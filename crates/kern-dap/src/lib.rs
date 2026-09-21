// DAP istemcisi: hata ayıklama bağdaştırıcısı süreci, stdio veya TCP üzerinden
use std::collections::HashMap;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU64, Ordering};
use std::sync::mpsc::{Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Map, Value, json};

pub use serde_json;

pub struct Adapter {
    pub command: String,
    pub args: Vec<String>,
    // true → bağdaştırıcı bir TCP sunucusu; ${port} argümanda değiştirilir
    pub tcp: bool,
    pub install: &'static str,
}

fn adapter(command: &str, args: &[&str], tcp: bool, install: &'static str) -> Adapter {
    Adapter { command: command.into(), args: args.iter().map(|a| a.to_string()).collect(), tcp, install }
}

// launch.json "type" → bağdaştırıcı adayları; ilk bulunan kullanılır
pub fn default_adapters(kind: &str) -> Vec<Adapter> {
    match kind {
        "lldb" | "cppdbg" | "c" | "cpp" | "rust" | "swift" => vec![
            adapter("lldb-dap", &[], false, "xcode-select --install"),
            adapter("codelldb", &["--port", "${port}"], true, "brew install codelldb"),
        ],
        "python" | "debugpy" => vec![
            adapter("debugpy-adapter", &[], false, "pip3 install debugpy"),
            adapter("python3", &["-m", "debugpy.adapter"], false, "pip3 install debugpy"),
        ],
        "node" | "pwa-node" | "js" => vec![adapter("js-debug-adapter", &["${port}"], true, "npm install -g js-debug-adapter")],
        _ => Vec::new(),
    }
}

// dosya uzantısı → launch.json türü
pub fn kind_for(path: &Path) -> Option<&'static str> {
    let ext = path.extension()?.to_str()?.to_ascii_lowercase();
    Some(match ext.as_str() {
        "py" => "python",
        "js" | "mjs" | "cjs" | "ts" => "node",
        "c" | "cc" | "cpp" | "cxx" | "m" | "mm" | "rs" | "swift" => "lldb",
        _ => return None,
    })
}

// PATH + Xcode araç zinciri ve yaygın konumlar
pub fn which(cmd: &str) -> Option<PathBuf> {
    if cmd.contains('/') {
        return Path::new(cmd).is_file().then(|| PathBuf::from(cmd));
    }
    let mut dirs: Vec<PathBuf> = std::env::var_os("PATH").map(|p| std::env::split_paths(&p).collect()).unwrap_or_default();
    if let Some(home) = std::env::var_os("HOME") {
        let home = PathBuf::from(home);
        dirs.extend(["go/bin", ".cargo/bin", ".local/bin", ".npm-global/bin", "Library/Python/3.13/bin"].map(|d| home.join(d)));
    }
    dirs.extend(
        [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/Applications/Xcode.app/Contents/Developer/usr/bin",
            "/Library/Developer/CommandLineTools/usr/bin",
        ]
        .map(PathBuf::from),
    );
    dirs.into_iter().map(|d| d.join(cmd)).find(|p| p.is_file())
}

// bağdaştırıcı durumu: "ok" ya da "missing: <kurulum komutu>"
pub fn adapter_status(kind: &str) -> String {
    let specs = default_adapters(kind);
    if specs.is_empty() {
        return format!("unsupported: {kind}");
    }
    match specs.iter().find(|s| which(&s.command).is_some()) {
        Some(_) => "ok".into(),
        None => format!("missing: {}", specs[0].install),
    }
}

fn strip_jsonc(src: &str) -> String {
    let b = src.as_bytes();
    let mut out = String::with_capacity(src.len());
    let (mut i, mut in_str, mut esc) = (0, false, false);
    while i < b.len() {
        let c = b[i] as char;
        if in_str {
            out.push(c);
            if esc {
                esc = false;
            } else if c == '\\' {
                esc = true;
            } else if c == '"' {
                in_str = false;
            }
            i += 1;
            continue;
        }
        match (c, b.get(i + 1).copied()) {
            ('/', Some(b'/')) => {
                while i < b.len() && b[i] != b'\n' {
                    i += 1;
                }
            }
            ('/', Some(b'*')) => {
                i += 2;
                while i + 1 < b.len() && !(b[i] == b'*' && b[i + 1] == b'/') {
                    i += 1;
                }
                i = (i + 2).min(b.len());
            }
            _ => {
                if c == '"' {
                    in_str = true;
                }
                out.push(c);
                i += 1;
            }
        }
    }
    out
}

