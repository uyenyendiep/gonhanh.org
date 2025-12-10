import Foundation
import Carbon
import AppKit

// MARK: - Debug Logging

/// Smart debug logging - only active when /tmp/gonhanh_debug.log exists
/// Enable: touch /tmp/gonhanh_debug.log
/// Disable: rm /tmp/gonhanh_debug.log
private enum Log {
    private static let logPath = "/tmp/gonhanh_debug.log"
    private static var isEnabled: Bool { FileManager.default.fileExists(atPath: logPath) }

    private static func write(_ msg: String) {
        guard isEnabled, let handle = FileHandle(forWritingAtPath: logPath) else { return }
        let ts = String(format: "%02d:%02d:%02d.%03d",
                        Calendar.current.component(.hour, from: Date()),
                        Calendar.current.component(.minute, from: Date()),
                        Calendar.current.component(.second, from: Date()),
                        Calendar.current.component(.nanosecond, from: Date()) / 1_000_000)
        handle.seekToEndOfFile()
        handle.write("[\(ts)] \(msg)\n".data(using: .utf8)!)
        handle.closeFile()
    }

    // Concise log methods
    static func key(_ code: UInt16, _ result: String) { write("K:\(code) → \(result)") }
    static func transform(_ bs: Int, _ chars: String) { write("T: ←\(bs) \"\(chars)\"") }
    static func send(_ method: String, _ bs: Int, _ chars: String) { write("S:\(method) ←\(bs) \"\(chars)\"") }
    static func method(_ name: String) { write("M: \(name)") }
    static func ax(_ role: String?, _ app: String) { write("AX: \(role ?? "?") @\(app.split(separator: ".").last ?? "")") }
    static func event(_ msg: String) { write("E: \(msg)") }
    static func info(_ msg: String) { write("I: \(msg)") }
    static func skip() { write("K: skip (self)") }
}

// MARK: - FFI (Rust Bridge)

/// FFI Result struct - must match Rust #[repr(C)]
private struct ImeResult {
    var chars: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
                UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
                UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
                UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32)
    var action: UInt8      // 0=None, 1=Send, 2=Restore
    var backspace: UInt8
    var count: UInt8
    var _pad: UInt8
}

@_silgen_name("ime_init") private func ime_init()
@_silgen_name("ime_key_ext") private func ime_key_ext(_ key: UInt16, _ caps: Bool, _ ctrl: Bool, _ shift: Bool) -> UnsafeMutablePointer<ImeResult>?
@_silgen_name("ime_method") private func ime_method(_ method: UInt8)
@_silgen_name("ime_enabled") private func ime_enabled(_ enabled: Bool)
@_silgen_name("ime_clear") private func ime_clear()
@_silgen_name("ime_free") private func ime_free(_ result: UnsafeMutablePointer<ImeResult>?)

// MARK: - RustBridge (Public API)

class RustBridge {
    private static var isInitialized = false

    static func initialize() {
        guard !isInitialized else { return }
        ime_init()
        isInitialized = true
        Log.info("Engine initialized")
    }

    /// Process key → (backspaceCount, newChars) or nil
    static func processKey(keyCode: UInt16, caps: Bool, ctrl: Bool, shift: Bool = false) -> (Int, [Character])? {
        guard isInitialized, let ptr = ime_key_ext(keyCode, caps, ctrl, shift) else { return nil }
        defer { ime_free(ptr) }

        let r = ptr.pointee
        guard r.action == 1 else { return nil }  // 1 = Send

        let chars = withUnsafePointer(to: r.chars) { p in
            p.withMemoryRebound(to: UInt32.self, capacity: 32) { bound in
                (0..<Int(r.count)).compactMap { Unicode.Scalar(bound[$0]).map(Character.init) }
            }
        }
        return (Int(r.backspace), chars)
    }

    static func setMethod(_ method: Int) {
        ime_method(UInt8(method))
        Log.info("Method: \(method == 0 ? "Telex" : "VNI")")
    }

    static func setEnabled(_ enabled: Bool) {
        ime_enabled(enabled)
        Log.info("Enabled: \(enabled)")
    }

    static func clearBuffer() { ime_clear() }
}

// MARK: - Keyboard Hook Manager

class KeyboardHookManager {
    static let shared = KeyboardHookManager()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isRunning = false

    private init() {}

    func start() {
        guard !isRunning else { return }

        guard AXIsProcessTrusted() else {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
            Log.info("Requesting accessibility permission")
            return
        }

        RustBridge.initialize()

        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                    options: .defaultTap, eventsOfInterest: mask,
                                    callback: keyboardCallback, userInfo: nil)
            ?? CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                 options: .defaultTap, eventsOfInterest: mask,
                                 callback: keyboardCallback, userInfo: nil)

        guard let tap = tap else {
            showAccessibilityAlert()
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            isRunning = true
            Log.info("Hook started")
        }
    }

    func stop() {
        guard isRunning else { return }
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes) }
        eventTap = nil
        runLoopSource = nil
        isRunning = false
        Log.info("Hook stopped")
    }

    func getTap() -> CFMachPort? { eventTap }

    private func showAccessibilityAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Cần quyền Accessibility"
            alert.informativeText = "GoNhanh cần quyền Accessibility để gõ tiếng Việt.\n\n1. Mở System Settings > Privacy & Security > Accessibility\n2. Bật GoNhanh\n3. Khởi động lại app"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Mở System Settings")
            alert.addButton(withTitle: "Hủy")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
        }
    }
}

// MARK: - Keyboard Callback

private let kEventMarker: Int64 = 0x474E4820  // "GNH " - marks self-generated events

