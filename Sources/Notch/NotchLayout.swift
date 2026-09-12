import AppKit

/// Every measurement is quoted in design pixels, converted to points by
/// `Design.scale`.
///
/// Most figures are plain constants. The ones that move with the theme's
/// cell size or card text size are functions instead, taking a `Metrics`
/// defaulted to `.default`, so every call site that predates theming still
/// compiles unchanged and still gets the old numbers.
enum NotchLayout {
    // The notch body
    /// The depth used: a 44pt ring with an even margin either side of it, at
    /// `metrics.cellScale` 1.
    private static let baseSideBodyDepth = Design.px(186)
    static func sideBodyDepth(_ metrics: Metrics = .default) -> CGFloat {
        baseSideBodyDepth * metrics.cellScale
    }

    /// How deep the notch is. The cell is the ring alone on every edge, so
    /// this is the same distance whichever edge the stack is on, except with
    /// labels on, where it grows to hold them. Which dimension grows differs
    /// A label sits directly under its ring, along the same axis depth
    /// already measures, so depth grows to fit the label's width, at the
    /// ring's own clearance on both the bezel side and the inner side facing
    /// the card (`cellLabelWidth + 2 * ringMargin`). It does not shrink the
    /// label to fit the ring's margin, which read worse: see
    /// `docs/qa/decisions.md` Phase 24.
    static func bodyDepth(for edge: NotchEdge, metrics: Metrics = .default) -> CGFloat {
        guard metrics.showsLabels else { return sideBodyDepth(metrics) }
        return max(sideBodyDepth(metrics), cellLabelWidth + 2 * ringMargin(for: edge, metrics: metrics))
    }

    /// Clear space between the ring and the bezel. Unaffected by labels: they
    /// add depth on the far side of the ring, not to this margin, which is
    /// what keeps a ring exactly this far from the bezel whether or not its
    /// cell has a label under it.
    private static func sideRingMargin(_ metrics: Metrics = .default) -> CGFloat {
        (sideBodyDepth(metrics) - ringDiameter(metrics)) / 2
    }

    /// The same margin on every edge: on a horizontal one it is the gap above
    /// the ring rather than beside it, but it is the same distance.
    static func ringMargin(for edge: NotchEdge, metrics: Metrics = .default) -> CGFloat {
        sideRingMargin(metrics)
    }

    static let curlRadius   = Design.px(103)
    static let cornerRadius = Design.px(78.8)

    private static let basePadTop      = Design.px(69.5)   // body top -> first ring
    private static let basePadBottom   = Design.px(50.1)   // last ring -> body bottom
    private static let baseCellSpacing = Design.px(83.5)   // ring bottom -> next ring top
    static func padTop(_ metrics: Metrics = .default) -> CGFloat { basePadTop * metrics.cellScale }
    static func padBottom(_ metrics: Metrics = .default) -> CGFloat { basePadBottom * metrics.cellScale }
    static func cellSpacing(_ metrics: Metrics = .default) -> CGFloat { baseCellSpacing * metrics.cellScale }

    // The resting pill. Not a scaled-down notch, but its own shape,
    // sized to read as a deliberate handle rather than a sliver of chrome.
    static let pillWidth  = Design.px(26)
    private static let basePillHeight = Design.px(210)
    static func pillHeight(_ metrics: Metrics = .default) -> CGFloat { basePillHeight * metrics.cellScale }
    /// The pill is small, so the region that wakes it is deliberately larger.
    static let pillHotZone = Design.px(90)

    // A cell's ring
    private static let baseRingDiameter = Design.px(117)   // 44pt, the anchor for Design.scale
    static func ringDiameter(_ metrics: Metrics = .default) -> CGFloat {
        baseRingDiameter * metrics.cellScale
    }
    static let trackStroke   = Design.px(15.5)
    static let progressStroke = Design.px(8)
    private static let baseGlyphSize = Design.px(46)
    static func glyphSize(_ metrics: Metrics = .default) -> CGFloat { baseGlyphSize * metrics.cellScale }

