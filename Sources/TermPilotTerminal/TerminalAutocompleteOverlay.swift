import AppKit
import QuartzCore
@preconcurrency import SwiftTerm

struct TerminalAutocompleteThemePalette {
    let background: NSColor
    let border: NSColor
    let primaryText: NSColor
    let secondaryText: NSColor
    let tertiaryText: NSColor
    let selectedBackground: NSColor
    let trailSelectedBackground: NSColor
    let keyBackground: NSColor
    let keyBorder: NSColor
    let shadow: NSColor

    static func colors(for appearance: NSAppearance) -> Self {
        if isDark(appearance) {
            return Self(
                background: color(0x151920),
                border: color(0x4B5563),
                primaryText: color(0xF0F4F8),
                secondaryText: color(0xB4BEC9),
                tertiaryText: color(0x8E9AA7),
                selectedBackground: color(0x264F78),
                trailSelectedBackground: color(0x1E3A56),
                keyBackground: color(0x0D1117),
                keyBorder: color(0x4B5563),
                shadow: color(0x000000, alpha: 0.36)
            )
        }
        return Self(
            background: color(0xFBFCFE),
            border: color(0xAEB8C4),
            primaryText: color(0x1F2933),
            secondaryText: color(0x4F5B67),
            tertiaryText: color(0x687583),
            selectedBackground: color(0xD8EAFF),
            trailSelectedBackground: color(0xEDF5FF),
            keyBackground: color(0xF2F5F8),
            keyBorder: color(0xB9C3CE),
            shadow: color(0x000000, alpha: 0.18)
        )
    }

    static func sourceColor(
        _ source: TerminalAutocompleteSuggestionSource,
        appearance: NSAppearance
    ) -> NSColor {
        let dark = isDark(appearance)
        return switch source {
        case .history:
            color(dark ? 0xE3B341 : 0x9A6700)
        case .command:
            color(dark ? 0x56D364 : 0x1A7F37)
        case .subcommand:
            color(dark ? 0x79C0FF : 0x0969DA)
        case .option:
            color(dark ? 0xD2A8FF : 0x8250DF)
        case .argument:
            color(dark ? 0xFF7B72 : 0xCF222E)
        case .path:
            color(dark ? 0x56D4DD : 0x0E7490)
        }
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private static func color(
        _ rgb: UInt32,
        alpha: CGFloat = 1
    ) -> NSColor {
        NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: alpha
        )
    }
}

private func updateAutocompleteLayers(
    animated: Bool,
    changes: () -> Void
) {
    CATransaction.begin()
    CATransaction.setAnimationDuration(animated ? 0.14 : 0)
    CATransaction.setAnimationTimingFunction(
        CAMediaTimingFunction(name: .easeInEaseOut)
    )
    CATransaction.setDisableActions(!animated)
    changes()
    CATransaction.commit()
}

@MainActor
final class TerminalAutocompleteOverlayView: NSView {
    weak var terminalView: LocalProcessTerminalView?
    var onSelectSuggestion: ((Int) -> Void)?
    var onDismiss: (() -> Void)?

    private let ghostLabel = NSTextField(labelWithString: "")
    private let popupView = TerminalAutocompletePopupView()
    private var presentation = TerminalAutocompletePresentation.empty
    private var eventMonitor: Any?