private func keyboardCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {

    // Re-enable if disabled
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = KeyboardHookManager.shared.getTap() { CGEvent.tapEnable(tap: tap, enable: true) }
        Log.event("tap re-enabled")
        return Unmanaged.passUnretained(event)
    }

    guard type == .keyDown else { return Unmanaged.passUnretained(event) }

    // Skip self-generated events
    if event.getIntegerValueField(.eventSourceUserData) == kEventMarker {
        Log.skip()
        return Unmanaged.passUnretained(event)
    }

    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags

    // Ctrl+Space = toggle Vietnamese
    if keyCode == 0x31 && flags.contains(.maskControl) && !flags.contains(.maskCommand) {
        DispatchQueue.main.async { NotificationCenter.default.post(name: .toggleVietnamese, object: nil) }
        return nil
    }

    let shift = flags.contains(.maskShift)
    let caps = shift || flags.contains(.maskAlphaShift)
    let ctrl = flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate)

    if let (bs, chars) = RustBridge.processKey(keyCode: keyCode, caps: caps, ctrl: ctrl, shift: shift) {
        let str = String(chars)
        Log.transform(bs, str)
        sendReplacement(backspace: bs, chars: chars)
        return nil
    }

    Log.key(keyCode, "pass")
    return Unmanaged.passUnretained(event)
}

// MARK: - Text Replacement

private enum Method { case fast, slow, selection }

private func detectMethod() -> Method {
    guard let app = NSWorkspace.shared.frontmostApplication,
          let bundleId = app.bundleIdentifier else { return .fast }

    // Try to get AX role
    let systemWide = AXUIElementCreateSystemWide()
    var focused: CFTypeRef?
    var role: String?

    if AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
       let el = focused {
        var roleVal: CFTypeRef?
        AXUIElementCopyAttributeValue(el as! AXUIElement, kAXRoleAttribute as CFString, &roleVal)
        role = roleVal as? String
    }

    let shortId = bundleId.split(separator: ".").last.map(String.init) ?? bundleId
    Log.ax(role, shortId)

    // Selection method for autocomplete contexts
    if role == "AXComboBox" { Log.method("sel:combo"); return .selection }

    let browsers = ["com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser"]
    if browsers.contains(bundleId) && role == "AXTextField" { Log.method("sel:browser"); return .selection }

    if role == "AXTextField" && bundleId.hasPrefix("com.jetbrains") { Log.method("sel:jb"); return .selection }
    if bundleId == "com.microsoft.Excel" { Log.method("sel:excel"); return .selection }
    if bundleId == "com.microsoft.Word" { Log.method("sel:word"); return .selection }

    // Slow method for terminal apps
    let terminals = ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.apple.Terminal",
                     "com.googlecode.iterm2", "io.alacritty", "com.github.wez.wezterm",
                     "com.google.antigravity", "dev.warp.Warp-Stable"]
    if terminals.contains(bundleId) { Log.method("slow:term"); return .slow }

    Log.method("fast")
    return .fast
}

private func sendReplacement(backspace bs: Int, chars: [Character]) {
    let method = detectMethod()
    let str = String(chars)

    switch method {
    case .selection: sendWithSelection(bs: bs, str: str)
    case .slow:      sendWithBackspace(bs: bs, str: str, delayMs: (1500, 3000, 2000))
    case .fast:      sendWithBackspace(bs: bs, str: str, delayMs: (200, 800, 500))
    }
}

private func sendWithBackspace(bs: Int, str: String, delayMs: (UInt32, UInt32, UInt32)) {
    guard let src = CGEventSource(stateID: .privateState) else { return }

    // Send backspaces
    for _ in 0..<bs {
        guard let dn = CGEvent(keyboardEventSource: src, virtualKey: 0x33, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 0x33, keyDown: false) else { continue }
        dn.setIntegerValueField(.eventSourceUserData, value: kEventMarker)
        up.setIntegerValueField(.eventSourceUserData, value: kEventMarker)
        dn.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        usleep(delayMs.0)
    }

    if bs > 0 { usleep(delayMs.1) }

    // Send unicode
    let utf16 = Array(str.utf16)
    guard let dn = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
          let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { return }
    dn.setIntegerValueField(.eventSourceUserData, value: kEventMarker)
    up.setIntegerValueField(.eventSourceUserData, value: kEventMarker)
    dn.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
    up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
    dn.post(tap: .cgSessionEventTap)
    up.post(tap: .cgSessionEventTap)
    usleep(delayMs.2)

    Log.send("bs", bs, str)
}

private func sendWithSelection(bs: Int, str: String) {
    guard let src = CGEventSource(stateID: .privateState) else { return }

    // Select with Shift+Left
    for _ in 0..<bs {
        guard let dn = CGEvent(keyboardEventSource: src, virtualKey: 0x7B, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 0x7B, keyDown: false) else { continue }
        dn.setIntegerValueField(.eventSourceUserData, value: kEventMarker)
        up.setIntegerValueField(.eventSourceUserData, value: kEventMarker)
        dn.flags = .maskShift
        up.flags = .maskShift
        dn.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    // Replace selection
    let utf16 = Array(str.utf16)
    guard let dn = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
          let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { return }
    dn.setIntegerValueField(.eventSourceUserData, value: kEventMarker)
    up.setIntegerValueField(.eventSourceUserData, value: kEventMarker)
    dn.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
    up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
    dn.post(tap: .cgSessionEventTap)
    up.post(tap: .cgSessionEventTap)

    Log.send("sel", bs, str)
}

// MARK: - Notifications

extension Notification.Name {
    static let toggleVietnamese = Notification.Name("toggleVietnamese")
}
