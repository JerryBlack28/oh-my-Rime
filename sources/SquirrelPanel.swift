//
//  SquirrelPanel.swift
//  Squirrel
//
//  Created by Leo Liu on 5/10/24.
//

import AppKit
import QuartzCore

final class SquirrelPanel: NSPanel {
  private let view: SquirrelView
  private let back: NSVisualEffectView
  private let appleGrid: AppleCandidateGridView
  var inputController: SquirrelInputController?

  var position: NSRect
  private var screenRect: NSRect = .zero
  private var maxHeight: CGFloat = 0

  private var statusMessage: String = ""
  private var statusTimer: Timer?

  private var preedit: String = ""
  private var selRange: NSRange = .empty
  private var caretPos: Int = 0
  private var candidates: [String] = .init()
  private var comments: [String] = .init()
  private var labels: [String] = .init()
  private var candidateOffset: Int = 0
  private var index: Int = 0
  private var cursorIndex: Int = 0
  private var scrollDirection: CGVector = .zero
  private var scrollTime: Date = .distantPast
  private var page: Int = 0
  private var lastPage: Bool = true
  private var pagingUp: Bool?
  private var visibleCandidateRange: Range<Int> = 0..<0
  private var appleGridStartRow = 0
  private(set) var appleGridMode = false
  private var lastPresentationWasAppleGrid: Bool?

  init(position: NSRect) {
    self.position = position
    self.view = SquirrelView(frame: position)
    self.back = NSVisualEffectView()
    self.appleGrid = AppleCandidateGridView()
    super.init(contentRect: position, styleMask: .nonactivatingPanel, backing: .buffered, defer: true)
    self.level = .init(Int(CGShieldingWindowLevel()))
    self.hasShadow = true
    self.isOpaque = false
    self.backgroundColor = .clear
    back.blendingMode = .behindWindow
    back.material = .hudWindow
    back.state = .active
    back.wantsLayer = true
    back.layer?.mask = view.shape
    back.autoresizingMask = [.width, .height]
    view.autoresizingMask = [.width, .height]
    view.textView.autoresizingMask = [.width, .height]
    appleGrid.autoresizingMask = [.width, .height]
    let contentView = NSView()
    contentView.addSubview(back)
    contentView.addSubview(view)
    contentView.addSubview(view.textView)
    contentView.addSubview(appleGrid)
    appleGrid.isHidden = true
    self.contentView = contentView
  }

  var linear: Bool {
    view.currentTheme.linear
  }
  var vertical: Bool {
    view.currentTheme.vertical
  }
  var inlinePreedit: Bool {
    view.currentTheme.inlinePreedit
  }
  var inlineCandidate: Bool {
    view.currentTheme.inlineCandidate
  }

  // swiftlint:disable:next cyclomatic_complexity
  override func sendEvent(_ event: NSEvent) {
    switch event.type {
    case .leftMouseDown:
      let (index, _, pagingUp) =  view.click(at: mousePosition())
      if let pagingUp {
        self.pagingUp = pagingUp
      } else {
        self.pagingUp = nil
      }
      if let index, let candidateIndex = candidateIndex(forVisibleIndex: index) {
        self.index = candidateIndex
      }
    case .leftMouseUp:
      let (index, preeditIndex, pagingUp) = view.click(at: mousePosition())

      if let pagingUp, pagingUp == self.pagingUp {
        _ = inputController?.page(up: pagingUp)
      } else {
        self.pagingUp = nil
      }
      if let preeditIndex, preeditIndex >= 0 && preeditIndex < preedit.utf16.count {
        if preeditIndex < caretPos {
          _ = inputController?.moveCaret(forward: true)
        } else if preeditIndex > caretPos {
          _ = inputController?.moveCaret(forward: false)
        }
      }
      if let index,
         let candidateIndex = candidateIndex(forVisibleIndex: index),
         candidateIndex == self.index {
        _ = inputController?.selectCandidate(index)
      }
    case .mouseEntered:
      acceptsMouseMovedEvents = true
    case .mouseExited:
      acceptsMouseMovedEvents = false
      if cursorIndex != index {
        update(preedit: preedit, selRange: selRange, caretPos: caretPos, candidates: candidates, comments: comments, labels: labels, candidateOffset: candidateOffset, highlighted: index, page: page, lastPage: lastPage, update: false)
      }
      pagingUp = nil
    case .mouseMoved:
      let (index, _, _) = view.click(at: mousePosition())
      if let index,
         let candidateIndex = candidateIndex(forVisibleIndex: index),
         cursorIndex != candidateIndex {
        update(preedit: preedit, selRange: selRange, caretPos: caretPos, candidates: candidates, comments: comments, labels: labels, candidateOffset: candidateOffset, highlighted: candidateIndex, page: page, lastPage: lastPage, update: false)
      }
    case .scrollWheel:
      if event.phase == .began {
        scrollDirection = .zero
        // Scrollboard span
      } else if event.phase == .ended || (event.phase == .init(rawValue: 0) && event.momentumPhase != .init(rawValue: 0)) {
        if abs(scrollDirection.dx) > abs(scrollDirection.dy) && abs(scrollDirection.dx) > 10 {
          _ = inputController?.page(up: (scrollDirection.dx < 0) == vertical)
        } else if abs(scrollDirection.dx) < abs(scrollDirection.dy) && abs(scrollDirection.dy) > 10 {
          _ = inputController?.page(up: scrollDirection.dy > 0)
        }
        scrollDirection = .zero
        // Mouse scroll wheel
      } else if event.phase == .init(rawValue: 0) && event.momentumPhase == .init(rawValue: 0) {
        if scrollTime.timeIntervalSinceNow < -1 {
          scrollDirection = .zero
        }
        scrollTime = .now
        if (scrollDirection.dy >= 0 && event.scrollingDeltaY > 0) || (scrollDirection.dy <= 0 && event.scrollingDeltaY < 0) {
          scrollDirection.dy += event.scrollingDeltaY
        } else {
          scrollDirection = .zero
        }
        if abs(scrollDirection.dy) > 10 {
          _ = inputController?.page(up: scrollDirection.dy > 0)
          scrollDirection = .zero
        }
      } else {
        scrollDirection.dx += event.scrollingDeltaX
        scrollDirection.dy += event.scrollingDeltaY
      }
    default:
      break
    }
    super.sendEvent(event)
  }