    init(terminalView: LocalProcessTerminalView) {
        self.terminalView = terminalView
        super.init(frame: terminalView.bounds)
        autoresizingMask = [.width, .height]

        ghostLabel.isHidden = true
        ghostLabel.isBezeled = false
        ghostLabel.drawsBackground = false
        ghostLabel.isEditable = false
        ghostLabel.isSelectable = false
        ghostLabel.lineBreakMode = .byClipping
        ghostLabel.maximumNumberOfLines = 1

        popupView.isHidden = true
        popupView.onSelect = { [weak self] index in
            self?.onSelectSuggestion?(index)
        }
        popupView.onPreferredSizeChange = { [weak self] in
            self?.updateLayout()
        }

        addSubview(ghostLabel)
        addSubview(popupView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayout()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !popupView.isHidden,
              popupView.frame.contains(point)
        else {
            return nil
        }
        let localPoint = popupView.convert(point, from: self)
        return popupView.hitTest(localPoint)
    }

    func update(_ presentation: TerminalAutocompletePresentation) {
        self.presentation = presentation
        ghostLabel.stringValue = presentation.ghostText
        ghostLabel.isHidden = presentation.ghostText.isEmpty

        popupView.update(
            suggestions: presentation.suggestions,
            selectedIndex: presentation.selectedIndex,
            subdirectoryPanels: presentation.subdirectoryPanels,
            subdirectoryFocusLevel: presentation.subdirectoryFocusLevel
        )
        popupView.isHidden = !presentation.popupVisible
        updateEventMonitor()
        updateLayout()
    }

    func updateLayout() {
        guard let terminalView else {
            return
        }
        frame = terminalView.bounds
        let cursorRect = resolvedCursorRect(in: terminalView)
        let font = terminalView.font

        if !ghostLabel.isHidden {
            ghostLabel.font = font
            ghostLabel.textColor = terminalView.nativeForegroundColor
                .withAlphaComponent(0.4)
            ghostLabel.frame = CGRect(
                x: cursorRect.minX,
                y: cursorRect.minY,
                width: max(0, bounds.width - cursorRect.minX),
                height: max(cursorRect.height, font.boundingRectForFont.height)
            )
        }

        guard !popupView.isHidden else {
            return
        }
        let desiredSize = popupView.desiredSize(
            maximumWidth: max(180, bounds.width - 16),
            maximumHeight: max(96, bounds.height - 16)
        )
        let gap: CGFloat = 6
        let belowY = cursorRect.minY - desiredSize.height - gap
        let aboveY = cursorRect.maxY + gap
        popupView.alignsPanelsToTop = belowY >= 8
        let y = belowY >= 8
            ? belowY
            : min(
                max(8, aboveY),
                max(8, bounds.height - desiredSize.height - 8)
            )
        let x = min(
            max(8, cursorRect.minX),
            max(8, bounds.width - desiredSize.width - 8)
        )
        popupView.frame = CGRect(origin: CGPoint(x: x, y: y), size: desiredSize)
        popupView.needsLayout = true
    }

    func stopMonitoring() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    private func resolvedCursorRect(
        in terminalView: LocalProcessTerminalView
    ) -> CGRect {
        if let caret = terminalView.subviews.first(where: {
            String(describing: type(of: $0)).contains("CaretView")
        }) {
            return caret.frame
        }

        let cursor = terminalView.getTerminal().getCursorLocation()
        let font = terminalView.font
        let glyph = font.glyph(withName: "W")
        let width = max(1, ceil(font.advancement(forGlyph: glyph).width))
        let height = max(
            1,
            ceil(font.ascender - font.descender + font.leading)
        )
        return CGRect(
            x: CGFloat(cursor.x) * width,
            y: bounds.height - CGFloat(cursor.y + 1) * height,
            width: width,
            height: height
        )
    }

    private func updateEventMonitor() {
        if presentation.popupVisible {
            guard eventMonitor == nil else {
                return
            }
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] event in
                guard let self,
                      let window = self.window,
                      event.window === window
                else {
                    return event
                }
                let point = self.convert(event.locationInWindow, from: nil)
                if !self.popupView.frame.contains(point) {
                    self.onDismiss?()
                }
                return event
            }
        } else {
            stopMonitoring()
        }
    }
}

@MainActor
private final class TerminalAutocompletePopupView: NSView {
    var onSelect: ((Int) -> Void)?
    var onPreferredSizeChange: (() -> Void)?
    var alignsPanelsToTop = true

