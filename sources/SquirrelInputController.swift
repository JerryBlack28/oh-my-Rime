//
//  SquirrelInputController.swift
//  Squirrel
//
//  Created by Leo Liu on 5/7/24.
//

import InputMethodKit

final class SquirrelInputController: IMKInputController {
  private static let keyRollOver = 50
  private static var unknownAppCnt: UInt = 0

  private weak var client: IMKTextInput?
  private let rimeAPI: RimeApi_stdbool = rime_get_api_stdbool().pointee
  private var preedit: String = ""
  private var selRange: NSRange = .empty
  private var caretPos: Int = 0
  private var lastModifiers: NSEvent.ModifierFlags = .init()
  private var session: RimeSessionId = 0
  private var schemaId: String = ""
  private var inlinePreedit = false
  private var inlineCandidate = false
  // for chord-typing
  private var chordKeyCodes: [UInt32] = .init(repeating: 0, count: SquirrelInputController.keyRollOver)
  private var chordModifiers: [UInt32] = .init(repeating: 0, count: SquirrelInputController.keyRollOver)
  private var chordKeyCount: Int = 0
  private var chordTimer: Timer?
  private var chordDuration: TimeInterval = 0
  private var currentApp: String = ""
  private var clipboardEntries = [ClipboardHistoryEntry]()
  private var clipboardPlaceholderActive = false
  private var candidateRankingContext: CandidateRankingContext?
  private var lastRankedInput = ""
  private var compositionDocumentContext = ""

  // swiftlint:disable:next cyclomatic_complexity
  override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
    guard let event = event else { return false }
    let modifiers = event.modifierFlags
    let changes = lastModifiers.symmetricDifference(modifiers)

    // Return true to indicate the the key input was received and dealt with.
    // Key processing will not continue in that case.  In other words the
    // system will not deliver a key down event to the application.
    // Returning false means the original key down will be passed on to the client.
    var handled = false

    if session == 0 || !rimeAPI.find_session(session) {
      createSession()
      if session == 0 {
        return false
      }
    }

    self.client ?= sender as? IMKTextInput
    if let app = client?.bundleIdentifier(), currentApp != app {
      currentApp = app
      updateAppOptions()
    }

    // Once the clipboard palette is open, releasing the shortcut modifier must not be
    // forwarded to Rime. Its normal no-composition update would hide the
    // palette immediately after the shortcut keys are released.
    if event.type == .flagsChanged,
       NSApp.squirrelAppDelegate.panel?.clipboardMode == true {
      lastModifiers = modifiers
      return true
    }

    switch event.type {
    case .flagsChanged:
      if lastModifiers == modifiers {
        handled = true
        break
      }
      // print("[DEBUG] FLAGSCHANGED client: \(sender ?? "nil"), modifiers: \(modifiers)")
      var rimeModifiers: UInt32 = SquirrelKeycode.osxModifiersToRime(modifiers: modifiers)
      // For flags-changed event, keyCode is available since macOS 10.15
      // (#715)
      let rimeKeycode: UInt32 = SquirrelKeycode.osxKeycodeToRime(keycode: event.keyCode, keychar: nil, shift: false, caps: false)

      if changes.contains(.capsLock) {
        // NOTE: rime assumes XK_Caps_Lock to be sent before modifier changes,
        // while NSFlagsChanged event has the flag changed already.
        // so it is necessary to revert kLockMask.
        rimeModifiers ^= kLockMask.rawValue
        _ = processKey(rimeKeycode, modifiers: rimeModifiers)
      }

      // Need to process release before modifier down. Because
      // sometimes release event is delayed to next modifier keydown.
      var buffer = [(keycode: UInt32, modifier: UInt32)]()
      for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] where changes.contains(flag) {
        if modifiers.contains(flag) { // New modifier
          buffer.append((keycode: rimeKeycode, modifier: rimeModifiers))
        } else { // Release
          buffer.insert((keycode: rimeKeycode, modifier: rimeModifiers | kReleaseMask.rawValue), at: 0)
        }
      }
      for (keycode, modifier) in buffer {
        _ = processKey(keycode, modifiers: modifier)
      }

      lastModifiers = modifiers
      rimeUpdate()

    case .keyDown:
      let shortcutModifiers = modifiers.intersection([.command, .control, .option, .shift])
      if event.keyCode == UInt16(kVK_ANSI_V), shortcutModifiers == [.option] {
        handled = showClipboardHistory(client: sender)
        break
      }
      if NSApp.squirrelAppDelegate.panel?.clipboardMode == true {
        if let clipboardHandled = handleClipboardKey(event) {
          // Return directly. Some clients (including Codex) attach their own
          // history action to the Up arrow; merely falling through the normal
          // input-method path can allow that client command to run as well.
          return clipboardHandled
        }
        closeClipboardHistory()
      }

      // ignore Command+X hotkeys.
      if modifiers.contains(.command) {
        break
      }

      let existingInput = rimeAPI.get_input(session).map { String(cString: $0) } ?? ""
      if existingInput.isEmpty {
        compositionDocumentContext = precedingClientText()
      }