// .kern/launch.json veya .vscode/launch.json → configurations dizisi
pub fn load_configs(root: &Path) -> Value {
    for rel in [".kern/launch.json", ".vscode/launch.json"] {
        let Ok(text) = std::fs::read_to_string(root.join(rel)) else { continue };
        let Ok(v) = serde_json::from_str::<Value>(&strip_jsonc(&text)) else { continue };
        let list = match v {
            Value::Array(a) => a,
            Value::Object(ref o) => o.get("configurations").and_then(Value::as_array).cloned().unwrap_or_default(),
            _ => continue,
        };
        let list: Vec<Value> = list
            .into_iter()
            .filter(|c| c.get("type").is_some())
            .map(|mut c| {
                if let Value::Object(o) = &mut c {
                    let fallback = o.get("type").and_then(Value::as_str).unwrap_or("debug").to_string();
                    o.entry("request").or_insert(json!("launch"));
                    o.entry("name").or_insert(json!(fallback));
                    o.insert("source".into(), json!(rel));
                }
                c
            })
            .collect();
        if !list.is_empty() {
            return Value::Array(list);
        }
    }
    Value::Array(vec![])
}

// launch.json yoksa dosyadan tek tıkla konfigürasyon
pub fn suggest_config(path: &Path) -> Option<Value> {
    let kind = kind_for(path)?;
    let name = path.file_name()?.to_string_lossy().into_owned();
    Some(match kind {
        "python" => {
            json!({ "name": format!("Run {name}"), "type": "python", "request": "launch", "program": path, "console": "internalConsole" })
        }
        "node" => json!({ "name": format!("Run {name}"), "type": "node", "request": "launch", "program": path }),
        // derlenmiş diller: çalıştırılabilir yolu kullanıcı verir
        _ => json!({ "name": format!("Debug {name}"), "type": "lldb", "request": "launch", "program": "", "needsProgram": true }),
    })
}

// ${port} yerine boş bir port
fn free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0").ok().and_then(|l| l.local_addr().ok()).map_or(4711, |a| a.port())
}

enum Wire {
    Stdio(std::process::ChildStdin),
    Tcp(TcpStream),
}

impl Write for Wire {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        match self {
            Wire::Stdio(w) => w.write(buf),
            Wire::Tcp(w) => w.write(buf),
        }
    }
    fn flush(&mut self) -> io::Result<()> {
        match self {
            Wire::Stdio(w) => w.flush(),
            Wire::Tcp(w) => w.flush(),
        }
    }
}

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

#[derive(Default)]
struct State {
    running: bool,
    thread: Option<i64>,
    frame: Option<i64>,
    reason: String,
    description: String,
    terminated: bool,
    exit_code: Option<i64>,
    output: Vec<Value>,
    dropped_output: usize,
    verified: HashMap<String, Vec<Value>>,
}

struct Inner {
    write: Mutex<Wire>,
    child: Mutex<Option<Child>>,
    seq: AtomicI64,
    pending: Mutex<HashMap<i64, Sender<Result<Value, String>>>>,
    st: Mutex<State>,
    bps: Mutex<HashMap<String, Vec<u32>>>,
    caps: Mutex<Value>,
    version: AtomicU64,
    alive: AtomicBool,
    configured: AtomicBool,
    name: String,
}

#[derive(Clone)]
pub struct Session(Arc<Inner>);

const TIMEOUT: Duration = Duration::from_secs(10);
const OUTPUT_LIMIT: usize = 5000;

