use kern_core::{Document, Editor, Motion};

// ekranda gösterilen satır uzunluğu sınırı (minified dosyalar için)
const MAX_LINE_CHARS: usize = 10_000;

#[swift_bridge::bridge]
mod ffi {
    enum KernMotion {
        Left,
        Right,
        Up,
        Down,
        WordLeft,
        WordRight,
        LineStart,
        LineEnd,
        PageUp,
        PageDown,
        DocStart,
        DocEnd,
    }

    extern "Rust" {
        fn kern_version() -> String;
    }

    extern "Rust" {
        type KernEditor;

        #[swift_bridge(init)]
        fn new() -> KernEditor;
        fn open_editor(path: &str) -> Option<KernEditor>;

        fn line_count(&self) -> usize;
        fn line(&self, index: usize) -> String;
        fn cursor_line(&self) -> usize;
        fn cursor_col(&self) -> usize;
        fn anchor_line(&self) -> usize;
        fn anchor_col(&self) -> usize;
        fn has_selection(&self) -> bool;
        fn selected_text(&self) -> String;

        fn move_cursor(&mut self, motion: KernMotion, extend: bool);
        fn set_page_lines(&mut self, lines: usize);
        fn click(&mut self, line: usize, col: usize, extend: bool);
        fn select_word(&mut self, line: usize, col: usize);
        fn select_line(&mut self, line: usize);
        fn select_all(&mut self);
        fn collapse_selection(&mut self);

        fn insert_text(&mut self, text: &str);
        fn insert_newline(&mut self);
        fn insert_tab(&mut self);
        fn delete_backward(&mut self);
        fn delete_forward(&mut self);
        fn delete_word_backward(&mut self);
        fn delete_word_forward(&mut self);
        fn delete_to_line_start(&mut self);
        fn undo(&mut self) -> bool;
        fn redo(&mut self) -> bool;

        fn is_dirty(&self) -> bool;
        fn path(&self) -> String;
        fn save(&mut self) -> bool;
        fn save_as(&mut self, path: &str) -> bool;

        fn type_text(&mut self, text: &str);
        fn language(&self) -> String;
        fn line_ending_name(&self) -> String;
        fn highlights(&mut self, first: usize, last: usize) -> Vec<u32>;
        fn matching_bracket(&self) -> Vec<u32>;
        fn toggle_comment(&mut self);
        fn indent_lines(&mut self, indent: bool);
        fn move_lines(&mut self, up: bool);
        fn duplicate_lines(&mut self, down: bool);
        fn delete_lines(&mut self);
        fn select_range(&mut self, line: usize, col: usize, len: usize);
        fn selections(&self) -> Vec<u32>;
        fn add_cursor(&mut self, line: usize, col: usize);
        fn add_cursor_vertical(&mut self, up: bool);
        fn add_next_occurrence(&mut self);
        fn select_all_occurrences(&mut self);

        fn find_next(&mut self, query: &str, case_sensitive: bool, forward: bool) -> bool;
        fn find_in_lines(&self, query: &str, case_sensitive: bool, first: usize, last: usize) -> Vec<u32>;
        fn find_status(&self, query: &str, case_sensitive: bool) -> Vec<u32>;
        fn replace_one(&mut self, query: &str, replacement: &str, case_sensitive: bool);
        fn replace_all(&mut self, query: &str, replacement: &str, case_sensitive: bool) -> usize;
    }

    extern "Rust" {
        type KernTerminal;

        fn spawn_terminal(cwd: &str, cols: usize, rows: usize, cell_w: u16, cell_h: u16) -> Option<KernTerminal>;
        fn write_text(&self, text: &str);
        fn resize(&mut self, cols: usize, rows: usize, cell_w: u16, cell_h: u16);
        fn scroll(&self, delta: i32);
        fn take_dirty(&self) -> bool;
        fn is_alive(&self) -> bool;
        fn title(&self) -> String;
        fn app_cursor(&self) -> bool;
        fn bracketed_paste(&self) -> bool;
        fn snapshot(&self) -> Vec<u32>;
        fn select_start(&self, row: usize, col: usize, right: bool, kind: u8);
        fn select_update(&self, row: usize, col: usize, right: bool);
        fn select_clear(&self);
        fn selection_text(&self) -> String;
    }

    extern "Rust" {
        type KernWorkspace;

        #[swift_bridge(init)]
        fn new(root: &str) -> KernWorkspace;
        fn refresh(&mut self);
        fn file_count(&self) -> usize;
        fn quick_open(&self, query: &str, limit: usize) -> String;
        fn search(&self, query: &str, case_sensitive: bool, limit: usize) -> String;
    }
}

use ffi::KernMotion;

pub struct KernTerminal(kern_term::Terminal);

fn spawn_terminal(cwd: &str, cols: usize, rows: usize, cell_w: u16, cell_h: u16) -> Option<KernTerminal> {
    let cwd = (!cwd.is_empty()).then(|| cwd.into());
    kern_term::Terminal::spawn(cwd, cols, rows, cell_w, cell_h).ok().map(KernTerminal)
}

