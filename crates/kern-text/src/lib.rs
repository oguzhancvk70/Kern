mod buffer;
mod history;
mod matcher;

pub use buffer::{Buffer, ByteEdit, is_line_break};
pub use history::{Edit, EditKind, History};
pub use matcher::{FIND_CASE, FIND_REGEX, FIND_WORD, Matcher};
pub use ropey::Rope;
