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

    pub fn fetch(&self, prune: bool) -> Result<String, String> {
        let mut args = vec!["fetch", "--all", "--tags"];
        if prune {
            args.push("--prune");
        }
        git(&self.root, &args)
    }

    // son commit'i yeniden yaz; message boşsa eskisi korunur
    pub fn amend(&self, message: &str, all: bool) -> Result<String, String> {
        let mut args = vec!["commit", "--amend"];
        if all {
            args.push("-a");
        }
        if message.trim().is_empty() {
            args.push("--no-edit");
            git(&self.root, &args)
        } else {
            args.extend(["-F", "-"]);
            git_input(&self.root, &args, Some(message))
        }
    }

    // HEAD'in commit mesajı (amend kutusunu doldurmak için)
    pub fn head_message(&self) -> Result<String, String> {
        git(&self.root, &["log", "-1", "--pretty=%B"]).map(|s| s.trim_end().to_string())
    }

    pub fn stash_push(&self, message: &str, keep_index: bool) -> Result<String, String> {
        let mut args = vec!["stash", "push", "--include-untracked"];
        if keep_index {
            args.push("--keep-index");
        }
        if !message.trim().is_empty() {
            args.extend(["-m", message]);
        }
        git(&self.root, &args)
    }

    // "stash@{0}\tWIP on main: ...\tunix zamanı" satırları
    pub fn stash_list(&self) -> Result<Vec<String>, String> {
        Ok(git(&self.root, &["stash", "list", "--pretty=%gd\t%s\t%at"])?.lines().map(str::to_string).collect())
    }

    // drop = true → pop (uygula ve sil)
    pub fn stash_apply(&self, name: &str, drop: bool) -> Result<String, String> {
        git(&self.root, &["stash", if drop { "pop" } else { "apply" }, name])
    }

    pub fn stash_drop(&self, name: &str) -> Result<String, String> {
        git(&self.root, &["stash", "drop", name])
    }

    // commit geçmişi: "hash\tkısa hash\tyazar\tunix zamanı\tözet" (path verilirse o dosyanınki)
    pub fn log(&self, limit: usize, path: Option<&Path>) -> Result<Vec<String>, String> {
        let limit = format!("-{}", limit.max(1));
        let rel;
        let mut args = vec!["--no-optional-locks", "log", &limit, "--pretty=%H\t%h\t%an\t%at\t%s"];
        if let Some(p) = path {
            rel = self.rel(p);
            args.extend(["--follow", "--", &rel]);
        }
        Ok(git(&self.root, &args)?.lines().map(str::to_string).collect())
    }

    // bir commit'teki dosyalar: "durum\tyol"
    pub fn commit_files(&self, hash: &str) -> Result<Vec<String>, String> {
        let out = git(&self.root, &["show", "--name-status", "--pretty=", hash])?;
        Ok(out.lines().filter(|l| !l.is_empty()).map(str::to_string).collect())
    }

    // bir commit'teki (ya da HEAD'deki) dosya içeriği
    pub fn show(&self, rev: &str, path: &Path) -> Result<String, String> {
        git(&self.root, &["show", &format!("{rev}:{}", self.rel(path))])
    }

    // dosyayı bir revizyondaki haline döndür (çalışma kopyası + index)
    pub fn revert_file(&self, rev: &str, path: &Path) -> Result<(), String> {
        let rel = self.rel(path);
        git(&self.root, &["checkout", rev, "--", &rel]).map(|_| ())
    }

    pub fn tags(&self) -> Result<Vec<String>, String> {
        Ok(git(&self.root, &["tag", "--sort=-creatordate"])?.lines().map(str::to_string).collect())
    }

    pub fn tag_create(&self, name: &str, message: &str) -> Result<String, String> {
        if message.trim().is_empty() { git(&self.root, &["tag", name]) } else { git(&self.root, &["tag", "-a", name, "-m", message]) }
    }

    pub fn tag_delete(&self, name: &str) -> Result<String, String> {
        git(&self.root, &["tag", "-d", name])
    }

    // "isim\turl" satırları
    pub fn remotes(&self) -> Result<Vec<String>, String> {
        let out = git(&self.root, &["remote", "-v"])?;
        let mut seen: Vec<String> = Vec::new();
        for l in out.lines() {
            let mut it = l.split_whitespace();
            if let (Some(n), Some(u)) = (it.next(), it.next()) {
                let row = format!("{n}\t{u}");
                if !seen.contains(&row) {
                    seen.push(row);
                }
            }
        }
        Ok(seen)
    }

    pub fn remote_add(&self, name: &str, url: &str) -> Result<String, String> {
        git(&self.root, &["remote", "add", name, url])
    }

    pub fn remote_remove(&self, name: &str) -> Result<String, String> {
        git(&self.root, &["remote", "remove", name])
    }

    pub fn push_tags(&self) -> Result<String, String> {
        git(&self.root, &["push", "--tags"])
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

// diff görünümü satırları: (eski satır, yeni satır, tür) — yoksa -1; tür ' ' eşit, '-' silinen, '+' eklenen
pub type DiffRow = (i64, i64, char);

pub fn diff_rows(base: &str, current: &str) -> Vec<DiffRow> {
    let diff = TextDiff::from_lines(base, current);
    let mut out = Vec::new();
    for op in diff.ops() {
        match *op {
            DiffOp::Equal { old_index, new_index, len } => {
                for i in 0..len {
                    out.push(((old_index + i) as i64, (new_index + i) as i64, ' '));
                }
            }
            DiffOp::Delete { old_index, old_len, .. } => {
                for i in 0..old_len {
                    out.push(((old_index + i) as i64, -1, '-'));
                }
            }
            DiffOp::Insert { new_index, new_len, .. } => {
                for i in 0..new_len {
                    out.push((-1, (new_index + i) as i64, '+'));
                }
            }
            DiffOp::Replace { old_index, old_len, new_index, new_len } => {
                // değişen blokta satırlar yan yana eşlenir, fazlası tek tarafta kalır
                for i in 0..old_len.max(new_len) {
                    let o = if i < old_len { (old_index + i) as i64 } else { -1 };
                    let n = if i < new_len { (new_index + i) as i64 } else { -1 };
                    out.push((
                        o,
                        n,
                        if o >= 0 && n >= 0 {
                            '~'
                        } else if o >= 0 {
                            '-'
                        } else {
                            '+'
                        },
                    ));
                }
            }
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
        // diff görünümü satırları
        let rows = diff_rows("a\nb\nc\n", "a\nB\nc\nd\n");
        assert_eq!(rows, vec![(0, 0, ' '), (1, 1, '~'), (2, 2, ' '), (-1, 3, '+')]);
        assert_eq!(diff_rows("a\nb\n", "a\n"), vec![(0, 0, ' '), (1, -1, '-')]);
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
        // stash / log / amend / revert
        std::fs::write(dir.join("a.txt"), "one\nstashed\n").unwrap();
        repo.stash_push("wip", false).unwrap();
        assert!(repo.status().unwrap().is_empty());
        assert!(repo.stash_list().unwrap()[0].starts_with("stash@{0}\t"));
        repo.stash_apply("stash@{0}", true).unwrap();
        assert_eq!(repo.status().unwrap()[0].worktree, 'M');
        repo.discard(&["a.txt"]).unwrap();
        let log = repo.log(10, None).unwrap();
        assert_eq!(log.len(), 1);
        assert!(log[0].ends_with("\tfirst"), "{}", log[0]);
        assert_eq!(repo.head_message().unwrap(), "first\n\nbody");
        repo.amend("first commit", false).unwrap();
        assert!(repo.log(10, None).unwrap()[0].ends_with("\tfirst commit"));
        assert_eq!(repo.commit_files("HEAD"), Ok(vec!["A\ta.txt".to_string()]));
        std::fs::write(dir.join("a.txt"), "changed\n").unwrap();
        repo.revert_file("HEAD", &dir.join("a.txt")).unwrap();
        assert_eq!(std::fs::read_to_string(dir.join("a.txt")).unwrap(), "one\ntwo\n");
        repo.tag_create("v1", "").unwrap();
        assert_eq!(repo.tags().unwrap(), vec!["v1"]);
        repo.remote_add("origin", "https://example.com/x.git").unwrap();
        assert_eq!(repo.remotes().unwrap(), vec!["origin\thttps://example.com/x.git"]);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
