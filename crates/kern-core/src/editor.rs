use std::io;
use std::ops::Range;
use std::path::PathBuf;

use kern_syntax::Syntax;
use kern_text::{Edit, EditKind, FIND_CASE, FIND_REGEX, History, Matcher, is_line_break};

use crate::Document;

const SYNTAX_MAX_BYTES: usize = 8 * 1024 * 1024;
const PAIRS: &[(char, char)] = &[('(', ')'), ('[', ']'), ('{', '}'), ('"', '"'), ('\'', '\''), ('`', '`')];

#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub struct Selection {
    pub anchor: usize,
    pub head: usize,
}

impl Selection {
    pub fn cursor(at: usize) -> Self {
        Self { anchor: at, head: at }
    }

    pub fn range(&self) -> Range<usize> {
        self.anchor.min(self.head)..self.anchor.max(self.head)
    }

    pub fn is_empty(&self) -> bool {
        self.anchor == self.head
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Motion {
    Left,
    Right,
    Up,
    Down,
    WordLeft,
    WordRight,
    LineStart,
    LineEnd,
    PageUp,
    PageDown,
    DocStart,
    DocEnd,
}

fn class(c: char) -> u8 {
    if c.is_whitespace() {
        0
    } else if c.is_alphanumeric() || c == '_' {
        1
    } else {
        2
    }
}

// birincil seçim + ek imleçler
type Snap = (Selection, Vec<Selection>);

pub struct Editor {
    pub doc: Document,
    sel: Selection,
    goal_col: Option<usize>,
    extra: Vec<Selection>,
    history: History<Snap>,
    saved_state: u64,
    page_lines: usize,
    line_ending: &'static str,
    language: &'static str,
    syntax: Option<Syntax>,
    // aynı belgeyi gösteren görünümler: etkin olan + park edilmiş (seçimleri buffer.marks içinde)
    view: u64,
    next_view: u64,
    parked: Vec<(u64, usize)>,
    pub tab_width: usize,
    pub insert_spaces: bool,
}

impl Editor {
    pub fn new(doc: Document) -> Self {
        let line_ending = doc.buffer.line_ending();
        let mut editor = Self {
            doc,
            sel: Selection::default(),
            extra: Vec::new(),
            goal_col: None,
            history: History::default(),
            saved_state: 0,
            page_lines: 30,
            line_ending,
            language: "Plain Text",
            syntax: None,
            view: 1,
            next_view: 1,
            parked: Vec::new(),
            tab_width: 4,
            insert_spaces: true,
        };
        editor.detect_language();
        editor
    }

    fn indent_unit(&self) -> String {
        if self.insert_spaces { " ".repeat(self.tab_width) } else { "\t".into() }
    }

    fn tab_text(&self, col: usize) -> String {
        if self.insert_spaces { " ".repeat(self.tab_width - col % self.tab_width) } else { "\t".into() }
    }

    // dosyadaki girinti biçimini tahmin et (ilk 2000 satır)
    pub fn detect_indent(&mut self) {
        let b = &self.doc.buffer;
        let (mut tabs, mut spaces) = (0, 0);
        let mut widths = [0usize; 9];
        let mut prev = 0usize;
        for i in 0..b.len_lines().min(2000) {
            let line = b.line_prefix(i, 200);
            if line.trim().is_empty() {
                continue;
            }
            if line.starts_with('\t') {
                tabs += 1;
                continue;
            }
            let n = line.chars().take_while(|c| *c == ' ').count();
            if n > 0 {
                spaces += 1;
            }
            let d = n.abs_diff(prev);
            if (2..=8).contains(&d) {
                widths[d] += 1;
            }
            prev = n;
        }
        if tabs > spaces {
            self.insert_spaces = false;
        } else if spaces > 0 {
            self.insert_spaces = true;
            if let Some((w, _)) = widths.iter().enumerate().filter(|(_, c)| **c > 0).max_by_key(|(w, c)| (**c, *w == 4)) {
                self.tab_width = w;
            }
        }
    }

    // görünümler

    pub fn active_view(&self) -> u64 {
        self.view
    }

    // yeni görünüm, etkin görünümün seçimleriyle başlar
    pub fn add_view(&mut self) -> u64 {
        self.next_view += 1;
        let flat = self.flat_selections();
        self.parked.push((self.next_view, flat.len()));
        self.doc.buffer.marks.extend(flat);
        self.next_view
    }

    pub fn remove_view(&mut self, id: u64) {
        if self.view == id {
            self.view = 0;
        } else {
            self.take_parked(id);
        }
    }

    pub fn activate_view(&mut self, id: u64) {
        if self.view == id {
            return;
        }
        let restored = self.take_parked(id);
        if self.view != 0 {
            let flat = self.flat_selections();
            self.parked.push((self.view, flat.len()));
            self.doc.buffer.marks.extend(flat);
        }
        self.view = id;
        let len = self.doc.buffer.len_chars();
        let mut sels = restored
            .chunks_exact(2)
            .map(|p| Selection { anchor: p[0].min(len), head: p[1].min(len) });
        self.sel = sels.next().unwrap_or_default();
        self.extra = sels.collect();
        self.goal_col = None;
        self.history.seal();
    }

    fn flat_selections(&self) -> Vec<usize> {
        std::iter::once(self.sel).chain(self.extra.iter().copied()).flat_map(|s| [s.anchor, s.head]).collect()
    }

    fn take_parked(&mut self, id: u64) -> Vec<usize> {
        let mut off = 0;
        for i in 0..self.parked.len() {
            let (vid, n) = self.parked[i];
            if vid == id {
                self.parked.remove(i);
                return self.doc.buffer.marks.drain(off..off + n).collect();
            }
            off += n;
        }
        Vec::new()
    }

    fn detect_language(&mut self) {
        let Some(path) = self.doc.path.clone() else { return };
        self.language = kern_syntax::language_name(&path);
        self.doc.buffer.take_edits();
        self.syntax = if self.doc.buffer.len_bytes() <= SYNTAX_MAX_BYTES {
            Syntax::for_path(&path, self.doc.buffer.rope())
        } else {
            None
        };
    }

    pub fn language(&self) -> &'static str {
        self.language
    }

    pub fn line_ending_name(&self) -> &'static str {
        if self.line_ending == "\r\n" { "CRLF" } else { "LF" }
    }

    // görünür satırlar için düz liste: [satır, utf16 başlangıç, utf16 bitiş, tür]*
    pub fn highlights(&mut self, first: usize, last: usize) -> Vec<u32> {
        let edits = self.doc.buffer.take_edits();
        let Some(syntax) = &mut self.syntax else { return Vec::new() };
        let b = &self.doc.buffer;
        if !edits.is_empty() {
            syntax.apply(&edits, b.rope());
        }
        let lines = b.len_lines();
        let last = last.min(lines - 1);
        if first > last {
            return Vec::new();
        }
        let start = b.line_to_byte(first);
        let end = if last + 1 < lines { b.line_to_byte(last + 1) } else { b.len_bytes() };
        let mut out = Vec::new();
        for (s, e, kind) in syntax.highlight(b.rope(), start..end) {
            let (s, e) = (s.max(start), e.min(end));
            if s >= e {
                continue;
            }
            for line in b.byte_to_line(s)..=b.byte_to_line(e.saturating_sub(1)).max(b.byte_to_line(s)) {
                let ls = b.line_to_byte(line);
                let le = if line + 1 < lines { b.line_to_byte(line + 1) } else { b.len_bytes() };
                let (a, z) = (s.max(ls), e.min(le));
                if a < z {
                    out.extend([line as u32, b.byte_to_col16(line, a) as u32, b.byte_to_col16(line, z) as u32, kind as u32]);
                }
            }
        }
        out
    }

    pub fn selection(&self) -> Selection {
        self.sel
    }

    // çoklu imleç

    fn snap(&self) -> Snap {
        (self.sel, self.extra.clone())
    }

