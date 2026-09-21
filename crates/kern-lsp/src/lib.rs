// LSP istemcisi: dil başına bir sunucu süreci, stdio üzerinden JSON-RPC
use std::collections::HashMap;
use std::io::{self, BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU64, Ordering};
use std::sync::mpsc::{Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Value, json};

pub use serde_json;

// dosya uzantısı → (LSP languageId, sunucu anahtarı)
pub fn language_id(path: &Path) -> Option<(&'static str, &'static str)> {
    let ext = path.extension()?.to_str()?.to_ascii_lowercase();
    Some(match ext.as_str() {
        "rs" => ("rust", "rust"),
        "c" | "h" => ("c", "c"),
        "cc" | "cpp" | "cxx" | "hpp" | "hh" | "hxx" => ("cpp", "c"),
        "m" => ("objective-c", "c"),
        "mm" => ("objective-cpp", "c"),
        "swift" => ("swift", "swift"),
        "py" | "pyi" => ("python", "python"),
        "ts" | "mts" | "cts" => ("typescript", "typescript"),
        "tsx" => ("typescriptreact", "typescript"),
        "js" | "mjs" | "cjs" => ("javascript", "typescript"),
        "jsx" => ("javascriptreact", "typescript"),
        "go" => ("go", "go"),
        "java" => ("java", "java"),
        "lua" => ("lua", "lua"),
        "sh" | "bash" | "zsh" => ("shellscript", "shell"),
        _ => return None,
    })
}

pub struct ServerSpec {
    pub command: String,
    pub args: Vec<String>,
    pub install: &'static str,
}

// varsayılan sunucular; ilk bulunan kullanılır
pub fn default_servers(key: &str) -> Vec<ServerSpec> {
    let s = |c: &str, a: &[&str], i: &'static str| ServerSpec {
        command: c.into(),
        args: a.iter().map(|x| x.to_string()).collect(),
        install: i,
    };
    match key {
        "rust" => vec![s("rust-analyzer", &[], "rustup component add rust-analyzer")],
        "c" => vec![s("clangd", &[], "xcode-select --install")],
        "swift" => vec![s("sourcekit-lsp", &[], "xcode-select --install")],
        "python" => {
            vec![s("pyright-langserver", &["--stdio"], "npm install -g pyright"), s("pylsp", &[], "pip3 install python-lsp-server")]
        }
        "typescript" => vec![s("typescript-language-server", &["--stdio"], "npm install -g typescript-language-server typescript")],
        "go" => vec![s("gopls", &[], "go install golang.org/x/tools/gopls@latest")],
        "java" => vec![s("jdtls", &[], "brew install jdtls")],
        "lua" => vec![s("lua-language-server", &[], "brew install lua-language-server")],
        "shell" => vec![s("bash-language-server", &["start"], "npm install -g bash-language-server")],
        _ => Vec::new(),
    }
}