impl KernTerminal {
    fn write_text(&self, text: &str) {
        self.0.write(text.as_bytes());
    }

    fn resize(&mut self, cols: usize, rows: usize, cell_w: u16, cell_h: u16) {
        self.0.resize(cols, rows, cell_w, cell_h);
    }

    fn scroll(&self, delta: i32) {
        self.0.scroll(delta);
    }

    fn take_dirty(&self) -> bool {
        self.0.take_dirty()
    }

    fn is_alive(&self) -> bool {
        self.0.is_alive()
    }

    fn title(&self) -> String {
        self.0.title()
    }

    fn app_cursor(&self) -> bool {
        self.0.mode().contains(alacritty_mode::APP_CURSOR)
    }

    fn bracketed_paste(&self) -> bool {
        self.0.mode().contains(alacritty_mode::BRACKETED_PASTE)
    }

    // hücreler (karakter, ön, arka, bayrak)* + [imleç satırı, sütunu, görünür, blok]
    fn snapshot(&self) -> Vec<u32> {
        let s = self.0.snapshot();
        let mut out = s.cells;
        let (row, col) = s.cursor.unwrap_or((0, 0));
        out.extend([row as u32, col as u32, s.cursor.is_some() as u32, s.cursor_block as u32]);
        out
    }

    fn select_start(&self, row: usize, col: usize, right: bool, kind: u8) {
        self.0.select_start(row, col, right, kind);
    }

    fn select_update(&self, row: usize, col: usize, right: bool) {
        self.0.select_update(row, col, right);
    }

    fn select_clear(&self) {
        self.0.select_clear();
    }

    fn selection_text(&self) -> String {
        self.0.selection_text()
    }
}

use kern_term::TermMode as alacritty_mode;

pub struct KernWorkspace(kern_search::Workspace);

impl KernWorkspace {
    fn new(root: &str) -> Self {
        Self(kern_search::Workspace::open(root))
    }

    fn refresh(&mut self) {
        self.0.refresh();
    }

    fn file_count(&self) -> usize {
        self.0.files().len()
    }

    // satır başına bir göreli yol
    fn quick_open(&self, query: &str, limit: usize) -> String {
        self.0.quick_open(query, limit).join("\n")
    }

    // satır başına: yol \t satır \t sütun16 \t uzunluk16 \t metin
    fn search(&self, query: &str, case_sensitive: bool, limit: usize) -> String {
        let mut out = String::new();
        for h in self.0.search(query, case_sensitive, limit) {
            let text = h.text.replace(['\t', '\n', '\r'], " ");
            out.push_str(&format!("{}\t{}\t{}\t{}\t{}\n", h.path, h.line, h.col16, h.len16, text));
        }
        out
    }
}

fn kern_version() -> String {
    kern_core::VERSION.to_string()
}

fn open_editor(path: &str) -> Option<KernEditor> {
    Document::open(path).ok().map(|d| KernEditor(Editor::new(d)))
}

pub struct KernEditor(Editor);

impl KernEditor {
    fn new() -> Self {
        Self(Editor::new(Document::default()))
    }

    fn line_count(&self) -> usize {
        self.0.doc.buffer.len_lines()
    }

    fn line(&self, index: usize) -> String {
        if index < self.line_count() { self.0.doc.buffer.line_prefix(index, MAX_LINE_CHARS) } else { String::new() }
    }

    fn cursor_line(&self) -> usize {
        self.0.doc.buffer.char_to_utf16(self.0.selection().head).0
    }

    fn cursor_col(&self) -> usize {
        self.0.doc.buffer.char_to_utf16(self.0.selection().head).1
    }

    fn anchor_line(&self) -> usize {
        self.0.doc.buffer.char_to_utf16(self.0.selection().anchor).0
    }

    fn anchor_col(&self) -> usize {
        self.0.doc.buffer.char_to_utf16(self.0.selection().anchor).1
    }

    fn has_selection(&self) -> bool {
        !self.0.selection().is_empty()
    }

    fn selected_text(&self) -> String {
        self.0.selected_text()
    }

    fn move_cursor(&mut self, motion: KernMotion, extend: bool) {
        let m = match motion {
            KernMotion::Left => Motion::Left,
            KernMotion::Right => Motion::Right,
            KernMotion::Up => Motion::Up,
            KernMotion::Down => Motion::Down,
            KernMotion::WordLeft => Motion::WordLeft,
            KernMotion::WordRight => Motion::WordRight,
            KernMotion::LineStart => Motion::LineStart,
            KernMotion::LineEnd => Motion::LineEnd,
            KernMotion::PageUp => Motion::PageUp,
            KernMotion::PageDown => Motion::PageDown,
            KernMotion::DocStart => Motion::DocStart,
            KernMotion::DocEnd => Motion::DocEnd,
        };
        self.0.move_cursor(m, extend);
    }

