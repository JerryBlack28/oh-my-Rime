//
//  GlobalClipboardHotkey.swift
//  Squirrel
//

import Carbon

enum ClipboardHotkeyAction: UInt32 {
  case open = 1
  case escape = 2
  case returnKey = 3
  case space = 4
  case left = 5
  case right = 6
  case up = 7
  case down = 8
  case pageUp = 9
  case pageDown = 10
  case minus = 11
  case equal = 12
  case number1 = 21
  case number2 = 22
  case number3 = 23
  case number4 = 24
  case number5 = 25
  case number6 = 26
  case number7 = 27
  case number8 = 28
  case number9 = 29

  var number: Int? {
    guard rawValue >= Self.number1.rawValue, rawValue <= Self.number9.rawValue else {
      return nil
    }
    return Int(rawValue - Self.number1.rawValue + 1)
  }
}

final class GlobalClipboardHotkey {
  fileprivate static let signature: OSType = 0x5351434C // "SQCL"
  private weak var delegate: SquirrelApplicationDelegate?
  private var eventHandler: EventHandlerRef?
  private var openHotKey: EventHotKeyRef?
  private var navigationHotKeys = [EventHotKeyRef]()

  init(delegate: SquirrelApplicationDelegate) {
    self.delegate = delegate
  }

  func start() {
    guard eventHandler == nil else { return }
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    let context = Unmanaged.passUnretained(self).toOpaque()
    let status = InstallEventHandler(
      GetApplicationEventTarget(),
      globalClipboardHotKeyHandler,
      1,
      &eventType,
      context,
      &eventHandler
    )
    guard status == noErr else {
      print("Unable to install global clipboard hotkey handler: \(status)")
      return
    }

    var reference: EventHotKeyRef?
    let hotKeyID = EventHotKeyID(signature: Self.signature, id: ClipboardHotkeyAction.open.rawValue)
    let registerStatus = RegisterEventHotKey(
      UInt32(kVK_ANSI_V),
      UInt32(controlKey | shiftKey),
      hotKeyID,
      GetApplicationEventTarget(),
      0,
      &reference
    )
    if registerStatus == noErr {
      openHotKey = reference
    } else {
      print("Unable to register global clipboard shortcut: \(registerStatus)")
    }
  }

  func stop() {
    endNavigation()
    if let openHotKey {
      UnregisterEventHotKey(openHotKey)
      self.openHotKey = nil
    }
    if let eventHandler {
      RemoveEventHandler(eventHandler)
      self.eventHandler = nil
    }
  }

  func beginNavigation() {
    guard navigationHotKeys.isEmpty else { return }
    let registrations: [(ClipboardHotkeyAction, Int)] = [
      (.escape, kVK_Escape),
      (.returnKey, kVK_Return),
      (.space, kVK_Space),
      (.left, kVK_LeftArrow),
      (.right, kVK_RightArrow),
      (.up, kVK_UpArrow),
      (.down, kVK_DownArrow),
      (.pageUp, kVK_PageUp),
      (.pageDown, kVK_PageDown),
      (.minus, kVK_ANSI_Minus),
      (.equal, kVK_ANSI_Equal),
      (.number1, kVK_ANSI_1),
      (.number2, kVK_ANSI_2),
      (.number3, kVK_ANSI_3),
      (.number4, kVK_ANSI_4),
      (.number5, kVK_ANSI_5),
      (.number6, kVK_ANSI_6),
      (.number7, kVK_ANSI_7),
      (.number8, kVK_ANSI_8),
      (.number9, kVK_ANSI_9)
    ]

    for (action, keyCode) in registrations {
      var reference: EventHotKeyRef?
      let hotKeyID = EventHotKeyID(signature: Self.signature, id: action.rawValue)
      let status = RegisterEventHotKey(
        UInt32(keyCode),
        0,
        hotKeyID,
        GetApplicationEventTarget(),
        0,
        &reference
      )
      if status == noErr, let reference {
        navigationHotKeys.append(reference)
      } else {
        print("Unable to register clipboard navigation key \(action): \(status)")
      }
    }
  }

  func endNavigation() {
    navigationHotKeys.forEach { UnregisterEventHotKey($0) }
    navigationHotKeys.removeAll()
  }

  fileprivate func handle(action: ClipboardHotkeyAction) {
    delegate?.handleGlobalClipboardHotkey(action)
  }
}

private let globalClipboardHotKeyHandler: EventHandlerUPP = { _, event, context in
  guard let event, let context else { return OSStatus(eventNotHandledErr) }
  var hotKeyID = EventHotKeyID()
  let status = GetEventParameter(
    event,
    EventParamName(kEventParamDirectObject),
    EventParamType(typeEventHotKeyID),
    nil,
    MemoryLayout<EventHotKeyID>.size,
    nil,
    &hotKeyID
  )
  guard status == noErr,
        hotKeyID.signature == GlobalClipboardHotkey.signature,
        let action = ClipboardHotkeyAction(rawValue: hotKeyID.id) else {
    return OSStatus(eventNotHandledErr)
  }
  let manager = Unmanaged<GlobalClipboardHotkey>.fromOpaque(context).takeUnretainedValue()
  manager.handle(action: action)
  return noErr
}
