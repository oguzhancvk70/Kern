# Kern — yapı haritası

## 1 Ortam  <!-- sürümler, paketler, komutlar -->
- macOS 27.0 arm64, Xcode 27.0, Swift 6.3.3, Homebrew 6.0.22
- Rust 1.98.1 (rustup, `source ~/.cargo/env` gerekir), xcodegen (brew), Sparkle 2.10 (SPM ile çekilir)
- `rustfmt.toml` (max_width 140); CI: `.github/workflows/ci.yml` → fmt + cargo test + xcodebuild + SelfTest
- Başlıca crate'ler: ropey 1.6, tree-sitter 0.27 (+ 13 dil grameri), swift-bridge 0.1.59, alacritty_terminal 0.26, ignore, regex, serde_json, libc, wasmtime 3x (runtime+cranelift+wat), similar 3.2
- Build çıktısı `target.nosync/` (iCloud senkronlamasın diye, `.cargo/config.toml`); `build-rust.sh` ffi lib + `kern` CLI'ı derler, CLI `Kern.app/Contents/Resources/bin`'e kopyalanır
- Kurulum: `./scripts/bootstrap.sh` (Rust lib + `xcodegen generate`) → `open apps/macos/Kern.xcodeproj` → ⌘R. Yeni Swift dosyası eklenince `xcodegen generate` şart
- CLI ile derleme: `xcodebuild -project apps/macos/Kern.xcodeproj -scheme Kern -derivedDataPath /tmp/claude-501/kern-dd build`
- Test: `cargo test --workspace` (55 test) + arayüz self-test: `KERN_CONFIG_DIR=<geçici> KERN_SELFTEST=<rapor.txt> Kern.app/Contents/MacOS/Kern` (125 kontrol, `Sources/App/SelfTest.swift`)
- Büyük dosya ölçümü: `cargo test --release -p kern-core -- --ignored --nocapture` (50 MB / 1 GB)
- Sürüm: `./scripts/release.sh` → imza + `dist/Kern-<sürüm>.dmg`; SIGN_ID/NOTARY_PROFILE/SPARKLE_BIN verilirse notarize + appcast
- Dil sunucuları: clangd, sourcekit-lsp kurulu; rust-analyzer kurulu değil (kurulup doğrulandı, yer kaplamasın diye kaldırıldı — testi kendini atlar)

## 2 Rotalar  <!-- uygulama giriş noktaları -->
- `apps/macos` → Kern.app (`Sources/App/main.swift`, AppDelegate)
- `cli/kern` → `kern [-n|-r] yol[:satır[:sütun]]` → `kern://open?path=&line=&col=&window=` URL şeması (AppDelegate.handleKernURL); terminalde `KERN_WINDOW` ile çağıran pencere

