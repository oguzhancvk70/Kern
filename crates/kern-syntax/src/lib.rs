use std::ops::Range;
use std::path::Path;

use kern_text::{ByteEdit, Rope};
use streaming_iterator::StreamingIterator;
use tree_sitter::{InputEdit, Language, Node, Parser, Point, Query, QueryCursor, Tree};

// token türleri — Swift tarafındaki Theme.syntax ile aynı sıra
pub mod token {
    pub const NONE: u8 = 0;
    pub const KEYWORD: u8 = 1;
    pub const CONTROL: u8 = 2;
    pub const STRING: u8 = 3;
    pub const COMMENT: u8 = 4;
    pub const FUNCTION: u8 = 5;
    pub const TYPE: u8 = 6;
    pub const VARIABLE: u8 = 7;
    pub const NUMBER: u8 = 8;
    pub const CONSTANT: u8 = 9;
    pub const PROPERTY: u8 = 10;
    pub const OPERATOR: u8 = 11;
    pub const PUNCTUATION: u8 = 12;
    pub const ATTRIBUTE: u8 = 13;
    pub const TAG: u8 = 14;
    pub const ESCAPE: u8 = 15;
    pub const MODULE: u8 = 16;
}

fn classify(name: &str) -> u8 {
    use token::*;
    const RULES: &[(&str, u8)] = &[
        ("comment", COMMENT),
        ("string.escape", ESCAPE),
        ("escape", ESCAPE),
        ("string.special.key", PROPERTY),
        ("string", STRING),
        ("character", STRING),
        ("keyword.control", CONTROL),
        ("keyword.return", CONTROL),
        ("keyword.conditional", CONTROL),
        ("keyword.repeat", CONTROL),
        ("keyword.import", CONTROL),
        ("conditional", CONTROL),
        ("repeat", CONTROL),
        ("include", CONTROL),
        ("keyword", KEYWORD),
        ("storage", KEYWORD),
        ("boolean", KEYWORD),
        ("constant.builtin", KEYWORD),
        ("variable.builtin", KEYWORD),
        ("function.macro", FUNCTION),
        ("function", FUNCTION),
        ("method", FUNCTION),
        ("constructor", TYPE),
        ("type", TYPE),
        ("number", NUMBER),
        ("float", NUMBER),
        ("constant.numeric", NUMBER),
        ("constant", CONSTANT),
        ("property", PROPERTY),
        ("field", PROPERTY),
        ("variable", VARIABLE),
        ("parameter", VARIABLE),
        ("label", VARIABLE),
        ("operator", OPERATOR),
        ("punctuation", PUNCTUATION),
        ("attribute", ATTRIBUTE),
        ("tag", TAG),
        ("module", MODULE),
        ("namespace", MODULE),
    ];
    RULES
        .iter()
        .find(|(prefix, _)| name == *prefix || name.starts_with(&format!("{prefix}.")))
        .map_or(NONE, |(_, k)| *k)
}

fn language_for(path: &Path) -> Option<(&'static str, Language, String)> {
    let ext = path.extension()?.to_str()?.to_ascii_lowercase();
    let js = || format!("{}\n{}", tree_sitter_javascript::HIGHLIGHT_QUERY, tree_sitter_javascript::JSX_HIGHLIGHT_QUERY);
    let ts = || format!("{}\n{}", tree_sitter_javascript::HIGHLIGHT_QUERY, tree_sitter_typescript::HIGHLIGHTS_QUERY);
    Some(match ext.as_str() {
        "rs" => ("Rust", tree_sitter_rust::LANGUAGE.into(), tree_sitter_rust::HIGHLIGHTS_QUERY.into()),
        "js" | "mjs" | "cjs" | "jsx" => ("JavaScript", tree_sitter_javascript::LANGUAGE.into(), js()),
        "ts" | "mts" | "cts" => ("TypeScript", tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into(), ts()),
        "tsx" => (
            "TypeScript JSX",
            tree_sitter_typescript::LANGUAGE_TSX.into(),
            format!("{}\n{}", ts(), tree_sitter_javascript::JSX_HIGHLIGHT_QUERY),
        ),
        "py" | "pyi" => ("Python", tree_sitter_python::LANGUAGE.into(), tree_sitter_python::HIGHLIGHTS_QUERY.into()),
        "json" | "jsonc" => ("JSON", tree_sitter_json::LANGUAGE.into(), tree_sitter_json::HIGHLIGHTS_QUERY.into()),
        "go" => ("Go", tree_sitter_go::LANGUAGE.into(), tree_sitter_go::HIGHLIGHTS_QUERY.into()),
        "java" => ("Java", tree_sitter_java::LANGUAGE.into(), tree_sitter_java::HIGHLIGHTS_QUERY.into()),
        "c" | "h" => ("C", tree_sitter_c::LANGUAGE.into(), tree_sitter_c::HIGHLIGHT_QUERY.into()),
        "sh" | "bash" | "zsh" => ("Shell", tree_sitter_bash::LANGUAGE.into(), tree_sitter_bash::HIGHLIGHT_QUERY.into()),
        "html" | "htm" => ("HTML", tree_sitter_html::LANGUAGE.into(), tree_sitter_html::HIGHLIGHTS_QUERY.into()),
        "css" => ("CSS", tree_sitter_css::LANGUAGE.into(), tree_sitter_css::HIGHLIGHTS_QUERY.into()),
        "toml" => ("TOML", tree_sitter_toml_ng::LANGUAGE.into(), tree_sitter_toml_ng::HIGHLIGHTS_QUERY.into()),
        "yml" | "yaml" => ("YAML", tree_sitter_yaml::LANGUAGE.into(), tree_sitter_yaml::HIGHLIGHTS_QUERY.into()),
        _ => return None,
    })
}

