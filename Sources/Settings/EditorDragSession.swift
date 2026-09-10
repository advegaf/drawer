import AppKit

enum EditorDragInput: Equatable {
    case local(DrawerDrag)
    case files([URL], sequence: Int)
}

struct EditorDragSession: Equatable {
    enum Position: Equatable { case before(String), after(String), end }
    enum Phase: Equatable { case active(Position?), accepted, cancelled }
    let input: EditorDragInput
    let baseline: [DrawerItem]
    let incoming: [DrawerItem]
    let movingID: String?
    private(set) var phase: Phase = .active(nil)

    var neighbor: String? {
        guard case .active(let position) = phase, let position else { return nil }
        switch position {
        case .before(let id): return id
        case .after(let id): return baseline.drop { $0.id != id }.dropFirst().first { $0.id != movingID }?.id
        case .end: return nil
        }
    }

    var displayed: [DrawerItem] {
        guard case .active(.some) = phase else { return baseline }
        var result = baseline.filter { $0.id != movingID }
        let index = neighbor.flatMap { id in result.firstIndex { $0.id == id } } ?? result.count
        result.insert(contentsOf: incoming, at: index)
        return result
    }

    mutating func propose(_ position: Position, current: [DrawerItem]) -> Bool {
        guard case .active = phase else { return false }
        guard current == baseline else { phase = .cancelled; return false }
        switch position {
        case .before(let id), .after(let id):
            guard id != movingID, baseline.contains(where: { $0.id == id }) else { return false }
        case .end: break
        }
        phase = .active(position)
        return true
    }

    mutating func accept(current: [DrawerItem]) -> Bool {
        guard current == baseline, case .active(.some) = phase, displayed != baseline else { return false }
        phase = .accepted
        return true
    }

    mutating func clearProposal() { if case .active = phase { phase = .active(nil) } }

    mutating func cancel() { if case .active = phase { phase = .cancelled } }
}

enum FinderAppValidation {
    static func entries(_ urls: [URL]) -> [AppEntry]? {
        guard !urls.isEmpty else { return nil }
        var seen = Set<String>()
        var result: [AppEntry] = []
        for original in urls {
            guard original.isFileURL else { return nil }
            let url = original.resolvingSymlinksInPath().standardizedFileURL
            guard url.pathExtension.lowercased() == "app",
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey]),
                  values.isDirectory == true, values.isReadable == true,
                  let bundle = Bundle(url: url),
                  bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
                  let id = bundle.bundleIdentifier, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let executable = bundle.executableURL,
                  FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
            guard seen.insert(id).inserted else { continue }
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            result.append(AppEntry(bundleID: id, name: name, url: url))
        }
        return result
    }
}
