use std::collections::HashMap;
use std::fs::File;
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::mpsc::{Sender, channel};
use std::sync::{Arc, Mutex};

use alacritty_terminal::event::{Event, EventListener, OnResize, WindowSize};
use alacritty_terminal::grid::{Dimensions, Scroll};
use alacritty_terminal::index::{Column, Line, Point, Side};
use alacritty_terminal::selection::{Selection, SelectionType};
use alacritty_terminal::sync::FairMutex;
pub use alacritty_terminal::term::TermMode;
use alacritty_terminal::term::cell::Flags;
use alacritty_terminal::term::color::Colors;
use alacritty_terminal::term::{Config, Term};
use alacritty_terminal::tty::{self, Pty, Shell};
use alacritty_terminal::vte::ansi::{Color, CursorShape, NamedColor, Processor, Rgb};

mod integration;

pub struct TermPalette {
    pub ansi: [u32; 16],
    pub fg: u32,
    pub bg: u32,
    pub dim: u32,
    pub cursor: u32,
}

// VS Code Dark Modern / Light Modern terminal paletleri
pub const DARK: TermPalette = TermPalette {
    ansi: [
        0x000000, 0xCD3131, 0x0DBC79, 0xE5E510, 0x2472C8, 0xBC3FBC, 0x11A8CD, 0xE5E5E5, 0x666666, 0xF14C4C, 0x23D18B, 0xF5F543, 0x3B8EEA,
        0xD670D6, 0x29B8DB, 0xE5E5E5,
    ],
    fg: 0xCCCCCC,
    bg: 0x181818,
    dim: 0x999999,
    cursor: 0xAEAFAD,
};
pub const LIGHT: TermPalette = TermPalette {
    ansi: [
        0x000000, 0xCD3131, 0x00BC00, 0x949800, 0x0451A5, 0xBC05BC, 0x0598BC, 0x555555, 0x666666, 0xCD3131, 0x14CE14, 0xB5BA00, 0x0451A5,
        0xBC05BC, 0x0598BC, 0xA5A5A5,
    ],
    fg: 0x3B3B3B,
    bg: 0xF8F8F8,
    dim: 0x777777,
    cursor: 0x000000,
};

// hücre bayrakları (Swift ile ortak)
pub mod flag {
    pub const BOLD: u32 = 1;
    pub const ITALIC: u32 = 2;
    pub const UNDERLINE: u32 = 4;
    pub const WIDE: u32 = 8;
    pub const SPACER: u32 = 16;
    pub const SELECTED: u32 = 32;
    pub const STRIKE: u32 = 64;
}

#[derive(Clone, Default)]
struct Listener {
    dirty: Arc<AtomicBool>,
    exited: Arc<AtomicBool>,
    title: Arc<Mutex<String>>,
    writer: Arc<Mutex<Option<Sender<Vec<u8>>>>>,
}

impl EventListener for Listener {
    fn send_event(&self, event: Event) {
        match event {
            Event::Wakeup => {}
            Event::Title(t) => *self.title.lock().unwrap() = t,
            Event::ResetTitle => self.title.lock().unwrap().clear(),
            Event::PtyWrite(text) => {
                if let Some(w) = self.writer.lock().unwrap().as_ref() {
                    let _ = w.send(text.into_bytes());
                }
            }
            Event::Exit | Event::ChildExit(_) => self.exited.store(true, Ordering::Relaxed),
            _ => return,
        }
        self.dirty.store(true, Ordering::Relaxed);
    }
}

// kabuk entegrasyonundan gelen durum (OSC 7 / 133)
#[derive(Default)]
struct ShellState {
    cwd: Option<String>,
    // (mutlak satır, çıkış kodu; None = sonuç bekleniyor / komut yok)
    marks: Vec<(usize, Option<i32>, bool)>,
}

