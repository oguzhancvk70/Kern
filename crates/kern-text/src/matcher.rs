// arama eşleştirici: düz metin / regex, büyük-küçük harf, tam kelime
use std::ops::Range;

use regex::{Regex, RegexBuilder};

pub const FIND_CASE: u8 = 1;
pub const FIND_WORD: u8 = 2;
pub const FIND_REGEX: u8 = 4;

pub struct Matcher {
    re: Regex,
    regex: bool,
}

// Türkçe: i/İ ve ı/I eşleşsin
fn turkish_class(c: char) -> Option<&'static str> {
    match c {
        'i' => Some("[iIİ]"),
        'I' => Some("[Iiı]"),
        'İ' => Some("[İi]"),
        'ı' => Some("[ıI]"),
        _ => None,
    }
}

impl Matcher {
    pub fn new(query: &str, flags: u8) -> Result<Self, String> {
        if query.is_empty() {
            return Err("empty query".into());
        }
        let case = flags & FIND_CASE != 0;
        let regex = flags & FIND_REGEX != 0;
        let mut pat = if regex {
            query.to_string()
        } else if case {
            regex::escape(query)
        } else {
            query.chars().map(|c| turkish_class(c).map_or_else(|| regex::escape(&c.to_string()), str::to_string)).collect()
        };
        if flags & FIND_WORD != 0 {
            pat = format!(r"\b(?:{pat})\b");
        }
        let re = RegexBuilder::new(&pat)
            .case_insensitive(!case)
            .multi_line(true)
            .size_limit(1 << 22)
            .build()
            .map_err(|e| e.to_string().lines().last().unwrap_or("invalid pattern").trim().to_string())?;
        Ok(Self { re, regex })
    }

    // satır içindeki eşleşmelerin bayt aralıkları (boş eşleşmeler atlanır)
    pub fn find(&self, line: &str) -> Vec<Range<usize>> {
        self.re.find_iter(line).filter(|m| !m.is_empty()).map(|m| m.range()).collect()
    }

    pub fn is_match(&self, line: &str) -> bool {
        self.re.find_iter(line).any(|m| !m.is_empty())
    }

    // tüm metin tam eşleşiyor mu
    pub fn matches_exactly(&self, text: &str) -> bool {
        self.re.find(text).is_some_and(|m| m.start() == 0 && m.end() == text.len())
    }

    // regex modunda $1 gibi gruplar genişletilir
    pub fn replacement(&self, matched: &str, repl: &str) -> String {
        if self.regex { self.re.replace(matched, repl).into_owned() } else { repl.to_string() }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn literal_word_regex_and_turkish() {
        let m = Matcher::new("a.b", 0).unwrap();
        assert_eq!(m.find("xa.b axb"), vec![1..4]);
        let m = Matcher::new("cat", FIND_WORD).unwrap();
        assert_eq!(m.find("cat concat Cat"), vec![0..3, 11..14]);
        let m = Matcher::new("cat", FIND_WORD | FIND_CASE).unwrap();
        assert_eq!(m.find("cat Cat"), vec![0..3]);
        let m = Matcher::new(r"(\w+)@(\w+)", FIND_REGEX).unwrap();
        assert_eq!(m.replacement("ali@kern", "$2:$1"), "kern:ali");
        let m = Matcher::new("istanbul", 0).unwrap();
        assert!(m.is_match("İSTANBUL") && m.is_match("İstanbul"));
        let m = Matcher::new("ışık", 0).unwrap();
        assert!(m.is_match("IŞIK"));
        let m = Matcher::new("ÇĞÖÜŞ", 0).unwrap();
        assert!(m.is_match("çğöüş"));
        assert!(Matcher::new("(", FIND_REGEX).is_err());
    }
}