  func hide() {
    statusTimer?.invalidate()
    statusTimer = nil
    orderOut(nil)
    maxHeight = 0
    appleGridMode = false
    appleGrid.isHidden = true
    appleGrid.alphaValue = 1
    view.alphaValue = 1
    view.textView.alphaValue = 1
    lastPresentationWasAppleGrid = nil
  }

  func activateAppleGrid() -> Bool {
    guard !candidates.isEmpty else { return false }
    appleGridMode = true
    appleGridStartRow = 0
    updateAppleGrid()
    return true
  }

  func appleGridTarget(up: Bool) -> Int? {
    guard appleGridMode else { return nil }
    guard let target = appleGrid.target(up: up) else { return nil }
    appleGridStartRow = target.visibleStartRow
    return target.candidateIndex
  }

  func deactivateAppleGrid() {
    guard appleGridMode else { return }
    appleGridMode = false
    appleGrid.isHidden = true
    update(preedit: preedit, selRange: selRange, caretPos: caretPos, candidates: candidates, comments: comments,
           labels: labels, candidateOffset: candidateOffset, highlighted: index, page: page, lastPage: lastPage, update: false)
  }

  // Main function to add attributes to text output from librime
  // swiftlint:disable:next cyclomatic_complexity function_parameter_count
  func update(preedit: String, selRange: NSRange, caretPos: Int, candidates: [String], comments: [String], labels: [String], candidateOffset: Int, highlighted index: Int, page: Int, lastPage: Bool, update: Bool) {
    if update {
      self.preedit = preedit
      self.selRange = selRange
      self.caretPos = caretPos
      self.candidates = candidates
      self.comments = comments
      self.labels = labels
      self.candidateOffset = candidateOffset
      self.index = index
      self.page = page
      self.lastPage = lastPage
    }
    cursorIndex = index

    if appleGridMode {
      updateAppleGrid()
      return
    }

    let pageRanges = candidatePageRanges(candidates: candidates, comments: comments, labels: labels)
    let selectedRange = pageRanges.first(where: { $0.contains(index) }) ?? pageRanges.first ?? 0..<0
    visibleCandidateRange = selectedRange
    let displayedCandidates = Array(candidates[selectedRange])
    let displayedComments = Array(comments[selectedRange])
    let displayedLabels = Array(labels.prefix(displayedCandidates.count))
    let displayedIndex = selectedRange.contains(index) ? index - selectedRange.lowerBound : 0

    if !candidates.isEmpty || !preedit.isEmpty {
      statusMessage = ""
      statusTimer?.invalidate()
      statusTimer = nil
    } else {
      if !statusMessage.isEmpty {
        show(status: statusMessage)
        statusMessage = ""
      } else if statusTimer == nil {
        hide()
      }
      return
    }

    let theme = view.currentTheme
    currentScreen()

    let text = NSMutableAttributedString()
    let preeditRange: NSRange
    let highlightedPreeditRange: NSRange

    // preedit
    if !preedit.isEmpty {
      preeditRange = NSRange(location: 0, length: preedit.utf16.count)
      highlightedPreeditRange = selRange

      let line = NSMutableAttributedString(string: preedit)
      line.addAttributes(theme.preeditAttrs, range: preeditRange)
      line.addAttributes(theme.preeditHighlightedAttrs, range: selRange)
      text.append(line)

      text.addAttribute(.paragraphStyle, value: theme.preeditParagraphStyle, range: NSRange(location: 0, length: text.length))
      if !candidates.isEmpty {
        text.append(NSAttributedString(string: "\n", attributes: theme.preeditAttrs))
      }
    } else {
      preeditRange = .empty
      highlightedPreeditRange = .empty
    }

    // candidates
    var candidateRanges = [NSRange]()
    for i in 0..<displayedCandidates.count {
      let attrs = i == displayedIndex ? theme.highlightedAttrs : theme.attrs
      let labelAttrs = i == displayedIndex ? theme.labelHighlightedAttrs : theme.labelAttrs
      let commentAttrs = i == displayedIndex ? theme.commentHighlightedAttrs : theme.commentAttrs

      let label = if theme.candidateFormat.contains(/\[label\]/) {
        if displayedLabels.count > 1 && i < displayedLabels.count {
          displayedLabels[i]
        } else if displayedLabels.count == 1 && i < displayedLabels.first!.count {
          // custom: A. B. C...
          String(displayedLabels.first![displayedLabels.first!.index(displayedLabels.first!.startIndex, offsetBy: i)])
        } else {
          // default: 1. 2. 3...
          "\(i+1)"
        }
      } else {
        ""
      }

      let candidate = displayedCandidates[i].precomposedStringWithCanonicalMapping
      let comment = displayedComments[i].precomposedStringWithCanonicalMapping

      let line = NSMutableAttributedString(string: theme.candidateFormat, attributes: labelAttrs)
      for range in line.string.ranges(of: /\[candidate\]/) {
        let convertedRange = convert(range: range, in: line.string)
        line.addAttributes(attrs, range: convertedRange)
        if candidate.count <= 5 {
          line.addAttribute(.noBreak, value: true, range: NSRange(location: convertedRange.location+1, length: convertedRange.length-1))
        }
      }
      for range in line.string.ranges(of: /\[comment\]/) {
        line.addAttributes(commentAttrs, range: convert(range: range, in: line.string))
      }
      line.mutableString.replaceOccurrences(of: "[label]", with: label, range: NSRange(location: 0, length: line.length))
      let labeledLine = line.copy() as! NSAttributedString
      line.mutableString.replaceOccurrences(of: "[candidate]", with: candidate, range: NSRange(location: 0, length: line.length))
      line.mutableString.replaceOccurrences(of: "[comment]", with: comment, range: NSRange(location: 0, length: line.length))

      if line.length <= 10 {
        line.addAttribute(.noBreak, value: true, range: NSRange(location: 1, length: line.length-1))
      }

      let lineSeparator = NSAttributedString(string: linear ? "  " : "\n", attributes: attrs)
      if i > 0 {
        text.append(lineSeparator)
      }
      let str = lineSeparator.mutableCopy() as! NSMutableAttributedString
      if vertical {
        str.addAttribute(.verticalGlyphForm, value: 1, range: NSRange(location: 0, length: str.length))
      }
      view.separatorWidth = str.boundingRect(with: .zero).width

      let paragraphStyleCandidate = (i == 0 ? theme.firstParagraphStyle : theme.paragraphStyle).mutableCopy() as! NSMutableParagraphStyle
      if linear {
        paragraphStyleCandidate.paragraphSpacingBefore -= theme.linespace
        paragraphStyleCandidate.lineSpacing = theme.linespace
      }
      if !linear, let labelEnd = labeledLine.string.firstMatch(of: /\[(candidate|comment)\]/)?.range.lowerBound {
        let labelString = labeledLine.attributedSubstring(from: NSRange(location: 0, length: labelEnd.utf16Offset(in: labeledLine.string)))
        let labelWidth = labelString.boundingRect(with: .zero, options: [.usesLineFragmentOrigin]).width
        paragraphStyleCandidate.headIndent = labelWidth
      }
      line.addAttribute(.paragraphStyle, value: paragraphStyleCandidate, range: NSRange(location: 0, length: line.length))

      candidateRanges.append(NSRange(location: text.length, length: line.length))
      text.append(line)
    }

    // text done!
    view.textView.textContentStorage?.attributedString = text
    view.textView.setLayoutOrientation(vertical ? .vertical : .horizontal)
    view.drawView(
      candidateRanges: candidateRanges,
      hilightedIndex: displayedIndex,
      preeditRange: preeditRange,
      highlightedPreeditRange: highlightedPreeditRange,
      canPageUp: page > 0 || selectedRange.lowerBound > 0,
      canPageDown: !lastPage || selectedRange.upperBound < candidates.count
    )
    show()
  }

