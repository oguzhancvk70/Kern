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
        fn vcs_conflicts(text: &str) -> String;
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
        fn syntax_pending(&self) -> bool;
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

        fn spawn_terminal(
            cwd: &str,
            cols: usize,
            rows: usize,
            cell_w: u16,
            cell_h: u16,
            scrollback: usize,
            env: &str,
        ) -> Option<KernTerminal>;
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
        type KernRepo;

        fn discover_repo(path: &str) -> Option<KernRepo>;
        fn root(&self) -> String;
        fn branch(&self) -> String;
        fn branches(&self) -> String;
        fn status(&self) -> String;
        fn stage(&self, paths: &str) -> String;
        fn unstage(&self, paths: &str) -> String;
        fn discard(&self, paths: &str) -> String;
        fn commit(&self, message: &str, all: bool) -> String;
        fn checkout(&self, branch: &str, create: bool) -> String;
        fn push(&self) -> String;
        fn pull(&self) -> String;
        fn blame(&self, path: &str, line: usize, contents: &str) -> String;
        fn line_changes(&self, path: &str, current: &str) -> String;
    }

    extern "Rust" {
        type KernDebug;

        fn debug_configs(root: &str) -> String;
        fn debug_suggest(path: &str) -> String;
        fn debug_adapter_status(kind: &str) -> String;
        fn debug_last_error() -> String;
        fn debug_start(root: &str, config_json: &str, breakpoints_json: &str) -> Option<KernDebug>;
        fn version(&self) -> u64;
        fn is_alive(&self) -> bool;
        fn status(&self) -> String;
        fn output(&self) -> String;
        fn set_breakpoints(&self, path: &str, lines: &str) -> String;
        fn breakpoints(&self, path: &str) -> String;
        fn threads(&self) -> String;
        fn stack_trace(&self, thread: i64) -> String;
        fn scopes(&self, frame: i64) -> String;
        fn variables(&self, reference: i64) -> String;
        fn evaluate(&self, expr: &str, frame: i64, context: &str) -> String;
        fn set_variable(&self, reference: i64, name: &str, value: &str) -> String;
        fn select_frame(&self, frame: i64);
        fn resume(&self, command: &str) -> String;
        fn pause(&self) -> String;
        fn terminate(&self);
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

// hata ayıklama oturumu; JSON metni, hata: {"error": "..."}
pub struct KernDebug(kern_dap::Session);

static DEBUG_ERROR: std::sync::Mutex<String> = std::sync::Mutex::new(String::new());

fn debug_configs(root: &str) -> String {
    kern_dap::load_configs(std::path::Path::new(root)).to_string()
}

fn debug_suggest(path: &str) -> String {
    kern_dap::suggest_config(std::path::Path::new(path)).unwrap_or(kern_lsp::serde_json::Value::Null).to_string()
}

fn debug_adapter_status(kind: &str) -> String {
    kern_dap::adapter_status(kind)
}

fn debug_last_error() -> String {
    DEBUG_ERROR.lock().unwrap().clone()
}

// config_json: launch.json girdisi, breakpoints_json: {yol: [satırlar]}
fn debug_start(root: &str, config_json: &str, breakpoints_json: &str) -> Option<KernDebug> {
    use kern_lsp::serde_json::{Value, from_str};
    let config: Value = from_str(config_json).unwrap_or(Value::Null);
    let bps: Value = from_str(breakpoints_json).unwrap_or(Value::Null);
    match kern_dap::Session::start(std::path::Path::new(root), &config, &bps) {
        Ok(s) => {
            DEBUG_ERROR.lock().unwrap().clear();
            Some(KernDebug(s))
        }
        Err(e) => {
            *DEBUG_ERROR.lock().unwrap() = e;
            None
        }
    }
}

impl KernDebug {
    fn version(&self) -> u64 {
        self.0.version()
    }

    fn is_alive(&self) -> bool {
        self.0.is_alive()
    }

    fn status(&self) -> String {
        self.0.status().to_string()
    }

    fn output(&self) -> String {
        self.0.take_output().to_string()
    }

    // lines: virgülle ayrılmış 1 tabanlı satırlar
    fn set_breakpoints(&self, path: &str, lines: &str) -> String {
        let lines: Vec<u32> = lines.split(',').filter_map(|l| l.trim().parse().ok()).collect();
        self.0.set_breakpoints(path, &lines).to_string()
    }

    fn breakpoints(&self, path: &str) -> String {
        self.0.breakpoints(path).to_string()
    }

    fn threads(&self) -> String {
        json_result(self.0.threads())
    }

    fn stack_trace(&self, thread: i64) -> String {
        json_result(self.0.stack_trace(thread))
    }

    fn scopes(&self, frame: i64) -> String {
        json_result(self.0.scopes(frame))
    }

    fn variables(&self, reference: i64) -> String {
        json_result(self.0.variables(reference))
    }

    fn evaluate(&self, expr: &str, frame: i64, context: &str) -> String {
        json_result(self.0.evaluate(expr, (frame >= 0).then_some(frame), context))
    }

    fn set_variable(&self, reference: i64, name: &str, value: &str) -> String {
        json_result(self.0.set_variable(reference, name, value))
    }

    fn select_frame(&self, frame: i64) {
        self.0.select_frame(frame);
    }

    fn resume(&self, command: &str) -> String {
        json_result(self.0.resume_all(command))
    }

    fn pause(&self) -> String {
        json_result(self.0.pause())
    }

    fn terminate(&self) {
        self.0.terminate();
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
            .map(|e| {
                json!({ "id": e.id, "name": e.manifest["name"], "version": e.manifest["version"],
                             "description": e.manifest["description"], "permissions": e.permissions, "dir": e.dir })
            })
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

// git; komutlar JSON döner: {"ok": çıktı} ya da {"error": mesaj}. Yavaş olabilir → arka plan thread'i
pub struct KernRepo(kern_vcs::Repo);

fn discover_repo(path: &str) -> Option<KernRepo> {
    kern_vcs::Repo::discover(std::path::Path::new(path)).map(KernRepo)
}

fn vcs_result(r: Result<String, String>) -> String {
    use kern_lsp::serde_json::json;
    match r {
        Ok(s) => json!({ "ok": s }).to_string(),
        Err(e) => json!({ "error": e }).to_string(),
    }
}

// satır başına: satır \t adet \t tür
fn format_changes(changes: &[kern_vcs::LineChange]) -> String {
    changes.iter().map(|(l, n, k)| format!("{l}\t{n}\t{k}\n")).collect()
}

// satır başına: başlangıç \t orta \t bitiş
fn vcs_conflicts(text: &str) -> String {
    kern_vcs::conflicts(text).iter().map(|(s, m, e)| format!("{s}\t{m}\t{e}\n")).collect()
}

impl KernRepo {
    fn paths(list: &str) -> Vec<&str> {
        list.lines().filter(|l| !l.is_empty()).collect()
    }

    fn root(&self) -> String {
        self.0.root.to_string_lossy().into_owned()
    }

    fn branch(&self) -> String {
        self.0.branch()
    }

    // satır başına bir dal
    fn branches(&self) -> String {
        self.0.branches().map(|b| b.join("\n")).unwrap_or_default()
    }

    // satır başına: X Y \t yol (göreli)
    fn status(&self) -> String {
        match self.0.status() {
            Ok(items) => items.iter().map(|f| format!("{}{}\t{}\n", f.index, f.worktree, f.path)).collect(),
            Err(_) => String::new(),
        }
    }

    fn stage(&self, paths: &str) -> String {
        vcs_result(self.0.stage(&Self::paths(paths)).map(|_| String::new()))
    }

    fn unstage(&self, paths: &str) -> String {
        vcs_result(self.0.unstage(&Self::paths(paths)).map(|_| String::new()))
    }

    fn discard(&self, paths: &str) -> String {
        vcs_result(self.0.discard(&Self::paths(paths)).map(|_| String::new()))
    }

    fn commit(&self, message: &str, all: bool) -> String {
        vcs_result(self.0.commit(message, all))
    }

    fn checkout(&self, branch: &str, create: bool) -> String {
        vcs_result(self.0.checkout(branch, create))
    }

    fn push(&self) -> String {
        vcs_result(self.0.push())
    }

    fn pull(&self) -> String {
        vcs_result(self.0.pull())
    }

    // "yazar \t unix zamanı \t özet"; contents boşsa diskteki dosya
    fn blame(&self, path: &str, line: usize, contents: &str) -> String {
        let c = if contents.is_empty() { None } else { Some(contents) };
        self.0.blame_line(std::path::Path::new(path), line, c).unwrap_or_default()
    }

    // HEAD'e göre; izlenmeyen dosyada tümü eklenmiş sayılır
    fn line_changes(&self, path: &str, current: &str) -> String {
        let base = self.0.head_text(std::path::Path::new(path)).unwrap_or_default();
        format_changes(&kern_vcs::line_changes(&base, current))
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

    // büyük dosyada ilk renklendirme arka planda; Swift buna bakıp yeniden çizer
    fn syntax_pending(&self) -> bool {
        self.e().syntax_pending()
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

// FFI sınırı: Swift'in bağlı olduğu dönüş biçimleri
#[cfg(test)]
mod tests {
    use super::*;
    use kern_lsp::serde_json::Value;

    fn tmp(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("kern-ffi-{}-{}", std::process::id(), name));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn editor_roundtrip() {
        let dir = tmp("editor");
        let path = dir.join("a.rs");
        std::fs::write(&path, "fn main() {}\n").unwrap();
        let mut e = open_editor(path.to_str().unwrap()).expect("editör");
        assert_eq!(e.line_count(), 2);
        assert_eq!(e.language(), "Rust");
        assert_eq!(e.line_ending_name(), "LF");
        assert_eq!(e.encoding_name(), "UTF-8");
        assert!(!e.is_dirty());
        e.select_range(0, 3, 4);
        assert_eq!(e.selected_text(), "main");
        e.insert_text("start");
        assert!(e.is_dirty());
        assert_eq!(e.line(0), "fn start() {}");
        // renklendirme: [satır, başlangıç, bitiş, tür] dörtlüleri
        let spans = e.highlights(0, 0);
        assert_eq!(spans.len() % 4, 0);
        assert!(!spans.is_empty());
        assert!(e.undo());
        assert_eq!(e.line(0), "fn main() {}");
        // LSP biçimli düzenleme
        let edit = r#"[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":2}},"newText":"pub fn"}]"#;
        assert!(e.apply_edits(edit));
        assert_eq!(e.line(0), "pub fn main() {}");
        assert_eq!(e.save(), "");
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "pub fn main() {}\n");
        assert!(!e.is_dirty());
        // bölünmüş görünüm aynı belgeyi paylaşır, imleci ayrıdır
        e.collapse_selection();
        let mut split = e.split_view();
        split.select_range(0, 0, 3);
        assert_eq!(split.selected_text(), "pub");
        assert!(!e.has_selection());
        split.insert_text("PUB");
        assert_eq!(e.line(0), "PUB fn main() {}");
        assert_eq!(e.version(), split.version());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn editor_errors_and_search() {
        assert!(open_editor("/kern/yok/dosya.txt").is_none());
        assert!(!find_error("(", 4).is_empty(), "geçersiz regex hata vermeli");
        assert!(find_error("(", 0).is_empty(), "düz metin hatasız");
        let mut e = KernEditor::new();
        e.insert_text("bir\niki\nbir\n");
        assert_eq!(e.find_status("bir", 0), vec![2, 0]);
        assert_eq!(e.replace_all("bir", "üç", 0), 2);
        assert_eq!(e.text(), "üç\niki\nüç\n");
        assert_eq!(e.find_in_lines("iki", 0, 0, 2), vec![1, 0, 3]);
        assert!(!kern_version().is_empty());
    }

    #[test]
    fn workspace_and_stream_search() {
        let dir = tmp("ws");
        std::fs::create_dir_all(dir.join("src")).unwrap();
        std::fs::write(dir.join("src/main.rs"), "let needle = 1;\n").unwrap();
        std::fs::write(dir.join("README.md"), "no match here\n").unwrap();
        let ws = KernWorkspace::new(dir.to_str().unwrap());
        assert_eq!(ws.file_count(), 2);
        assert_eq!(ws.quick_open("mainrs", 10), "src/main.rs");
        let job = ws.start_search("needle", 0, 100).expect("arama");
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        let mut hits = String::new();
        while !job.is_done() || !hits.contains("needle") {
            hits.push_str(&job.poll());
            assert!(std::time::Instant::now() < deadline, "arama bitmedi: {hits}");
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        let fields: Vec<&str> = hits.trim_end().split('\t').collect();
        assert_eq!(fields[0], "src/main.rs");
        assert_eq!(fields[1], "0");
        assert_eq!(fields[2], "4");
        assert_eq!(job.total(), 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn repo_json_contract() {
        let dir = tmp("repo");
        let run = |args: &[&str]| {
            std::process::Command::new("git").args(args).current_dir(&dir).output().unwrap();
        };
        run(&["init", "-q", "-b", "main"]);
        run(&["config", "user.email", "t@example.com"]);
        run(&["config", "user.name", "Tester"]);
        std::fs::write(dir.join("a.txt"), "one\n").unwrap();
        let repo = discover_repo(dir.to_str().unwrap()).expect("depo");
        assert_eq!(repo.status(), "??\ta.txt\n");
        let ok = |raw: String| -> bool {
            let v: Value = kern_lsp::serde_json::from_str(&raw).unwrap();
            v.get("ok").is_some() && v.get("error").is_none()
        };
        assert!(ok(repo.stage("a.txt")));
        assert_eq!(repo.status(), "A \ta.txt\n");
        assert!(ok(repo.commit("first", false)));
        assert_eq!(repo.status(), "");
        assert_eq!(repo.branch(), "main");
        // hata da JSON: {"error": "..."}
        let bad: Value = kern_lsp::serde_json::from_str(&repo.checkout("main", true)).unwrap();
        assert!(bad.get("error").is_some(), "var olan dalı oluşturmak hata vermeli");
        std::fs::write(dir.join("a.txt"), "one\ntwo\n").unwrap();
        let changes = repo.line_changes("a.txt", "one\ntwo\n");
        assert_eq!(changes.trim_end(), "1\t1\tA");
        assert!(repo.blame("a.txt", 1, "one\ntwo\n").contains("Uncommitted"));
        assert_eq!(vcs_conflicts("a\n<<<<<<< HEAD\nb\n=======\nc\n>>>>>>> x\n").trim_end(), "1\t3\t5");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn debug_contract() {
        let dir = tmp("dap");
        std::fs::create_dir_all(dir.join(".kern")).unwrap();
        std::fs::write(
            dir.join(".kern/launch.json"),
            "{\"configurations\":[{\"type\":\"lldb\",\"name\":\"app\",\"program\":\"/bin/ls\"}]}",
        )
        .unwrap();
        let configs: Value = kern_lsp::serde_json::from_str(&debug_configs(dir.to_str().unwrap())).unwrap();
        assert_eq!(configs[0]["name"], "app");
        let suggest: Value = kern_lsp::serde_json::from_str(&debug_suggest("/x/a.py")).unwrap();
        assert_eq!(suggest["type"], "python");
        assert_eq!(debug_suggest("/x/a.txt"), "null");
        assert!(debug_adapter_status("ruby").starts_with("unsupported"));
        // desteklenmeyen tür: oturum yok, hata saklanır
        let bad = debug_start(dir.to_str().unwrap(), "{\"type\":\"ruby\",\"request\":\"launch\"}", "{}");
        assert!(bad.is_none());
        assert!(debug_last_error().contains("ruby"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn terminal_contract() {
        let Some(mut term) = spawn_terminal("/tmp", 40, 8, 8, 16, 200, "KERN_TEST=1") else {
            return;
        };
        term.write_text("printf 'hello-ffi\\n'\n");
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        loop {
            let _ = term.take_dirty();
            let screen: String = (0..8).map(|r| term.row_text(r)).collect::<Vec<_>>().join("\n");
            if screen.contains("hello-ffi") {
                break;
            }
            assert!(std::time::Instant::now() < deadline, "terminal çıktısı gelmedi: {screen}");
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        assert!(term.is_alive());
        term.resize(60, 10, 8, 16);
        // anlık görüntü: hücre başına (kod, renk) çiftleri
        assert!(!term.snapshot().is_empty());
    }
}