    private let mainPanel = TerminalAutocompleteBoxView()
    private let mainScrollView = NSScrollView()
    private let mainDocumentView = TerminalAutocompleteFlippedView()
    private let detailView = TerminalAutocompleteDetailView()
    private var rows: [TerminalAutocompleteRowView] = []
    private var subdirectoryViews: [TerminalAutocompleteSubdirectoryView] = []
    private var suggestions: [TerminalAutocompleteSuggestion] = []
    private var selectedIndex = -1
    private var subdirectoryPanels: [TerminalAutocompleteSubdirectoryPanel] = []
    private var subdirectoryFocusLevel = -1
    private var hoveredIndex = -1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        mainScrollView.drawsBackground = false
        mainScrollView.borderType = .noBorder
        mainScrollView.hasHorizontalScroller = false
        mainScrollView.autohidesScrollers = true
        mainScrollView.documentView = mainDocumentView
        mainPanel.addSubview(mainScrollView)
        addSubview(mainPanel)
        detailView.isHidden = true
        addSubview(detailView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        suggestions: [TerminalAutocompleteSuggestion],
        selectedIndex: Int,
        subdirectoryPanels: [TerminalAutocompleteSubdirectoryPanel],
        subdirectoryFocusLevel: Int
    ) {
        guard self.suggestions != suggestions
                || self.selectedIndex != selectedIndex
                || self.subdirectoryPanels != subdirectoryPanels
                || self.subdirectoryFocusLevel != subdirectoryFocusLevel
        else {
            return
        }
        if self.suggestions != suggestions {
            hoveredIndex = -1
        }
        self.suggestions = suggestions
        self.selectedIndex = selectedIndex
        self.subdirectoryPanels = subdirectoryPanels
        self.subdirectoryFocusLevel = subdirectoryFocusLevel

        while rows.count < suggestions.count {
            let row = TerminalAutocompleteRowView()
            row.onSelect = { [weak self] index in
                self?.onSelect?(index)
            }
            row.onHover = { [weak self] index, hovering in
                guard let self else {
                    return
                }
                self.hoveredIndex = hovering ? index : -1
                self.updateDetailView()
                self.needsLayout = true
                self.onPreferredSizeChange?()
            }
            rows.append(row)
            mainDocumentView.addSubview(row)
        }
        while rows.count > suggestions.count {
            rows.removeLast().removeFromSuperview()
        }
        for (index, suggestion) in suggestions.enumerated() {
            rows[index].update(
                suggestion: suggestion,
                index: index,
                selected: index == selectedIndex
            )
        }

        while subdirectoryViews.count < subdirectoryPanels.count {
            let view = TerminalAutocompleteSubdirectoryView()
            subdirectoryViews.append(view)
            addSubview(view)
        }
        while subdirectoryViews.count > subdirectoryPanels.count {
            subdirectoryViews.removeLast().removeFromSuperview()
        }
        for (index, panel) in subdirectoryPanels.enumerated() {
            subdirectoryViews[index].update(
                panel: panel,
                focused: index == subdirectoryFocusLevel
            )
        }
        updateDetailView()
        needsLayout = true
        layoutSubtreeIfNeeded()
        if rows.indices.contains(selectedIndex) {
            mainDocumentView.scrollToVisible(rows[selectedIndex].frame)
        }
    }

    func desiredSize(
        maximumWidth: CGFloat,
        maximumHeight: CGFloat
    ) -> CGSize {
        let mainWidth = preferredMainWidth
        let panelCount = subdirectoryPanels.count
        let preferredWidth = mainWidth
            + CGFloat(panelCount) * 214
            + (detailView.isHidden ? 0 : 284)
        let mainHeight = listHeight(for: suggestions.count)
        let subdirectoryHeight = subdirectoryPanels
            .map { listHeight(for: $0.entries.count) }
            .max() ?? 0
        let detailHeight = detailView.isHidden
            ? 0
            : detailView.desiredHeight(forWidth: 280)
        return CGSize(
            width: min(maximumWidth, max(240, preferredWidth)),
            height: min(
                maximumHeight,
                max(mainHeight, subdirectoryHeight, detailHeight)
            )
        )
    }

