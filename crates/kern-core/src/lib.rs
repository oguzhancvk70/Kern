use std::fs::{self, File};
use std::io::{self, BufWriter, Write};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

pub mod display;
mod editor;

pub use editor::{Editor, Motion, Selection};
pub use kern_text::Buffer;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Encoding {
    #[default]
    Utf8,
    Utf8Bom,
    Utf16Le,
    Utf16Be,
    Latin1,
}

impl Encoding {
    pub fn name(self) -> &'static str {
        match self {
            Encoding::Utf8 => "UTF-8",
            Encoding::Utf8Bom => "UTF-8 with BOM",
            Encoding::Utf16Le => "UTF-16 LE",
            Encoding::Utf16Be => "UTF-16 BE",
            Encoding::Latin1 => "Latin-1",
        }
    }

    pub fn decode(mut bytes: Vec<u8>) -> (String, Encoding) {
        if bytes.starts_with(b"\xEF\xBB\xBF") && std::str::from_utf8(&bytes[3..]).is_ok() {
            bytes.drain(..3);
            return (String::from_utf8(bytes).unwrap_or_default(), Encoding::Utf8Bom);
        }
        if let Some(rest) = bytes.strip_prefix(b"\xFF\xFE") {
            return (utf16(rest, u16::from_le_bytes), Encoding::Utf16Le);
        }
        if let Some(rest) = bytes.strip_prefix(b"\xFE\xFF") {
            return (utf16(rest, u16::from_be_bytes), Encoding::Utf16Be);
        }
        match String::from_utf8(bytes) {
            Ok(s) => (s, Encoding::Utf8),
            Err(e) => (e.as_bytes().iter().map(|&b| b as char).collect(), Encoding::Latin1),
        }
    }

    pub fn encode(self, buffer: &Buffer, mut w: impl Write) -> io::Result<()> {
        match self {
            Encoding::Utf8 => buffer.write_to(w),
            Encoding::Utf8Bom => {
                w.write_all(b"\xEF\xBB\xBF")?;
                buffer.write_to(w)
            }
            Encoding::Utf16Le | Encoding::Utf16Be => {
                let le = self == Encoding::Utf16Le;
                w.write_all(if le { b"\xFF\xFE" } else { b"\xFE\xFF" })?;
                let mut units = [0u16; 2];
                for c in buffer.rope().chars() {
                    for u in c.encode_utf16(&mut units) {
                        w.write_all(&if le { u.to_le_bytes() } else { u.to_be_bytes() })?;
                    }
                }
                Ok(())
            }
            Encoding::Latin1 => {
                for c in buffer.rope().chars() {
                    let b = u8::try_from(u32::from(c))
                        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, format!("'{c}' cannot be saved as Latin-1")))?;
                    w.write_all(&[b])?;
                }
                Ok(())
            }
        }
    }
}

fn utf16(bytes: &[u8], f: fn([u8; 2]) -> u16) -> String {
    let units: Vec<u16> = bytes.chunks_exact(2).map(|c| f([c[0], c[1]])).collect();
    String::from_utf16_lossy(&units)
}

#[derive(Default)]
pub struct Document {
    pub buffer: Buffer,
    pub path: Option<PathBuf>,
    pub encoding: Encoding,
    pub mtime: Option<SystemTime>,
}

impl Document {
    pub fn scratch(text: &str) -> Self {
        Self { buffer: Buffer::new(text), path: None, encoding: Encoding::Utf8, mtime: None }
    }

    pub fn open(path: impl AsRef<Path>) -> io::Result<Self> {
        let path = path.as_ref();
        let mtime = disk_mtime(path);
        let (text, encoding) = Encoding::decode(fs::read(path)?);
        Ok(Self { buffer: Buffer::new(&text), path: Some(path.to_path_buf()), encoding, mtime })
    }