impl Session {
    // config: launch.json girdisi; breakpoints: {yol: [1 tabanlı satırlar]}
    pub fn start(root: &Path, config: &Value, breakpoints: &Value) -> Result<Session, String> {
        let kind = config.get("type").and_then(Value::as_str).unwrap_or_default().to_string();
        let specs = default_adapters(&kind);
        if specs.is_empty() {
            return Err(format!("unsupported debug type “{kind}”"));
        }
        let spec = specs
            .into_iter()
            .find_map(|s| which(&s.command).map(|p| (p, s)))
            .ok_or_else(|| format!("missing: {}", default_adapters(&kind)[0].install))?;
        let (exe, spec) = spec;
        let port = spec.tcp.then(free_port);
        let args: Vec<String> = spec.args.iter().map(|a| a.replace("${port}", &port.unwrap_or_default().to_string())).collect();
        let cwd = config.get("cwd").and_then(Value::as_str).map(PathBuf::from).unwrap_or_else(|| root.to_path_buf());

        let mut cmd = Command::new(&exe);
        cmd.args(&args).current_dir(if cwd.is_dir() { &cwd } else { root }).stderr(Stdio::null());
        if port.is_some() {
            cmd.stdin(Stdio::null()).stdout(Stdio::null());
        } else {
            cmd.stdin(Stdio::piped()).stdout(Stdio::piped());
        }
        let mut child = cmd.spawn().map_err(|e| format!("{}: {e}", exe.display()))?;

        let (wire, reader): (Wire, Box<dyn Read + Send>) = match port {
            Some(p) => {
                let addr: SocketAddr = ([127, 0, 0, 1], p).into();
                let mut stream = None;
                for _ in 0..80 {
                    match TcpStream::connect_timeout(&addr, Duration::from_millis(200)) {
                        Ok(s) => {
                            stream = Some(s);
                            break;
                        }
                        Err(_) => std::thread::sleep(Duration::from_millis(50)),
                    }
                }
                let s = stream.ok_or_else(|| {
                    let _ = child.kill();
                    format!("{} porta bağlanamadı ({p})", exe.display())
                })?;
                (Wire::Tcp(s.try_clone().map_err(|e| e.to_string())?), Box::new(s))
            }
            None => {
                let stdin = child.stdin.take().ok_or("stdin yok")?;
                let stdout = child.stdout.take().ok_or("stdout yok")?;
                (Wire::Stdio(stdin), Box::new(stdout))
            }
        };

        let mut seeded: HashMap<String, Vec<u32>> = HashMap::new();
        if let Some(map) = breakpoints.as_object() {
            for (path, lines) in map {
                let lines: Vec<u32> =
                    lines.as_array().map(|a| a.iter().filter_map(|l| l.as_u64().map(|l| l as u32)).collect()).unwrap_or_default();
                if !lines.is_empty() {
                    seeded.insert(path.clone(), lines);
                }
            }
        }

        let inner = Arc::new(Inner {
            write: Mutex::new(wire),
            child: Mutex::new(Some(child)),
            seq: AtomicI64::new(1),
            pending: Mutex::new(HashMap::new()),
            st: Mutex::new(State::default()),
            bps: Mutex::new(seeded),
            caps: Mutex::new(Value::Null),
            version: AtomicU64::new(1),
            alive: AtomicBool::new(true),
            configured: AtomicBool::new(false),
            name: config.get("name").and_then(Value::as_str).unwrap_or("debug").to_string(),
        });

        let reader_inner = inner.clone();
        std::thread::spawn(move || {
            let mut r = BufReader::new(reader);
            while let Ok(Some(msg)) = read_message(&mut r) {
                Session(reader_inner.clone()).dispatch(msg);
            }
            reader_inner.alive.store(false, Ordering::Relaxed);
            for (_, tx) in reader_inner.pending.lock().unwrap().drain() {
                let _ = tx.send(Err("debug adapter exited".into()));
            }
            {
                let mut st = reader_inner.st.lock().unwrap();
                st.terminated = true;
                st.running = false;
                st.thread = None;
            }
            reader_inner.version.fetch_add(1, Ordering::Relaxed);
        });

        let session = Session(inner);
        let init = session.request(
            "initialize",
            json!({
                "clientID": "kern",
                "clientName": "Kern",
                "adapterID": kind,
                "locale": "en",
                "pathFormat": "path",
                "linesStartAt1": true,
                "columnsStartAt1": true,
                "supportsVariableType": true,
                "supportsVariablePaging": false,
                "supportsRunInTerminalRequest": false,
                "supportsProgressReporting": false,
                "supportsMemoryReferences": false
            }),
            Duration::from_secs(15),
        );
        match init {
            Ok(caps) => *session.0.caps.lock().unwrap() = caps,
            Err(e) => {
                session.kill();
                return Err(e);
            }
        }

        // launch/attach argümanları: iç anahtarlar çıkarılır, cwd tamamlanır
        let mut args: Map<String, Value> = config.as_object().cloned().unwrap_or_default();
        for k in ["source", "needsProgram"] {
            args.remove(k);
        }
        args.entry("cwd").or_insert(json!(root));
        let attach = config.get("request").and_then(Value::as_str) == Some("attach");
        let launched = session.request(if attach { "attach" } else { "launch" }, Value::Object(args), Duration::from_secs(30));
        if let Err(e) = launched {
            session.kill();
            return Err(e);
        }
        Ok(session)
    }

