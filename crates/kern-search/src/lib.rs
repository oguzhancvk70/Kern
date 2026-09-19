use std::path::{Path, PathBuf};

use ignore::WalkBuilder;

const MAX_FILES: usize = 200_000;
const MAX_SEARCH_BYTES: u64 = 4 * 1024 * 1024;

pub struct Hit {
    pub path: String,
    pub line: usize,
    pub col16: usize,
    pub len16: usize,
    pub text: String,
}

pub struct Workspace {
    root: PathBuf,
    files: Vec<String>,
}

impl Workspace {
    pub fn open(root: impl AsRef<Path>) -> Self {
        let mut w = Self { root: root.as_ref().to_path_buf(), files: Vec::new() };
        w.refresh();
        w
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn files(&self) -> &[String] {
        &self.files
    }

    pub fn refresh(&mut self) {
        let walker = WalkBuilder::new(&self.root)
            .hidden(false)
            .require_git(false)
            .filter_entry(|e| e.file_name() != ".git" && e.file_name() != ".DS_Store")
            .build();
        let mut files = Vec::new();
        for entry in walker.flatten() {
            if entry.file_type().is_some_and(|t| t.is_file()) {
                if let Ok(rel) = entry.path().strip_prefix(&self.root) {
                    files.push(rel.to_string_lossy().into_owned());
                }
                if files.len() >= MAX_FILES {
                    break;
                }
            }
        }
        files.sort();
        self.files = files;
    }

    // alt dizi eşleşmesi; dosya adında ve ardışık eşleşmede ödül
    pub fn quick_open(&self, query: &str, limit: usize) -> Vec<&str> {
        let q: Vec<char> = query.chars().filter(|c| !c.is_whitespace()).flat_map(char::to_lowercase).collect();
        if q.is_empty() {
            return self.files.iter().take(limit).map(String::as_str).collect();
        }
        let mut scored: Vec<(i64, &str)> =
            self.files.iter().filter_map(|f| fuzzy_score(f, &q).map(|s| (s, f.as_str()))).collect();
        scored.sort_by(|a, b| b.0.cmp(&a.0).then(a.1.len().cmp(&b.1.len())));
        scored.into_iter().take(limit).map(|(_, f)| f).collect()
    }

    pub fn search(&self, query: &str, case: bool, limit: usize) -> Vec<Hit> {
        let mut hits = Vec::new();
        if query.is_empty() {
            return hits;
        }
        let needle = if case { query.to_string() } else { query.to_ascii_lowercase() };
        for rel in &self.files {
            let path = self.root.join(rel);
            if std::fs::metadata(&path).map_or(true, |m| m.len() > MAX_SEARCH_BYTES) {
                continue;
            }
            let Ok(bytes) = std::fs::read(&path) else { continue };
            if bytes[..bytes.len().min(8000)].contains(&0) {
                continue;
            }
            let text = String::from_utf8_lossy(&bytes);
            for (i, line) in text.lines().enumerate() {
                let hay = if case { line.to_string() } else { line.to_ascii_lowercase() };
                let Some(pos) = hay.find(&needle) else { continue };
                let col16 = line[..pos].encode_utf16().count();
                let len16 = line[pos..pos + needle.len()].encode_utf16().count();
                let trimmed: String = line.chars().take(240).collect();
                hits.push(Hit { path: rel.clone(), line: i, col16, len16, text: trimmed });
                if hits.len() >= limit {
                    return hits;
                }
            }
        }
        hits
    }
}

fn fuzzy_score(path: &str, q: &[char]) -> Option<i64> {
    let lower: Vec<char> = path.chars().flat_map(char::to_lowercase).collect();
    let name_start = lower.iter().rposition(|c| *c == '/').map_or(0, |i| i + 1);
    let mut score = 0i64;
    let mut qi = 0;
    let mut prev: Option<usize> = None;
    for (i, c) in lower.iter().enumerate() {
        if qi < q.len() && *c == q[qi] {
            score += 1;
            if prev == Some(i.wrapping_sub(1)) {
                score += 5;
            }
            if i >= name_start {
                score += 3;
            }
            if i == name_start || (i > 0 && matches!(lower[i - 1], '/' | '_' | '-' | '.')) {
                score += 4;
            }
            prev = Some(i);
            qi += 1;
        }
    }
    (qi == q.len()).then_some(score - lower.len() as i64 / 8)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fuzzy_prefers_filename() {
        let q: Vec<char> = "edit".chars().collect();
        let a = fuzzy_score("src/editor.rs", &q).unwrap();
        let b = fuzzy_score("e/d/i/t/x.rs", &q).unwrap();
        assert!(a > b);
        assert!(fuzzy_score("abc", &q).is_none());
    }

    #[test]
    fn walks_and_searches_this_crate() {
        let w = Workspace::open(env!("CARGO_MANIFEST_DIR"));
        assert!(w.files().iter().any(|f| f == "src/lib.rs"));
        assert_eq!(w.quick_open("lib", 1), vec!["src/lib.rs"]);
        let hits = w.search("fn fuzzy_score", true, 10);
        assert!(hits.iter().any(|h| h.path == "src/lib.rs" && h.col16 == 0));
    }
}
