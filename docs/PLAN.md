# Kern — Teknik Plan

macOS için native kod editörü. Terminal komutu: `kern`.

---

## 1. Ürün tanımı

**Kern**, VS Code seviyesinde yetenekli, Apple Silicon MacBook için sıfırdan yazılmış bir kod editörüdür.

**Tasarım ilkeleri**

| İlke | Anlamı |
|---|---|
| Native önce | AppKit pencere, gerçek macOS menüsü, Metal render, VoiceOver, IME, Handoff |
| Sıfır gecikme | Tuşa basma → piksel < 8ms (120Hz ProMotion tek frame) |
| Dilden bağımsız | tree-sitter + LSP; hiçbir dil ayrıcalıklı değil |
| Kum havuzu eklenti | Eklentiler WASM; editörü kilitleyemez, dosya sistemine izinsiz dokunamaz |
| AI yerleşik | Sonradan takılan panel değil; buffer, LSP ve git ile aynı veri modelini paylaşır |

**Kern olmayacak şeyler:** web teknolojisi barındırmaz (WKWebView yok), VS Code eklentilerini çalıştırmaz, Electron değildir.

---

## 2. Mimari

İki katmanlı. Sınır tek yerde ve dar tutulur.

```
┌─────────────────────────────────────────────────────┐
│  apps/macos  —  Swift / AppKit / Metal / CoreText   │
│                                                     │
│  Pencere, sekme, menü, klavye, IME, metin şekillen- │
│  dirme (shaping), GPU render, tema, ayarlar UI      │
└───────────────────────┬─────────────────────────────┘
                        │  swift-bridge (C ABI)
                        │  · komut gönder (edit, cursor, search)
                        │  · frame verisi çek (span'ler, zero-copy)
                        │  · olay akışı (LSP diagnostics, git, AI)
┌───────────────────────┴─────────────────────────────┐
│  crates/  —  Rust (tokio runtime, UI thread dışı)   │
│                                                     │
│  Buffer, undo, tree-sitter, LSP/DAP, WASM host,     │
│  PTY, arama, dosya izleme, proje indeksi, AI        │
└─────────────────────────────────────────────────────┘
```

**Sorumluluk sınırı — tek cümlelik kural:**
Rust *ne yazdığını* bilir, Swift *nasıl göründüğünü* bilir.

Rust bir karakterin genişliğini bilmez, font metriklerini tutmaz, satır sarmasını (wrap) hesaplamaz. Swift metnin ne anlama geldiğini bilmez. Bu sınırı bulanıklaştırmak projeyi öldürür — her PR'da bu kurala bakılır.

**Threading modeli**

- UI thread: yalnız AppKit + Metal. Asla bloke olmaz.
- Rust core thread pool: tokio multi-thread runtime.
- Edit'ler UI thread'de senkron uygulanır (rope edit ~µs), ağır iş (parse, LSP, arama) pool'a düşer.
- Rust → Swift geri bildirimi `dispatch_async(main)` ile tek noktadan.

---

## 3. Repo yapısı

```
kern/
├─ Cargo.toml                    workspace
├─ crates/
│  ├─ kern-text/                 rope buffer, undo, çok imleç, kodlama
│  ├─ kern-syntax/               tree-sitter, injection, fold, indent
│  ├─ kern-lsp/                  LSP client + sunucu registry/indirici
│  ├─ kern-dap/                  debug adapter client
│  ├─ kern-ext/                  wasmtime host, WIT API, izin modeli
│  ├─ kern-term/                 portable-pty + VT ayrıştırıcı
│  ├─ kern-vcs/                  gix tabanlı git
│  ├─ kern-search/               ripgrep motoru, sembol indeksi
│  ├─ kern-project/              çalışma alanı, dosya izleme (FSEvents)
│  ├─ kern-ai/                   Claude API, bağlam derleyici, agent döngüsü
│  ├─ kern-config/               ayarlar, keymap, tema şeması
│  ├─ kern-core/                 üsttekileri birleştiren fasad + komut yolu
│  └─ kern-ffi/                  swift-bridge sınırı, tek dışa açık crate
├─ apps/
│  └─ macos/
│     ├─ Kern.xcodeproj
│     └─ Sources/
│        ├─ App/                 NSApplication, menü, pencere, sekme
│        ├─ Editor/              NSView, imleç, seçim, IME, scroll
│        ├─ Render/              Metal pipeline, glyph atlas, CoreText
│        ├─ Panels/              dosya ağacı, terminal, AI, arama, git
│        └─ Theme/               token → renk, Liquid Glass materyalleri
├─ cli/kern/                     terminal komutu (Rust)
├─ extensions/                   ilk parti WASM eklentileri
├─ docs/
│  ├─ PLAN.md                    bu dosya
│  ├─ ARCHITECTURE.md            karar kayıtları (ADR)
│  └─ EXTENSION-API.md           WIT arayüzü ve kılavuz
└─ .claude/structure.md          yerel çalışma notu (gitignore)
```