// PATH + yaygın konumlarda çalıştırılabilir dosya ara
pub fn which(cmd: &str) -> Option<PathBuf> {
    if cmd.contains('/') {
        return Path::new(cmd).is_file().then(|| PathBuf::from(cmd));
    }
    let mut dirs: Vec<PathBuf> = std::env::var_os("PATH").map(|p| std::env::split_paths(&p).collect()).unwrap_or_default();
    if let Some(home) = std::env::var_os("HOME") {
        let home = PathBuf::from(home);
        dirs.extend(["go/bin", ".cargo/bin", ".local/bin", ".npm-global/bin"].map(|d| home.join(d)));
    }
    dirs.extend(["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].map(PathBuf::from));
    dirs.into_iter().map(|d| d.join(cmd)).find(|p| p.is_file())
}

pub fn path_to_uri(path: &Path) -> String {
    let mut out = String::from("file://");
    for b in path.to_string_lossy().bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' | b'/' => out.push(b as char),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

pub fn uri_to_path(uri: &str) -> Option<PathBuf> {
    let rest = uri.strip_prefix("file://")?;
    let b = rest.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let Ok(v) = u8::from_str_radix(std::str::from_utf8(&b[i + 1..i + 3]).ok()?, 16) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    Some(PathBuf::from(String::from_utf8_lossy(&out).into_owned()))
}

struct Inner {
    stdin: Mutex<ChildStdin>,
    child: Mutex<Child>,
    next_id: AtomicI64,
    pending: Mutex<HashMap<i64, Sender<Result<Value, String>>>>,
    diagnostics: Mutex<HashMap<String, Value>>,
    diag_version: Arc<AtomicU64>,
    capabilities: Mutex<Value>,
    alive: AtomicBool,
    log: Mutex<Vec<String>>,
    applied: Mutex<Vec<Value>>,
}

// LSP semantic token türü → kern-syntax token kodu
fn semantic_kind(name: &str) -> u8 {
    match name {
        "namespace" | "module" => 16,
        "type" | "class" | "struct" | "interface" | "enum" | "typeParameter" | "builtinType" => 6,
        "parameter" | "variable" | "typeAlias" | "selfKeyword" => 7,
        "property" | "enumMember" | "field" => 10,
        "function" | "method" | "macro" | "event" => 5,
        "keyword" | "modifier" => 1,
        "comment" => 4,
        "string" | "regexp" => 3,
        "number" => 8,
        "operator" | "arithmetic" | "bitwise" | "comparison" | "logical" => 11,
        "decorator" | "attribute" | "attributeBracket" | "lifetime" => 13,
        _ => 0,
    }
}

// {changes} ve {documentChanges} → {uri: [TextEdit]}
fn edit_changes(v: &Value) -> serde_json::Map<String, Value> {
    let mut out = serde_json::Map::new();
    if let Some(changes) = v.get("changes").and_then(Value::as_object) {
        out.extend(changes.clone());
    }
    for dc in v.get("documentChanges").and_then(Value::as_array).into_iter().flatten() {
        if let (Some(uri), Some(edits)) = (dc.pointer("/textDocument/uri").and_then(Value::as_str), dc.get("edits")) {
            out.insert(uri.to_string(), edits.clone());
        }
    }
    out
}

fn has_cap(caps: &Value, key: &str) -> bool {
    matches!(caps.get(key), Some(v) if !v.is_null() && *v != Value::Bool(false))
}

#[derive(Clone)]
pub struct Client(Arc<Inner>);

fn write_message(w: &mut impl Write, v: &Value) -> io::Result<()> {
    let body = v.to_string();
    write!(w, "Content-Length: {}\r\n\r\n{}", body.len(), body)?;
    w.flush()
}

fn read_message(r: &mut impl BufRead) -> io::Result<Option<Value>> {
    let mut len = None;
    loop {
        let mut line = String::new();
        if r.read_line(&mut line)? == 0 {
            return Ok(None);
        }
        let line = line.trim_end();
        if line.is_empty() {
            break;
        }
        if let Some(v) = line.strip_prefix("Content-Length:") {
            len = v.trim().parse::<usize>().ok();
        }
    }
    let Some(len) = len else { return Ok(Some(Value::Null)) };
    let mut buf = vec![0; len];
    r.read_exact(&mut buf)?;
    Ok(Some(serde_json::from_slice(&buf).unwrap_or(Value::Null)))
}

impl Client {
    pub fn start(command: &Path, args: &[String], root: &Path, diag_version: Arc<AtomicU64>) -> Result<Client, String> {
        let mut child = Command::new(command)
            .args(args)
            .current_dir(root)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| format!("{}: {e}", command.display()))?;
        let stdin = child.stdin.take().ok_or("stdin yok")?;
        let stdout = child.stdout.take().ok_or("stdout yok")?;
        let inner = Arc::new(Inner {
            stdin: Mutex::new(stdin),
            child: Mutex::new(child),
            next_id: AtomicI64::new(1),
            pending: Mutex::new(HashMap::new()),
            diagnostics: Mutex::new(HashMap::new()),
            diag_version,
            capabilities: Mutex::new(Value::Null),
            alive: AtomicBool::new(true),
            log: Mutex::new(Vec::new()),
            applied: Mutex::new(Vec::new()),
        });
        let reader_inner = inner.clone();
        std::thread::spawn(move || {
            let mut r = BufReader::new(stdout);
            while let Ok(Some(msg)) = read_message(&mut r) {
                Client(reader_inner.clone()).dispatch(msg);
            }
            reader_inner.alive.store(false, Ordering::Relaxed);
            for (_, tx) in reader_inner.pending.lock().unwrap().drain() {
                let _ = tx.send(Err("server exited".into()));
            }
        });
        let client = Client(inner);
        let root_uri = path_to_uri(root);
        let name = root.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let init = client.request(
            "initialize",
            json!({
                "processId": std::process::id(),
                "rootUri": root_uri,
                "rootPath": root.to_string_lossy(),
                "workspaceFolders": [{ "uri": root_uri, "name": name }],
                "clientInfo": { "name": "Kern", "version": env!("CARGO_PKG_VERSION") },
                "capabilities": {
                    "general": { "positionEncodings": ["utf-16"] },
                    "workspace": {
                        "workspaceFolders": true,
                        "configuration": true,
                        "applyEdit": true,
                        "executeCommand": { "dynamicRegistration": false },
                        "symbol": { "dynamicRegistration": false }
                    },
                    "textDocument": {
                        "synchronization": { "didSave": true, "dynamicRegistration": false },
                        "completion": {
                            "completionItem": { "snippetSupport": false, "documentationFormat": ["plaintext", "markdown"] },
                            "contextSupport": true
                        },
                        "hover": { "contentFormat": ["plaintext", "markdown"] },
                        "signatureHelp": { "signatureInformation": { "documentationFormat": ["plaintext"] } },
                        "definition": { "linkSupport": false },
                        "references": {},
                        "rename": { "prepareSupport": false },
                        "formatting": {},
                        "documentSymbol": { "hierarchicalDocumentSymbolSupport": true },
                        "publishDiagnostics": { "relatedInformation": false },
                        "codeAction": {
                            "dataSupport": true,
                            "resolveSupport": { "properties": ["edit"] },
                            "codeActionLiteralSupport": {
                                "codeActionKind": {
                                    "valueSet": ["", "quickfix", "refactor", "refactor.extract", "refactor.inline",
                                                 "refactor.rewrite", "source", "source.organizeImports", "source.fixAll"]
                                }
                            }
                        },
                        "semanticTokens": {
                            "requests": { "full": true, "range": false },
                            "tokenTypes": ["namespace", "type", "class", "enum", "interface", "struct", "typeParameter",
                                           "parameter", "variable", "property", "enumMember", "event", "function", "method",
                                           "macro", "keyword", "modifier", "comment", "string", "number", "regexp", "operator",
                                           "decorator"],
                            "tokenModifiers": [],
                            "formats": ["relative"],
                            "overlappingTokenSupport": false,
                            "multilineTokenSupport": false
                        },
                        "inlayHint": { "resolveSupport": { "properties": ["label"] } },
                        "foldingRange": { "lineFoldingOnly": true }
                    }
                }
            }),
            Duration::from_secs(30),
        )?;
        *client.0.capabilities.lock().unwrap() = init.get("capabilities").cloned().unwrap_or(Value::Null);
        client.notify("initialized", json!({}));
        Ok(client)
    }

    fn dispatch(&self, msg: Value) {
        let id = msg.get("id").cloned();
        let method = msg.get("method").and_then(Value::as_str).map(str::to_string);
        match (id, method) {
            (Some(id), None) => {
                let Some(id) = id.as_i64() else { return };
                if let Some(tx) = self.0.pending.lock().unwrap().remove(&id) {
                    let res = match msg.get("error") {
                        Some(e) => Err(e.get("message").and_then(Value::as_str).unwrap_or("error").to_string()),
                        None => Ok(msg.get("result").cloned().unwrap_or(Value::Null)),
                    };
                    let _ = tx.send(res);
                }
            }
            // sunucudan istek: makul boş yanıtlar
            (Some(id), Some(method)) => {
                let result = match method.as_str() {
                    "workspace/configuration" => {
                        let n = msg.pointer("/params/items").and_then(Value::as_array).map_or(1, Vec::len);
                        Value::Array(vec![Value::Null; n])
                    }
                    "workspace/workspaceFolders" => Value::Array(vec![]),
                    // sunucudan gelen düzenleme: kuyruğa al, uygulamayı Swift yapar
                    "workspace/applyEdit" => {
                        if let Some(edit) = msg.pointer("/params/edit") {
                            let mut q = self.0.applied.lock().unwrap();
                            q.push(edit.clone());
                            if q.len() > 32 {
                                q.remove(0);
                            }
                        }
                        json!({ "applied": true })
                    }
                    _ => Value::Null,
                };
                self.send(&json!({ "jsonrpc": "2.0", "id": id, "result": result }));
            }
            (None, Some(method)) => match method.as_str() {
                "textDocument/publishDiagnostics" => {
                    if let Some(uri) = msg.pointer("/params/uri").and_then(Value::as_str) {
                        let diags = msg.pointer("/params/diagnostics").cloned().unwrap_or(Value::Array(vec![]));
                        self.0.diagnostics.lock().unwrap().insert(uri.to_string(), diags);
                        self.0.diag_version.fetch_add(1, Ordering::Relaxed);
                    }
                }
                "window/logMessage" | "window/showMessage" => {
                    if let Some(m) = msg.pointer("/params/message").and_then(Value::as_str) {
                        let mut log = self.0.log.lock().unwrap();
                        log.push(m.to_string());
                        if log.len() > 200 {
                            log.drain(..100);
                        }
                    }
                }
                _ => {}
            },
            _ => {}
        }
    }

    fn send(&self, v: &Value) {
        if let Ok(mut w) = self.0.stdin.lock() {
            if write_message(&mut *w, v).is_err() {
                self.0.alive.store(false, Ordering::Relaxed);
            }
        }
    }

    pub fn is_alive(&self) -> bool {
        self.0.alive.load(Ordering::Relaxed)
    }

    pub fn capabilities(&self) -> Value {
        self.0.capabilities.lock().unwrap().clone()
    }

    pub fn notify(&self, method: &str, params: Value) {
        self.send(&json!({ "jsonrpc": "2.0", "method": method, "params": params }));
    }

    pub fn request(&self, method: &str, params: Value, timeout: Duration) -> Result<Value, String> {
        if !self.is_alive() {
            return Err("server not running".into());
        }
        let id = self.0.next_id.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = channel();
        self.0.pending.lock().unwrap().insert(id, tx);
        self.send(&json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params }));
        match rx.recv_timeout(timeout) {
            Ok(r) => r,
            Err(_) => {
                self.0.pending.lock().unwrap().remove(&id);
                self.notify("$/cancelRequest", json!({ "id": id }));
                Err("timeout".into())
            }
        }
    }

    pub fn diagnostics(&self, uri: &str) -> Value {
        self.0.diagnostics.lock().unwrap().get(uri).cloned().unwrap_or(Value::Array(vec![]))
    }

    pub fn all_diagnostics(&self) -> HashMap<String, Value> {
        self.0.diagnostics.lock().unwrap().clone()
    }

    // sunucunun gönderdiği bekleyen workspace/applyEdit düzenlemeleri
    pub fn take_applied(&self) -> Vec<Value> {
        std::mem::take(&mut *self.0.applied.lock().unwrap())
    }

    pub fn shutdown(&self) {
        if self.is_alive() {
            let _ = self.request("shutdown", Value::Null, Duration::from_millis(500));
            self.notify("exit", Value::Null);
        }
        let _ = self.0.child.lock().unwrap().kill();
    }
}