// OSC dizilerini bayt akışında bulan küçük durum makinesi
#[derive(Default)]
struct OscScanner {
    state: u8, // 0 normal, 1 ESC, 2 OSC içinde, 3 OSC içinde ESC
    buf: Vec<u8>,
}

impl OscScanner {
    // tamamlanan OSC gövdesini ve bittiği bayt konumunu döndürür
    fn feed(&mut self, bytes: &[u8], mut on: impl FnMut(usize, &[u8])) {
        for (i, &b) in bytes.iter().enumerate() {
            match (self.state, b) {
                (0, 0x1b) => self.state = 1,
                (0, _) => {}
                (1, b']') => {
                    self.state = 2;
                    self.buf.clear();
                }
                (1, 0x1b) => {}
                (1, _) => self.state = 0,
                (2, 0x07) => {
                    on(i + 1, &self.buf);
                    self.state = 0;
                }
                (2, 0x1b) => self.state = 3,
                (2, _) => {
                    if self.buf.len() < 4096 {
                        self.buf.push(b);
                    }
                }
                (3, b'\\') => {
                    on(i + 1, &self.buf);
                    self.state = 0;
                }
                (3, _) => {
                    self.state = if b == 0x1b { 1 } else { 0 };
                }
                _ => self.state = 0,
            }
        }
    }
}

fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() && b[i + 1].is_ascii_hexdigit() && b[i + 2].is_ascii_hexdigit() {
            let hex = |c: u8| (c as char).to_digit(16).unwrap_or(0) as u8;
            out.push(hex(b[i + 1]) << 4 | hex(b[i + 2]));
            i += 3;
            continue;
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

struct Size {
    cols: usize,
    lines: usize,
}

impl Dimensions for Size {
    fn total_lines(&self) -> usize {
        self.lines
    }
    fn screen_lines(&self) -> usize {
        self.lines
    }
    fn columns(&self) -> usize {
        self.cols
    }
}

pub struct Snapshot {
    // her hücre için: karakter, ön plan, arka plan, bayraklar
    pub cells: Vec<u32>,
    pub cursor: Option<(usize, usize)>,
    pub cursor_block: bool,
}

pub struct Terminal {
    term: Arc<FairMutex<Term<Listener>>>,
    writer: Sender<Vec<u8>>,
    pty: Mutex<Pty>,
    listener: Listener,
    shell: Arc<Mutex<ShellState>>,
    last_exit: Arc<AtomicI32>,
    cols: usize,
    lines: usize,
    light: AtomicBool,
}

fn pack(c: Rgb) -> u32 {
    (c.r as u32) << 16 | (c.g as u32) << 8 | c.b as u32
}

fn indexed(i: u8, p: &TermPalette) -> u32 {
    match i {
        0..=15 => p.ansi[i as usize],
        16..=231 => {
            let i = i - 16;
            let step = |v: u8| if v == 0 { 0 } else { 55 + v as u32 * 40 };
            step(i / 36) << 16 | step((i / 6) % 6) << 8 | step(i % 6)
        }
        _ => {
            let v = 8 + (i as u32 - 232) * 10;
            v << 16 | v << 8 | v
        }
    }
}

fn resolve(color: Color, colors: &Colors, bold: bool, p: &TermPalette) -> u32 {
    match color {
        Color::Spec(rgb) => pack(rgb),
        Color::Indexed(i) => {
            let i = if bold && i < 8 { i + 8 } else { i };
            colors[i as usize].map_or(indexed(i, p), pack)
        }
        Color::Named(n) => {
            if let Some(rgb) = colors[n] {
                return pack(rgb);
            }
            let idx = n as usize;
            match n {
                NamedColor::Foreground | NamedColor::BrightForeground => p.fg,
                NamedColor::DimForeground => p.dim,
                NamedColor::Background => p.bg,
                NamedColor::Cursor => p.cursor,
                _ if idx < 8 && bold => p.ansi[idx + 8],
                _ if idx < 16 => p.ansi[idx],
                _ => {
                    // Dim* renkler
                    let base = idx.saturating_sub(NamedColor::DimBlack as usize) % 8;
                    p.ansi[base]
                }
            }
        }
    }
}

impl Terminal {
    pub fn spawn(cwd: Option<PathBuf>, cols: usize, lines: usize, cell_w: u16, cell_h: u16) -> io::Result<Self> {
        Self::spawn_with(cwd, cols, lines, cell_w, cell_h, 10_000, &HashMap::new())
    }

    pub fn spawn_with(
        cwd: Option<PathBuf>,
        cols: usize,
        lines: usize,
        cell_w: u16,
        cell_h: u16,
        scrollback: usize,
        extra_env: &HashMap<String, String>,
    ) -> io::Result<Self> {
        let (cols, lines) = (cols.max(2), lines.max(1));
        let listener = Listener::default();
        let config = Config { scrolling_history: scrollback.clamp(100, 1_000_000), ..Config::default() };
        let term = Arc::new(FairMutex::new(Term::new(config, &Size { cols, lines }, listener.clone())));

        let mut env = HashMap::new();
        env.insert("TERM".to_string(), "xterm-256color".to_string());
        env.insert("COLORTERM".to_string(), "truecolor".to_string());
        env.insert("TERM_PROGRAM".to_string(), "Kern".to_string());
        env.extend(extra_env.iter().map(|(k, v)| (k.clone(), v.clone())));
        let (shell, integration_env) = integration::setup();
        env.extend(integration_env);
        let options = tty::Options {
            shell: shell.map(|(program, args)| Shell::new(program, args)),
            working_directory: cwd,
            drain_on_exit: false,
            env,
        };
        let size = WindowSize { num_lines: lines as u16, num_cols: cols as u16, cell_width: cell_w, cell_height: cell_h };
        let pty = tty::new(&options, size, 0)?;

        // okuma/yazma için engelleyen kopyalar
        let reader = pty.file().try_clone()?;
        let mut writer_file = pty.file().try_clone()?;
        unsafe {
            let fd = reader.as_raw_fd();
            let flags = libc::fcntl(fd, libc::F_GETFL);
            libc::fcntl(fd, libc::F_SETFL, flags & !libc::O_NONBLOCK);
        }
        let (tx, rx) = channel::<Vec<u8>>();
        *listener.writer.lock().unwrap() = Some(tx.clone());
        std::thread::spawn(move || {
            for bytes in rx {
                if writer_file.write_all(&bytes).is_err() {
                    break;
                }
            }
        });

        let shell_state = Arc::new(Mutex::new(ShellState::default()));
        let last_exit = Arc::new(AtomicI32::new(-1));
        {
            let (term, listener, shell_state, last_exit) = (term.clone(), listener.clone(), shell_state.clone(), last_exit.clone());
            std::thread::spawn(move || read_loop(reader, term, listener, shell_state, last_exit));
        }
        Ok(Self {
            term,
            writer: tx,
            pty: Mutex::new(pty),
            listener,
            shell: shell_state,
            last_exit,
            cols,
            lines,
            light: AtomicBool::new(false),
        })
    }

    pub fn write(&self, bytes: &[u8]) {
        self.term.lock().scroll_display(Scroll::Bottom);
        let _ = self.writer.send(bytes.to_vec());
    }

    // OSC 7 ile bildirilen çalışma dizini
    pub fn cwd(&self) -> Option<String> {
        self.shell.lock().unwrap().cwd.clone()
    }

    pub fn last_exit(&self) -> i32 {
        self.last_exit.load(Ordering::Relaxed)
    }

    // görünür satırlardaki komut işaretleri: (satır, çıkış kodu; -1 = çalışıyor)
    pub fn marks(&self) -> Vec<(usize, i32)> {
        let term = self.term.lock();
        let grid = term.grid();
        let top = grid.history_size() - grid.display_offset();
        let shell = self.shell.lock().unwrap();
        shell
            .marks
            .iter()
            .filter(|(_, _, ran)| *ran)
            .filter_map(|&(abs, exit, _)| (abs >= top && abs < top + self.lines).then(|| (abs - top, exit.unwrap_or(-1))))
            .collect()
    }

    // görünür satırın metni (geniş karakter boşlukları atlanır)
    pub fn row_text(&self, row: usize) -> String {
        if row >= self.lines {
            return String::new();
        }
        let term = self.term.lock();
        let line = Line(row as i32 - term.grid().display_offset() as i32);
        Self::line_text(&term, line, self.cols).0.trim_end().to_string()
    }

    fn line_text(term: &Term<Listener>, line: Line, cols: usize) -> (String, bool) {
        let grid = term.grid();
        let mut out = String::new();
        for col in 0..cols {
            let cell = &grid[line][Column(col)];
            if cell.flags.intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER) {
                continue;
            }
            out.push(cell.c);
        }
        (out, grid[line][Column(cols - 1)].flags.contains(Flags::WRAPLINE))
    }

    // sarılmış satırlar birleştirilmiş mantıksal satır + bu satırın başladığı karakter ofseti
    pub fn logical_line(&self, row: usize) -> (String, usize) {
        if row >= self.lines {
            return (String::new(), 0);
        }
        let term = self.term.lock();
        let grid = term.grid();
        let line = Line(row as i32 - grid.display_offset() as i32);
        let top = Line(-(grid.history_size() as i32));
        let bottom = Line(self.lines as i32 - 1);
        let mut first = line;
        while first > top && Self::line_text(&term, first - 1, self.cols).1 {
            first = first - 1;
        }
        let mut text = String::new();
        let mut offset = 0;
        let mut l = first;
        loop {
            if l == line {
                offset = text.chars().count();
            }
            let (t, wraps) = Self::line_text(&term, l, self.cols);
            text.push_str(&t);
            if !wraps || l >= bottom {
                break;
            }
            l = l + 1;
        }
        (text.trim_end().to_string(), offset)
    }

    pub fn resize(&mut self, cols: usize, lines: usize, cell_w: u16, cell_h: u16) {
        let (cols, lines) = (cols.max(2), lines.max(1));
        if cols == self.cols && lines == self.lines {
            return;
        }
        self.cols = cols;
        self.lines = lines;
        self.term.lock().resize(Size { cols, lines });
        let size = WindowSize { num_lines: lines as u16, num_cols: cols as u16, cell_width: cell_w, cell_height: cell_h };
        self.pty.lock().unwrap().on_resize(size);
        self.listener.dirty.store(true, Ordering::Relaxed);
    }

    pub fn scroll(&self, delta: i32) {
        self.term.lock().scroll_display(Scroll::Delta(delta));
        self.listener.dirty.store(true, Ordering::Relaxed);
    }

    pub fn set_light(&self, light: bool) {
        if self.light.swap(light, Ordering::Relaxed) != light {
            self.listener.dirty.store(true, Ordering::Relaxed);
        }
    }

    pub fn palette(&self) -> &'static TermPalette {
        if self.light.load(Ordering::Relaxed) { &LIGHT } else { &DARK }
    }

    pub fn take_dirty(&self) -> bool {
        self.listener.dirty.swap(false, Ordering::Relaxed)
    }

    pub fn is_alive(&self) -> bool {
        !self.listener.exited.load(Ordering::Relaxed)
    }

    pub fn title(&self) -> String {
        self.listener.title.lock().unwrap().clone()
    }

    pub fn mode(&self) -> TermMode {
        *self.term.lock().mode()
    }

    pub fn size(&self) -> (usize, usize) {
        (self.cols, self.lines)
    }

    fn point(&self, term: &Term<Listener>, row: usize, col: usize) -> Point {
        let offset = term.grid().display_offset() as i32;
        Point::new(Line(row as i32 - offset), Column(col.min(self.cols - 1)))
    }

    // kind: 0 karakter, 1 kelime, 2 satır
    pub fn select_start(&self, row: usize, col: usize, right: bool, kind: u8) {
        let mut term = self.term.lock();
        let ty = match kind {
            1 => SelectionType::Semantic,
            2 => SelectionType::Lines,
            _ => SelectionType::Simple,
        };
        let p = self.point(&term, row, col);
        term.selection = Some(Selection::new(ty, p, if right { Side::Right } else { Side::Left }));
        self.listener.dirty.store(true, Ordering::Relaxed);
    }

    pub fn select_update(&self, row: usize, col: usize, right: bool) {
        let mut term = self.term.lock();
        let p = self.point(&term, row, col);
        if let Some(sel) = term.selection.as_mut() {
            sel.update(p, if right { Side::Right } else { Side::Left });
        }
        self.listener.dirty.store(true, Ordering::Relaxed);
    }

    pub fn select_clear(&self) {
        self.term.lock().selection = None;
        self.listener.dirty.store(true, Ordering::Relaxed);
    }

    pub fn selection_text(&self) -> String {
        self.term.lock().selection_to_string().unwrap_or_default()
    }

    pub fn snapshot(&self) -> Snapshot {
        let term = self.term.lock();
        let content = term.renderable_content();
        let offset = content.display_offset as i32;
        let (cols, lines) = (self.cols, self.lines);
        let p = self.palette();
        let mut cells = vec![0u32; cols * lines * 4];
        for i in 0..cols * lines {
            cells[i * 4] = ' ' as u32;
            cells[i * 4 + 1] = p.fg;
            cells[i * 4 + 2] = p.bg;
        }
        let selection = content.selection;
        for item in content.display_iter {
            let row = item.point.line.0 + offset;
            let col = item.point.column.0;
            if row < 0 || row as usize >= lines || col >= cols {
                continue;
            }
            let cell = item.cell;
            let bold = cell.flags.contains(Flags::BOLD);
            let mut fg = resolve(cell.fg, content.colors, bold, p);
            let mut bg = resolve(cell.bg, content.colors, false, p);
            if cell.flags.contains(Flags::INVERSE) {
                std::mem::swap(&mut fg, &mut bg);
            }
            if cell.flags.contains(Flags::HIDDEN) {
                fg = bg;
            }
            let mut f = 0;
            if bold {
                f |= flag::BOLD;
            }
            if cell.flags.contains(Flags::ITALIC) {
                f |= flag::ITALIC;
            }
            if cell.flags.intersects(Flags::UNDERLINE | Flags::DOUBLE_UNDERLINE | Flags::UNDERCURL) {
                f |= flag::UNDERLINE;
            }
            if cell.flags.contains(Flags::STRIKEOUT) {
                f |= flag::STRIKE;
            }
            if cell.flags.contains(Flags::WIDE_CHAR) {
                f |= flag::WIDE;
            }
            if cell.flags.intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER) {
                f |= flag::SPACER;
            }
            if selection.is_some_and(|s| s.contains(item.point)) {
                f |= flag::SELECTED;
            }
            let i = (row as usize * cols + col) * 4;
            cells[i] = cell.c as u32;
            cells[i + 1] = fg;
            cells[i + 2] = bg;
            cells[i + 3] = f;
        }
        let c = content.cursor;
        let row = c.point.line.0 + offset;
        let cursor =
            (c.shape != CursorShape::Hidden && row >= 0 && (row as usize) < lines).then(|| (row as usize, c.point.column.0.min(cols - 1)));
        Snapshot { cells, cursor, cursor_block: c.shape == CursorShape::Block }
    }
}

