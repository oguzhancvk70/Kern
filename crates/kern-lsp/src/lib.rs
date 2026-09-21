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
                    "workspace": { "workspaceFolders": true, "configuration": true, "applyEdit": false },
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
                        "publishDiagnostics": { "relatedInformation": false }
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
        let mut out = serde_json::Map::new();
        if let Some(changes) = r.get("changes").and_then(Value::as_object) {
            out.extend(changes.clone());
        }
        for dc in r.get("documentChanges").and_then(Value::as_array).into_iter().flatten() {
            if let (Some(uri), Some(edits)) = (dc.pointer("/textDocument/uri").and_then(Value::as_str), dc.get("edits")) {
                out.insert(uri.to_string(), edits.clone());
            }
        }
        Ok(Value::Object(out))
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
        let _ = std::fs::remove_dir_all(&dir);
    }
}