// dosya adına göre dil adı (renklendirme olmasa da durum çubuğu için)
pub fn language_name(path: &Path) -> &'static str {
    match path.extension().and_then(|e| e.to_str()).map(|e| e.to_ascii_lowercase()).as_deref() {
        Some("md" | "markdown") => "Markdown",
        Some("swift") => "Swift",
        Some("txt") | None => "Plain Text",
        _ => language_for(path).map_or("Plain Text", |(n, _, _)| n),
    }
}

fn chunk_at(rope: &Rope, byte: usize) -> &[u8] {
    if byte >= rope.len_bytes() {
        return &[];
    }
    let (chunk, start, _, _) = rope.chunk_at_byte(byte);
    &chunk.as_bytes()[byte - start..]
}

fn to_point(p: (usize, usize)) -> Point {
    Point { row: p.0, column: p.1 }
}

pub struct Syntax {
    name: &'static str,
    parser: Parser,
    tree: Option<Tree>,
    query: Query,
    kinds: Vec<u8>,
}

impl Syntax {
    pub fn for_path(path: &Path, rope: &Rope) -> Option<Syntax> {
        let (name, language, source) = language_for(path)?;
        let query = Query::new(&language, &source).ok()?;
        let kinds = query.capture_names().iter().map(|n| classify(n)).collect();
        let mut parser = Parser::new();
        parser.set_language(&language).ok()?;
        let mut syntax = Syntax { name, parser, tree: None, query, kinds };
        syntax.reparse(rope);
        Some(syntax)
    }

    pub fn name(&self) -> &'static str {
        self.name
    }

    pub fn apply(&mut self, edits: &[ByteEdit], rope: &Rope) {
        if let Some(tree) = &mut self.tree {
            for e in edits {
                tree.edit(&InputEdit {
                    start_byte: e.start_byte,
                    old_end_byte: e.old_end_byte,
                    new_end_byte: e.new_end_byte,
                    start_position: to_point(e.start),
                    old_end_position: to_point(e.old_end),
                    new_end_position: to_point(e.new_end),
                });
            }
        }
        self.reparse(rope);
    }

    fn reparse(&mut self, rope: &Rope) {
        let mut read = |byte: usize, _: Point| chunk_at(rope, byte);
        self.tree = self.parser.parse_with_options(&mut read, self.tree.as_ref(), None);
    }

    // bayt aralığındaki boyama sırasına göre (başlangıç, bitiş, tür) listesi; sonraki öncekini ezer
    pub fn highlight(&self, rope: &Rope, range: Range<usize>) -> Vec<(usize, usize, u8)> {
        let Some(tree) = &self.tree else { return Vec::new() };
        let mut cursor = QueryCursor::new();
        cursor.set_byte_range(range);
        let text = |node: Node| rope.byte_slice(node.byte_range()).chunks().map(str::as_bytes);
        let mut captures = cursor.captures(&self.query, tree.root_node(), text);
        let mut out = Vec::new();
        let mut last = None;
        while let Some((m, i)) = captures.next() {
            let c = m.captures()[*i];
            let kind = self.kinds[c.index as usize];
            let r = c.node.byte_range();
            if kind == token::NONE || last == Some((r.start, r.end)) {
                continue;
            }
            last = Some((r.start, r.end));
            out.push((r.start, r.end, kind));
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn all_queries_compile() {
        for ext in ["rs", "js", "ts", "tsx", "py", "json", "go", "java", "c", "sh", "html", "css", "toml", "yaml"] {
            let (name, lang, src) = language_for(Path::new(&format!("a.{ext}"))).unwrap();
            assert!(Query::new(&lang, &src).is_ok(), "{name} sorgusu derlenmedi");
        }
    }

    #[test]
    fn rust_keywords_highlighted() {
        let rope = Rope::from_str("fn main() { let x = \"hi\"; }");
        let s = Syntax::for_path(Path::new("a.rs"), &rope).unwrap();
        let spans = s.highlight(&rope, 0..rope.len_bytes());
        assert!(spans.contains(&(0, 2, token::KEYWORD)));
        assert!(spans.iter().any(|&(a, _, k)| a == 20 && k == token::STRING));
    }
}
