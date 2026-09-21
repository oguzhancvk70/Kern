// satır sarma (sütun tabanlı) ve girintiye göre katlama; genişlik bilgisi Swift'ten sütun olarak gelir
use kern_text::Buffer;

const TAB: usize = 4;

// satırın sarılmış parçalarının UTF-16 başlangıçları (ilki hariç)
pub fn wrap_breaks(line: &str, cols: usize) -> Vec<usize> {
    let cols = cols.max(8);
    let mut out = Vec::new();
    let (mut col, mut u16i, mut row_start_u16) = (0usize, 0usize, 0usize);
    let mut last_space: Option<(usize, usize)> = None; // (u16 konumu, o noktadaki sütun)
    for c in line.chars() {
        let w = if c == '\t' { TAB - col % TAB } else { 1 };
        if col + w > cols && u16i > row_start_u16 {
            let (at, used) = match last_space {
                Some((at, used)) if at > row_start_u16 => (at, used),
                _ => (u16i, col),
            };
            out.push(at);
            row_start_u16 = at;
            col -= used;
            last_space = None;
        }
        col += w;
        u16i += c.len_utf16();
        if c == ' ' || c == '\t' {
            last_space = Some((u16i, col));
        }
    }
    out
}

pub fn wrap_rows(buf: &Buffer, cols: usize) -> Vec<u32> {
    (0..buf.len_lines())
        .map(|i| {
            let len = buf.line_len(i);
            if len * TAB <= cols.max(8) { 1 } else { 1 + wrap_breaks(&buf.line(i), cols).len() as u32 }
        })
        .collect()
}

fn indent_of(line: &str) -> Option<usize> {
    let mut n = 0;
    for c in line.chars() {
        match c {
            ' ' => n += 1,
            '\t' => n += TAB - n % TAB,
            '\r' | '\n' => return None,
            _ => return Some(n),
        }
    }
    None
}

// (başlangıç satırı, son satır) çiftleri; boş satırlar bloğun sonuna dahil edilmez
pub fn fold_ranges(buf: &Buffer) -> Vec<(usize, usize)> {
    let n = buf.len_lines();
    let indents: Vec<Option<usize>> = (0..n).map(|i| indent_of(&buf.line(i))).collect();
    let mut out = Vec::new();
    let mut stack: Vec<(usize, usize)> = Vec::new(); // (girinti, başlangıç)
    let mut last_nonblank = 0;
    for (i, ind) in indents.iter().enumerate() {
        let Some(ind) = *ind else { continue };
        while let Some(&(sind, start)) = stack.last() {
            if ind > sind {
                break;
            }
            stack.pop();
            if last_nonblank > start {
                out.push((start, last_nonblank));
            }
        }
        if let Some(next) = indents[i + 1..].iter().flatten().next() {
            if *next > ind {
                stack.push((ind, i));
            }
        }
        last_nonblank = i;
    }
    while let Some((_, start)) = stack.pop() {
        if last_nonblank > start {
            out.push((start, last_nonblank));
        }
    }
    out.sort();
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wraps_at_spaces_then_hard() {
        assert_eq!(wrap_breaks("aaaa bbbb cccc", 10), vec![10]);
        assert_eq!(wrap_breaks("aaaa bbbb cccc", 9), vec![5]);
        assert_eq!(wrap_breaks("aaaa bbbb cccc", 7), vec![5, 10]);
        assert_eq!(wrap_breaks("abcdefghijklmnopqrst", 8), vec![8, 16]);
        assert!(wrap_breaks("short", 80).is_empty());
        let b = Buffer::new("x\nabcdefghijklmnopqrst\n");
        assert_eq!(wrap_rows(&b, 8), vec![1, 3, 1]);
    }

    #[test]
    fn folds_by_indent() {
        let b = Buffer::new("fn a() {\n    x;\n\n    y;\n}\nz\n  w\n");
        assert_eq!(fold_ranges(&b), vec![(0, 3), (5, 6)]);
    }
}
