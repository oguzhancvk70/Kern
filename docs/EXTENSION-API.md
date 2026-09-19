# Kern Extension API (v1, unstable)

An extension is a folder with a `kern-extension.json` manifest. Declarative contributions (themes, snippets, language servers, keybindings) need no code. Commands run as a WebAssembly module inside Kern, limited by fuel (CPU) and memory, and they can only call the host functions their permissions allow.

Extensions are loaded from two places:

- `Kern.app/Contents/Resources/extensions/`: built-in; cannot be uninstalled.
- `~/Library/Application Support/Kern/extensions/`: user-installed. Use **Extensions → Install Extension from Folder…**, which shows the requested permissions and asks for approval before installing.

If two extensions share an `id`, the user-installed one wins.

## Manifest

```json
{
  "id": "acme.tools",
  "name": "Acme Tools",
  "version": "1.0.0",
  "description": "…",
  "main": "tools.wasm",
  "permissions": ["editor:read", "editor:write"],
  "contributes": {
    "commands":        [{ "id": "upper", "title": "Transform to Uppercase" }],
    "keybindings":     [{ "key": "cmd+alt+u", "command": "upper" }],
    "themes":          [{ "name": "Acme Dark", "type": "dark", "colors": { "background": "#101010" }, "tokens": { "keyword": "#FF8800" } }],
    "snippets":        { "Rust": [{ "prefix": "fnmain", "body": "fn main() {\n    $0\n}", "description": "main" }] },
    "languageServers": { "python": "pylsp" }
  }
}
```

| Field | Notes |
|---|---|
| `id` | `[A-Za-z0-9._-]+`, unique |
| `main` | Optional. A `.wasm` or `.wat` module inside the folder. Commands need it. |
| `permissions` | Any of `editor:read`, `editor:write`, `fs:read`, `ui`. Unknown permissions reject the manifest. |
| `themes[].colors` | `background text lineNumber activeLineNumber currentLineBorder selection inactiveSelection cursor indentGuide bracketMatch findMatch scrollbar`; `#RRGGBB` or `#RRGGBBAA` |
| `themes[].tokens` | `none keyword control string comment function type variable number constant property operator punctuation attribute tag escape module` |
| `snippets` | Key is the Kern language name (`Rust`, `Swift`, `Python`, `JavaScript`, …). `$1`, `${1:x}` placeholders are inserted as plain text. |
| `languageServers` | Server key → command line. Keys: `rust c swift python typescript go java lua shell`. The user's `lsp.servers` setting overrides these. |
| `keybindings` | Same syntax as `keymap.json`. A `command` without `:` refers to this extension's command. |

## Wasm ABI

The module is a core WebAssembly module (not a component). It must export:

| Export | Signature | |
|---|---|---|
| `memory` | memory | |
| `kern_alloc` | `(len: i32) -> i32` | Returns a buffer; the host writes the command id into it. |
| `kern_command` | `(id_ptr: i32, id_len: i32) -> i32` | Runs a command. `0` means success; any other value is reported as an error. |

Host imports come from module `"kern"`. Strings are UTF-8 `(ptr, len)` pairs.

| Import | Signature | Permission |
|---|---|---|
| `log(ptr, len)` | | none |
| `ctx_get(key_ptr, key_len, buf, cap) -> len` | Keys: `text`, `selection`, `path`, `language`. Returns the full length; the value is written only if it fits in `cap`, so call again with a bigger buffer if needed. | `editor:read` for `text` and `selection` |
| `read_file(path_ptr, path_len, buf, cap) -> len` | Path relative to the project root; paths outside the root are refused. Returns `-1` if denied, `-2` if unreadable. | `fs:read` |
| `action(kind_ptr, kind_len, val_ptr, val_len) -> i32` | `replace_selection` and `insert` need `editor:write`; `status` and `message` need `ui`. Returns `-1` if denied. | see left |

Actions are collected while the command runs and applied to the editor afterwards, all at once.

**Limits:** 200M fuel units and 64 MB of memory per command. A command that runs out is stopped and reported ("ran too long"); the editor never freezes.

## Example

`apps/macos/Resources/extensions/kern.text-tools/` is a complete command extension written in WAT. It needs no build step.

## Not yet supported

- Tree-sitter grammars shipped as extensions.
- WIT / component-model interfaces.
- An online registry.
- A separate extension host process. Commands run in-process and are isolated by the wasm sandbox and its limits.
