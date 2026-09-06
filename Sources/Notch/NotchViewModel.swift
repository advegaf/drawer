import AppKit
import SwiftUI
import Combine

@MainActor
final class NotchViewModel: ObservableObject {
    @Published var cells: [DrawerCell] = []

    /// Set on a `DRAWER_DEMO=1` run, once the fixture cells are in place. The
    /// items sink checks this and leaves the cells alone.
    @Published var isDemo = false

    /// Which cell the cursor is over, if any. Driven from the window controller
    /// rather than SwiftUI's `.onHover`: the panel ignores mouse events until
    /// the cursor is over it, so SwiftUI cannot see the crossing that turns
    /// event handling on in the first place.
    @Published var hoveredIndex: Int?

    /// Whether the current hover came from the pointer or the keyboard. The
    /// poll ignores a keyboard-sourced hover, so a cursor that has not
    /// actually moved cannot clobber a selection the arrow keys just made.
    enum HoverSource { case pointer, keyboard }
    @Published var hoverSource: HoverSource = .pointer

    /// Swaps in a freshly resolved cell list without losing the hover.
    ///
    /// A resolve can land while the pointer is sitting on a cell: reordering
    /// pinned items should not make the tooltip jump or vanish out from under
    /// it. So the hovered id, not the index, is what's tracked across the
    /// swap. Removing the source dismisses its card.
    func replaceCells(_ newCells: [DrawerCell]) {
        let previousIndex = hoveredIndex
        let previousID = previousIndex.flatMap { cells.indices.contains($0) ? cells[$0].id : nil }
        let newCells = newCells.isEmpty ? [DrawerCell.add] : newCells
        cells = newCells
        clampScroll()
        guard previousIndex != nil else { return }
        if let previousID, let newIndex = newCells.firstIndex(where: { $0.id == previousID }) {
            hoveredIndex = geometricIndex(of: newIndex) == nil ? nil : newIndex
        } else {
            hoveredIndex = nil
        }
    }

