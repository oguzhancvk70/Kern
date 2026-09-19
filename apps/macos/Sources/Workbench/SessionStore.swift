import CryptoKit
import Foundation

// klasör başına açık sekmeler: ~/Library/Application Support/Kern/sessions/<hash>.json
struct Session: Codable {
    struct Entry: Codable {
        var path: String
        var line: Int
        var col: Int
        var top: Int
    }
    var folder: String
    var tabs: [Entry]
    var active: Int
}

enum SessionStore {
    static var directory: URL {
        Settings.directory.appendingPathComponent("sessions", isDirectory: true)
    }

    static func file(for folder: URL) -> URL {
        let digest = Insecure.SHA1.hash(data: Data(folder.standardizedFileURL.path.utf8))
        return directory.appendingPathComponent(digest.map { String(format: "%02x", $0) }.joined() + ".json")
    }

    static func load(_ folder: URL) -> Session? {
        guard let data = try? Data(contentsOf: file(for: folder)) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    static func save(_ session: Session, for folder: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(session) else { return }
        try? data.write(to: file(for: folder), options: .atomic)
    }
}
