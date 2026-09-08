import SwiftUI

/// Press feedback for every button in the settings window.
///
/// Four percent, and gone in eighty milliseconds. Enough that a click
/// registers in the hand, short enough that holding the mouse down does
/// not leave the control visibly shrunken.
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