---

## 4. Alt sistemler

### 4.1 Metin çekirdeği — `kern-text`

- **Yapı:** rope (yaprakları ~1KB UTF-8 chunk). `ropey` crate ile başla; darboğaz çıkarsa kendi implementasyonuna geç.
- **Koordinat sistemleri:** byte offset (depolama), char index (LSP UTF-16 dönüşümü), satır/sütun (UI). Üçü arasında O(log n) dönüşüm. **Tüm hatalar burada doğar** — kapsamlı property test yazılır.
- **Undo:** işlem grupları hâlinde ters-yama yığını. Zaman aşımı + imleç sıçraması ile gruplama. Sınırsız geçmiş, diske sürülebilir.
- **Çok imleç:** imleç listesi + birincil imleç. Her edit tüm imleçlere aynı anda uygulanır, çakışanlar birleştirilir.
- **Kodlama:** UTF-8 varsayılan. UTF-16/Latin-1 okunurken dönüştürülür, orijinal biçim yazarken korunur. BOM ve satır sonu (LF/CRLF) dosya başına saklanır.
- **Büyük dosya:** 50MB üstünde syntax highlight kapanır, sanal scroll devreye girer. 1GB dosya açılabilir olmalı.

### 4.2 Sözdizimi — `kern-syntax`

- tree-sitter, artımlı parse. Her edit sonrası yalnız değişen alt ağaç yeniden ayrıştırılır.
- Dil gramerleri **eklenti olarak** gelir (WASM), çekirdeğe gömülü değil. İlk parti paket: TS/JS/TSX, Python, Rust, Go, C/C++, Swift, Java, Kotlin, C#, Ruby, PHP, HTML, CSS, JSON, YAML, TOML, Markdown, SQL, Shell, Dockerfile.
- **Injection:** HTML içinde `<script>`, Markdown içinde kod bloğu, Rust içinde `sql!` makrosu — iç içe gramerler.
- Sorgu dosyaları: `highlights.scm`, `injections.scm`, `folds.scm`, `indents.scm`, `textobjects.scm`.
- Parse UI thread dışında; sonuç gelene kadar önceki highlight gösterilir (asla boş ekran yok).

### 4.3 Dil zekâsı — `kern-lsp`

- Her dil sunucusu ayrı süreç, stdio üzerinden JSON-RPC.
- **Sunucu registry'si:** `language-servers.toml` — indirme URL'i, sürüm, checksum. Kern gerekli sunucuyu otomatik indirir (`~/Library/Application Support/Kern/servers/`). Kullanıcı elle kurulum yapmak zorunda kalmaz.
- Desteklenecek yetenekler: completion (+resolve), hover, signature help, go-to definition/type/implementation, find references, rename, code actions, formatting, inlay hints, semantic tokens, document symbols, workspace symbols, diagnostics, call hierarchy.
- **Debounce & iptal:** yazarken her tuşta istek atılmaz; eski istekler `$/cancelRequest` ile iptal edilir.
- Bir sunucu çökerse yalnız o dil bozulur, editör etkilenmez — otomatik yeniden başlatma (üstel geri çekilme).

### 4.4 Render — Swift, `apps/macos/Render`

- **Metal pipeline:** glyph atlas (MTLTexture), instanced quad çizimi. Bir frame = birkaç draw call.
- **Shaping:** CoreText. Ligatür (Fira Code, JetBrains Mono), RTL, birleşik emoji, grafem kümesi — hepsi CoreText'e bırakılır, elle yazılmaz.
- **Önbellek:** satır bazlı shaping cache. Değişmeyen satır yeniden shape edilmez.
- **Scroll:** sanal — yalnız görünür satırlar + tampon işlenir. 1M satırlık dosyada scroll maliyeti sabittir.
- ProMotion 120Hz hedefi; `CVDisplayLink` yerine `CAMetalDisplayLink`.
- Minimap, diff gutter, satır numarası, katlama işaretleri aynı pipeline'da ayrı instanced katman olarak.

### 4.5 Eklenti sistemi — `kern-ext`

- **Runtime:** wasmtime, WASI Preview 2 component model.
- **Arayüz:** WIT ile tanımlı. Eklenti yazarı Rust, Zig, C, TinyGo veya JS (Javy) kullanabilir.
- **İzin modeli:** manifest'te açıkça beyan edilir — `fs:read(workspace)`, `net:host(api.example.com)`, `process:spawn`. Beyan edilmeyen çağrı reddedilir. Kurulumda kullanıcıya gösterilir.
- **Uzantı noktaları (v1):** dil grameri, LSP sunucu tanımı, tema, keymap, komut, durum çubuğu öğesi, dosya simgesi, formatter, snippet.
- **Kaynak limiti:** eklenti başına fuel ve bellek tavanı. Takılan eklenti öldürülür, editör donmaz.
- Eklenti host süreci ayrıdır (`kern-ext-host`); çökme editörü etkilemez.

