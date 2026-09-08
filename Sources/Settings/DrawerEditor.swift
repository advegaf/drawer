import AppKit
import SwiftUI

struct DrawerDrag: Codable, Identifiable, Equatable {
    enum Source: String, Codable { case library, pinned }
    let id: String
    let itemID: String
    let source: Source
    let token: UUID


}

struct EditorEntry: Identifiable {
    let item: DrawerItem
    let cell: DrawerCell
    let available: Bool
    let detail: String
    var id: String { item.id }

    @MainActor
    static func action(_ id: ActionID) -> EditorEntry {
        let spec = ActionRegistry.spec(for: id)
        let available = ActionRegistry.isAvailable(id)
        let kind = ActionRegistry.kind[id] ?? .fire(destructive: false)
        let state: CellState = !available ? .unavailable : kind == .level ? .level(0.5) : kind == .toggle ? .on : .ready
        let item = DrawerItem.action(id.rawValue)
        return EditorEntry(item: item, cell: DrawerCell(id: item.id, title: spec.title,
            icon: .symbol(spec.symbol), kind: kind, state: state), available: available,
            detail: available ? spec.detail : "Unavailable on this Mac")
    }

    @MainActor
    static func app(_ entry: AppEntry) -> EditorEntry {
        let item = DrawerItem.app(bundleID: entry.bundleID)
        return EditorEntry(item: item, cell: DrawerCell(id: item.id, title: entry.name,
            icon: .image(AppCatalog.icon(for: entry)), kind: .launch, state: .ready),
            available: true, detail: "App")
    }

    static func shortcut(_ name: String) -> EditorEntry {
        let item = DrawerItem.shortcut(name: name)
        return EditorEntry(item: item, cell: DrawerCell(id: item.id, title: name,
            icon: .symbol("square.2.layers.3d.fill"), kind: .shortcut, state: .ready),
            available: true, detail: "Shortcut")
    }

    static func missing(_ item: DrawerItem) -> EditorEntry {
        let title: String
        let kind: Kind
        let state: CellState
        switch item {
        case .app(let id): title = id; kind = .launch; state = .notInstalled
        case .shortcut(let name): title = name; kind = .shortcut; state = .notFound
        case .action(let id): title = id; kind = .fire(destructive: false); state = .unavailable
        }
        return EditorEntry(item: item, cell: DrawerCell(id: item.id, title: title,
            icon: .symbol("questionmark.circle"), kind: kind, state: state), available: false,
            detail: state.label)
    }
}

@MainActor
final class DrawerEditor: ObservableObject {
    var ownsUndoFocus = false
    private var cancelledFileSequences = Set<Int>()
    @Published var selection: String?
    @Published private(set) var drag: DrawerDrag?
    @Published var session: EditorDragSession?
    @Published var incomingEntries: [EditorEntry] = []
    @Published private(set) var importedApps: [String: EditorEntry] = [:]
    @Published var isTargeted = false
    @Published private(set) var status = ""

    private func begin(id: String, itemID: String, source: DrawerDrag.Source) -> DrawerDrag {
        if let drag, drag.id == id, drag.itemID == itemID, drag.source == source { return drag }
        let value = DrawerDrag(id: id, itemID: itemID, source: source, token: UUID())
        drag = value
        return value
    }

    func beginNative(_ entry: EditorEntry, source: DrawerDrag.Source, items: [DrawerItem]) -> NativeEditorDrag? {
        guard session == nil, source == .pinned || (entry.available && !items.contains(where: { $0.id == entry.id })) else { return nil }
        if source == .pinned, !items.contains(entry.item) { return nil }
        let payload = begin(id: source.rawValue + "|" + entry.id, itemID: entry.id, source: source)
        session = EditorDragSession(input: .local(payload), baseline: items, incoming: [entry.item],
                                    movingID: source == .pinned ? entry.id : nil)
        incomingEntries = [entry]
        let image: NSImage
        switch entry.cell.icon {
        case .image(let value): image = value
        case .symbol(let name): image = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
        }
        return NativeEditorDrag(payload: payload, image: image)
    }