    // konuma göre sıralı tüm seçimler (birincil dahil)
    pub fn selections(&self) -> Vec<Selection> {
        self.all_selections()
    }

    fn all_selections(&self) -> Vec<Selection> {
        let mut all = self.extra.clone();
        all.push(self.sel);
        all.sort_by_key(|s| (s.range().start, s.range().end));
        all
    }

    // çakışanları birleştir, birincili koru
    fn normalize(&mut self) {
        if self.extra.is_empty() {
            return;
        }
        let primary = self.sel;
        let mut merged: Vec<Selection> = Vec::new();
        let mut primary_idx = 0;
        for s in self.all_selections() {
            if let Some(last) = merged.last_mut() {
                let (lr, sr) = (last.range(), s.range());
                if sr.start < lr.end || sr.start == lr.start {
                    let (start, end) = (lr.start.min(sr.start), lr.end.max(sr.end));
                    *last = if last.anchor <= last.head {
                        Selection { anchor: start, head: end }
                    } else {
                        Selection { anchor: end, head: start }
                    };
                    if s == primary {
                        primary_idx = merged.len() - 1;
                    }
                    continue;
                }
            }
            if s == primary {
                primary_idx = merged.len();
            }
            merged.push(s);
        }
        self.sel = merged.remove(primary_idx);
        self.extra = merged;
    }

    // her seçim için (değişecek aralık, yeni metin, imlecin yeni metindeki yeri); tek geri alma adımı
    fn edit_multi(&mut self, kind: EditKind, f: impl Fn(&Self, Selection, usize) -> (Range<usize>, String, Option<usize>)) {
        let before = self.snap();
        let primary = self.sel;
        let mut changes = Vec::new();
        let mut prev_end = 0;
        for (i, s) in self.all_selections().into_iter().enumerate() {
            let (mut r, text, caret) = f(self, s, i);
            r.start = r.start.max(prev_end);
            r.end = r.end.max(r.start);
            prev_end = r.end;
            changes.push((r, text, caret, s == primary));
        }
        let mut delta: isize = 0;
        let mut sels = Vec::new();
        let mut primary_idx = 0;
        for (r, text, caret, is_primary) in &changes {
            let start = (r.start as isize + delta) as usize;
            let len = text.chars().count();
            if *is_primary {
                primary_idx = sels.len();
            }
            sels.push(Selection::cursor(start + caret.unwrap_or(len)));
            delta += len as isize - (r.end - r.start) as isize;
        }
        let mut edits = Vec::new();
        for (r, text, _, _) in changes.iter().rev() {
            if r.is_empty() && text.is_empty() {
                continue;
            }
            let removed = self.doc.buffer.slice(r.clone());
            self.doc.buffer.remove(r.clone());
            self.doc.buffer.insert(r.start, text);
            edits.push(Edit { at: r.start, removed, inserted: text.clone() });
        }
        if edits.is_empty() {
            return;
        }
        self.sel = sels.remove(primary_idx);
        self.extra = sels;
        self.normalize();
        self.goal_col = None;
        self.history.record_many(kind, edits, before, self.snap());
    }

    // ek imleçler için hareket (hedef sütun hafızası yok)
    fn moved(&self, s: Selection, motion: Motion, extend: bool) -> Selection {
        use Motion::*;
        if !extend && !s.is_empty() {
            match motion {
                Left => return Selection::cursor(s.range().start),
                Right => return Selection::cursor(s.range().end),
                _ => {}
            }
        }
        let b = &self.doc.buffer;
        let vertical = |delta: isize| {
            let line = b.char_to_line(s.head);
            let col = s.head - b.line_to_char(line);
            let t = line as isize + delta;
            if t < 0 {
                0
            } else if t as usize >= b.len_lines() {
                b.len_chars()
            } else {
                b.line_to_char(t as usize) + col.min(b.line_len(t as usize))
            }
        };
        let page = self.page_lines as isize;
        let head = match motion {
            Left => self.prev_char(s.head),
            Right => self.next_char(s.head),
            Up => vertical(-1),
            Down => vertical(1),
            PageUp => vertical(-page),
            PageDown => vertical(page),
            WordLeft => self.word_left(s.head),
            WordRight => self.word_right(s.head),
            LineStart => self.smart_home(s.head),
            LineEnd => {
                let l = b.char_to_line(s.head);
                b.line_to_char(l) + b.line_len(l)
            }
            DocStart => 0,
            DocEnd => b.len_chars(),
        };
        if extend { Selection { anchor: s.anchor, head } } else { Selection::cursor(head) }
    }

    fn word_at(&self, at: usize) -> Option<Range<usize>> {
        let b = &self.doc.buffer;
        let len = b.len_chars();
        let probe = if at < len && !is_line_break(b.char(at)) { at } else { at.checked_sub(1)? };
        if probe >= len || is_line_break(b.char(probe)) {
            return None;
        }
        let k = class(b.char(probe));
        let mut start = probe;
        while start > 0 && class(b.char(start - 1)) == k && !is_line_break(b.char(start - 1)) {
            start -= 1;
        }
        let mut end = probe + 1;
        while end < len && class(b.char(end)) == k && !is_line_break(b.char(end)) {
            end += 1;
        }
        Some(start..end)
    }

    // ⌥ tık: imleç ekle ya da var olanı kaldır
    pub fn add_cursor(&mut self, line: usize, col16: usize) {
        let at = self.doc.buffer.utf16_to_char(line, col16);
        if let Some(i) = self.extra.iter().position(|s| s.is_empty() && s.head == at) {
            self.extra.remove(i);
        } else if self.sel.is_empty() && self.sel.head == at {
            if let Some(next) = self.extra.pop() {
                self.sel = next;
            }
        } else {
            self.extra.push(self.sel);
            self.sel = Selection::cursor(at);
            self.normalize();
        }
        self.goal_col = None;
        self.history.seal();
    }

    // ⌥⌘↑/↓
    pub fn add_cursor_vertical(&mut self, up: bool) {
        let b = &self.doc.buffer;
        let line = b.char_to_line(self.sel.head);
        if (up && line == 0) || (!up && line + 1 >= b.len_lines()) {
            return;
        }
        let goal = self.goal_col.unwrap_or(self.sel.head - b.line_to_char(line));
        let t = if up { line - 1 } else { line + 1 };
        let at = b.line_to_char(t) + goal.min(b.line_len(t));
        self.extra.push(self.sel);
        self.sel = Selection::cursor(at);
        self.normalize();
        self.goal_col = Some(goal);
        self.history.seal();
    }

    // ⌘D
    pub fn add_next_occurrence(&mut self) {
        if self.sel.is_empty() {
            if let Some(r) = self.word_at(self.sel.head) {
                self.sel = Selection { anchor: r.start, head: r.end };
            }
            return self.history.seal();
        }
        let text = self.doc.buffer.slice(self.sel.range());
        if text.contains('\n') {
            return;
        }
        let matches = self.find_all(&text, FIND_CASE, 100_000);
        let taken: Vec<Range<usize>> = self.all_selections().iter().map(|s| s.range()).collect();
        let free = |m: &&Range<usize>| !taken.iter().any(|t| t.start < m.end && m.start < t.end);
        let from = self.sel.range().end;
        let pick = matches.iter().filter(free).find(|m| m.start >= from).or_else(|| matches.iter().find(free)).cloned();
        if let Some(m) = pick {
            self.extra.push(self.sel);
            self.sel = Selection { anchor: m.start, head: m.end };
            self.normalize();
        }
        self.history.seal();
    }

    // ⇧⌘L
    pub fn select_all_occurrences(&mut self) {
        if self.sel.is_empty() {
            match self.word_at(self.sel.head) {
                Some(r) => self.sel = Selection { anchor: r.start, head: r.end },
                None => return,
            }
        }
        let text = self.doc.buffer.slice(self.sel.range());
        if text.is_empty() || text.contains('\n') {
            return;
        }
        let primary = self.sel.range();
        self.extra = self
            .find_all(&text, FIND_CASE, 10_000)
            .into_iter()
            .filter(|m| *m != primary)
            .map(|m| Selection { anchor: m.start, head: m.end })
            .collect();
        self.normalize();
        self.history.seal();
    }

