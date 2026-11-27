import Cocoa

// Borderless candidate list. 倉頡 draws one dark capsule: the choice a Space or Return would
// type sits in a blue chip, and a list with more than one page has an up/down pair at the end.
// Every other method keeps the original rounded box, the horizontal row, and the ▼ page footer.
// A character is chosen with a number key. The classic box follows the system appearance; its
// geometry scales with the live candidate font size.
final class CandidateWindow {
    // Geometry mapped from the original app. Sizes that must track the candidate glyph are derived
    // from `fontSize` so the live font-size preference keeps the whole box proportional.
    private enum Style {
        static let cornerRadius: CGFloat = 12
        static let borderWidth: CGFloat = 1.5
        static let insetH: CGFloat = 14          // left/right padding inside the box
        static let insetV: CGFloat = 8           // top/bottom padding inside the box
        static let sectionSpacing: CGFloat = 6   // gaps between header / list / footer
        static func numberSize(_ f: CGFloat) -> CGFloat { max(11, (f * 0.6).rounded()) }
        static func chromeSize(_ f: CGFloat) -> CGFloat { max(11, (f * 0.6).rounded()) }
        // One ordinary space between choices, the same width as the space after each number.
        static let itemGap = " "
        static let borderAlpha: CGFloat = 0.25
        static let insets = NSEdgeInsets(top: insetV, left: insetH, bottom: insetV, right: insetH)
    }

    private let panel: NSPanel
    private let content = NSView()
    private let stack = NSStackView()
    private let candLabel = NSTextField(labelWithString: "")
    private let divider = NSBox()
    private let footerRow = NSView()
    private let pageDown = NSTextField(labelWithString: "▼")
    private let pageLabel = NSTextField(labelWithString: "")
    private let cangjieStrip = CangjieStrip()
    // -1 turns back a page, +1 turns forward. Set by the input controller.
    var onTurnPage: ((Int) -> Void)?
    // The rows are runs inside ONE attributed string, so they cannot be exposed by annotating the
    // label; the box publishes a synthetic accessibility element per row instead (plus one for the
    // page indicator). Created once rather than per show so assistive technologies keep seeing the
    // same elements while the user types.
    private let rowElements = (0..<9).map { _ in NSAccessibilityElement() }
    private let pageElement = NSAccessibilityElement()
    // Page last shown, so a page turn — which changes nothing else an assistive technology can
    // observe — can be announced. Cleared on hide so a later list never announces against it.
    private var lastShownPage: Int?
    private var showingCangjieBar = false

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = NSWindow.Level(Int(CGWindowLevelForKey(.popUpMenuWindow)))
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear

        // Rounded, bordered, layer-backed container; colours are set per-show so they follow the
        // current appearance. masksToBounds clips the children to the rounded corners.
        content.wantsLayer = true
        content.layer?.cornerRadius = Style.cornerRadius
        content.layer?.borderWidth = Style.borderWidth
        content.layer?.masksToBounds = true

        candLabel.maximumNumberOfLines = 1
        candLabel.lineBreakMode = .byClipping
        candLabel.cell?.wraps = false
        candLabel.cell?.isScrollable = true
        // Let the box widen to whichever row is widest (candidate list vs footer): the candidate
        // label hugs its text only weakly, so the equal-width constraints below resolve both rows
        // to the common maximum.
        candLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        configureChrome(pageLabel)
        configureChrome(pageDown)
        divider.boxType = .separator
        cangjieStrip.isHidden = true
        cangjieStrip.onTurnPage = { [weak self] delta in self?.onTurnPage?(delta) }

