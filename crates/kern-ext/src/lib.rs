// eklenti sistemi: manifest (bildirimsel katkılar) + wasm modülü (komutlar), izin ve kaynak sınırlı
use std::path::{Path, PathBuf};

use serde_json::{Map, Value, json};
use wasmtime::{Caller, Config, Engine, Linker, Module, Store, StoreLimits, StoreLimitsBuilder};

pub const MANIFEST: &str = "kern-extension.json";
const FUEL: u64 = 200_000_000;
const MEMORY_LIMIT: usize = 64 << 20;

pub struct Extension {
    pub dir: PathBuf,
    pub manifest: Value,
    pub id: String,
    pub permissions: Vec<String>,
    module: Option<Module>,
}

impl Extension {
    pub fn allows(&self, p: &str) -> bool {
        self.permissions.iter().any(|x| x == p)
    }
}

pub struct Registry {
    engine: Engine,
    pub extensions: Vec<Extension>,
    pub errors: Vec<(PathBuf, String)>,
}

// komutun görebildiği editör durumu ve ürettiği eylemler
struct State {
    ctx: Map<String, Value>,
    permissions: Vec<String>,
    root: PathBuf,
    actions: Vec<Value>,
    logs: Vec<String>,
    limits: StoreLimits,
    denied: Option<String>,
}

pub const KNOWN_PERMISSIONS: &[&str] = &["editor:read", "editor:write", "fs:read", "ui"];

pub fn validate_manifest(m: &Value) -> Result<(), String> {
    let id = m.get("id").and_then(Value::as_str).ok_or("manifest: missing \"id\"")?;
    if id.is_empty() || !id.chars().all(|c| c.is_ascii_alphanumeric() || "._-".contains(c)) {
        return Err(format!("manifest: invalid id \"{id}\""));
    }
    m.get("name").and_then(Value::as_str).ok_or("manifest: missing \"name\"")?;
    m.get("version").and_then(Value::as_str).ok_or("manifest: missing \"version\"")?;
    for p in m.get("permissions").and_then(Value::as_array).into_iter().flatten() {
        let p = p.as_str().unwrap_or("");
        if !KNOWN_PERMISSIONS.contains(&p) {
            return Err(format!("manifest: unknown permission \"{p}\""));
        }
    }
    Ok(())
}

impl Registry {
    pub fn new() -> Self {
        let mut config = Config::new();
        config.consume_fuel(true);
        Self { engine: Engine::new(&config).expect("wasm engine"), extensions: Vec::new(), errors: Vec::new() }
    }

    // birden çok kök dizin (paket içi + kullanıcı); aynı id'de sonraki kazanır
    pub fn load(&mut self, roots: &[PathBuf]) {
        self.extensions.clear();
        self.errors.clear();
        for root in roots {
            let Ok(entries) = std::fs::read_dir(root) else { continue };
            let mut dirs: Vec<PathBuf> = entries.flatten().map(|e| e.path()).filter(|p| p.join(MANIFEST).is_file()).collect();
            dirs.sort();
            for dir in dirs {
                match self.load_one(&dir) {
                    Ok(ext) => {
                        self.extensions.retain(|e| e.id != ext.id);
                        self.extensions.push(ext);
                    }
                    Err(e) => self.errors.push((dir, e)),
                }
            }
        }
    }