### 4.6 Terminal — `kern-term`

- `portable-pty` (süreç) + `alacritty_terminal` (VT ayrıştırıcı ve grid).
- Render editörle **aynı** Metal pipeline'ı kullanır — ayrı terminal emülatörü yazılmaz.
- Split, sekme, shell entegrasyonu (komut sınırı işaretleme, çıkış kodu, dizin takibi via OSC 133/7).
- Çıktıdaki dosya yolu ve hata satırları tıklanabilir (regex + workspace çözümleme).
- `kern` CLI terminal içinden çağrıldığında mevcut pencereye dosya açar.

### 4.7 AI asistanı — `kern-ai`

Kern'in ayırt edici özelliği. Üç mod:

| Mod | Model | Davranış |
|---|---|---|
| Inline completion | `claude-haiku-4-5` | Yazarken gri hayalet metin, Tab ile kabul. Prefix/suffix (FIM) bağlamı + açık dosyalar |
| Sohbet paneli | `claude-sonnet-5` | Seçili kod, dosya, diagnostics bağlamı. Diff önerisi üretir, tek tuşla uygulanır |
| Agent modu | `claude-opus-5` | Çok adımlı görev. Tool use ile dosya okuma/yazma, terminal, LSP sorgusu. Her yazma işlemi onaya tabi |

- **Bağlam derleyici** kritik parça: hangi dosyalar gönderilecek? Sırayla — açık buffer, imleç çevresi, LSP ile çözülen semboller, git diff, kullanıcının `@` ile eklediği dosyalar. Token bütçesi yönetilir, prompt caching kullanılır.
- API anahtarı **Keychain**'de. Asla dosyaya yazılmaz.
- Streaming zorunlu — ilk token gecikmesi görünür olmalı.
- Çevrimdışı çalışma: AI kapalıyken editörün hiçbir özelliği bozulmaz.

### 4.8 Arama — `kern-search`

- Dosya içi: rope üzerinde artımlı arama, regex (`regex` crate), büyük/küçük harf ve kelime seçenekleri.
- Proje geneli: `ripgrep` motoru (`grep` crate'leri) kütüphane olarak gömülü. `.gitignore` saygılı.
- Sonuçlar akış hâlinde gelir — arama bitmeden ilk sonuçlar görünür.
- Dosya bulucu (`⌘P`): fuzzy skorlama, frecency ağırlıklı.
- Komut paleti (`⌘⇧P`) ve sembol arama (`⌘T`) aynı altyapıyı kullanır.

### 4.9 Proje ve dosya sistemi — `kern-project`

- FSEvents ile izleme, debounce'lu. Harici değişiklikte buffer yeniden yüklenir (kirli ise çakışma UI'ı).
- Çok köklü çalışma alanı (multi-root workspace).
- Oturum durumu: açık sekmeler, imleç konumları, scroll, katlama durumu — `~/Library/Application Support/Kern/sessions/`.
- Sandbox uyumlu: security-scoped bookmark ile dizin erişimi kalıcılaştırılır.

### 4.10 Konfigürasyon — `kern-config`

- `settings.json` (kullanıcı) + `.kern/settings.json` (proje) katmanlı birleşim.
- `keymap.json` — varsayılan macOS şeması; VS Code ve Vim preset'leri hazır gelir.
- Vim modu v1 kapsamında değil, mimari buna engel olmayacak şekilde tasarlanır (komut yolu modal girdiye hazır).
- Tema JSON: tree-sitter token adı → renk. Sistem görünümüyle otomatik açık/koyu geçiş.

---

## 5. Apple'a özgü entegrasyonlar

Bunlar Kern'i "macOS'ta çalışan editör" değil "macOS editörü" yapan şeyler:

- Gerçek NSMenu — Services menüsü dahil
- Tam VoiceOver desteği (erişilebilirlik ağacı, satır satır okuma)
- Native IME — Japonca/Çince/Korece giriş, ölü tuşlar, Türkçe klavye
- ProMotion 120Hz adaptif frame rate
- Apple Silicon: NEON SIMD ile arama ve UTF-8 doğrulama, universal binary
- Keychain — API anahtarları ve git kimlik bilgileri
- Quick Look — dosya ağacında Space tuşu
- Core Spotlight — proje sembolleri Spotlight'ta aranabilir
- Handoff — bir Mac'te açık dosya diğerinde devam eder
- Liquid Glass (macOS 26 Tahoe) materyalleri — kenar çubuğu ve paletlerde
- Sandbox + hardened runtime + notarization
- Sparkle 2 ile otomatik güncelleme (veya kendi delta updater'ı)

---

## 6. Performans bütçeleri

Bunlar hedef değil, **kabul kriteri**. CI'da ölçülür, aşılırsa merge yok.

| Ölçüm | Bütçe |
|---|---|
| Tuş → piksel | < 8 ms (p99) |
| Soğuk açılış | < 400 ms |
| 100MB dosya açma | < 600 ms |
| 1GB dosya açma | < 3 s (highlight kapalı) |
| Artımlı parse (1 karakter) | < 1 ms |
| Proje araması (100k dosya) | ilk sonuç < 100 ms |
| Boşta RAM (orta proje) | < 250 MB |
| Boşta CPU | %0 |

Ölçülen (M-serisi, release, `cargo test --release -p kern-core -- --ignored --nocapture`):

| Dosya | Açma | İlk ekran | Renklendirme | Ortadan düzenleme | Arama |
|---|---|---|---|---|---|
| 50 MB (2.4M satır) | 24 ms | < 1 ms | 3.0 s (arka planda, arayüz beklemez) | < 1 ms | 356 ms |
| 1 GB (50M satır) | 431 ms | < 1 ms | kapalı (sınır 50 MB) | < 1 ms | 375 ms |

---

## 7. Yol haritası

### v0.1 — "Metin görünüyor" (4–6 hafta)
Rust workspace + Xcode projesi iskeleti · swift-bridge FFI sınırı · rope buffer + undo · Metal glyph render · dosya aç/kaydet · imleç, seçim, temel klavye · `kern` CLI
**Çıkış kriteri:** 100MB dosyayı açıp akıcı scroll edebilmek.

### v0.2 — "Editör gibi" (4 hafta)
tree-sitter + highlight · çok imleç · dosya ağacı · sekmeler ve split · dosya içi arama/değiştir · ayarlar ve tema · otomatik girinti, parantez eşleme

### v0.3 — "Dil zekâsı" (5 hafta)
LSP client · completion, hover, go-to, rename, diagnostics · sunucu otomatik indirme · komut paleti · `⌘P` fuzzy dosya bulucu · proje geneli arama

### v0.4 — "Terminal" (3 hafta)
PTY + VT emülasyonu · split terminal · shell entegrasyonu · tıklanabilir yollar · görev (task) çalıştırıcı

### v0.5 — "AI" (5 hafta)
Claude entegrasyonu · inline completion · sohbet paneli · diff uygulama · agent modu + onay akışı · bağlam derleyici · Keychain

### v0.6 — "Eklentiler" (5 hafta)
wasmtime host · WIT API · izin modeli · eklenti registry ve kurulum UI'ı · ilk parti gramer/tema paketleri · `EXTENSION-API.md`

### v0.7 — "Git" (3 hafta)
gix entegrasyonu · diff gutter, blame · stage/commit/push · branch switcher · merge conflict editörü

### v0.8 — "Debug" (4 hafta)
DAP client · breakpoint, step, watch, call stack · değişken inceleyici · launch konfigürasyonu

### v0.9 — "Cilalama" (4 hafta)
Erişilebilirlik denetimi · IME testleri · performans bütçelerinin tutturulması · çökme raporlama · Sparkle güncelleme · sandbox + notarization

### v1.0 — Dağıtım
DMG + Homebrew cask · dokümantasyon sitesi · sürüm notları

**Toplam: ~9–10 ay tek geliştirici temposunda.**

---

## 8. Riskler

| Risk | Etki | Önlem |
|---|---|---|
| FFI sınırı bulanıklaşır, iki dilde aynı mantık yazılır | Yüksek | Sınır kuralı (§2) her PR'da denetlenir; `kern-ffi` dışında Swift'e açılan API yok |
| Metal metin render'ı beklenenden zor (subpixel, ligatür, RTL) | Yüksek | Shaping tamamen CoreText'e bırakılır; v0.1'de bu risk erken test edilir |
| LSP sunucu çeşitliliği — her sunucu spec'i farklı yorumluyor | Orta | Sunucu başına uyumluluk katmanı; en çok kullanılan 10 sunucu ile test matrisi |
| Kapsam patlaması | Yüksek | Faz çıkış kriterleri katı; v1'de yok denen şey (Vim modu, uzak geliştirme, notebook, canlı paylaşım) v1'e girmez |
| WASM component model henüz olgunlaşıyor | Orta | Eklenti API'si v1'de "kararsız" etiketli; kırıcı değişiklik hakkı saklı |
| Tek geliştirici, 10 aylık takvim | Orta | Her faz bağımsız kullanılabilir bir editör bırakır; erken durulabilir |

---

## 9. Sonraki adım

`v0.1` iskeleti: Cargo workspace, Xcode projesi, swift-bridge köprüsü ve ekrana metin basan ilk Metal frame.
