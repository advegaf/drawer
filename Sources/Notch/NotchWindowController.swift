import AppKit
import SwiftUI
import Combine

/// A keyboard action the notch can act on. Filled in by the keyboard phase.
enum KeyCommand {
    case escape, up, down, left, right, `return`
}

@MainActor
final class NotchWindowController {
    let model = NotchViewModel()

    /// The panel's content view, so a test can check what SwiftUI is and is not
    /// allowed to reach.
    var panelContentViewForTesting: NSView? { panel?.contentView }

    /// What AppKit settled on, for tests that need to see the panel move and
    /// fade rather than take our word for it.
    var panelFrameForTesting: CGRect? { panel?.frame }
    var panelAlphaForTesting: CGFloat { panel?.alphaValue ?? 0 }
    var panelAcceptsKeyForTesting: Bool { panel?.acceptsKey ?? false }
    var panelIsVisibleForTesting: Bool { panel?.isVisible ?? false }
    /// The hit regions actually handed to the hosting view, so a test can
    /// check what a click would land on without a real panel underneath it.
    var interactiveRectsForTesting: [CGRect] { hostingView?.interactiveRects ?? [] }

    /// Stands in for `NotchPanel.resignKey()` firing for real: an XCTest
    /// process cannot reliably force a key-window change, but it can call the
    /// same override directly.
    func simulateResignKeyForTesting() { panel?.resignKey() }

    /// Open the settings window, asked for by clicking the handle.
    var onOpenSettings: (() -> Void)?
    var onExpandedChange: ((Bool) -> Void)?
    /// A cell was clicked. Does nothing yet.
    var onActivate: ((DrawerCell) -> Void)?
    /// A level cell's slider moved, dragged or clicked straight to a point.
    var onSetLevel: ((DrawerCell, Double) -> Void)?
    var onBeginLevelInteraction: ((DrawerCell) -> Void)?
    var onEndLevelInteraction: ((DrawerCell) -> Void)?
    /// "Remove" was chosen from a cell's context menu, carrying its id.
    var onRemove: ((String) -> Void)?

    /// The chord Settings has registered, so the bar and cell menus can show
    /// its glyph as "Show drawer"'s key equivalent. AppDelegate sets this and
    /// keeps it in step with `preferences.$hotKey`.
    var hotKeyChord: HotKeyChord = .default

    /// Set by a `DRAWER_HOVER` demo run: the poll never clears `hoveredIndex`,
    /// so a screenshot taken any time after launch still finds it hovered.
    var holdHover = false

    /// Where AppKit says the pointer is right now, as a screen point. A test
    /// swaps this for a fixed point instead of asking AppKit.
    var cursorLocation: () -> CGPoint = { NSEvent.mouseLocation }
    var pressedMouseButtons: () -> Int = { NSEvent.pressedMouseButtons }

    private var panel: NotchPanel?
    private var hostingView: NotchHostingView<NotchRootView>?
    private var cancellables = Set<AnyCancellable>()
    private var mouseMonitors: [Any] = []
    private var clearHoverWork: DispatchWorkItem?
    private var cursorTimer: Timer?

    /// The live slider drag, while a level cell's bar is being dragged.
    private var drag: SliderDrag?
    private var dragCell: DrawerCell?
    private var cardMotionTimer: Timer?
    /// A drag that stops receiving events (the mouse-up lost somewhere) is
    /// ended by hand a second after its last one, rather than left stuck.
    private var dragWatchdog: DispatchWorkItem?
    var isDragging: Bool { drag?.isActive ?? false }

    /// Turns wheel deltas into whole steps through the visible window.
    /// `stepThreshold` does not vary by edge: every edge shares one
    /// `cellPitch`. It does vary by cell size, so `relocate()` refreshes it
    /// on the live theme rather than leaving this starting value stale;
    /// `stepThreshold` is a `var` on `WheelStepper`, so reassigning it there
    /// is the smaller change against rebuilding the stepper and losing its
    /// accumulator.
    private var wheelStepper = WheelStepper(stepThreshold: NotchLayout.cellPitch(for: .right) / 2)
    private var overscrollWork: DispatchWorkItem?

    /// Hover in is quick; hover out waits, because the pointer has to cross the
    /// gap between the notch and the card without the card vanishing under it.
    private let hoverGrace: TimeInterval = 0.25
    /// Longer than the hover grace: folding shut is a bigger movement than
    /// dismissing a tooltip, and doing it the instant the pointer strays feels
    /// twitchy rather than responsive.
    private let foldGrace: TimeInterval = 0.45
    private var foldWork: DispatchWorkItem?
    /// True from the moment `foldNow()` starts the closing spring until it
    /// has actually finished, so `updateInteractiveRects()` knows to keep
    /// serving `preFoldRects` instead of recomputing from the model.
    private var isFolding = false
    /// The hit regions as they were the instant before a fold began, held
    /// steady for as long as `isFolding` is true.
    ///
    /// `notchRect`'s depth reads `model.isExpanded` directly, so the moment
    /// `foldNow()` sets it false, a freshly computed `notchRect` is already
    /// pill-thin, well before `unfold`'s spring has actually drawn the shape
    /// that small. Recomputing mid-fold would just trade one wrong rect for
    /// another; freezing the last true-open snapshot is what keeps a click
    /// on a cell that is still visibly there from falling through to
    /// whatever is behind the panel.
    private var preFoldRects: [CGRect] = []
    /// How long the pointer has to sit over the pill, once a monitor has
    /// actually seen it arrive, before it opens.
    var dwell: TimeInterval = 0.2
    private var dwellWork: DispatchWorkItem?
    /// False right after `foldForAction()`, until the pointer has been seen
    /// outside the pill once. Keeps a pointer that never left after the click
    /// that folded the notch from reopening it right back up.
    private var hoverMayReopen = true
    /// Whether we have pushed the pointing hand onto the cursor stack.
    private var isPointing = false
    /// The usable area the panel was last placed against.
    ///
    /// The notch is pinned to `visibleFrame` so it rests on the Dock rather than
    /// under it. But an auto-hiding Dock revealing or concealing itself fires
    /// no screen-parameter notification, so nothing would tell us the space had
    /// come back. The cursor poll is already running; noticing there costs one
    /// rect comparison every 0.3s and needs no new machinery.
    private var lastVisibleFrame: CGRect?

    /// Whether the chord, not a click, is what has the drawer open and pinned.
    private var openedByChord = false
    /// Whether Settings has the notch ordered out right now. Set by
    /// `apply(.hidden)`, cleared by the other two cases, and read by the
    /// chord to decide whether it has to reveal the panel before opening.
    private var hiddenByVisibility = false
    /// Whichever app was frontmost when the chord opened the drawer, so
    /// Escape or a second chord press can hand the keyboard back to it.
    private var previousApp: NSRunningApplication?

