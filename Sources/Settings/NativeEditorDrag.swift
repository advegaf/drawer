import AppKit
import SwiftUI

struct NativeEditorDrag {
    let payload: DrawerDrag
    let image: NSImage
}

struct NativeEditorSurface: NSViewRepresentable {
    var select: (CGPoint) -> Void = { _ in }
    var begin: (CGPoint) -> NativeEditorDrag? = { _ in nil }
    var ended: (UUID) -> Void = { _ in }
    var update: (EditorDragInput, CGPoint) -> Bool = { _, _ in false }
    var accept: (EditorDragInput, CGPoint) -> Bool = { _, _ in false }
    var exited: () -> Void = {}
    var destinationEnded: () -> Void = {}
    var receivesDrops = true

    func makeNSView(context: Context) -> NativeEditorDragView { NativeEditorDragView() }
    func updateNSView(_ view: NativeEditorDragView, context: Context) {
        view.select = select
        view.begin = begin
        view.ended = ended
        view.update = update
        view.accept = accept
        view.exited = exited
        view.receivesDrops = receivesDrops
        view.destinationEnded = destinationEnded
    }
}

final class NativeEditorDragView: NSView, NSDraggingSource {
    static let pasteboardType = NSPasteboard.PasteboardType("com.advegaf.drawer.native-editor-item")
    var select: (CGPoint) -> Void = { _ in }
    var begin: (CGPoint) -> NativeEditorDrag? = { _ in nil }
    var ended: (UUID) -> Void = { _ in }
    var update: (EditorDragInput, CGPoint) -> Bool = { _, _ in false }
    var accept: (EditorDragInput, CGPoint) -> Bool = { _, _ in false }
    var exited: () -> Void = {}
    var destinationEnded: () -> Void = {}
    var receivesDrops = true
    private var lastProposal: Bool?
    private var down: NSEvent?
    private var active: (payload: DrawerDrag, completion: (UUID) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([Self.pasteboardType, .fileURL])
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        trace("down", point: convert(event.locationInWindow, from: nil))
        down = event
    }
    override func mouseUp(with event: NSEvent) {
        trace("up", point: convert(event.locationInWindow, from: nil))
        defer { down = nil }
        guard down != nil, active == nil else { return }
        select(convert(event.locationInWindow, from: nil))
    }
    override func mouseDragged(with event: NSEvent) {
        trace("mouse-dragged", point: convert(event.locationInWindow, from: nil))
        guard active == nil, let down,
              hypot(event.locationInWindow.x - down.locationInWindow.x,
                    event.locationInWindow.y - down.locationInWindow.y) >= 3,
              let drag = prepareDrag(at: convert(down.locationInWindow, from: nil)),
              let data = try? JSONEncoder().encode(drag.payload) else { return }
        self.down = nil
        let pasteboard = NSPasteboardItem()
        pasteboard.setData(data, forType: Self.pasteboardType)
        let item = NSDraggingItem(pasteboardWriter: pasteboard)
        let point = convert(event.locationInWindow, from: nil)
        let badge = Self.badge(image: drag.image, appearance: effectiveAppearance)
        let start = convert(down.locationInWindow, from: nil)
        item.setDraggingFrame(Self.initialFrame(at: start, visibleRect: visibleRect), contents: badge)
        trace("begin-session", point: point)
        let session = beginDraggingSession(with: [item], event: down, source: self)
        trace("session-started", point: point)
        session.animatesToStartingPositionsOnCancelOrFail = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    static func initialFrame(at point: CGPoint, visibleRect: CGRect) -> CGRect {
        let side = max(1, min(56, min(visibleRect.width, visibleRect.height)))
        let x = min(max(visibleRect.minX, point.x - side / 2), visibleRect.maxX - side)
        let y = min(max(visibleRect.minY, point.y - side / 2), visibleRect.maxY - side)
        return CGRect(x: x, y: y, width: side, height: side)
    }
    static func badge(image: NSImage, appearance: NSAppearance) -> NSImage {
        let result = NSImage(size: NSSize(width: 56, height: 56))
        appearance.performAsCurrentDrawingAppearance {
            result.lockFocus()
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: 56, height: 56), xRadius: 12, yRadius: 12).fill()
            let glyph = NSImage(size: NSSize(width: 32, height: 32))
            glyph.lockFocus()
            image.draw(in: CGRect(x: 0, y: 0, width: 32, height: 32))
            if image.isTemplate {
                NSColor.labelColor.setFill()
                CGRect(x: 0, y: 0, width: 32, height: 32).fill(using: .sourceAtop)
            }
            glyph.unlockFocus()
            glyph.draw(in: CGRect(x: 12, y: 12, width: 32, height: 32))
            result.unlockFocus()
        }
        result.isTemplate = false
        return result
    }
    func prepareDrag(at point: CGPoint) -> NativeEditorDrag? {
        guard active == nil, let drag = begin(point) else { trace("source-rejected", point: point); return nil }
        active = (drag.payload, ended)
        return drag
    }
    func finishDrag() {
        trace("source-ended")
        let previous = active
        active = nil
        down = nil
        if let previous { previous.completion(previous.payload.token) }
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        guard context == .withinApplication else { return [] }
        return active?.payload.source == .library ? .copy : .move
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { finishDrag() }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        trace("destination-enter", point: convert(sender.draggingLocation, from: nil))
        return draggingUpdated(sender)
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        guard let input = input(sender) else {
            if lastProposal != false { trace("input-rejected", point: point); lastProposal = false }
            return []
        }
        let proposed = update(input, point)
        if lastProposal != proposed { trace(proposed ? "proposal-accepted" : "proposal-rejected", point: point); lastProposal = proposed }
        guard proposed else { return [] }
        if case .local(let payload) = input, payload.source == .pinned { return .move }
        return .copy
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { trace("destination-exit"); lastProposal = nil; exited() }
    override func draggingEnded(_ sender: any NSDraggingInfo) { trace("destination-ended"); lastProposal = nil; destinationEnded() }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { input(sender) != nil }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let input = input(sender) else { trace("drop-input-rejected"); return false }
        let accepted = accept(input, convert(sender.draggingLocation, from: nil))
        trace(accepted ? "drop-committed" : "drop-rejected")
        return accepted
    }
    private func trace(_ phase: String, point: CGPoint = .zero) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["DRAWER_TRACE_EDITOR"] == "1" else { return }
        Log.drawer.notice("editor-event \(phase, privacy: .public) destination=\(self.receivesDrops) down=\(self.down != nil) active=\(self.active != nil) x=\(point.x) y=\(point.y) width=\(self.bounds.width) height=\(self.bounds.height)")
        #endif
    }
    private func input(_ sender: any NSDraggingInfo) -> EditorDragInput? {
        guard receivesDrops, let items = sender.draggingPasteboard.pasteboardItems, !items.isEmpty else { return nil }
        if let source = sender.draggingSource as? NativeEditorDragView {
            guard items.count == 1, let data = items[0].data(forType: Self.pasteboardType),
                  let payload = try? JSONDecoder().decode(DrawerDrag.self, from: data),
                  source.active?.payload == payload else { return nil }
            return .local(payload)
        }
        guard !items.contains(where: { $0.types.contains(Self.pasteboardType) }),
              sender.draggingSourceOperationMask.contains(.copy) else { return nil }
        let urls = items.compactMap { $0.string(forType: .fileURL).flatMap(URL.init(string:)) }
        guard urls.count == items.count else { return nil }
        return .files(urls, sequence: sender.draggingSequenceNumber)
    }
}
