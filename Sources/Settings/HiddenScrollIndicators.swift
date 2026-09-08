import AppKit
import SwiftUI

struct LibraryOverflow: Equatable {
    let above: Bool
    let below: Bool
}

struct HiddenScrollIndicators: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ScrollIndicatorProbe() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { (view as? ScrollIndicatorProbe)?.hideIndicators() }
    }
}

final class ScrollIndicatorProbe: NSView {
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        hideIndicators()
        DispatchQueue.main.async { [weak self] in self?.hideIndicators() }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hideIndicators()
        DispatchQueue.main.async { [weak self] in self?.hideIndicators() }
    }
    override func layout() { super.layout(); hideIndicators() }
    func hideIndicators() {
        guard let scroll = enclosingScrollView else { return }
        if scroll.hasVerticalScroller { scroll.hasVerticalScroller = false }
        if scroll.hasHorizontalScroller { scroll.hasHorizontalScroller = false }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
