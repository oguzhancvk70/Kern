use std::fs::File;
use std::io::{self, BufReader, BufWriter, Write};
use std::path::{Path, PathBuf};

mod editor;

pub use editor::{Editor, Motion, Selection};
pub use kern_text::Buffer;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Default)]
pub struct Document {
    pub buffer: Buffer,
    pub path: Option<PathBuf>,
}

impl Document {
    pub fn scratch(text: &str) -> Self {
        Self { buffer: Buffer::new(text), path: None }
    }

    pub fn open(path: impl AsRef<Path>) -> io::Result<Self> {
        let path = path.as_ref();
        let buffer = Buffer::from_reader(BufReader::new(File::open(path)?))?;
        Ok(Self { buffer, path: Some(path.to_path_buf()) })
    }

    pub fn save(&self) -> io::Result<()> {
        let path = self
            .path
            .as_ref()
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "document has no path"))?;
        let mut w = BufWriter::new(File::create(path)?);
        self.buffer.write_to(&mut w)?;
        w.flush()
    }
}
