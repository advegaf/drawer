import AppKit
import Foundation

/// One installed app, for the Items page's Apps section.
struct AppEntry: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let url: URL
    var id: String { bundleID }
}

/// Every app under `/Applications`, `/System/Applications` and
/// `~/Applications`, for the Apps section's list and search. `apps` stays nil
/// until `load()` finishes, so a row can tell "loading" apart from "loaded
/// and there is nothing".
@MainActor
final class AppCatalog: ObservableObject {
    @Published var apps: [AppEntry]?

    private static let iconCache = NSCache<NSString, NSImage>()

    /// The three places apps live, one level deep. Enumerating and reading
    /// bundle info off the main actor: `contentsOfDirectory` and `Bundle`
    /// hit disk for every app, and there can be a few hundred of them.
    func load() async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let directories = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            home.appendingPathComponent("Applications"),
        ]
        apps = await Task.detached { Self.entries(in: directories) }.value
    }

    /// The enumeration itself, pulled out as a plain nonisolated function so
    /// a test can point it at a temp directory instead of the real
    /// filesystem. Directories are read in order and a bundle id already
    /// seen is skipped, so the first directory to carry a given app wins.
    static nonisolated func entries(in directories: [URL]) -> [AppEntry] {
        var seenIDs = Set<String>()
        var result: [AppEntry] = []
        for directory in directories {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for url in contents where url.pathExtension == "app" {
                let bundle = Bundle(url: url)
                guard let bundleID = bundle?.bundleIdentifier, seenIDs.insert(bundleID).inserted else { continue }
                let name = nonEmpty(bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? nonEmpty(bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                result.append(AppEntry(bundleID: bundleID, name: name, url: url))
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Substring, case-insensitive, against the loaded list. Empty while
    /// still loading, same as an empty result.
    func filtered(_ query: String) -> [AppEntry] {
        guard let apps else { return [] }
        guard !query.isEmpty else { return apps }
        return apps.filter { $0.name.range(of: query, options: .caseInsensitive) != nil }
    }

    /// 32pt icons, cached by bundle id: `NSWorkspace.shared.icon(forFile:)`
    /// is not cheap, and every row asks for its own each time SwiftUI
    /// redraws the list.
    static func icon(for entry: AppEntry) -> NSImage {
        if let cached = iconCache.object(forKey: entry.bundleID as NSString) { return cached }
        let image = NSWorkspace.shared.icon(forFile: entry.url.path(percentEncoded: false))
        image.size = NSSize(width: 32, height: 32)
        iconCache.setObject(image, forKey: entry.bundleID as NSString)
        return image
    }
}

private func nonEmpty(_ string: String?) -> String? {
    guard let string, !string.isEmpty else { return nil }
    return string
}
