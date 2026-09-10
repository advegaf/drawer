import AppKit
import SwiftUI

struct ItemsPage: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var shortcuts: ShortcutsCatalog
    @ObservedObject var apps: AppCatalog
    @ObservedObject var editor = DrawerEditor()
    @ObservedObject var session = SettingsSession()
    @FocusState private var focus: Focus?
    var undoManager: UndoManager? = nil
    var levelStates: [ActionID: CellState]? = nil
    @FocusState private var focusedLibrary: String?
    @State private var hoveredLibraryRow: String?
    /// A screenshot lever, and the only way to photograph a hover state:
    /// `CGWarpMouseCursorPosition` moves the pointer without generating a
    /// mouse-moved event, so a capture script can put the pointer on a row
    /// and SwiftUI's `onHover` never fires. Debug builds only, and it names
    /// one library row.
    private var forcedHoverRow: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["DRAWER_LIBRARY_HOVER"]
        #else
        nil
        #endif
    }
    @State private var overflowAbove = false
    @State private var overflowBelow = false
    @State private var keyboardFocus = false
    @State private var screenAspect: CGFloat = 1.6
    /// Starts at the height the page has in a window opened at its
    /// default size: the window's 1000 less this page's own 24 of padding
    /// top and bottom. Without it the first frame draws the canvas at the
    /// floor and the second one jumps.
    @State private var pageHeight: CGFloat = 952

    private enum Focus: Hashable { case search, preview }

    private var library: [EditorEntry] {
        ActionRegistry.ordered.map(EditorEntry.action)
            + (apps.apps ?? []).map(EditorEntry.app)
            + Array(Set(shortcuts.names ?? [])).sorted().map(EditorEntry.shortcut)
    }

    private var visibleEntries: [EditorEntry] {
        library.filter { entry in
            let matchesCategory: Bool
            switch (session.category, entry.item) {
            case (.actions, .action), (.apps, .app), (.shortcuts, .shortcut): matchesCategory = true
            default: matchesCategory = false
            }
            return matchesCategory && (session.query.isEmpty || entry.cell.title.localizedStandardContains(session.query))
        }
    }

    private var pinned: [EditorEntry] {
        let entries = Dictionary(library.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return preferences.items.map { item in
            let entry: EditorEntry
            if let known = entries[item.id] ?? editor.importedApps[item.id] { entry = known }
            else if case .app(let id) = item, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                let bundle = Bundle(url: url)
                let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
                entry = EditorEntry.app(AppEntry(bundleID: id, name: name, url: url))
            } else { entry = EditorEntry.missing(item) }
            guard let levelStates, case .action(let raw) = item, let id = ActionID(rawValue: raw),
                  id == .volume || id == .brightness else { return entry }
            let state = levelStates[id] ?? .unknown
            let cell = DrawerCell(id: entry.id, title: entry.cell.title, icon: entry.cell.icon, kind: entry.cell.kind, state: state)
            return EditorEntry(item: item, cell: cell, available: entry.available, detail: entry.detail)
        }
    }

    /// Items and Appearance are one view because they share the preview.
    /// The banner is pinned above whatever the page puts under it, never
    /// inside a scroll view: a library row below the fold would otherwise
    /// scroll the preview off screen and leave a drag from that row with
    /// nowhere to land.
    var body: some View {
        VStack(spacing: SettingsStyle.s24) {
            previewView
            Group {
                if session.page == .appearance { AppearancePage(preferences: preferences) }
                else { libraryCard }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(SettingsStyle.s24)
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
            editor.cancel()
            pageHeight = size.height
        }
        .onAppear { if editor.selection == nil { editor.selection = preferences.items.first?.id }; refreshScreen() }
        .onChange(of: preferences.items) { _, current in
            if let session = editor.session, case .active = session.phase, session.baseline != current { editor.cancel() }
        }
        .onChange(of: preferences.notchEdge) { editor.cancel() }
        .onChange(of: preferences.theme.metrics) { editor.cancel() }
        .onChange(of: session.category) { focus = nil; editor.ownsUndoFocus = false; keyboardFocus = false }
        .onKeyPress(.tab) { keyboardFocus = true; return .ignored }
        .onChange(of: focus) { editor.ownsUndoFocus = focus == .preview }
        .onDisappear { editor.cancel(); editor.ownsUndoFocus = false }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in refreshScreen() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in editor.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerWillUndoChange, object: undoManager)) { _ in editor.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerWillRedoChange, object: undoManager)) { _ in editor.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange, object: undoManager)) { notification in
            guard let manager = notification.object as? UndoManager, manager === undoManager else { return }
            editor.historyDidChange(redo: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidRedoChange, object: undoManager)) { notification in
            guard let manager = notification.object as? UndoManager, manager === undoManager else { return }
            editor.historyDidChange(redo: true)
        }
        .navigationTitle(session.page.title)
        .task { if apps.apps == nil { await apps.load() } }
    }

    /// The library, as one card that fills whatever the banner leaves and
    /// scrolls inside itself. The card scrolls, not the page: the list
    /// already carries its own overflow cues and a reader that scrolls to
    /// the focused row, and neither survives being nested in a second
    /// vertical scroll view.
    private var libraryCard: some View {
        SettingsCard(padding: SettingsStyle.s16) {
            VStack(alignment: .leading, spacing: SettingsStyle.s12) {
                SettingsSectionHeader("Library") {
                    Picker("Category", selection: $session.category) {
                        ForEach(LibraryCategory.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }

                searchField

                if session.category == .shortcuts {
                    if shortcuts.isLoading { ProgressView("Loading shortcuts").controlSize(.small) }
                    if shortcuts.failed {
                        HStack {
                            Text(shortcuts.names == nil ? "Couldn't load shortcuts." : "Couldn't refresh. Showing saved results.")
                                .settingsFont(SettingsStyle.captionLight).foregroundStyle(SettingsStyle.textSecondary)
                            Button("Retry") { Task { await shortcuts.reload() } }.disabled(shortcuts.isLoading)
                        }
                    }
                }
                if session.category == .apps && apps.apps == nil {
                    ProgressView("Loading apps").controlSize(.small)
                }

                Divider()
                libraryList
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: SettingsStyle.s8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(SettingsStyle.textSecondary).accessibilityHidden(true)
            TextField("Search items", text: $session.query)
                .textFieldStyle(.plain).focused($focus, equals: .search).focusEffectDisabled()
                .accessibilityLabel("Search items")
            if !session.query.isEmpty {
                Button { session.query = ""; focus = .search } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10).frame(height: 32)
        .background(focus == .search ? SettingsStyle.accent.opacity(0.1) : SettingsStyle.ink.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: SettingsStyle.r8))
        .overlay(alignment: .leading) {
            Capsule().fill(SettingsStyle.accent).frame(width: 3, height: 18)
                .opacity(focus == .search ? 1 : 0).allowsHitTesting(false)
        }
    }

    private var libraryList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visibleEntries) { entry in libraryRow(entry) }
                    if visibleEntries.isEmpty {
                        ContentUnavailableView(session.query.isEmpty ? "No items" : "No matches", systemImage: "magnifyingglass",
                            description: Text(session.query.isEmpty ? "Choose another category." : "Try a different search."))
                    }
                }
                .background(HiddenScrollIndicators())
            }
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: LibraryOverflow.self) { geometry in
                LibraryOverflow(above: geometry.contentOffset.y > 1,
                    below: geometry.contentOffset.y + geometry.containerSize.height < geometry.contentSize.height - 1)
            } action: { _, value in overflowAbove = value.above; overflowBelow = value.below }
            .overlay(alignment: .top) { overflowCue(up: true).opacity(overflowAbove ? 1 : 0) }
            .overlay(alignment: .bottom) { overflowCue(up: false).opacity(overflowBelow ? 1 : 0) }
            .onChange(of: focusedLibrary) { _, id in if let id { proxy.scrollTo(id) } }
        }
    }

    private func overflowCue(up: Bool) -> some View {
        Image(systemName: up ? "chevron.up" : "chevron.down")
            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            .padding(4).background(SettingsStyle.canvas, in: Capsule())
            .allowsHitTesting(false).accessibilityHidden(true)
    }

    /// One library item, in the window's own row language. The drag
    /// surface stays an overlay on the label side only: it must not cover
    /// the Add button, which is a click target of its own.
    private func libraryRow(_ entry: EditorEntry) -> some View {
        let added = preferences.items.contains { $0.id == entry.id }
        return HStack(alignment: .center, spacing: SettingsStyle.s16) {
            HStack(spacing: SettingsStyle.s12) {
                Group {
                    switch entry.cell.icon {
                    case .symbol(let name): Image(systemName: name).resizable().scaledToFit()
                    case .image(let image): Image(nsImage: image).resizable().scaledToFit()
                    }
                }
                .frame(width: 22, height: 22).accessibilityHidden(true)

                VStack(alignment: .leading, spacing: SettingsStyle.s2) {
                    Text(entry.cell.title)
                        .settingsFont(SettingsStyle.bodyMedium)
                        .foregroundStyle(SettingsStyle.ink)
                        .lineLimit(1).help(entry.cell.title)
                    if !entry.available {
                        Text(entry.detail)
                            .settingsFont(SettingsStyle.captionLight)
                            .foregroundStyle(SettingsStyle.textSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 34)
            .overlay {
                NativeEditorSurface(select: { _ in focus = nil; editor.ownsUndoFocus = false; keyboardFocus = false },
                    begin: { _ in editor.beginNative(entry, source: .library, items: preferences.items) },
                    ended: { token in if editor.drag?.token == token { editor.cancel() } }, receivesDrops: false)
            }

            if added {
                // A button in both states rather than a label that becomes
                // one under the pointer: hover is not a thing a keyboard or
                // VoiceOver can do, and this is the only way to take an item
                // out of the library's own list.
                Button { removeFromLibrary(entry) } label: {
                    if hoveredLibraryRow == entry.id || focusedLibrary == entry.id || forcedHoverRow == entry.id {
                        LibraryAddColumn.remove
                    } else {
                        LibraryAddColumn.added
                    }
                }
                .buttonStyle(.plain)
                .focused($focusedLibrary, equals: entry.id)
                .onHover { hoveredLibraryRow = $0 ? entry.id : (hoveredLibraryRow == entry.id ? nil : hoveredLibraryRow) }
                .accessibilityLabel("Remove \(entry.cell.title)")
                .accessibilityHint("Removes it from the drawer. Command Z puts it back.")
            } else {
                Button(action: { add(entry) }) { LibraryAddColumn.addLabel }
                    .buttonStyle(SettingsSecondaryButtonStyle()).disabled(!entry.available)
                    .controlSize(.small).accessibilityLabel("Add \(entry.cell.title)")
                    .focused($focusedLibrary, equals: entry.id)
            }
        }
        .padding(.vertical, SettingsStyle.s4).id(entry.id)
    }

    /// The canvas the drawer is drawn on, in points, for a page of a given
    /// height.
    ///
    /// A little under half the page, under a ceiling, and under whatever
    /// the rest of the page needs.
    ///
    /// It used to be a flat 260, which drew the mock display about 415pt
    /// wide in a card twice that: the user had to resize the window every
    /// time they wanted to see what they were arranging. The ring the
    /// pointer has to hit scales with this and nothing else, since
    /// `EditorPreviewTransform` fits the display to the shorter of the two
    /// dimensions and in a wide banner that is always the height. So this
    /// is a drop target size, not a taste one.
    ///
    /// The fraction is the part that was measured rather than chosen. Half
    /// the page leaves the library card showing one row at the window's
    /// default height, which just moves the resizing to the other half of
    /// the page; reserving a fixed block for the library instead pins it
    /// at three rows however large the window gets, which is worse on a
    /// big screen. At 0.45 the preview is 380 at the default height and
    /// both halves grow together after that: three library rows at the
    /// default, five on a window the height of this screen.
    ///
    /// The ceiling is roughly where the display fills the card's width and
    /// more height only adds margin beside it.
    ///
    /// The same on both pages, deliberately: same input, same output. The
    /// user asked for that in an earlier round after watching the drawer
    /// change size when they switched tabs, and
    /// `testPreviewCanvasIsTheSameSizeOnItemsAndAppearance` holds it.
    ///
    /// The third term is the one that keeps the page inside the window.
    /// This used to be a 380 floor, which fits at the default height and
    /// nowhere near it: 45 percent of the page is more than the page has
    /// left over for any window under about 905pt, so the library card
    /// dropped off the bottom and the whole page rode up over the traffic
    /// lights. Giving the canvas back whatever `itemsPageReserve` says the
    /// rest of the page needs makes the fit hold at every height. The 160
    /// is not a design floor: nothing can drag the window that small, and
    /// it is only there so a display too short for the window's own
    /// minimum gets a canvas rather than a negative one.
    static func canvasHeight(pageHeight: CGFloat) -> CGFloat {
        max(160, min(620, pageHeight * 0.45, pageHeight - SettingsStyle.itemsPageReserve))
    }

    private var previewView: some View {
        SettingsCard(style: .hero, padding: SettingsStyle.s16) {
        VStack(alignment: .leading, spacing: SettingsStyle.s12) {
            SettingsSectionHeader("Preview",
                                  subtitle: session.page == .appearance
                                      ? "Your drawer on this display."
                                      : "Select to edit. Drag to add or reorder.") {
                Picker("Preview background", selection: $session.background) {
                    ForEach(PreviewBackground.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 120)
            }
            DrawerEditorPreview(entries: pinned, theme: preferences.theme.resolved(system: session.background.colorScheme), edge: preferences.notchEdge, screenAspect: screenAspect,
                background: session.background, editor: editor,
                onSelect: { keyboardFocus = false; focus = .preview; editor.ownsUndoFocus = true },
                begin: { session.page == .items ? editor.beginNative($0, source: .pinned, items: preferences.items) : nil },
                prepare: { session.page == .items && editor.prepare($0, items: preferences.items, library: library) },
                commit: { input in
                    let accepted = editor.commitNative(input, preferences: preferences, library: library, undoManager: undoManager)
                    if accepted { keyboardFocus = false; focus = .preview; editor.ownsUndoFocus = true }
                    return accepted
                })
                .focusable().focused($focus, equals: .preview).focusEffectDisabled()
                .background(SettingsStyle.accent.opacity(keyboardFocus && focus == .preview ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .leading) {
                    Capsule().fill(SettingsStyle.accent).frame(width: 3, height: 24)
                        .opacity(keyboardFocus && focus == .preview ? 1 : 0).allowsHitTesting(false)
                }
                .onTapGesture { keyboardFocus = false; focus = .preview; editor.ownsUndoFocus = true }
                .onDeleteCommand(perform: session.page == .items && focus == .preview && editor.ownsUndoFocus ? { remove() } : nil)
                .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                    guard session.page == .items, focus == .preview, editor.ownsUndoFocus else { return .ignored }
                    remove()
                    return .handled
                }
                .frame(height: Self.canvasHeight(pageHeight: pageHeight))
                .onKeyPress(.escape) { editor.cancel(); return .handled }
                .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .home, .end]) { press in
                    guard focus == .preview, editor.ownsUndoFocus else { return .ignored }
                    keyboardFocus = true
                    select(key: press.key)
                    return .handled
                }
            belowCanvas
        }
        }
    }

    /// The selection detail, the Items-only move/remove row, and the
    /// status line, together in one fixed-height container. Appearance
    /// never draws the move/remove row, and the detail block is one line
    /// with nothing selected against two lines with something selected;
    /// left free-floating, each of those differences changed the height
    /// of everything above, including the canvas. A fixed height for the
    /// whole block, sized from the tallest arrangement (Items, with a
    /// selection), means the canvas above always gets the same remaining
    /// space, and the block just leaves blank room under a shorter
    /// arrangement instead of resizing anything.
    private var belowCanvas: some View {
        VStack(alignment: .leading, spacing: SettingsStyle.s8) {
            // Appearance shows the drawer but cannot edit it, so it never
            // claims a selection. Saying "Selected, 1 of 8" on a page with
            // no way to select anything reads as a control that has gone
            // missing rather than as information.
            if session.page == .appearance {
                Text("Changing a setting below redraws this straight away.")
                    .settingsFont(SettingsStyle.body)
                    .foregroundStyle(SettingsStyle.textSecondary)
            } else if let entry = pinned.first(where: { $0.id == editor.selection }),
               let index = pinned.firstIndex(where: { $0.id == entry.id }) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                    Text(entry.cell.title).font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                    Text("Selected, \(index + 1) of \(pinned.count)\(entry.cell.kind == .level ? ", " + (entry.cell.state.label.isEmpty ? "Reading level" : entry.cell.state.label) : entry.available ? "" : ", unavailable")")
                        .font(.caption).foregroundStyle(.secondary)
                    }.accessibilityElement(children: .combine)
                    Spacer(minLength: 0)
                    Button { select(key: .leftArrow); keyboardFocus = false; focus = .preview; editor.ownsUndoFocus = true } label: {
                        Image(systemName: "chevron.left")
                    }.disabled(index == 0).accessibilityLabel("Previous item")
                    Button { select(key: .rightArrow); keyboardFocus = false; focus = .preview; editor.ownsUndoFocus = true } label: {
                        Image(systemName: "chevron.right")
                    }.disabled(index == pinned.count - 1).accessibilityLabel("Next item")
                }.controlSize(.small)
            } else {
                Text(preferences.items.isEmpty ? "Drop an item here, or add one from the library." : "Select an item to edit.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if session.page == .items { HStack {
                Button("Move earlier") { move(later: false) }.disabled(!canMove(later: false))
                Button("Move later") { move(later: true) }.disabled(!canMove(later: true))
                Spacer(minLength: 4)
                Button("Remove") { remove() }.disabled(editor.selection == nil)
            }.controlSize(.small).buttonStyle(SettingsSecondaryButtonStyle()) }
            // On Appearance the line above already says changes land at
            // once, so the fallback here would repeat it. The row keeps
            // its height either way: it is what stops the canvas above
            // moving when a status message arrives.
            Text(editor.status.isEmpty
                 ? (session.page == .appearance ? "" : "Changes apply immediately.")
                 : editor.status)
                .font(.caption).foregroundStyle(.secondary).frame(minHeight: 16, alignment: .topLeading)
        }
        // Items reserves the height; Appearance takes what its one line
        // needs. The reservation is for Items alone: its block changes
        // height as a selection comes and goes, and without a fixed height
        // the library card below it would jump every time. Appearance has
        // one line that never changes, so reserving 88pt there only bought
        // 36pt of empty card above and below it, which round four centred
        // rather than removed and which reads as leftover space now that
        // the preview above is half again taller.
        //
        // The canvas is above this, so neither page's canvas moves either
        // way, which is what `testPreviewCanvasIsTheSameSize...` holds.
        .frame(height: session.page == .items ? Self.belowCanvasHeight : nil, alignment: .center)
    }

    /// Sized for the tallest arrangement, Items with a selection: the
    /// two-line detail row, the move and remove row, and the status line.
    /// Fixed rather than free so the library card below never shifts when
    /// a selection appears or goes. `.frame(height:)` does not clip, so a
    /// status line that grows past one line spills downward rather than
    /// being cut off.
    private static let belowCanvasHeight: CGFloat = 88


    private func refreshScreen() {
        guard let screen = NotchGeometry.preferredScreen(from: NSScreen.screens) else { return }
        screenAspect = screen.frame.width / max(1, screen.frame.height)
    }

    private func add(_ entry: EditorEntry) {
        keyboardFocus = false
        editor.cancel()
        if preferences.commit(.add(entry.item, before: nil), undoManager: undoManager) {
            editor.selection = entry.id
            focus = .preview
            editor.ownsUndoFocus = true
            editor.announce("Added \(entry.cell.title).")
        }
    }

    /// Removing from the library row, which is not the same as removing the
    /// selected item: the row says which item, and the selection stays where
    /// it was unless it was the item that just went.
    private func removeFromLibrary(_ entry: EditorEntry) {
        editor.cancel()
        let next = DrawerEditor.nextSelection(afterRemoving: entry.id, from: preferences.items)
        if preferences.commit(.remove(id: entry.id), undoManager: undoManager) {
            if editor.selection == entry.id { editor.selection = next }
            editor.announce("Removed \(entry.cell.title).")
        }
    }

    private func remove() {
        guard let id = editor.selection else { return }
        editor.cancel()
        let next = DrawerEditor.nextSelection(afterRemoving: id, from: preferences.items)
        if preferences.commit(.remove(id: id), undoManager: undoManager) {
            editor.selection = next
            focus = .preview
            editor.ownsUndoFocus = true
            editor.announce("Item removed.")
        }
    }

    private func canMove(later: Bool) -> Bool {
        guard let id = editor.selection, let index = preferences.items.firstIndex(where: { $0.id == id }) else { return false }
        return later ? index < preferences.items.count - 1 : index > 0
    }

    private func move(later: Bool) {
        guard let id = editor.selection, canMove(later: later) else { return }
        editor.cancel()
        if preferences.commit(.move(id: id, before: DrawerEditor.moveTarget(id: id, later: later, items: preferences.items)), undoManager: undoManager) {
            focus = .preview
            editor.ownsUndoFocus = true
            editor.announce("Item moved \(later ? "later" : "earlier").")
        }
    }

    private func select(key: KeyEquivalent) {
        editor.clearStatus()
        guard !preferences.items.isEmpty else { return }
        let current = preferences.items.firstIndex { $0.id == editor.selection } ?? 0
        let index: Int
        switch key {
        case .home: index = 0
        case .end: index = preferences.items.count - 1
        case .upArrow, .leftArrow: index = max(0, current - 1)
        default: index = min(preferences.items.count - 1, current + 1)
        }
        editor.selection = preferences.items[index].id
    }
}

