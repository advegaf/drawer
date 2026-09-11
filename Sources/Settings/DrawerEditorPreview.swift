import AppKit
import SwiftUI

@MainActor
struct EditorPreviewLayout {
    let edge: NotchEdge
    let metrics: Metrics
    let count: Int
    var shapeLength: CGFloat {
        NotchLayout.shapeLength(cellCount: max(1, count), edge: edge, flare: NotchLayout.curlRadius, metrics: metrics)
    }
    var length: CGFloat { max(shapeLength + NotchLayout.orbDiameter * 1.5, NotchLayout.cardMaxWidth + 24) }
    var depth: CGFloat {
        return NotchLayout.bodyDepth(for: edge, metrics: metrics) + NotchLayout.cardMaxWidth + NotchLayout.cardGap + 12
    }
    var size: CGSize { NotchPlacement.panelSize(edge: edge, length: length, depth: depth) }
    var placement: NotchPlacement { NotchPlacement(edge: edge, panelSize: size) }
    var bar: CGRect { placement.rect(along: 0, across: 0, length: shapeLength, depth: NotchLayout.bodyDepth(for: edge, metrics: metrics)) }
    var orb: NotchLayout.OrbGeometry { NotchLayout.orbGeometry(edge: edge, shapeSize: bar.size) }
    func center(_ index: Int) -> CGPoint {
        placement.point(along: NotchLayout.ringCenter(index: index, edge: edge, flare: NotchLayout.curlRadius, metrics: metrics)
            + (NotchLayout.cellExtent(metrics) - NotchLayout.ringDiameter(metrics)) / 2,
            across: NotchLayout.ringMargin(for: edge, metrics: metrics) + NotchLayout.ringDiameter(metrics) / 2)
    }
    func insertion(at point: CGPoint, entries: [EditorEntry], excluding source: String?) -> String? {
        let along = placement.along(of: point)
        return entries.enumerated().first { index, entry in
            entry.id != source && along < placement.along(of: center(index))
        }?.element.id
    }
    func position(at point: CGPoint, entries: [EditorEntry], excluding sources: Set<String>) -> EditorDragSession.Position {
        let along = placement.along(of: point)
        let candidates = entries.enumerated().filter { !sources.contains($0.element.id) }
        guard let nearest = candidates.min(by: {
            abs(placement.along(of: center($0.offset)) - along) < abs(placement.along(of: center($1.offset)) - along)
        }) else { return .end }
        return along < placement.along(of: center(nearest.offset)) ? .before(nearest.element.id) : .after(nearest.element.id)
    }
    func marker(before id: String?, entries: [EditorEntry]) -> CGPoint {
        let index = id.flatMap { value in entries.firstIndex { $0.id == value } } ?? entries.count
        let along = NotchLayout.curlRadius + NotchLayout.padStart(for: edge, metrics: metrics) + CGFloat(index) * NotchLayout.cellPitch(for: edge, metrics: metrics)
        return placement.point(along: along, across: NotchLayout.bodyDepth(for: edge, metrics: metrics) / 2)
    }
    func hit(_ point: CGPoint, entries: [EditorEntry]) -> EditorEntry? {
        let extent = NotchLayout.cellExtent(metrics) + 10
        return entries.enumerated().first { index, _ in
            let center = center(index)
            return CGRect(x: center.x - extent / 2, y: center.y - extent / 2, width: extent, height: extent).contains(point)
        }?.element
    }
}

struct EditorPreviewTransform: Equatable {
    let scale: CGFloat
    let origin: CGPoint
    let screenRect: CGRect

    @MainActor
    init(layout: EditorPreviewLayout, viewport: CGSize, screenAspect: CGFloat) {
        let available = CGSize(width: max(1, viewport.width - 24), height: max(1, viewport.height - 24))
        let aspect = screenAspect.isFinite && screenAspect > 0 ? screenAspect : 1.6
        let width = min(available.width, available.height * aspect)
        let screenSize = CGSize(width: width, height: width / aspect)
        let screen = CGRect(x: (viewport.width - screenSize.width) / 2, y: (viewport.height - screenSize.height) / 2,
                            width: screenSize.width, height: screenSize.height)
        let anchor: CGPoint
        let source: CGPoint
        switch layout.edge {
        case .right: anchor = CGPoint(x: screen.maxX, y: screen.midY); source = CGPoint(x: layout.bar.maxX, y: layout.bar.midY)
        case .left: anchor = CGPoint(x: screen.minX, y: screen.midY); source = CGPoint(x: layout.bar.minX, y: layout.bar.midY)
        }
        let extents = [source.x, layout.size.width - source.x, source.y, layout.size.height - source.y]
        let spaces = [anchor.x - screen.minX, screen.maxX - anchor.x, anchor.y - screen.minY, screen.maxY - anchor.y]
        let ratios = zip(extents, spaces).compactMap { extent, space -> CGFloat? in extent > 0.001 ? max(0.001, space) / extent : nil }
        scale = min(1, ratios.min() ?? 1)
        origin = CGPoint(x: anchor.x - source.x * scale, y: anchor.y - source.y * scale)
        screenRect = screen
    }

