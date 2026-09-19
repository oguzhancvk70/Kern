use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use ignore::WalkBuilder;
use kern_text::Matcher;
pub use kern_text::{FIND_CASE, FIND_REGEX, FIND_WORD};

const MAX_FILES: usize = 200_000;
const MAX_SEARCH_BYTES: u64 = 64 * 1024 * 1024;

pub struct Hit {
    pub path: String,
    pub line: usize,
    pub col16: usize,
    pub len16: usize,
    pub text: String,
    // text içinde eşleşmenin başladığı UTF-16 sütunu
    pub preview_col16: usize,
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

    // arka planda, çok iş parçacıklı arama; sonuçlar geldikçe `take` ile alınır
    pub fn search_stream(&self, query: &str, flags: u8, limit: usize) -> Result<SearchJob, String> {
        let matcher = Arc::new(Matcher::new(query, flags)?);
        let job = SearchJob::default();
        let files = Arc::new(self.files.clone());
        let root = Arc::new(self.root.clone());
        let next = Arc::new(AtomicUsize::new(0));
        let threads = std::thread::available_parallelism().map_or(4, |n| n.get()).min(8);
        let running = Arc::new(AtomicUsize::new(threads));
        for _ in 0..threads {
            let (files, root, next, matcher, running) = (files.clone(), root.clone(), next.clone(), matcher.clone(), running.clone());
            let (hits, count, cancel, done) = (job.hits.clone(), job.count.clone(), job.cancel.clone(), job.done.clone());
            std::thread::spawn(move || {
                loop {
                    let i = next.fetch_add(1, Ordering::Relaxed);
                    if i >= files.len() || cancel.load(Ordering::Relaxed) || count.load(Ordering::Relaxed) >= limit {
                        break;
                    }
                    let found = search_file(&root.join(&files[i]), &files[i], &matcher);
                    if !found.is_empty() {
                        let n = count.fetch_add(found.len(), Ordering::Relaxed);
                        let take = found.len().min(limit.saturating_sub(n));
                        hits.lock().unwrap().extend(found.into_iter().take(take));
                    }
                }
                if running.fetch_sub(1, Ordering::AcqRel) == 1 {
                    done.store(true, Ordering::Release);
                }
            });
        }
        Ok(job)
    }

    // eşzamanlı sarmalayıcı (testler ve CLI için)
    pub fn search(&self, query: &str, flags: u8, limit: usize) -> Vec<Hit> {
        let Ok(job) = self.search_stream(query, flags, limit) else { return Vec::new() };
        let mut out = Vec::new();
        while !job.is_done() {
            out.extend(job.take());
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        out.extend(job.take());
        out.sort_by(|a, b| a.path.cmp(&b.path).then(a.line.cmp(&b.line)));
        out
    }
}

#[derive(Default)]
pub struct SearchJob {
    hits: Arc<Mutex<Vec<Hit>>>,
    count: Arc<AtomicUsize>,
    cancel: Arc<AtomicBool>,
    done: Arc<AtomicBool>,
}

impl SearchJob {
    pub fn take(&self) -> Vec<Hit> {
        std::mem::take(&mut *self.hits.lock().unwrap())
    }

    pub fn is_done(&self) -> bool {
        self.done.load(Ordering::Acquire)
    }

    pub fn cancel(&self) {
        self.cancel.store(true, Ordering::Relaxed);
    }

    pub fn total(&self) -> usize {
        self.count.load(Ordering::Relaxed)
    }
}

impl Drop for SearchJob {
    fn drop(&mut self) {
        self.cancel();
    }
}

fn search_file(path: &Path, rel: &str, m: &Matcher) -> Vec<Hit> {
    let mut out = Vec::new();
    if std::fs::metadata(path).map_or(true, |md| md.len() > MAX_SEARCH_BYTES) {
        return out;
    }
    let Ok(bytes) = std::fs::read(path) else { return out };
    if bytes[..bytes.len().min(8000)].contains(&0) {
        return out;
    }
    let text = String::from_utf8_lossy(&bytes);
    for (i, line) in text.lines().enumerate() {
        for r in m.find(line) {
            let col16 = line[..r.start].encode_utf16().count();
            let len16 = line[r.clone()].encode_utf16().count();
            // uzun satırda eşleşme civarını göster
            let from = line[..r.start].char_indices().rev().nth(60).map_or(0, |(b, _)| b);
            let shown: String = line[from..].chars().take(240).collect();
            let shift = line[from..r.start].encode_utf16().count();
            out.push(Hit { path: rel.to_string(), line: i, col16, len16, text: shown, preview_col16: shift });
            if out.len() >= 1000 {
                return out;
            }
        }
    }
    out
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
        let hits = w.search("fn fuzzy_score", FIND_CASE, 10);
        assert!(hits.iter().any(|h| h.path == "src/lib.rs" && h.col16 == 0));
        let hits = w.search(r"fn \w+_score\(", FIND_REGEX | FIND_CASE, 10);
        assert!(hits.iter().any(|h| h.text.starts_with("fn fuzzy_score(")));
        let job = w.search_stream("the", 0, 3).unwrap();
        while !job.is_done() {
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        assert!(job.take().len() <= 3);
    }
}