## 3 Bileşenler ve veri  <!-- klasör → sorumluluk -->
- `crates/kern-text` rope Buffer (ByteEdit, `marks` kayan konumlar, `version`), History, `Matcher` (regex/kelime/Türkçe İı)
- `crates/kern-core` Document (Encoding tespit/koruma, atomik save, mtime) + Editor (görünümler: `add/activate_view`, reload, apply_text_edits, prepare_save, detect_indent, akıllı girinti) + `display.rs` (sarma/katlama)
- `crates/kern-syntax` dil tespiti, artımlı tree-sitter, 17 token türü
- `crates/kern-search` Workspace: dosya listesi, fuzzy quick open, paralel akışlı arama (`search_stream` → SearchJob)
- `crates/kern-term` kendi PTY okuma döngüsü + OSC 7/133 (cwd, komut işaretleri), `integration.rs` zsh/bash kancaları, açık/koyu palet
- `crates/kern-lsp` LSP istemcisi (Manager: dil başına sunucu, belge senkronu, istekler, yeniden başlatma) + code action (resolve/executeCommand, `applyEdit` kuyruğu), workspace/symbol, semanticTokens (sunucu legend'ı → kern-syntax token kodu), inlayHint, foldingRange
- `crates/kern-dap` DAP istemcisi (Session: stdio/TCP, launch.json okuma, kesme noktası kuyruğu, olaylar, stack/scope/variable/evaluate)
- `crates/kern-ext` wasm eklentiler (manifest, izinler, fuel/bellek sınırı) — API: `docs/EXTENSION-API.md`
- `crates/kern-vcs` git CLI sarmalayıcı (status/stage/commit/push/pull/branch/blame) + `line_changes`, `conflicts`
- `crates/kern-ffi` swift-bridge köprüsü: KernEditor (Rc paylaşımlı belge + görünüm id), KernTerminal, KernWorkspace, KernSearch, KernLsp, KernExtensions, KernRepo (git; komutlar `{"ok"}`/`{"error"}` JSON)
- `Sources/Editor/EditorView` Metal editör; görüntü satırı haritası (rowStart), tanı çizgileri, hayalet metin, LSP kancaları, anlamsal renkler (`semanticSpans`), satır içi ipuçları (`inlayHints`), `lspFolds`
- `Sources/Workbench` WorkbenchWindowController (EditorGroup'lar, bölme), `WorkbenchLanguage` (LSP), `WorkbenchExtensions`, FileWatcher (FSEvents), SessionStore, LanguageService (+Completion/Hover), `SourceControl` (panel, 4. sekme), `WorkbenchGit` (GitState: seri kuyruk, gutter, blame, dal paleti, çakışma çözümü)
- `Sources/App` AppDelegate, MainMenu, Settings (JSONC + keymap), SettingsWindow, Extensions, SelfTest, Updater (Sparkle)
- `Sources/Panels/DebugPanel` + `DebugConsole`, `Sources/Workbench/WorkbenchDebug` (DebugState: seri kuyruk, 0.2 sn yoklama, kesme noktaları UserDefaults'ta)
- `Sources/AI` AIClient (ham HTTP+SSE, Keychain), AIAgent (araçlar+onay), ChatPanel, WorkbenchAI (hayalet tamamlama)
- `Sources/Panels` TerminalPanel (gruplar/bölme) + TerminalView; `Sources/Theme` Theme (dark/light/eklenti) + dinamik Palette
- `Resources/extensions` paket içi eklentiler (text-tools wasm, solarized tema, snippets)

## 4 Tuzaklar  <!-- tekrar eden hatalar -->
- **FFI sınırı:** Rust = model, Swift = view/shaping/render. `kern-ffi` dışında Swift'e API açılmaz; shaping CoreText'te.
- **Kurulum izni:** yeni toolchain/brew kurulumu için önce sor.
- macOS 14+: NSView `clipsToBounds` varsayılan false, `dirtyRect` sınır dışına taşar → FlippedView bounds ∩ dirtyRect boyar.
- Elle layout'lu hücrelerde `layout()` güvenilmez; `resizeSubviews` kullan. Outline sütunu autoresize olmalı.
- Genişlik 0 iken scroll/reveal hesabı yapma (sekme bar kaybolma hatası).
- Xcode 26 Metal toolchain ayrı indirilir → shader runtime'da string'den derleniyor.
- Pencere boyutu ekrana göre sınırlanır (MacBook'ta status bar ekran dışına düşüyordu).
- Symlink yollar (/var ↔ /private/var): dosya eşleştirmesi `resolvingSymlinksInPath` ile; clangd aynı dosyaya iki URI döndürebilir.
- KernEditor Rc kullanır → yalnız ana thread. KernLsp/KernWorkspace/KernSearch thread-safe.
- FFI python yamalarında 4-boşluk desen extern bildirimini (8 boşluk) de yakalayabilir; yerleşimi kontrol et.
- Ekran kaydı/erişilebilirlik izni yok: arayüz testi ekran görüntüsüyle değil SelfTest ile.
- AI testleri sahte transport ile; gerçek API çağrısı ücretli, testte yapılmaz.
- SelfTest `wait` ana kuyruğu bloklamamalı: adımı yeniden kuyruğa koyarak yoklar (RunLoop döndürmek `main.async` bloklarını çalıştırmaz).
- FSEvents `/private/var/...` bildirir, klasör `/var/...` olabilir → önek karşılaştırmasında `/private` atılır.
- `git status` index'i tazelerken yazar → FSEvents → tekrar status: sonsuz döngü. Tüm okuma komutları `--no-optional-locks` ile.
- Xcode güncellemesi lisans onayını sıfırlar; git/clang/xcodebuild hepsi reddeder → `sudo xcodebuild -license accept`.
- iCloud klasöründe codesign patlar ("resource fork ... not allowed"); release derlemesi `$TMPDIR`'de yapılır, `xattr -cr` ile temizlenir.
- `rustup component remove <araç>` shim'i `~/.cargo/bin`'de bırakır; `which` onu bulup çalıştırır → "server exited". Bileşeni kaldırınca shim de silinir.
- Satır içi ipucu metni satırı sağa iter: `colX`/`appendGlyphs` kaydırması ile tıklama telafisi (`unshift`) hep birlikte güncellenir.
- 2 MB üstü dosyada ilk tree-sitter parse arka planda (50 MB'ta 3 sn); bitince `syntax_pending()` ile yeniden çizilir, 50 MB üstü renklendirilmez.

## 5 Durum  <!-- ne çalışıyor, ne yarım -->
29 maddelik iş listesinin tamamı bitti ve testli (cargo 53, SelfTest 119). 23–29: DAP hata ayıklama, erişilebilirlik + IME, FFI testleri, CI, README/LICENSE, büyük dosya (50 MB arka plan renklendirme, 1 GB ölçümü), dağıtım (entitlements + hardened runtime + DMG + Sparkle). 1–22: atomik kaydetme, kodlamalar, FSEvents, oturum, editör bölme, word wrap, katlama, ayarlar/keymap, açık tema, akıllı girinti, regex/kelime/Türkçe arama, akışlı proje araması, çoklu/bölünmüş terminal, OSC 7/133, tıklanabilir yollar, Option-as-Meta, `kern` CLI, LSP (clangd ile doğrulandı), AI (Chat/Agent/inline, sahte akışla test), wasm eklentiler, Git (panel/gutter/blame/dal/çakışma). 22'ye kadar commit edilmedi (commit'ler kullanıcıda).

29 maddenin tamamı commit'li (`70d7f05`). Üstüne LSP eksikleri kapatıldı: imza yardımı (⇧⌘Space, `(`/`,` ile otomatik), quick fix (⌘.), proje sembolü (`#` / ⌘T), anlamsal renkler + satır içi ipuçları (ayarlar: `editor.semanticHighlighting`, `editor.inlayHints`), LSP katlama aralıkları. rust-analyzer ile uçtan uca doğrulandı.

LSP eksikleri `907c747` ile commit'li. `.claude/structure.md` artık gitignore'da değil, repoda taşınıyor (klonda hazır gelsin diye). Çalışma alanı iCloud'dan `~/dev/Kern`'e taşındı; notlar ayrıca `~/dev/.notes/Kern/` altında yedekli.

**Kaldığımız yer:** Kod tarafında açık iş yok. Kullanıcıda bekleyen doğrulama: `cargo test --workspace` + SelfTest (LSP eklemelerinden sonra tam tur atılmadı). Sapmalar: AI Swift'te (Rust yerine), eklenti ABI'si core-wasm (WIT değil), git CLI (gix değil), Sparkle anahtarı (`SUPublicEDKey`) boş → güncelleme kapalı.

## 6 Oturum notları  <!-- en fazla 3 oturum, en yeni üstte -->
### 2026-09-22
- Karar: `structure.md` repoya alındı (gitignore'dan çıktı) — global kural 16'nın istisnası, klasör silinince kaybolmasın diye.
- Depo `~/dev/Kern`'e klonlandı, iCloud kopyası silindi. Bundan sonra çalışma dizini `~/dev/Kern`.

### 2026-09-21
- LSP eksik listesi çıkarıldı ve 6 madde kapatıldı; karar: inlay hint "satır sonuna yaz" kolaycılığı yerine gerçek yerine çizilir (glyph kaydırma + tıklama telafisi).
- Code action zinciri: `codeAction` → gerekirse `codeAction/resolve` → düzenleme yoksa `workspace/executeCommand`; sunucunun gönderdiği `applyEdit` Rust'ta kuyruğa alınır, uygulamayı Swift yapar.
- Anlamsal renkler tree-sitter renginin üstüne biner (tree-sitter yedek kalır); satır kayınca LSP verisi düşürülüp yeniden istenir, >20000 satırda hiç istenmez.
- Yeni global kural (CLAUDE.md 22–24): gün kapanınca önce `structure.md`, sonra onay sorulmadan SSD cache temizliği.
- Debug: kesme noktaları 0 tabanlı tutulur, DAP'a +1 gönderilir; oturum durumu 0.2 sn'de bir `version()` ile yoklanır.
- Xcode 27 güncellemesi: lisans sıfırlandı (git/clang durdu), `Simulator.app` bundle'dan kaldırıldı (Dock kısayolu kırık, yerine DeviceHub).
- Kullanıcı tercihi: komutlar tek parça ve doğrudan verilsin (`sudo xcodebuild -license accept` gibi), adım adım tarif değil.
- Disk: build çıktıları 12 GB, kaynak 3.3 MB. Yeni akış → GitHub'dan klonla, çalış, push et, kopyayı sil; çalışma alanı `~/dev` (iCloud dışında).

### 2026-09-19 (gece)
- Git: işlemler tek seri kuyrukta; commit'te stage yoksa tüm değişiklikler eklenir; izlenmeyen dosyada discard = çöpe taşı.
- Gutter işaretleri HEAD'e göre, düzenlemede 0.4 sn gecikmeli; blame imleçte 0.5 sn gecikmeli, kirli içerik stdin'den.

### Arşiv
- 2026-09-19 (akşam): repo github.com/oguzhancvk70/Kern'e bağlandı; bölünmüş görünümler belgeyi paylaşır (imleç Buffer.marks); AI modelleri inline Haiku 4.5 / chat Sonnet 5 / agent Opus 5, anahtar Keychain; eklenti izinleri kurulumda onaylanır.
- 2026-09-19: "VS Code gibi" beklentisi → tam workbench; ikonlar Material Icon Theme; logo yalnız uygulama ikonunda; çoklu imleç tek undo adımı.
- 2026-09-16: Rust çekirdek + Swift/AppKit; eklentiler WASM, dil desteği LSP; VS Code eklenti uyumu kapsam dışı.
