use std::process::{Command, ExitCode};

const BUNDLE_ID: &str = "dev.kern.Kern";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.iter().any(|a| a == "-v" || a == "--version") {
        println!("kern {}", env!("CARGO_PKG_VERSION"));
        return ExitCode::SUCCESS;
    }

    // olmayan dosya: boş oluştur, open -b bunu ister
    for path in args.iter().filter(|a| !a.starts_with('-')) {
        let p = std::path::Path::new(path);
        if !p.exists() {
            if let Err(e) = std::fs::File::create(p) {
                eprintln!("kern: {path}: {e}");
                return ExitCode::FAILURE;
            }
        }
    }

    let status = Command::new("open").args(["-b", BUNDLE_ID]).args(&args).status();
    match status {
        Ok(s) if s.success() => ExitCode::SUCCESS,
        _ => {
            eprintln!("kern: Kern.app açılamadı ({BUNDLE_ID})");
            ExitCode::FAILURE
        }
    }
}