  var visibleCandidateCount: Int {
    visibleCandidateRange.count
  }

  func candidateIndex(forVisibleIndex index: Int) -> Int? {
    guard index >= 0 && index < visibleCandidateRange.count else { return nil }
    return visibleCandidateRange.lowerBound + index
  }

  func absoluteCandidateIndex(forVisibleIndex index: Int) -> Int? {
    candidateIndex(forVisibleIndex: index).map { candidateOffset + $0 }
  }

  func absoluteCandidateIndex(forLocalIndex index: Int) -> Int {
    candidateOffset + index
  }

  func nextCandidateAfterVisibleEnd() -> Int? {
    guard !appleGridMode,
          !visibleCandidateRange.isEmpty,
          index == visibleCandidateRange.upperBound - 1,
          index + 1 < candidates.count else {
      return nil
    }
    return index + 1
  }

  func prepareAppleGridForKeyboardNavigation() {
    appleGridMode = true
    appleGridStartRow = 0
  }

  func localPageTarget(up: Bool) -> Int? {
    let ranges = candidatePageRanges(candidates: candidates, comments: comments, labels: labels)
    guard let current = ranges.firstIndex(of: visibleCandidateRange) else { return nil }
    let target = up ? current - 1 : current + 1
    guard target >= 0 && target < ranges.count else { return nil }
    return ranges[target].lowerBound
  }

