// git: durum/stage/commit/push/dallar/blame git CLI ile; satır farkları ve çakışmalar burada
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use similar::{DiffOp, TextDiff};

pub struct Repo {
    pub root: PathBuf,
}

#[derive(Debug, Clone, PartialEq)]
pub struct FileStatus {
    pub path: String,
    pub index: char,
    pub worktree: char,
}

// gutter işaretleri: (satır, adet, tür) — 'A' eklendi, 'M' değişti, 'D' silindi (satırın üstünde)
pub type LineChange = (usize, usize, char);

fn git(dir: &Path, args: &[&str]) -> Result<String, String> {
    git_input(dir, args, None)
}

fn git_input(dir: &Path, args: &[&str], input: Option<&str>) -> Result<String, String> {
    let mut cmd = Command::new("git");
    cmd.args(args).current_dir(dir).env("GIT_TERMINAL_PROMPT", "0").env("LC_ALL", "C");
    cmd.stdin(if input.is_some() { Stdio::piped() } else { Stdio::null() }).stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = cmd.spawn().map_err(|e| format!("git: {e}"))?;
    if let (Some(text), Some(mut stdin)) = (input, child.stdin.take()) {
        let text = text.to_string();
        std::thread::spawn(move || {
            let _ = stdin.write_all(text.as_bytes());
        });
    }
    let out = child.wait_with_output().map_err(|e| e.to_string())?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    } else {
        let err = String::from_utf8_lossy(&out.stderr).trim().to_string();
        Err(if err.is_empty() { format!("git {} failed", args.first().unwrap_or(&"")) } else { err })
    }
}

impl Repo {
    pub fn discover(path: &Path) -> Option<Repo> {
        let dir = if path.is_dir() { path } else { path.parent()? };
        let top = git(dir, &["rev-parse", "--show-toplevel"]).ok()?;
        Some(Repo { root: PathBuf::from(top.trim()) })
    }

    fn rel(&self, path: &Path) -> String {
        let p = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
        let r = self.root.canonicalize().unwrap_or_else(|_| self.root.clone());
        p.strip_prefix(&r).unwrap_or(&p).to_string_lossy().into_owned()
    }

    // HEAD'deki içerik (yeni/izlenmeyen dosyada None)
    pub fn head_text(&self, path: &Path) -> Option<String> {
        git(&self.root, &["show", &format!("HEAD:{}", self.rel(path))]).ok()
    }

    pub fn status(&self) -> Result<Vec<FileStatus>, String> {
        // --no-optional-locks: index'i tazelemek için yazma yapılmaz, yoksa FSEvents → status döngüsü
        let out = git(&self.root, &["--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=all"])?;
        let mut items = Vec::new();
        let mut parts = out.split('\0');
        while let Some(entry) = parts.next() {
            if entry.len() < 4 {
                continue;
            }
            let b = entry.as_bytes();
            let (x, y) = (b[0] as char, b[1] as char);
            // yeniden adlandırmada eski yol ayrı parça olarak gelir
            if x == 'R' || x == 'C' {
                parts.next();
            }
            items.push(FileStatus { path: entry[3..].to_string(), index: x, worktree: y });
        }
        Ok(items)
    }

    pub fn branch(&self) -> String {
        git(&self.root, &["rev-parse", "--abbrev-ref", "HEAD"]).map(|s| s.trim().to_string()).unwrap_or_default()
    }

    pub fn branches(&self) -> Result<Vec<String>, String> {
        Ok(git(&self.root, &["branch", "--format=%(refname:short)"])?.lines().map(str::to_string).collect())
    }

    pub fn checkout(&self, branch: &str, create: bool) -> Result<String, String> {
        if create { git(&self.root, &["checkout", "-b", branch]) } else { git(&self.root, &["checkout", branch]) }
    }

    pub fn stage(&self, paths: &[&str]) -> Result<(), String> {
        let mut args = vec!["add", "--"];
        args.extend(paths);
        git(&self.root, &args).map(|_| ())
    }

    pub fn unstage(&self, paths: &[&str]) -> Result<(), String> {
        let mut args = vec!["reset", "-q", "HEAD", "--"];
        args.extend(paths);
        // ilk commit öncesi HEAD yok
        git(&self.root, &args)
            .or_else(|_| {
                let mut a = vec!["rm", "--cached", "-q", "--"];
                a.extend(paths);
                git(&self.root, &a)
            })
            .map(|_| ())
    }

    pub fn discard(&self, paths: &[&str]) -> Result<(), String> {
        let mut args = vec!["checkout", "--"];
        args.extend(paths);
        git(&self.root, &args).map(|_| ())
    }

    pub fn commit(&self, message: &str, all: bool) -> Result<String, String> {
        let mut args = vec!["commit", "-F", "-"];
        if all {
            args.push("-a");
        }
        git_input(&self.root, &args, Some(message))
    }

    pub fn push(&self) -> Result<String, String> {
        git(&self.root, &["push"]).or_else(|e| {
            // upstream yoksa kur
            if e.contains("no upstream") || e.contains("--set-upstream") {
                let b = self.branch();
                git(&self.root, &["push", "-u", "origin", &b])
            } else {
                Err(e)
            }
        })
    }

