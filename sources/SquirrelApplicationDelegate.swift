//
//  SquirrelApplicationDelegate.swift
//  Squirrel
//
//  Created by Leo Liu on 5/6/24.
//

import UserNotifications
import AppKit
import ApplicationServices
import Carbon

final class SquirrelApplicationDelegate: NSObject, NSApplicationDelegate {
  static let rimeWikiURL = URL(string: "https://github.com/rime/home/wiki")!
  static let notificationIdentifier = "SquirrelNotification"

  let rimeAPI: RimeApi_stdbool = rime_get_api_stdbool().pointee
  var config: SquirrelConfig?
  var panel: SquirrelPanel?
  let clipboardHistory = ClipboardHistoryManager()
  let candidateReranker = CandidateReranker()
  weak var activeInputController: SquirrelInputController?
  private lazy var globalClipboardHotkey = GlobalClipboardHotkey(delegate: self)
  private var globalClipboardEntries = [ClipboardHistoryEntry]()
  private var globalClipboardTargetPID: pid_t?
  var enableNotifications = false

  func applicationWillFinishLaunching(_ notification: Notification) {
    panel = SquirrelPanel(position: .zero)
    clipboardHistory.start()
    globalClipboardHotkey.start()
    addObservers()
  }

  func applicationWillTerminate(_ notification: Notification) {
    // swiftlint:disable:next notification_center_detachment
    NotificationCenter.default.removeObserver(self)
    DistributedNotificationCenter.default().removeObserver(self)
    clipboardHistory.stop()
    candidateReranker.flush()
    globalClipboardHotkey.stop()
    panel?.hide()
  }

  func handleGlobalClipboardHotkey(_ action: ClipboardHotkeyAction) {
    if action == .open {
      if let activeInputController {
        activeInputController.openClipboardHistoryFromGlobalHotkey()
      } else {
        showGlobalClipboardHistory()
      }
      return
    }

    guard activeInputController == nil,
          let panel,
          panel.clipboardMode else {
      return
    }
    switch action {
    case .escape:
      closeGlobalClipboardHistory()
    case .returnKey, .space:
      if let index = panel.highlightedClipboardCandidate {
        selectGlobalClipboardEntry(index)
      }
    case .left:
      _ = panel.moveClipboardHorizontally(forward: false)
    case .right:
      _ = panel.moveClipboardHorizontally(forward: true)
    case .up, .minus:
      _ = panel.moveClipboardVertically(up: true)
    case .down, .equal:
      _ = panel.moveClipboardVertically(up: false)
    case .pageUp:
      _ = panel.pageClipboard(up: true)
    case .pageDown:
      _ = panel.pageClipboard(up: false)
    default:
      if let number = action.number,
         number <= panel.visibleCandidateCount,
         let index = panel.candidateIndex(forVisibleIndex: number - 1) {
        selectGlobalClipboardEntry(index)
      }
    }
  }

  func deploy() {
    print("Start maintenance...")
    self.shutdownRime()
    self.startRime(fullCheck: true)
    self.loadSettings()
  }

  func syncUserData() {
    print("Sync user data")
    _ = rimeAPI.sync_user_data()
  }

  func openLogFolder() {
    NSWorkspace.shared.open(SquirrelApp.logDir)
  }

  func openRimeFolder() {
    NSWorkspace.shared.open(SquirrelApp.userDir)
  }

  func openWiki() {
    NSWorkspace.shared.open(Self.rimeWikiURL)
  }

  func clipboardPanelAnchor() -> NSRect {
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ??
      NSScreen.main ??
      NSScreen.screens.first
    guard let screen else {
      return NSRect(x: mouse.x, y: mouse.y, width: 1, height: 22)
    }

    let menuBarHeight = max(
      24,
      screen.frame.maxY - screen.visibleFrame.maxY
    )
    return NSRect(
      x: screen.frame.maxX - 14,
      y: screen.frame.maxY - menuBarHeight,
      width: 1,
      height: menuBarHeight
    )
  }

  func ensurePasteAccessibility() -> Bool {
    guard !AXIsProcessTrusted() else { return true }
    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    return false
  }