  var isAtFirstVisualPage: Bool {
    visibleCandidateRange.lowerBound == 0
  }

  var hasPreviousBackingPage: Bool {
    page > 0
  }

  func lastVisualPageTarget() -> Int? {
    candidatePageRanges(candidates: candidates, comments: comments, labels: labels).last?.lowerBound
  }

  func updateStatus(long longMessage: String, short shortMessage: String) {
    let theme = view.currentTheme
    switch theme.statusMessageType {
    case .mix:
      statusMessage = shortMessage.isEmpty ? longMessage : shortMessage
    case .long:
      statusMessage = longMessage
    case .short:
      if !shortMessage.isEmpty {
        statusMessage = shortMessage
      } else if let initial = longMessage.first {
        statusMessage = String(initial)
      } else {
        statusMessage = ""
      }
    }
  }

  func load(config: SquirrelConfig, forDarkMode isDark: Bool) {
    if isDark {
      view.darkTheme = SquirrelTheme()
      view.darkTheme.load(config: config, dark: true)
    } else {
      view.lightTheme = SquirrelTheme()
      view.lightTheme.load(config: config, dark: isDark)
    }
  }
}

private extension SquirrelPanel {
  func updateAppleGrid() {
    guard !candidates.isEmpty else {
      appleGridMode = false
      appleGrid.isHidden = true
      return
    }

    appleGrid.update(
      candidates: candidates,
      candidateOffset: candidateOffset,
      highlightedIndex: index,
      visibleStartRow: appleGridStartRow
    )
    appleGridStartRow = appleGrid.visibleStartRow
    visibleCandidateRange = appleGrid.activeCandidateRange
    currentScreen()
    show()
  }

  func mousePosition() -> NSPoint {
    var point = NSEvent.mouseLocation
    point = self.convertPoint(fromScreen: point)
    return view.convert(point, from: nil)
  }

  func currentScreen() {
    if let screen = NSScreen.main {
      screenRect = screen.frame
    }
    for screen in NSScreen.screens where screen.frame.contains(position.origin) {
      screenRect = screen.frame
      break
    }
  }

  func maxTextWidth() -> CGFloat {
    let theme = view.currentTheme
    let font: NSFont = theme.font
    let fontScale = font.pointSize / 12
    let textWidthRatio = min(1, 1 / (vertical ? 4 : 3) + fontScale / 12)
    let maxWidth = if vertical {
      screenRect.height * textWidthRatio - theme.edgeInset.height * 2
    } else {
      screenRect.width * textWidthRatio - theme.edgeInset.width * 2
    }
    return maxWidth
  }