        layoutPageRow()

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Style.sectionSpacing
        stack.edgeInsets = Style.insets
        stack.translatesAutoresizingMaskIntoConstraints = false
        for v in [cangjieStrip, candLabel, divider, footerRow] { stack.addArrangedSubview(v) }

        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            // Full-width rows match the candidate column; equal (not one-directional) so the
            // common width is the max of every row's intrinsic width.
            divider.widthAnchor.constraint(equalTo: candLabel.widthAnchor),
            footerRow.widthAnchor.constraint(equalTo: candLabel.widthAnchor),
        ])
        panel.contentView = content
        configureAccessibility()
    }

    // Static half of the accessibility exposure (roles, labels, what to ignore); the per-show half
    // is in updateAccessibility.
    private func configureAccessibility() {
        // The box is a list of numbered choices. The drawn views are hidden from assistive
        // technologies because neither reads usefully: the candidate label is one attributed blob,
        // and the footer would be spoken as the bare glyph "▼" plus "1/3". The synthetic elements
        // below stand in for both.
        content.setAccessibilityElement(true)
        content.setAccessibilityRole(.list)
        content.setAccessibilityLabel("候選字")
        for v in [candLabel, pageDown, pageLabel, cangjieStrip] { v.setAccessibilityElement(false) }
        for (i, element) in rowElements.enumerated() {
            element.setAccessibilityRole(.staticText)
            element.setAccessibilityLabel("\(i + 1)")   // the digit that selects this candidate
            element.setAccessibilityParent(content)
        }
        pageElement.setAccessibilityRole(.staticText)
        pageElement.setAccessibilityLabel("頁數")
        pageElement.setAccessibilityParent(content)
    }

    private func configureChrome(_ field: NSTextField) {
        field.textColor = .secondaryLabelColor
        field.translatesAutoresizingMaskIntoConstraints = false
    }

    // ▼ at the left edge, the page number centred. Used by every method except 倉頡.
    private func layoutPageRow() {
        footerRow.translatesAutoresizingMaskIntoConstraints = false
        for v in [pageDown, pageLabel] {
            footerRow.addSubview(v)
        }
        NSLayoutConstraint.activate([
            pageDown.leadingAnchor.constraint(equalTo: footerRow.leadingAnchor),
            pageDown.centerYAnchor.constraint(equalTo: footerRow.centerYAnchor),
            pageLabel.centerXAnchor.constraint(equalTo: footerRow.centerXAnchor),
            pageLabel.topAnchor.constraint(equalTo: footerRow.topAnchor),
            pageLabel.bottomAnchor.constraint(equalTo: footerRow.bottomAnchor),
        ])
    }

    // `pageCandidates` is the already-sliced set for the current page (≤9), drawn left to right as
    // "1 有 2 冇". `fontSize` is read live from Preferences by the caller so size changes apply
    // without restarting the IME.
    // `hints`, when non-empty, is parallel to `pageCandidates`; a non-nil entry is drawn as a
    // dimmed 倉頡-code hint (反查/拆碼提示) after that choice's glyph. An empty array (the default)
    // renders exactly as before.
    // `selected`, when non-nil, is the choice (0-based, on this page) drawn highlighted: the
    // candidate the Up/Down arrows are on, which Space or Return then picks.
    // `cangjieBar` draws the dark capsule instead of this box. Other methods pass false.
    func show(_ pageCandidates: [String], page: Int, pageCount: Int, fontSize: CGFloat,
              hints: [String?] = [], selected: Int? = nil, showsPageIndicator: Bool = true,
              cangjieBar: Bool = false, near caret: NSRect) {
        showingCangjieBar = cangjieBar
        if cangjieBar {
            showCangjieBar(pageCandidates, page: page, pageCount: pageCount, fontSize: fontSize,
                           hints: hints, selected: selected, near: caret)
            return
        }
        showClassic(pageCandidates, page: page, pageCount: pageCount, fontSize: fontSize,
                    hints: hints, selected: selected, showsPageIndicator: showsPageIndicator,
                    near: caret)
    }

    private func showCangjieBar(_ pageCandidates: [String], page: Int, pageCount: Int,
                                fontSize: CGFloat, hints: [String?], selected: Int?,
                                near caret: NSRect) {
        cangjieStrip.isHidden = false
        candLabel.isHidden = true
        divider.isHidden = true
        footerRow.isHidden = true
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets()
        content.layer?.borderWidth = 0
        // No chip while the code is still being typed. The blue mark is only the choice an
        // arrow has moved onto; Space and Return still take the first candidate.
        cangjieStrip.configure(pageCandidates, hints: hints, highlighted: selected,
                               page: page, pageCount: pageCount, fontSize: fontSize)
        updateChromeColors()
        panel.setContentSize(stack.fittingSize)
        content.layoutSubtreeIfNeeded()
        content.layer?.cornerRadius = max(1, content.bounds.height / 2)
        positionPanel(near: caret)
        panel.orderFront(nil)
        updateAccessibility(pageCandidates, page: page, pageCount: pageCount, hints: hints,
                            showsPageIndicator: pageCount > 1)
    }

    private func showClassic(_ pageCandidates: [String], page: Int, pageCount: Int, fontSize: CGFloat,
                             hints: [String?], selected: Int?, showsPageIndicator: Bool,
                             near caret: NSRect) {
        cangjieStrip.isHidden = true
        candLabel.isHidden = false
        stack.spacing = Style.sectionSpacing
        stack.edgeInsets = Style.insets
        content.layer?.borderWidth = Style.borderWidth
        content.layer?.cornerRadius = Style.cornerRadius

        let glyphFont = NSFont.systemFont(ofSize: fontSize)
        let numFont = NSFont.monospacedDigitSystemFont(ofSize: Style.numberSize(fontSize), weight: .regular)
        let chromeFont = NSFont.systemFont(ofSize: Style.chromeSize(fontSize), weight: .medium)
        let hintFont = NSFont.systemFont(ofSize: Style.chromeSize(fontSize), weight: .regular)
        pageDown.font = chromeFont
        pageLabel.font = chromeFont

        let out = NSMutableAttributedString()
        for (i, cand) in pageCandidates.prefix(9).enumerated() {
            if i > 0 {
                out.append(NSAttributedString(
                    string: Style.itemGap,
                    attributes: [.font: glyphFont]))
            }
            let itemStart = out.length
            out.append(NSAttributedString(
                string: "\(i + 1) ",
                attributes: [.font: numFont, .foregroundColor: NSColor.secondaryLabelColor]))
            out.append(NSAttributedString(
                string: cand,
                attributes: [.font: glyphFont, .foregroundColor: NSColor.labelColor]))
            // Optional dimmed 倉頡-code hint after the glyph (反查/拆碼提示).
            if i < hints.count, let hint = hints[i], !hint.isEmpty {
                out.append(NSAttributedString(
                    string: " \(hint)",
                    attributes: [.font: hintFont, .foregroundColor: NSColor.tertiaryLabelColor]))
            }
            if i == selected {
                out.addAttribute(.backgroundColor,
                                 value: NSColor.controlAccentColor.withAlphaComponent(0.35),
                                 range: NSRange(location: itemStart, length: out.length - itemStart))
            }
        }
        candLabel.attributedStringValue = out
        pageLabel.stringValue = "\(page + 1)/\(pageCount)"
        // 速成, 注音, 拼音, and a 倉頡 聯想 list keep this footer. The 倉頡 candidate list
        // takes the capsule path above and never reaches here.
        divider.isHidden = !showsPageIndicator
        footerRow.isHidden = !showsPageIndicator

        updateChromeColors()
        panel.setContentSize(stack.fittingSize)
        positionPanel(near: caret)
        panel.orderFront(nil)
        updateAccessibility(pageCandidates, page: page, pageCount: pageCount, hints: hints,
                            showsPageIndicator: showsPageIndicator)
    }

    // Mirror what was just drawn into the synthetic elements. Purely additive: nothing here touches
    // the views, so drawing and layout are unaffected.
    private func updateAccessibility(_ pageCandidates: [String], page: Int, pageCount: Int,
                                     hints: [String?], showsPageIndicator: Bool) {
        // Row frames are derived from the label's frame, which is only final once the panel has
        // been resized and the stack has actually laid out.
        content.layoutSubtreeIfNeeded()
        let visible = pageCandidates.prefix(9)
        if showingCangjieBar {
            let frames = cangjieStrip.itemFrames.map { content.convert($0, from: cangjieStrip) }
            for (i, cand) in visible.enumerated() {
                let element = rowElements[i]
                if i < hints.count, let hint = hints[i], !hint.isEmpty {
                    element.setAccessibilityValue("\(cand)，\(hint)")
                } else {
                    element.setAccessibilityValue(cand)
                }
                if i < frames.count {
                    element.setAccessibilityFrameInParentSpace(frames[i])
                }
            }
            pageElement.setAccessibilityValue("第 \(page + 1) 頁，共 \(pageCount) 頁")
            pageElement.setAccessibilityFrameInParentSpace(
                content.convert(cangjieStrip.chevronBounds, from: cangjieStrip))
        } else {
            let listFrame = content.convert(candLabel.bounds, from: candLabel)
            let itemWidth = listFrame.width / CGFloat(max(1, visible.count))
            for (i, cand) in visible.enumerated() {
                let element = rowElements[i]
                if i < hints.count, let hint = hints[i], !hint.isEmpty {
                    element.setAccessibilityValue("\(cand)，\(hint)")
                } else {
                    element.setAccessibilityValue(cand)
                }
                // Choices run left to right. Equal slices ignore the gap between them, which is
                // close enough to put the VoiceOver cursor on the right choice.
                element.setAccessibilityFrameInParentSpace(
                    NSRect(x: listFrame.minX + CGFloat(i) * itemWidth, y: listFrame.minY,
                           width: itemWidth, height: listFrame.height))
            }
            pageElement.setAccessibilityValue("第 \(page + 1) 頁，共 \(pageCount) 頁")
            pageElement.setAccessibilityFrameInParentSpace(
                content.convert(footerRow.bounds, from: footerRow))
        }
        var children: [NSAccessibilityElement] = Array(rowElements.prefix(visible.count))
        if showsPageIndicator { children.append(pageElement) }
        content.setAccessibilityChildren(children)

        // A page turn leaves the window, its position and its element set unchanged, so nothing
        // would be spoken on its own — announce the new position. Only on an actual change: every
        // keystroke re-shows page 1, and announcing that would talk over the typing.
        if showsPageIndicator, let last = lastShownPage, last != page {
            NSAccessibility.post(element: panel, notification: .announcementRequested,
                                 userInfo: [.announcement: "第 \(page + 1) 頁，共 \(pageCount) 頁",
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        lastShownPage = page
    }

    // Layer colours are CGColors and don't auto-adapt to appearance, so resolve them against the
    // current effective appearance each show.
    private func updateChromeColors() {
        content.effectiveAppearance.performAsCurrentDrawingAppearance {
            if showingCangjieBar {
                content.layer?.backgroundColor = CangjieStrip.fill.cgColor
                content.layer?.borderColor = nil
            } else {
                content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                content.layer?.borderColor = NSColor.labelColor
                    .withAlphaComponent(Style.borderAlpha).cgColor
            }
        }
    }

    // Place the window just below the caret; flip above if it would run off the bottom; clamp
    // horizontally so the whole window stays on the caret's screen. The caret rect is in screen
    // coordinates (Cocoa, y-up): minY = caret bottom, maxY = caret top.
    private func positionPanel(near caret: NSRect) {
        let size = panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.intersects(caret) }
            ?? NSScreen.main ?? NSScreen.screens.first
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        // Some clients report an empty (0,0) caret rect: fall back to screen centre.
        let anchor = (caret.width == 0 && caret.height == 0)
            ? NSRect(x: vf.midX, y: vf.midY, width: 1, height: 16) : caret
        let gap: CGFloat = 4
        var x = anchor.minX
        var top = anchor.minY - gap                      // window top just below the caret
        if top - size.height < vf.minY {                 // would run off the bottom -> flip above
            top = anchor.maxY + gap + size.height
        }
        if x + size.width > vf.maxX { x = vf.maxX - size.width }       // clamp right
        if x < vf.minX { x = vf.minX }                                // clamp left
        if top > vf.maxY { top = vf.maxY }                            // clamp top
        if top - size.height < vf.minY { top = vf.minY + size.height } // final bottom clamp
        panel.setFrameTopLeftPoint(NSPoint(x: x, y: top))
    }

    func hide() {
        panel.orderOut(nil)
        lastShownPage = nil   // the next show starts a fresh list, not a page turn
    }
}

// The 倉頡 candidate row: one dark capsule, the current choice in a blue chip, and — when the
// list has another page — a small up/down pair at the trailing end.
private final class CangjieStrip: NSView {
    // The capsule in the reference is dark on a light page, so the bar stays this colour in
    // either appearance.
    static let fill = NSColor(srgbRed: 0.227, green: 0.227, blue: 0.235, alpha: 1)

    var onTurnPage: ((Int) -> Void)?

    private var candidates: [String] = []
    private var hints: [String?] = []
    private var highlighted: Int?
    private var page = 0
    private var pageCount = 1
    private var fontSize: CGFloat = 18

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func configure(_ candidates: [String], hints: [String?], highlighted: Int?,
                   page: Int, pageCount: Int, fontSize: CGFloat) {
        self.candidates = Array(candidates.prefix(9))
        self.hints = hints
        self.highlighted = highlighted
        self.page = page
        self.pageCount = pageCount
        self.fontSize = fontSize
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    var itemFrames: [NSRect] { geometry().items.map(\.bounds) }
    var chevronBounds: NSRect {
        let geo = geometry()
        guard geo.showsChevrons else { return .zero }
        return geo.upRect.union(geo.downRect)
    }

    override var intrinsicContentSize: NSSize { geometry().size }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        let geo = geometry()
        guard geo.showsChevrons else { return }
        addCursorRect(geo.upRect.union(geo.downRect), cursor: .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        let geo = geometry()
        for item in geo.items {
            if let chip = item.chip {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: chip, xRadius: chip.height / 2, yRadius: chip.height / 2).fill()
            }
            for run in item.runs {
                let attrs: [NSAttributedString.Key: Any] = [.font: run.font, .foregroundColor: run.color]
                (run.text as NSString).draw(in: run.rect, withAttributes: attrs)
            }
        }
        guard geo.showsChevrons else { return }
        let point = max(8, (fontSize * 0.42).rounded())
        drawSymbol("chevron.up", in: geo.upRect, pointSize: point,
                   color: page > 0 ? Self.chevron : Self.chevronOff)
        drawSymbol("chevron.down", in: geo.downRect, pointSize: point,
                   color: page + 1 < pageCount ? Self.chevron : Self.chevronOff)
    }

    override func mouseDown(with event: NSEvent) {
        let geo = geometry()
        guard geo.showsChevrons else { return }
        let point = convert(event.locationInWindow, from: nil)
        if geo.upRect.contains(point), page > 0 { onTurnPage?(-1) }
        if geo.downRect.contains(point), page + 1 < pageCount { onTurnPage?(1) }
    }

    private static let chevron = NSColor.white.withAlphaComponent(0.72)
    private static let chevronOff = NSColor.white.withAlphaComponent(0.22)

    private struct Run {
        var text: String
        var font: NSFont
        var color: NSColor
        var rect: NSRect
    }
    private struct Item {
        var bounds: NSRect
        var chip: NSRect?
        var runs: [Run]
    }
    private struct Geometry {
        var size: NSSize
        var items: [Item]
        var upRect: NSRect
        var downRect: NSRect
        var showsChevrons: Bool
    }

    private func geometry() -> Geometry {
        let glyphFont = NSFont.systemFont(ofSize: fontSize)
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: max(11, (fontSize * 0.62).rounded()),
                                                          weight: .regular)
        let hintFont = NSFont.systemFont(ofSize: max(10, (fontSize * 0.55).rounded()))
        let padX: CGFloat = 8
        let padY: CGFloat = 5
        let itemGap = max(10, (fontSize * 0.55).rounded())
        let chipX: CGFloat = max(8, (fontSize * 0.45).rounded())
        let chipY: CGFloat = max(3, (fontSize * 0.16).rounded())
        let numberGap: CGFloat = max(4, (fontSize * 0.22).rounded())
        let onChip = NSColor.white
        let number = NSColor.white.withAlphaComponent(0.45)
        let glyph = NSColor.white
        let hintColor = NSColor.white.withAlphaComponent(0.4)
        let hintOnChip = NSColor.white.withAlphaComponent(0.75)

        var items: [Item] = []
        var x = padX
        var textHeight: CGFloat = fontSize
        for (i, cand) in candidates.enumerated() {
            let chosen = i == highlighted
            let num = "\(i + 1)"
            let numSize = (num as NSString).size(withAttributes: [.font: numberFont])
            let glyphSize = (cand as NSString).size(withAttributes: [.font: glyphFont])
            let hint: String? = {
                guard i < hints.count, let hint = hints[i], !hint.isEmpty else { return nil }
                return hint
            }()
            let hintSize = hint.map { ($0 as NSString).size(withAttributes: [.font: hintFont]) } ?? .zero
            let hintExtra: CGFloat = hint == nil ? 0 : numberGap + hintSize.width
            let innerW = numSize.width + numberGap + glyphSize.width + hintExtra
            let innerH = max(numSize.height, glyphSize.height, hintSize.height)
            textHeight = max(textHeight, innerH)
            let itemW = chosen ? innerW + chipX * 2 : innerW
            let originX = x
            x += itemW + itemGap

            let numColor = chosen ? onChip : number
            let glyphColor = chosen ? onChip : glyph
            items.append(Item(
                bounds: NSRect(x: originX, y: 0, width: itemW, height: 0),
                chip: chosen ? NSRect(x: originX, y: 0, width: itemW, height: 0) : nil,
                runs: [
                    Run(text: num, font: numberFont, color: numColor,
                        rect: NSRect(x: originX + (chosen ? chipX : 0), y: 0,
                                     width: numSize.width, height: numSize.height)),
                    Run(text: cand, font: glyphFont, color: glyphColor,
                        rect: NSRect(x: originX + (chosen ? chipX : 0) + numSize.width + numberGap, y: 0,
                                     width: glyphSize.width, height: glyphSize.height)),
                ] + (hint.map {
                    [Run(text: $0, font: hintFont, color: chosen ? hintOnChip : hintColor,
                         rect: NSRect(x: originX + (chosen ? chipX : 0) + numSize.width + numberGap
                            + glyphSize.width + numberGap,
                                      y: 0, width: hintSize.width, height: hintSize.height))]
                } ?? [])))
        }
        if !items.isEmpty { x -= itemGap }

        let chipH = textHeight + chipY * 2
        let barH = chipH + padY * 2
        let showsChevrons = pageCount > 1
        let chevron = max(8, (fontSize * 0.42).rounded())
        let chevronGap: CGFloat = 1
        if showsChevrons { x += 6 + chevron + 10 }
        x += padX

        var upRect = NSRect.zero
        var downRect = NSRect.zero
        if showsChevrons {
            let colW = chevron + 10
            let colH = chevron * 2 + chevronGap
            let colX = x - padX - colW
            let colY = (barH - colH) / 2
            upRect = NSRect(x: colX, y: colY, width: colW, height: chevron + chevronGap / 2)
            downRect = NSRect(x: colX, y: colY + chevron + chevronGap / 2,
                              width: colW, height: chevron + chevronGap / 2)
        }

        let laidOut = items.map { item -> Item in
            var copy = item
            copy.bounds.origin.y = 0
            copy.bounds.size.height = barH
            if copy.chip != nil {
                copy.chip = NSRect(x: copy.bounds.minX, y: padY,
                                   width: copy.bounds.width, height: chipH)
            }
            copy.runs = copy.runs.map { run in
                var placed = run
                placed.rect.origin.y = (barH - run.rect.height) / 2
                return placed
            }
            return copy
        }
        return Geometry(size: NSSize(width: max(x, 1), height: max(barH, 1)),
                        items: laidOut, upRect: upRect, downRect: downRect,
                        showsChevrons: showsChevrons)
    }

    private func drawSymbol(_ name: String, in rect: NSRect, pointSize: CGFloat, color: NSColor) {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        image.isTemplate = true
        color.set()
        let side = pointSize
        let symbolRect = NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2,
                                width: side, height: side)
        image.draw(in: symbolRect, from: NSRect.zero, operation: .sourceIn, fraction: 1)
    }
}