    override func layout() {
        super.layout()
        let gap: CGFloat = 4
        let panelCount = subdirectoryViews.count
        let minimumListWidth = 180
            + CGFloat(panelCount) * 154
        let detailWidth: CGFloat = detailView.isHidden
            ? 0
            : min(
                280,
                max(
                    160,
                    bounds.width - minimumListWidth - gap
                )
            )
        let detailSpacing = detailView.isHidden ? 0 : gap
        let listWidth = max(
            180,
            bounds.width - detailWidth - detailSpacing
        )
        let reservedPanelWidth = panelCount == 0
            ? 0
            : CGFloat(panelCount) * 180
                + CGFloat(panelCount) * gap
        let mainWidth = min(
            preferredMainWidth,
            max(180, listWidth - reservedPanelWidth)
        )
        let remainingWidth = max(
            0,
            listWidth - mainWidth - CGFloat(panelCount) * gap
        )
        let panelWidth = panelCount == 0
            ? 0
            : remainingWidth / CGFloat(panelCount)
        let mainHeight = min(bounds.height, listHeight(for: suggestions.count))

        mainPanel.frame = CGRect(
            x: 0,
            y: panelY(forHeight: mainHeight),
            width: mainWidth,
            height: mainHeight
        )
        mainScrollView.frame = mainPanel.bounds.insetBy(dx: 4, dy: 4)
        mainScrollView.hasVerticalScroller = suggestions.count > 8
        let rowHeight: CGFloat = 30
        mainDocumentView.frame = CGRect(
            x: 0,
            y: 0,
            width: mainScrollView.contentSize.width,
            height: CGFloat(suggestions.count) * rowHeight
        )
        for (index, row) in rows.enumerated() {
            row.frame = CGRect(
                x: 0,
                y: CGFloat(index) * rowHeight,
                width: mainDocumentView.bounds.width,
                height: rowHeight
            )
        }

        var x = mainWidth + gap
        for (index, view) in subdirectoryViews.enumerated() {
            let panelHeight = min(
                bounds.height,
                listHeight(
                    for: subdirectoryPanels[index].entries.count
                )
            )
            view.frame = CGRect(
                x: x,
                y: panelY(forHeight: panelHeight),
                width: panelWidth,
                height: panelHeight
            )
            x += panelWidth + gap
        }
        if !detailView.isHidden {
            let detailHeight = min(
                bounds.height,
                detailView.desiredHeight(forWidth: detailWidth)
            )
            detailView.frame = CGRect(
                x: x,
                y: panelY(forHeight: detailHeight),
                width: detailWidth,
                height: detailHeight
            )
        }
    }

    private var preferredMainWidth: CGFloat {
        let commandWidth = suggestions.map {
            ($0.displayText as NSString).size(
                withAttributes: [.font: NSFont.systemFont(ofSize: 12)]
            ).width
        }.max() ?? 0
        let detailWidth = suggestions.map {
            (($0.detail ?? "") as NSString).size(
                withAttributes: [.font: NSFont.systemFont(ofSize: 10)]
            ).width
        }.max() ?? 0
        return max(
            240,
            min(440, commandWidth + min(detailWidth, 150) + 104)
        )
    }

    private func listHeight(for itemCount: Int) -> CGFloat {
        CGFloat(max(1, min(8, itemCount))) * 30 + 8
    }

    private func panelY(forHeight height: CGFloat) -> CGFloat {
        alignsPanelsToTop ? bounds.height - height : 0
    }

    private func updateDetailView() {
        let index = hoveredIndex >= 0 ? hoveredIndex : selectedIndex
        guard suggestions.indices.contains(index) else {
            detailView.isHidden = true
            return
        }
        let suggestion = suggestions[index]
        guard suggestion.source != .path,
              suggestion.detail?.isEmpty == false
        else {
            detailView.isHidden = true
            return
        }
        detailView.update(suggestion)
        detailView.isHidden = false
    }
}

@MainActor
private class TerminalAutocompleteBoxView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.masksToBounds = false
        applyTheme(animated: false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme(animated: window != nil)
    }

    private func applyTheme(animated: Bool) {
        let colors = TerminalAutocompleteThemePalette.colors(
            for: effectiveAppearance
        )
        updateAutocompleteLayers(animated: animated) {
            layer?.backgroundColor = colors.background.cgColor
            layer?.borderColor = colors.border.cgColor
            layer?.shadowColor = colors.shadow.cgColor
        }
    }
}

