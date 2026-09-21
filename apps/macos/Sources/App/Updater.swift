import AppKit
import Sparkle

// Sparkle ile otomatik güncelleme; imzalama anahtarı (SUPublicEDKey) boşsa kapalı kalır
final class Updater: NSObject, SPUUpdaterDelegate {
    static let shared = Updater()

    private var controller: SPUStandardUpdaterController?

    // Info.plist'te hem besleme adresi hem genel anahtar varsa açılır
    var isConfigured: Bool {
        let info = Bundle.main.infoDictionary
        let feed = info?["SUFeedURL"] as? String ?? ""
        let key = info?["SUPublicEDKey"] as? String ?? ""
        return !feed.isEmpty && !key.isEmpty
    }

    func start() {
        guard isConfigured, controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        controller?.updater.automaticallyChecksForUpdates = Settings.shared.bool("update.automatic")
    }

    func checkForUpdates() {
        guard isConfigured else {
            let alert = NSAlert()
            alert.messageText = "Updates aren’t configured for this build."
            alert.informativeText = "Release builds are signed and published with an appcast; see scripts/release.sh."
            alert.runModal()
            return
        }
        start()
        controller?.checkForUpdates(nil)
    }
}
