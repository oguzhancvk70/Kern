use std::borrow::Cow;
use std::collections::HashMap;
use std::io;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use alacritty_terminal::event::{Event, EventListener, WindowSize};
use alacritty_terminal::event_loop::{EventLoop, EventLoopSender, Msg};
use alacritty_terminal::grid::{Dimensions, Scroll};
use alacritty_terminal::index::{Column, Line, Point, Side};
use alacritty_terminal::selection::{Selection, SelectionType};
use alacritty_terminal::sync::FairMutex;
use alacritty_terminal::term::cell::Flags;
use alacritty_terminal::term::color::Colors;
pub use alacritty_terminal::term::TermMode;
use alacritty_terminal::term::{Config, Term};
use alacritty_terminal::tty;
use alacritty_terminal::vte::ansi::{Color, CursorShape, NamedColor, Rgb};

// VS Code Dark Modern terminal paleti
const ANSI: [u32; 16] = [
    0x000000, 0xCD3131, 0x0DBC79, 0xE5E510, 0x2472C8, 0xBC3FBC, 0x11A8CD, 0xE5E5E5,
    0x666666, 0xF14C4C, 0x23D18B, 0xF5F543, 0x3B8EEA, 0xD670D6, 0x29B8DB, 0xE5E5E5,
];
pub const FOREGROUND: u32 = 0xCCCCCC;
pub const BACKGROUND: u32 = 0x181818;

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
    sender: Arc<Mutex<Option<EventLoopSender>>>,
}

impl EventListener for Listener {
    fn send_event(&self, event: Event) {
        match event {
            Event::Wakeup => {}
            Event::Title(t) => *self.title.lock().unwrap() = t,
            Event::ResetTitle => self.title.lock().unwrap().clear(),
            Event::PtyWrite(text) => {
                if let Some(s) = self.sender.lock().unwrap().as_ref() {
                    let _ = s.send(Msg::Input(Cow::Owned(text.into_bytes())));
                }
            }
            Event::Exit | Event::ChildExit(_) => self.exited.store(true, Ordering::Relaxed),
            _ => return,
        }
        self.dirty.store(true, Ordering::Relaxed);
    }
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
    sender: EventLoopSender,
    listener: Listener,
    cols: usize,
    lines: usize,
}

fn pack(c: Rgb) -> u32 {
    (c.r as u32) << 16 | (c.g as u32) << 8 | c.b as u32
}

fn indexed(i: u8) -> u32 {
    match i {
        0..=15 => ANSI[i as usize],
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

fn resolve(color: Color, colors: &Colors, bold: bool) -> u32 {
    match color {
        Color::Spec(rgb) => pack(rgb),
        Color::Indexed(i) => {
            let i = if bold && i < 8 { i + 8 } else { i };
            colors[i as usize].map_or(indexed(i), pack)
        }
        Color::Named(n) => {
            if let Some(rgb) = colors[n] {
                return pack(rgb);
            }
            let idx = n as usize;
            match n {
                NamedColor::Foreground | NamedColor::BrightForeground => FOREGROUND,
                NamedColor::DimForeground => 0x999999,
                NamedColor::Background => BACKGROUND,
                NamedColor::Cursor => 0xAEAFAD,
                _ if idx < 8 && bold => ANSI[idx + 8],
                _ if idx < 16 => ANSI[idx],
                _ => {
                    // Dim* renkler
                    let base = idx.saturating_sub(NamedColor::DimBlack as usize) % 8;
                    ANSI[base]
                }
            }
        }
    }
}

impl Terminal {
    pub fn spawn(cwd: Option<PathBuf>, cols: usize, lines: usize, cell_w: u16, cell_h: u16) -> io::Result<Self> {
        let (cols, lines) = (cols.max(2), lines.max(1));
        let listener = Listener::default();
        let config = Config { scrolling_history: 10_000, ..Config::default() };
        let term = Arc::new(FairMutex::new(Term::new(config, &Size { cols, lines }, listener.clone())));

        let mut env = HashMap::new();
        env.insert("TERM".to_string(), "xterm-256color".to_string());
        env.insert("COLORTERM".to_string(), "truecolor".to_string());
        env.insert("TERM_PROGRAM".to_string(), "Kern".to_string());
        let options = tty::Options { shell: None, working_directory: cwd, drain_on_exit: false, env };
        let size = WindowSize { num_lines: lines as u16, num_cols: cols as u16, cell_width: cell_w, cell_height: cell_h };
        let pty = tty::new(&options, size, 0)?;

        let event_loop = EventLoop::new(term.clone(), listener.clone(), pty, false, false)?;
        let sender = event_loop.channel();
        *listener.sender.lock().unwrap() = Some(sender.clone());
        event_loop.spawn();
        Ok(Self { term, sender, listener, cols, lines })
    }

    pub fn write(&self, bytes: &[u8]) {
        self.term.lock().scroll_display(Scroll::Bottom);
        let _ = self.sender.send(Msg::Input(Cow::Owned(bytes.to_vec())));
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
        let _ = self.sender.send(Msg::Resize(size));
        self.listener.dirty.store(true, Ordering::Relaxed);
    }

    pub fn scroll(&self, delta: i32) {
        self.term.lock().scroll_display(Scroll::Delta(delta));
        self.listener.dirty.store(true, Ordering::Relaxed);
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
        let mut cells = vec![0u32; cols * lines * 4];
        for i in 0..cols * lines {
            cells[i * 4] = ' ' as u32;
            cells[i * 4 + 1] = FOREGROUND;
            cells[i * 4 + 2] = BACKGROUND;
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
            let mut fg = resolve(cell.fg, content.colors, bold);
            let mut bg = resolve(cell.bg, content.colors, false);
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
        let cursor = (c.shape != CursorShape::Hidden && row >= 0 && (row as usize) < lines)
            .then(|| (row as usize, c.point.column.0.min(cols - 1)));
        Snapshot { cells, cursor, cursor_block: c.shape == CursorShape::Block }
    }
}

impl Drop for Terminal {
    fn drop(&mut self) {
        let _ = self.sender.send(Msg::Shutdown);
    }
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
    }
}