    pub fn name(&self) -> String {
        self.0.name.clone()
    }

    pub fn version(&self) -> u64 {
        self.0.version.load(Ordering::Relaxed)
    }

    pub fn is_alive(&self) -> bool {
        self.0.alive.load(Ordering::Relaxed)
    }

    fn bump(&self) {
        self.0.version.fetch_add(1, Ordering::Relaxed);
    }

    fn dispatch(&self, msg: Value) {
        match msg.get("type").and_then(Value::as_str) {
            Some("response") => {
                let Some(id) = msg.get("request_seq").and_then(Value::as_i64) else { return };
                let ok = msg.get("success").and_then(Value::as_bool).unwrap_or(false);
                if let Some(tx) = self.0.pending.lock().unwrap().remove(&id) {
                    let res = if ok {
                        Ok(msg.get("body").cloned().unwrap_or(Value::Null))
                    } else {
                        Err(msg
                            .get("message")
                            .and_then(Value::as_str)
                            .or_else(|| msg.pointer("/body/error/format").and_then(Value::as_str))
                            .unwrap_or("request failed")
                            .to_string())
                    };
                    let _ = tx.send(res);
                }
            }
            Some("event") => self.event(&msg),
            // ters istekler: desteklenmeyenler kibarca reddedilir
            Some("request") => {
                let cmd = msg.get("command").and_then(Value::as_str).unwrap_or_default().to_string();
                let seq = msg.get("seq").and_then(Value::as_i64).unwrap_or(0);
                let ok = cmd == "startDebugging";
                self.send(&json!({
                    "seq": self.0.seq.fetch_add(1, Ordering::Relaxed),
                    "type": "response", "request_seq": seq, "command": cmd,
                    "success": ok, "message": if ok { Value::Null } else { json!("unsupported by Kern") }
                }));
            }
            _ => {}
        }
    }

    fn event(&self, msg: &Value) {
        let event = msg.get("event").and_then(Value::as_str).unwrap_or_default();
        let body = msg.get("body").cloned().unwrap_or(Value::Null);
        match event {
            "initialized" => {
                // yapılandırma sırası: kesme noktaları → configurationDone
                let me = self.clone();
                std::thread::spawn(move || {
                    let paths: Vec<String> = me.0.bps.lock().unwrap().keys().cloned().collect();
                    for p in paths {
                        me.push_breakpoints(&p);
                    }
                    let _ = me.request("configurationDone", json!({}), TIMEOUT);
                    me.0.configured.store(true, Ordering::Relaxed);
                    me.0.st.lock().unwrap().running = true;
                    me.bump();
                });
            }
            "stopped" => {
                let mut st = self.0.st.lock().unwrap();
                st.running = false;
                st.thread = body.get("threadId").and_then(Value::as_i64);
                st.frame = None;
                st.reason = body.get("reason").and_then(Value::as_str).unwrap_or("stopped").to_string();
                st.description = body
                    .get("description")
                    .and_then(Value::as_str)
                    .or_else(|| body.get("text").and_then(Value::as_str))
                    .unwrap_or_default()
                    .to_string();
                drop(st);
                self.bump();
            }
            "continued" => {
                let mut st = self.0.st.lock().unwrap();
                st.running = true;
                st.thread = None;
                st.reason.clear();
                drop(st);
                self.bump();
            }
            "terminated" | "exited" => {
                let mut st = self.0.st.lock().unwrap();
                st.terminated = true;
                st.running = false;
                st.thread = None;
                if let Some(code) = body.get("exitCode").and_then(Value::as_i64) {
                    st.exit_code = Some(code);
                }
                drop(st);
                self.bump();
            }
            "output" => {
                let text = body.get("output").and_then(Value::as_str).unwrap_or_default();
                if text.is_empty() {
                    return;
                }
                let mut st = self.0.st.lock().unwrap();
                st.output.push(json!({
                    "category": body.get("category").and_then(Value::as_str).unwrap_or("console"),
                    "text": text,
                    "line": body.get("line").cloned().unwrap_or(Value::Null),
                    "path": body.pointer("/source/path").cloned().unwrap_or(Value::Null),
                }));
                if st.output.len() > OUTPUT_LIMIT {
                    let extra = st.output.len() - OUTPUT_LIMIT / 2;
                    st.output.drain(..extra);
                    st.dropped_output += extra;
                }
                drop(st);
                self.bump();
            }
            "breakpoint" => {
                if let Some(path) = body.pointer("/breakpoint/source/path").and_then(Value::as_str) {
                    let bp = body.get("breakpoint").cloned().unwrap_or(Value::Null);
                    let id = bp.get("id").and_then(Value::as_i64);
                    let mut st = self.0.st.lock().unwrap();
                    let list = st.verified.entry(path.to_string()).or_default();
                    match list.iter_mut().find(|b| b.get("id").and_then(Value::as_i64) == id && id.is_some()) {
                        Some(slot) => *slot = bp,
                        None => list.push(bp),
                    }
                    drop(st);
                    self.bump();
                }
            }
            "thread" => self.bump(),
            _ => {}
        }
    }