    func canvasPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - origin.x) / scale, y: (point.y - origin.y) / scale)
    }
    func renderedPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + point.x * scale, y: origin.y + point.y * scale)
    }
    func renderedRect(_ rect: CGRect) -> CGRect {
        CGRect(origin: renderedPoint(rect.origin), size: CGSize(width: rect.width * scale, height: rect.height * scale))
    }
}

struct DrawerEditorPreview: View {
    @Environment(\.colorScheme) private var systemScheme
    let entries: [EditorEntry]
    let theme: Theme
    let edge: NotchEdge
    var screenAspect: CGFloat = 1.6
    var background: PreviewBackground = .light
    @ObservedObject var editor: DrawerEditor
    let onSelect: () -> Void
    let begin: (EditorEntry) -> NativeEditorDrag?
    let prepare: (EditorDragInput) -> Bool
    let commit: (EditorDragInput) -> Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frozenTransform: EditorPreviewTransform?
    @State private var frozenLayout: EditorPreviewLayout?
    @State private var currentTransform: EditorPreviewTransform?

    private var displayed: [EditorEntry] {
        guard editor.isTargeted, let session = editor.session else { return entries }
        let map = Dictionary((entries + editor.incomingEntries).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return session.displayed.map { map[$0.id] ?? EditorEntry.missing($0) }
    }
    private var layout: EditorPreviewLayout {
        if let frozenLayout { return frozenLayout }
        return EditorPreviewLayout(edge: edge, metrics: theme.metrics, count: entries.count)
    }
    var body: some View {
        GeometryReader { geometry in
            let transform = frozenTransform ?? EditorPreviewTransform(layout: layout, viewport: geometry.size, screenAspect: screenAspect)
            ZStack(alignment: .topLeading) {
                mockDisplay(transform.screenRect)
                canvas.environment(\.colorScheme, theme.colorScheme(fallback: systemScheme))
                    .scaleEffect(transform.scale, anchor: .topLeading)
                    .frame(width: layout.size.width * transform.scale, height: layout.size.height * transform.scale, alignment: .topLeading)
                    .offset(x: transform.origin.x, y: transform.origin.y)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .overlay {
                NativeEditorSurface(select: { point in
                    if let entry = layout.hit(transform.canvasPoint(point), entries: displayed) {
                        editor.clearStatus(); editor.selection = entry.id; onSelect()
                    }
                }, begin: { point in
                    guard let entry = layout.hit(transform.canvasPoint(point), entries: entries) else { return nil }
                    let drag = begin(entry)
                    if drag != nil { frozenLayout = layout; frozenTransform = transform }
                    return drag
                }, ended: { token in
                    if editor.drag?.token == token { editor.cancel() }
                }, update: { input, point in
                    update(input, point: point, viewport: geometry.size)
                }, accept: { input, point in
                    guard update(input, point: point, viewport: geometry.size) else { return false }
                    return commit(input)
                }, exited: {
                    editor.session?.clearProposal(); editor.isTargeted = false
                }, destinationEnded: { editor.cancel() })
            }
            .onAppear { currentTransform = transform }
            .onChange(of: transform) { currentTransform = transform }
            .onChange(of: geometry.size) { cancelTransform() }
        }
        .onChange(of: background) { cancelTransform() }
        .onChange(of: screenAspect) { cancelTransform() }
        .onChange(of: editor.session?.input) { _, input in
            if input != nil, frozenTransform == nil { frozenTransform = currentTransform }
        }
        .onChange(of: editor.session == nil) { _, idle in if idle { frozenTransform = nil; frozenLayout = nil } }
        .onChange(of: entries.map(\.id)) { _, ids in
            if let selected = editor.selection, !ids.contains(selected) { editor.selection = ids.first }
        }
    }
    /// The mock screen behind the drawer. A wash rather than a flat fill:
    /// a white rectangle the size of this one reads as a blank page, and the
    /// drawer is supposed to look like it is sitting on somebody's display.
    /// Quiet on purpose, since the subject is the black bar on its edge.
    private var wallpaper: LinearGradient {
        LinearGradient(colors: background == .light
            ? [Color(hex: 0xEDF1FB), Color(hex: 0xD3DCEF)]
            : [Color(hex: 0x20232E), Color(hex: 0x0D0F15)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func mockDisplay(_ rect: CGRect) -> some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 15).fill(SettingsStyle.ink.opacity(0.1))
                .padding(-6)
            RoundedRectangle(cornerRadius: 10).fill(wallpaper)
            HStack(spacing: 8) {
                Image(systemName: "apple.logo")
                Text("Finder").fontWeight(.semibold)
                Text("File   Edit   View")
                Spacer()
            }
            .font(.system(size: 7))
            .foregroundStyle((background == .light ? Color.black : Color.white).opacity(0.65))
            .padding(.horizontal, 8).frame(height: 18)
            .background((background == .light ? Color.black : Color.white).opacity(0.04))
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10))
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .allowsHitTesting(false).accessibilityHidden(true)
    }
    private func cancelTransform() {
        editor.cancel(); frozenTransform = nil; frozenLayout = nil
    }
    private func update(_ input: EditorDragInput, point: CGPoint, viewport: CGSize) -> Bool {
        guard point.x.isFinite, point.y.isFinite, prepare(input), var session = editor.session else { return false }
        if frozenLayout == nil {
            let reserved = EditorPreviewLayout(edge: edge, metrics: theme.metrics,
                count: session.baseline.count + (session.movingID == nil ? session.incoming.count : 0))
            if frozenTransform == nil {
                frozenTransform = currentTransform ?? EditorPreviewTransform(layout: layout, viewport: viewport, screenAspect: screenAspect)
            }
            frozenLayout = reserved
        }
        guard let transform = frozenTransform else { return false }
        let location = transform.canvasPoint(point)
        let dropBand = layout.bar.insetBy(dx: -16 / transform.scale, dy: -16 / transform.scale)
        guard dropBand.contains(location) else {
            editor.session?.clearProposal(); editor.isTargeted = false
            return false
        }
        let position = layout.position(at: location, entries: displayed, excluding: Set(session.incoming.map(\.id)))
        guard session.propose(position, current: entries.map(\.item)) else { cancelTransform(); return false }
        editor.session = session; editor.isTargeted = true
        return true
    }
    private func cardBody(_ entry: EditorEntry, index: Int) -> CGRect {
        let height = NotchLayout.cardHeight(for: entry.cell.kind, state: entry.cell.state, metrics: theme.metrics)
        let along = layout.placement.along(of: layout.center(index))
        let start = min(max(0, along - height / 2), layout.length - height)
        return layout.placement.rect(along: start,
            across: NotchLayout.bodyDepth(for: edge, metrics: theme.metrics) + NotchLayout.cardGap,
            length: height, depth: NotchLayout.cardMaxWidth)
    }
    private var canvas: some View {
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                Color.clear
                ForEach(Array(displayed.enumerated()), id: \.element.id) { index, entry in
                    Button { editor.clearStatus(); editor.selection = entry.id; onSelect() } label: {
                        DrawerCellView(cell: entry.cell, theme: theme).accessibilityHidden(true)
                            .padding(5)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.primary(theme).opacity(editor.selection == entry.id ? 0.12 : 0)))
                            .opacity(editor.isTargeted && editor.incomingEntries.contains(where: { $0.id == entry.id }) ? 0.35 : 1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(entry.cell.title)
                    .accessibilityValue("\(index + 1) of \(entries.count)\(entry.cell.kind == .level ? ", " + (entry.cell.state.label.isEmpty ? "Reading level" : entry.cell.state.label) : entry.available ? "" : ", unavailable")")
                    .accessibilityHint("Select to edit. Preview controls do not change system settings.")
                    .accessibilityAddTraits(editor.selection == entry.id ? .isSelected : [])
                    .position(x: layout.center(index).x - layout.bar.minX,
                              y: layout.center(index).y - layout.bar.minY)
                    .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 1), value: displayed.map(\.id))
                }
            }
            .frame(width: layout.bar.width, height: layout.bar.height)
            .modifier(DrawerSurface(shape: SideNotchShape(edge: edge), theme: theme))
            .position(x: layout.bar.midX, y: layout.bar.midY)
            SettingsOrb(isHovered: false, edge: edge, convex: layout.orb.convex,
                        arcRadius: layout.orb.arcRadius, arcOffset: layout.orb.arcOffset, theme: theme)
                .position(layout.placement.point(along: layout.orb.along, across: layout.orb.across))
                .accessibilityHidden(true).allowsHitTesting(false)
            if editor.isTargeted {
                RoundedRectangle(cornerRadius: 2).fill(Palette.primary(theme))
                    .frame(width: NotchLayout.bodyDepth(for: edge, metrics: theme.metrics) - 8, height: 3)
                    .position(layout.marker(before: editor.incomingEntries.first?.id, entries: displayed))
                    .accessibilityHidden(true)
            } else if editor.session == nil, let index = entries.firstIndex(where: { $0.id == editor.selection }) {
                let entry = entries[index]
                let body = cardBody(entry, index: index)
                let along = layout.placement.along(of: layout.center(index))
                let cardAlong = layout.placement.along(of: CGPoint(x: body.midX, y: body.midY))
                ItemCard(cell: entry.cell, direction: edge.tooltipDirection, theme: theme,
                         pointerOffset: along - cardAlong)
                    .position(x: body.midX, y: body.midY)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
    }
}