    pub fn load_one(&self, dir: &Path) -> Result<Extension, String> {
        let text = std::fs::read_to_string(dir.join(MANIFEST)).map_err(|e| e.to_string())?;
        let manifest: Value = serde_json::from_str(&text).map_err(|e| format!("manifest: {e}"))?;
        validate_manifest(&manifest)?;
        let id = manifest["id"].as_str().unwrap_or_default().to_string();
        let permissions = manifest
            .get("permissions")
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(Value::as_str).map(str::to_string).collect())
            .unwrap_or_default();
        let module = match manifest.get("main").and_then(Value::as_str) {
            Some(main) => {
                let path = dir.join(main);
                if !path.starts_with(dir) {
                    return Err("main must be inside the extension folder".into());
                }
                Some(Module::from_file(&self.engine, &path).map_err(|e| format!("{main}: {e}"))?)
            }
            None => None,
        };
        Ok(Extension { dir: dir.to_path_buf(), manifest, id, permissions, module })
    }

    // tüm eklentilerin katkıları: {commands:[{extension,id,title}], themes:[], snippets:{lang:[]}, languageServers:{}, keybindings:[]}
    pub fn contributions(&self) -> Value {
        let mut commands = Vec::new();
        let mut themes = Vec::new();
        let mut snippets = Map::new();
        let mut servers = Map::new();
        let mut keys = Vec::new();
        for e in &self.extensions {
            let c = &e.manifest["contributes"];
            for cmd in c["commands"].as_array().into_iter().flatten() {
                if e.module.is_some() {
                    let mut cmd = cmd.clone();
                    cmd["extension"] = json!(e.id);
                    commands.push(cmd);
                }
            }
            for t in c["themes"].as_array().into_iter().flatten() {
                let mut t = t.clone();
                t["extension"] = json!(e.id);
                themes.push(t);
            }
            for (lang, list) in c["snippets"].as_object().into_iter().flatten() {
                let entry = snippets.entry(lang.clone()).or_insert_with(|| json!([]));
                if let (Some(dst), Some(src)) = (entry.as_array_mut(), list.as_array()) {
                    dst.extend(src.iter().cloned());
                }
            }
            for (k, v) in c["languageServers"].as_object().into_iter().flatten() {
                servers.insert(k.clone(), v.clone());
            }
            for kb in c["keybindings"].as_array().into_iter().flatten() {
                let mut kb = kb.clone();
                if let Some(cmd) = kb["command"].as_str() {
                    if !cmd.contains(':') {
                        kb["command"] = json!(format!("ext:{}:{}", e.id, cmd));
                    }
                }
                keys.push(kb);
            }
        }
        json!({ "commands": commands, "themes": themes, "snippets": snippets, "languageServers": servers, "keybindings": keys })
    }

    // komutu çalıştır: {actions:[...], logs:[...], error?}
    pub fn run_command(&self, ext_id: &str, command: &str, ctx: Value, root: &Path) -> Value {
        let Some(ext) = self.extensions.iter().find(|e| e.id == ext_id) else {
            return json!({ "error": format!("unknown extension {ext_id}") });
        };
        let Some(module) = &ext.module else { return json!({ "error": "extension has no code" }) };
        // izin yoksa editör metni hiç verilmez
        let mut ctx = ctx.as_object().cloned().unwrap_or_default();
        if !ext.allows("editor:read") {
            ctx.retain(|k, _| k == "path" || k == "language");
        }
        let state = State {
            ctx,
            permissions: ext.permissions.clone(),
            root: root.to_path_buf(),
            actions: Vec::new(),
            logs: Vec::new(),
            limits: StoreLimitsBuilder::new().memory_size(MEMORY_LIMIT).instances(1).build(),
            denied: None,
        };
        let mut store = Store::new(&self.engine, state);
        store.limiter(|s| &mut s.limits);
        let _ = store.set_fuel(FUEL);
        let result = (|| -> Result<i32, String> {
            let linker = host_linker(&self.engine).map_err(|e| e.to_string())?;
            let instance = linker.instantiate(&mut store, module).map_err(|e| e.to_string())?;
            let memory = instance.get_memory(&mut store, "memory").ok_or("module does not export memory")?;
            let alloc = instance.get_typed_func::<i32, i32>(&mut store, "kern_alloc").map_err(|e| e.to_string())?;
            let run = instance.get_typed_func::<(i32, i32), i32>(&mut store, "kern_command").map_err(|e| e.to_string())?;
            let bytes = command.as_bytes();
            let ptr = alloc.call(&mut store, bytes.len() as i32).map_err(|e| e.to_string())?;
            memory.write(&mut store, ptr as usize, bytes).map_err(|e| e.to_string())?;
            run.call(&mut store, (ptr, bytes.len() as i32)).map_err(|e| {
                if store.get_fuel().map_or(false, |f| f == 0) { "extension ran too long and was stopped".to_string() } else { format!("{e:#}") }
            })
        })();
        let s = store.data();
        let mut out = json!({ "actions": s.actions, "logs": s.logs });
        match result {
            Ok(code) if code != 0 => out["error"] = json!(format!("command returned {code}")),
            Ok(_) => {}
            Err(e) => out["error"] = json!(e),
        }
        if let Some(d) = &s.denied {
            out["error"] = json!(format!("permission denied: {d}"));
        }
        out
    }
}