    fn send(&self, v: &Value) {
        if let Ok(mut w) = self.0.write.lock() {
            if write_message(&mut *w, v).is_err() {
                self.0.alive.store(false, Ordering::Relaxed);
            }
        }
    }

    pub fn request(&self, command: &str, arguments: Value, timeout: Duration) -> Result<Value, String> {
        if !self.is_alive() {
            return Err("debug adapter not running".into());
        }
        let seq = self.0.seq.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = channel();
        self.0.pending.lock().unwrap().insert(seq, tx);
        self.send(&json!({ "seq": seq, "type": "request", "command": command, "arguments": arguments }));
        match rx.recv_timeout(timeout) {
            Ok(r) => r,
            Err(_) => {
                self.0.pending.lock().unwrap().remove(&seq);
                Err("timeout".into())
            }
        }
    }

    // {state, reason, thread, name, exitCode, description}
    pub fn status(&self) -> Value {
        let st = self.0.st.lock().unwrap();
        let state = if st.terminated {
            "terminated"
        } else if st.thread.is_some() {
            "stopped"
        } else if st.running || self.0.configured.load(Ordering::Relaxed) {
            "running"
        } else {
            "starting"
        };
        json!({
            "state": state, "reason": st.reason, "description": st.description,
            "thread": st.thread, "frame": st.frame, "name": self.0.name,
            "exitCode": st.exit_code, "version": self.version(),
        })
    }

    pub fn capabilities(&self) -> Value {
        self.0.caps.lock().unwrap().clone()
    }

    // biriken çıktıyı boşaltır
    pub fn take_output(&self) -> Value {
        let mut st = self.0.st.lock().unwrap();
        let dropped = std::mem::take(&mut st.dropped_output);
        let mut items: Vec<Value> = std::mem::take(&mut st.output);
        if dropped > 0 {
            items.insert(0, json!({ "category": "console", "text": format!("… {dropped} satır atlandı\n") }));
        }
        Value::Array(items)
    }

    pub fn breakpoints(&self, path: &str) -> Value {
        Value::Array(self.0.st.lock().unwrap().verified.get(path).cloned().unwrap_or_default())
    }

    // satırlar 1 tabanlı; oturum yapılandırıldıysa hemen gönderilir
    pub fn set_breakpoints(&self, path: &str, lines: &[u32]) -> Value {
        if lines.is_empty() {
            self.0.bps.lock().unwrap().remove(path);
        } else {
            self.0.bps.lock().unwrap().insert(path.to_string(), lines.to_vec());
        }
        if self.0.configured.load(Ordering::Relaxed) {
            return self.push_breakpoints(path);
        }
        Value::Array(vec![])
    }

    fn push_breakpoints(&self, path: &str) -> Value {
        let lines = self.0.bps.lock().unwrap().get(path).cloned().unwrap_or_default();
        let name = Path::new(path).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let args = json!({
            "source": { "path": path, "name": name },
            "breakpoints": lines.iter().map(|l| json!({ "line": l })).collect::<Vec<_>>(),
            "lines": lines,
            "sourceModified": false,
        });
        let body = self.request("setBreakpoints", args, TIMEOUT).unwrap_or(Value::Null);
        let list = body.get("breakpoints").and_then(Value::as_array).cloned().unwrap_or_default();
        self.0.st.lock().unwrap().verified.insert(path.to_string(), list.clone());
        self.bump();
        Value::Array(list)
    }

