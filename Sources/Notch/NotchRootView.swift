import AppKit
import SwiftUI

struct NotchRootView: View {
    @ObservedObject var model: NotchViewModel
    var onAccessibilityActivate: (String) -> Void = { _ in }
    var onAccessibilityAdjust: (String, Bool) -> Void = { _, _ in }
    var onAccessibilityOpenSettings: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var systemScheme

    private var theme: Theme {
        model.theme.resolved(system: systemScheme)
    }

    var body: some View {
        // Measured rather than assumed: the panel's real size is whatever
        // AppKit settled on, and the notch has to sit flush against *that*
        // edge, not against the size we asked for.
        GeometryReader { proxy in
            let place = NotchPlacement(edge: model.edge, panelSize: proxy.size)

            ZStack(alignment: .topLeading) {
                Color.clear

                notch(place)

                hoverCard(place)

                // Outside the clip, like the orb below: a cell scrolled past
                // either end still leaves the shape it belongs to on screen,
                // and that shape is what the chevron has to sit inside.
                scrollChevron(startChevronSymbol)
                    .position(place.point(along: startChevronAlong, across: chevronAcross))
                    .opacity(model.isExpanded && model.firstVisibleIndex > 0 ? 1 : 0)
                    .animation(motion(NotchMotion.crossfade), value: model.firstVisibleIndex > 0)

                scrollChevron(endChevronSymbol)
                    .position(place.point(along: endChevronAlong, across: chevronAcross))
                    .opacity(model.isExpanded && hasMoreAfterVisible ? 1 : 0)
                    .animation(motion(NotchMotion.crossfade), value: hasMoreAfterVisible)

                // Outside the notch and outside its clip: the orb hangs past
                // the end of the shape, tucked into the corner the far flare
                // makes.
                SettingsOrb(isHovered: model.isHoveringSettings, edge: model.edge,
                                convex: model.orbHugsCorner,
                                arcRadius: model.orbArcRadius,
                                arcOffset: model.orbArcOffset,
                                theme: theme)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Drawer settings")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { onAccessibilityOpenSettings() }
                    .accessibilityHidden(!model.isExpanded)
                    .position(orbCentre(place))
                    // Outward, into the black, not inward to nothing.
                    .scaleEffect(reduceMotion ? 1 : model.isExpanded ? 1 : model.orbMergeScale)
                    .opacity(model.isExpanded ? 1 : 0)
                    .animation(motion(orbMotion), value: model.isExpanded)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .environment(\.colorScheme, theme.colorScheme(fallback: systemScheme))
            .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.125), value: model.hoveredIndex == nil)
        }
        .animation(motion(NotchMotion.unfold), value: model.isExpanded)
    }

    /// Opening and closing are not mirror images. Appearing, the orb waits
    /// its turn behind the cells before it; hiding, any delay at all lets the
    /// notch start folding first, and the orb reads as going with the frame
    /// rather than into it.
    private var orbMotion: Animation {
        model.isExpanded ? NotchMotion.stagger(index: model.cells.count) : NotchMotion.merge
    }

    private func notch(_ place: NotchPlacement) -> some View {
        let shape = SideNotchShape(edge: model.edge)
        return Color.clear
        .frame(width: model.notchSize.width, height: model.notchSize.height)
        .overlay(alignment: contentAlignment) {
            cells
        }
        .clipShape(shape)
        .modifier(DrawerSurface(shape: shape, theme: theme))
        .position(place.point(
            along: model.notchLeadingInset + model.notchLength / 2,
            across: model.notchDepth / 2
        ))
    }

    @ViewBuilder
    private var cells: some View {
        // Read once for the whole stack rather than inside the loop. Asking
        // the model per cell made a body evaluation cost grow with the square
        // of the list, since every read of `visibleCount` is a fit walk.
        let visible = model.visibleRange
        let stack = ForEach(Array(model.cells.enumerated()), id: \.element.id) { index, cell in
            cellView(cell)
                .disabled(!NotchWindowController.accessibilityEnabled(cell))
                .accessibilityHidden(!model.isExpanded || !visible.contains(index))
                // Pinned to what the cell claims along the stack, or the drawn
                // rings stop lining up with the centres `ringCenter` hands to
                // the hover bands and the card.
                                .opacity(model.isExpanded ? 1 : 0)
                // A short slide toward the edge, no scaling: the clip is
                // already doing the concealing, and scaling on top of it
                // reads as two effects fighting.
                .offset(
                    x: reduceMotion || model.isExpanded ? 0 : model.edge.outward.x * Design.px(28),
                    y: reduceMotion || model.isExpanded ? 0 : model.edge.outward.y * Design.px(28)
                )
                .animation(motion(NotchMotion.stagger(index: index)),
                          value: model.isExpanded)
        }

        // Scrolled past the visible window, the stack is carried the rest of
        // the way by one offset rather than by hiding and re-showing cells;
        // the clip below is what actually keeps the rest out of sight.
        let scrolled = -(CGFloat(model.firstVisibleIndex) * NotchLayout.cellPitch(for: model.edge, metrics: model.metrics))
            + model.overscroll

        Group {
            VStack(spacing: NotchLayout.cellSpacing(model.metrics)) { stack }
                .padding(.top, leadIn)
                // The contents keep the expanded layout while folding, so
                // the stack does not reflow on its way out; the shape clips it.
                .frame(width: NotchLayout.bodyDepth(for: model.edge, metrics: model.metrics))
                .offset(y: scrolled)
        }
        .animation(motion(NotchMotion.glide), value: model.firstVisibleIndex)
        .animation(motion(NotchMotion.overscroll), value: model.overscroll)
        .allowsHitTesting(model.isExpanded)
    }

    /// The cell's own content; which state draws what is `DrawerCellView`'s call.
    @ViewBuilder private func cellView(_ cell: DrawerCell) -> some View {
        if cell.kind == .level {
            DrawerCellView(cell: cell, theme: theme)
                .accessibilityRemoveTraits(.isButton)
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: onAccessibilityAdjust(cell.id, true)
                    case .decrement: onAccessibilityAdjust(cell.id, false)
                    @unknown default: break
                    }
                }
        } else {
            DrawerCellView(cell: cell, theme: theme)
                .accessibilityAction { onAccessibilityActivate(cell.id) }
        }
    }

    /// The corner of the shape's own frame where the stack starts and the
    /// bezel is. The origin everything inside it is measured from.
    private var contentAlignment: Alignment {
        switch model.edge {
        case .right:  return .topTrailing
        case .left:   return .topLeading
        }
    }

    /// Distance from the start of the shape to the first cell.
    private var leadIn: CGFloat {
        NotchLayout.curlRadius + NotchLayout.padStart(for: model.edge, metrics: model.metrics)
    }

    private func motion(_ animation: Animation) -> Animation? {
        NotchMotion.respectingReduceMotion(animation, reduceMotion)
    }

    /// Whether cells remain past the end of the visible window.
    private var hasMoreAfterVisible: Bool {
        model.firstVisibleIndex + model.visibleCount < model.cells.count
    }

    /// Points at the earlier cells scrolled out of view, in the gap between
    /// the shape's start and the first visible ring.
    private var startChevronSymbol: String {
        "chevron.compact.up"
    }

    /// Points at the later ones, in the matching gap at the far end.
    private var endChevronSymbol: String {
        "chevron.compact.down"
    }

    private var startChevronAlong: CGFloat {
        model.slack + NotchLayout.curlRadius + NotchLayout.padStart(for: model.edge, metrics: model.metrics) / 2
    }

    private var endChevronAlong: CGFloat {
        model.slack + model.shapeLength - NotchLayout.curlRadius
            - NotchLayout.padEnd(for: model.edge, metrics: model.metrics) / 2
    }

    /// Centred across the body, the same band a ring sits in.
    private var chevronAcross: CGFloat {
        NotchLayout.bodyDepth(for: model.edge, metrics: model.metrics) / 2
    }

    private func scrollChevron(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .resizable()
            .scaledToFit()
            .foregroundStyle(Palette.secondary(theme))
            .frame(width: NotchLayout.scrollHintGlyph, height: NotchLayout.scrollHintGlyph)
    }

    /// The orb sits on the flare's own centre of curvature, one radius in from
    /// the bezel and level with the far end of the shape.
    private func orbCentre(_ place: NotchPlacement) -> CGPoint {
        place.point(
            along: model.slack + model.orbAlong,
            across: model.orbInset
        )
    }

    @ViewBuilder
    private func hoverCard(_ place: NotchPlacement) -> some View {
        if model.isExpanded, let cell = model.hoveredCell,
           let index = model.hoveredIndex,
           let card = model.cardPlacement(index: index, panelSize: place.panelSize) {
            ItemCard(cell: cell, direction: model.edge.tooltipDirection, theme: theme,
                     pointerOffset: card.pointerOffset, presentationHeight: card.body.height,
                     presentationWidth: card.body.width)
                .frame(width: card.body.width, height: card.body.height)
                .position(x: card.body.midX, y: card.body.midY)
                .transition(.opacity.combined(with: .offset(
                    x: reduceMotion ? 0 : model.edge.outward.x * Design.px(8),
                    y: reduceMotion ? 0 : model.edge.outward.y * Design.px(8)
                )))
        }
    }
}
