import SwiftUI

/// The hover card: what the cell is and what it is doing. No gesture lives
/// here, and no button; the window controller dispatches clicks and drags by
/// geometry, not by anything this view attaches.
struct ItemCard: View {
    let cell: DrawerCell
    let direction: NotchEdge.TooltipDirection
    /// The user's look. `Theme` rather than `Metrics` alone, since the level
    /// fill needs `Palette.on(theme)`, not just the text scale.
    var theme: Theme = .default
    private var metrics: Metrics { theme.metrics }
    /// Overrides the level bar's fill while a drag is live. Nil falls back to
    /// the value already in `cell.state`.
    var sliderFraction: Double?
    var pointerOffset: CGFloat = 0
    var presentationHeight: CGFloat?

    /// The word a toggle showed before it went pending, kept by id so a click
    /// on one cell never bleeds its word into another's card.
    @State private var lastToggleWord: [String: String] = [:]

    private var height: CGFloat {
        presentationHeight ?? NotchLayout.cardHeight(for: cell.kind, state: cell.state, metrics: metrics)
    }

    var body: some View {
        TooltipShell(height: height, direction: direction, theme: theme, pointerOffset: pointerOffset) {
            VStack(alignment: .leading, spacing: 0) {
                TooltipHeader(title: cell.title, note: note, noteColor: noteColor, metrics: metrics, theme: theme) {
                    mark
                }
                if cell.kind == .level, let levelFraction {
                    LevelBar(fraction: levelFraction, fill: Palette.on(theme), track: Palette.track(theme), thumb: true, theme: theme)
                        .frame(height: NotchLayout.sliderHitDepth)
                        .padding(.top, NotchLayout.headerToBlock)
                } else if cell.kind != .level, let bodyMessage {
                    Text(bodyMessage)
                        .font(Typography.cardBody(metrics))
                        .foregroundStyle(Palette.secondary(theme))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, NotchLayout.headerToBlock)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .id(cell.id)
            .transition(.opacity)
            .animation(NotchMotion.crossfade, value: cell.id)
        }
        .accessibilityHidden(true)
        .onChange(of: cell.state, initial: true) { _, newState in
            switch newState {
            case .on: lastToggleWord[cell.id] = "On"
            case .off: lastToggleWord[cell.id] = "Off"
            default: break
            }
        }
    }

    // MARK: - Mark

    private var markIcon: Icon {
        if cell.kind == .add { return .symbol("plus") }
        if cell.kind == .launch, cell.state == .notInstalled { return .symbol("app.dashed") }
        return cell.icon
    }

    private var markTint: Color {
        cell.kind == .add ? Palette.secondary(theme) : Palette.primary(theme)
    }

    @ViewBuilder
    private var mark: some View {
        switch markIcon {
        case .symbol(let name):
            Image(systemName: name)
                .resizable()
                .scaledToFit()
                .foregroundStyle(markTint)
                .frame(width: NotchLayout.glyphSize(metrics), height: NotchLayout.glyphSize(metrics))
        case .image(let nsImage):
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
                .frame(width: NotchLayout.glyphSize(metrics), height: NotchLayout.glyphSize(metrics))
        }
    }

    // MARK: - Note

    private var note: String? {
        if case .failed = cell.state { return "Failed" }
        switch cell.kind {
        case .launch:
            return cell.state == .notInstalled ? "Not installed" : nil
        case .toggle:
            switch cell.state {
            case .on: return "On"
            case .off: return "Off"
            case .pending: return lastToggleWord[cell.id]
            case .unavailable, .unknown: return "Unavailable"
            default: return nil
            }
        case .level:
            guard let levelFraction else { return "Unavailable" }
            return "\(Int((levelFraction * 100).rounded()))%"
        case .fire:
            if case .armed = cell.state { return "Click again" }
            return nil
        case .shortcut:
            if case .notFound = cell.state { return "Not found" }
            return nil
        case .add:
            return nil
        }
    }

    private var noteColor: Color {
        switch cell.state {
        case .failed, .armed: return Palette.critical
        default: return Palette.secondary(theme)
        }
    }

    /// Empty Trash reads "the Trash", not the generic "confirm": the one
    /// place a destructive fire says what it is about to do.
    private var armedNote: String {
        cell.id == "action:emptyTrash" ? "Click again to empty the Trash" : "Click again to confirm"
    }

    // MARK: - Body row

    private var bodyMessage: String? {
        switch cell.state {
        case .failed(let message): return message
        case .armed: return armedNote
        default: return nil
        }
    }

    private var levelFraction: Double? {
        let value: Double
        if let sliderFraction { value = sliderFraction }
        else if case .level(let current) = cell.state { value = current }
        else { return nil }
        return value.isFinite ? min(1, max(0, value)) : nil
    }
}