    /// The same answer, for the cells that act on the app the user was in:
    /// Quit App and Hide Others. Falls back to the menu bar's owner, which
    /// is right whenever the drawer was opened by hovering rather than by
    /// the chord, since hovering never takes focus.
    var appBeforeDrawer: NSRunningApplication? {
        if let previousApp, !previousApp.isTerminated { return previousApp }
        let owner = NSWorkspace.shared.menuBarOwningApplication
        return owner?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : owner
    }

    func show() {
        relocate()
        startWatchingCursor()

        NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )
        .sink { [weak self] _ in
            MainActor.assumeIsolated { self?.relocate() }
        }
        .store(in: &cancellables)

        model.$isExpanded
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] expanded in
                guard let self, expanded == self.model.isExpanded else { return }
                if !expanded { self.endLevelDrag(); self.stopCardMotion() }
                self.onExpandedChange?(expanded)
            }
            .store(in: &cancellables)

        model.$cells
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, let cell = self.dragCell else { return }
                if !self.model.cells.contains(where: { $0.id == cell.id && $0.kind == .level }) {
                    self.endLevelDrag()
                }
            }
            .store(in: &cancellables)

        model.$hoveredIndex
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.updateInteractiveRects() }
            }
            .store(in: &cancellables)

        // The notch is as tall as the cell list, so gaining or losing one has
        // to resize the panel, not just redraw inside it.
        model.$cells
            .map(\.count)
            .removeDuplicates()
            // Delivered a turn later on purpose. `@Published` fires in
            // `willSet`, and resizing the panel inside that turn lays the
            // hosting view out at once, so SwiftUI renders the old array and
            // never gets a second chance at the new one. After the turn the
            // assignment is done and the render sees the cells it resizes for.
            .receive(on: RunLoop.main)
            .sink { [weak self] count in
                MainActor.assumeIsolated {
                    guard let self, count == self.model.cells.count else { return }
                    self.relocate(cellCount: min(count, self.model.fitCount))
                }
            }
            .store(in: &cancellables)
    }

    func stop() {
        edgeChange += 1
        pendingEdge = nil
        endLevelDrag()
        stopCardMotion()
        cancellables.removeAll()
        onExpandedChange?(false)
        setPointing(false)
        foldWork?.cancel()
        isFolding = false
        dwellWork?.cancel()
        dragWatchdog?.cancel()
        cursorTimer?.invalidate()
        cursorTimer = nil
        mouseMonitors.forEach(NSEvent.removeMonitor)
        mouseMonitors.removeAll()
        clearHoverWork?.cancel()
        overscrollWork?.cancel()
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }

    /// Opens the drawer once, unprompted, on a fresh install: an agent app
    /// with nothing on screen has no way to be found otherwise. Not a pin, so
    /// the pointer leaving folds it through the ordinary hover grace; three
    /// seconds with the pointer never having arrived does the same on its own.
    func revealOnce() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                withAnimation(NotchMotion.unfold) { self.model.isExpanded = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    MainActor.assumeIsolated { self?.setExpanded(false) }
                }
            }
        }
    }

    /// Brings the drawer back up so a failure can be read.
    ///
    /// A fire action folds the drawer before it runs, which is right for a
    /// screenshot and wrong for an error: the red ring lands on a cell drawn
    /// at zero opacity. This puts it back for as long as the failure shows,
    /// without pinning it, so the pointer leaving still folds it.
    func revealForFailure() {
        guard !model.isExpanded else { return }
        withAnimation(NotchMotion.unfold) { model.isExpanded = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.model.isAlwaysOn, !self.model.staysOpen else { return }
                self.setExpanded(false)
            }
        }
    }

    // MARK: - Placement

    func relocate(cellCount: Int? = nil) {
        guard let screen = NotchGeometry.preferredScreen(from: NSScreen.screens) else { return }
        model.adopt(screen: screen)
        wheelStepper.stepThreshold = NotchLayout.cellPitch(for: model.edge, metrics: model.metrics) / 2
        let size = model.panelSize(cellCount: cellCount ?? model.visibleCount)
        let frame = NotchGeometry.panelFrame(for: screen, panelSize: size, edge: model.edge)
        lastVisibleFrame = screen.visibleFrame

        if let panel {
            if panel.frame != frame {
                endLevelDrag()
                stopCardMotion()
            }
            panel.setFrame(frame, display: true)
        } else {
            let panel = NotchPanel(contentRect: frame)
            let hosting = NotchHostingView(rootView: NotchRootView(model: model,
                onAccessibilityActivate: { [weak self] in self?.activateAccessibilityCell(id: $0) },
                onAccessibilityAdjust: { [weak self] in self?.adjustAccessibilityLevel(id: $0, increment: $1) },
                onAccessibilityOpenSettings: { [weak self] in self?.openAccessibilitySettings() }))
            panel.contextMenuProvider = { [weak self] windowPoint in
                guard let self else { return nil }
                return self.contextMenu(atLocal: self.localFromWindow(windowPoint))
            }
            panel.onClick = { [weak self] in self?.handleClick() }
            panel.onPress = { [weak self] windowPoint in
                guard let self else { return false }
                return self.beginDragIfOnBand(at: self.localFromWindow(windowPoint))
            }
            panel.onDrag = { [weak self] windowPoint in
                guard let self else { return }
                self.pointerDragged(at: self.screenPoint(fromWindow: windowPoint))
            }
            panel.onRelease = { [weak self] windowPoint in
                guard let self else { return }
                self.pointerUp(at: self.screenPoint(fromWindow: windowPoint))
            }
            panel.onKey = { [weak self] command in self?.key(command) }
            panel.onResignKey = { [weak self] in
                guard let self, self.openedByChord else { return }
                self.closeChord()
            }

            // The hosting view goes *inside* a plain container rather than
            // being the content view itself.
            //
            // As the content view, SwiftUI gets a say in the window's frame: it
            // reports the content's ideal size, and this view's root is a
            // `GeometryReader`, whose ideal size is 10x10. On the side edges
            // that never surfaced. Turned horizontal, AppKit started walking
            // the window down toward it. 522pt of height to 266, to 10, to
            // zero. Until nothing was drawn at all and the constraint pass
            // gave up and threw, taking the app with it.
            //
            // A container removes the channel instead of arguing with it. The
            // panel's size comes from `NotchGeometry` and from nowhere else,
            // which is what every hit region in this file already assumes.
            let container = NotchContainerView(frame: CGRect(origin: .zero, size: frame.size))
            container.autoresizingMask = [.width, .height]
            hosting.frame = container.bounds
            hosting.autoresizingMask = [.width, .height]
            container.addSubview(hosting)
            panel.contentView = container
            panel.ignoresMouseEvents = true
            panel.orderFrontRegardless()
            self.panel = panel
            self.hostingView = hosting
        }
        // The frame AppKit actually gave us, which is what the flush right-hand
        // edge depends on.
        if let panel {
            Log.drawer.debug("panel \(NSStringFromRect(panel.frame), privacy: .public) on screen \(NSStringFromRect(screen.frame), privacy: .public)")
        }
        updateInteractiveRects()
        model.clampScroll()
    }

    // MARK: - Hit regions

    /// The panel's real size, which AppKit may have rounded up from the one we
    /// asked for. And which the flush edge depends on.
    private var placement: NotchPlacement {
        NotchPlacement(edge: model.edge, panelSize: panel?.frame.size ?? model.panelSize)
    }

    /// The notch itself, in panel coordinates with a top-left origin.
    /// The bar's area as if it were open, whatever state it is in now.
    private var openBarRect: CGRect {
        placement.rect(
            along: model.slack,
            across: 0,
            length: model.shapeLength,
            depth: NotchLayout.bodyDepth(for: model.edge, metrics: model.metrics)
        )
    }

    var notchRect: CGRect {
        placement.rect(
            along: model.slack,
            across: 0,
            length: model.shapeLength,
            depth: model.notchDepth
        )
    }

    /// What wakes the folded notch. Deliberately larger than the pill it
    /// surrounds. A 10pt target on a screen edge is a fiddly thing to hit, and
    /// the cost of being generous is only that it opens a little eagerly.
    var pillRect: CGRect {
        // Whatever the resting shape is. The pill, or the display's own notch
        // when it is joining one. The region that wakes it is that plus a
        // generous band, because both are small targets on a screen edge.
        let length = max(model.restingLength, NotchLayout.pillHotZone)
        return placement.rect(
            along: model.slack + (model.shapeLength - length) / 2,
            across: 0,
            length: length,
            depth: model.restingDepth + NotchLayout.pillHotZone
        )
    }

    /// The handle's bounding box, for deciding whether the panel takes events
    /// at all. Whether a point is actually *on* the handle is a finer question
    /// than a box can answer. See `isOverHandle`.
    private var handleRect: CGRect {
        let side = NotchLayout.orbHotZone
        let boxes = model.orbHandlePoints.map { point -> CGRect in
            let centre = placement.point(along: model.slack + point.x, across: point.y)
            return CGRect(x: centre.x - side / 2, y: centre.y - side / 2,
                          width: side, height: side)
        }
        return boxes.dropFirst().reduce(boxes.first ?? .zero) { $0.union($1) }
    }

    /// Whether the pointer is on the handle itself rather than merely inside
    /// the box that contains it.
    private func isOverHandle(_ local: CGPoint) -> Bool {
        model.isOnOrbHandle(along: placement.along(of: local) - model.slack,
                            across: placement.across(of: local))
    }

    /// The only region that takes the mouse. Everything else in the panel is a
    /// hole. This matters far more folded than open, since the point of
    /// folding away is to stop being in the way.
    var liveRect: CGRect {
        guard model.isExpanded else { return pillRect }
        // The orb hangs below the shape, so the live region is both together.
        return notchRect.union(handleRect)
    }

    func tooltipRect(index: Int) -> CGRect? {
        model.cardPlacement(index: index, panelSize: placement.panelSize)?.body
    }

    /// The `LevelBar` row inside a hovered level cell's card, in panel
    /// coordinates: the same header height and gap `ItemCard` lays out with,
    /// so what is drawn and what is draggable never drift apart.
    func sliderBand(for index: Int) -> CGRect? {
        guard model.cells.indices.contains(index), model.cells[index].kind == .level,
              let card = tooltipRect(index: index)
        else { return nil }
        return CGRect(
            x: card.minX + NotchLayout.cardPadding,
            y: card.minY + NotchLayout.cardPadding + NotchLayout.cardTitleLineHeight(model.metrics) + NotchLayout.headerToBlock,
            width: NotchLayout.cardTextWidth,
            height: NotchLayout.sliderHitDepth
        )
    }

    /// The regions a click reaches while the notch is genuinely open: the
    /// shape, the handle, and whatever tooltip card is out.
    private func openRects() -> [CGRect] {
        var rects = [notchRect, handleRect]
        if let index = model.hoveredIndex, let card = tooltipRect(index: index) {
            rects.append(card)
        }
        return rects
    }

    private func updateInteractiveRects() {
        // `model.isExpanded` wins whenever it is true, including a reopen
        // that lands mid-fold: that always recomputes fresh, so the frozen
        // snapshot below can never go stale on it. Only a still-closing fold
        // falls back to `preFoldRects`.
        let rects: [CGRect]
        if model.isExpanded {
            rects = openRects()
        } else if isFolding {
            rects = preFoldRects
        } else {
            rects = [pillRect]
        }
        hostingView?.interactiveRects = rects
        // A drag holds the panel live regardless of where the pointer strays,
        // or the mouse-up that ends it would never arrive.
        guard !isDragging, let panel else { return }
        let local = localCursor(cursorLocation(), in: panel.frame)
        panel.ignoresMouseEvents = !rects.contains { $0.contains(local) }
    }

    // MARK: - Cursor tracking

    /// A global monitor catches the outside-to-inside crossing while the panel
    /// is still ignoring events; a local one catches the way back out.
    ///
    /// A slow poll backs both of them up, because a cursor that never moves
    /// produces no events at all. So a notch that appears, resizes or is
    /// re-anchored underneath a parked pointer would otherwise sit there with
    /// stale hover state until the user jogged the mouse.
    ///
    /// The monitors and the poll are adapters, nothing more: each reads the
    /// cursor once, through cursorLocation, and feeds the result to
    /// pointerMoved(at:), which has no way to tell which of the three called
    /// it. That matters for whatever arms a dwell later: it must be armed only
    /// from the monitor path, never from the poll, or a pointer that is not
    /// moving at all would still trip it every 0.3 seconds.
    private func startWatchingCursor() {
        let poll = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Only on the poll, not on every mouse-moved event: this reads
                // the screen list, and doing that per event would be work at
                // 60Hz to answer a question that changes twice a minute.
                self.followUsableAreaIfItMoved()
                self.pointerMoved(at: self.cursorLocation(), fromMonitor: false)
            }
        }
        RunLoop.main.add(poll, forMode: .common)
        cursorTimer = poll

        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        let handler: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.type == .leftMouseDragged {
                    self.pointerDragged(at: self.cursorLocation())
                } else {
                    self.pointerMoved(at: self.cursorLocation(), fromMonitor: true)
                }
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: handler) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            handler(event)
            if event.type == .leftMouseDragged, event.window === self?.panel { return nil }
            return event
        }) {
            mouseMonitors.append(local)
        }

        if let globalScroll = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            MainActor.assumeIsolated { _ = self?.handleScroll(event) }
        }) {
            mouseMonitors.append(globalScroll)
        }
        if let localScroll = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }
                return self.handleScroll(event) ? nil : event
            }
        }) {
            mouseMonitors.append(localScroll)
        }

        let outsideClickHandler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.outsideClick(at: self.cursorLocation())
            }
        }
        if let globalClick = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: outsideClickHandler) {
            mouseMonitors.append(globalClick)
        }
        if let localClick = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { event in
            outsideClickHandler(event)
            return event
        }) {
            mouseMonitors.append(localClick)
        }
    }

    /// A left click while the drawer is pinned, anywhere but the bar and its
    /// tooltip, unpins it; if the chord is what pinned it, that also hands the
    /// keyboard back. A click on the bar or the card is `pointerDown`'s to
    /// answer, and Always show is never touched here.
    func outsideClick(at screenPoint: CGPoint) {
        guard let panel, model.isPinned, !model.isAlwaysOn else { return }
        let local = localCursor(screenPoint, in: panel.frame)
        guard !liveRect.contains(local) else { return }
        if let index = model.hoveredIndex, let card = tooltipRect(index: index), card.contains(local) {
            return
        }
        model.isPinned = false
        if openedByChord { closeChord() }
    }

    /// Feeds a scroll event to `wheel(deltaAlong:precise:momentum:)` when the
    /// pointer is over the live region, the same gate every other pointer
    /// source already goes through. Returns whether it was consumed.
    @discardableResult
    private func handleScroll(_ event: NSEvent) -> Bool {
        guard let panel else { return false }
        let local = localCursor(cursorLocation(), in: panel.frame)
        guard liveRect.contains(local) else { return false }
        // AppKit hands a physical scroll toward later content as a negative
        // delta on both axes; `wheel(deltaAlong:)` wants the opposite sign, so
        // it stays plain reading "positive moves forward" whichever edge or
        // axis the delta came from.
        let raw = event.scrollingDeltaY
        wheel(deltaAlong: -raw, precise: event.hasPreciseScrollingDeltas,
              momentum: event.momentumPhase != [])
        return true
    }

    /// A screen point, converted into the panel's own top-left-origin space.
    private func localCursor(_ screenPoint: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: screenPoint.x - frame.minX, y: frame.maxY - screenPoint.y)
    }

    /// `localCursor`'s sibling for a point AppKit already hands over in
    /// window coordinates: bottom-left origin, but already window-relative,
    /// so only the axis needs flipping, not the origin as well.
    private func localFromWindow(_ windowPoint: CGPoint) -> CGPoint {
        guard let panel else { return windowPoint }
        return CGPoint(x: windowPoint.x, y: panel.frame.height - windowPoint.y)
    }

    /// The inverse of `NSEvent.locationInWindow`: a window point promoted to
    /// a screen point, so `pointerDragged(at:)` and `pointerUp(at:)` stay on
    /// the one screen-point API every other pointer source already uses.
    private func screenPoint(fromWindow windowPoint: CGPoint) -> CGPoint {
        guard let panel else { return windowPoint }
        return CGPoint(x: windowPoint.x + panel.frame.minX, y: windowPoint.y + panel.frame.minY)
    }

    /// Has the Dock appeared, gone away, moved or resized since we last placed
    /// the panel? Nothing notifies us, so this is asked rather than told.
    private func followUsableAreaIfItMoved() {
        guard let screen = NotchGeometry.preferredScreen(from: NSScreen.screens) else { return }
        guard screen.visibleFrame != lastVisibleFrame else { return }
        relocate()
    }

    /// Where every pointer-position source ends up: the poll, both monitors,
    /// and a test standing in for either. `screenPoint` is whatever
    /// `cursorLocation()` answered at the moment the caller read it.
    func pointerMoved(at screenPoint: CGPoint, fromMonitor: Bool = true) {
        guard let panel else { return }
        // A drag owns the pointer until it ends: no folding and no hover churn.
        guard !isDragging else { return }

        if model.hoverSource == .keyboard {
            // Only a real monitor move takes the keyboard's selection back;
            // the poll must leave it exactly alone.
            guard fromMonitor else { return }
            model.hoverSource = .pointer
        }

        let local = localCursor(screenPoint, in: panel.frame)

        if model.isExpanded {
            let overTooltip = model.hoveredIndex
                .flatMap(tooltipRect(index:))
                .map { $0.contains(local) } ?? false
            let overBridge = model.hoveredIndex.flatMap {
                model.cardPlacement(index: $0, panelSize: placement.panelSize)
            }?.bridge.contains(local) ?? false
            setExpanded(liveRect.contains(local) || overTooltip || overBridge)
        } else if pillRect.contains(local) {
            if fromMonitor, hoverMayReopen, dwellWork == nil {
                armDwell()
            }
        } else {
            dwellWork?.cancel()
            dwellWork = nil
            // Re-armed only once the pointer has left the whole bar, not just
            // the pill: after an action fold the pointer is still where the
            // cell was, which is outside the pill but inside the bar.
            if !openBarRect.contains(local) { hoverMayReopen = true }
        }

        var target: Int?
        if model.isExpanded, let current = model.hoveredIndex,
           model.cardPlacement(index: current, panelSize: placement.panelSize)?.bridge.contains(local) == true {
            target = current
        } else if model.isExpanded, notchRect.contains(local) {
            target = cellIndex(along: placement.along(of: local))
        } else if model.isExpanded, let current = model.hoveredIndex,
                  let card = tooltipRect(index: current),
                  card.contains(local) {
            target = current
        }

        let overHandle = model.isExpanded && isOverHandle(local)
        if model.isHoveringSettings != overHandle {
            model.isHoveringSettings = overHandle
        }
        setPointing(
            Self.wantsPointingHand(isExpanded: model.isExpanded, cellIndex: target) || overHandle
        )

        // A demo run's injected hover is the one being screenshotted: not
        // moved to wherever a real cursor happens to sit, and not cleared by
        // the usual grace timer either.
        if !holdHover, let target {
            clearHoverWork?.cancel()
            clearHoverWork = nil
            if model.hoveredIndex != target {
                if model.hoveredIndex == nil {
                    withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.125)) {
                        model.hoveredIndex = target
                    }
                } else {
                    moveCard(to: target)
                }
            }
        } else if !holdHover, target == nil, model.hoveredIndex != nil, clearHoverWork == nil {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.clearHoverWork = nil
                    self.stopCardMotion()
                    withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.125)) { self.model.hoveredIndex = nil }
                }
            }
            clearHoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + hoverGrace, execute: work)
        }

        updateInteractiveRects()
    }

    private func stopCardMotion(clearPresentation: Bool = true) {
        cardMotionTimer?.invalidate()
        cardMotionTimer = nil
        if clearPresentation { model.presentedCardPlacement = nil }
    }

    private func moveCard(to index: Int) {
        let from = model.hoveredIndex.flatMap { model.cardPlacement(index: $0) }
        stopCardMotion()
        guard let from, let target = model.targetCardPlacement(index: index),
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            model.hoveredIndex = index
            return
        }
        model.presentedCardPlacement = from
        withAnimation(.easeOut(duration: 0.1)) { model.hoveredIndex = index }
        let started = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.model.hoveredIndex == index, self.model.isExpanded else {
                    timer.invalidate()
                    self?.stopCardMotion()
                    return
                }
                let progress = min(1, (ProcessInfo.processInfo.systemUptime - started) / 0.14)
                let eased = 1 - pow(1 - progress, 3)
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    self.model.presentedCardPlacement = .interpolate(from: from, to: target, fraction: eased)
                }
                self.updateInteractiveRects()
                if progress >= 1 { self.stopCardMotion() }
            }
        }
        cardMotionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// A drag reports through the same monitor a plain move does. Away from a
    /// slider that is still just a move, never arming the dwell; a live
    /// slider drag instead feeds the point straight to `onSetLevel` and
    /// leaves the hover alone.
    func pointerDragged(at screenPoint: CGPoint) {
        guard let panel, let activeDrag = drag, activeDrag.isActive,
              let cell = dragCell
        else {
            pointerMoved(at: screenPoint, fromMonitor: false)
            return
        }
        guard let index = model.cells.firstIndex(where: { $0.id == cell.id }),
              model.geometricIndex(of: index) != nil else {
            endLevelDrag()
            return
        }
        let local = localCursor(screenPoint, in: panel.frame)
        onSetLevel?(cell, activeDrag.value(at: local))
        armDragWatchdog()
    }

    /// Schedules the notch opening once the pointer has sat in the pill's hot
    /// zone for `dwell`. Cancelled the moment the pointer leaves.
    private func armDwell() {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dwellWork = nil
                self.setExpanded(true)
            }
        }
        dwellWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dwell, execute: work)
    }

    /// Releasing ends a drag with one final value, then lets an ordinary
    /// hover move decide whether that leaves the pointer on the card, on the
    /// notch, or nowhere the grace fold should wait for.
    func pointerUp(at screenPoint: CGPoint) {
        guard let panel, let activeDrag = drag, activeDrag.isActive else { return }
        let local = localCursor(screenPoint, in: panel.frame)
        if let cell = dragCell {
            onSetLevel?(cell, activeDrag.value(at: local))
        }
        endLevelDrag()
        pointerMoved(at: screenPoint, fromMonitor: false)
    }

    /// Starts a drag if `local` lands inside the hovered level cell's band.
    /// Shared by `pointerDown(at:)`, which tests drive directly, and the
    /// panel's `onPress`, which needs the same check to decide whether it has
    /// consumed the mouse-down at all.
    @discardableResult
    private func beginDragIfOnBand(at local: CGPoint) -> Bool {
        guard let index = model.hoveredIndex, model.cells.indices.contains(index),
              model.cells[index].kind == .level,
              case .level = model.cells[index].state,
              let band = sliderBand(for: index), band.contains(local)
        else { return false }
        let newDrag = SliderDrag(band: band, horizontal: true, isActive: true)
        stopCardMotion(clearPresentation: false)
        drag = newDrag
        dragCell = model.cells[index]
        onBeginLevelInteraction?(model.cells[index])
        onSetLevel?(model.cells[index], newDrag.value(at: local))
        setPointing(true)
        armDragWatchdog()
        return true
    }

    /// Restarted on every drag event; ends a drag that stops receiving them
    /// (a mouse-up lost to another window, say) rather than leaving it stuck.
    private func armDragWatchdog() {
        dragWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.endStalledDrag() }
        }
        dragWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func endStalledDrag() {
        dragWatchdog = nil
        guard drag != nil else { return }
        if pressedMouseButtons() & 1 != 0 {
            armDragWatchdog()
            return
        }
        endLevelDrag()
        pointerMoved(at: cursorLocation(), fromMonitor: false)
    }

    private func endLevelDrag() {
        drag = nil
        dragWatchdog?.cancel()
        dragWatchdog = nil
        if let cell = dragCell {
            dragCell = nil
            onEndLevelInteraction?(cell)
            stopCardMotion()
        }
    }

    /// Steps the visible window through the cell list. A positive
    /// `deltaAlong` moves toward later cells, whichever edge or axis it came
    /// from; the caller is what turns a raw AppKit delta into that.
    ///
    /// Ignored while folded: there is nothing open to scroll, and a stray
    /// wheel event under a parked pointer must not move the list out from
    /// under the notch before it is even seen.
    func wheel(deltaAlong: CGFloat, precise: Bool, momentum: Bool) {
        guard model.isExpanded, !isDragging else { return }
        let steps = wheelStepper.feed(delta: deltaAlong, precise: precise, momentum: momentum)
        guard steps != 0 else { return }

        let maxStart = max(0, model.cells.count - model.visibleCount)
        let wanted = model.firstVisibleIndex + steps
        model.firstVisibleIndex = wheelStepper.clamp(wanted, within: 0...maxStart)
        if wheelStepper.overscrolled {
            bounceOverscroll(forward: steps > 0)
        }
    }

    /// Pushes the column past its end for a beat, so an overscroll reads as a
    /// bounce rather than simply doing nothing.
    private func bounceOverscroll(forward: Bool) {
        overscrollWork?.cancel()
        model.overscroll = forward ? -NotchLayout.overscroll : NotchLayout.overscroll
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.model.overscroll = 0 }
        }
        overscrollWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }

    /// Opens the drawer pinned from the global chord, or closes it if the
    /// chord is what has it open right now. The keyboard then drives it
    /// without stealing focus from whatever was frontmost.
    func toggleFromHotKey() {
        if openedByChord, model.isExpanded {
            closeChord()
            return
        }
        guard let panel else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        if let frontmost, frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = frontmost
        }
        if hiddenByVisibility {
            panel.orderFrontRegardless()
        }
        dwellWork?.cancel()
        dwellWork = nil
        model.isPinned = true
        openedByChord = true
        model.hoveredIndex = nil
        model.hoverSource = .keyboard
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { model.isExpanded = true }
        panel.acceptsKey = true
        panel.makeKey()
        // A window with no established first responder can otherwise hand
        // the key view loop to the SwiftUI content, which would swallow the
        // arrows before `keyDown` ever sees them. `nil` here means the window
        // itself.
        panel.makeFirstResponder(nil)
    }

    /// Ends a chord-opened drawer: folds it (Always show aside), releases the
    /// keyboard, re-hides it if Settings had it hidden, and hands the
    /// keyboard back to whatever was frontmost before the chord.
    func closeChord() {
        endLevelDrag()
        stopCardMotion()
        panel?.acceptsKey = false
        openedByChord = false
        model.isPinned = false
        model.hoverSource = .pointer
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if !model.isAlwaysOn { foldNow() }
        }
        if hiddenByVisibility { panel?.orderOut(nil) }
        if let previousApp, previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            _ = previousApp.activate()
        }
    }

    /// Drives the open drawer from the keyboard: arrows move the selection,
    /// Return activates it, Escape hands the chord back. Ignored while folded.
    func key(_ command: KeyCommand) {
        guard model.isExpanded else { return }
        endLevelDrag()
        stopCardMotion()
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            switch command {
            case .escape:
                closeChord()
            case .down, .right:
                moveHover(forward: true)
            case .up, .left:
                moveHover(forward: false)
            case .return:
                activateHovered()
            }
        }
    }

    /// Steps the selection by one cell, wrapping into `firstVisibleIndex`
    /// or the last visible cell from no selection at all, and scrolling the
    /// window by one when the new selection would otherwise fall outside it.
    private func moveHover(forward: Bool) {
        guard !model.cells.isEmpty else { return }
        let newIndex: Int
        if let hovered = model.hoveredIndex {
            newIndex = forward ? min(hovered + 1, model.cells.count - 1) : max(hovered - 1, 0)
        } else {
            newIndex = forward ? model.firstVisibleIndex : model.firstVisibleIndex + model.visibleCount - 1
        }
        if !model.visibleRange.contains(newIndex) {
            model.firstVisibleIndex += forward ? 1 : -1
            model.clampScroll()
        }
        model.hoverSource = .keyboard
        model.hoveredIndex = newIndex
    }

    /// Return's guards mirror `pointerDown`'s: a pending or a level cell
    /// ignores the key the same way it ignores the click.
    private func activateHovered() {
        guard let index = model.hoveredIndex, model.cells.indices.contains(index) else { return }
        let cell = model.cells[index]
        guard cell.state != .pending, cell.kind != .level else { return }
        onActivate?(cell)
    }

    static func accessibilityEnabled(_ cell: DrawerCell) -> Bool {
        guard cell.state != .pending else { return false }
        switch cell.kind {
        case .level:
            guard case .level(let value) = cell.state else { return false }
            return value.isFinite
        case .toggle:
            return cell.state != .unknown && cell.state != .unavailable
        case .launch, .shortcut, .fire, .add:
            return true
        }
    }

    private func accessibilityCell(id: String) -> DrawerCell? {
        guard panel?.isVisible == true, model.isExpanded, !isDragging,
              let index = model.cells.firstIndex(where: { $0.id == id }),
              index >= model.firstVisibleIndex,
              index < model.firstVisibleIndex + model.visibleCount,
              Self.accessibilityEnabled(model.cells[index]) else { return nil }
        return model.cells[index]
    }

    func activateAccessibilityCell(id: String) {
        guard let cell = accessibilityCell(id: id), cell.kind != .level else { return }
        onActivate?(cell)
    }

    func adjustAccessibilityLevel(id: String, increment: Bool) {
        guard let cell = accessibilityCell(id: id), cell.kind == .level,
              case .level(let value) = cell.state else { return }
        let adjusted = min(1, max(0, value + (increment ? 0.05 : -0.05)))
        guard adjusted != value else { return }
        onBeginLevelInteraction?(cell)
        onSetLevel?(cell, adjusted)
        onEndLevelInteraction?(cell)
    }

    func openAccessibilitySettings() {
        guard panel?.isVisible == true, model.isExpanded else { return }
        onOpenSettings?()
    }

    /// Opens on contact, folds shut after a pause. Unless it has been pinned
    /// open, in which case the pointer is not what decides.
    private func setExpanded(_ wanted: Bool) {
        if wanted {
            foldWork?.cancel()
            foldWork = nil
            guard !model.isExpanded else { return }
            withAnimation(NotchMotion.unfold) { model.isExpanded = true }
            return
        }

        guard model.isExpanded, !model.staysOpen, foldWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.foldWork = nil
                self?.foldNow()
            }
        }
        foldWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + foldGrace, execute: work)
    }

    /// The actual fold, shared by the graced path above and by `foldForAction`,
    /// which needs it to happen at once rather than after a pause.
    private func foldNow() {
        guard !model.staysOpen else { return }
        endLevelDrag()
        stopCardMotion()
        // Only worth doing when there is a spring to outlast: under Reduce
        // Motion `motion(_:)` returns nil, the shape jumps straight to the
        // pill with nothing to see in between, and holding the open rects
        // open here would just be a dead window of its own. Same check
        // `moveCard` already uses.
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Computed fresh, before anything below flips, rather than
            // trusted from whatever `hostingView.interactiveRects` last
            // happened to hold: nothing guarantees that was refreshed since
            // the notch opened. Held until the spring is done: see
            // `preFoldRects`.
            preFoldRects = openRects()
            isFolding = true
        }
        withAnimation(NotchMotion.unfold, completionCriteria: .logicallyComplete) {
            model.isExpanded = false
            model.hoveredIndex = nil
        } completion: { [weak self] in
            MainActor.assumeIsolated {
                self?.isFolding = false
                self?.updateInteractiveRects()
            }
        }
        // A folded drawer always reopens at the top, not wherever it was
        // scrolled to last.
        model.firstVisibleIndex = 0
        setPointing(false)
        updateInteractiveRects()
    }

    /// Folds for an action's own sake: no grace, and the pointer sitting right
    /// where it was must not reopen the notch out from under the click that
    /// just folded it. Held open by Settings' Always show is the one thing
    /// this does not override.
    func foldForAction() {
        hoverMayReopen = false
        if openedByChord {
            closeChord()
            return
        }
        guard !model.isAlwaysOn else { return }
        foldWork?.cancel()
        foldWork = nil
        model.isPinned = false
        foldNow()
    }

    /// The rings are buttons, so they should say so.
    static func wantsPointingHand(isExpanded: Bool, cellIndex: Int?) -> Bool {
        isExpanded && cellIndex != nil
    }

    /// Pushed and popped rather than `set`, so leaving restores whatever cursor
    /// the app underneath had chosen. Setting `.arrow` on the way out would
    /// stamp an arrow over someone else's text caret.
    private func setPointing(_ wanted: Bool) {
        guard wanted != isPointing else { return }
        isPointing = wanted
        if wanted {
            NSCursor.pointingHand.push()
        } else {
            NSCursor.pop()
        }
    }

    /// A click on a ring activates that cell; a click anywhere else on the
    /// open notch pins it. The ring is the more specific target, so it wins.
    func pointerDown(at screenPoint: CGPoint) {
        guard let panel, model.isExpanded else {
            // Opens it, the same as the pointer arriving would. It must not
            // also pin it. The pill's hot zone is deliberately generous, since
            // it is a small target on a screen edge, so a click aimed at
            // something else nearby can land here without the notch ever
            // having been seen open. Pinning is what a click on a notch that
            // is *already* open does; folding it back in later is exactly
            // the ordinary hover behaviour, which a plain `setExpanded` leaves
            // intact.
            setExpanded(true)
            return
        }
        let local = localCursor(screenPoint, in: panel.frame)

        let onCard = model.hoveredIndex.flatMap(tooltipRect(index:))?.contains(local) ?? false
        guard notchRect.contains(local) || isOverHandle(local) || onCard else { return }
        if beginDragIfOnBand(at: local) { return }

        // The handle sits inside the notch, so it has to be tested before the
        // cells, otherwise the cell band nearest the foot of the stack swallows
        // it and clicking the gear opens settings instead.
        if isOverHandle(local) {
            onOpenSettings?()
            return
        }
        if notchRect.contains(local),
           let index = cellIndex(along: placement.along(of: local)),
           model.cells.indices.contains(index) {
            let cell = model.cells[index]
            guard cell.state != .pending, cell.kind != .level else { return }
            onActivate?(cell)
            return
        }
        togglePinned()
    }

    /// `NotchPanel.onClick` and tests written before the pointer seam call
    /// this; it reads the cursor itself and forwards to `pointerDown(at:)`.
    func handleClick() {
        pointerDown(at: cursorLocation())
    }

    /// Move the notch to another screen edge.
    ///
    /// It goes out where it was, crosses while there is nothing to see, and
    /// then **opens** where it now is. The same unfold hovering uses, so a
    /// move ends the way reaching for it does rather than with a bar appearing
    /// at full size.
    ///
    /// Changing the placement moves the panel, turns the shape on its side and
    /// relays the whole stack, all in one frame. Done in view that is a jump no
    /// animation can smooth over, and animating a panel across a corner looks
    /// like a bug rather than a choice. Hence the crossing rather than a
    /// slide.
    func apply(edge: NotchEdge) {
        guard (pendingEdge ?? model.edge) != edge else { return }
        let wasOpen = pendingEdge == nil ? model.isExpanded : edgeTransitionWasOpen
        edgeTransitionWasOpen = wasOpen
        pendingEdge = edge
        edgeChange += 1
        let change = edgeChange
        endLevelDrag()
        stopCardMotion()
        guard let panel else {   // before there is anything on screen to fade
            model.edge = edge
            relocate()
            pendingEdge = nil
            return
        }
        model.hoveredIndex = nil
        setPointing(false)

        // Clicking through the picker starts a move before the last one has
        // landed, and a stale completion would drop the notch on an edge the
        // user has already moved on from.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.edgeCrossfade
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, change == self.edgeChange else { return }

                // Land folded, and at full strength: the opening *is* the
                // animation, and fading in underneath it would be two at once.
                self.model.edge = edge
                self.model.isExpanded = false
                self.relocate()
                self.updateInteractiveRects()
                panel.alphaValue = 1

                guard wasOpen else {
                    self.pendingEdge = nil
                    return
                }
                // A beat, then open. Not decoration: setting it shut and open
                // again inside one turn lets SwiftUI coalesce the pair, and the
                // notch arrives at full size having animated nothing.
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.arrivalBeat) {
                    MainActor.assumeIsolated {
                        guard change == self.edgeChange else { return }
                        withAnimation(NotchMotion.unfold) { self.model.isExpanded = true }
                        self.pendingEdge = nil
                        self.updateInteractiveRects()
                    }
                }
            }
        }
    }

    /// Half the crossing, each way. Short: it is a settings change, not a
    /// flourish, and the notch should be back before you have looked up.
    private static let edgeCrossfade: TimeInterval = 0.16
    /// The pause between landing and opening.
    private static let arrivalBeat: TimeInterval = 0.05
    private var edgeChange = 0
    private var pendingEdge: NotchEdge?
    private var edgeTransitionWasOpen = false

    func apply(_ visibility: NotchVisibility) {
        endLevelDrag()
        stopCardMotion()
        // A standing choice from Settings overrides a chord that happens to
        // be open, the same way it already overrides a hand-made pin.
        if openedByChord { closeChord() }
        switch visibility {
        case .alwaysShow:
            hiddenByVisibility = false
            panel?.orderFrontRegardless()
            model.isAlwaysOn = true
            // Any pin made by hand is subsumed by the setting; leaving it set
            // would outlive a later switch back to hover.
            model.isPinned = false
            foldWork?.cancel()
            foldWork = nil
            withAnimation(NotchMotion.unfold) { model.isExpanded = true }
        case .onHover:
            hiddenByVisibility = false
            panel?.orderFrontRegardless()
            model.isAlwaysOn = false
            model.isPinned = false
            // Fold now rather than waiting for the pointer to leave: it may
            // already be somewhere else, in which case nothing would arrive to
            // close it and "on hover" would look exactly like "always show".
            withAnimation(NotchMotion.unfold) {
                model.isExpanded = false
                model.hoveredIndex = nil
            }
        case .hidden:
            hiddenByVisibility = true
            model.isAlwaysOn = false
            model.isPinned = false
            model.isExpanded = false
            model.hoveredIndex = nil
            // Ordered out rather than made transparent. An invisible panel that
            // still takes the screen edge would keep swallowing the pointer.
            panel?.orderOut(nil)
        }
        setPointing(false)
        updateInteractiveRects()
    }

    /// Clicking the open notch pins it, so it stays put while you read it.
    ///
    /// A no-op while Settings says Always show: there the notch is already
    /// held open by a standing choice, and letting a click release it meant
    /// the setting said one thing and the notch did another.
    func togglePinned() {
        guard !model.isAlwaysOn else { return }
        model.isPinned.toggle()
        if model.isPinned {
            foldWork?.cancel()
            foldWork = nil
            withAnimation(NotchMotion.unfold) { model.isExpanded = true }
        }
        updateInteractiveRects()
    }

    /// Not private: exercised directly by the scroll tests, the same way the
    /// pointer path already does.
    func cellIndex(along: CGFloat) -> Int? {
        let pitch = NotchLayout.cellPitch(for: model.edge, metrics: model.metrics)
        for slot in 0..<model.visibleCount {
            let centre = model.slack + model.ringCenter(visible: slot)
            if abs(along - centre) <= pitch / 2 { return model.firstVisibleIndex + slot }
        }
        return nil
    }

    // MARK: - Odds and ends

    /// `local` is the right-click point in panel coordinates, when there is
    /// one to check against a cell; the bar's own items are the same either
    /// way. Order: Keep open, Show drawer, Settings, a separator, Quit.
    func contextMenu(atLocal local: CGPoint?) -> NSMenu {
        Log.drawer.debug("context menu opened")
        let menu = NSMenu()
        // AppKit otherwise decides enablement itself and overrules the lines
        // below. Turning it off means every item has to say so for itself.
        menu.autoenablesItems = false

        if let local, let cell = cellUnderPoint(local),
           cell.id.hasPrefix("action:"),
           let action = ActionID(rawValue: String(cell.id.dropFirst("action:".count))),
           CellPicker.has(action) {
            for item in CellPicker.items(for: action, target: menuActions) { menu.addItem(item) }
        }

        if let local, let cell = cellUnderPoint(local) {
            let remove = NSMenuItem(
                title: "Remove \(cell.title)",
                action: #selector(MenuActions.removeCell(_:)),
                keyEquivalent: ""
            )
            remove.target = menuActions
            remove.representedObject = cell.id
            remove.isEnabled = true
            menu.addItem(remove)
            menu.addItem(.separator())
        }

        let keepOpen = NSMenuItem(
            title: "Keep open",
            action: #selector(MenuActions.togglePinned(_:)),
            keyEquivalent: ""
        )
        keepOpen.target = menuActions
        // Checked whichever way it is being held open, but only changeable
        // when it is the click that is holding it. The setting is Settings'
        // to change, and a menu item that silently loses is worse than one
        // that says it is not yours to press.
        keepOpen.state = model.staysOpen ? .on : .off
        keepOpen.isEnabled = !model.isAlwaysOn
        keepOpen.toolTip = model.isAlwaysOn
            ? "Drawer is set to Always show. Change it in Settings."
            : nil
        menu.addItem(keepOpen)

        let showDrawer = NSMenuItem(
            title: "Show drawer",
            action: #selector(MenuActions.showDrawer(_:)),
            keyEquivalent: hotKeyChord.menuKeyEquivalent.key
        )
        showDrawer.keyEquivalentModifierMask = hotKeyChord.menuKeyEquivalent.modifiers
        showDrawer.target = menuActions
        showDrawer.isEnabled = true
        menu.addItem(showDrawer)

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(MenuActions.openSettings(_:)),
            keyEquivalent: ","
        )
        settings.target = menuActions
        settings.isEnabled = true
        menu.addItem(settings)

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Drawer",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ).isEnabled = true
        return menu
    }

    /// The cell a right-click point landed on, if the notch is open and the
    /// point is inside `notchRect` over a real cell rather than the add tile.
    private func cellUnderPoint(_ local: CGPoint) -> DrawerCell? {
        guard model.isExpanded, notchRect.contains(local),
              let index = cellIndex(along: placement.along(of: local)),
              model.cells.indices.contains(index)
        else { return nil }
        let cell = model.cells[index]
        return cell.kind == .add ? nil : cell
    }

    private lazy var menuActions = MenuActions(
        togglePinned: { [weak self] in self?.togglePinned() },
        openSettings: { [weak self] in self?.onOpenSettings?() },
        showDrawer: { [weak self] in self?.toggleFromHotKey() },
        removeCell: { [weak self] id in self?.onRemove?(id) }
    )
}