struct Doc {
    key: String,
    version: i64,
}

// çalışma alanı başına sunucular ve açık belgeler
pub struct Manager {
    root: PathBuf,
    clients: Mutex<HashMap<String, Result<Client, String>>>,
    docs: Mutex<HashMap<String, Doc>>,
    overrides: Mutex<HashMap<String, (String, Vec<String>)>>,
    diag_version: Arc<AtomicU64>,
    restarts: Mutex<HashMap<String, u32>>,
}

const TIMEOUT: Duration = Duration::from_secs(8);

impl Manager {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self {
            root: root.into(),
            clients: Mutex::new(HashMap::new()),
            docs: Mutex::new(HashMap::new()),
            overrides: Mutex::new(HashMap::new()),
            diag_version: Arc::new(AtomicU64::new(0)),
            restarts: Mutex::new(HashMap::new()),
        }
    }

    // ayarlardan: sunucu anahtarı → komut (boşluklarla ayrılmış argümanlar)
    pub fn set_override(&self, key: &str, command_line: &str) {
        let mut parts = command_line.split_whitespace().map(str::to_string);
        if let Some(cmd) = parts.next() {
            self.overrides.lock().unwrap().insert(key.to_string(), (cmd, parts.collect()));
        }
    }

    pub fn diagnostics_version(&self) -> u64 {
        self.diag_version.load(Ordering::Relaxed)
    }

    fn spec(&self, key: &str) -> Option<(PathBuf, Vec<String>)> {
        if let Some((cmd, args)) = self.overrides.lock().unwrap().get(key) {
            return which(cmd).map(|p| (p, args.clone()));
        }
        default_servers(key).into_iter().find_map(|s| which(&s.command).map(|p| (p, s.args)))
    }

    // sunucu durumu: "ok", "starting", "missing: <kurulum komutu>", "error: ..."
    pub fn status(&self, path: &Path) -> String {
        let Some((_, key)) = language_id(path) else { return String::new() };
        match self.clients.lock().unwrap().get(key) {
            Some(Ok(c)) if c.is_alive() => "ok".into(),
            Some(Ok(_)) => "error: server exited".into(),
            Some(Err(e)) => e.clone(),
            None => match self.spec(key) {
                Some(_) => "starting".into(),
                None => format!("missing: {}", default_servers(key).first().map_or("", |s| s.install)),
            },
        }
    }

    fn client(&self, key: &str) -> Option<Client> {
        let mut clients = self.clients.lock().unwrap();
        if let Some(Ok(c)) = clients.get(key) {
            if c.is_alive() {
                return Some(c.clone());
            }
            // çöktüyse en fazla 3 kez yeniden başlat
            let mut r = self.restarts.lock().unwrap();
            let n = r.entry(key.to_string()).or_insert(0);
            if *n >= 3 {
                return None;
            }
            *n += 1;
            clients.remove(key);
        } else if clients.contains_key(key) {
            return None;
        }
        let result = match self.spec(key) {
            Some((cmd, args)) => Client::start(&cmd, &args, &self.root, self.diag_version.clone()),
            None => Err(format!("missing: {}", default_servers(key).first().map_or("", |s| s.install))),
        };
        let out = result.as_ref().ok().cloned();
        clients.insert(key.to_string(), result);
        drop(clients);
        // yeniden başlayan sunucuya açık belgeleri tekrar bildir
        if out.is_some() {
            let reopen: Vec<String> = self.docs.lock().unwrap().iter().filter(|(_, d)| d.key == key).map(|(u, _)| u.clone()).collect();
            for uri in reopen {
                if let Some(path) = uri_to_path(&uri) {
                    if let Ok(text) = std::fs::read_to_string(&path) {
                        self.did_open_with(out.as_ref().unwrap(), &path, &text);
                    }
                }
            }
        }
        out
    }

    fn doc_client(&self, path: &Path) -> Option<(Client, String)> {
        let (_, key) = language_id(path)?;
        Some((self.client(key)?, path_to_uri(path)))
    }

    fn did_open_with(&self, c: &Client, path: &Path, text: &str) {
        let Some((lang, _)) = language_id(path) else { return };
        let uri = path_to_uri(path);
        c.notify("textDocument/didOpen", json!({ "textDocument": { "uri": uri, "languageId": lang, "version": 1, "text": text } }));
    }

    pub fn open(&self, path: &Path, text: &str) -> bool {
        let Some((_, key)) = language_id(path) else { return false };
        let uri = path_to_uri(path);
        if self.docs.lock().unwrap().contains_key(&uri) {
            return self.change(path, text);
        }
        let Some(c) = self.client(key) else { return false };
        self.docs.lock().unwrap().insert(uri, Doc { key: key.to_string(), version: 1 });
        self.did_open_with(&c, path, text);
        true
    }

    pub fn change(&self, path: &Path, text: &str) -> bool {
        let uri = path_to_uri(path);
        let version = {
            let mut docs = self.docs.lock().unwrap();
            let Some(d) = docs.get_mut(&uri) else {
                drop(docs);
                return self.open(path, text);
            };
            d.version += 1;
            d.version
        };
        let Some((c, _)) = self.doc_client(path) else { return false };
        c.notify(
            "textDocument/didChange",
            json!({ "textDocument": { "uri": uri, "version": version }, "contentChanges": [{ "text": text }] }),
        );
        true
    }

    pub fn save(&self, path: &Path) {
        if let Some((c, uri)) = self.doc_client(path) {
            c.notify("textDocument/didSave", json!({ "textDocument": { "uri": uri } }));
        }
    }

    pub fn close(&self, path: &Path) {
        let uri = path_to_uri(path);
        if self.docs.lock().unwrap().remove(&uri).is_some() {
            if let Some((c, _)) = self.doc_client(path) {
                c.notify("textDocument/didClose", json!({ "textDocument": { "uri": uri } }));
            }
        }
    }

    fn position_request(&self, method: &str, path: &Path, line: u32, col: u32, extra: Value) -> Result<Value, String> {
        let (c, uri) = self.doc_client(path).ok_or("no language server")?;
        let mut params = json!({ "textDocument": { "uri": uri }, "position": { "line": line, "character": col } });
        if let (Value::Object(p), Value::Object(e)) = (&mut params, extra) {
            p.extend(e);
        }
        c.request(method, params, TIMEOUT)
    }

    pub fn diagnostics(&self, path: &Path) -> Value {
        self.doc_client_existing(path).map_or(Value::Array(vec![]), |(c, uri)| c.diagnostics(&uri))
    }

    // tüm dosyalardaki tanılar: {uri: [..]}
    pub fn all_diagnostics(&self) -> Value {
        let mut out = serde_json::Map::new();
        for c in self.clients.lock().unwrap().values().flatten() {
            for (uri, d) in c.all_diagnostics() {
                if d.as_array().is_some_and(|a| !a.is_empty()) {
                    out.insert(uri, d);
                }
            }
        }
        Value::Object(out)
    }

    // sunucu başlatmadan mevcut istemci
    fn doc_client_existing(&self, path: &Path) -> Option<(Client, String)> {
        let (_, key) = language_id(path)?;
        let clients = self.clients.lock().unwrap();
        let c = clients.get(key)?.as_ref().ok()?.clone();
        Some((c, path_to_uri(path)))
    }

    pub fn completion(&self, path: &Path, line: u32, col: u32, trigger: Option<&str>) -> Result<Value, String> {
        let ctx = match trigger {
            Some(t) => json!({ "context": { "triggerKind": 2, "triggerCharacter": t } }),
            None => json!({ "context": { "triggerKind": 1 } }),
        };
        let r = self.position_request("textDocument/completion", path, line, col, ctx)?;
        Ok(match r {
            Value::Array(items) => Value::Array(items),
            Value::Object(o) => o.get("items").cloned().unwrap_or(Value::Array(vec![])),
            _ => Value::Array(vec![]),
        })
    }

    pub fn hover(&self, path: &Path, line: u32, col: u32) -> Result<Value, String> {
        self.position_request("textDocument/hover", path, line, col, json!({}))
    }

    pub fn signature_help(&self, path: &Path, line: u32, col: u32) -> Result<Value, String> {
        self.position_request("textDocument/signatureHelp", path, line, col, json!({}))
    }

    // her zaman konum dizisi: [{uri, range}]
    pub fn definition(&self, path: &Path, line: u32, col: u32) -> Result<Value, String> {
        let r = self.position_request("textDocument/definition", path, line, col, json!({}))?;
        Ok(normalize_locations(r))
    }

    pub fn references(&self, path: &Path, line: u32, col: u32) -> Result<Value, String> {
        let r = self.position_request("textDocument/references", path, line, col, json!({ "context": { "includeDeclaration": true } }))?;
        Ok(normalize_locations(r))
    }

    // {uri: [TextEdit]}
    pub fn rename(&self, path: &Path, line: u32, col: u32, name: &str) -> Result<Value, String> {
        let r = self.position_request("textDocument/rename", path, line, col, json!({ "newName": name }))?;
        Ok(Value::Object(edit_changes(&r)))
    }

    // [{title, kind, action}] — action apply_code_action'a geri verilir
    pub fn code_actions(&self, path: &Path, line: u32, col: u32, end_line: u32, end_col: u32) -> Result<Value, String> {
        let (c, uri) = self.doc_client(path).ok_or("no language server")?;
        if !has_cap(&c.capabilities(), "codeActionProvider") {
            return Ok(Value::Array(vec![]));
        }
        // seçimle kesişen tanılar bağlam olarak gider
        let diags: Vec<Value> = c
            .diagnostics(&uri)
            .as_array()
            .map(|a| {
                a.iter()
                    .filter(|d| {
                        let s = d.pointer("/range/start/line").and_then(Value::as_u64).unwrap_or(0) as u32;
                        let e = d.pointer("/range/end/line").and_then(Value::as_u64).unwrap_or(0) as u32;
                        e >= line && s <= end_line
                    })
                    .cloned()
                    .collect()
            })
            .unwrap_or_default();
        let params = json!({
            "textDocument": { "uri": uri },
            "range": { "start": { "line": line, "character": col }, "end": { "line": end_line, "character": end_col } },
            "context": { "diagnostics": diags, "triggerKind": 1 }
        });
        let r = c.request("textDocument/codeAction", params, TIMEOUT)?;
        let out: Vec<Value> = r
            .as_array()
            .map(Vec::as_slice)
            .unwrap_or(&[])
            .iter()
            .filter_map(|a| {
                let title = a.get("title").and_then(Value::as_str).or_else(|| a.pointer("/command/title").and_then(Value::as_str))?;
                Some(json!({ "title": title, "kind": a.get("kind").cloned().unwrap_or(Value::Null), "action": a }))
            })
            .collect();
        Ok(Value::Array(out))
    }

    // eylemi çöz/çalıştır → {uri: [TextEdit]}
    pub fn apply_code_action(&self, path: &Path, action: &str) -> Result<Value, String> {
        let (c, _) = self.doc_client(path).ok_or("no language server")?;
        let mut a: Value = serde_json::from_str(action).map_err(|e| e.to_string())?;
        if a.get("edit").is_none() && a.get("data").is_some() {
            if let Ok(r) = c.request("codeAction/resolve", a.clone(), TIMEOUT) {
                if r.is_object() {
                    a = r;
                }
            }
        }
        let _ = c.take_applied();
        let mut changes = a.get("edit").map(edit_changes).unwrap_or_default();
        // düzenleme yoksa komut çalıştır; sunucu düzenlemeyi applyEdit ile gönderir
        let cmd = match a.get("command") {
            Some(v) if v.is_object() => Some(v.clone()),
            Some(v) if v.is_string() => Some(a.clone()),
            _ => None,
        };
        if changes.is_empty() {
            if let Some(cmd) = cmd {
                let params = json!({
                    "command": cmd.get("command").cloned().unwrap_or(Value::Null),
                    "arguments": cmd.get("arguments").cloned().unwrap_or(json!([]))
                });
                c.request("workspace/executeCommand", params, Duration::from_secs(15))?;
                for e in c.take_applied() {
                    for (k, v) in edit_changes(&e) {
                        changes.insert(k, v);
                    }
                }
            }
        }
        Ok(Value::Object(changes))
    }

    // çalışan tüm sunucularda sembol ara: [{name, kind, container, uri, line, col}]
    pub fn workspace_symbols(&self, query: &str) -> Result<Value, String> {
        let clients: Vec<Client> = self.clients.lock().unwrap().values().flatten().cloned().collect();
        if clients.is_empty() {
            return Err("no language server".into());
        }
        let mut out = Vec::new();
        for c in clients {
            if !has_cap(&c.capabilities(), "workspaceSymbolProvider") {
                continue;
            }
            let Ok(r) = c.request("workspace/symbol", json!({ "query": query }), TIMEOUT) else { continue };
            for s in r.as_array().map(Vec::as_slice).unwrap_or(&[]) {
                let Some(uri) = s.pointer("/location/uri").and_then(Value::as_str) else { continue };
                let pos = s.pointer("/location/range/start");
                out.push(json!({
                    "name": s.get("name").cloned().unwrap_or(Value::Null),
                    "kind": s.get("kind").cloned().unwrap_or(Value::Null),
                    "container": s.get("containerName").cloned().unwrap_or(Value::Null),
                    "uri": uri,
                    "line": pos.and_then(|p| p.get("line")).cloned().unwrap_or(json!(0)),
                    "col": pos.and_then(|p| p.get("character")).cloned().unwrap_or(json!(0)),
                }));
                if out.len() >= 300 {
                    break;
                }
            }
        }
        Ok(Value::Array(out))
    }

    // [{line, col, len, kind}] — kind kern-syntax token kodu, 0 olanlar atlanır
    pub fn semantic_tokens(&self, path: &Path) -> Result<Value, String> {
        let (c, uri) = self.doc_client(path).ok_or("no language server")?;
        let caps = c.capabilities();
        let legend: Vec<u8> = caps
            .pointer("/semanticTokensProvider/legend/tokenTypes")
            .and_then(Value::as_array)
            .map(|a| a.iter().map(|v| semantic_kind(v.as_str().unwrap_or(""))).collect())
            .unwrap_or_default();
        if legend.is_empty() {
            return Ok(Value::Array(vec![]));
        }
        let r = c.request("textDocument/semanticTokens/full", json!({ "textDocument": { "uri": uri } }), TIMEOUT)?;
        let data = r.get("data").and_then(Value::as_array).cloned().unwrap_or_default();
        let mut out = Vec::new();
        let (mut line, mut col) = (0u64, 0u64);
        for t in data.chunks_exact(5) {
            let n = |v: &Value| v.as_u64().unwrap_or(0);
            let (dl, dc, len, ty) = (n(&t[0]), n(&t[1]), n(&t[2]), n(&t[3]) as usize);
            line += dl;
            col = if dl == 0 { col + dc } else { dc };
            let kind = legend.get(ty).copied().unwrap_or(0);
            if kind == 0 || len == 0 {
                continue;
            }
            out.push(json!({ "line": line, "col": col, "len": len, "kind": kind }));
        }
        Ok(Value::Array(out))
    }

    // [{line, col, text}] — satır içi ipuçları
    pub fn inlay_hints(&self, path: &Path, start_line: u32, end_line: u32) -> Result<Value, String> {
        let (c, uri) = self.doc_client(path).ok_or("no language server")?;
        if !has_cap(&c.capabilities(), "inlayHintProvider") {
            return Ok(Value::Array(vec![]));
        }
        let params = json!({
            "textDocument": { "uri": uri },
            "range": { "start": { "line": start_line, "character": 0 }, "end": { "line": end_line, "character": 0 } }
        });
        let r = c.request("textDocument/inlayHint", params, TIMEOUT)?;
        let mut out = Vec::new();
        for h in r.as_array().map(Vec::as_slice).unwrap_or(&[]) {
            let label = match h.get("label") {
                Some(Value::String(s)) => s.clone(),
                Some(Value::Array(parts)) => parts.iter().filter_map(|p| p.get("value").and_then(Value::as_str)).collect(),
                _ => String::new(),
            };
            let label = label.trim().to_string();
            if label.is_empty() {
                continue;
            }
            let pad = |k: &str| h.get(k).and_then(Value::as_bool).unwrap_or(false);
            out.push(json!({
                "line": h.pointer("/position/line").and_then(Value::as_u64).unwrap_or(0),
                "col": h.pointer("/position/character").and_then(Value::as_u64).unwrap_or(0),
                "text": format!("{}{}{}", if pad("paddingLeft") { " " } else { "" }, label, if pad("paddingRight") { " " } else { "" }),
            }));
        }
        Ok(Value::Array(out))
    }

    // [{start, end}] — katlanabilir aralıklar (satır bazlı)
    pub fn folding_ranges(&self, path: &Path) -> Result<Value, String> {
        let (c, uri) = self.doc_client(path).ok_or("no language server")?;
        if !has_cap(&c.capabilities(), "foldingRangeProvider") {
            return Ok(Value::Array(vec![]));
        }
        let r = c.request("textDocument/foldingRange", json!({ "textDocument": { "uri": uri } }), TIMEOUT)?;
        let mut out = Vec::new();
        for f in r.as_array().map(Vec::as_slice).unwrap_or(&[]) {
            let s = f.get("startLine").and_then(Value::as_u64).unwrap_or(0);
            let e = f.get("endLine").and_then(Value::as_u64).unwrap_or(0);
            if e > s {
                out.push(json!({ "start": s, "end": e }));
            }
        }
        Ok(Value::Array(out))
    }

    pub fn formatting(&self, path: &Path, tab_size: u32, insert_spaces: bool) -> Result<Value, String> {
        let (c, uri) = self.doc_client(path).ok_or("no language server")?;
        c.request(
            "textDocument/formatting",
            json!({ "textDocument": { "uri": uri }, "options": { "tabSize": tab_size, "insertSpaces": insert_spaces } }),
            TIMEOUT,
        )
    }

    // düz liste: [{name, kind, line, col, depth}]
    pub fn document_symbols(&self, path: &Path) -> Result<Value, String> {
        let (c, uri) = self.doc_client(path).ok_or("no language server")?;
        let r = c.request("textDocument/documentSymbol", json!({ "textDocument": { "uri": uri } }), TIMEOUT)?;
        let mut out = Vec::new();
        fn walk(items: &[Value], depth: u32, out: &mut Vec<Value>) {
            for s in items {
                let pos = s.pointer("/selectionRange/start").or_else(|| s.pointer("/location/range/start")).cloned().unwrap_or(Value::Null);
                out.push(json!({
                    "name": s.get("name").cloned().unwrap_or(Value::Null),
                    "kind": s.get("kind").cloned().unwrap_or(Value::Null),
                    "line": pos.get("line").cloned().unwrap_or(json!(0)),
                    "col": pos.get("character").cloned().unwrap_or(json!(0)),
                    "depth": depth,
                }));
                if let Some(ch) = s.get("children").and_then(Value::as_array) {
                    walk(ch, depth + 1, out);
                }
            }
        }
        walk(r.as_array().map(Vec::as_slice).unwrap_or(&[]), 0, &mut out);
        Ok(Value::Array(out))
    }

    pub fn shutdown(&self) {
        for c in self.clients.lock().unwrap().drain().filter_map(|(_, c)| c.ok()) {
            c.shutdown();
        }
    }
}

