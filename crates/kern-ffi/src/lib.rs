use std::cell::{RefCell, RefMut};
use std::rc::Rc;

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
        fn find_error(query: &str, flags: u8) -> String;
    }

    extern "Rust" {
        type KernEditor;

        #[swift_bridge(init)]
        fn new() -> KernEditor;
        fn open_editor(path: &str) -> Option<KernEditor>;
        fn split_view(&self) -> KernEditor;

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
        fn save(&mut self) -> String;
        fn save_as(&mut self, path: &str) -> String;
        fn encoding_name(&self) -> String;
        fn reload(&mut self) -> bool;
        fn wrap_rows(&self, cols: usize) -> Vec<u32>;
        fn wrap_breaks(&self, line: usize, cols: usize) -> Vec<u32>;
        fn fold_ranges(&self) -> Vec<u32>;
        fn byte_len(&self) -> usize;
        fn version(&self) -> u64;
        fn prepare_save(&mut self, trim: bool, final_newline: bool);
        fn text(&self) -> String;
        fn apply_edits(&mut self, json: &str) -> bool;
        fn set_indent(&mut self, tab_width: usize, insert_spaces: bool, detect: bool);
        fn tab_width(&self) -> usize;
        fn insert_spaces(&self) -> bool;
        fn disk_changed(&self) -> bool;
        fn disk_missing(&self) -> bool;

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

        fn find_next(&mut self, query: &str, flags: u8, forward: bool) -> bool;
        fn find_in_lines(&self, query: &str, flags: u8, first: usize, last: usize) -> Vec<u32>;
        fn find_status(&self, query: &str, flags: u8) -> Vec<u32>;
        fn replace_one(&mut self, query: &str, replacement: &str, flags: u8);
        fn replace_all(&mut self, query: &str, replacement: &str, flags: u8) -> usize;
    }

    extern "Rust" {
        type KernTerminal;

        fn spawn_terminal(cwd: &str, cols: usize, rows: usize, cell_w: u16, cell_h: u16, scrollback: usize, env: &str) -> Option<KernTerminal>;
        fn cwd(&self) -> String;
        fn last_exit(&self) -> i32;
        fn marks(&self) -> Vec<i32>;
        fn row_text(&self, row: usize) -> String;
        fn logical_line(&self, row: usize) -> String;
        fn logical_offset(&self, row: usize) -> usize;
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
        fn set_light(&self, light: bool);
        fn background(&self) -> u32;
    }

    extern "Rust" {
        type KernWorkspace;

        #[swift_bridge(init)]
        fn new(root: &str) -> KernWorkspace;
        fn refresh(&mut self);
        fn file_count(&self) -> usize;
        fn quick_open(&self, query: &str, limit: usize) -> String;
        fn start_search(&self, query: &str, flags: u8, limit: usize) -> Option<KernSearch>;
    }

    extern "Rust" {
        type KernLsp;

        #[swift_bridge(init)]
        fn new(root: &str) -> KernLsp;
        fn configure(&self, key: &str, command_line: &str);
        fn status(&self, path: &str) -> String;
        fn open(&self, path: &str, text: &str) -> bool;
        fn change(&self, path: &str, text: &str) -> bool;
        fn save(&self, path: &str);
        fn close(&self, path: &str);
        fn diagnostics_version(&self) -> u64;
        fn diagnostics(&self, path: &str) -> String;
        fn all_diagnostics(&self) -> String;
        fn completion(&self, path: &str, line: u32, col: u32, trigger: &str) -> String;
        fn hover(&self, path: &str, line: u32, col: u32) -> String;
        fn signature_help(&self, path: &str, line: u32, col: u32) -> String;
        fn definition(&self, path: &str, line: u32, col: u32) -> String;
        fn references(&self, path: &str, line: u32, col: u32) -> String;
        fn rename(&self, path: &str, line: u32, col: u32, name: &str) -> String;
        fn formatting(&self, path: &str, tab_size: u32, insert_spaces: bool) -> String;
        fn document_symbols(&self, path: &str) -> String;
        fn shutdown(&self);
    }

    extern "Rust" {
        type KernExtensions;

        #[swift_bridge(init)]
        fn new() -> KernExtensions;
        fn load(&mut self, roots: &str);
        fn list(&self) -> String;
        fn errors(&self) -> String;
        fn contributions(&self) -> String;
        fn run_command(&self, ext: &str, command: &str, ctx_json: &str, root: &str) -> String;
        fn inspect(&self, dir: &str) -> String;
    }

    extern "Rust" {
        type KernSearch;

        fn poll(&self) -> String;
        fn is_done(&self) -> bool;
        fn cancel(&self);
        fn total(&self) -> usize;
    }
}

