use std::time::{Duration, Instant};

use crate::Buffer;

const MERGE_WINDOW: Duration = Duration::from_millis(1000);

#[derive(Clone, Debug)]
pub struct Edit {
    pub at: usize,
    pub removed: String,
    pub inserted: String,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum EditKind {
    Insert,
    Delete,
    Other,
}

struct Transaction<S> {
    id: u64,
    kind: EditKind,
    edits: Vec<Edit>,
    before: S,
    after: S,
    time: Instant,
}

pub struct History<S> {
    undo: Vec<Transaction<S>>,
    redo: Vec<Transaction<S>>,
    next_id: u64,
    sealed: bool,
    grouping: bool,
    group_open: bool,
}

impl<S> Default for History<S> {
    fn default() -> Self {
        Self { undo: Vec::new(), redo: Vec::new(), next_id: 0, sealed: false, grouping: false, group_open: false }
    }
}

impl<S: Clone + PartialEq> History<S> {
    // begin..end arasındaki tüm kayıtlar tek geri alma adımı olur
    pub fn begin(&mut self) {
        self.grouping = true;
        self.group_open = false;
    }

    pub fn end(&mut self, after: S) {
        if self.group_open {
            if let Some(t) = self.undo.last_mut() {
                t.after = after;
            }
        }
        self.grouping = false;
        self.group_open = false;
        self.sealed = true;
    }

    pub fn record(&mut self, kind: EditKind, edit: Edit, before: S, after: S) {
        self.record_many(kind, vec![edit], before, after);
    }

    // uygulama sırasıyla birden çok düzenleme (çoklu imleç) tek adım olarak
    pub fn record_many(&mut self, kind: EditKind, edits: Vec<Edit>, before: S, after: S) {
        self.redo.clear();
        let now = Instant::now();
        if self.grouping {
            if self.group_open {
                if let Some(t) = self.undo.last_mut() {
                    t.edits.extend(edits);
                    t.after = after;
                    return;
                }
            }
            self.group_open = true;
            self.next_id += 1;
            self.undo.push(Transaction { id: self.next_id, kind: EditKind::Other, edits, before, after, time: now });
            return;
        }
        if !self.sealed && kind != EditKind::Other {
            if let Some(t) = self.undo.last_mut() {
                if t.kind == kind && t.after == before && now - t.time < MERGE_WINDOW {
                    t.edits.extend(edits);
                    t.after = after;
                    t.time = now;
                    return;
                }
            }
        }
        self.sealed = false;
        self.next_id += 1;
        self.undo.push(Transaction { id: self.next_id, kind, edits, before, after, time: now });
    }

    // sonraki kayıt yeni bir grup açar
    pub fn seal(&mut self) {
        self.sealed = true;
    }

    // kaydedilmiş durumla karşılaştırmak için
    pub fn state(&self) -> u64 {
        self.undo.last().map_or(0, |t| t.id)
    }

    pub fn undo(&mut self, buf: &mut Buffer) -> Option<S> {
        let t = self.undo.pop()?;
        for e in t.edits.iter().rev() {
            buf.remove(e.at..e.at + e.inserted.chars().count());
            buf.insert(e.at, &e.removed);
        }
        let sel = t.before.clone();
        self.redo.push(t);
        self.sealed = true;
        Some(sel)
    }

    pub fn redo(&mut self, buf: &mut Buffer) -> Option<S> {
        let t = self.redo.pop()?;
        for e in &t.edits {
            buf.remove(e.at..e.at + e.removed.chars().count());
            buf.insert(e.at, &e.inserted);
        }
        let sel = t.after.clone();
        self.undo.push(t);
        self.sealed = true;
        Some(sel)
    }
}
