import SwiftUI

/// The chord that opens the drawer, where the app shows itself, whether it
/// starts at login, and who made it. Two cards on the canvas, one setting
/// per row.
struct GeneralPage: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsStyle.s24) {
                behaviour
                about
            }
            .padding(SettingsStyle.s24)
        }
        .scrollIndicators(.hidden)
        .background(HiddenScrollIndicators())
        .navigationTitle(SettingsPage.general.title)
    }

    private var behaviour: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: SettingsStyle.s4) {
                SettingsSectionHeader("General")

                Divider()

                SettingsRow("Open with", symbol: "command",
                            subtitle: "Opens the drawer from any app. Click the field and press the "
                                    + "combination you want. While it is open by the chord, Drawer holds "
                                    + "the keyboard until you press Escape, the chord, or click elsewhere.") {
                    HotKeyRecorderView(
                        chord: preferences.hotKey,
                        onCommit: { preferences.hotKey = $0 },
                        suspend: { preferences.suspendHotKey?() },
                        resume: { preferences.resumeHotKey?() }
                    )
                    .frame(width: 160, height: 22)
                }

                // Warnings hang under the row that caused them rather than
                // inside it: a row's subtitle is what the setting always
                // means, and these are only true sometimes.
                if let problem = preferences.hotKeyProblem {
                    note(problem, tone: .orange)
                }

                if preferences.hotKey == HotKeyPreset.controlOptionSpace.chord,
                   Preferences.enabledKeyboardInputSourceCount > 1 {
                    note("Control Option Space also switches keyboard input sources on this Mac. "
                       + "Pick another chord, or change it in System Settings > Keyboard > "
                       + "Keyboard Shortcuts > Input Sources.")
                }

                Divider()

                SettingsRow("Show Drawer in", symbol: "menubar.rectangle",
                            subtitle: preferences.appPresence.explanation) {
                    Picker("Show Drawer in", selection: $preferences.appPresence) {
                        ForEach(AppPresence.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }

                Divider()

                SettingsRow("Open at login", symbol: "power",
                            subtitle: "Starts Drawer when you log in.") {
                    Toggle("Open at login", isOn: $preferences.launchAtLogin)
                        .labelsHidden().toggleStyle(.switch)
                }

                if let problem = preferences.launchAtLoginProblem {
                    note(problem)
                }
            }
        }
    }

    private var about: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: SettingsStyle.s4) {
                AboutHeader()

                Divider()

                SettingsRow("Version", symbol: "info.circle") {
                    Text(AboutView.versionLine(Bundle.main.infoDictionary)
                        .replacingOccurrences(of: "Version ", with: ""))
                        .settingsFont(SettingsStyle.bodyMedium)
                        .foregroundStyle(SettingsStyle.textSecondary)
                }

                Divider()

                SettingsRow("Developed by", symbol: "person.2") {
                    Text(AboutView.developers)
                        .settingsFont(SettingsStyle.bodyMedium)
                        .foregroundStyle(SettingsStyle.textSecondary)
                }

                Divider()

                SettingsRow("Notch design", symbol: "paintbrush.pointed") {
                    Text(AboutView.notchDesigner)
                        .settingsFont(SettingsStyle.bodyMedium)
                        .foregroundStyle(SettingsStyle.textSecondary)
                }

                Divider()

                SettingsRow("Repository", symbol: "link") {
                    // The window sets its own foreground style on everything
                    // inside it, which would paint this the same colour as
                    // the text beside it. Restate the accent and the
                    // underline so it still reads as a link.
                    Link(AboutView.repositoryLabel, destination: AboutView.repository)
                        .settingsFont(SettingsStyle.bodyMedium)
                        .foregroundStyle(SettingsStyle.accent)
                        .underline()
                }
            }
        }
    }

    private func note(_ text: String, tone: Color? = nil) -> some View {
        Text(text)
            .settingsFont(SettingsStyle.captionLight)
            .foregroundStyle(tone ?? SettingsStyle.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 40)
            .padding(.bottom, SettingsStyle.s4)
    }
}