  func candidatePageRanges(candidates: [String], comments: [String], labels: [String]) -> [Range<Int>] {
    guard !candidates.isEmpty else { return [] }
    let theme = view.currentTheme
    guard theme.linear && theme.candidateWindowWidth > 0 else {
      return [0..<candidates.count]
    }

    let availableWidth = max(
      1,
      theme.candidateWindowWidth - theme.edgeInset.width * 2 - theme.pagingOffset
    )
    let separatorWidth = NSAttributedString(string: "  ", attributes: theme.attrs)
      .boundingRect(with: NSSize(width: 10_000, height: 100), options: [.usesLineFragmentOrigin, .usesFontLeading])
      .width

    func label(at visibleIndex: Int) -> String {
      guard theme.candidateFormat.contains(/\[label\]/) else { return "" }
      if labels.count > 1 && visibleIndex < labels.count {
        return labels[visibleIndex]
      }
      if labels.count == 1 && visibleIndex < labels[0].count {
        return String(labels[0][labels[0].index(labels[0].startIndex, offsetBy: visibleIndex)])
      }
      return "\(visibleIndex + 1)"
    }

    func width(at index: Int, visibleIndex: Int) -> CGFloat {
      let candidate = candidates[index].precomposedStringWithCanonicalMapping
      let comment = comments[index].precomposedStringWithCanonicalMapping
      let line = NSMutableAttributedString(string: theme.candidateFormat, attributes: theme.labelAttrs)
      for range in line.string.ranges(of: /\[candidate\]/) {
        line.addAttributes(theme.attrs, range: convert(range: range, in: line.string))
      }
      for range in line.string.ranges(of: /\[comment\]/) {
        line.addAttributes(theme.commentAttrs, range: convert(range: range, in: line.string))
      }
      line.mutableString.replaceOccurrences(of: "[label]", with: label(at: visibleIndex), range: NSRange(location: 0, length: line.length))
      line.mutableString.replaceOccurrences(of: "[candidate]", with: candidate, range: NSRange(location: 0, length: line.length))
      line.mutableString.replaceOccurrences(of: "[comment]", with: comment, range: NSRange(location: 0, length: line.length))
      return ceil(
        line.boundingRect(
          with: NSSize(width: 10_000, height: 100),
          options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).width
      )
    }

    var ranges = [Range<Int>]()
    var start = 0
    var lineWidth: CGFloat = 0
    for index in candidates.indices {
      let candidateWidth = width(at: index, visibleIndex: index - start)
      let requiredWidth = candidateWidth + (index == start ? 0 : separatorWidth)
      if index > start && lineWidth + requiredWidth > availableWidth {
        ranges.append(start..<index)
        start = index
        lineWidth = candidateWidth
      } else {
        lineWidth += requiredWidth
      }
    }
    ranges.append(start..<candidates.count)
    return ranges
  }