impl Drop for Manager {
    fn drop(&mut self) {
        self.shutdown();
    }
}

fn normalize_locations(r: Value) -> Value {
    let items = match r {
        Value::Array(a) => a,
        Value::Null => vec![],
        v => vec![v],
    };
    Value::Array(
        items
            .into_iter()
            .map(|l| {
                // LocationLink → Location
                if let Some(uri) = l.get("targetUri") {
                    json!({ "uri": uri, "range": l.get("targetSelectionRange").or(l.get("targetRange")).cloned().unwrap_or(Value::Null) })
                } else {
                    l
                }
            })
            .collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uri_roundtrip_and_ids() {
        let p = Path::new("/tmp/a b/ç.rs");
        assert_eq!(uri_to_path(&path_to_uri(p)).unwrap(), p);
        assert_eq!(language_id(Path::new("x.tsx")), Some(("typescriptreact", "typescript")));
        assert!(language_id(Path::new("x.txt")).is_none());
    }

    #[test]
    fn semantic_kinds_and_edits() {
        assert_eq!(semantic_kind("function"), 5);
        assert_eq!(semantic_kind("struct"), 6);
        assert_eq!(semantic_kind("bogus"), 0);
        let e = json!({ "documentChanges": [{ "textDocument": { "uri": "file:///a.c" }, "edits": [{ "newText": "x" }] }] });
        assert!(edit_changes(&e).contains_key("file:///a.c"));
        assert!(has_cap(&json!({ "a": true }), "a"));
        assert!(!has_cap(&json!({ "a": false }), "a"));
    }

    #[test]
    fn framing() {
        let mut buf = Vec::new();
        write_message(&mut buf, &json!({ "a": 1 })).unwrap();
        let mut r = BufReader::new(&buf[..]);
        assert_eq!(read_message(&mut r).unwrap().unwrap(), json!({ "a": 1 }));
    }

    // clangd kuruluysa uçtan uca: tanı, tamamlama, tanım
    #[test]
    fn clangd_end_to_end() {
        if which("clangd").is_none() {
            return;
        }
        let dir = std::env::temp_dir().join(format!("kern-lsp-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("main.c");
        let text = "int square(int x) { return x * x; }\nint main(void) { int y = square(2); return undefined_name + y; }\n";
        std::fs::write(&file, text).unwrap();
        let m = Manager::new(&dir);
        assert!(m.open(&file, text));
        let deadline = std::time::Instant::now() + Duration::from_secs(20);
        while m.diagnostics(&file).as_array().is_none_or(Vec::is_empty) {
            assert!(std::time::Instant::now() < deadline, "tanı gelmedi");
            std::thread::sleep(Duration::from_millis(100));
        }
        let d = m.diagnostics(&file);
        assert!(d.to_string().contains("undefined_name"));
        let def = m.definition(&file, 1, 27).unwrap();
        assert_eq!(def[0]["range"]["start"]["line"], 0);
        let items = m.completion(&file, 1, 27, None).unwrap();
        assert!(items.to_string().contains("square"));
        let syms = m.document_symbols(&file).unwrap();
        assert!(syms.to_string().contains("\"main\""));
        // katlama, anlamsal renklendirme ve düzeltme eylemleri (clangd hepsini destekler)
        let folds = m.folding_ranges(&file).unwrap();
        assert!(folds.as_array().is_some());
        let sem = m.semantic_tokens(&file).unwrap();
        assert!(sem.to_string().contains("\"kind\""));
        let actions = m.code_actions(&file, 1, 27, 1, 27).unwrap();
        assert!(actions.as_array().is_some());
        let _ = m.inlay_hints(&file, 0, 2).unwrap();
        let _ = std::fs::remove_dir_all(&dir);
    }

    // rust-analyzer kuruluysa: anlamsal renk, satır içi ipucu, katlama, sembol
    #[test]
    fn rust_analyzer_end_to_end() {
        if which("rust-analyzer").is_none() {
            return;
        }
        let dir = std::env::temp_dir().join(format!("kern-ra-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("src")).unwrap();
        std::fs::write(dir.join("Cargo.toml"), "[package]\nname = \"kern-ra-test\"\nversion = \"0.1.0\"\nedition = \"2021\"\n").unwrap();
        let file = dir.join("src/main.rs");
        let text = "fn double(x: i32) -> i32 {\n    x * 2\n}\n\nfn main() {\n    let value = double(21);\n    println!(\"{value}\");\n}\n";
        std::fs::write(&file, text).unwrap();
        let m = Manager::new(&dir);
        assert!(m.open(&file, text));
        // çalışma alanı (cargo metadata) yüklenene kadar tanım/tür çözülmez
        let deadline = std::time::Instant::now() + Duration::from_secs(180);
        loop {
            let def = m.definition(&file, 5, 17).unwrap_or(Value::Null);
            if def[0]["range"]["start"]["line"] == 0 {
                break;
            }
            assert!(std::time::Instant::now() < deadline, "rust-analyzer çalışma alanını yüklemedi");
            std::thread::sleep(Duration::from_millis(500));
        }
        let syms = m.document_symbols(&file).unwrap();
        assert!(syms.to_string().contains("\"double\""));
        let sem = m.semantic_tokens(&file).unwrap();
        assert!(!sem.as_array().unwrap().is_empty());
        let folds = m.folding_ranges(&file).unwrap();
        assert!(!folds.as_array().unwrap().is_empty());
        // `let value` satırında tür ipucu
        let hints = m.inlay_hints(&file, 0, 8).unwrap();
        assert!(hints.to_string().contains("i32"), "ipucu yok: {hints}");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