      let keyCode = event.keyCode
      var keyChars = event.charactersIgnoringModifiers
      let capitalModifiers = modifiers.isSubset(of: [.shift, .capsLock])
      if let code = keyChars?.first,
         (capitalModifiers && !code.isLetter) || (!capitalModifiers && !code.isASCII) {
        keyChars = event.characters
      }
      // print("[DEBUG] KEYDOWN client: \(sender ?? "nil"), modifiers: \(modifiers), keyCode: \(keyCode), keyChars: [\(keyChars ?? "empty")]")

      // The native-width candidate window can contain a different number of
      // candidates on each visual page. Handle paging and numeric selection
      // here so they map back to the corresponding librime page index.
      let hasOnlyCapsLock = modifiers.intersection([.command, .control, .option, .shift]).isEmpty
      let appleGridUpKeys: Set<UInt16> = [UInt16(kVK_ANSI_Minus), UInt16(kVK_UpArrow)]
      let appleGridDownKeys: Set<UInt16> = [UInt16(kVK_ANSI_Equal), UInt16(kVK_DownArrow)]
      let pageUpKeys: Set<UInt16> = [UInt16(kVK_PageUp)]
      let pageDownKeys: Set<UInt16> = [UInt16(kVK_PageDown)]
      if hasOnlyCapsLock,
         [UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter), UInt16(kVK_Space)].contains(keyCode),
         let panel = NSApp.squirrelAppDelegate.panel,
         panel.isVisible,
         panel.usesAdaptiveCandidateOrder,
         let localIndex = panel.highlightedLocalCandidateIndex {
        handled = selectLocalCandidate(localIndex)
        if handled {
          break
        }
      }
      if hasOnlyCapsLock, keyCode == UInt16(kVK_RightArrow) {
        handled = moveRightIntoAppleGrid()
        if handled {
          break
        }
      }
      if hasOnlyCapsLock,
         [UInt16(kVK_LeftArrow), UInt16(kVK_RightArrow)].contains(keyCode),
         let panel = NSApp.squirrelAppDelegate.panel,
         panel.isVisible,
         panel.usesAdaptiveCandidateOrder {
        handled = moveAcrossAdaptiveCandidates(forward: keyCode == UInt16(kVK_RightArrow))
        if handled {
          break
        }
      }
      if hasOnlyCapsLock, appleGridUpKeys.contains(keyCode) || appleGridDownKeys.contains(keyCode) {
        handled = appleGridPage(up: appleGridUpKeys.contains(keyCode))
        if handled {
          break
        }
      }
      if hasOnlyCapsLock, pageUpKeys.contains(keyCode) || pageDownKeys.contains(keyCode) {
        handled = appleGridVisualPage(up: pageUpKeys.contains(keyCode))
        if handled {
          break
        }
      }
      if modifiers.intersection([.command, .control, .option, .shift]).isEmpty,
         let char = keyChars?.first,
         let number = Int(String(char)),
         number >= 1,
         number <= 9,
         let panel = NSApp.squirrelAppDelegate.panel,
         panel.isVisible,
         number <= panel.visibleCandidateCount {
        handled = selectCandidate(number - 1)
        if handled {
          break
        }
      }

      // translate osx keyevents to rime keyevents
      if let char = keyChars?.first {
        let rimeKeycode = SquirrelKeycode.osxKeycodeToRime(keycode: keyCode, keychar: char,
                                                           shift: modifiers.contains(.shift),
                                                           caps: modifiers.contains(.capsLock))
        if rimeKeycode != 0 {
          let rimeModifiers = SquirrelKeycode.osxModifiersToRime(modifiers: modifiers)
          handled = processKey(rimeKeycode, modifiers: rimeModifiers)
          rimeUpdate()
        }
      }

    default:
      break
    }

    return handled
  }

  func selectCandidate(_ index: Int) -> Bool {
    let candidateIndex = NSApp.squirrelAppDelegate.panel?.absoluteCandidateIndex(forVisibleIndex: index) ?? index
    let success = rimeAPI.select_candidate(session, candidateIndex)
    if success {
      rimeUpdate()
    }
    return success
  }

  private func selectLocalCandidate(_ index: Int) -> Bool {
    let candidateIndex = NSApp.squirrelAppDelegate.panel?.absoluteCandidateIndex(forLocalIndex: index) ?? index
    let success = rimeAPI.select_candidate(session, candidateIndex)
    if success {
      rimeUpdate()
    }
    return success
  }

  func selectClipboardEntry(_ index: Int) -> Bool {
    guard index >= 0, index < clipboardEntries.count else { return false }
    let entry = clipboardEntries[index]
    closeClipboardHistory()
    switch entry.kind {
    case .text:
      guard let text = entry.text else { return false }
      commit(string: text)
      return true
    case .image, .files:
      guard NSApp.squirrelAppDelegate.ensurePasteAccessibility() else {
        NSSound.beep()
        return false
      }
      guard NSApp.squirrelAppDelegate.clipboardHistory.restore(entry) else {
        NSSound.beep()
        return false
      }
      postPasteShortcut(to: NSWorkspace.shared.frontmostApplication?.processIdentifier)
      return true
    }
  }

  // swiftlint:disable:next identifier_name
  func page(up: Bool) -> Bool {
    var handled = false
    if up,
       let panel = NSApp.squirrelAppDelegate.panel,
       panel.isVisible,
       panel.isAtFirstVisualPage,
       panel.hasPreviousBackingPage {
      // Rime moves between its backing pages from the currently highlighted
      // item. After arriving at the previous backing page, continue at its
      // final visual group rather than its first candidate.
      handled = rimeAPI.change_page(session, true)
      if handled {
        rimeUpdate()
        if let panel = NSApp.squirrelAppDelegate.panel,
           let target = panel.lastVisualPageTarget(), target > 0 {
          handled = rimeAPI.highlight_candidate(session, panel.absoluteCandidateIndex(forLocalIndex: target))
          if handled {
            rimeUpdate()
          }
        }
      }
      return handled
    }
    if let panel = NSApp.squirrelAppDelegate.panel,
       panel.isVisible,
       let localTarget = panel.localPageTarget(up: up) {
      handled = rimeAPI.highlight_candidate(session, panel.absoluteCandidateIndex(forLocalIndex: localTarget))
    } else {
      // librime preserves the highlighted offset when changing its larger
      // backing page. Reset it so the next visual group starts at candidate 1
      // instead of appearing to skip the beginning of that page.
      _ = rimeAPI.highlight_candidate_on_current_page(session, 0)
      handled = rimeAPI.change_page(session, up)
    }
    if handled {
      rimeUpdate()
    }
    return handled
  }

  private func appleGridPage(up: Bool) -> Bool {
    guard let panel = NSApp.squirrelAppDelegate.panel, panel.isVisible else { return false }

    if !panel.appleGridMode {
      return up ? false : panel.activateAppleGrid()
    }

    guard let target = panel.appleGridTarget(up: up) else {
      if up {
        panel.deactivateAppleGrid()
        return true
      }
      return false
    }
    let handled = rimeAPI.highlight_candidate(session, panel.absoluteCandidateIndex(forLocalIndex: target))
    if handled {
      rimeUpdate()
    }
    return handled
  }

  private func moveRightIntoAppleGrid() -> Bool {
    guard let panel = NSApp.squirrelAppDelegate.panel,
          panel.isVisible,
          let target = panel.nextCandidateAfterVisibleEnd() else {
      return false
    }
    let handled = rimeAPI.highlight_candidate(session, panel.absoluteCandidateIndex(forLocalIndex: target))
    if handled {
      panel.prepareAppleGridForKeyboardNavigation()
      rimeUpdate()
    }
    return handled
  }

  private func moveAcrossAdaptiveCandidates(forward: Bool) -> Bool {
    guard let panel = NSApp.squirrelAppDelegate.panel,
          let target = panel.adjacentCandidate(forward: forward) else {
      return true
    }
    let handled = rimeAPI.highlight_candidate(
      session,
      panel.absoluteCandidateIndex(forLocalIndex: target)
    )
    if handled {
      rimeUpdate()
    }
    return handled
  }

  private func appleGridVisualPage(up: Bool) -> Bool {
    guard let panel = NSApp.squirrelAppDelegate.panel, panel.isVisible else { return false }

    if !panel.appleGridMode {
      return up ? page(up: true) : panel.activateAppleGrid()
    }

    if up, panel.appleGridHighlightIsOnFirstRow {
      panel.deactivateAppleGrid()
      return true
    }

    guard let target = panel.appleGridPageTarget(up: up) else {
      // Consume the key at the first/last grid page instead of passing it to
      // librime and unexpectedly changing its backing page.
      return true
    }
    let handled = rimeAPI.highlight_candidate(session, panel.absoluteCandidateIndex(forLocalIndex: target))
    if handled {
      rimeUpdate()
    }
    return handled
  }

  func moveCaret(forward: Bool) -> Bool {
    let currentCaretPos = rimeAPI.get_caret_pos(session)
    guard let input = rimeAPI.get_input(session) else { return false }
    if forward {
      if currentCaretPos <= 0 {
        return false
      }
      rimeAPI.set_caret_pos(session, currentCaretPos - 1)
    } else {
      let inputStr = String(cString: input)
      if currentCaretPos >= inputStr.utf8.count {
        return false
      }
      rimeAPI.set_caret_pos(session, currentCaretPos + 1)
    }
    rimeUpdate()
    return true
  }

  override func recognizedEvents(_ sender: Any!) -> Int {
    // print("[DEBUG] recognizedEvents:")
    return Int(NSEvent.EventTypeMask.Element(arrayLiteral: .keyDown, .flagsChanged).rawValue)
  }

  override func activateServer(_ sender: Any!) {
    self.client ?= sender as? IMKTextInput
    NSApp.squirrelAppDelegate.activeInputController = self
    // print("[DEBUG] activateServer:")
    var keyboardLayout = NSApp.squirrelAppDelegate.config?.getString("keyboard_layout") ?? ""
    if keyboardLayout == "last" || keyboardLayout == "" {
      keyboardLayout = ""
    } else if keyboardLayout == "default" {
      keyboardLayout = "com.apple.keylayout.ABC"
    } else if !keyboardLayout.hasPrefix("com.apple.keylayout.") {
      keyboardLayout = "com.apple.keylayout.\(keyboardLayout)"
    }
    if keyboardLayout != "" {
      client?.overrideKeyboard(withKeyboardNamed: keyboardLayout)
    }
    preedit = ""
  }

  override init!(server: IMKServer!, delegate: Any!, client: Any!) {
    self.client = client as? IMKTextInput
    // print("[DEBUG] initWithServer: \(server ?? .init()) delegate: \(delegate ?? "nil") client:\(client ?? "nil")")
    super.init(server: server, delegate: delegate, client: client)
    createSession()
  }

  override func deactivateServer(_ sender: Any!) {
    // print("[DEBUG] deactivateServer: \(sender ?? "nil")")
    hidePalettes()
    commitComposition(sender)
    if NSApp.squirrelAppDelegate.activeInputController === self {
      NSApp.squirrelAppDelegate.activeInputController = nil
    }
    client = nil
  }

  override func hidePalettes() {
    clearClipboardPlaceholder()
    NSApp.squirrelAppDelegate.panel?.hide()
    super.hidePalettes()
  }

  /*!
   @method
   @abstract   Called when a user action was taken that ends an input session.
   Typically triggered by the user selecting a new input method
   or keyboard layout.
   @discussion When this method is called your controller should send the
   current input buffer to the client via a call to
   insertText:replacementRange:.  Additionally, this is the time
   to clean up if that is necessary.
   */
  override func commitComposition(_ sender: Any!) {
    self.client ?= sender as? IMKTextInput
    // print("[DEBUG] commitComposition: \(sender ?? "nil")")
    //  commit raw input
    if session != 0 {
      if let input = rimeAPI.get_input(session) {
        commit(string: String(cString: input))
        rimeAPI.clear_composition(session)
      }
    }
  }

  override func menu() -> NSMenu! {
    let deploy = NSMenuItem(title: NSLocalizedString("Deploy", comment: "Menu item"), action: #selector(deploy), keyEquivalent: "`")
    deploy.target = self
    deploy.keyEquivalentModifierMask = [.control, .option]
    let sync = NSMenuItem(title: NSLocalizedString("Sync user data", comment: "Menu item"), action: #selector(syncUserData), keyEquivalent: "")
    sync.target = self
    let clipboard = NSMenuItem(title: "剪贴板历史…", action: #selector(openClipboardHistory), keyEquivalent: "v")
    clipboard.target = self
    clipboard.keyEquivalentModifierMask = [.option]
    let adaptiveRanking = NSMenuItem(
      title: NSApp.squirrelAppDelegate.candidateReranker.hasSemanticModel
        ? "智能候选排序（上下文模型已加载）"
        : "智能候选排序（仅习惯学习）",
      action: #selector(toggleAdaptiveRanking),
      keyEquivalent: ""
    )
    adaptiveRanking.target = self
    adaptiveRanking.state = NSApp.squirrelAppDelegate.candidateReranker.isEnabled ? .on : .off
    let logDir = NSMenuItem(title: NSLocalizedString("Logs...", comment: "Menu item"), action: #selector(openLogFolder), keyEquivalent: "")
    logDir.target = self
    let setting = NSMenuItem(title: NSLocalizedString("Settings...", comment: "Menu item"), action: #selector(openRimeFolder), keyEquivalent: "")
    setting.target = self
    let wiki = NSMenuItem(title: NSLocalizedString("Rime Wiki...", comment: "Menu item"), action: #selector(openWiki), keyEquivalent: "")
    wiki.target = self

    let menu = NSMenu()
    menu.addItem(deploy)
    menu.addItem(sync)
    menu.addItem(clipboard)
    menu.addItem(adaptiveRanking)
    menu.addItem(logDir)
    menu.addItem(setting)
    menu.addItem(wiki)

    return menu
  }

  @objc private func openClipboardHistory() {
    _ = showClipboardHistory(client: client)
  }

  func openClipboardHistoryFromGlobalHotkey() {
    _ = showClipboardHistory(client: client)
  }

  @objc private func toggleAdaptiveRanking() {
    _ = NSApp.squirrelAppDelegate.candidateReranker.toggleEnabled()
    rimeUpdate()
  }

  @objc func deploy() {
    NSApp.squirrelAppDelegate.deploy()
  }

  @objc func syncUserData() {
    NSApp.squirrelAppDelegate.syncUserData()
  }

  @objc func openLogFolder() {
    NSApp.squirrelAppDelegate.openLogFolder()
  }

  @objc func openRimeFolder() {
    NSApp.squirrelAppDelegate.openRimeFolder()
  }

  @objc func openWiki() {
    NSApp.squirrelAppDelegate.openWiki()
  }

  deinit {
    destroySession()
  }
}

private extension SquirrelInputController {

  func onChordTimer(_: Timer) {
    // chord release triggered by timer
    var processedKeys = false
    if chordKeyCount > 0 && session != 0 {
      // simulate key-ups
      for i in 0..<chordKeyCount {
        let handled = rimeAPI.process_key(session, Int32(chordKeyCodes[i]), Int32(chordModifiers[i] | kReleaseMask.rawValue))
        if handled {
          processedKeys = true
        }
      }
    }
    clearChord()
    if processedKeys {
      rimeUpdate()
    }
  }

  func updateChord(keycode: UInt32, modifiers: UInt32) {
    // print("[DEBUG] update chord: {\(chordKeyCodes)} << \(keycode)")
    for i in 0..<chordKeyCount where chordKeyCodes[i] == keycode {
      return
    }
    if chordKeyCount >= Self.keyRollOver {
      // you are cheating. only one human typist (fingers <= 10) is supported.
      return
    }
    chordKeyCodes[chordKeyCount] = keycode
    chordModifiers[chordKeyCount] = modifiers
    chordKeyCount += 1
    // reset timer
    if let timer = chordTimer, timer.isValid {
      timer.invalidate()
    }
    chordDuration = 0.1
    if let duration = NSApp.squirrelAppDelegate.config?.getDouble("chord_duration"), duration > 0 {
      chordDuration = duration
    }
    chordTimer = Timer.scheduledTimer(withTimeInterval: chordDuration, repeats: false, block: onChordTimer)
  }

  func clearChord() {
    chordKeyCount = 0
    if let timer = chordTimer {
      if timer.isValid {
        timer.invalidate()
      }
      chordTimer = nil
    }
  }

  func createSession() {
    let app = client?.bundleIdentifier() ?? {
      SquirrelInputController.unknownAppCnt &+= 1
      return "UnknownApp\(SquirrelInputController.unknownAppCnt)"
    }()
    print("createSession: \(app)")
    currentApp = app
    session = rimeAPI.create_session()
    schemaId = ""

    if session != 0 {
      updateAppOptions()
    }
  }

  func updateAppOptions() {
    if currentApp == "" {
      return
    }
    if let appOptions = NSApp.squirrelAppDelegate.config?.getAppOptions(currentApp) {
      for (key, value) in appOptions {
        print("set app option: \(key) = \(value)")
        rimeAPI.set_option(session, key, value)
      }
    }
  }

  func destroySession() {
    // print("[DEBUG] destroySession:")
    if session != 0 {
      _ = rimeAPI.destroy_session(session)
      session = 0
    }
    clearChord()
  }

  func processKey(_ rimeKeycode: UInt32, modifiers rimeModifiers: UInt32) -> Bool {
    // TODO add special key event preprocessing here

    // with linear candidate list, arrow keys may behave differently.
    if let panel = NSApp.squirrelAppDelegate.panel {
      if panel.linear != rimeAPI.get_option(session, "_linear") {
        rimeAPI.set_option(session, "_linear", panel.linear)
      }
      // with vertical text, arrow keys may behave differently.
      if panel.vertical != rimeAPI.get_option(session, "_vertical") {
        rimeAPI.set_option(session, "_vertical", panel.vertical)
      }
    }

    let handled = rimeAPI.process_key(session, Int32(rimeKeycode), Int32(rimeModifiers))
    // print("[DEBUG] rime_keycode: \(rimeKeycode), rime_modifiers: \(rimeModifiers), handled = \(handled)")

    // TODO add special key event postprocessing here

    if !handled {
      let isVimBackInCommandMode = rimeKeycode == XK_Escape || ((rimeModifiers & kControlMask.rawValue != 0) && (rimeKeycode == XK_c || rimeKeycode == XK_C || rimeKeycode == XK_bracketleft))
      if isVimBackInCommandMode && rimeAPI.get_option(session, "vim_mode") &&
          !rimeAPI.get_option(session, "ascii_mode") {
        rimeAPI.set_option(session, "ascii_mode", true)
        // print("[DEBUG] turned Chinese mode off in vim-like editor's command mode")
      }
    } else {
      let isChordingKey = switch Int32(rimeKeycode) {
      case XK_space...XK_asciitilde, XK_Control_L, XK_Control_R, XK_Alt_L, XK_Alt_R, XK_Shift_L, XK_Shift_R:
        true
      default:
        false
      }
      if isChordingKey && rimeAPI.get_option(session, "_chord_typing") {
        updateChord(keycode: rimeKeycode, modifiers: rimeModifiers)
      } else if (rimeModifiers & kReleaseMask.rawValue) == 0 {
        // non-chording key pressed
        clearChord()
      }
    }

    return handled
  }

  func rimeConsumeCommittedText() {
    var commitText = RimeCommit.rimeStructInit()
    if rimeAPI.get_commit(session, &commitText) {
      if let text = commitText.text {
        let committed = String(cString: text)
        if let context = candidateRankingContext {
          let chosen = context.candidates
            .filter {
              !($0.isEmpty) &&
                (committed.hasPrefix($0) || committed.hasSuffix($0))
            }
            .max(by: { $0.count < $1.count }) ?? committed
          NSApp.squirrelAppDelegate.candidateReranker.learn(
            chosen: chosen,
            context: context
          )
        }
        candidateRankingContext = nil
        commit(string: committed)
      }
      _ = rimeAPI.free_commit(&commitText)
    }
  }

  // swiftlint:disable:next cyclomatic_complexity
  func rimeUpdate() {
    // print("[DEBUG] rimeUpdate")
    rimeConsumeCommittedText()

    var status = RimeStatus_stdbool.rimeStructInit()
    if rimeAPI.get_status(session, &status) {
      // enable schema specific ui style
      // swiftlint:disable:next identifier_name
      if let schema_id = status.schema_id, schemaId == "" || schemaId != String(cString: schema_id) {
        schemaId = String(cString: schema_id)
        NSApp.squirrelAppDelegate.loadSettings(for: schemaId)
        // inline preedit
        if let panel = NSApp.squirrelAppDelegate.panel {
          inlinePreedit = (panel.inlinePreedit && !rimeAPI.get_option(session, "no_inline")) || rimeAPI.get_option(session, "inline")
          inlineCandidate = panel.inlineCandidate && !rimeAPI.get_option(session, "no_inline")
          // if not inline, embed soft cursor in preedit string
          rimeAPI.set_option(session, "soft_cursor", !inlinePreedit)
        }
      }
      _ = rimeAPI.free_status(&status)
    }

    var ctx = RimeContext_stdbool.rimeStructInit()
    if rimeAPI.get_context(session, &ctx) {
      // update preedit text
      let preedit = ctx.composition.preedit.map({ String(cString: $0) }) ?? ""

      let start = String.Index(preedit.utf8.index(preedit.utf8.startIndex, offsetBy: Int(ctx.composition.sel_start)), within: preedit) ?? preedit.startIndex
      let end = String.Index(preedit.utf8.index(preedit.utf8.startIndex, offsetBy: Int(ctx.composition.sel_end)), within: preedit) ?? preedit.startIndex
      let caretPos = String.Index(preedit.utf8.index(preedit.utf8.startIndex, offsetBy: Int(ctx.composition.cursor_pos)), within: preedit) ?? preedit.startIndex

      if inlineCandidate {
        var candidatePreview = ctx.commit_text_preview.map { String(cString: $0) } ?? ""
        let endOfCandidatePreview = candidatePreview.endIndex
        if inlinePreedit {
          // 左移光標後的情形：
          // preedit:             ^已選某些字[xiang zuo yi dong]|guangbiao$
          // commit_text_preview: ^已選某些字向左移動$
          // candidate_preview:   ^已選某些字[向左移動]|guangbiao$
          // 繼續翻頁至指定更短字詞的情形：
          // preedit:             ^已選某些字[xiang zuo]yidong|guangbiao$
          // commit_text_preview: ^已選某些字向左yidong$
          // candidate_preview:   ^已選某些字[向左]yidong|guangbiao$
          // 光標移至當前段落最左端的情形：
          // preedit:             ^已選某些字|[xiang zuo yi dong guang biao]$
          // commit_text_preview: ^已選某些字向左移動光標$
          // candidate_preview:   ^已選某些字|[向左移動光標]$
          // 討論：
          // preedit 與 commit_text_preview 中“已選某些字”部分一致
          // 因此，選中範圍即正在翻譯的碼段“向左移動”中，兩者的 start 值一致
          // 光標位置的範圍是 start ..= endOfCandidatePreview
          if caretPos >= end && caretPos < preedit.endIndex {
            // 從 preedit 截取光標後未翻譯的編碼“guangbiao”
            candidatePreview += preedit[caretPos...]
          }
        } else {
          // 翻頁至指定更短字詞的情形：
          // preedit:             ^已選某些字[xiang zuo]yidong|guangbiao$
          // commit_text_preview: ^已選某些字向左yidongguangbiao$
          // candidate_preview:   ^已選某些字[向左???]|$
          // 光標移至當前段落最左端，繼續翻頁至指定更短字詞的情形：
          // preedit:             ^已選某些字|[xiang zuo]yidongguangbiao$
          // commit_text_preview: ^已選某些字向左yidongguangbiao$
          // candidate_preview:   ^已選某些字|[向左]???$
          // FIXME: add librime APIs to support preview candidate without remaining code.
        }
        // preedit can contain additional prompt text before start:
        // ^(prompt)[selection]$
        let start = min(start, candidatePreview.endIndex)
        // caret can be either before or after the selected range.
        let caretPos = caretPos <= start ? caretPos : endOfCandidatePreview
        show(preedit: candidatePreview,
             selRange: NSRange(location: start.utf16Offset(in: candidatePreview),
                               length: candidatePreview.utf16.distance(from: start, to: candidatePreview.endIndex)),
             caretPos: caretPos.utf16Offset(in: candidatePreview))
      } else {
        if inlinePreedit {
          show(preedit: preedit, selRange: NSRange(location: start.utf16Offset(in: preedit), length: preedit.utf16.distance(from: start, to: end)), caretPos: caretPos.utf16Offset(in: preedit))
        } else {
          // TRICKY: display a non-empty string to prevent iTerm2 from echoing
          // each character in preedit. note this is a full-shape space U+3000;
          // using half shape characters like "..." will result in an unstable
          // baseline when composing Chinese characters.
          show(preedit: preedit.isEmpty ? "" : "　", selRange: NSRange(location: 0, length: 0), caretPos: 0)
        }
      }

      // update candidates
      let numCandidates = Int(ctx.menu.num_candidates)
      var candidates = [String]()
      var comments = [String]()
      for i in 0..<numCandidates {
        let candidate = ctx.menu.candidates[i]
        candidates.append(candidate.text.map { String(cString: $0) } ?? "")
        comments.append(candidate.comment.map { String(cString: $0) } ?? "")
      }
      var labels = [String]()
      // swiftlint:disable identifier_name
      if let select_keys = ctx.menu.select_keys {
        labels = String(cString: select_keys).map { String($0) }
      } else if let select_labels = ctx.select_labels {
        let pageSize = Int(ctx.menu.page_size)
        for i in 0..<pageSize {
          labels.append(select_labels[i].map { String(cString: $0) } ?? "")
        }
      }
      // swiftlint:enable identifier_name
      let page = Int(ctx.menu.page_no)
      let pageSize = Int(ctx.menu.page_size)
      let lastPage = ctx.menu.is_last_page
      let highlighted = Int(ctx.menu.highlighted_candidate_index)
      let selectedCandidate = page * pageSize + highlighted
      let input = rimeAPI.get_input(session).map { String(cString: $0) } ?? ""
      let precedingText = compositionDocumentContext
      let originalCandidates = candidates
      let rankedIndices = NSApp.squirrelAppDelegate.candidateReranker.rankedIndices(
        candidates: candidates,
        input: input,
        precedingText: precedingText,
        application: currentApp
      )
      candidates = rankedIndices.map { candidates[$0] }
      comments = rankedIndices.map { comments[$0] }
      let currentAbsoluteIndices = rankedIndices.map { page * pageSize + $0 }
      candidateRankingContext = CandidateRankingContext(
        input: input,
        precedingText: precedingText,
        application: currentApp,
        candidates: originalCandidates
      )

      // Keep the fixed-width window independent from librime's backing-page
      // boundary by keeping adjacent backing pages in one candidate stream.
      // The panel can therefore form visual pages across either boundary.
      var displayedCandidates = candidates
      var displayedComments = comments
      var displayedLastPage = lastPage
      var candidateOffset = page * pageSize
      var displayedAbsoluteIndices = currentAbsoluteIndices
      if page > 0, pageSize > 0 {
        let previousPageStart = candidateOffset - pageSize
        if rimeAPI.highlight_candidate(session, previousPageStart) {
          var previousContext = RimeContext_stdbool.rimeStructInit()
          if rimeAPI.get_context(session, &previousContext) {
            var previousCandidates = [String]()
            var previousComments = [String]()
            for i in 0..<Int(previousContext.menu.num_candidates) {
              let candidate = previousContext.menu.candidates[i]
              previousCandidates.append(candidate.text.map { String(cString: $0) } ?? "")
              previousComments.append(candidate.comment.map { String(cString: $0) } ?? "")
            }
            displayedCandidates = previousCandidates + displayedCandidates
            displayedComments = previousComments + displayedComments
            displayedAbsoluteIndices =
              Array(previousPageStart..<(previousPageStart + previousCandidates.count)) +
              displayedAbsoluteIndices
            candidateOffset = previousPageStart
            _ = rimeAPI.free_context(&previousContext)
          }
          _ = rimeAPI.highlight_candidate(session, selectedCandidate)
        }
      }
      if !lastPage, pageSize > 0 {
        let nextPageStart = page * pageSize + pageSize
        if rimeAPI.highlight_candidate(session, nextPageStart) {
          var nextContext = RimeContext_stdbool.rimeStructInit()
          if rimeAPI.get_context(session, &nextContext) {
            for i in 0..<Int(nextContext.menu.num_candidates) {
              let candidate = nextContext.menu.candidates[i]
              displayedCandidates.append(candidate.text.map { String(cString: $0) } ?? "")
              displayedComments.append(candidate.comment.map { String(cString: $0) } ?? "")
            }
            displayedAbsoluteIndices.append(
              contentsOf: nextPageStart..<(nextPageStart + Int(nextContext.menu.num_candidates))
            )
            displayedLastPage = nextContext.menu.is_last_page
            _ = rimeAPI.free_context(&nextContext)
          }
          _ = rimeAPI.highlight_candidate(session, selectedCandidate)
        }
      }

      let compositionChanged = input != lastRankedInput
      let desiredAbsoluteIndex = compositionChanged ?
        (currentAbsoluteIndices.first ?? selectedCandidate) :
        selectedCandidate
      let displayedHighlight =
        displayedAbsoluteIndices.firstIndex(of: desiredAbsoluteIndex) ?? 0
      lastRankedInput = input
      let selRange = NSRange(location: start.utf16Offset(in: preedit), length: preedit.utf16.distance(from: start, to: end))
      showPanel(preedit: inlinePreedit ? "" : preedit, selRange: selRange, caretPos: caretPos.utf16Offset(in: preedit),
                candidates: displayedCandidates, comments: displayedComments, labels: labels, candidateOffset: candidateOffset,
                candidateAbsoluteIndices: displayedAbsoluteIndices, highlighted: displayedHighlight,
                page: page, lastPage: displayedLastPage)
      _ = rimeAPI.free_context(&ctx)
    } else {
      hidePalettes()
    }
  }

  func commit(string: String) {
    guard let client = client else { return }
    // print("[DEBUG] commitString: \(string)")
    client.insertText(string, replacementRange: .empty)
    preedit = ""
    hidePalettes()
  }

  private func showClipboardHistory(client sender: Any!) -> Bool {
    self.client ?= sender as? IMKTextInput
    clipboardEntries = NSApp.squirrelAppDelegate.clipboardHistory.currentEntries()
    guard !clipboardEntries.isEmpty, let client else {
      NSSound.beep()
      return true
    }

    if session != 0 {
      rimeAPI.clear_composition(session)
    }
    clearClipboardPlaceholder()
    // Keep an invisible marked-text composition alive while the clipboard
    // palette is open. Web/Electron editors can observe arrow keys before
    // InputMethodKit returns its handled result; their history shortcuts
    // normally ignore those keys while an IME composition is active.
    let placeholder = "\u{2060}"
    client.setMarkedText(
      placeholder,
      selectionRange: NSRange(location: placeholder.utf16.count, length: 0),
      replacementRange: .empty
    )
    clipboardPlaceholderActive = true
    preedit = ""

    if let panel = NSApp.squirrelAppDelegate.panel {
      panel.position = NSApp.squirrelAppDelegate.clipboardPanelAnchor()
      panel.inputController = self
      panel.showClipboard(clipboardEntries.map(\.displayTitle))
    }
    return true
  }

  private func closeClipboardHistory() {
    clipboardEntries.removeAll()
    clearClipboardPlaceholder()
    NSApp.squirrelAppDelegate.panel?.hideClipboard()
  }

  private func clearClipboardPlaceholder() {
    guard clipboardPlaceholderActive else { return }
    client?.setMarkedText("", selectionRange: .empty, replacementRange: .empty)
    clipboardPlaceholderActive = false
  }

  private func handleClipboardKey(_ event: NSEvent) -> Bool? {
    guard let panel = NSApp.squirrelAppDelegate.panel else { return nil }

    // Navigation keys always belong exclusively to the open clipboard panel,
    // even if macOS still reports a just-released shortcut modifier.
    switch Int(event.keyCode) {
    case kVK_Escape:
      closeClipboardHistory()
      return true
    case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space:
      guard let index = panel.highlightedClipboardCandidate else { return true }
      return selectClipboardEntry(index)
    case kVK_LeftArrow:
      return panel.moveClipboardHorizontally(forward: false)
    case kVK_RightArrow:
      return panel.moveClipboardHorizontally(forward: true)
    case kVK_UpArrow, kVK_ANSI_Minus:
      return panel.moveClipboardVertically(up: true)
    case kVK_DownArrow, kVK_ANSI_Equal:
      return panel.moveClipboardVertically(up: false)
    case kVK_PageUp:
      return panel.pageClipboard(up: true)
    case kVK_PageDown:
      return panel.pageClipboard(up: false)
    default:
      let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
      guard modifiers.isEmpty else { return nil }
      if let characters = event.charactersIgnoringModifiers,
         let number = Int(characters),
         number >= 1,
         number <= panel.visibleCandidateCount,
         let candidate = panel.candidateIndex(forVisibleIndex: number - 1) {
        return selectClipboardEntry(candidate)
      }
      return nil
    }
  }

  private func postPasteShortcut(to targetPID: pid_t?) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
      guard let source = CGEventSource(stateID: .hidSystemState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
        NSSound.beep()
        return
      }
      keyDown.flags = .maskCommand
      keyUp.flags = .maskCommand
      if let targetPID {
        keyDown.postToPid(targetPID)
        keyUp.postToPid(targetPID)
      } else {
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
      }
    }
  }

  func show(preedit: String, selRange: NSRange, caretPos: Int) {
    guard let client = client else { return }
    // print("[DEBUG] showPreeditString: '\(preedit)'")
    if self.preedit == preedit && self.caretPos == caretPos && self.selRange == selRange {
      return
    }

    self.preedit = preedit
    self.caretPos = caretPos
    self.selRange = selRange

    // print("[DEBUG] selRange.location = \(selRange.location), selRange.length = \(selRange.length); caretPos = \(caretPos)")
    let start = selRange.location
    let attrString = NSMutableAttributedString(string: preedit)
    if start > 0 {
      let attrs = mark(forStyle: kTSMHiliteConvertedText, at: NSRange(location: 0, length: start))! as! [NSAttributedString.Key: Any]
      attrString.setAttributes(attrs, range: NSRange(location: 0, length: start))
    }
    let remainingRange = NSRange(location: start, length: preedit.utf16.count - start)
    let attrs = mark(forStyle: kTSMHiliteSelectedRawText, at: remainingRange)! as! [NSAttributedString.Key: Any]
    attrString.setAttributes(attrs, range: remainingRange)
    client.setMarkedText(attrString, selectionRange: NSRange(location: caretPos, length: 0), replacementRange: .empty)
  }

  // swiftlint:disable:next function_parameter_count
  func showPanel(preedit: String, selRange: NSRange, caretPos: Int, candidates: [String], comments: [String], labels: [String], candidateOffset: Int, candidateAbsoluteIndices: [Int], highlighted: Int, page: Int, lastPage: Bool) {
    // print("[DEBUG] showPanelWithPreedit:...:")
    guard let client = client else { return }
    var inputPos = NSRect()
    client.attributes(forCharacterIndex: 0, lineHeightRectangle: &inputPos)
    if let panel = NSApp.squirrelAppDelegate.panel {
      panel.position = inputPos
      panel.inputController = self
      panel.update(preedit: preedit, selRange: selRange, caretPos: caretPos, candidates: candidates, comments: comments, labels: labels,
                   candidateOffset: candidateOffset, candidateAbsoluteIndices: candidateAbsoluteIndices,
                   highlighted: highlighted, page: page, lastPage: lastPage, update: true)
    }
  }

  func precedingClientText(limit: Int = 96) -> String {
    guard let client else { return "" }
    let selection = client.selectedRange()
    guard selection.location != NSNotFound, selection.location > 0 else {
      return ""
    }
    let length = min(limit, selection.location)
    let range = NSRange(location: selection.location - length, length: length)
    return client.attributedSubstring(from: range)?.string ?? ""
  }
}
