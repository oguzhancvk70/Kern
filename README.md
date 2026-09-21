# Kern

macOS için yerel bir kod editörü: çekirdek Rust, arayüz Swift/AppKit, çizim Metal. Electron yok, web görünümü yok.

Sürüm 0.1 — geliştirme aşamasında.

## Ne yapar

- **Editör** — rope tabanlı tampon, çoklu imleç, katlama, word wrap, akıllı girinti, parantez eşleme, kodlama tespiti (UTF‑8/16, Latin‑1), atomik kaydetme, diskte değişiklik izleme
- **Renklendirme** — tree-sitter ile artımlı, 17 dil grameri
- **Dil zekâsı** — LSP istemcisi: tamamlama, hover, imza, tanıma git, referanslar, yeniden adlandırma, biçimlendirme, tanılar, belge sembolleri
- **Hata ayıklama** — DAP istemcisi: kesme noktaları, adımlama, çağrı yığını, değişken inceleyici, ifade değerlendirme, hata ayıklama konsolu (`lldb-dap`, `debugpy`, `js-debug`)
- **Terminal** — kendi PTY döngüsü, bölünmüş terminaller, OSC 7/133 kabuk entegrasyonu, tıklanabilir yollar
- **Git** — durum paneli, stage/commit/push/pull, dal değiştirici, gutter işaretleri, satır blame, çakışma çözümü
- **Arama** — dosya içi (regex/kelime/Türkçe İı duyarlı), proje geneli paralel akışlı arama, fuzzy dosya bulucu
- **AI** — satır içi tamamlama, sohbet paneli, onaylı agent modu (anahtar Keychain'de)
- **Eklentiler** — wasm (wasmtime), izin modeli, fuel/bellek sınırı — bkz. [docs/EXTENSION-API.md](docs/EXTENSION-API.md)
- **Ayarlar** — JSONC ayar ve keymap dosyaları, açık/koyu tema, eklenti temaları

## Kurulum

Gerekenler: macOS 26+, Xcode 26+, Rust (stable), [xcodegen](https://github.com/yonaskolb/XcodeGen).

```sh
git clone https://github.com/oguzhancvk70/Kern.git
cd Kern
./scripts/bootstrap.sh          # Rust kütüphanesi + Xcode projesi
open apps/macos/Kern.xcodeproj  # ⌘R ile çalıştır
```

Komut satırından derlemek için:

```sh
xcodebuild -project apps/macos/Kern.xcodeproj -scheme Kern -derivedDataPath build build
```

Yeni bir Swift dosyası eklendiğinde `xcodegen generate` tekrar çalıştırılır.

## `kern` komutu

Uygulama paketindeki `Resources/bin/kern` ikilisi terminalden dosya açar:

```sh
kern dosya.rs          # açık pencerede aç
kern dosya.rs:42:8     # satır ve sütuna git
kern -n dosya.rs       # yeni pencere
kern -r klasor/        # klasörü aç
```

PATH'e eklemek için: `ln -s /Applications/Kern.app/Contents/Resources/bin/kern /usr/local/bin/kern`

## Hata ayıklama yapılandırması

Proje kökünde `.kern/launch.json` (veya `.vscode/launch.json`) okunur — VS Code ile aynı biçim:

```jsonc
{
  "configurations": [
    { "name": "app", "type": "lldb", "request": "launch", "program": "${workspaceFolder}/target/debug/app" }
  ]
}
```

Menü: **Run** → Start Debugging (F5), Step Over (F10), Step Into (F11), Toggle Breakpoint (F9).

## Mimari

```
crates/
  kern-text     rope tampon, undo, arama motoru
  kern-core     belge (kodlama, atomik kayıt), editör, görünüm hesapları
  kern-syntax   tree-sitter, dil tespiti, token türleri
  kern-search   dosya listesi, fuzzy açma, paralel arama
  kern-term     PTY + VT emülasyonu, kabuk entegrasyonu
  kern-lsp      LSP istemcisi
  kern-dap      DAP istemcisi
  kern-vcs      git sarmalayıcı
  kern-ext      wasm eklenti çalışma zamanı
  kern-ffi      swift-bridge sınırı (Swift'e açılan tek yüzey)
apps/macos      Kern.app — AppKit arayüzü, Metal editör
cli/kern        terminal başlatıcısı
```

Kural: model ve tüm ağır iş Rust'ta, Swift yalnızca görünüm ve şekillendirme (CoreText) yapar. Ayrıntılar: [docs/PLAN.md](docs/PLAN.md).

## Testler

```sh
cargo test --workspace     # Rust çekirdek + FFI sınırı

# arayüz self-test'i (geçici klasörde tüm senaryolar)
KERN_CONFIG_DIR=$(mktemp -d) KERN_SELFTEST=/tmp/kern-selftest.txt \
  build/Build/Products/Debug/Kern.app/Contents/MacOS/Kern
cat /tmp/kern-selftest.txt
```

Self-test uygulamayı açar, senaryoları sırayla çalıştırır, raporu yazıp çıkar; çıkış kodu 0 ise hepsi geçmiştir.

## Sürüm çıkarma

```sh
./scripts/release.sh          # Release derleme + imza + dist/Kern-<sürüm>.dmg
```

İmzalı ve notarize edilmiş sürüm için:

```sh
SIGN_ID="Developer ID Application: Ad Soyad (TEAMID)" \
NOTARY_PROFILE=kern-notary \
SPARKLE_BIN=~/Library/Developer/Xcode/DerivedData/.../Sparkle/bin \
  ./scripts/release.sh
```

Otomatik güncelleme Sparkle ile yapılır. `generate_keys` ile üretilen genel anahtar
`apps/macos/project.yml` içindeki `SUPublicEDKey` alanına yazılana kadar güncelleme kapalıdır;
menüdeki **Check for Updates…** bunu söyler. DMG ve `appcast.xml` GitHub Releases'e yüklenir.

## Lisans

MIT ya da Apache‑2.0 — tercih sizin. Bkz. [LICENSE-MIT](LICENSE-MIT), [LICENSE-APACHE](LICENSE-APACHE).

Dosya simgeleri [Material Icon Theme](https://github.com/material-extensions/vscode-material-icon-theme)'den (MIT).