/// A menu item needs an Objective-C target, which a `@MainActor` Swift class
/// with closures cannot be directly.
final class MenuActions: NSObject {
    private let pin: () -> Void
    private let settings: () -> Void
    private let showDrawerAction: () -> Void
    private let removeCellAction: (String) -> Void

    init(togglePinned: @escaping () -> Void, openSettings: @escaping () -> Void,
         showDrawer: @escaping () -> Void, removeCell: @escaping (String) -> Void) {
        self.pin = togglePinned
        self.settings = openSettings
        self.showDrawerAction = showDrawer
        self.removeCellAction = removeCell
    }

    @objc func togglePinned(_ sender: Any?) { pin() }
    @objc func openSettings(_ sender: Any?) { settings() }
    @objc func showDrawer(_ sender: Any?) { showDrawerAction() }
    @objc func removeCell(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.representedObject as? String else { return }
        removeCellAction(id)
    }

    /// The three pickers. Each one does its work off the main thread and
    /// says nothing on success: the menu is already gone by then, and the
    /// cell shows the result the next time it reads.
    @objc func joinNetwork(_ sender: Any?) {
        guard let ssid = (sender as? NSMenuItem)?.representedObject as? String else { return }
        Task { try? await WiFiNetworks.join(ssid) }
    }

