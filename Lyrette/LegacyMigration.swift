import Foundation
import ServiceManagement

/// Lyrette used to be called LyricBar (bundle ID com.rigelra.LyricBar). macOS treats the new bundle
/// ID as a different app, so on first launch carry over what the old app left behind.
enum LegacyMigration {
    private static let legacyBundleID = "com.rigelra.LyricBar"
    private static let doneKey = "didMigrateFromLyricBar"
    private static let carriedKeys = ["lyricsOffsetsV2", "lyricsOffsets", "lyricsSourcePreference"]

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }

        guard let legacy = UserDefaults(suiteName: legacyBundleID) else { return }
        for key in carriedKeys where defaults.object(forKey: key) == nil {
            if let value = legacy.object(forKey: key) { defaults.set(value, forKey: key) }
        }

        moveLegacyCache()

        // The old app records this right before it hands over to Lyrette and removes its own login item.
        if legacy.bool(forKey: "migratedLaunchAtLogin"), SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
    }

    private static func moveLegacyCache() {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let old = base.appendingPathComponent("LyricBarCache", isDirectory: true)
        let new = base.appendingPathComponent("LyretteCache", isDirectory: true)
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        try? fm.moveItem(at: old, to: new)
    }
}