    /// Updates one cell's state in place, by id. A no-op if the cell is gone.
    ///
    /// A level the user is dragging must land with no animation at all: the
    /// bar is following their pointer and any interpolation reads as the
    /// control lagging behind the hand. A level that arrives from anywhere
    /// else, a brightness key or another app, is the opposite case. It
    /// arrives as one jump from wherever the bar was, and drawn instantly
    /// that jump reads as a glitch rather than a change, which is why
    /// Control Center animates the same transition. `live` is what tells
    /// the two apart.
    func updateCell(id: String, state: CellState, live: Bool = true) {
        guard let index = cells.firstIndex(where: { $0.id == id }) else { return }
        guard case .level = state else { cells[index].state = state; return }
        // Reduce Motion is read here rather than from the environment
        // because this runs in the model, outside any view, the same
        // reason `NotchWindowController` reads the workspace flag directly.
        let animates = !live && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animates else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { cells[index].state = state }
            return
        }
        withAnimation(NotchMotion.level) { cells[index].state = state }
    }

    // MARK: - Scrolling through more cells than fit

    /// The first cell drawn in the visible window. Everything before it is
    /// still in `cells`, just scrolled out of view.
    @Published var firstVisibleIndex = 0 {
        didSet {
            if let hoveredIndex, geometricIndex(of: hoveredIndex) == nil { self.hoveredIndex = nil }
        }
    }

    /// How far the column has bounced past its end, in the direction pushed.
    /// Zero at rest; the controller sets it briefly on an overscroll and then
    /// clears it, so the view has something to spring back from.
    @Published var overscroll: CGFloat = 0

    /// The largest number of cells `panelSize(cellCount:)` can hold without
    /// running past the length `NotchGeometry.panelFrame` actually grants: the
    /// full screen on a side edge, since a vertical bar is centred on the whole
    /// screen; the usable screen on a horizontal one, since the Dock can eat
    /// into it.
    ///
    /// Solved by walking up rather than inverting `panelSize`. The size is a
    /// sum of parts (`shapeLength`, `slack`) that later phases can still change
    /// independently, and an inverted copy would have to be kept in step by hand.
    var fitCount: Int {
        guard screenSize != .zero else { return max(1, cells.count) }
        let limit = screenSize.height
        var fits = 1
        for n in 1...Self.fitCeiling {
            let size = panelSize(cellCount: n)
            guard size.height <= limit else { break }
            fits = n
        }
        return fits
    }

    /// Generous past anything a real screen could hold, so the walk never
    /// stops short on an unusually tall or wide display.
    private static let fitCeiling = 200

    /// How many cells are actually drawn right now.
    var visibleCount: Int {
        cells.isEmpty ? 0 : min(cells.count, fitCount)
    }

    /// Which cells of the full list are on screen right now.
    var visibleRange: Range<Int> {
        firstVisibleIndex..<(firstVisibleIndex + visibleCount)
    }

    /// Keeps `firstVisibleIndex` inside what the list and the fit actually
    /// allow. A shorter list, a shrunk fit, or a smaller fit than before all
    /// leave it somewhere it can no longer be, and this is the one place that
    /// pulls it back.
    func clampScroll() {
        let maxStart = max(0, cells.count - visibleCount)
        firstVisibleIndex = min(max(firstVisibleIndex, 0), maxStart)
    }

    /// Where cell `index` sits in the visible window, or nil while it is
    /// scrolled out of view.
    func geometricIndex(of index: Int) -> Int? {
        let slot = index - firstVisibleIndex
        return (0..<visibleCount).contains(slot) ? slot : nil
    }

    /// A ring centre for a slot in the visible window, `0..<visibleCount`. The
    /// one geometry hit-testing and drawing both read, so a cell scrolled into
    /// slot 2 is always found and drawn at the same place.
    func ringCenter(visible slot: Int) -> CGFloat {
        ringCenter(index: slot)
    }

    /// The user's chosen look. Persisted by `Preferences`, mirrored here so
    /// the notch, cells, card and controller geometry can all read it.
    @Published var theme: Theme = .default
    /// What `NotchLayout` actually reads for `theme`.
    var metrics: Metrics { theme.metrics }

    /// Whether the notch is open or folded away to its pill.
    @Published var isExpanded = false
    /// Clicked open, so it stays open until clicked shut again. A gesture,
    /// not a setting: it lasts as long as this session of looking at it.
    @Published var isPinned = false

    /// The standing choice from Settings. "Always show".
    ///
    /// Separate from `isPinned` because the two are not the same claim, and
    /// sharing one flag is what let a click on the bar undo a setting. Clicking
    /// toggles a pin; only Settings moves this.
    @Published var isAlwaysOn = false

    /// Held open, by either route. What the folding logic actually asks.
    var staysOpen: Bool { isPinned || isAlwaysOn }
    /// The settings handle is under the cursor.
    @Published var isHoveringSettings = false
    /// Which screen edge the notch is welded to. Everything geometric reads
    /// this through `placement` rather than assuming an axis.
    @Published var edge: NotchEdge = .right {
        didSet { if oldValue != edge { hoveredIndex = nil } }
    }

    /// How much screen there is to spend on the panel. Zero until the
    /// controller says otherwise, which reads as "no screen known yet".
    @Published var screenSize: CGSize = .zero

    /// The same screen minus the menu bar and the Dock.
    ///
    /// A horizontal notch starts at the *usable* edge and grows inward from
    /// there, so those two are room it never had. A side notch is centred on
    /// the whole screen and floats over both, so for that one they are not.
    @Published var screenUsableSize: CGSize = .zero

    /// Take the notch geometry of whichever screen the panel is on.
    func adopt(screen: ScreenDescribing) {
        // `frame`, not `visibleFrame`: the panel is centred on the full screen
        // and may sit under the menu bar, so the menu bar is not room lost.
        let size = screen.frameValue.size
        if screenSize != size { screenSize = size }
        let usable = screen.visibleFrameValue.size
        if screenUsableSize != usable { screenUsableSize = usable }
    }

    private var expandedShapeSize: CGSize {
        NotchPlacement.panelSize(edge: edge, length: shapeLength,
                                 depth: NotchLayout.bodyDepth(for: edge, metrics: metrics))
    }

    var drawnCornerRadius: CGFloat {
        SideNotchShape(edge: edge).resolvedCurves(in: expandedShapeSize).corner
    }

    var orbGeometry: NotchLayout.OrbGeometry {
        NotchLayout.orbGeometry(edge: edge, shapeSize: expandedShapeSize)
    }

    var orbMergeScale: CGFloat { orbGeometry.mergeScale }
    var orbArcRadius: CGFloat { orbGeometry.arcRadius }

    var orbHugsCorner: Bool { orbGeometry.convex }
    var orbAlong: CGFloat { orbGeometry.along }
    var orbInset: CGFloat { orbGeometry.across }
    var orbArcOffset: CGSize { orbGeometry.arcOffset }
    var orbHandlePoints: [CGPoint] { orbGeometry.handlePoints }

    var cornerCentreAlong: CGFloat {
        let curves = SideNotchShape(edge: edge).resolvedCurves(in: expandedShapeSize)
        return shapeLength - curves.curl - curves.corner
    }

    /// Whether a point in stack space is on the settings handle.
    ///
    /// A circle around each of those points, rather than one box around the
    /// pair. The handle is a round thing in two places, and the bounding box of
    /// the two takes in a great deal of ground that is near neither. Which is
    /// why the button used to appear well before the pointer reached the arc.
    func isOnOrbHandle(along: CGFloat, across: CGFloat) -> Bool {
        let radius = NotchLayout.orbHotZone / 2
        return orbHandlePoints.contains {
            hypot(along - $0.x, across - $0.y) <= radius
        }
    }


    var tooltipInset: CGFloat {
        NotchLayout.bodyDepth(for: edge, metrics: metrics) + NotchLayout.cardGap
    }

    @Published var presentedCardPlacement: CardPlacement?

    struct CardPlacement: Equatable {
        let body: CGRect
        let bridge: CGRect
        let pointerOffset: CGFloat

        static func interpolate(from: Self, to: Self, fraction: Double) -> Self {
            let t = CGFloat(min(1, max(0, fraction)))
            func rect(_ a: CGRect, _ b: CGRect) -> CGRect {
                CGRect(x: a.minX + (b.minX - a.minX) * t,
                       y: a.minY + (b.minY - a.minY) * t,
                       width: a.width + (b.width - a.width) * t,
                       height: a.height + (b.height - a.height) * t)
            }
            return Self(body: rect(from.body, to.body), bridge: rect(from.bridge, to.bridge),
                        pointerOffset: from.pointerOffset + (to.pointerOffset - from.pointerOffset) * t)
        }
    }

    func cardPlacement(index: Int, panelSize: CGSize? = nil) -> CardPlacement? {
        if index == hoveredIndex, let presentedCardPlacement { return presentedCardPlacement }
        return targetCardPlacement(index: index, panelSize: panelSize)
    }

    func targetCardPlacement(index: Int, panelSize: CGSize? = nil) -> CardPlacement? {
        guard cells.indices.contains(index), let slot = geometricIndex(of: index) else { return nil }
        let size = panelSize ?? self.panelSize
        let place = NotchPlacement(edge: edge, panelSize: size)
        let cell = cells[index]
        let height = NotchLayout.cardHeight(for: cell.kind, state: cell.state, metrics: metrics)
        let alongExtent = height
        let acrossExtent = NotchLayout.cardWidth
        let source = slack + ringCenter(visible: slot)
        let limit = size.height
        let start = min(max(source - alongExtent / 2, NotchLayout.cardShadowPad),
                        max(NotchLayout.cardShadowPad, limit - alongExtent - NotchLayout.cardShadowPad))
        let body = place.rect(along: start, across: tooltipInset, length: alongExtent, depth: acrossExtent)
        let halfBase = NotchLayout.pointerBase / 2
        let pointer = min(max(source - start, NotchLayout.cardCorner + halfBase),
                          alongExtent - NotchLayout.cardCorner - halfBase)
        let halfCell = NotchLayout.ringDiameter(metrics) / 2
        let bridgeStart = max(start, source - halfCell)
        let bridgeEnd = min(start + alongExtent, source + halfCell)
        let bridge = place.rect(along: bridgeStart, across: tooltipInset - NotchLayout.cardGap,
                                length: max(0, bridgeEnd - bridgeStart), depth: NotchLayout.cardGap)
        return CardPlacement(body: body, bridge: bridge, pointerOffset: pointer - alongExtent / 2)
    }

    /// The straight part of the shape, flares excluded.
    var bodyLength: CGFloat {
        NotchLayout.bodyLength(cellCount: visibleCount, edge: edge, metrics: metrics)
    }

    /// Distance along the stack to cell `index`'s ring centre, widening
    /// included so the cells stay in the middle of the bar.
    func ringCenter(index: Int) -> CGFloat {
        NotchLayout.ringCenter(index: index, edge: edge, flare: NotchLayout.curlRadius, metrics: metrics)
    }

    var hoveredCell: DrawerCell? {
        guard let hoveredIndex, cells.indices.contains(hoveredIndex) else { return nil }
        return cells[hoveredIndex]
    }

    var shapeLength: CGFloat { shapeLength(cellCount: visibleCount) }

    var panelSize: CGSize { panelSize(cellCount: visibleCount) }

    /// How stack space maps onto the panel right now.
    var placement: NotchPlacement { NotchPlacement(edge: edge, panelSize: panelSize) }

    /// Room at each end of the stack, for this edge.
    var slack: CGFloat { slack(cellCount: visibleCount) }

    func slack(cellCount: Int) -> CGFloat {
        NotchLayout.slack(for: edge, maxCardHeight: maxCardHeight)
    }

    /// How tall the tallest card may be before the panel runs off the screen.
    var maxCardHeight: CGFloat { NotchLayout.maxCardHeight(metrics) }

    /// The drawn extent of the notch body right now, along the stack.
    var notchLength: CGFloat {
        if isExpanded { return shapeLength }
        return NotchLayout.pillHeight(metrics)
    }

    /// And across it.
    var notchDepth: CGFloat {
        if isExpanded { return NotchLayout.bodyDepth(for: edge, metrics: metrics) }
        return NotchLayout.pillWidth
    }

    /// What the notch folds away to, whether or not it is open right now:
    /// the hit region has to know that while the notch is still open.
    var restingLength: CGFloat { NotchLayout.pillHeight(metrics) }
    var restingDepth: CGFloat { NotchLayout.pillWidth }

    /// The drawn size of the notch body, in panel axes.
    var notchSize: CGSize {
        NotchPlacement.panelSize(edge: edge, length: notchLength, depth: notchDepth)
    }

    /// Where the notch starts along the stack. Both states share a centre line,
    /// so folding away does not slide the notch along the edge as it shrinks.
    var notchLeadingInset: CGFloat {
        slack + (shapeLength - notchLength) / 2
    }

    /// Sized from an explicit count rather than from `cells`.
    ///
    /// `@Published` notifies its subscribers in `willSet`, so a sink reacting to
    /// a change in the cell list still sees the *old* array if it reads the
    /// model back. Taking the count as an argument is the only way to be sure
    /// the panel is sized for the list that caused the change.
    func shapeLength(cellCount: Int) -> CGFloat {
        NotchLayout.shapeLength(cellCount: cellCount,
                                edge: edge, flare: NotchLayout.curlRadius, metrics: metrics)
    }

    func panelSize(cellCount: Int) -> CGSize {
        let card = maxCardHeight
        return NotchPlacement.panelSize(
            edge: edge,
            length: shapeLength(cellCount: cellCount)
                + 2 * NotchLayout.slack(for: edge, maxCardHeight: card),
            depth: NotchLayout.tooltipDepth(for: edge, maxCardHeight: card)
                + NotchLayout.bodyDepth(for: edge, metrics: metrics)
        )
    }
}