    pub fn pull(&self) -> Result<String, String> {
        git(&self.root, &["pull", "--ff-only"])
    }

    // "yazar\tunix zamanı\tözet"; kirli içerik stdin'den verilir
    pub fn blame_line(&self, path: &Path, line: usize, contents: Option<&str>) -> Result<String, String> {
        let range = format!("{},{}", line + 1, line + 1);
        let rel = self.rel(path);
        let mut args = vec!["blame", "--porcelain", "-L", &range];
        if contents.is_some() {
            args.extend(["--contents", "-"]);
        }
        args.extend(["--", &rel]);
        let out = git_input(&self.root, &args, contents)?;
        let (mut author, mut time, mut summary) = (String::new(), String::new(), String::new());
        let not_committed = out.starts_with("0000000000000000000000000000000000000000");
        for l in out.lines() {
            if let Some(v) = l.strip_prefix("author ") {
                author = v.to_string();
            } else if let Some(v) = l.strip_prefix("author-time ") {
                time = v.to_string();
            } else if let Some(v) = l.strip_prefix("summary ") {
                summary = v.to_string();
            }
        }
        if not_committed {
            return Ok("You\t0\tUncommitted changes".into());
        }
        Ok(format!("{author}\t{time}\t{summary}"))
    }
}

pub fn line_changes(base: &str, current: &str) -> Vec<LineChange> {
    let diff = TextDiff::from_lines(base, current);
    let mut out = Vec::new();
    for op in diff.ops() {
        match *op {
            DiffOp::Equal { .. } => {}
            DiffOp::Insert { new_index, new_len, .. } => out.push((new_index, new_len, 'A')),
            DiffOp::Delete { new_index, .. } => out.push((new_index, 0, 'D')),
            DiffOp::Replace { new_index, new_len, .. } => out.push((new_index, new_len, 'M')),
        }
    }
    out
}

// çakışma blokları: (<<<<<<< satırı, ======= satırı, >>>>>>> satırı)
pub fn conflicts(text: &str) -> Vec<(usize, usize, usize)> {
    let mut out = Vec::new();
    let (mut start, mut mid) = (None, None);
    for (i, l) in text.lines().enumerate() {
        if l.starts_with("<<<<<<<") {
            start = Some(i);
            mid = None;
        } else if l.starts_with("=======") && start.is_some() {
            mid = Some(i);
        } else if l.starts_with(">>>>>>>") {
            if let (Some(s), Some(m)) = (start, mid) {
                out.push((s, m, i));
            }
            start = None;
            mid = None;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sh(dir: &Path, args: &[&str]) {
        git(dir, args).unwrap();
    }

    #[test]
    fn diff_kinds_and_conflicts() {
        let c = line_changes("a\nb\nc\nd\n", "a\nB\nc\nx\ny\nd\n");
        assert_eq!(c, vec![(1, 1, 'M'), (3, 2, 'A')]);
        assert_eq!(line_changes("a\nb\nc\n", "a\nc\n"), vec![(1, 0, 'D')]);
        let t = "x\n<<<<<<< HEAD\nmine\n=======\ntheirs\n>>>>>>> b\ny\n";
        assert_eq!(conflicts(t), vec![(1, 3, 5)]);
    }

    #[test]
    fn repo_workflow() {
        let dir = std::env::temp_dir().join(format!("kern-vcs-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        sh(&dir, &["init", "-q", "-b", "main"]);
        sh(&dir, &["config", "user.email", "t@example.com"]);
        sh(&dir, &["config", "user.name", "Tester"]);
        std::fs::write(dir.join("a.txt"), "one\ntwo\n").unwrap();
        let repo = Repo::discover(&dir.join("a.txt")).unwrap();
        assert_eq!(repo.status().unwrap(), vec![FileStatus { path: "a.txt".into(), index: '?', worktree: '?' }]);
        repo.stage(&["a.txt"]).unwrap();
        assert_eq!(repo.status().unwrap()[0].index, 'A');
        repo.commit("first\n\nbody", false).unwrap();
        assert!(repo.status().unwrap().is_empty());
        assert_eq!(repo.head_text(&dir.join("a.txt")).unwrap(), "one\ntwo\n");
        std::fs::write(dir.join("a.txt"), "one\nTWO\n").unwrap();
        assert_eq!(repo.status().unwrap()[0].worktree, 'M');
        let b = repo.blame_line(&dir.join("a.txt"), 0, None).unwrap();
        assert!(b.starts_with("Tester\t") && b.ends_with("\tfirst"), "{b}");
        let b = repo.blame_line(&dir.join("a.txt"), 1, Some("one\nchanged\n")).unwrap();
        assert!(b.contains("Uncommitted"), "{b}");
        repo.checkout("feature", true).unwrap();
        assert_eq!(repo.branch(), "feature");
        assert_eq!(repo.branches().unwrap(), vec!["feature", "main"]);
        repo.discard(&["a.txt"]).unwrap();
        assert!(repo.status().unwrap().is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