/// The right hand end of a library row, in its two states.
///
/// Added used to be a checkmark and loose text beside a solid Add button
/// in the same column, so a list of rows read as a button on some and
/// nothing much on others. Both are chips now, and both are built from
/// the one width here rather than from their own text, so the column's
/// right edge does not jog as rows change state. Padding is the button
/// style's, which is what makes the two chips come out the same size.
///
/// Added is not a button. Clicking it does nothing and it takes no focus
/// ring: removing an item is the preview's job, not this column's.
enum LibraryAddColumn {
    /// Wide enough for the longest of the three, "Remove" with its minus.
    ///
    /// The width is on the label inside the chip rather than on a frame
    /// around it. Around it, a narrow chip centres inside a wide frame and
    /// the three states stop ending on the same pixel, which is what
    /// `testAddAndAddedAreTheSameChip` caught the first time.
    static let labelWidth: CGFloat = 62

    static var addLabel: some View {
        Text("Add").frame(minWidth: labelWidth)
    }

    static var added: some View {
        chip(Label("Added", systemImage: "checkmark"), tint: SettingsStyle.textSecondary,
             fill: SettingsStyle.ink.opacity(0.07))
    }

    /// What Added turns into under the pointer, or when the chip has
    /// keyboard focus. Red, and it removes on the click: there is nothing to
    /// confirm, since the item is one click to add back and Command Z puts
    /// it where it was.
    static var remove: some View {
        chip(Label("Remove", systemImage: "minus"), tint: SettingsStyle.danger,
             fill: SettingsStyle.danger.opacity(0.12))
    }

    private static func chip(_ label: Label<Text, Image>, tint: Color, fill: Color) -> some View {
        label
            .labelStyle(.titleAndIcon)
            .settingsFont(SettingsStyle.caption)
            .foregroundStyle(tint)
            .frame(minWidth: labelWidth)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(fill, in: RoundedRectangle(cornerRadius: SettingsStyle.r6))
    }
}