impl Default for Registry {
    fn default() -> Self {
        Self::new()
    }
}

fn read_str(caller: &mut Caller<'_, State>, ptr: i32, len: i32) -> Option<String> {
    let mem = caller.get_export("memory")?.into_memory()?;
    let data = mem.data(&caller);
    let (s, e) = (ptr as usize, ptr as usize + len as usize);
    (e <= data.len()).then(|| String::from_utf8_lossy(&data[s..e]).into_owned())
}

// değeri tampona yaz; toplam uzunluğu döndür (tampon küçükse yazmaz)
fn write_out(caller: &mut Caller<'_, State>, bytes: &[u8], ptr: i32, cap: i32) -> i32 {
    if bytes.len() <= cap as usize {
        if let Some(mem) = caller.get_export("memory").and_then(|e| e.into_memory()) {
            if mem.write(&mut *caller, ptr as usize, bytes).is_err() {
                return -3;
            }
        }
    }
    bytes.len() as i32
}

fn host_linker(engine: &Engine) -> wasmtime::Result<Linker<State>> {
    let mut l = Linker::new(engine);
    l.func_wrap("kern", "log", |mut c: Caller<'_, State>, p: i32, n: i32| {
        if let Some(s) = read_str(&mut c, p, n) {
            c.data_mut().logs.push(s);
        }
    })?;
    // ctx_get("text" | "selection" | "path" | "language", buf, cap) -> uzunluk
    l.func_wrap("kern", "ctx_get", |mut c: Caller<'_, State>, kp: i32, kn: i32, bp: i32, cap: i32| -> i32 {
        let Some(key) = read_str(&mut c, kp, kn) else { return -1 };
        let val = c.data().ctx.get(&key).and_then(Value::as_str).unwrap_or("").to_string();
        write_out(&mut c, val.as_bytes(), bp, cap)
    })?;
    // read_file(yol, buf, cap) -> uzunluk | -1 izin yok | -2 okunamadı
    l.func_wrap("kern", "read_file", |mut c: Caller<'_, State>, pp: i32, pn: i32, bp: i32, cap: i32| -> i32 {
        if !c.data().permissions.iter().any(|p| p == "fs:read") {
            c.data_mut().denied = Some("fs:read".into());
            return -1;
        }
        let Some(rel) = read_str(&mut c, pp, pn) else { return -2 };
        let root = c.data().root.clone();
        let path = root.join(&rel);
        let ok = path.canonicalize().ok().zip(root.canonicalize().ok()).is_some_and(|(p, r)| p.starts_with(r));
        let Some(bytes) = ok.then(|| std::fs::read(&path).ok()).flatten() else { return -2 };
        write_out(&mut c, &bytes, bp, cap)
    })?;
    // action(tür, değer): replace_selection | insert (editor:write), status | message (ui)
    l.func_wrap("kern", "action", |mut c: Caller<'_, State>, kp: i32, kn: i32, vp: i32, vn: i32| -> i32 {
        let (Some(kind), Some(val)) = (read_str(&mut c, kp, kn), read_str(&mut c, vp, vn)) else { return -2 };
        let need = match kind.as_str() {
            "replace_selection" | "insert" => "editor:write",
            "status" | "message" => "ui",
            _ => return -2,
        };
        if !c.data().permissions.iter().any(|p| p == need) {
            c.data_mut().denied = Some(need.into());
            return -1;
        }
        c.data_mut().actions.push(json!({ "kind": kind, "value": val }));
        0
    })?;
    Ok(l)
}

#[cfg(test)]
mod tests {
    use super::*;