    /// Gap between the ring and the label under it, when labels are on.
    static let labelGap = Design.px(12)

    // The settings orb: it lives *below* the notch, not inside it. At rest only
    // an arc of its edge is drawn, tucked into the corner the bottom flare
    // makes; on hover the same circle fills in and takes a gear. One circle,
    // two states. This is why the arc has to be a segment of it rather than a
    // decorative stroke that happens to sit nearby.
    // Measured off the reference frames, which are 2px per point. The notch
    // body is the familiar 70pt in both, and that fixes the scale.
    //
    // The important find: the resting arc is **concentric with the notch's own
    // bottom flare**, one radius inside it. That is what makes it follow the
    // contour of the edge instead of merely sitting near it, and it is why the
    // orb is centred on the flare's centre rather than on the body's axis.
    //
    //   flare : centre (edge - curlRadius, shapeBottom)   radius 38.5pt
    //   arc   : same centre                                radius 28.5pt
    //   disc  : same centre                                diameter 46.5pt
    static let orbDiameter = Design.px(124)
    static let orbStroke   = Design.px(18)
    /// Distance from the flare's curve in to the resting arc.
    static let orbGap      = Design.px(27)
    /// Radius of the resting arc: the flare's radius, less the gap.
    static var orbArcRadius: CGFloat { curlRadius - orbGap }
    static let orbGlyph    = Design.px(56)
    /// What the arc scales to as it hides.
    ///
    /// The arc is concentric with the bottom flare, `orbGap` inside it, so
    /// growing its radius carries it outward along the normal and *into* the
    /// notch's black. Landing exactly on the flare is not enough. Sitting on
    /// the boundary it is still half visible. It goes a full stroke past, so
    /// the line is genuinely buried and stops being drawable rather than
    /// merely becoming faint.
    ///
    /// Shrinking it instead pulled it toward its own centre, away from the
    /// notch, which is what read as flying off.
    static var orbMergeScale: CGFloat { (curlRadius + orbStroke) / orbArcRadius }
    /// Generous, like the pill's. It is a small target on a screen edge.
    static let orbHotZone  = Design.px(152)

    struct OrbGeometry {
        let along: CGFloat
        let across: CGFloat
        let arcRadius: CGFloat
        let arcOffset: CGSize
        let convex: Bool
        let mergeScale: CGFloat
        let handlePoints: [CGPoint]
    }

    static func orbGeometry(edge: NotchEdge, shapeSize: CGSize) -> OrbGeometry {
        let curves = SideNotchShape(edge: edge).resolvedCurves(in: shapeSize)
        let length = shapeSize.height
        let radius = max(0, curves.curl - orbGap)
        return OrbGeometry(along: length, across: curves.curl, arcRadius: radius,
                           arcOffset: .zero, convex: false,
                           mergeScale: radius > 0 ? (curves.curl + orbStroke) / radius : 1,
                           handlePoints: [CGPoint(x: length, y: curves.curl)])
    }

    // The hover tooltip
    /// What a card was, fixed, until a note got longer than "62%".
    ///
    /// Now the floor rather than the width: a short card looks exactly as it
    /// did, and only a card with more to say grows. The ceiling is what keeps
    /// a failure sentence from running across the screen.
    static let cardMinWidth  = Design.px(600)
    static let cardMaxWidth  = Design.px(940)
    static let cardCorner    = Design.px(32)
    static let cardPadding   = Design.px(32)
    static let cardGap = Design.px(32)
    static let pointerDepth = Design.px(14)
    static let pointerBase = Design.px(28)
    /// Room outside the card for its shadow.
    static let cardShadowPad = Design.px(53)
    static let barHeight     = Design.px(10.5)
    static let headerGap     = Design.px(17)    // glyph -> title
    static let headerToBlock = Design.px(21)
    /// The spinner beside a row's status. Sized against the body text's cap
    /// (18px) rather than picked by eye, so it reads as part of the word rather
    /// than a bullet pinned near it.
    static let statusDot       = Design.px(17)
    static let statusDotStroke = Design.px(3.4)
    static let statusDotGap    = Design.px(11)

