import AppKit
import SwiftUI

/// The app's identity and the credit the user asked to carry by name.
///
/// This is the one file in the whole product allowed to name the upstream
/// author and project. The identity gate that bans that name everywhere
/// else excludes this path on purpose.
enum AboutView {
    /// Pulled out so a test can drive it with a fake dictionary and confirm
    /// it reads `CFBundleShortVersionString` rather than showing a fixed
    /// string.
    static func versionLine(_ infoDictionary: [String: Any]?) -> String {
        "Version " + ((infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?")
    }

    /// Who drew the notch this app's drawer grew out of, and where that
    /// work lives. Both stay in this file rather than at the call site:
    /// the identity gate excludes this one path, so a page that wants to
    /// show the credit reads it from here instead of spelling it out and
    /// tripping the gate.
    static let notchDesigner = "Vinz"
    /// The two names on the app, in the order they appear on the About card.
    static let developers = "Angel Vega and Daniel JW"
    static let repositoryLabel = "github.com/advegaf/drawer"
    static let repository = URL(string: "https://" + repositoryLabel)!
}

/// The icon and the name, above the About card's rows.
///
/// `NSApp.applicationIconImage` at 64pt draws the icon's 128px
/// representation at 2x with no resampling.
struct AboutHeader: View {
    var body: some View {
        HStack(spacing: SettingsStyle.s16) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SettingsStyle.s2) {
                Text("Drawer")
                    .settingsFont(SettingsStyle.sectionHeading)
                    .foregroundStyle(SettingsStyle.ink)
                Text("A drawer at the edge of the screen.")
                    .settingsFont(SettingsStyle.body)
                    .foregroundStyle(SettingsStyle.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, SettingsStyle.s4)
    }
}
