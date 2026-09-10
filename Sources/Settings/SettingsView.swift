import AppKit
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case items, appearance, general
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .items: "square.grid.2x2"
        case .appearance: "paintpalette"
        case .general: "gearshape"
        }
    }
}

enum LibraryCategory: String, CaseIterable { case actions = "Actions", apps = "Apps", shortcuts = "Shortcuts" }
enum PreviewBackground: String, CaseIterable {
    case light = "Light", dark = "Dark"
    var colorScheme: ColorScheme { self == .light ? .light : .dark }
}

@MainActor
final class SettingsSession: ObservableObject {
    @Published var page: SettingsPage
    @Published var query = ""
    @Published var category = LibraryCategory.actions
    @Published var background = PreviewBackground.light
    init(page: SettingsPage = .items) { self.page = page }
    func select(_ page: SettingsPage, editor: DrawerEditor) {
        editor.cancel()
        editor.ownsUndoFocus = false
        self.page = page
    }
}

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var shortcuts: ShortcutsCatalog
    @ObservedObject var apps: AppCatalog
    let undoManager: UndoManager?
    let liveLevels: LiveLevels?
    @StateObject private var editor: DrawerEditor
    @ObservedObject var session: SettingsSession

    init(preferences: Preferences, shortcuts: ShortcutsCatalog, apps: AppCatalog,
         initialPage: SettingsPage = .items, undoManager: UndoManager? = nil, editor: DrawerEditor? = nil,
         liveLevels: LiveLevels? = nil, session: SettingsSession? = nil) {
        self.preferences = preferences
        self.shortcuts = shortcuts
        self.apps = apps
        self.undoManager = undoManager
        self.liveLevels = liveLevels
        _editor = StateObject(wrappedValue: editor ?? DrawerEditor())
        self.session = session ?? SettingsSession(page: initialPage)
    }
    /// A split view rather than two columns in an `HStack`, for the two
    /// things only a split view gives: the sidebar runs the full height of
    /// the window with the traffic lights over it and no titlebar band
    /// above it, and the collapse button in the toolbar is one the split
    /// view vends rather than one drawn here.
    var body: some View {
        NavigationSplitView {
            SettingsSidebar(session: session, editor: editor)
        } detail: {
            Group {
                if session.page == .general {
                    GeneralPage(preferences: preferences)
                } else if let liveLevels {
                    LiveSettingsEditor(preferences: preferences, shortcuts: shortcuts, apps: apps, editor: editor,
                        session: session, undoManager: undoManager, liveLevels: liveLevels)
                } else {
                    ItemsPage(preferences: preferences, shortcuts: shortcuts, apps: apps, editor: editor,
                              session: session, undoManager: undoManager)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SettingsStyle.canvas)
        }
        .navigationSplitViewStyle(.balanced)
        // The window's real floor, and it has to be here. The hosting view
        // overwrites `contentMinSize` with SwiftUI's own minimum on the
        // first layout, so the size the window is created with is gone by
        // the time anyone can drag an edge: measured, the window took a
        // 700 by 700 resize without it.
        //
        // The height is the window's minimum less the titlebar, because
        // SwiftUI insets this view by the titlebar's safe area and the
        // window's own floor then comes out that much taller.
        //
        // Top aligned so that if the content ever is taller than the
        // window anyway, on a display too short for the minimum, it hangs
        // off the bottom rather than being centred: centred, the sidebar
        // rides up until the brand header sits under the traffic lights,
        // which is what the user photographed.
        .frame(minWidth: SettingsStyle.windowMinimum.width,
               minHeight: SettingsStyle.windowMinimum.height - SettingsStyle.titlebarInset,
               alignment: .top)
        .background(SettingsStyle.canvas)
        .foregroundStyle(SettingsStyle.ink).tint(SettingsStyle.accent)
        .onAppear { liveLevels?.setSettingsVisible(session.page != .general) }
        .onChange(of: session.page) {
            liveLevels?.setSettingsVisible(session.page != .general)
            editor.cancel(); editor.ownsUndoFocus = false
        }
        .onDisappear { liveLevels?.setSettingsVisible(false) }
    }
}

private struct LiveSettingsEditor: View {
    let preferences: Preferences
    let shortcuts: ShortcutsCatalog
    let apps: AppCatalog
    let editor: DrawerEditor
    let session: SettingsSession
    let undoManager: UndoManager?
    @ObservedObject var liveLevels: LiveLevels
    var body: some View {
        ItemsPage(preferences: preferences, shortcuts: shortcuts, apps: apps, editor: editor,
                  session: session, undoManager: undoManager, levelStates: liveLevels.states)
    }
}