use ffi::KernMotion;

pub struct KernTerminal(kern_term::Terminal);

// env: satır başına ANAHTAR=değer
fn spawn_terminal(cwd: &str, cols: usize, rows: usize, cell_w: u16, cell_h: u16, scrollback: usize, env: &str) -> Option<KernTerminal> {
    let cwd = (!cwd.is_empty()).then(|| cwd.into());
    let env = env.lines().filter_map(|l| l.split_once('=')).map(|(k, v)| (k.to_string(), v.to_string())).collect();
    kern_term::Terminal::spawn_with(cwd, cols, rows, cell_w, cell_h, scrollback, &env).ok().map(KernTerminal)
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

    fn cwd(&self) -> String {
        self.0.cwd().unwrap_or_default()
    }

    fn last_exit(&self) -> i32 {
        self.0.last_exit()
    }

    // [satır, çıkış kodu]*; -1 = çalışıyor
    fn marks(&self) -> Vec<i32> {
        self.0.marks().into_iter().flat_map(|(r, e)| [r as i32, e]).collect()
    }

    fn row_text(&self, row: usize) -> String {
        self.0.row_text(row)
    }

    fn logical_line(&self, row: usize) -> String {
        self.0.logical_line(row).0
    }

    fn logical_offset(&self, row: usize) -> usize {
        self.0.logical_line(row).1
    }

    fn set_light(&self, light: bool) {
        self.0.set_light(light);
    }

    fn background(&self) -> u32 {
        self.0.palette().bg
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

    fn start_search(&self, query: &str, flags: u8, limit: usize) -> Option<KernSearch> {
        self.0.search_stream(query, flags, limit).ok().map(KernSearch)
    }
}

// iş parçacığı güvenli; sonuçlar JSON metni, hata: {"error": "..."}
pub struct KernLsp(kern_lsp::Manager);

fn json_result(r: Result<kern_lsp::serde_json::Value, String>) -> String {
    match r {
        Ok(v) => v.to_string(),
        Err(e) => kern_lsp::serde_json::json!({ "error": e }).to_string(),
    }
}

impl KernLsp {
    fn new(root: &str) -> Self {
        Self(kern_lsp::Manager::new(root))
    }

    fn configure(&self, key: &str, command_line: &str) {
        self.0.set_override(key, command_line);
    }

    fn status(&self, path: &str) -> String {
        self.0.status(std::path::Path::new(path))
    }

    fn open(&self, path: &str, text: &str) -> bool {
        self.0.open(std::path::Path::new(path), text)
    }

    fn change(&self, path: &str, text: &str) -> bool {
        self.0.change(std::path::Path::new(path), text)
    }

    fn save(&self, path: &str) {
        self.0.save(std::path::Path::new(path));
    }

    fn close(&self, path: &str) {
        self.0.close(std::path::Path::new(path));
    }

    fn diagnostics_version(&self) -> u64 {
        self.0.diagnostics_version()
    }

    fn diagnostics(&self, path: &str) -> String {
        self.0.diagnostics(std::path::Path::new(path)).to_string()
    }

    fn all_diagnostics(&self) -> String {
        self.0.all_diagnostics().to_string()
    }

    fn completion(&self, path: &str, line: u32, col: u32, trigger: &str) -> String {
        json_result(self.0.completion(std::path::Path::new(path), line, col, (!trigger.is_empty()).then_some(trigger)))
    }

    fn hover(&self, path: &str, line: u32, col: u32) -> String {
        json_result(self.0.hover(std::path::Path::new(path), line, col))
    }

    fn signature_help(&self, path: &str, line: u32, col: u32) -> String {
        json_result(self.0.signature_help(std::path::Path::new(path), line, col))
    }

    fn definition(&self, path: &str, line: u32, col: u32) -> String {
        json_result(self.0.definition(std::path::Path::new(path), line, col))
    }

    fn references(&self, path: &str, line: u32, col: u32) -> String {
        json_result(self.0.references(std::path::Path::new(path), line, col))
    }

    fn rename(&self, path: &str, line: u32, col: u32, name: &str) -> String {
        json_result(self.0.rename(std::path::Path::new(path), line, col, name))
    }

    fn formatting(&self, path: &str, tab_size: u32, insert_spaces: bool) -> String {
        json_result(self.0.formatting(std::path::Path::new(path), tab_size, insert_spaces))
    }

    fn document_symbols(&self, path: &str) -> String {
        json_result(self.0.document_symbols(std::path::Path::new(path)))
    }

    fn shutdown(&self) {
        self.0.shutdown();
    }
}

pub struct KernExtensions(kern_ext::Registry);

impl KernExtensions {
    fn new() -> Self {
        Self(kern_ext::Registry::new())
    }

    // satır başına bir kök dizin
    fn load(&mut self, roots: &str) {
        let roots: Vec<std::path::PathBuf> = roots.lines().filter(|l| !l.is_empty()).map(Into::into).collect();
        self.0.load(&roots);
    }

    fn list(&self) -> String {
        use kern_lsp::serde_json::json;
        let v: Vec<_> = self
            .0
            .extensions
            .iter()
            .map(|e| json!({ "id": e.id, "name": e.manifest["name"], "version": e.manifest["version"],
                             "description": e.manifest["description"], "permissions": e.permissions, "dir": e.dir }))
            .collect();
        kern_lsp::serde_json::Value::Array(v).to_string()
    }

    fn errors(&self) -> String {
        use kern_lsp::serde_json::json;
        let v: Vec<_> = self.0.errors.iter().map(|(d, e)| json!({ "dir": d, "error": e })).collect();
        kern_lsp::serde_json::Value::Array(v).to_string()
    }

    fn contributions(&self) -> String {
        self.0.contributions().to_string()
    }

    fn run_command(&self, ext: &str, command: &str, ctx_json: &str, root: &str) -> String {
        let ctx = kern_lsp::serde_json::from_str(ctx_json).unwrap_or_default();
        self.0.run_command(ext, command, ctx, std::path::Path::new(root)).to_string()
    }

    // kurmadan önce doğrula: manifest ya da {"error"}
    fn inspect(&self, dir: &str) -> String {
        match self.0.load_one(std::path::Path::new(dir)) {
            Ok(e) => e.manifest.to_string(),
            Err(e) => kern_lsp::serde_json::json!({ "error": e }).to_string(),
        }
    }
}

pub struct KernSearch(kern_search::SearchJob);

impl KernSearch {
    // satır başına: yol \t satır \t sütun16 \t uzunluk16 \t önizleme sütunu \t metin
    fn poll(&self) -> String {
        let mut out = String::new();
        for h in self.0.take() {
            let text = h.text.replace(['\t', '\n', '\r'], " ");
            out.push_str(&format!("{}\t{}\t{}\t{}\t{}\t{}\n", h.path, h.line, h.col16, h.len16, h.preview_col16, text));
        }
        out
    }

    fn is_done(&self) -> bool {
        self.0.is_done()
    }

    fn cancel(&self) {
        self.0.cancel();
    }

    fn total(&self) -> usize {
        self.0.total()
    }
}

fn find_error(query: &str, flags: u8) -> String {
    Editor::find_error(query, flags).unwrap_or_default()
}

fn kern_version() -> String {
    kern_core::VERSION.to_string()
}

fn open_editor(path: &str) -> Option<KernEditor> {
    Document::open(path).ok().map(|d| KernEditor::wrap(Editor::new(d)))
}

// aynı belgeyi paylaşan görünümler; her görünüm kendi seçimini taşır
pub struct KernEditor {
    shared: Rc<RefCell<Editor>>,
    view: u64,
}

impl Drop for KernEditor {
    fn drop(&mut self) {
        if let Ok(mut e) = self.shared.try_borrow_mut() {
            e.remove_view(self.view);
        }
    }
}

impl KernEditor {
    fn wrap(editor: Editor) -> Self {
        let view = editor.active_view();
        Self { shared: Rc::new(RefCell::new(editor)), view }
    }

    fn e(&self) -> RefMut<'_, Editor> {
        let mut e = self.shared.borrow_mut();
        e.activate_view(self.view);
        e
    }

    fn new() -> Self {
        Self::wrap(Editor::new(Document::default()))
    }

    fn split_view(&self) -> KernEditor {
        let view = self.e().add_view();
        KernEditor { shared: self.shared.clone(), view }
    }

    fn line_count(&self) -> usize {
        self.e().doc.buffer.len_lines()
    }

    fn line(&self, index: usize) -> String {
        let e = self.e();
        if index < e.doc.buffer.len_lines() { e.doc.buffer.line_prefix(index, MAX_LINE_CHARS) } else { String::new() }
    }

    fn cursor_line(&self) -> usize {
        let mut g = self.e();
        let e = &mut *g;
        e.doc.buffer.char_to_utf16(e.selection().head).0
    }

    fn cursor_col(&self) -> usize {
        let mut g = self.e();
        let e = &mut *g;
        e.doc.buffer.char_to_utf16(e.selection().head).1
    }

    fn anchor_line(&self) -> usize {
        let mut g = self.e();
        let e = &mut *g;
        e.doc.buffer.char_to_utf16(e.selection().anchor).0
    }

    fn anchor_col(&self) -> usize {
        let mut g = self.e();
        let e = &mut *g;
        e.doc.buffer.char_to_utf16(e.selection().anchor).1
    }

    fn has_selection(&self) -> bool {
        let mut g = self.e();
        let e = &mut *g;
        !e.selection().is_empty()
    }

    fn selected_text(&self) -> String {
        let mut g = self.e();
        let e = &mut *g;
        e.selected_text()
    }

    fn move_cursor(&mut self, motion: KernMotion, extend: bool) {
        let mut g = self.e();
        let e = &mut *g;
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
        e.move_cursor(m, extend);
    }

    fn set_page_lines(&mut self, lines: usize) {
        let mut g = self.e();
        let e = &mut *g;
        e.set_page_lines(lines);
    }

    fn click(&mut self, line: usize, col: usize, extend: bool) {
        let mut g = self.e();
        let e = &mut *g;
        e.click(line, col, extend);
    }

    fn select_word(&mut self, line: usize, col: usize) {
        let mut g = self.e();
        let e = &mut *g;
        e.select_word(line, col);
    }

    fn select_line(&mut self, line: usize) {
        let mut g = self.e();
        let e = &mut *g;
        e.select_line(line);
    }

    fn select_all(&mut self) {
        let mut g = self.e();
        let e = &mut *g;
        e.select_all();
    }

    fn collapse_selection(&mut self) {
        let mut g = self.e();
        let e = &mut *g;
        e.collapse_selection();
    }

    fn insert_text(&mut self, text: &str) {
        let mut g = self.e();
        let e = &mut *g;
        e.insert_text(text);
    }

    fn insert_newline(&mut self) {
        let mut g = self.e();
        let e = &mut *g;
        e.insert_newline();
    }

    fn insert_tab(&mut self) {
        let mut g = self.e();
        let e = &mut *g;
        e.insert_tab();
    }

    fn delete_backward(&mut self) {
        let mut g = self.e();
        let e = &mut *g;
        e.delete_backward();
    }

    fn delete_forward(&mut self) {
        let mut g = self.e();
        let e = &mut *g;
        e.delete_forward();
    }

    fn delete_word_backward(&mut self) {
        let mut g = self.e();
        let e = &mut *g;
        e.delete_word_backward();
    }

    fn delete_word_forward(&mut self) {
        let mut g = self.e();
        let e = &mut *g;
        e.delete_word_forward();
    }

    fn delete_to_line_start(&mut self) {
        let mut g = self.e();
        let e = &mut *g;
        e.delete_to_line_start();
    }

    fn undo(&mut self) -> bool {
        let mut g = self.e();
        let e = &mut *g;
        e.undo()
    }

    fn redo(&mut self) -> bool {
        let mut g = self.e();
        let e = &mut *g;
        e.redo()
    }

    fn is_dirty(&self) -> bool {
        let mut g = self.e();
        let e = &mut *g;
        e.is_dirty()
    }

    fn path(&self) -> String {
        let mut g = self.e();
        let e = &mut *g;
        e.doc.path.as_ref().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default()
    }

    // boş = başarılı, aksi halde hata mesajı
    fn save(&mut self) -> String {
        let mut g = self.e();
        let e = &mut *g;
        e.save().err().map(|e| e.to_string()).unwrap_or_default()
    }

    fn save_as(&mut self, path: &str) -> String {
        let mut g = self.e();
        let e = &mut *g;
        e.save_as(path).err().map(|e| e.to_string()).unwrap_or_default()
    }

    fn encoding_name(&self) -> String {
        let mut g = self.e();
        let e = &mut *g;
        e.doc.encoding.name().to_string()
    }

    fn reload(&mut self) -> bool {
        let mut g = self.e();
        let e = &mut *g;
        e.reload().is_ok()
    }

    fn disk_changed(&self) -> bool {
        let mut g = self.e();
        let e = &mut *g;
        e.doc.disk_changed()
    }

    fn wrap_rows(&self, cols: usize) -> Vec<u32> {
        kern_core::display::wrap_rows(&self.e().doc.buffer, cols)
    }

    fn wrap_breaks(&self, line: usize, cols: usize) -> Vec<u32> {
        let e = self.e();
        if line >= e.doc.buffer.len_lines() {
            return Vec::new();
        }
        kern_core::display::wrap_breaks(&e.doc.buffer.line(line), cols).into_iter().map(|c| c as u32).collect()
    }

    // [başlangıç, son]*
    fn fold_ranges(&self) -> Vec<u32> {
        kern_core::display::fold_ranges(&self.e().doc.buffer).into_iter().flat_map(|(a, b)| [a as u32, b as u32]).collect()
    }

    fn text(&self) -> String {
        self.e().doc.buffer.rope().to_string()
    }

    // LSP TextEdit dizisi (JSON)
    fn apply_edits(&mut self, json: &str) -> bool {
        let Ok(v) = kern_lsp::serde_json::from_str::<kern_lsp::serde_json::Value>(json) else { return false };
        let n = |v: &kern_lsp::serde_json::Value, p: &str| v.pointer(p).and_then(|x| x.as_u64()).unwrap_or(0) as usize;
        let edits: Vec<(usize, usize, usize, usize, String)> = v
            .as_array()
            .into_iter()
            .flatten()
            .map(|e| {
                let t = e.get("newText").and_then(|t| t.as_str()).unwrap_or("").to_string();
                (n(e, "/range/start/line"), n(e, "/range/start/character"), n(e, "/range/end/line"), n(e, "/range/end/character"), t)
            })
            .collect();
        if edits.is_empty() {
            return false;
        }
        self.e().apply_text_edits(&edits);
        true
    }

    fn prepare_save(&mut self, trim: bool, final_newline: bool) {
        self.e().prepare_save(trim, final_newline);
    }

    fn set_indent(&mut self, tab_width: usize, insert_spaces: bool, detect: bool) {
        let mut e = self.e();
        e.tab_width = tab_width.clamp(1, 16);
        e.insert_spaces = insert_spaces;
        if detect {
            e.detect_indent();
        }
    }

    fn tab_width(&self) -> usize {
        self.e().tab_width
    }

    fn insert_spaces(&self) -> bool {
        self.e().insert_spaces
    }

    fn version(&self) -> u64 {
        self.e().doc.buffer.version()
    }

    fn byte_len(&self) -> usize {
        self.e().doc.buffer.len_bytes()
    }

    fn disk_missing(&self) -> bool {
        let mut g = self.e();
        let e = &mut *g;
        e.doc.disk_missing()
    }

    fn type_text(&mut self, text: &str) {
        let mut g = self.e();
        let e = &mut *g;
        e.type_text(text);
    }

    fn language(&self) -> String {
        let mut g = self.e();
        let e = &mut *g;
        e.language().to_string()
    }

    fn line_ending_name(&self) -> String {
        let mut g = self.e();
        let e = &mut *g;
        e.line_ending_name().to_string()
    }

    fn highlights(&mut self, first: usize, last: usize) -> Vec<u32> {
        let mut g = self.e();
        let e = &mut *g;
        e.highlights(first, last)
    }

    fn matching_bracket(&self) -> Vec<u32> {
        let mut g = self.e();
        let e = &mut *g;
        let b = &e.doc.buffer;
        match e.matching_bracket() {
            Some((a, z)) => {
                let (l1, c1) = b.char_to_utf16(a);
                let (l2, c2) = b.char_to_utf16(z);
                vec![l1 as u32, c1 as u32, l2 as u32, c2 as u32]
            }
            None => Vec::new(),
        }
    }

    fn toggle_comment(&mut self) {
        let mut g = self.e();
        let e = &mut *g;
        e.toggle_comment();
    }

    fn indent_lines(&mut self, indent: bool) {
        let mut g = self.e();
        let e = &mut *g;
        e.indent_lines(indent);
    }

    fn move_lines(&mut self, up: bool) {
        let mut g = self.e();
        let e = &mut *g;
        e.move_lines(up);
    }

    fn duplicate_lines(&mut self, down: bool) {
        let mut g = self.e();
        let e = &mut *g;
        e.duplicate_lines(down);
    }

    fn delete_lines(&mut self) {
        let mut g = self.e();
        let e = &mut *g;
        e.delete_lines();
    }

    // [çapa satırı, çapa sütunu, baş satırı, baş sütunu]* (UTF-16)
    fn selections(&self) -> Vec<u32> {
        let mut g = self.e();
        let e = &mut *g;
        let b = &e.doc.buffer;
        let mut out = Vec::new();
        for s in e.selections() {
            let (al, ac) = b.char_to_utf16(s.anchor);
            let (hl, hc) = b.char_to_utf16(s.head);
            out.extend([al as u32, ac as u32, hl as u32, hc as u32]);
        }
        out
    }

    fn add_cursor(&mut self, line: usize, col: usize) {
        let mut g = self.e();
        let e = &mut *g;
        e.add_cursor(line, col);
    }

    fn add_cursor_vertical(&mut self, up: bool) {
        let mut g = self.e();
        let e = &mut *g;
        e.add_cursor_vertical(up);
    }

    fn add_next_occurrence(&mut self) {
        let mut g = self.e();
        let e = &mut *g;
        e.add_next_occurrence();
    }

    fn select_all_occurrences(&mut self) {
        let mut g = self.e();
        let e = &mut *g;
        e.select_all_occurrences();
    }

    fn select_range(&mut self, line: usize, col: usize, len: usize) {
        let mut g = self.e();
        let e = &mut *g;
        e.click(line, col, false);
        e.click(line, col + len, true);
    }

    fn find_next(&mut self, query: &str, flags: u8, forward: bool) -> bool {
        let mut g = self.e();
        let e = &mut *g;
        e.find_next(query, flags, forward)
    }

    fn find_in_lines(&self, query: &str, flags: u8, first: usize, last: usize) -> Vec<u32> {
        let mut g = self.e();
        let e = &mut *g;
        e.find_in_lines(query, flags, first, last)
    }

    fn find_status(&self, query: &str, flags: u8) -> Vec<u32> {
        let mut g = self.e();
        let e = &mut *g;
        let (total, current) = e.find_status(query, flags);
        vec![total as u32, current as u32]
    }

    fn replace_one(&mut self, query: &str, replacement: &str, flags: u8) {
        let mut g = self.e();
        let e = &mut *g;
        e.replace_one(query, replacement, flags);
    }

    fn replace_all(&mut self, query: &str, replacement: &str, flags: u8) -> usize {
        let mut g = self.e();
        let e = &mut *g;
        e.replace_all(query, replacement, flags)
    }
}