    /// Scaled by the theme's card text size.
    static func cardTitleLineHeight(_ metrics: Metrics = .default) -> CGFloat {
        lineHeight(NSFont.systemFont(
            ofSize: Design.fontSize(capPixels: 26) * metrics.cardTextScale, weight: .semibold
        ))
    }
    /// The card's body face. Built fresh per call rather than held, since it
    /// now varies with the theme; every caller measuring body text goes
    /// through this so what is drawn and what is measured never drift apart.
    static func cardBodyFont(_ metrics: Metrics = .default) -> NSFont {
        NSFont.systemFont(ofSize: Design.fontSize(capPixels: 21) * metrics.cardTextScale, weight: .regular)
    }
    static func cardBodyLineHeight(_ metrics: Metrics = .default) -> CGFloat {
        lineHeight(cardBodyFont(metrics))
    }

    /// The cell's label under the ring, when labels are on. Not scaled by the
    /// theme, matching `Typography.cellLabel`.
    static let cellLabelLineHeight: CGFloat = lineHeight(
        NSFont.systemFont(ofSize: Design.fontSize(capPixels: 22), weight: .medium)
    )

    /// The label's own frame width, when labels are on. Wide enough that the
    /// demo set's real titles ("Bluetooth", "Dark mode", "Screenshot",
    /// "Empty Trash") read in full; a narrower frame that merely kept the
    /// ring's margin truncated too much of it to read. `bodyDepth` grows to
    /// fit this on a vertical edge instead, at the ring's own clearance,
    /// rather than this shrinking to fit the ring's old depth. Not scaled by
    /// `metrics`, matching `cellLabelLineHeight`.
    static let cellLabelWidth = Design.px(190)

    /// How wide a line of body text is inside the card.
    static func cardTextWidth(_ width: CGFloat) -> CGFloat { width - 2 * cardPadding }

    /// How wide a card has to be to say what it says.
    ///
    /// `TooltipHeader` lays out the glyph, a gap, the title, a minimum spacer
    /// and the note on one line, and the title carries no line limit, so at a
    /// fixed width SwiftUI squeezes the title first and then clips the note.
    /// Measuring the row is what stops that: "Screen Recording" beside
    /// "Recording 0:15" needs more than the 201.6pt a fixed card left for text.
    static func cardWidth(title: String, note: String?, metrics: Metrics = .default) -> CGFloat {
        let titleWidth = measure(title, font: Typography.cardTitleFont(metrics))
        // The header is an HStack, so its spacing sits between every pair of
        // children: glyph to title, title to spacer, spacer to note. Counting
        // one gap instead of three is 12.8pt short, which is a title that
        // still truncates in a card that measured as wide enough.
        var content = glyphSize(metrics) + headerGap + titleWidth
        if let note, !note.isEmpty {
            content += 2 * headerGap + headerSpacer + measure(note, font: Typography.cardBodyFont(metrics))
        }
        // A little slack: AppKit measures a string and SwiftUI draws it, and
        // the two disagree by a fraction of a point on some faces. Slack can
        // only ever leave a card a hair wide, which nobody sees.
        return min(cardMaxWidth, max(cardMinWidth, content + 2 * cardPadding + Design.px(8)))
    }

    /// The `Spacer(minLength:)` between the title and the note in the header.
    static let headerSpacer = Design.px(20)