  // Get the window size, the windows will be the dirtyRect in
  // SquirrelView.drawRect
  // swiftlint:disable:next cyclomatic_complexity
  func show() {
    currentScreen()
    if appleGridMode {
      showAppleGrid()
      return
    }

    appleGrid.isHidden = true
    view.isHidden = false
    view.textView.isHidden = false
    let theme = view.currentTheme
    if theme.native || view.darkTheme.available {
      self.appearance = NSApp.effectiveAppearance
    } else {
      // user configured only a light theme, set window appearance to light.
      self.appearance = NSAppearance(named: .aqua)
    }

    // Break line if the text is too long, based on screen size.
    let textWidth = maxTextWidth()
    let maxTextHeight = vertical ? screenRect.width - theme.edgeInset.width * 2 : screenRect.height - theme.edgeInset.height * 2
    let configuredTextWidth = if !vertical && theme.candidateWindowWidth > 0 {
      max(1, theme.candidateWindowWidth - theme.edgeInset.width * 2 - theme.pagingOffset)
    } else {
      textWidth
    }
    view.textContainer.size = NSSize(width: min(textWidth, configuredTextWidth), height: maxTextHeight)

    var panelRect = NSRect.zero
    // in vertical mode, the width and height are interchanged
    var contentRect = view.contentRect
    if theme.memorizeSize && (vertical && position.midY / screenRect.height < 0.5) ||
        (vertical && position.minX + max(contentRect.width, maxHeight) + theme.edgeInset.width * 2 > screenRect.maxX) {
      if contentRect.width >= maxHeight {
        maxHeight = contentRect.width
      } else {
        contentRect.size.width = maxHeight
        view.textContainer.size = NSSize(width: maxHeight, height: maxTextHeight)
      }
    }

    if vertical {
      panelRect.size = NSSize(width: min(0.95 * screenRect.width, contentRect.height + theme.edgeInset.height * 2),
                              height: min(0.95 * screenRect.height, contentRect.width + theme.edgeInset.width * 2) + theme.pagingOffset)

      // To avoid jumping up and down while typing, use the lower screen when
      // typing on upper, and vice versa
      if position.midY / screenRect.height >= 0.5 {
        panelRect.origin.y = position.minY - SquirrelTheme.offsetHeight - panelRect.height + theme.pagingOffset
      } else {
        panelRect.origin.y = position.maxY + SquirrelTheme.offsetHeight
      }
      // Make the first candidate fixed at the left of cursor
      panelRect.origin.x = position.minX - panelRect.width - SquirrelTheme.offsetHeight
      if view.preeditRange.length > 0, let preeditTextRange = view.convert(range: view.preeditRange) {
        let preeditRect = view.contentRect(range: preeditTextRange)
        panelRect.origin.x += preeditRect.height + theme.edgeInset.width
      }
    } else {
      let naturalWidth = contentRect.width + theme.edgeInset.width * 2 + theme.pagingOffset
      let preferredWidth = theme.candidateWindowWidth > 0 ? theme.candidateWindowWidth : naturalWidth
      panelRect.size = NSSize(width: min(0.95 * screenRect.width, preferredWidth),
                              height: min(0.95 * screenRect.height, contentRect.height + theme.edgeInset.height * 2))
      panelRect.origin = NSPoint(
        x: position.minX - 12,
        y: position.minY - SquirrelTheme.offsetHeight - panelRect.height
      )
    }
    if panelRect.maxX > screenRect.maxX {
      panelRect.origin.x = screenRect.maxX - panelRect.width
    }
    if panelRect.minX < screenRect.minX {
      panelRect.origin.x = screenRect.minX
    }
    if panelRect.minY < screenRect.minY {
      if vertical {
        panelRect.origin.y = screenRect.minY
      } else {
        panelRect.origin.y = position.maxY + SquirrelTheme.offsetHeight
      }
    }
    if panelRect.maxY > screenRect.maxY {
      panelRect.origin.y = screenRect.maxY - panelRect.height
    }
    if panelRect.minY < screenRect.minY {
      panelRect.origin.y = screenRect.minY
    }
    setPanelFrame(panelRect, appleGrid: false)

    // rotate the view, the core in vertical mode!
    if vertical {
      contentView!.boundsRotation = -90
      contentView!.setBoundsOrigin(NSPoint(x: 0, y: panelRect.width))
    } else {
      contentView!.boundsRotation = 0
      contentView!.setBoundsOrigin(.zero)
    }
    view.textView.boundsRotation = 0
    view.textView.setBoundsOrigin(.zero)

    view.frame = contentView!.bounds
    view.textView.frame = contentView!.bounds
    view.textView.frame.size.width -= theme.pagingOffset
    view.textView.textContainerInset = theme.edgeInset

    if theme.translucency {
      back.frame = contentView!.bounds
      back.frame.size.width += theme.pagingOffset
      back.appearance = NSApp.effectiveAppearance
      back.isHidden = false
    } else {
      back.isHidden = true
    }
    alphaValue = theme.alpha
    invalidateShadow()
    orderFront(nil)
    // voila!
  }

  func showAppleGrid() {
    let preferredSize = AppleCandidateGridView.preferredSize
    let panelSize = NSSize(
      width: min(preferredSize.width, screenRect.width * 0.95),
      height: min(preferredSize.height, screenRect.height * 0.95)
    )
    var panelRect = NSRect(
      x: position.minX - 12,
      y: position.minY - SquirrelTheme.offsetHeight - panelSize.height,
      width: panelSize.width,
      height: panelSize.height
    )
    if panelRect.maxX > screenRect.maxX {
      panelRect.origin.x = screenRect.maxX - panelRect.width
    }
    if panelRect.minX < screenRect.minX {
      panelRect.origin.x = screenRect.minX
    }
    if panelRect.minY < screenRect.minY {
      panelRect.origin.y = position.maxY + SquirrelTheme.offsetHeight
    }
    if panelRect.maxY > screenRect.maxY {
      panelRect.origin.y = screenRect.maxY - panelRect.height
    }

    setPanelFrame(panelRect, appleGrid: true)
    contentView!.boundsRotation = 0
    contentView!.setBoundsOrigin(.zero)
    view.isHidden = true
    view.textView.isHidden = true
    back.isHidden = true
    appleGrid.frame = contentView!.bounds
    appleGrid.isHidden = false
    appleGrid.needsDisplay = true
    alphaValue = 1
    invalidateShadow()
    orderFront(nil)
  }

