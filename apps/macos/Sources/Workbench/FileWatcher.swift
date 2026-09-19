import CoreServices
import Foundation

// FSEvents: izlenen yollardaki değişiklikleri debounce'lu bildirir
final class FileWatcher {
    var onChange: (([String]) -> Void)?
    private var stream: FSEventStreamRef?
    private var paths: Set<String> = []

    func watch(_ newPaths: Set<String>) {
        guard newPaths != paths else { return }
        stop()
        paths = newPaths
        guard !paths.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, _, _ in
            guard let info else { return }
            let me = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
            me.onChange?(Array(list.prefix(count)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &ctx, Array(paths) as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
        paths = []
    }

    deinit { stop() }
}