    // son okuma/yazmadan sonra diskte değişti mi
    pub fn disk_changed(&self) -> bool {
        match &self.path {
            Some(p) => disk_mtime(p).is_some_and(|m| Some(m) != self.mtime),
            None => false,
        }
    }

    pub fn disk_missing(&self) -> bool {
        self.path.as_ref().is_some_and(|p| !p.exists())
    }

    // atomik kaydetme: aynı dizinde geçici dosya → fsync → rename
    pub fn save(&mut self) -> io::Result<()> {
        let path = self.path.as_ref().ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "document has no path"))?;
        let target = fs::canonicalize(path).unwrap_or_else(|_| path.clone());
        let dir = target.parent().filter(|d| !d.as_os_str().is_empty()).unwrap_or(Path::new("."));
        let name = target.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let tmp = dir.join(format!(".{name}.kern-{}.tmp", std::process::id()));
        let result = (|| {
            let file = File::create(&tmp)?;
            let mut w = BufWriter::new(file);
            self.encoding.encode(&self.buffer, &mut w)?;
            let file = w.into_inner().map_err(|e| e.into_error())?;
            if let Ok(meta) = fs::metadata(&target) {
                file.set_permissions(meta.permissions())?;
            }
            file.sync_all()?;
            fs::rename(&tmp, &target)
        })();
        match result {
            Ok(()) => self.mtime = disk_mtime(&target),
            Err(_) => {
                let _ = fs::remove_file(&tmp);
            }
        }
        result
    }
}

fn disk_mtime(path: &Path) -> Option<SystemTime> {
    fs::metadata(path).and_then(|m| m.modified()).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmpdir(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("kern-core-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn roundtrip_all_encodings() {
        let d = tmpdir("enc");
        let cases: [(&[u8], Encoding); 5] = [
            (b"a\xC3\xA7b", Encoding::Utf8),
            (b"\xEF\xBB\xBFa\xC3\xA7b", Encoding::Utf8Bom),
            (b"\xFF\xFEa\x00\xE7\x00b\x00", Encoding::Utf16Le),
            (b"\xFE\xFF\x00a\x00\xE7\x00b", Encoding::Utf16Be),
            (b"a\xE7b", Encoding::Latin1),
        ];
        for (i, (bytes, enc)) in cases.iter().enumerate() {
            let p = d.join(format!("f{i}"));
            fs::write(&p, bytes).unwrap();
            let mut doc = Document::open(&p).unwrap();
            assert_eq!(doc.encoding, *enc);
            assert_eq!(doc.buffer.rope().to_string(), "açb");
            doc.save().unwrap();
            assert_eq!(fs::read(&p).unwrap(), *bytes);
        }
    }

    #[test]
    fn latin1_rejects_unencodable() {
        let d = tmpdir("lat");
        let p = d.join("f");
        fs::write(&p, b"a\xE7").unwrap();
        let mut doc = Document::open(&p).unwrap();
        doc.buffer = Buffer::new("€");
        assert!(doc.save().is_err());
        assert_eq!(fs::read(&p).unwrap(), b"a\xE7");
        assert_eq!(fs::read_dir(&d).unwrap().count(), 1);
    }

    #[cfg(unix)]
    #[test]
    fn save_keeps_permissions_and_follows_symlink() {
        use std::os::unix::fs::PermissionsExt;
        let d = tmpdir("perm");
        let real = d.join("real.sh");
        fs::write(&real, "x").unwrap();
        fs::set_permissions(&real, fs::Permissions::from_mode(0o755)).unwrap();
        let link = d.join("link.sh");
        std::os::unix::fs::symlink(&real, &link).unwrap();
        let mut doc = Document::open(&link).unwrap();
        doc.buffer = Buffer::new("y");
        doc.save().unwrap();
        assert!(fs::symlink_metadata(&link).unwrap().file_type().is_symlink());
        assert_eq!(fs::read_to_string(&real).unwrap(), "y");
        assert_eq!(fs::metadata(&real).unwrap().permissions().mode() & 0o777, 0o755);
    }
}