    pub fn threads(&self) -> Result<Value, String> {
        Ok(self.request("threads", json!({}), TIMEOUT)?.get("threads").cloned().unwrap_or(Value::Array(vec![])))
    }

    // [{id, name, line, column, path, presentationHint}]
    pub fn stack_trace(&self, thread: i64) -> Result<Value, String> {
        let body = self.request("stackTrace", json!({ "threadId": thread, "startFrame": 0, "levels": 40 }), TIMEOUT)?;
        let frames: Vec<Value> = body
            .get("stackFrames")
            .and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .map(|f| {
                        json!({
                            "id": f.get("id").cloned().unwrap_or(Value::Null),
                            "name": f.get("name").cloned().unwrap_or(Value::Null),
                            "line": f.get("line").cloned().unwrap_or(json!(0)),
                            "column": f.get("column").cloned().unwrap_or(json!(0)),
                            "path": f.pointer("/source/path").cloned().unwrap_or(Value::Null),
                            "source": f.pointer("/source/name").cloned().unwrap_or(Value::Null),
                            "subtle": f.get("presentationHint").and_then(Value::as_str) == Some("subtle"),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();
        if let Some(first) = frames.first().and_then(|f| f.get("id")).and_then(Value::as_i64) {
            self.0.st.lock().unwrap().frame = Some(first);
        }
        Ok(Value::Array(frames))
    }

    pub fn scopes(&self, frame: i64) -> Result<Value, String> {
        Ok(self.request("scopes", json!({ "frameId": frame }), TIMEOUT)?.get("scopes").cloned().unwrap_or(Value::Array(vec![])))
    }

    pub fn variables(&self, reference: i64) -> Result<Value, String> {
        Ok(self
            .request("variables", json!({ "variablesReference": reference }), TIMEOUT)?
            .get("variables")
            .cloned()
            .unwrap_or(Value::Array(vec![])))
    }

    pub fn evaluate(&self, expr: &str, frame: Option<i64>, context: &str) -> Result<Value, String> {
        let mut args = json!({ "expression": expr, "context": context });
        if let (Some(f), Value::Object(o)) = (frame, &mut args) {
            o.insert("frameId".into(), json!(f));
        }
        self.request("evaluate", args, TIMEOUT)
    }

    pub fn set_variable(&self, reference: i64, name: &str, value: &str) -> Result<Value, String> {
        self.request("setVariable", json!({ "variablesReference": reference, "name": name, "value": value }), TIMEOUT)
    }

    pub fn select_frame(&self, frame: i64) {
        self.0.st.lock().unwrap().frame = Some(frame);
    }

    fn resume(&self, command: &str, thread: i64) -> Result<Value, String> {
        let arg =
            if command == "continue" { json!({ "threadId": thread }) } else { json!({ "threadId": thread, "granularity": "statement" }) };
        let r = self.request(command, arg, TIMEOUT)?;
        let mut st = self.0.st.lock().unwrap();
        st.running = true;
        st.thread = None;
        st.frame = None;
        st.reason.clear();
        drop(st);
        self.bump();
        Ok(r)
    }

    pub fn resume_all(&self, command: &str) -> Result<Value, String> {
        let thread = self.0.st.lock().unwrap().thread.unwrap_or(1);
        match command {
            "continue" | "next" | "stepIn" | "stepOut" => self.resume(command, thread),
            _ => Err(format!("unknown command {command}")),
        }
    }

    pub fn pause(&self) -> Result<Value, String> {
        let thread = self.0.st.lock().unwrap().thread.unwrap_or(1);
        self.request("pause", json!({ "threadId": thread }), TIMEOUT)
    }

    pub fn terminate(&self) {
        if self.is_alive() {
            let supports = self.capabilities().get("supportsTerminateRequest").and_then(Value::as_bool).unwrap_or(false);
            if supports {
                let _ = self.request("terminate", json!({ "restart": false }), Duration::from_secs(2));
            }
            let _ = self.request("disconnect", json!({ "restart": false, "terminateDebuggee": true }), Duration::from_secs(2));
        }
        self.kill();
    }

    fn kill(&self) {
        self.0.alive.store(false, Ordering::Relaxed);
        if let Some(mut child) = self.0.child.lock().unwrap().take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        let mut st = self.0.st.lock().unwrap();
        st.terminated = true;
        st.running = false;
        st.thread = None;
        drop(st);
        self.bump();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn jsonc_and_configs() {
        let dir = std::env::temp_dir().join(format!("kern-dap-cfg-{}", std::process::id()));
        std::fs::create_dir_all(dir.join(".kern")).unwrap();
        std::fs::write(
            dir.join(".kern/launch.json"),
            "{\n // yorum\n \"configurations\": [{ \"type\": \"lldb\", \"name\": \"app\", \"program\": \"/bin/ls\" }]\n}",
        )
        .unwrap();
        let cfg = load_configs(&dir);
        assert_eq!(cfg[0]["name"], "app");
        assert_eq!(cfg[0]["request"], "launch");
        assert_eq!(cfg[0]["source"], ".kern/launch.json");
        assert!(load_configs(Path::new("/tmp/kern-dap-yok")).as_array().unwrap().is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn framing_and_kinds() {
        let mut buf = Vec::new();
        write_message(&mut buf, &json!({ "type": "event" })).unwrap();
        let mut r = BufReader::new(&buf[..]);
        assert_eq!(read_message(&mut r).unwrap().unwrap(), json!({ "type": "event" }));
        assert_eq!(kind_for(Path::new("a.py")), Some("python"));
        assert_eq!(kind_for(Path::new("a.rs")), Some("lldb"));
        assert!(kind_for(Path::new("a.txt")).is_none());
        assert!(suggest_config(Path::new("/x/a.py")).unwrap()["program"] == json!("/x/a.py"));
        assert!(adapter_status("ruby").starts_with("unsupported"));
    }

    // lldb-dap kuruluysa uçtan uca: kesme noktası, dur, değişken, adımla
    #[test]
    fn lldb_end_to_end() {
        let Some(cc) = which("clang") else { return };
        if which("lldb-dap").is_none() {
            return;
        }
        let dir = std::env::temp_dir().join(format!("kern-dap-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let src = dir.join("main.c");
        std::fs::write(&src, "#include <stdio.h>\nint main(void) {\n  int total = 0;\n  for (int i = 1; i <= 3; i++) total += i;\n  printf(\"total=%d\\n\", total);\n  return 0;\n}\n").unwrap();
        let exe = dir.join("main");
        let built = Command::new(cc).args(["-g", "-O0"]).arg(&src).arg("-o").arg(&exe).status();
        if !built.map(|s| s.success()).unwrap_or(false) {
            let _ = std::fs::remove_dir_all(&dir);
            return;
        }
        let config = json!({ "name": "c", "type": "lldb", "request": "launch", "program": exe, "cwd": dir });
        let bps = json!({ src.to_string_lossy(): [5] });
        let s = Session::start(&dir, &config, &bps).expect("oturum");
        let deadline = std::time::Instant::now() + Duration::from_secs(25);
        while s.status()["state"] != json!("stopped") {
            assert!(std::time::Instant::now() < deadline, "durmadı: {}", s.status());
            std::thread::sleep(Duration::from_millis(100));
        }
        let thread = s.status()["thread"].as_i64().unwrap();
        let frames = s.stack_trace(thread).unwrap();
        assert_eq!(frames[0]["line"], 5);
        assert_eq!(frames[0]["name"], "main");
        let scopes = s.scopes(frames[0]["id"].as_i64().unwrap()).unwrap();
        let vars = s.variables(scopes[0]["variablesReference"].as_i64().unwrap()).unwrap();
        assert!(vars.to_string().contains("total"), "{vars}");
        let ev = s.evaluate("total", frames[0]["id"].as_i64(), "watch").unwrap();
        assert_eq!(ev["result"], "6");
        s.resume_all("continue").unwrap();
        let deadline = std::time::Instant::now() + Duration::from_secs(20);
        while s.status()["state"] != json!("terminated") {
            assert!(std::time::Instant::now() < deadline, "bitmedi: {}", s.status());
            std::thread::sleep(Duration::from_millis(100));
        }
        assert!(s.take_output().to_string().contains("total=6"));
        s.terminate();
        let _ = std::fs::remove_dir_all(&dir);
    }
}
