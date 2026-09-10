import AppKit
import SwiftUI

/// The settings window's left column: what the app is, where you are in
/// it, and which version you are running.
///
/// This replaces a row of tabs in the toolbar. Three pages fit in a
/// toolbar, but the tabs put the app's name and the page you are on in
/// two different places, and left the column beside them holding a
/// wordmark and nothing else. One column carries all of it.
struct SettingsSidebar: View {
    @ObservedObject var session: SettingsSession
    let editor: DrawerEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            navigation
            Spacer(minLength: 0)
            footer
        }
        .frame(minWidth: SettingsStyle.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(SettingsStyle.sidebar)
    }

    /// The icon is inset 16pt while the rows below are inset 8pt, so its
    /// leading edge sits 8pt inside the selection pills rather than flush
    /// with them. Flush reads as a list item that lost its pill.
    ///
    /// The frame is `SettingsStyle.brandIcon`, measured rather than picked:
    /// macOS normalises an app icon inside whatever frame it is given, so a
    /// 32pt frame drew 26pt of artwork beside a 17pt wordmark and read as
    /// the smaller of the two. 38 draws 31 and the two balance.
    private var header: some View {
        HStack(spacing: SettingsStyle.s12) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: SettingsStyle.brandIcon, height: SettingsStyle.brandIcon)
                .accessibilityHidden(true)
            Text("Drawer")
                .settingsFont(SettingsStyle.cardTitle)
                .foregroundStyle(SettingsStyle.ink)
        }
        .padding(.horizontal, SettingsStyle.s16)
        .padding(.top, SettingsStyle.s8)
        .padding(.bottom, SettingsStyle.s12)
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: SettingsStyle.s2) {
            ForEach(SettingsPage.allCases) { page in
                SettingsNavigationRow(page: page, isSelected: session.page == page) {
                    session.select(page, editor: editor)
                }
            }
        }
        .padding(.horizontal, SettingsStyle.s8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pages")
    }

    private var footer: some View {
        VStack(spacing: SettingsStyle.s4) {
            Text("v" + ((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"))
            // Credit on its own line, then the legal line. Both names inside a
            // copyright notice read as small print rather than as a credit,
            // and the names are read from the same constant the About card
            // uses so the two cannot end up naming different people.
            Text("Built by " + AboutView.developers)
                .multilineTextAlignment(.center)
            Text("\u{00A9} 2026 Angel Vega")
                .multilineTextAlignment(.center)
        }
        .settingsFont(SettingsStyle.micro)
        .foregroundStyle(SettingsStyle.textTertiary)
        .frame(maxWidth: .infinity)
        .padding(.bottom, SettingsStyle.s16)
    }
}

/// One page in the sidebar's list.
private struct SettingsNavigationRow: View {
    let page: SettingsPage
    let isSelected: Bool
    let select: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: SettingsStyle.s8) {
                Image(systemName: page.symbol)
                    .foregroundStyle(isSelected ? SettingsStyle.accent : SettingsStyle.textSecondary)
                    .frame(width: 16, height: 16)
                Text(page.title)
                    .settingsFont(SettingsStyle.nav)
                    .foregroundStyle(isSelected ? SettingsStyle.accent : SettingsStyle.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SettingsStyle.s12)
            .padding(.vertical, SettingsStyle.s8)
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: SettingsStyle.r8))
            .contentShape(Rectangle())
            .animation(.easeInOut(duration: 0.12), value: isHovering)
            .animation(.easeInOut(duration: 0.12), value: isSelected)
        }
        .buttonStyle(PressScale())
        .onHover { isHovering = $0 }
        .accessibilityLabel(page.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Selection is a tint of the accent rather than a solid fill: the row
    /// has to read as chosen without competing with the page beside it.
    @ViewBuilder
    private var fill: some View {
        if isSelected {
            SettingsStyle.accent.opacity(0.12)
        } else if isHovering {
            SettingsStyle.surfaceHover
        } else {
            Color.clear
        }
    }
}