@MainActor
private final class TerminalAutocompleteDetailView:
    TerminalAutocompleteBoxView
{
    private let titleLabel = NSTextField(labelWithString: "")
    private let sourceLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private var source = TerminalAutocompleteSuggestionSource.command

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        sourceLabel.font = .systemFont(ofSize: 10, weight: .medium)
        sourceLabel.alignment = .center
        sourceLabel.wantsLayer = true
        sourceLabel.layer?.cornerRadius = 3
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 12)
        textView.textContainerInset = CGSize(width: 0, height: 2)
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        [titleLabel, sourceLabel, scrollView].forEach(addSubview)
        applyTheme(animated: false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(_ suggestion: TerminalAutocompleteSuggestion) {
        source = suggestion.source
        titleLabel.stringValue = suggestion.displayText
        sourceLabel.stringValue = suggestion.source.rawValue.capitalized
        textView.string = suggestion.detail ?? ""
        applyTheme(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme(animated: window != nil)
    }

    func desiredHeight(forWidth width: CGFloat) -> CGFloat {
        let textWidth = max(40, width - 20)
        let textHeight = (textView.string as NSString).boundingRect(
            with: CGSize(
                width: textWidth,
                height: .greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: textView.font as Any]
        ).height
        return max(96, ceil(textHeight) + 54)
    }

    override func layout() {
        super.layout()
        let badgeWidth = min(
            82,
            max(
                50,
                (sourceLabel.stringValue as NSString).size(
                    withAttributes: [.font: sourceLabel.font as Any]
                ).width + 12
            )
        )
        sourceLabel.frame = CGRect(
            x: bounds.width - badgeWidth - 10,
            y: bounds.height - 28,
            width: badgeWidth,
            height: 18
        )
        titleLabel.frame = CGRect(
            x: 10,
            y: bounds.height - 28,
            width: max(40, sourceLabel.frame.minX - 16),
            height: 18
        )
        scrollView.frame = CGRect(
            x: 10,
            y: 8,
            width: max(40, bounds.width - 20),
            height: max(20, bounds.height - 42)
        )
        let contentWidth = scrollView.contentSize.width
        let contentHeight = max(
            scrollView.contentSize.height,
            desiredHeight(forWidth: bounds.width) - 50
        )
        textView.frame = CGRect(
            x: 0,
            y: 0,
            width: contentWidth,
            height: contentHeight
        )
    }

    private func applyTheme(animated: Bool) {
        let colors = TerminalAutocompleteThemePalette.colors(
            for: effectiveAppearance
        )
        let badgeColor = TerminalAutocompleteThemePalette.sourceColor(
            source,
            appearance: effectiveAppearance
        )
        titleLabel.textColor = colors.primaryText
        textView.textColor = colors.secondaryText
        sourceLabel.textColor = badgeColor
        updateAutocompleteLayers(animated: animated) {
            sourceLabel.layer?.backgroundColor = badgeColor
                .withAlphaComponent(0.14)
                .cgColor
        }
    }
}

@MainActor
private final class TerminalAutocompleteFlippedView: NSView {
    override var isFlipped: Bool {
        true
    }
}

@MainActor
private final class TerminalAutocompleteSubdirectoryView:
    TerminalAutocompleteBoxView
{
    private let scrollView = NSScrollView()
    private let documentView = TerminalAutocompleteFlippedView()
    private var rows: [TerminalAutocompleteSubdirectoryRowView] = []
    private var panel = TerminalAutocompleteSubdirectoryPanel(
        entries: [],
        directory: ""
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = documentView
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        panel: TerminalAutocompleteSubdirectoryPanel,
        focused: Bool
    ) {
        self.panel = panel
        while rows.count < panel.entries.count {
            let row = TerminalAutocompleteSubdirectoryRowView()
            rows.append(row)
            documentView.addSubview(row)
        }
        while rows.count > panel.entries.count {
            rows.removeLast().removeFromSuperview()
        }
        for (index, entry) in panel.entries.enumerated() {
            rows[index].update(
                entry: entry,
                selected: focused && index == panel.selectedIndex,
                trailSelected: !focused && index == panel.selectedIndex
            )
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        if rows.indices.contains(panel.selectedIndex) {
            documentView.scrollToVisible(rows[panel.selectedIndex].frame)
        }
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds.insetBy(dx: 4, dy: 4)
        scrollView.hasVerticalScroller = panel.entries.count > 8
        let rowHeight: CGFloat = 30
        documentView.frame = CGRect(
            x: 0,
            y: 0,
            width: scrollView.contentSize.width,
            height: CGFloat(panel.entries.count) * rowHeight
        )
        for (index, row) in rows.enumerated() {
            row.frame = CGRect(
                x: 0,
                y: CGFloat(index) * rowHeight,
                width: documentView.bounds.width,
                height: rowHeight
            )
        }
    }
}

@MainActor
private final class TerminalAutocompleteSubdirectoryRowView: NSView {
    private let iconLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private let arrowLabel = NSTextField(labelWithString: "")
    private var entryKind = TerminalAutocompleteDirectoryEntry.Kind.file
    private var selected = false
    private var trailSelected = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        iconLabel.alignment = .center
        iconLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.lineBreakMode = .byTruncatingTail
        arrowLabel.font = .systemFont(ofSize: 11)
        arrowLabel.alignment = .center
        [iconLabel, nameLabel, arrowLabel].forEach(addSubview)
        applyTheme(animated: false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        entry: TerminalAutocompleteDirectoryEntry,
        selected: Bool,
        trailSelected: Bool
    ) {
        entryKind = entry.kind
        self.selected = selected
        self.trailSelected = trailSelected
        iconLabel.stringValue = switch entry.kind {
        case .directory: "d"
        case .symlink: "l"
        case .file: "f"
        }
        nameLabel.stringValue = entry.name
            + (entry.kind == .directory ? "/" : "")
        arrowLabel.stringValue = entry.kind == .directory ? "›" : ""
        applyTheme(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme(animated: window != nil)
    }

    override func layout() {
        super.layout()
        iconLabel.frame = CGRect(x: 6, y: 6, width: 18, height: 18)
        arrowLabel.frame = CGRect(
            x: bounds.width - 22,
            y: 6,
            width: 16,
            height: 18
        )
        nameLabel.frame = CGRect(
            x: 30,
            y: 6,
            width: max(40, bounds.width - 56),
            height: 18
        )
    }

    private func applyTheme(animated: Bool) {
        let colors = TerminalAutocompleteThemePalette.colors(
            for: effectiveAppearance
        )
        nameLabel.textColor = colors.primaryText
        arrowLabel.textColor = colors.secondaryText
        switch entryKind {
        case .directory:
            iconLabel.textColor =
                TerminalAutocompleteThemePalette.sourceColor(
                    .path,
                    appearance: effectiveAppearance
                )
        case .symlink:
            iconLabel.textColor =
                TerminalAutocompleteThemePalette.sourceColor(
                    .option,
                    appearance: effectiveAppearance
                )
        case .file:
            iconLabel.textColor = colors.secondaryText
        }
        let background = selected
            ? colors.selectedBackground
            : (trailSelected
                ? colors.trailSelectedBackground
                : .clear)
        updateAutocompleteLayers(animated: animated) {
            layer?.backgroundColor = background.cgColor
        }
    }
}

@MainActor
private final class TerminalAutocompleteRowView: NSView {
    var onSelect: ((Int) -> Void)?
    var onHover: ((Int, Bool) -> Void)?

    private let sourceLabel = NSTextField(labelWithString: "")
    private let commandLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let frequencyLabel = NSTextField(labelWithString: "")
    private let keyLabel = NSTextField(labelWithString: "")
    private var index = 0
    private var trackingAreaReference: NSTrackingArea?
    private var source = TerminalAutocompleteSuggestionSource.command
    private var pathKind: TerminalAutocompleteDirectoryEntry.Kind?
    private var selected = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5

        sourceLabel.alignment = .center
        sourceLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        sourceLabel.wantsLayer = true
        sourceLabel.layer?.cornerRadius = 3

        commandLabel.font = .systemFont(ofSize: 12)
        commandLabel.lineBreakMode = .byTruncatingTail

        detailLabel.font = .systemFont(ofSize: 10)
        detailLabel.lineBreakMode = .byTruncatingTail

        frequencyLabel.font = .monospacedDigitSystemFont(
            ofSize: 9,
            weight: .regular
        )
        frequencyLabel.alignment = .right

        keyLabel.font = .systemFont(ofSize: 10, weight: .medium)
        keyLabel.alignment = .center
        keyLabel.wantsLayer = true
        keyLabel.layer?.cornerRadius = 3
        keyLabel.layer?.borderWidth = 1

        [
            sourceLabel,
            commandLabel,
            detailLabel,
            frequencyLabel,
            keyLabel,
        ].forEach(addSubview)
        applyTheme(animated: false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with _: NSEvent) {
        onSelect?(index)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        )
        addTrackingArea(trackingArea)
        trackingAreaReference = trackingArea
    }

    override func mouseEntered(with _: NSEvent) {
        onHover?(index, true)
    }

    override func mouseExited(with _: NSEvent) {
        onHover?(index, false)
    }

    func update(
        suggestion: TerminalAutocompleteSuggestion,
        index: Int,
        selected: Bool
    ) {
        self.index = index
        source = suggestion.source
        pathKind = suggestion.pathKind
        self.selected = selected
        let source = pathSourceAppearance(suggestion)
        sourceLabel.stringValue = source.label
        commandLabel.stringValue = suggestion.displayText
        commandLabel.font = .systemFont(
            ofSize: 12,
            weight: selected ? .medium : .regular
        )
        detailLabel.stringValue = suggestion.detail ?? ""
        frequencyLabel.stringValue = (suggestion.frequency ?? 0) > 1
            ? "x\(suggestion.frequency ?? 0)"
            : ""
        keyLabel.stringValue = selected
            ? (suggestion.isDirectory ? "→  return" : "return")
            : ""
        keyLabel.isHidden = !selected
        applyTheme(animated: false)
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme(animated: window != nil)
    }

    override func layout() {
        super.layout()
        let verticalInset: CGFloat = 6
        sourceLabel.frame = CGRect(
            x: 6,
            y: verticalInset,
            width: 18,
            height: bounds.height - verticalInset * 2
        )
        let keyWidth: CGFloat = keyLabel.isHidden
            ? 0
            : (keyLabel.stringValue.hasPrefix("→") ? 68 : 44)
        keyLabel.frame = CGRect(
            x: bounds.width - keyWidth - 6,
            y: 7,
            width: keyWidth,
            height: 16
        )
        let frequencyWidth: CGFloat = frequencyLabel.stringValue.isEmpty
            ? 0
            : 28
        frequencyLabel.frame = CGRect(
            x: keyLabel.frame.minX - frequencyWidth - 4,
            y: verticalInset,
            width: frequencyWidth,
            height: bounds.height - verticalInset * 2
        )
        let rightEdge = frequencyWidth > 0
            ? frequencyLabel.frame.minX - 6
            : keyLabel.frame.minX - 6
        let available = max(80, rightEdge - 32)
        let detailWidth = detailLabel.stringValue.isEmpty
            ? 0
            : min(150, available * 0.4)
        detailLabel.frame = CGRect(
            x: 32 + available - detailWidth,
            y: verticalInset,
            width: detailWidth,
            height: bounds.height - verticalInset * 2
        )
        commandLabel.frame = CGRect(
            x: 32,
            y: verticalInset,
            width: max(40, available - detailWidth - (detailWidth > 0 ? 8 : 0)),
            height: bounds.height - verticalInset * 2
        )
    }

    private func pathSourceAppearance(
        _ suggestion: TerminalAutocompleteSuggestion
    ) -> (label: String, color: NSColor) {
        guard suggestion.source == .path,
              let kind = suggestion.pathKind
        else {
            return (
                suggestion.source.badge,
                TerminalAutocompleteThemePalette.sourceColor(
                    suggestion.source,
                    appearance: effectiveAppearance
                )
            )
        }
        switch kind {
        case .directory:
            return (
                "d",
                TerminalAutocompleteThemePalette.sourceColor(
                    .path,
                    appearance: effectiveAppearance
                )
            )
        case .symlink:
            return (
                "l",
                TerminalAutocompleteThemePalette.sourceColor(
                    .option,
                    appearance: effectiveAppearance
                )
            )
        case .file:
            return (
                "f",
                TerminalAutocompleteThemePalette.colors(
                    for: effectiveAppearance
                ).secondaryText
            )
        }
    }

    private func applyTheme(animated: Bool) {
        let colors = TerminalAutocompleteThemePalette.colors(
            for: effectiveAppearance
        )
        let badgeColor: NSColor
        if source == .path, pathKind == .file {
            badgeColor = colors.secondaryText
        } else {
            badgeColor = TerminalAutocompleteThemePalette.sourceColor(
                source == .path && pathKind == .symlink ? .option : source,
                appearance: effectiveAppearance
            )
        }
        commandLabel.textColor = colors.primaryText
        detailLabel.textColor = colors.secondaryText
        frequencyLabel.textColor = colors.tertiaryText
        keyLabel.textColor = colors.secondaryText
        sourceLabel.textColor = badgeColor
        updateAutocompleteLayers(animated: animated) {
            layer?.backgroundColor = (
                selected ? colors.selectedBackground : .clear
            ).cgColor
            sourceLabel.layer?.backgroundColor = badgeColor
                .withAlphaComponent(0.14)
                .cgColor
            keyLabel.layer?.backgroundColor = colors.keyBackground.cgColor
            keyLabel.layer?.borderColor = colors.keyBorder.cgColor
        }
    }
}