  func setPanelFrame(_ frame: NSRect, appleGrid: Bool) {
    let isTransition = isVisible && lastPresentationWasAppleGrid != appleGrid
    if isTransition {
      let destinationViews: [NSView] = appleGrid ? [self.appleGrid] : [view, view.textView]
      destinationViews.forEach { $0.alphaValue = 0 }
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.16
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        context.allowsImplicitAnimation = true
        self.animator().setFrame(frame, display: true)
        destinationViews.forEach { $0.animator().alphaValue = 1 }
      }
    } else {
      setFrame(frame, display: true)
      self.appleGrid.alphaValue = 1
      view.alphaValue = 1
      view.textView.alphaValue = 1
    }
    lastPresentationWasAppleGrid = appleGrid
  }

  func show(status message: String) {
    let theme = view.currentTheme
    let text = NSMutableAttributedString(string: message, attributes: theme.attrs)
    text.addAttribute(.paragraphStyle, value: theme.paragraphStyle, range: NSRange(location: 0, length: text.length))
    view.textContentStorage.attributedString = text
    view.textView.setLayoutOrientation(vertical ? .vertical : .horizontal)
    view.drawView(candidateRanges: [NSRange(location: 0, length: text.length)], hilightedIndex: -1,
                  preeditRange: .empty, highlightedPreeditRange: .empty, canPageUp: false, canPageDown: false)
    show()

    statusTimer?.invalidate()
    statusTimer = Timer.scheduledTimer(withTimeInterval: SquirrelTheme.showStatusDuration, repeats: false) { _ in
      self.hide()
    }
  }

  func convert(range: Range<String.Index>, in string: String) -> NSRange {
    let startPos = range.lowerBound.utf16Offset(in: string)
    let endPos = range.upperBound.utf16Offset(in: string)
    return NSRange(location: startPos, length: endPos - startPos)
  }
}

private final class AppleCandidateGridView: NSView {
  static let columnCount = 6
  static let rowCount = 5
  // The reference images are Retina screenshots. AppKit sizes are in points,
  // so these values are half of the captured pixel dimensions.
  static let preferredSize = NSSize(width: 400, height: 151)

  private struct CandidateCell {
    let candidateIndex: Int
    let row: Int
    let column: Int
    let span: Int
    let orderInRow: Int
  }

  private var candidates = [String]()
  private var highlightedIndex = 0
  private var cells = [CandidateCell]()
  private(set) var visibleStartRow = 0
  private(set) var activeCandidateRange: Range<Int> = 0..<0

  override var isFlipped: Bool { true }

  func update(candidates: [String], candidateOffset: Int, highlightedIndex: Int, visibleStartRow: Int) {
    self.candidates = candidates
    self.highlightedIndex = highlightedIndex
    cells = makeCells(candidates: candidates)

    let highlightedRow = cells.first(where: { $0.candidateIndex == highlightedIndex })?.row ?? 0
    let finalRow = cells.last?.row ?? 0
    self.visibleStartRow = min(max(0, visibleStartRow), max(0, finalRow - Self.rowCount + 1))
    if highlightedRow < self.visibleStartRow {
      self.visibleStartRow = max(0, highlightedRow - 1)
    } else if highlightedRow >= self.visibleStartRow + Self.rowCount {
      self.visibleStartRow = highlightedRow - Self.rowCount + 1
    }

    let activeCells = cells.filter { $0.row == highlightedRow }
    if let first = activeCells.first?.candidateIndex, let last = activeCells.last?.candidateIndex {
      activeCandidateRange = first..<(last + 1)
    } else {
      activeCandidateRange = 0..<0
    }
    needsDisplay = true
  }

  func target(up: Bool) -> (candidateIndex: Int, visibleStartRow: Int)? {
    guard let selected = cells.first(where: { $0.candidateIndex == highlightedIndex }) else { return nil }
    let targetRow = selected.row + (up ? -1 : 1)
    let rowCells = cells.filter { $0.row == targetRow }
    guard let lastCell = rowCells.last else { return nil }
    let target = rowCells.first(where: { $0.orderInRow == selected.orderInRow }) ?? lastCell
    var nextStart = visibleStartRow
    if up, targetRow <= visibleStartRow {
      nextStart = max(0, visibleStartRow - 1)
    } else if !up, targetRow >= visibleStartRow + Self.rowCount {
      nextStart += 1
    }
    return (target.candidateIndex, nextStart)
  }

