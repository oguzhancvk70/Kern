use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

const USAGE: &str = "kullanım: kern [-n | -r] [yol[:satır[:sütun]] ...]
  -n, --new-window   yeni pencerede aç
  -r, --reuse-window son pencerede aç
  -v, --version      sürüm";

fn encode(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' | b'/' => (b as char).to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

// "dosya.rs:12:3" → (yol, satır, sütun); yol gerçekten varsa olduğu gibi bırak
fn split_location(arg: &str) -> (String, Option<u32>, Option<u32>) {
    if Path::new(arg).exists() {
        return (arg.to_string(), None, None);
    }
    let parts: Vec<&str> = arg.rsplitn(3, ':').collect();
    match parts.as_slice() {
        [c, l, p] if l.parse::<u32>().is_ok() && c.parse::<u32>().is_ok() => (p.to_string(), l.parse().ok(), c.parse().ok()),
        [l, p] if l.parse::<u32>().is_ok() => (p.to_string(), l.parse().ok(), None),
        [c, l, p] if c.parse::<u32>().is_ok() => (format!("{p}:{l}"), c.parse().ok(), None),
        _ => (arg.to_string(), None, None),
    }
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.iter().any(|a| a == "-v" || a == "--version") {
        println!("kern {}", env!("CARGO_PKG_VERSION"));
        return ExitCode::SUCCESS;
    }
    if args.iter().any(|a| a == "-h" || a == "--help") {
        println!("{USAGE}");
        return ExitCode::SUCCESS;
    }
    let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    let mut query = Vec::new();
    for a in &args {
        match a.as_str() {
            "-n" | "--new-window" => query.push("new=1".to_string()),
            "-r" | "--reuse-window" => query.push("reuse=1".to_string()),
            s if s.starts_with('-') => {
                eprintln!("kern: bilinmeyen seçenek {s}\n{USAGE}");
                return ExitCode::FAILURE;
            }
            s => {
                let (path, line, col) = split_location(s);
                let abs = cwd.join(&path);
                // olmayan dosya: boş oluştur
                if !abs.exists() {
                    if let Err(e) = std::fs::File::create(&abs) {
                        eprintln!("kern: {path}: {e}");
                        return ExitCode::FAILURE;
                    }
                }
                let abs = abs.canonicalize().unwrap_or(abs);
                // satır/sütun, kendinden önceki yola uygulanır
                query.push(format!("path={}", encode(&abs.to_string_lossy())));
                if let Some(l) = line {
                    query.push(format!("line={l}"));
                }
                if let Some(c) = col {
                    query.push(format!("col={c}"));
                }
            }
        }
    }
    // Kern terminalinden çağrıldıysa o pencereyi hedefle
    if let Ok(w) = std::env::var("KERN_WINDOW") {
        query.push(format!("window={}", encode(&w)));
    }
    let url = format!("kern://open?{}", query.join("&"));
    match Command::new("open").arg(&url).status() {
        Ok(s) if s.success() => ExitCode::SUCCESS,
        _ => {
            eprintln!("kern: Kern.app açılamadı");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_locations_and_encodes() {
        assert_eq!(split_location("nope.rs:12"), ("nope.rs".into(), Some(12), None));
        assert_eq!(split_location("nope.rs:12:3"), ("nope.rs".into(), Some(12), Some(3)));
        assert_eq!(split_location("nope.rs"), ("nope.rs".into(), None, None));
        assert_eq!(encode("/a b/ç"), "/a%20b/%C3%A7");
    }
}