    // seçimi ASCII büyük harfe çeviren WAT eklentisi
    pub const UPPER_WAT: &str = r#"
    (module
      (import "kern" "ctx_get" (func $ctx_get (param i32 i32 i32 i32) (result i32)))
      (import "kern" "action" (func $action (param i32 i32 i32 i32) (result i32)))
      (import "kern" "log" (func $log (param i32 i32)))
      (memory (export "memory") 2)
      (data (i32.const 0) "selection")
      (data (i32.const 16) "replace_selection")
      (data (i32.const 48) "loop")
      (global $heap (mut i32) (i32.const 1024))
      (func (export "kern_alloc") (param $n i32) (result i32)
        (local $p i32)
        (local.set $p (global.get $heap))
        (global.set $heap (i32.add (global.get $heap) (local.get $n)))
        (local.get $p))
      (func (export "kern_command") (param $id i32) (param $idn i32) (result i32)
        (local $len i32) (local $i i32) (local $c i32)
        ;; "loop" komutu: sonsuz döngü (yakıt sınırı testi)
        (if (i32.eq (i32.load8_u (local.get $id)) (i32.const 108))
          (then (loop $forever (br $forever))))
        (local.set $len (call $ctx_get (i32.const 0) (i32.const 9) (i32.const 4096) (i32.const 60000)))
        (if (i32.gt_s (local.get $len) (i32.const 60000)) (then (return (i32.const 1))))
        (block $done
          (loop $next
            (br_if $done (i32.ge_u (local.get $i) (local.get $len)))
            (local.set $c (i32.load8_u (i32.add (i32.const 4096) (local.get $i))))
            (if (i32.and (i32.ge_u (local.get $c) (i32.const 97)) (i32.le_u (local.get $c) (i32.const 122)))
              (then (i32.store8 (i32.add (i32.const 4096) (local.get $i)) (i32.sub (local.get $c) (i32.const 32)))))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $next)))
        (call $log (i32.const 48) (i32.const 4))
        (drop (call $action (i32.const 16) (i32.const 17) (i32.const 4096) (local.get $len)))
        (i32.const 0)))
    "#;

    fn install(root: &Path, id: &str, perms: &[&str]) -> PathBuf {
        let dir = root.join(id);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("ext.wat"), UPPER_WAT).unwrap();
        let m = json!({
            "id": id, "name": "Upper", "version": "1.0.0", "main": "ext.wat", "permissions": perms,
            "contributes": {
                "commands": [{ "id": "upper", "title": "Uppercase" }],
                "themes": [{ "name": "Test Theme", "type": "dark", "colors": { "background": "#101010" } }],
                "snippets": { "Rust": [{ "prefix": "fnm", "body": "fn main() {\n    $0\n}" }] },
                "languageServers": { "python": "pylsp" },
                "keybindings": [{ "key": "cmd+shift+u", "command": "upper" }]
            }
        });
        std::fs::write(dir.join(MANIFEST), m.to_string()).unwrap();
        dir
    }

    #[test]
    fn runs_commands_with_permissions_and_limits() {
        let root = std::env::temp_dir().join(format!("kern-ext-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        install(&root, "test.upper", &["editor:read", "editor:write"]);
        install(&root, "test.nowrite", &["editor:read"]);
        let bad = root.join("bad");
        std::fs::create_dir_all(&bad).unwrap();
        std::fs::write(bad.join(MANIFEST), r#"{"id":"bad","name":"x","version":"1","permissions":["net"]}"#).unwrap();
        let mut reg = Registry::new();
        reg.load(&[root.clone()]);
        assert_eq!(reg.extensions.len(), 2);
        assert!(reg.errors[0].1.contains("unknown permission"));

        let ctx = json!({ "text": "hello world", "selection": "hello", "path": "a.rs" });
        let out = reg.run_command("test.upper", "upper", ctx.clone(), &root);
        assert_eq!(out["actions"][0], json!({ "kind": "replace_selection", "value": "HELLO" }), "{out}");
        assert_eq!(out["logs"][0], "loop");
        assert!(out.get("error").is_none());

        let out = reg.run_command("test.nowrite", "upper", ctx.clone(), &root);
        assert!(out["error"].as_str().unwrap().contains("editor:write"));
        assert!(out["actions"].as_array().unwrap().is_empty());

        let t = std::time::Instant::now();
        let out = reg.run_command("test.upper", "loop", ctx, &root);
        assert!(out["error"].as_str().unwrap().contains("too long"), "{out}");
        assert!(t.elapsed().as_secs() < 10);

        let c = reg.contributions();
        assert_eq!(c["commands"].as_array().unwrap().len(), 2);
        assert_eq!(c["snippets"]["Rust"].as_array().unwrap().len(), 2);
        assert_eq!(c["languageServers"]["python"], "pylsp");
        assert_eq!(c["keybindings"][0]["command"], "ext:test.nowrite:upper");
        let _ = std::fs::remove_dir_all(&root);
    }
}