    fn set_page_lines(&mut self, lines: usize) {
        self.0.set_page_lines(lines);
    }

    fn click(&mut self, line: usize, col: usize, extend: bool) {
        self.0.click(line, col, extend);
    }

    fn select_word(&mut self, line: usize, col: usize) {
        self.0.select_word(line, col);
    }

    fn select_line(&mut self, line: usize) {
        self.0.select_line(line);
    }

    fn select_all(&mut self) {
        self.0.select_all();
    }

    fn collapse_selection(&mut self) {
        self.0.collapse_selection();
    }

    fn insert_text(&mut self, text: &str) {
        self.0.insert_text(text);
    }

    fn insert_newline(&mut self) {
        self.0.insert_newline();
    }

    fn insert_tab(&mut self) {
        self.0.insert_tab();
    }

    fn delete_backward(&mut self) {
        self.0.delete_backward();
    }

    fn delete_forward(&mut self) {
        self.0.delete_forward();
    }

    fn delete_word_backward(&mut self) {
        self.0.delete_word_backward();
    }

    fn delete_word_forward(&mut self) {
        self.0.delete_word_forward();
    }

    fn delete_to_line_start(&mut self) {
        self.0.delete_to_line_start();
    }

    fn undo(&mut self) -> bool {
        self.0.undo()
    }

    fn redo(&mut self) -> bool {
        self.0.redo()
    }

    fn is_dirty(&self) -> bool {
        self.0.is_dirty()
    }

    fn path(&self) -> String {
        self.0.doc.path.as_ref().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default()
    }

    fn save(&mut self) -> bool {
        self.0.save().is_ok()
    }

    fn save_as(&mut self, path: &str) -> bool {
        self.0.save_as(path).is_ok()
    }

    fn type_text(&mut self, text: &str) {
        self.0.type_text(text);
    }

    fn language(&self) -> String {
        self.0.language().to_string()
    }

    fn line_ending_name(&self) -> String {
        self.0.line_ending_name().to_string()
    }

    fn highlights(&mut self, first: usize, last: usize) -> Vec<u32> {
        self.0.highlights(first, last)
    }

    fn matching_bracket(&self) -> Vec<u32> {
        let b = &self.0.doc.buffer;
        match self.0.matching_bracket() {
            Some((a, z)) => {
                let (l1, c1) = b.char_to_utf16(a);
                let (l2, c2) = b.char_to_utf16(z);
                vec![l1 as u32, c1 as u32, l2 as u32, c2 as u32]
            }
            None => Vec::new(),
        }
    }

    fn toggle_comment(&mut self) {
        self.0.toggle_comment();
    }

    fn indent_lines(&mut self, indent: bool) {
        self.0.indent_lines(indent);
    }

    fn move_lines(&mut self, up: bool) {
        self.0.move_lines(up);
    }

    fn duplicate_lines(&mut self, down: bool) {
        self.0.duplicate_lines(down);
    }

    fn delete_lines(&mut self) {
        self.0.delete_lines();
    }

    // [çapa satırı, çapa sütunu, baş satırı, baş sütunu]* (UTF-16)
    fn selections(&self) -> Vec<u32> {
        let b = &self.0.doc.buffer;
        let mut out = Vec::new();
        for s in self.0.selections() {
            let (al, ac) = b.char_to_utf16(s.anchor);
            let (hl, hc) = b.char_to_utf16(s.head);
            out.extend([al as u32, ac as u32, hl as u32, hc as u32]);
        }
        out
    }

    fn add_cursor(&mut self, line: usize, col: usize) {
        self.0.add_cursor(line, col);
    }

    fn add_cursor_vertical(&mut self, up: bool) {
        self.0.add_cursor_vertical(up);
    }

    fn add_next_occurrence(&mut self) {
        self.0.add_next_occurrence();
    }

    fn select_all_occurrences(&mut self) {
        self.0.select_all_occurrences();
    }

    fn select_range(&mut self, line: usize, col: usize, len: usize) {
        self.0.click(line, col, false);
        self.0.click(line, col + len, true);
    }

    fn find_next(&mut self, query: &str, case_sensitive: bool, forward: bool) -> bool {
        self.0.find_next(query, case_sensitive, forward)
    }

    fn find_in_lines(&self, query: &str, case_sensitive: bool, first: usize, last: usize) -> Vec<u32> {
        self.0.find_in_lines(query, case_sensitive, first, last)
    }

    fn find_status(&self, query: &str, case_sensitive: bool) -> Vec<u32> {
        let (total, current) = self.0.find_status(query, case_sensitive);
        vec![total as u32, current as u32]
    }

    fn replace_one(&mut self, query: &str, replacement: &str, case_sensitive: bool) {
        self.0.replace_one(query, replacement, case_sensitive);
    }

    fn replace_all(&mut self, query: &str, replacement: &str, case_sensitive: bool) -> usize {
        self.0.replace_all(query, replacement, case_sensitive)
    }
}