  static func showMessage(msgText: String?) {
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .provisional]) { _, error in
      if let error = error {
        print("User notification authorization error: \(error.localizedDescription)")
      }
    }
    center.getNotificationSettings { settings in
      if (settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional) && settings.alertSetting == .enabled {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("Squirrel", comment: "")
        if let msgText = msgText {
          content.subtitle = msgText
        }
        content.interruptionLevel = .active
        let request = UNNotificationRequest(identifier: Self.notificationIdentifier, content: content, trigger: nil)
        center.add(request) { error in
          if let error = error {
            print("User notification request error: \(error.localizedDescription)")
          }
        }
      }
    }
  }

  func setupRime() {
    createDirIfNotExist(path: SquirrelApp.userDir)
    createDirIfNotExist(path: SquirrelApp.logDir)
    // swiftlint:disable identifier_name
    let notification_handler: @convention(c) (UnsafeMutableRawPointer?, RimeSessionId, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void = notificationHandler
    let context_object = Unmanaged.passUnretained(self).toOpaque()
    // swiftlint:enable identifier_name
    rimeAPI.set_notification_handler(notification_handler, context_object)

    var squirrelTraits = RimeTraits.rimeStructInit()
    squirrelTraits.setCString(Bundle.main.sharedSupportPath!, to: \.shared_data_dir)
    squirrelTraits.setCString(SquirrelApp.userDir.path(), to: \.user_data_dir)
    squirrelTraits.setCString(SquirrelApp.logDir.path(), to: \.log_dir)
    squirrelTraits.setCString("Squirrel", to: \.distribution_code_name)
    squirrelTraits.setCString("鼠鬚管", to: \.distribution_name)
    squirrelTraits.setCString(Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as! String, to: \.distribution_version)
    squirrelTraits.setCString("rime.squirrel", to: \.app_name)
    rimeAPI.setup(&squirrelTraits)
  }

  func startRime(fullCheck: Bool) {
    print("Initializing la rime...")
    rimeAPI.initialize(nil)
    // check for configuration updates
    if rimeAPI.start_maintenance(fullCheck) {
      // update squirrel config
      // print("[DEBUG] maintenance suceeds")
      _ = rimeAPI.deploy_config_file("squirrel.yaml", "config_version")
    } else {
      // print("[DEBUG] maintenance fails")
    }
  }

  func loadSettings() {
    config = SquirrelConfig()
    if !config!.openBaseConfig() {
      return
    }

    enableNotifications = config!.getString("show_notifications_when") != "never"
    if let panel = panel, let config = self.config {
      panel.load(config: config, forDarkMode: false)
      panel.load(config: config, forDarkMode: true)
    }
  }

  func loadSettings(for schemaID: String) {
    if schemaID.count == 0 || schemaID.first == "." {
      return
    }
    let schema = SquirrelConfig()
    if let panel = panel, let config = self.config {
      if schema.open(schemaID: schemaID, baseConfig: config) && schema.has(section: "style") {
        panel.load(config: schema, forDarkMode: false)
        panel.load(config: schema, forDarkMode: true)
      } else {
        panel.load(config: config, forDarkMode: false)
        panel.load(config: config, forDarkMode: true)
      }
    }
    schema.close()
  }

  // prevent freezing the system
  func problematicLaunchDetected() -> Bool {
    var detected = false
    let logFile = FileManager.default.temporaryDirectory.appendingPathComponent("squirrel_launch.json", conformingTo: .json)
    // print("[DEBUG] archive: \(logFile)")
    do {
      let archive = try Data(contentsOf: logFile, options: [.uncached])
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .millisecondsSince1970
      let previousLaunch = try decoder.decode(Date.self, from: archive)
      if previousLaunch.timeIntervalSinceNow >= -2 {
        detected = true
      }
    } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {

    } catch {
      print("Error occurred during processing launch time archive: \(error.localizedDescription)")
      return detected
    }
    do {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .millisecondsSince1970
      let record = try encoder.encode(Date.now)
      try record.write(to: logFile)
    } catch {
      print("Error occurred during saving launch time to archive: \(error.localizedDescription)")
    }
    return detected
  }

  // add an awakeFromNib item so that we can set the action method.  Note that
  // any menuItems without an action will be disabled when displayed in the Text
  // Input Menu.
  func addObservers() {
    let center = NSWorkspace.shared.notificationCenter
    center.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: nil, using: workspaceWillPowerOff)

    let notifCenter = DistributedNotificationCenter.default()
    notifCenter.addObserver(forName: .init("SquirrelReloadNotification"), object: nil, queue: nil, using: rimeNeedsReload)
    notifCenter.addObserver(forName: .init("SquirrelSyncNotification"), object: nil, queue: nil, using: rimeNeedsSync)
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    print("Squirrel is quitting.")
    rimeAPI.cleanup_all_sessions()
    return .terminateNow
  }

}