fn read_loop(
    mut reader: File,
    term: Arc<FairMutex<Term<Listener>>>,
    listener: Listener,
    shell: Arc<Mutex<ShellState>>,
    last_exit: Arc<AtomicI32>,
) {
    let mut parser: Processor = Processor::new();
    let mut scanner = OscScanner::default();
    let mut buf = vec![0u8; 65536];
    loop {
        let n = match reader.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => break,
        };
        let chunk = &buf[..n];
        let mut t = term.lock();
        let mut fed = 0;
        let mut events: Vec<(usize, Vec<u8>)> = Vec::new();
        scanner.feed(chunk, |end, body| {
            if body.starts_with(b"133;") || body.starts_with(b"7;") {
                events.push((end, body.to_vec()));
            }
        });
        for (end, body) in events {
            parser.advance(&mut *t, &chunk[fed..end]);
            fed = end;
            let text = String::from_utf8_lossy(&body);
            let grid = t.grid();
            let abs = grid.history_size() + t.grid().cursor.point.line.0.max(0) as usize;
            let mut st = shell.lock().unwrap();
            if let Some(url) = text.strip_prefix("7;") {
                // file://host/yol
                let path = url.strip_prefix("file://").map(|r| r.find('/').map_or("", |i| &r[i..])).unwrap_or(url);
                st.cwd = Some(percent_decode(path));
            } else {
                let mut parts = text[4..].split(';');
                match parts.next() {
                    Some("A") => {
                        st.marks.push((abs, None, false));
                        if st.marks.len() > 5000 {
                            st.marks.drain(..1000);
                        }
                    }
                    Some("C") => {
                        if let Some(m) = st.marks.last_mut() {
                            m.2 = true;
                        }
                    }
                    Some("D") => {
                        let code = parts.next().and_then(|c| c.trim().parse().ok()).unwrap_or(0);
                        if let Some(m) = st.marks.last_mut() {
                            if m.2 && m.1.is_none() {
                                m.1 = Some(code);
                                last_exit.store(code, Ordering::Relaxed);
                            }
                        }
                    }
                    _ => {}
                }
            }
        }
        parser.advance(&mut *t, &chunk[fed..]);
        drop(t);
        listener.dirty.store(true, Ordering::Relaxed);
    }
    listener.exited.store(true, Ordering::Relaxed);
    listener.dirty.store(true, Ordering::Relaxed);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    #[test]
    fn runs_a_command() {
        let t = Terminal::spawn(None, 80, 24, 8, 16).unwrap();
        t.write(b"echo kern-$((40+2))\r");
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let snap = t.snapshot();
            let text: String = snap.cells.chunks(4).map(|c| char::from_u32(c[0]).unwrap_or(' ')).collect();
            if text.contains("kern-42") {
                break;
            }
            assert!(Instant::now() < deadline, "çıktı gelmedi: {}", text.trim());
            std::thread::sleep(Duration::from_millis(50));
        }
        assert!(t.is_alive());
        // kabuk entegrasyonu: çalışma dizini ve çıkış kodu
        t.write(b"cd /tmp && false\r");
        let deadline = Instant::now() + Duration::from_secs(10);
        while !(t.cwd().is_some_and(|c| c.ends_with("/tmp")) && t.last_exit() == 1) {
            assert!(Instant::now() < deadline, "osc gelmedi: cwd={:?} exit={}", t.cwd(), t.last_exit());
            std::thread::sleep(Duration::from_millis(50));
        }
        assert!(!t.marks().is_empty());
    }

    #[test]
    fn osc_scanner_and_decode() {
        let mut s = OscScanner::default();
        let mut got = Vec::new();
        s.feed(b"ab\x1b]133;A\x07cd\x1b]7;file://h/a%20b", |e, b| got.push((e, b.to_vec())));
        s.feed(b"\x1b\\x", |e, b| got.push((e, b.to_vec())));
        assert_eq!(got[0], (10, b"133;A".to_vec()));
        assert_eq!(got[1], (2, b"7;file://h/a%20b".to_vec()));
        assert_eq!(percent_decode("/a%20b%C3%A7"), "/a bç");
    }
}