    func prepare(_ input: EditorDragInput, items: [DrawerItem], library: [EditorEntry]) -> Bool {
        if let session {
            guard session.input == input, session.baseline == items, case .active = session.phase else { cancel(); return false }
            if case .local(let payload) = input, payload.source == .library {
                guard library.contains(where: { $0.id == payload.itemID && $0.available }) else { cancel(); return false }
            }
            return true
        }
        guard case .files(let urls, let sequence) = input, !cancelledFileSequences.contains(sequence) else { return false }
        guard let validated = FinderAppValidation.entries(urls) else {
            if status != "Drop only valid app bundles." { announce("Drop only valid app bundles.") }
            return false
        }
        let additions = validated.filter { app in !items.contains { $0.id == DrawerItem.app(bundleID: app.bundleID).id } }
        guard !additions.isEmpty else {
            if status != "These apps are already in the drawer." { announce("These apps are already in the drawer.") }
            return false
        }
        incomingEntries = additions.map(EditorEntry.app)
        session = EditorDragSession(input: input, baseline: items, incoming: incomingEntries.map(\.item), movingID: nil)
        return true
    }

    func commitNative(_ input: EditorDragInput, preferences: Preferences, library: [EditorEntry], undoManager: UndoManager?) -> Bool {
        guard prepare(input, items: preferences.items, library: library), var pending = session else { return false }
        let neighbor = pending.neighbor
        if case .files(let urls, _) = input {
            guard let validated = FinderAppValidation.entries(urls) else { reject("The dropped apps are no longer available."); return false }
            let additions = validated.map { DrawerItem.app(bundleID: $0.bundleID) }.filter { item in !preferences.items.contains { $0.id == item.id } }
            guard additions == pending.incoming else { reject("The dropped apps changed. Try again."); return false }
        }
        guard pending.accept(current: preferences.items) else { cancel(); return false }
        session = pending
        let committed: Bool
        switch input {
        case .local(let payload):
            if payload.source == .pinned { committed = preferences.commit(.move(id: payload.itemID, before: neighbor), undoManager: undoManager) }
            else { committed = preferences.commit(.add(pending.incoming[0], before: neighbor), undoManager: undoManager) }
        case .files:
            committed = preferences.commitApps(pending.incoming, before: neighbor, undoManager: undoManager)
        }
        if committed {
            selection = pending.incoming.first?.id
            if case .files = input {
                for entry in incomingEntries {
                    let available: Bool
                    if case .app(let id) = entry.item { available = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil }
                    else { available = false }
                    let cell = DrawerCell(id: entry.id, title: entry.cell.title, icon: entry.cell.icon,
                                          kind: entry.cell.kind, state: available ? .ready : .notInstalled)
                    importedApps[entry.id] = EditorEntry(item: entry.item, cell: cell, available: available,
                                                        detail: available ? "App" : "Unavailable on this Mac")
                }
            }
        }
        cancel()
        if committed {
            let missing = pending.incoming.filter { importedApps[$0.id]?.available == false }.count
            announce(missing > 0 ? "Apps added. \(missing) unavailable until macOS can locate them." : "Drawer updated.")
        }
        return committed
    }

    func clearStatus() { status = "" }

    func historyDidChange(redo: Bool) {
        cancel()
        announce(redo ? "Change redone." : "Change undone.")
    }

    func cancel() {
        if case .files(_, let sequence) = session?.input {
            cancelledFileSequences.insert(sequence)
        }
        drag = nil
        session = nil
        incomingEntries = []
        isTargeted = false
    }

    func announce(_ text: String) {
        status = text
        if let window = NSApp.keyWindow {
            NSAccessibility.post(element: window, notification: .announcementRequested,
                userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }

    private func reject(_ text: String) {
        cancel()
        Log.drawer.debug("editor rejected drop")
        announce(text)
    }

    static func nextSelection(afterRemoving id: String, from items: [DrawerItem]) -> String? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return items.first?.id }
        return items.indices.contains(index + 1) ? items[index + 1].id : index > 0 ? items[index - 1].id : nil
    }

    static func moveTarget(id: String, later: Bool, items: [DrawerItem]) -> String? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        if later { return items.indices.contains(index + 2) ? items[index + 2].id : nil }
        return index > 0 ? items[index - 1].id : id
    }
}