    pub fn is_dirty(&self) -> bool {
        self.history.state() != self.saved_state
    }

    pub fn set_page_lines(&mut self, lines: usize) {
        self.page_lines = lines.max(1);
    }

    // diskteki içeriği tek geri alma adımı olarak yükle
    pub fn reload(&mut self) -> io::Result<()> {
        let path = self.doc.path.clone().ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "no path"))?;
        let fresh = Document::open(&path)?;
        let new_text = fresh.buffer.rope().to_string();
        let old = self.doc.buffer.rope();
        let new: Vec<char> = new_text.chars().collect();
        let old_len = old.len_chars();
        let mut pre = 0;
        for (a, b) in old.chars().zip(new.iter()) {
            if a != *b {
                break;
            }
            pre += 1;
        }
        let mut suf = 0;
        while suf < old_len - pre && suf < new.len() - pre && old.char(old_len - 1 - suf) == new[new.len() - 1 - suf] {
            suf += 1;
        }
        if pre != old_len || pre != new.len() {
            let inserted: String = new[pre..new.len() - suf].iter().collect();
            self.history.seal();
            self.edit_raw(pre..old_len - suf, &inserted);
            self.history.seal();
        }
        let len = self.doc.buffer.len_chars();
        self.sel = Selection { anchor: self.sel.anchor.min(len), head: self.sel.head.min(len) };
        self.extra.clear();
        self.goal_col = None;
        self.doc.encoding = fresh.encoding;
        self.doc.mtime = fresh.mtime;
        self.line_ending = self.doc.buffer.line_ending();
        self.saved_state = self.history.state();
        Ok(())
    }

    // LSP düzenlemeleri: (satır, utf16 sütun, son satır, son utf16 sütun, yeni metin); tek geri alma adımı
    pub fn apply_text_edits(&mut self, edits: &[(usize, usize, usize, usize, String)]) {
        let b = &self.doc.buffer;
        let mut ranges: Vec<(usize, usize, &str)> = edits
            .iter()
            .map(|(l0, c0, l1, c1, t)| {
                let s = b.utf16_to_char(*l0, *c0);
                let e = b.utf16_to_char(*l1, *c1).max(s);
                (s, e, t.as_str())
            })
            .collect();
        ranges.sort_by(|a, b| b.0.cmp(&a.0).then(b.1.cmp(&a.1)));
        if ranges.is_empty() {
            return;
        }
        // imleci işaretle takip et
        let base = self.doc.buffer.marks.len();
        self.doc.buffer.marks.extend([self.sel.anchor, self.sel.head]);
        self.extra.clear();
        self.history.begin();
        let mut prev_start = usize::MAX;
        for (s, e, t) in ranges {
            if e > prev_start {
                continue; // çakışan düzenleme
            }
            self.edit_raw(s..e, t);
            prev_start = s;
        }
        let marks: Vec<usize> = self.doc.buffer.marks.drain(base..).collect();
        self.sel = Selection { anchor: marks[0], head: marks[1] };
        self.history.end(self.snap());
        self.goal_col = None;
    }

    // kaydetmeden önce: satır sonu boşluklarını sil, dosya sonuna satır sonu ekle (tek geri alma adımı)
    pub fn prepare_save(&mut self, trim: bool, final_newline: bool) {
        let before = self.snap();
        self.history.begin();
        if trim {
            for l in (0..self.doc.buffer.len_lines()).rev() {
                let len = self.doc.buffer.line_len(l);
                let start = self.doc.buffer.line_to_char(l);
                let text = self.doc.buffer.slice(start..start + len);
                let kept = text.trim_end_matches([' ', '\t']).chars().count();
                if kept < len {
                    self.edit_raw(start + kept..start + len, "");
                }
            }
        }
        let n = self.doc.buffer.len_chars();
        if final_newline && n > 0 && !is_line_break(self.doc.buffer.char(n - 1)) {
            let le = self.line_ending;
            self.edit_raw(n..n, le);
        }
        let len = self.doc.buffer.len_chars();
        self.sel = Selection { anchor: before.0.anchor.min(len), head: before.0.head.min(len) };
        self.extra.retain(|s| s.head <= len && s.anchor <= len);
        self.history.end(self.snap());
    }

    pub fn save(&mut self) -> io::Result<()> {
        self.doc.save()?;
        self.history.seal();
        self.saved_state = self.history.state();
        Ok(())
    }

    pub fn save_as(&mut self, path: impl Into<PathBuf>) -> io::Result<()> {
        let old = self.doc.path.replace(path.into());
        if let Err(e) = self.save() {
            self.doc.path = old;
            return Err(e);
        }
        self.detect_language();
        Ok(())
    }

    // hareket

    pub fn move_cursor(&mut self, motion: Motion, extend: bool) {
        if !self.extra.is_empty() {
            self.sel = self.moved(self.sel, motion, extend);
            let extras = std::mem::take(&mut self.extra);
            self.extra = extras.into_iter().map(|s| self.moved(s, motion, extend)).collect();
            self.normalize();
            self.goal_col = None;
            return self.history.seal();
        }
        use Motion::*;
        let sel = self.sel;
        if !extend && !sel.is_empty() {
            match motion {
                Left => return self.set_cursor(sel.range().start),
                Right => return self.set_cursor(sel.range().end),
                _ => {}
            }
        }
        let page = self.page_lines as isize;
        let head = match motion {
            Left => self.prev_char(sel.head),
            Right => self.next_char(sel.head),
            Up => self.vertical(sel.head, -1),
            Down => self.vertical(sel.head, 1),
            PageUp => self.vertical(sel.head, -page),
            PageDown => self.vertical(sel.head, page),
            WordLeft => self.word_left(sel.head),
            WordRight => self.word_right(sel.head),
            LineStart => self.smart_home(sel.head),
            LineEnd => {
                let line = self.doc.buffer.char_to_line(sel.head);
                self.doc.buffer.line_to_char(line) + self.doc.buffer.line_len(line)
            }
            DocStart => 0,
            DocEnd => self.doc.buffer.len_chars(),
        };
        if !matches!(motion, Up | Down | PageUp | PageDown) {
            self.goal_col = None;
        }
        self.sel = if extend { Selection { anchor: sel.anchor, head } } else { Selection::cursor(head) };
        self.history.seal();
    }

    pub fn set_cursor(&mut self, at: usize) {
        self.extra.clear();
        self.sel = Selection::cursor(at.min(self.doc.buffer.len_chars()));
        self.goal_col = None;
        self.history.seal();
    }

    pub fn click(&mut self, line: usize, col16: usize, extend: bool) {
        let at = self.doc.buffer.utf16_to_char(line, col16);
        if extend {
            self.extra.clear();
            self.sel.head = at;
            self.goal_col = None;
            self.history.seal();
        } else {
            self.set_cursor(at);
        }
    }

    pub fn select_word(&mut self, line: usize, col16: usize) {
        self.extra.clear();
        let b = &self.doc.buffer;
        let at = b.utf16_to_char(line, col16);
        let len = b.len_chars();
        let probe = if at < len && !is_line_break(b.char(at)) { at } else { at.saturating_sub(1) };
        if len == 0 || is_line_break(b.char(probe)) {
            return self.set_cursor(at);
        }
        let k = class(b.char(probe));
        let mut start = probe;
        while start > 0 && class(b.char(start - 1)) == k && !is_line_break(b.char(start - 1)) {
            start -= 1;
        }
        let mut end = probe + 1;
        while end < len && class(b.char(end)) == k && !is_line_break(b.char(end)) {
            end += 1;
        }
        self.sel = Selection { anchor: start, head: end };
        self.goal_col = None;
        self.history.seal();
    }

    pub fn select_line(&mut self, line: usize) {
        self.extra.clear();
        let b = &self.doc.buffer;
        let line = line.min(b.len_lines() - 1);
        let start = b.line_to_char(line);
        let end = if line + 1 < b.len_lines() { b.line_to_char(line + 1) } else { b.len_chars() };
        self.sel = Selection { anchor: start, head: end };
        self.goal_col = None;
        self.history.seal();
    }

    pub fn select_all(&mut self) {
        self.extra.clear();
        self.sel = Selection { anchor: 0, head: self.doc.buffer.len_chars() };
        self.history.seal();
    }

    pub fn collapse_selection(&mut self) {
        if !self.extra.is_empty() {
            self.extra.clear();
            return self.history.seal();
        }
        self.set_cursor(self.sel.head);
    }

    pub fn selected_text(&self) -> String {
        if self.extra.is_empty() {
            return self.doc.buffer.slice(self.sel.range());
        }
        let parts: Vec<String> = self.all_selections().iter().map(|s| self.doc.buffer.slice(s.range())).collect();
        parts.join(self.line_ending)
    }

    fn prev_char(&self, at: usize) -> usize {
        let b = &self.doc.buffer;
        if at == 0 {
            return 0;
        }
        let p = at - 1;
        if p > 0 && b.char(p) == '\n' && b.char(p - 1) == '\r' { p - 1 } else { p }
    }

    fn next_char(&self, at: usize) -> usize {
        let b = &self.doc.buffer;
        let len = b.len_chars();
        if at >= len {
            return len;
        }
        if b.char(at) == '\r' && at + 1 < len && b.char(at + 1) == '\n' { at + 2 } else { at + 1 }
    }

    fn vertical(&mut self, at: usize, delta: isize) -> usize {
        let b = &self.doc.buffer;
        let line = b.char_to_line(at);
        let col = at - b.line_to_char(line);
        let goal = *self.goal_col.get_or_insert(col);
        let target = line as isize + delta;
        if target < 0 {
            return 0;
        }
        if target as usize >= b.len_lines() {
            return b.len_chars();
        }
        let t = target as usize;
        b.line_to_char(t) + goal.min(b.line_len(t))
    }

    fn word_left(&self, at: usize) -> usize {
        let b = &self.doc.buffer;
        let mut i = at;
        while i > 0 && class(b.char(i - 1)) == 0 {
            i -= 1;
        }
        if i > 0 {
            let k = class(b.char(i - 1));
            while i > 0 && class(b.char(i - 1)) == k {
                i -= 1;
            }
        }
        i
    }

    fn word_right(&self, at: usize) -> usize {
        let b = &self.doc.buffer;
        let len = b.len_chars();
        let mut i = at;
        while i < len && class(b.char(i)) == 0 {
            i += 1;
        }
        if i < len {
            let k = class(b.char(i));
            while i < len && class(b.char(i)) == k {
                i += 1;
            }
        }
        i
    }

    fn smart_home(&self, at: usize) -> usize {
        let b = &self.doc.buffer;
        let line = b.char_to_line(at);
        let start = b.line_to_char(line);
        let end = start + b.line_len(line);
        let mut first = start;
        while first < end && matches!(b.char(first), ' ' | '\t') {
            first += 1;
        }
        if at == first { start } else { first }
    }

    // düzenleme

    pub fn insert_text(&mut self, text: &str) {
        let mut text = text.replace("\r\n", "\n").replace('\r', "\n");
        if self.line_ending != "\n" {
            text = text.replace('\n', self.line_ending);
        }
        if !self.extra.is_empty() {
            // satır sayısı imleç sayısına eşitse her imlece bir satır
            let parts: Vec<String> = text.split(self.line_ending).map(String::from).collect();
            let n = self.extra.len() + 1;
            let spread = parts.len() == n || (parts.len() == n + 1 && parts[n].is_empty());
            return self.edit_multi(EditKind::Other, |_, s, i| {
                (s.range(), if spread { parts[i].clone() } else { text.clone() }, None)
            });
        }
        let single = text.chars().count() == 1 && !text.contains('\n');
        self.replace_selection(&text, if single { EditKind::Insert } else { EditKind::Other });
    }

    pub fn insert_newline(&mut self) {
        if !self.extra.is_empty() {
            let le = self.line_ending;
            return self.edit_multi(EditKind::Other, |e, s, _| {
                let b = &e.doc.buffer;
                let start = s.range().start;
                let ls = b.line_to_char(b.char_to_line(start));
                let indent: String = (ls..start).map(|i| b.char(i)).take_while(|c| *c == ' ' || *c == '\t').collect();
                (s.range(), format!("{le}{indent}"), None)
            });
        }
        let b = &self.doc.buffer;
        let start = self.sel.range().start;
        let line_start = b.line_to_char(b.char_to_line(start));
        let mut indent = String::new();
        for i in line_start..start {
            match b.char(i) {
                c @ (' ' | '\t') => indent.push(c),
                _ => break,
            }
        }
        let prev = (start > 0).then(|| b.char(start - 1));
        let end = self.sel.range().end;
        let next = (end < b.len_chars()).then(|| b.char(end));
        let le = self.line_ending;
        let line_text: String = (line_start..start).map(|i| b.char(i)).collect();
        let trimmed = line_text.trim_start();
        let next2: String = (end..(end + 2).min(b.len_chars())).map(|i| b.char(i)).collect();
        // python: akışı bitiren deyimden sonra bir düzey geri
        if self.language == "Python" && prev != Some(':') {
            let word = trimmed.split(|c: char| !c.is_alphanumeric() && c != '_').next().unwrap_or("");
            if matches!(word, "return" | "pass" | "break" | "continue" | "raise") {
                let unit = self.indent_unit();
                let dedented = indent.strip_suffix(unit.as_str()).map(str::to_string).unwrap_or_else(|| {
                    indent.strip_suffix('\t').unwrap_or(&indent).to_string()
                });
                return self.replace_selection(&format!("{le}{dedented}"), EditKind::Other);
            }
        }
        // <div>|</div> → blok aç
        if prev == Some('>') && next2 == "</" {
            let unit = self.indent_unit();
            let head = format!("{le}{indent}{unit}");
            self.replace_selection(&format!("{head}{le}{indent}"), EditKind::Other);
            self.sel = Selection::cursor(start + head.chars().count());
            return;
        }
        match prev {
            // {|} → blok aç
            Some(o @ ('{' | '(' | '[')) if PAIRS.iter().any(|&(a, c)| a == o && Some(c) == next) => {
                let head = format!("{le}{indent}{}", self.indent_unit());
                self.replace_selection(&format!("{head}{le}{indent}"), EditKind::Other);
                let at = start + head.chars().count();
                self.sel = Selection::cursor(at);
            }
            Some('{' | '(' | '[' | ':') => {
                let unit = self.indent_unit();
                self.replace_selection(&format!("{le}{indent}{unit}"), EditKind::Other)
            }
            _ => self.replace_selection(&format!("{le}{indent}"), EditKind::Other),
        }
    }

    pub fn insert_tab(&mut self) {
        if !self.extra.is_empty() {
            return self.edit_multi(EditKind::Insert, |e, s, _| {
                let b = &e.doc.buffer;
                let start = s.range().start;
                let col = start - b.line_to_char(b.char_to_line(start));
                (s.range(), e.tab_text(col), None)
            });
        }
        let (first, last) = self.selected_lines();
        if first != last {
            return self.indent_lines(true);
        }
        let b = &self.doc.buffer;
        let start = self.sel.range().start;
        let col = start - b.line_to_char(b.char_to_line(start));
        let text = self.tab_text(col);
        self.replace_selection(&text, EditKind::Insert);
    }

    pub fn delete_backward(&mut self) {
        if !self.extra.is_empty() {
            return self.edit_multi(EditKind::Delete, |e, s, _| {
                if !s.is_empty() {
                    return (s.range(), String::new(), None);
                }
                let h = s.head;
                let b = &e.doc.buffer;
                if h > 0 && h < b.len_chars() && PAIRS.iter().any(|&(o, c)| o == b.char(h - 1) && c == b.char(h)) {
                    return (h - 1..h + 1, String::new(), None);
                }
                (e.prev_char(h)..h, String::new(), None)
            });
        }
        if !self.sel.is_empty() {
            return self.replace_selection("", EditKind::Other);
        }
        let head = self.sel.head;
        let b = &self.doc.buffer;
        if head > 0 && head < b.len_chars() {
            let (p, n) = (b.char(head - 1), b.char(head));
            if PAIRS.iter().any(|&(o, c)| o == p && c == n) {
                return self.delete_range(head - 1..head + 1);
            }
        }
        self.delete_range(self.prev_char(head)..head);
    }

    pub fn delete_forward(&mut self) {
        if !self.extra.is_empty() {
            return self.edit_multi(EditKind::Delete, |e, s, _| {
                if !s.is_empty() {
                    return (s.range(), String::new(), None);
                }
                let h = s.head;
                (h..e.next_char(h), String::new(), None)
            });
        }
        if !self.sel.is_empty() {
            return self.replace_selection("", EditKind::Other);
        }
        let head = self.sel.head;
        self.delete_range(head..self.next_char(head));
    }

    pub fn delete_word_backward(&mut self) {
        if !self.extra.is_empty() {
            return self.edit_multi(EditKind::Delete, |e, s, _| {
                if !s.is_empty() {
                    return (s.range(), String::new(), None);
                }
                let h = s.head;
                (e.word_left(h)..h, String::new(), None)
            });
        }
        if !self.sel.is_empty() {
            return self.replace_selection("", EditKind::Other);
        }
        let head = self.sel.head;
        self.delete_range(self.word_left(head)..head);
    }

    pub fn delete_word_forward(&mut self) {
        if !self.extra.is_empty() {
            return self.edit_multi(EditKind::Delete, |e, s, _| {
                if !s.is_empty() {
                    return (s.range(), String::new(), None);
                }
                let h = s.head;
                (h..e.word_right(h), String::new(), None)
            });
        }
        if !self.sel.is_empty() {
            return self.replace_selection("", EditKind::Other);
        }
        let head = self.sel.head;
        self.delete_range(head..self.word_right(head));
    }

    pub fn delete_to_line_start(&mut self) {
        if !self.extra.is_empty() {
            return self.edit_multi(EditKind::Delete, |e, s, _| {
                if !s.is_empty() {
                    return (s.range(), String::new(), None);
                }
                let h = s.head;
                let b = &e.doc.buffer;
                let ls = b.line_to_char(b.char_to_line(h));
                (if ls == h { e.prev_char(h) } else { ls }..h, String::new(), None)
            });
        }
        if !self.sel.is_empty() {
            return self.replace_selection("", EditKind::Other);
        }
        let head = self.sel.head;
        let b = &self.doc.buffer;
        let start = b.line_to_char(b.char_to_line(head));
        let start = if start == head { self.prev_char(head) } else { start };
        self.delete_range(start..head);
    }

    // yazılan tek karakter: parantez/tırnak eşleme
    pub fn type_text(&mut self, text: &str) {
        if !self.extra.is_empty() {
            let mut it = text.chars();
            let single = match (it.next(), it.next()) {
                (Some(c), None) => Some(c),
                _ => None,
            };
            let kind = if single.is_some() { EditKind::Insert } else { EditKind::Other };
            return self.edit_multi(kind, |e, s, _| {
                let b = &e.doc.buffer;
                if let (Some(c), true) = (single, s.is_empty()) {
                    let head = s.head;
                    let next = (head < b.len_chars()).then(|| b.char(head));
                    let prev = (head > 0).then(|| b.char(head - 1));
                    if next == Some(c) && PAIRS.iter().any(|&(_, cl)| cl == c) {
                        return (head..head + 1, c.to_string(), Some(1));
                    }
                    if let Some(&(open, close)) = PAIRS.iter().find(|p| p.0 == c) {
                        let next_ok = next.is_none_or(|n| n.is_whitespace() || ")]},;:".contains(n));
                        let prev_ok = open != close || prev.is_none_or(|p| !(p.is_alphanumeric() || p == '_' || p == open));
                        if next_ok && prev_ok {
                            return (head..head, format!("{open}{close}"), Some(1));
                        }
                    }
                }
                (s.range(), text.to_string(), None)
            });
        }
        let mut chars = text.chars();
        let (Some(c), None) = (chars.next(), chars.next()) else { return self.insert_text(text) };
        let b = &self.doc.buffer;
        let head = self.sel.head;
        let next = (head < b.len_chars()).then(|| b.char(head));
        let prev = (head > 0).then(|| b.char(head - 1));

        if self.sel.is_empty() && next == Some(c) && PAIRS.iter().any(|&(_, cl)| cl == c) {
            return self.set_cursor(head + 1);
        }
        if self.sel.is_empty() && matches!(c, ')' | ']' | '}') && self.outdent_closing(c) {
            return;
        }
        if let Some(&(open, close)) = PAIRS.iter().find(|p| p.0 == c) {
            if !self.sel.is_empty() {
                let r = self.sel.range();
                self.history.begin();
                self.edit_raw(r.end..r.end, &close.to_string());
                self.edit_raw(r.start..r.start, &open.to_string());
                self.sel = Selection { anchor: r.start + 1, head: r.end + 1 };
                self.history.end(self.snap());
                return;
            }
            let quote = open == close;
            let next_ok = next.is_none_or(|n| n.is_whitespace() || ")]},;:".contains(n));
            let prev_ok = !quote || prev.is_none_or(|p| !(p.is_alphanumeric() || p == '_' || p == open));
            if next_ok && prev_ok {
                self.replace_selection(&format!("{open}{close}"), EditKind::Other);
                self.sel = Selection::cursor(head + 1);
                return;
            }
        }
        self.insert_text(text)
    }

    // satırda yalnız boşluk varken kapanış parantezi: açılış satırının girintisine hizala
    fn outdent_closing(&mut self, close: char) -> bool {
        let b = &self.doc.buffer;
        let head = self.sel.head;
        let line = b.char_to_line(head);
        let ls = b.line_to_char(line);
        if !(ls..head).all(|i| matches!(b.char(i), ' ' | '\t')) {
            return false;
        }
        let open = match close {
            ')' => '(',
            ']' => '[',
            _ => '{',
        };
        let mut depth = 0usize;
        let mut i = ls;
        let floor = ls.saturating_sub(200_000);
        let found = loop {
            if i == floor {
                break None;
            }
            i -= 1;
            let ch = b.char(i);
            if ch == close {
                depth += 1;
            } else if ch == open {
                if depth == 0 {
                    break Some(i);
                }
                depth -= 1;
            }
        };
        let Some(at) = found else { return false };
        let ol = b.char_to_line(at);
        let ols = b.line_to_char(ol);
        let indent: String = (ols..at).map(|i| b.char(i)).take_while(|c| matches!(c, ' ' | '\t')).collect();
        self.replace_selection_range(ls..head, &format!("{indent}{close}"));
        true
    }

    fn replace_selection_range(&mut self, r: Range<usize>, text: &str) {
        self.sel = Selection { anchor: r.start, head: r.end };
        self.replace_selection(text, EditKind::Other);
    }

    fn selected_lines(&self) -> (usize, usize) {
        let b = &self.doc.buffer;
        let r = self.sel.range();
        let first = b.char_to_line(r.start);
        let mut last = b.char_to_line(r.end);
        if last > first && r.end == b.line_to_char(last) {
            last -= 1;
        }
        (first, last)
    }

    fn edit_raw(&mut self, r: Range<usize>, text: &str) {
        let removed = self.doc.buffer.slice(r.clone());
        self.doc.buffer.remove(r.clone());
        self.doc.buffer.insert(r.start, text);
        let edit = Edit { at: r.start, removed, inserted: text.to_string() };
        self.history.record(EditKind::Other, edit, self.snap(), self.snap());
    }

    fn select_lines(&mut self, first: usize, last: usize) {
        let b = &self.doc.buffer;
        self.sel = Selection { anchor: b.line_to_char(first), head: b.line_to_char(last) + b.line_len(last) };
    }

    fn comment_prefix(&self) -> Option<&'static str> {
        match self.language {
            "Rust" | "JavaScript" | "TypeScript" | "TypeScript JSX" | "Go" | "Java" | "C" | "Swift" | "JSON" => Some("//"),
            "Python" | "Shell" | "TOML" | "YAML" => Some("#"),
            _ => None,
        }
    }

    pub fn toggle_comment(&mut self) {
        self.extra.clear();
        let Some(prefix) = self.comment_prefix() else { return };
        let (first, last) = self.selected_lines();
        let lines: Vec<String> = (first..=last).map(|l| self.doc.buffer.line(l)).collect();
        let indent_of = |s: &str| s.chars().take_while(|c| *c == ' ' || *c == '\t').count();
        let content: Vec<&String> = lines.iter().filter(|l| !l.trim().is_empty()).collect();
        if content.is_empty() {
            return;
        }
        let min_indent = content.iter().map(|l| indent_of(l)).min().unwrap_or(0);
        let commented = content.iter().all(|l| l.trim_start().starts_with(prefix));
        let was_empty = self.sel.is_empty();
        let (line, col) = {
            let b = &self.doc.buffer;
            let l = b.char_to_line(self.sel.head);
            (l, self.sel.head - b.line_to_char(l))
        };
        let plen = prefix.chars().count();

        self.history.begin();
        let mut cursor_delta: isize = 0;
        for (i, text) in lines.iter().enumerate().rev() {
            if text.trim().is_empty() {
                continue;
            }
            let l = first + i;
            let start = self.doc.buffer.line_to_char(l);
            if commented {
                let ind = indent_of(text);
                let space = text.chars().nth(ind + plen) == Some(' ');
                let n = plen + space as usize;
                self.edit_raw(start + ind..start + ind + n, "");
                if l == line && col > ind {
                    cursor_delta = -((col - ind).min(n) as isize);
                }
            } else {
                self.edit_raw(start + min_indent..start + min_indent, &format!("{prefix} "));
                if l == line && col >= min_indent {
                    cursor_delta = plen as isize + 1;
                }
            }
        }
        if was_empty {
            let at = self.doc.buffer.line_to_char(line) + (col as isize + cursor_delta).max(0) as usize;
            self.sel = Selection::cursor(at);
        } else {
            self.select_lines(first, last);
        }
        self.history.end(self.snap());
        self.goal_col = None;
    }

    pub fn indent_lines(&mut self, indent: bool) {
        self.extra.clear();
        let (first, last) = self.selected_lines();
        let single = first == last && self.sel.is_empty();
        let col = self.sel.head - self.doc.buffer.line_to_char(first);
        let mut delta: isize = 0;
        let unit = self.indent_unit();
        self.history.begin();
        for l in (first..=last).rev() {
            let text = self.doc.buffer.line(l);
            let start = self.doc.buffer.line_to_char(l);
            if indent {
                if !text.trim().is_empty() || single {
                    self.edit_raw(start..start, &unit);
                    delta = unit.chars().count() as isize;
                }
            } else {
                let n = if text.starts_with('\t') {
                    1
                } else {
                    text.chars().take(self.tab_width).take_while(|c| *c == ' ').count()
                };
                if n > 0 {
                    self.edit_raw(start..start + n, "");
                    delta = -(n.min(col) as isize);
                }
            }
        }
        if single {
            let at = self.doc.buffer.line_to_char(first) + (col as isize + delta).max(0) as usize;
            self.sel = Selection::cursor(at);
        } else {
            self.select_lines(first, last);
        }
        self.history.end(self.snap());
        self.goal_col = None;
    }

    pub fn move_lines(&mut self, up: bool) {
        self.extra.clear();
        let (first, last) = self.selected_lines();
        let b = &self.doc.buffer;
        let lines = b.len_lines();
        if (up && first == 0) || (!up && last + 1 >= lines) {
            return;
        }
        let (lo, hi) = if up { (first - 1, last) } else { (first, last + 1) };
        let mut block: Vec<String> = (lo..=hi).map(|l| b.line(l)).collect();
        let le_len = self.line_ending.chars().count() as isize;
        let shift = if up {
            block.rotate_left(1);
            -(b.line_len(lo) as isize + le_len)
        } else {
            block.rotate_right(1);
            b.line_len(hi) as isize + le_len
        };
        let start = b.line_to_char(lo);
        let end = b.line_to_char(hi) + b.line_len(hi);
        let text = block.join(self.line_ending);
        let sel = self.sel;
        self.history.begin();
        self.edit_raw(start..end, &text);
        let mv = |p: usize| (p as isize + shift) as usize;
        self.sel = Selection { anchor: mv(sel.anchor), head: mv(sel.head) };
        self.history.end(self.snap());
    }

    pub fn duplicate_lines(&mut self, down: bool) {
        self.extra.clear();
        let (first, last) = self.selected_lines();
        let b = &self.doc.buffer;
        let block: Vec<String> = (first..=last).map(|l| b.line(l)).collect();
        let text = format!("{}{}", self.line_ending, block.join(self.line_ending));
        let at = b.line_to_char(last) + b.line_len(last);
        let sel = self.sel;
        self.history.begin();
        self.edit_raw(at..at, &text);
        if down {
            let n = text.chars().count();
            self.sel = Selection { anchor: sel.anchor + n, head: sel.head + n };
        }
        self.history.end(self.snap());
    }

    pub fn delete_lines(&mut self) {
        self.extra.clear();
        let (first, last) = self.selected_lines();
        let b = &self.doc.buffer;
        let lines = b.len_lines();
        let range = if last + 1 < lines {
            b.line_to_char(first)..b.line_to_char(last + 1)
        } else if first > 0 {
            let prev = first - 1;
            b.line_to_char(prev) + b.line_len(prev)..b.len_chars()
        } else {
            0..b.len_chars()
        };
        self.history.begin();
        self.edit_raw(range.clone(), "");
        self.sel = Selection::cursor(range.start.min(self.doc.buffer.len_chars()));
        self.history.end(self.snap());
        self.goal_col = None;
    }

    // imleç yanındaki parantezin eşi: [satır, sütun16, satır, sütun16]
    pub fn matching_bracket(&self) -> Option<(usize, usize)> {
        const LIMIT: usize = 20_000;
        let b = &self.doc.buffer;
        let len = b.len_chars();
        let head = self.sel.head;
        let brackets = [('(', ')'), ('[', ']'), ('{', '}')];
        for at in [head, head.wrapping_sub(1)] {
            if at >= len {
                continue;
            }
            let c = b.char(at);
            if let Some(&(o, cl)) = brackets.iter().find(|p| p.0 == c) {
                let mut depth = 0;
                for i in at..len.min(at + LIMIT) {
                    match b.char(i) {
                        x if x == o => depth += 1,
                        x if x == cl => {
                            depth -= 1;
                            if depth == 0 {
                                return Some((at, i));
                            }
                        }
                        _ => {}
                    }
                }
            } else if let Some(&(o, cl)) = brackets.iter().find(|p| p.1 == c) {
                let mut depth = 0;
                for i in (at.saturating_sub(LIMIT)..=at).rev() {
                    match b.char(i) {
                        x if x == cl => depth += 1,
                        x if x == o => {
                            depth -= 1;
                            if depth == 0 {
                                return Some((i, at));
                            }
                        }
                        _ => {}
                    }
                }
            }
        }
        None
    }

    // arama

    // satırdaki eşleşmeler: (char başlangıç, char bitiş)
    fn line_matches(m: &Matcher, line: &str) -> Vec<(usize, usize)> {
        let mut out = Vec::new();
        let (mut byte, mut chars) = (0, 0);
        for r in m.find(line) {
            chars += line[byte..r.start].chars().count();
            let len = line[r.clone()].chars().count();
            out.push((chars, chars + len));
            chars += len;
            byte = r.end;
        }
        out
    }

    pub fn find_error(query: &str, flags: u8) -> Option<String> {
        if query.is_empty() { None } else { Matcher::new(query, flags).err() }
    }

    // tüm eşleşmeler (char aralıkları), sınırla
    pub fn find_all(&self, query: &str, flags: u8, limit: usize) -> Vec<Range<usize>> {
        let Ok(m) = Matcher::new(query, flags) else { return Vec::new() };
        let b = &self.doc.buffer;
        let mut out = Vec::new();
        for l in 0..b.len_lines() {
            let start = b.line_to_char(l);
            for (s, e) in Self::line_matches(&m, &b.line(l)) {
                out.push(start + s..start + e);
                if out.len() >= limit {
                    return out;
                }
            }
        }
        out
    }

    pub fn find_in_lines(&self, query: &str, flags: u8, first: usize, last: usize) -> Vec<u32> {
        let Ok(m) = Matcher::new(query, flags) else { return Vec::new() };
        let b = &self.doc.buffer;
        let mut out = Vec::new();
        for l in first..=last.min(b.len_lines() - 1) {
            let start = b.line_to_char(l);
            for (s, e) in Self::line_matches(&m, &b.line(l)) {
                let (_, c0) = b.char_to_utf16(start + s);
                let (_, c1) = b.char_to_utf16(start + e);
                out.extend([l as u32, c0 as u32, c1 as u32]);
            }
        }
        out
    }

    pub fn find_next(&mut self, query: &str, flags: u8, forward: bool) -> bool {
        self.extra.clear();
        let matches = self.find_all(query, flags, 200_000);
        if matches.is_empty() {
            return false;
        }
        let r = self.sel.range();
        let pick = if forward {
            matches.iter().find(|m| m.start >= r.end && *m != &r).or(matches.first())
        } else {
            matches.iter().rev().find(|m| m.start < r.start).or(matches.last())
        };
        let m = pick.cloned().unwrap_or(0..0);
        self.sel = Selection { anchor: m.start, head: m.end };
        self.goal_col = None;
        self.history.seal();
        true
    }

    // (toplam, seçili eşleşmenin 1 tabanlı sırası ya da 0)
    pub fn find_status(&self, query: &str, flags: u8) -> (usize, usize) {
        let matches = self.find_all(query, flags, 200_000);
        let r = self.sel.range();
        let current = matches.iter().position(|m| *m == r).map_or(0, |i| i + 1);
        (matches.len(), current)
    }

    pub fn replace_one(&mut self, query: &str, replacement: &str, flags: u8) {
        let Ok(m) = Matcher::new(query, flags) else { return };
        let selected = self.selected_text();
        if !selected.is_empty() && m.matches_exactly(&selected) {
            let text = m.replacement(&selected, replacement);
            self.replace_selection(&text, EditKind::Other);
        }
        self.find_next(query, flags, true);
    }

    pub fn replace_all(&mut self, query: &str, replacement: &str, flags: u8) -> usize {
        self.extra.clear();
        let Ok(matcher) = Matcher::new(query, flags) else { return 0 };
        let matches = self.find_all(query, flags, usize::MAX);
        if matches.is_empty() {
            return 0;
        }
        self.history.begin();
        for m in matches.iter().rev() {
            let text = matcher.replacement(&self.doc.buffer.slice(m.clone()), replacement);
            self.edit_raw(m.clone(), &text);
        }
        self.sel = Selection::cursor(self.sel.head.min(self.doc.buffer.len_chars()));
        self.history.end(self.snap());
        matches.len()
    }

    pub fn undo(&mut self) -> bool {
        match self.history.undo(&mut self.doc.buffer) {
            Some(snap) => self.restore(snap),
            None => false,
        }
    }

    pub fn redo(&mut self) -> bool {
        match self.history.redo(&mut self.doc.buffer) {
            Some(snap) => self.restore(snap),
            None => false,
        }
    }

    fn restore(&mut self, (sel, extra): Snap) -> bool {
        let len = self.doc.buffer.len_chars();
        let clamp = |s: Selection| Selection { anchor: s.anchor.min(len), head: s.head.min(len) };
        self.sel = clamp(sel);
        self.extra = extra.into_iter().map(clamp).collect();
        self.goal_col = None;
        true
    }

    fn replace_selection(&mut self, text: &str, kind: EditKind) {
        let before = self.sel;
        let before_snap = self.snap();
        let r = before.range();
        let removed = self.doc.buffer.slice(r.clone());
        if removed.is_empty() && text.is_empty() {
            return;
        }
        self.doc.buffer.remove(r.clone());
        self.doc.buffer.insert(r.start, text);
        self.sel = Selection::cursor(r.start + text.chars().count());
        self.goal_col = None;
        let edit = Edit { at: r.start, removed, inserted: text.to_string() };
        self.history.record(kind, edit, before_snap, self.snap());
    }

    fn delete_range(&mut self, r: Range<usize>) {
        if r.is_empty() {
            return;
        }
        let before = self.snap();
        let removed = self.doc.buffer.slice(r.clone());
        self.doc.buffer.remove(r.clone());
        self.sel = Selection::cursor(r.start);
        self.goal_col = None;
        let edit = Edit { at: r.start, removed, inserted: String::new() };
        self.history.record(EditKind::Delete, edit, before, self.snap());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ed(text: &str) -> Editor {
        Editor::new(Document::scratch(text))
    }

    fn text(e: &Editor) -> String {
        e.doc.buffer.slice(0..e.doc.buffer.len_chars())
    }

    #[test]
    fn typing_merges_into_one_undo() {
        let mut e = ed("");
        for c in ["a", "b", "c"] {
            e.insert_text(c);
        }
        assert!(e.is_dirty());
        assert!(e.undo());
        assert_eq!(text(&e), "");
        assert!(!e.is_dirty());
        assert!(e.redo());
        assert_eq!(text(&e), "abc");
    }

    #[test]
    fn backspace_undo_restores() {
        let mut e = ed("hello");
        e.move_cursor(Motion::DocEnd, false);
        e.delete_backward();
        e.delete_backward();
        assert_eq!(text(&e), "hel");
        e.undo();
        assert_eq!(text(&e), "hello");
        assert_eq!(e.selection(), Selection::cursor(5));
    }

    #[test]
    fn newline_keeps_indent_and_crlf() {
        let mut e = ed("  a\r\nb");
        e.move_cursor(Motion::LineEnd, false);
        e.insert_newline();
        assert_eq!(text(&e), "  a\r\n  \r\nb");
    }

    #[test]
    fn vertical_keeps_goal_column() {
        let mut e = ed("abcdef\nab\nabcdef");
        e.move_cursor(Motion::LineEnd, false);
        e.move_cursor(Motion::Down, false);
        e.move_cursor(Motion::Down, false);
        assert_eq!(e.selection().head, 16);
    }

    #[test]
    fn crlf_is_one_step() {
        let mut e = ed("a\r\nb");
        e.move_cursor(Motion::DocEnd, false);
        e.move_cursor(Motion::Left, false);
        e.move_cursor(Motion::Left, false);
        assert_eq!(e.selection().head, 1);
    }

    fn ed_at(path: &str, text: &str) -> Editor {
        let mut doc = Document::scratch(text);
        doc.path = Some(path.into());
        Editor::new(doc)
    }

    #[test]
    fn auto_pairs() {
        let mut e = ed("");
        e.type_text("(");
        assert_eq!(text(&e), "()");
        e.type_text("a");
        e.type_text(")");
        assert_eq!(text(&e), "(a)");
        assert_eq!(e.selection().head, 3);
        e.type_text("(");
        e.delete_backward();
        assert_eq!(text(&e), "(a)");
    }

    #[test]
    fn brace_newline() {
        let mut e = ed("fn x() {}");
        e.set_cursor(8);
        e.insert_newline();
        assert_eq!(text(&e), "fn x() {\n    \n}");
        assert_eq!(e.selection().head, 13);
    }

    #[test]
    fn toggle_comment_roundtrip() {
        let mut e = ed_at("a.rs", "  let a;\n  let b;");
        e.select_all();
        e.toggle_comment();
        assert_eq!(text(&e), "  // let a;\n  // let b;");
        e.toggle_comment();
        assert_eq!(text(&e), "  let a;\n  let b;");
        e.undo();
        assert_eq!(text(&e), "  // let a;\n  // let b;");
    }

    #[test]
    fn move_and_duplicate() {
        let mut e = ed("a\nb\nc");
        e.move_cursor(Motion::Down, false);
        e.move_lines(true);
        assert_eq!(text(&e), "b\na\nc");
        assert_eq!(e.selection().head, 0);
        e.duplicate_lines(true);
        assert_eq!(text(&e), "b\nb\na\nc");
        assert_eq!(e.selection().head, 2);
        e.delete_lines();
        assert_eq!(text(&e), "b\na\nc");
    }

    #[test]
    fn find_replace() {
        let mut e = ed("foo Foo foo");
        assert!(e.find_next("foo", 0, true));
        assert_eq!(e.selection().range(), 0..3);
        assert_eq!(e.find_status("foo", 0), (3, 1));
        assert_eq!(e.replace_all("foo", "x", FIND_CASE), 2);
        assert_eq!(text(&e), "x Foo x");
        let mut e = ed("a1 b22 çç3");
        assert_eq!(e.replace_all(r"(\w)(\d+)", "$2$1", FIND_REGEX), 3);
        assert_eq!(text(&e), "1a 22b ç3ç");
        assert!(Editor::find_error("(", FIND_REGEX).is_some());
    }

    #[test]
    fn highlights_track_edits() {
        let mut e = ed_at("a.rs", "let x = 1;");
        assert!(!e.highlights(0, 0).is_empty());
        e.set_cursor(0);
        e.insert_text("// ");
        let h = e.highlights(0, 0);
        assert_eq!(&h[..4], &[0, 0, 13, kern_syntax::token::COMMENT as u32]);
    }

    #[test]
    fn multi_cursor_typing_and_undo() {
        let mut e = ed("ab\ncd\nef");
        e.add_cursor_vertical(false);
        e.add_cursor_vertical(false);
        assert_eq!(e.selections().len(), 3);
        e.type_text("x");
        e.type_text("y");
        assert_eq!(text(&e), "xyab\nxycd\nxyef");
        e.delete_backward();
        assert_eq!(text(&e), "xab\nxcd\nxef");
        e.undo();
        assert_eq!(text(&e), "xyab\nxycd\nxyef");
        e.undo();
        assert_eq!(text(&e), "ab\ncd\nef");
        assert_eq!(e.selections().len(), 3);
    }

    #[test]
    fn add_next_occurrence_and_replace() {
        let mut e = ed("let foo = foo + foo;");
        e.set_cursor(5);
        e.add_next_occurrence();
        assert_eq!(e.selected_text(), "foo");
        e.add_next_occurrence();
        e.add_next_occurrence();
        assert_eq!(e.selections().len(), 3);
        e.type_text("b");
        assert_eq!(text(&e), "let b = b + b;");
        e.move_cursor(Motion::Left, false);
        assert_eq!(e.selections().iter().map(|s| s.head).collect::<Vec<_>>(), vec![4, 8, 12]);
        e.collapse_selection();
        assert_eq!(e.selections().len(), 1);
    }

    #[test]
    fn multi_paste_spreads_lines() {
        let mut e = ed("a\nb");
        e.add_cursor_vertical(false);
        e.move_cursor(Motion::LineEnd, false);
        e.insert_text("1\n2");
        assert_eq!(text(&e), "a1\nb2");
        e.select_all_occurrences();
    }

    #[test]
    fn overlapping_cursors_merge() {
        let mut e = ed("abc");
        e.set_cursor(1);
        e.add_cursor(0, 2);
        e.move_cursor(Motion::DocEnd, false);
        assert_eq!(e.selections().len(), 1);
    }

    #[test]
    fn reload_is_undoable_and_clean() {
        let p = std::env::temp_dir().join(format!("kern-reload-{}.txt", std::process::id()));
        std::fs::write(&p, "alpha beta gamma").unwrap();
        let mut e = Editor::new(Document::open(&p).unwrap());
        e.set_cursor(16);
        std::thread::sleep(std::time::Duration::from_millis(20));
        std::fs::write(&p, "alpha BETA gamma!").unwrap();
        assert!(e.doc.disk_changed());
        e.reload().unwrap();
        assert_eq!(text(&e), "alpha BETA gamma!");
        assert!(!e.is_dirty() && !e.doc.disk_changed());
        assert!(e.undo());
        assert_eq!(text(&e), "alpha beta gamma");
        assert!(e.is_dirty());
        let _ = std::fs::remove_file(&p);
    }

    #[test]
    fn views_keep_own_cursors_across_edits() {
        let mut e = ed("hello world");
        e.set_cursor(6);
        let v2 = e.add_view();
        e.activate_view(v2);
        assert_eq!(e.selection().head, 6);
        e.set_cursor(11);
        e.activate_view(1);
        e.set_cursor(0);
        e.insert_text(">> ");
        e.activate_view(v2);
        assert_eq!(e.selection().head, 14);
        e.insert_text("!");
        e.activate_view(1);
        assert_eq!(e.selection().head, 3);
        assert_eq!(text(&e), ">> hello world!");
        e.remove_view(v2);
        assert!(e.doc.buffer.marks.is_empty());
    }

    #[test]
    fn detects_indentation() {
        let mut e = ed("a:\n  b\n  c:\n    d\n");
        e.detect_indent();
        assert!(e.insert_spaces && e.tab_width == 2);
        let mut e = ed("a {\n\tb\n\tc\n}\n");
        e.detect_indent();
        assert!(!e.insert_spaces);
        e.set_cursor(2);
        e.insert_tab();
        assert_eq!(text(&e), "a \t{\n\tb\n\tc\n}\n");
    }

    #[test]
    fn prepare_save_trims_and_appends() {
        let mut e = ed("a  \nb\t\nc");
        e.prepare_save(true, true);
        assert_eq!(text(&e), "a\nb\nc\n");
        assert!(e.undo());
        assert_eq!(text(&e), "a  \nb\t\nc");
        let mut e = ed("x\n");
        e.prepare_save(true, true);
        assert!(!e.undo());
    }

    #[test]
    fn smart_indent_rules() {
        let mut e = ed("fn a() {\n    x;\n    ");
        e.set_cursor(e.doc.buffer.len_chars());
        e.type_text("}");
        assert_eq!(text(&e), "fn a() {\n    x;\n}");
        let mut e = ed_at("a.py", "def f():\n    return 1");
        e.set_cursor(e.doc.buffer.len_chars());
        e.insert_newline();
        assert_eq!(text(&e), "def f():\n    return 1\n");
        let mut e = ed_at("a.html", "<div></div>");
        e.set_cursor(5);
        e.insert_newline();
        assert_eq!(text(&e), "<div>\n    \n</div>");
        assert_eq!(e.selection().head, 10);
    }

    #[test]
    fn applies_lsp_edits() {
        let mut e = ed("int  x=1;\nint y;\n");
        e.set_cursor(14);
        e.apply_text_edits(&[(0, 3, 0, 5, " ".into()), (0, 6, 0, 7, " = ".into()), (1, 0, 1, 3, "long".into())]);
        assert_eq!(text(&e), "int x = 1;\nlong y;\n");
        assert_eq!(e.selection().head, 16);
        assert!(e.undo());
        assert_eq!(text(&e), "int  x=1;\nint y;\n");
    }

    #[test]
    fn word_motion() {
        let mut e = ed("foo.bar baz");
        e.move_cursor(Motion::WordRight, false);
        assert_eq!(e.selection().head, 3);
        e.move_cursor(Motion::DocEnd, false);
        e.move_cursor(Motion::WordLeft, false);
        assert_eq!(e.selection().head, 8);
    }
}