    private static func measure(_ text: String, font: NSFont) -> CGFloat {
        #if DEBUG
        textMeasurements += 1
        #endif
        // Rounded up: a fraction of a point short is a truncated glyph, and a
        // fraction over is invisible.
        return (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }

    #if DEBUG
    /// How many times text has been laid out since the counter was last reset.
    ///
    /// A counter rather than a stopwatch. What went wrong here was work done
    /// thousands of times per frame, and a count of that work says the same
    /// thing on a busy machine as on an idle one, which a millisecond figure
    /// does not. `Tests/HoverCostTests.swift` is what reads it.
    nonisolated(unsafe) static var textMeasurements = 0
    #endif

    private static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    /// What a cell claims along a *vertical* stack: the ring alone, plus a
    /// label's own room when labels are on. On a horizontal stack this is not
    /// what `cellAlong` returns; see there.
    static func cellExtent(_ metrics: Metrics = .default) -> CGFloat {
        var extent = ringDiameter(metrics)
        if metrics.showsLabels { extent += labelGap + cellLabelLineHeight }
        return extent
    }

    /// What one cell claims along the stack. On a side edge that is
    /// `cellExtent`, ring and label together, since the label grows the stack
    /// in the same direction it runs. On a horizontal edge the label sits
    /// under the ring, across the stack rather than along it, so this stays
    /// the ring alone; `bodyDepth(for:metrics:)` is what grows instead.
    static func cellAlong(for edge: NotchEdge, metrics: Metrics = .default) -> CGFloat {
        cellExtent(metrics)
    }

    /// Ring centre to ring centre.
    static func cellPitch(for edge: NotchEdge, metrics: Metrics = .default) -> CGFloat {
        cellAlong(for: edge, metrics: metrics) + cellSpacing(metrics)
    }

    /// Padding at the start and the end of the stack.
    ///
    /// Down a side edge these are two distinct numbers, and they stay
    /// different: `padTop` measures the body's top to the first ring,
    /// `padBottom` measures the last ring to the body's foot. That asymmetry
    /// is deliberate and is kept as is.
    ///
    /// Across a horizontal edge both ends are padding the same thing, a cell.
    /// Carrying the difference over there only pushes the stack off centre:
    /// with four rings it reads as a slightly heavy left end, and with one it
    /// is a ring visibly not in the middle of its own notch. So the two become
    /// one number, their mean, which leaves the bar exactly as long as it
    /// would have been.
    static func padStart(for edge: NotchEdge, metrics: Metrics = .default) -> CGFloat {
        padTop(metrics)
    }

    static func padEnd(for edge: NotchEdge, metrics: Metrics = .default) -> CGFloat {
        padBottom(metrics)
    }

    /// Distance from the start of the whole shape to cell `index`'s ring centre.
    ///
    /// The ring leads its cell on every edge, since the cell is the ring
    /// alone whichever edge the stack is on. Still true with labels on: this
    /// measures to the *ring's* centre, not the cell's, and a label under it
    /// does not move that point.
    static func ringCenter(index: Int, edge: NotchEdge = .right,
                           flare: CGFloat = curlRadius, metrics: Metrics = .default) -> CGFloat {
        flare + padStart(for: edge, metrics: metrics) + ringDiameter(metrics) / 2
            + CGFloat(index) * cellPitch(for: edge, metrics: metrics)
    }

    /// Height of the notch body for a given number of cells.
    static func bodyLength(cellCount: Int, edge: NotchEdge = .right, metrics: Metrics = .default) -> CGFloat {
        let start = padStart(for: edge, metrics: metrics), end = padEnd(for: edge, metrics: metrics)
        guard cellCount > 0 else { return start + end }
        return start
            + CGFloat(cellCount) * cellAlong(for: edge, metrics: metrics)
            + CGFloat(cellCount - 1) * cellSpacing(metrics)
            + end
    }

    /// Centre of the settings orb: the same point the notch's bottom flare
    /// curves around, which is what makes the arc parallel that curve.
    static func orbCenterAlong(cellCount: Int, edge: NotchEdge = .right, metrics: Metrics = .default) -> CGFloat {
        shapeLength(cellCount: cellCount, edge: edge, metrics: metrics)
    }

    /// Distance in from the screen edge, matching the flare's centre.
    static var orbInsetFromEdge: CGFloat { curlRadius }

    /// Full shape length, flares included.
    ///
    /// `flare` is what the ends actually take, not what they might: a flush bar
    /// has only the small corner into the frame, and reserving a whole
    /// `curlRadius` there leaves some 56pt of dead black either side of the
    /// cells, which is exactly what made the top bar look too wide.
    static func shapeLength(cellCount: Int, edge: NotchEdge = .right,
                            flare: CGFloat = curlRadius, metrics: Metrics = .default) -> CGFloat {
        bodyLength(cellCount: cellCount, edge: edge, metrics: metrics) + 2 * flare
    }

    /// Depth the hit region reaches for a `Kind.level` card's slider, past the
    /// text a plain card stops at.
    static let sliderHitDepth = Design.px(64)

    /// The chevron glyph shown in the pad bands.
    static let scrollHintGlyph = Design.px(22)

    /// The slider thumb.
    static let sliderThumb = Design.px(28)

    /// How far the column overscrolls before springing back.
    static let overscroll = Design.px(16)

    /// The tooltip's height for a cell of this kind and state. Worked out here
    /// rather than left to SwiftUI so the hover region can be computed before
    /// the card is ever laid out.
    static func cardHeight(for kind: Kind, state: CellState, metrics: Metrics = .default) -> CGFloat {
        var height = 2 * cardPadding + cardTitleLineHeight(metrics)

        // A level card keeps its slider row whatever its state; a failure on
        // one is a word on the header line, not a sentence. Every other kind
        // budgets two body lines for a failure sentence or a confirm prompt.
        if kind == .level {
            height += headerToBlock + sliderHitDepth
        } else {
            switch state {
            case .failed, .armed: height += headerToBlock + 2 * cardBodyLineHeight(metrics)
            default: break
            }
        }

        return height
    }

    /// The tallest card any kind and state combination can ask for. The
    /// panel is sized once for the whole stack and has to hold whichever
    /// card is worst.
    static func maxCardHeight(_ metrics: Metrics = .default) -> CGFloat {
        max(cardHeight(for: .level, state: .ready, metrics: metrics),
            cardHeight(for: .toggle, state: .failed(""), metrics: metrics))
    }

    /// Room at each end of the stack: enough for the settings orb to hang past
    /// the foot of the shape, and enough for a tooltip anchored to the first or
    /// last cell to still have somewhere to sit.
    ///
    /// Both orientations need half a card past each end, and for the same
    /// reason: the card is centred on the cell it belongs to, so hovering the
    /// first or last cell throws half the card past the stack.
    ///
    /// A side edge was assumed exempt. The card sits *beside* the stack, so
    /// it looked like it needed no room at the ends. It sits beside it
    /// horizontally and is centred on it *vertically*, so half its height still
    /// has to fit. With the tallest card at ~474pt against 71pt of slack, the
    /// first cell's tooltip lost its title off the top of the panel.
    ///
    /// Which dimension crosses the ends is what differs: the card's height
    /// along a vertical edge, its width along a horizontal one. The reach past
    /// that half extent is the shadow pad around it.
    static func slack(for edge: NotchEdge,
                      maxCardHeight: CGFloat = NotchLayout.maxCardHeight()) -> CGFloat {
        max(endSlack, maxCardHeight / 2 + cardShadowPad)
    }

    static let endSlack = Design.px(190)

    /// How far the panel reaches inward from the bezel, past the notch itself,
    /// so the card has somewhere to live. Beside the stack on a side edge,
    /// below or above it on a horizontal one.
    static func tooltipDepth(for edge: NotchEdge,
                             maxCardHeight: CGFloat = NotchLayout.maxCardHeight(),
                             cardWidth: CGFloat = cardMinWidth) -> CGFloat {
        cardWidth + cardGap + cardShadowPad
    }
}
