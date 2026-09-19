import AppKit

// Material Icon Theme (MIT) — Resources/FileIcons
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    private static let folders: [String: String] = [
        "src": "src", "source": "src", "sources": "src",
        "doc": "docs", "docs": "docs", "documentation": "docs",
        "script": "scripts", "scripts": "scripts",
        "app": "app", "apps": "app",
        "crates": "packages", "packages": "packages", "pkg": "packages",
        "cli": "command", "bin": "command", "cmd": "command", "console": "console",
        "lib": "lib", "libs": "lib",
        "test": "test", "tests": "test", "spec": "test", "__tests__": "test",
        "images": "images", "img": "images", "icons": "images",
        "resources": "resource", "res": "resource", "assets": "resource", "static": "resource",
        ".git": "git", ".github": "github", ".vscode": "vscode", "node_modules": "node",
        "target": "target", "target.nosync": "target",
        "dist": "dist", "build": "dist", "out": "dist", "release": "dist", "debug": "dist",
        "config": "config", "configs": "config", ".cargo": "config", ".config": "config", "settings": "config",
        ".claude": "claude", "theme": "theme", "themes": "theme", "components": "components",
        "public": "public", "examples": "examples", "example": "examples", "samples": "examples",
        "include": "include", "plugins": "plugin", "extensions": "plugin",
        "core": "core", "ui": "ui", "views": "views", "view": "views", "rust": "rust",
        "tools": "tools", "helpers": "helper", "helper": "helper", "utils": "utils", "util": "utils",
        "server": "server", "api": "api", "desktop": "desktop", "macos": "desktop",
        "tmp": "temp", "temp": "temp", "private": "private", "env": "environment", "environment": "environment",
    ]

    private static let names: [String: String] = [
        ".gitignore": "git", ".gitattributes": "git", ".gitmodules": "git", ".gitkeep": "git",
        "cargo.toml": "rust", "cargo.lock": "rust",
        "package.json": "nodejs", "package-lock.json": "nodejs",
        "readme.md": "readme", "readme": "readme",
        "license": "certificate", "license.md": "certificate", "licence": "certificate",
        "dockerfile": "docker", "docker-compose.yml": "docker", "makefile": "makefile",
        "tsconfig.json": "tsconfig", ".editorconfig": "editorconfig",
        "claude.md": "claude", "agents.md": "claude", ".env": "tune", ".env.local": "tune",
    ]

    private static let extensions: [String: String] = [
        "rs": "rust", "swift": "swift", "js": "javascript", "mjs": "javascript", "cjs": "javascript",
        "jsx": "react", "ts": "typescript", "mts": "typescript", "cts": "typescript", "tsx": "react_ts",
        "json": "json", "jsonc": "json", "md": "markdown", "markdown": "markdown",
        "py": "python", "pyi": "python", "go": "go", "c": "c", "h": "h", "metal": "c",
        "cpp": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "hpp", "hh": "hpp",
        "html": "html", "htm": "html", "css": "css", "scss": "sass", "sass": "sass",
        "toml": "toml", "yml": "yaml", "yaml": "yaml",
        "sh": "console", "bash": "console", "zsh": "console", "fish": "console", "lock": "lock",
        "png": "image", "jpg": "image", "jpeg": "image", "gif": "image", "webp": "image", "ico": "image",
        "bmp": "image", "heic": "image", "tiff": "image", "icns": "image", "svg": "svg",
        "txt": "document", "rtf": "document", "pdf": "pdf",
        "zip": "zip", "gz": "zip", "tar": "zip", "tgz": "zip", "xz": "zip", "7z": "zip", "rar": "zip",
        "xml": "xml", "sql": "database", "db": "database", "sqlite": "database",
        "java": "java", "kt": "kotlin", "kts": "kotlin", "rb": "ruby", "php": "php", "cs": "csharp",
        "lua": "lua", "vue": "vue", "svelte": "svelte", "dart": "dart", "log": "log",
        "csv": "table", "tsv": "table", "wasm": "webassembly",
        "ttf": "font", "otf": "font", "woff": "font", "woff2": "font",
        "mp4": "video", "mov": "video", "webm": "video", "mp3": "audio", "wav": "audio", "m4a": "audio", "flac": "audio",
        "xcconfig": "settings", "plist": "settings", "entitlements": "settings", "ini": "settings", "conf": "settings",
    ]

    static func icon(for name: String, directory: Bool, open: Bool = false) -> NSImage? {
        let lower = name.lowercased()
        if directory {
            let base = folders[lower].map { "folder-\($0)" } ?? "folder"
            return open ? (image(base + "-open") ?? image(base)) : image(base)
        }
        let key = names[lower] ?? extensions[(lower as NSString).pathExtension] ?? "file"
        return image(key) ?? image("file")
    }

    private static func image(_ name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "FileIcons"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 16, height: 16)
        cache[name] = image
        return image
    }
}