  override func draw(_ dirtyRect: NSRect) {
    let bounds = self.bounds.insetBy(dx: 0.25, dy: 0.25)
    let cornerRadius = min(13, bounds.height / 10)
    let background = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
    NSColor(calibratedWhite: 0.975, alpha: 0.99).setFill()
    background.fill()
    NSColor(calibratedWhite: 0.8, alpha: 0.72).setStroke()
    background.lineWidth = 0.5
    background.stroke()

    let rowHeight = bounds.height / CGFloat(Self.rowCount)
    let columnWidth = bounds.width / CGFloat(Self.columnCount)
    let separator = NSColor(calibratedWhite: 0.89, alpha: 0.85)
    separator.setStroke()
    for row in 1..<Self.rowCount {
      let line = NSBezierPath()
      line.move(to: NSPoint(x: bounds.minX, y: bounds.minY + CGFloat(row) * rowHeight))
      line.line(to: NSPoint(x: bounds.maxX, y: bounds.minY + CGFloat(row) * rowHeight))
      line.lineWidth = 0.5
      line.stroke()
    }

    let textFont = NSFont(name: "PingFangSC-Regular", size: 14) ?? .systemFont(ofSize: 14, weight: .regular)
    let labelFont = NSFont.systemFont(ofSize: 8, weight: .regular)
    let normalAttributes: [NSAttributedString.Key: Any] = [
      .font: textFont,
      .foregroundColor: NSColor(calibratedWhite: 0.13, alpha: 1)
    ]
    let highlightedAttributes: [NSAttributedString.Key: Any] = [
      .font: textFont,
      .foregroundColor: NSColor.white
    ]
    let labelAttributes: [NSAttributedString.Key: Any] = [
      .font: labelFont,
      .foregroundColor: NSColor(calibratedWhite: 0.46, alpha: 1)
    ]
    let highlightedLabelAttributes: [NSAttributedString.Key: Any] = [
      .font: labelFont,
      .foregroundColor: NSColor.white
    ]

    let highlightedRow = cells.first(where: { $0.candidateIndex == highlightedIndex })?.row ?? -1
    for cell in cells where cell.row >= visibleStartRow && cell.row < visibleStartRow + Self.rowCount {
      let candidate = candidates[cell.candidateIndex]
      let row = cell.row - visibleStartRow
      let cellX = bounds.minX + CGFloat(cell.column) * columnWidth
      let cellY = bounds.minY + CGFloat(row) * rowHeight
      let cellWidth = CGFloat(cell.span) * columnWidth
      let isHighlighted = cell.candidateIndex == highlightedIndex
      let isActiveRow = cell.row == highlightedRow
      let candidateAttributes = isHighlighted ? highlightedAttributes : normalAttributes
      let candidateSize = (candidate as NSString).size(withAttributes: candidateAttributes)

      let candidateX = cellX + 15.5
      if isActiveRow {
        let label = "\(cell.orderInRow + 1)"
        let labelAttributes = isHighlighted ? highlightedLabelAttributes : labelAttributes
        if isHighlighted {
          let pillWidth = min(cellWidth - 5, max(56, candidateSize.width + 22))
          let pill = NSBezierPath(
            roundedRect: NSRect(x: cellX + 3, y: cellY + 3, width: pillWidth, height: rowHeight - 6),
            xRadius: (rowHeight - 6) / 2,
            yRadius: (rowHeight - 6) / 2
          )
          NSColor.systemBlue.setFill()
          pill.fill()
        }
        (label as NSString).draw(at: NSPoint(x: cellX + 5.5, y: cellY + 9.5), withAttributes: labelAttributes)
      }
      (candidate as NSString).draw(at: NSPoint(x: candidateX, y: cellY + 5.5), withAttributes: candidateAttributes)
    }
  }

  private func makeCells(candidates: [String]) -> [CandidateCell] {
    let font = NSFont(name: "PingFangSC-Regular", size: 14) ?? .systemFont(ofSize: 14, weight: .regular)
    let attributes: [NSAttributedString.Key: Any] = [.font: font]
    let columnWidth = Self.preferredSize.width / CGFloat(Self.columnCount)
    var cells = [CandidateCell]()
    var row = 0
    var column = 0
    var orderInRow = 0

    for (candidateIndex, candidate) in candidates.enumerated() {
      let width = (candidate as NSString).size(withAttributes: attributes).width + 22
      let span = min(Self.columnCount, max(1, Int(ceil(width / columnWidth))))
      if column > 0, column + span > Self.columnCount {
        row += 1
        column = 0
        orderInRow = 0
      }
      cells.append(CandidateCell(candidateIndex: candidateIndex, row: row, column: column, span: span, orderInRow: orderInRow))
      column += span
      orderInRow += 1
      if column == Self.columnCount {
        row += 1
        column = 0
        orderInRow = 0
      }
    }
    return cells
  }
}
