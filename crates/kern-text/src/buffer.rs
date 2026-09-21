use std::io::{self, Read, Write};
use std::ops::Range;

use ropey::{Rope, RopeSlice};

// tree-sitter InputEdit karşılığı; noktalar (satır, satır içi bayt)
#[derive(Clone, Copy, Debug)]
pub struct ByteEdit {
    pub start_byte: usize,
    pub old_end_byte: usize,
    pub new_end_byte: usize,
    pub start: (usize, usize),
    pub old_end: (usize, usize),
    pub new_end: (usize, usize),
}

#[derive(Default, Clone)]
pub struct Buffer {
    rope: Rope,
    edits: Vec<ByteEdit>,
    // düzenlemelerle birlikte kayan karakter konumları (diğer görünümlerin imleçleri)
    pub marks: Vec<usize>,
    version: u64,
}

pub fn is_line_break(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

fn ending_len(s: RopeSlice) -> usize {
    let n = s.len_chars();
    if n >= 2 && s.char(n - 2) == '\r' && s.char(n - 1) == '\n' {
        2
    } else if n >= 1 && is_line_break(s.char(n - 1)) {
        1
    } else {
        0
    }
}

impl Buffer {
    pub fn new(text: &str) -> Self {
        Self { rope: Rope::from_str(text), edits: Vec::new(), marks: Vec::new(), version: 0 }
    }

    pub fn from_reader(reader: impl Read) -> io::Result<Self> {
        Ok(Self { rope: Rope::from_reader(reader)?, edits: Vec::new(), marks: Vec::new(), version: 0 })
    }

    pub fn rope(&self) -> &Rope {
        &self.rope
    }

    // her düzenlemede artar
    pub fn version(&self) -> u64 {
        self.version
    }

    pub fn take_edits(&mut self) -> Vec<ByteEdit> {
        std::mem::take(&mut self.edits)
    }

    pub fn len_bytes(&self) -> usize {
        self.rope.len_bytes()
    }

    pub fn line_to_byte(&self, line: usize) -> usize {
        self.rope.line_to_byte(line)
    }

    pub fn byte_to_line(&self, byte: usize) -> usize {
        self.rope.byte_to_line(byte)
    }

    // satır içindeki baytın UTF-16 sütunu
    pub fn byte_to_col16(&self, line: usize, byte: usize) -> usize {
        let r = &self.rope;
        r.char_to_utf16_cu(r.byte_to_char(byte)) - r.char_to_utf16_cu(r.line_to_char(line))
    }

    fn point(&self, byte: usize) -> (usize, usize) {
        let line = self.rope.byte_to_line(byte);
        (line, byte - self.rope.line_to_byte(line))
    }

    pub fn write_to(&self, writer: impl Write) -> io::Result<()> {
        self.rope.write_to(writer)
    }

    pub fn len_chars(&self) -> usize {
        self.rope.len_chars()
    }

    pub fn len_lines(&self) -> usize {
        self.rope.len_lines()
    }

    pub fn char(&self, idx: usize) -> char {
        self.rope.char(idx)
    }

    pub fn line_to_char(&self, line: usize) -> usize {
        self.rope.line_to_char(line)
    }

    pub fn char_to_line(&self, idx: usize) -> usize {
        self.rope.char_to_line(idx)
    }

    // satır sonu hariç uzunluk (char)
    pub fn line_len(&self, line: usize) -> usize {
        let s = self.rope.line(line);
        s.len_chars() - ending_len(s)
    }

    pub fn line(&self, index: usize) -> String {
        self.line_prefix(index, usize::MAX)
    }

    pub fn line_prefix(&self, index: usize, max_chars: usize) -> String {
        let len = self.line_len(index).min(max_chars);
        self.rope.line(index).slice(..len).to_string()
    }

    pub fn slice(&self, range: Range<usize>) -> String {
        self.rope.slice(range).to_string()
    }

    pub fn insert(&mut self, char_idx: usize, text: &str) {
        if text.is_empty() {
            return;
        }
        let b = self.rope.char_to_byte(char_idx);
        let start = self.point(b);
        self.rope.insert(char_idx, text);
        self.version += 1;
        let n = text.chars().count();
        for m in &mut self.marks {
            if *m > char_idx {
                *m += n;
            }
        }
        let end = b + text.len();
        let new_end = self.point(end);
        self.edits.push(ByteEdit { start_byte: b, old_end_byte: b, new_end_byte: end, start, old_end: start, new_end });
    }

    pub fn remove(&mut self, range: Range<usize>) {
        if range.is_empty() {
            return;
        }
        let s = self.rope.char_to_byte(range.start);
        let e = self.rope.char_to_byte(range.end);
        let start = self.point(s);
        let old_end = self.point(e);
        for m in &mut self.marks {
            if *m >= range.end {
                *m -= range.len();
            } else if *m > range.start {
                *m = range.start;
            }
        }
        self.rope.remove(range);
        self.version += 1;
        self.edits.push(ByteEdit { start_byte: s, old_end_byte: e, new_end_byte: s, start, old_end, new_end: start });
    }

    // UI/LSP koordinatı: satır + UTF-16 sütun
    pub fn utf16_to_char(&self, line: usize, col16: usize) -> usize {
        let line = line.min(self.len_lines() - 1);
        let content = self.rope.line(line).slice(..self.line_len(line));
        let col16 = col16.min(content.len_utf16_cu());
        self.rope.line_to_char(line) + content.utf16_cu_to_char(col16)
    }

    pub fn char_to_utf16(&self, idx: usize) -> (usize, usize) {
        let line = self.rope.char_to_line(idx);
        let start = self.rope.line_to_char(line);
        (line, self.rope.line(line).char_to_utf16_cu(idx - start))
    }

    pub fn line_ending(&self) -> &'static str {
        let line = self.rope.line(0);
        let n = line.len_chars();
        if n >= 2 && line.char(n - 2) == '\r' && line.char(n - 1) == '\n' { "\r\n" } else { "\n" }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lines_strip_endings() {
        let mut m = Buffer::new("abcdef");
        m.marks = vec![1, 3, 5];
        m.remove(2..4);
        assert_eq!(m.marks, vec![1, 2, 3]);
        m.insert(2, "XY");
        assert_eq!(m.marks, vec![1, 2, 5]);
        let b = Buffer::new("a\r\nb\nc");
        assert_eq!(b.len_lines(), 3);
        assert_eq!(b.line(0), "a");
        assert_eq!(b.line_len(0), 1);
        assert_eq!(b.line(2), "c");
        assert_eq!(b.line_ending(), "\r\n");
    }

    #[test]
    fn utf16_roundtrip() {
        let b = Buffer::new("x\n😀ab\n");
        // 😀 = 2 UTF-16 birimi, 1 char
        assert_eq!(b.utf16_to_char(1, 2), 3);
        assert_eq!(b.char_to_utf16(4), (1, 3));
        assert_eq!(b.utf16_to_char(1, 99), 5);
    }

    #[test]
    fn edit() {
        let mut b = Buffer::new("hello");
        b.insert(5, " world");
        b.remove(0..1);
        assert_eq!(b.line(0), "ello world");
    }
}