    @objc func toggleBluetoothDevice(_ sender: Any?) {
        guard let address = (sender as? NSMenuItem)?.representedObject as? String else { return }
        Task.detached { try? BluetoothDevices.toggle(address: address) }
    }

    @objc func chooseOutput(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.representedObject as? UInt32 else { return }
        try? AudioDevices.setDefault(id)
    }



    @objc func chooseInput(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.representedObject as? UInt32 else { return }
        try? AudioInputs.setDefault(id)
    }

    @objc func openNetworkSettings(_ sender: Any?) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func openBluetoothSettings(_ sender: Any?) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// The picker a cell offers on a secondary click, built from the action it
/// carries. Nothing here talks to the radio: the items carry what they need
/// and `MenuActions` does the work when one is chosen.
enum CellPicker {
    /// Which cells have one. Everything else gets the plain menu.
    static func has(_ id: ActionID) -> Bool {
        id == .wifi || id == .bluetooth || id == .volume || id == .mute
            || id == .micMute || id == .micLevel
    }

    @MainActor
    static func items(for id: ActionID, target: MenuActions,
                      networks: [WiFiNetworks.Network]? = nil,
                      devices: [BluetoothDevices.Device]? = nil,
                      outputs: [AudioDevices.Device]? = nil,
                      inputs: [AudioDevices.Device]? = nil) -> [NSMenuItem] {
        switch id {
        case .micMute, .micLevel:
            return list(
                title: "Input",
                entries: (inputs ?? AudioInputs.inputs()).map {
                    ($0.name, $0.isDefault, $0.id as Any, #selector(MenuActions.chooseInput(_:)))
                },
                empty: "No inputs",
                tail: nil,
                target: target
            )
        case .wifi:
            return list(
                title: "Networks",
                entries: (networks ?? WiFiNetworks.known()).map {
                    ($0.ssid, $0.isCurrent, $0.ssid as Any, #selector(MenuActions.joinNetwork(_:)))
                },
                empty: "No known networks",
                tail: ("Network Settings...", #selector(MenuActions.openNetworkSettings(_:))),
                target: target
            )
        case .bluetooth:
            return list(
                title: "Devices",
                entries: (devices ?? BluetoothDevices.paired()).map {
                    ($0.name, $0.isConnected, $0.address as Any, #selector(MenuActions.toggleBluetoothDevice(_:)))
                },
                empty: "No paired devices",
                tail: ("Bluetooth Settings...", #selector(MenuActions.openBluetoothSettings(_:))),
                target: target
            )
        default:
            return list(
                title: "Output",
                entries: (outputs ?? AudioDevices.outputs()).map {
                    ($0.name, $0.isDefault, $0.id as Any, #selector(MenuActions.chooseOutput(_:)))
                },
                empty: "No outputs",
                tail: nil,
                target: target
            )
        }
    }

    private static func list(title: String,
                             entries: [(String, Bool, Any, Selector)],
                             empty: String,
                             tail: (String, Selector)?,
                             target: MenuActions) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        items.append(header)
        if entries.isEmpty {
            let none = NSMenuItem(title: empty, action: nil, keyEquivalent: "")
            none.isEnabled = false
            items.append(none)
        }
        for (name, isOn, payload, selector) in entries {
            let item = NSMenuItem(title: name, action: selector, keyEquivalent: "")
            item.target = target
            item.representedObject = payload
            item.state = isOn ? .on : .off
            item.isEnabled = true
            items.append(item)
        }
        if let tail {
            let item = NSMenuItem(title: tail.0, action: tail.1, keyEquivalent: "")
            item.target = target
            item.isEnabled = true
            items.append(item)
        }
        items.append(.separator())
        return items
    }
}