private extension SquirrelApplicationDelegate {
  func showGlobalClipboardHistory() {
    globalClipboardEntries = clipboardHistory.currentEntries()
    guard !globalClipboardEntries.isEmpty, let panel else {
      NSSound.beep()
      return
    }

    globalClipboardTargetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
    _ = ensurePasteAccessibility()

    panel.position = clipboardPanelAnchor()
    panel.inputController = nil
    panel.clipboardSelectionHandler = { [weak self] index in
      self?.selectGlobalClipboardEntry(index)
    }
    panel.showClipboard(globalClipboardEntries.map(\.displayTitle))
    globalClipboardHotkey.beginNavigation()
  }

  func closeGlobalClipboardHistory() {
    globalClipboardHotkey.endNavigation()
    globalClipboardEntries.removeAll()
    panel?.clipboardSelectionHandler = nil
    panel?.hideClipboard()
  }

  func selectGlobalClipboardEntry(_ index: Int) {
    guard index >= 0, index < globalClipboardEntries.count else { return }
    let entry = globalClipboardEntries[index]
    let targetPID = globalClipboardTargetPID
    guard clipboardHistory.restore(entry) else {
      NSSound.beep()
      return
    }
    closeGlobalClipboardHistory()
    globalClipboardTargetPID = nil
    postGlobalPasteShortcut(to: targetPID)
  }

  func postGlobalPasteShortcut(to targetPID: pid_t?) {
    guard ensurePasteAccessibility() else {
      NSSound.beep()
      return
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
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
}

private func notificationHandler(contextObject: UnsafeMutableRawPointer?, sessionId: RimeSessionId, messageTypeC: UnsafePointer<CChar>?, messageValueC: UnsafePointer<CChar>?) {
  let delegate: SquirrelApplicationDelegate = Unmanaged<SquirrelApplicationDelegate>.fromOpaque(contextObject!).takeUnretainedValue()

  let messageType = messageTypeC.map { String(cString: $0) }
  let messageValue = messageValueC.map { String(cString: $0) }
  if messageType == "deploy" {
    switch messageValue {
    case "start":
      SquirrelApplicationDelegate.showMessage(msgText: NSLocalizedString("deploy_start", comment: ""))
    case "success":
      SquirrelApplicationDelegate.showMessage(msgText: NSLocalizedString("deploy_success", comment: ""))
    case "failure":
      SquirrelApplicationDelegate.showMessage(msgText: NSLocalizedString("deploy_failure", comment: ""))
    default:
      break
    }
    return
  }
  // off
  if !delegate.enableNotifications {
    return
  }

  if messageType == "schema", let messageValue = messageValue, let schemaName = try? /^[^\/]*\/(.*)$/.firstMatch(in: messageValue)?.output.1 {
    delegate.showStatusMessage(msgTextLong: String(schemaName), msgTextShort: String(schemaName))
    return
  } else if messageType == "option" {
    let state = messageValue?.first != "!"
    let optionName = if state {
      messageValue
    } else {
      String(messageValue![messageValue!.index(after: messageValue!.startIndex)...])
    }
    if let optionName = optionName {
      optionName.withCString { name in
        let stateLabelLong = delegate.rimeAPI.get_state_label_abbreviated(sessionId, name, state, false)
        let stateLabelShort = delegate.rimeAPI.get_state_label_abbreviated(sessionId, name, state, true)
        let longLabel = stateLabelLong.str.map { String(cString: $0) }
        let shortLabel = stateLabelShort.str.map { String(cString: $0) }
        delegate.showStatusMessage(msgTextLong: longLabel, msgTextShort: shortLabel)
      }
    }
  }

}

private extension SquirrelApplicationDelegate {
  func showStatusMessage(msgTextLong: String?, msgTextShort: String?) {
    if !(msgTextLong ?? "").isEmpty || !(msgTextShort ?? "").isEmpty {
      panel?.updateStatus(long: msgTextLong ?? "", short: msgTextShort ?? "")
    }
  }

  func shutdownRime() {
    config?.close()
    rimeAPI.finalize()
  }

  func workspaceWillPowerOff(_: Notification) {
    print("Finalizing before logging out.")
    self.shutdownRime()
  }

  func rimeNeedsReload(_: Notification) {
    print("Reloading rime on demand.")
    self.deploy()
  }

  func rimeNeedsSync(_: Notification) {
    print("Sync rime on demand.")
    self.syncUserData()
  }

  func createDirIfNotExist(path: URL) {
    let fileManager = FileManager.default
    if !fileManager.fileExists(atPath: path.path()) {
      do {
        try fileManager.createDirectory(at: path, withIntermediateDirectories: true)
      } catch {
        print("Error creating user data directory: \(path.path())")
      }
    }
  }
}

extension NSApplication {
  var squirrelAppDelegate: SquirrelApplicationDelegate {
    self.delegate as! SquirrelApplicationDelegate
  }
}
