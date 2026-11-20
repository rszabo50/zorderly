import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Darwin
import ServiceManagement

private struct ProcessSerialNumber {
    var high: UInt32 = 0
    var low: UInt32 = 0
}

private final class PrivateFocus {
    private typealias WindowID = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> Int32
    private typealias ProcessID = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32
    private typealias SetFront = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32) -> Int32
    private typealias PostRecord = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt8>) -> Int32

    private let skyLight: UnsafeMutableRawPointer
    private let windowID: WindowID
    private let processID: ProcessID
    private let setFront: SetFront
    private let postRecord: PostRecord

    init?() {
        guard let framework = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let currentProcess = dlopen(nil, RTLD_NOW),
              let windowSymbol = dlsym(currentProcess, "_AXUIElementGetWindow"),
              let processSymbol = dlsym(currentProcess, "GetProcessForPID"),
              let frontSymbol = dlsym(framework, "_SLPSSetFrontProcessWithOptions"),
              let postSymbol = dlsym(framework, "SLPSPostEventRecordTo") else { return nil }
        skyLight = framework
        windowID = unsafeBitCast(windowSymbol, to: WindowID.self)
        processID = unsafeBitCast(processSymbol, to: ProcessID.self)
        setFront = unsafeBitCast(frontSymbol, to: SetFront.self)
        postRecord = unsafeBitCast(postSymbol, to: PostRecord.self)
    }

    deinit { dlclose(skyLight) }

    func id(for window: AXUIElement) -> UInt32? {
        var id: UInt32 = 0
        return windowID(window, &id) == 0 && id != 0 ? id : nil
    }

    func focus(window: AXUIElement, pid: pid_t) -> String {
        guard let id = id(for: window) else { return "window-id-unavailable" }
        var psn = ProcessSerialNumber()
        let lookup = withUnsafeMutablePointer(to: &psn) { processID(pid, UnsafeMutableRawPointer($0)) }
        guard lookup == 0 else { return "process-serial-number-error:\(lookup)" }

        let front = withUnsafeMutablePointer(to: &psn) { setFront(UnsafeMutableRawPointer($0), id, 0x200) }
        guard front == 0 else { return "set-front-error:\(front)" }

        var event = [UInt8](repeating: 0, count: 0xf8)
        event[0x04] = 0xf8
        event[0x3a] = 0x10
        for index in 0x20..<0x30 { event[index] = 0xff }
        withUnsafeBytes(of: id) { bytes in
            for index in 0..<4 { event[0x3c + index] = bytes[index] }
        }
        event[0x08] = 0x01
        let down = withUnsafeMutablePointer(to: &psn) { pointer in
            event.withUnsafeMutableBufferPointer { bytes in postRecord(UnsafeMutableRawPointer(pointer), bytes.baseAddress!) }
        }
        event[0x08] = 0x02
        let up = withUnsafeMutablePointer(to: &psn) { pointer in
            event.withUnsafeMutableBufferPointer { bytes in postRecord(UnsafeMutableRawPointer(pointer), bytes.baseAddress!) }
        }
        return "window:\(id),front:\(front),down:\(down),up:\(up)"
    }
}

private struct ClickTarget {
    let pid: pid_t
    let windowID: UInt32
    let frame: CGRect
    let isBehind: Bool

    func containsClientPoint(_ point: CGPoint) -> Bool {
        guard isBehind, frame.contains(point) else { return false }
        return point.x >= frame.minX + 7 && point.x <= frame.maxX - 7 &&
            point.y >= frame.minY + 48 && point.y <= frame.maxY - 7
    }
}

private final class ClickRouter {
    private static let marker: Int64 = 0x5A4F524445524C59
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var target: ClickTarget?
    private var targetPoint: CGPoint?
    private var routedPID: pid_t?

    func start() -> Bool {
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                    .rightMouseDown, .rightMouseUp, .rightMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let router = Unmanaged<ClickRouter>.fromOpaque(userInfo).takeUnretainedValue()
                return router.handle(type: type, event: event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        tap = port
        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            tap = nil
            return false
        }
        source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        return true
    }

    func stop() {
        target = nil
        targetPoint = nil
        routedPID = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
    }

    func update(target: ClickTarget?, at point: CGPoint) {
        self.target = target
        targetPoint = point
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker {
            return Unmanaged.passUnretained(event)
        }
        let down = type == .leftMouseDown || type == .rightMouseDown
        let up = type == .leftMouseUp || type == .rightMouseUp
        if down {
            guard let target, let targetPoint,
                  hypot(event.location.x - targetPoint.x, event.location.y - targetPoint.y) < 10,
                  target.containsClientPoint(event.location) else {
                return Unmanaged.passUnretained(event)
            }
            routedPID = target.pid
            fputs("Routing content click to pid=\(target.pid) window=\(target.windowID)\n", stderr)
        }
        guard let pid = routedPID else { return Unmanaged.passUnretained(event) }
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        event.postToPid(pid)
        if up { routedPID = nil }
        return nil
    }
}

struct WindowInfo: Codable {
    let id: Int
    let pid: Int
    let owner: String
    let title: String
    let rank: Int
    let bounds: String
}

struct Snapshot: Codable {
    let activePID: Int?
    let activeApp: String?
    let focusedPID: Int?
    let focusedWindow: String?
    let targetPID: Int?
    let targetWindow: String?
    let topWindows: [WindowInfo]
}

struct Record: Codable {
    let time: String
    let event: String
    let point: String?
    let action: String?
    let axResult: Int?
    let activationAccepted: Bool?
    let snapshot: Snapshot
}

enum FocusMode: String, CaseIterable {
    case observe
    case accessibility
    case activate
    case privateFocus

    var title: String {
        switch self {
        case .observe: "Click to focus (system default)"
        case .accessibility: "AX focus only (diagnostic)"
        case .activate: "Focus follows mouse + auto-raise"
        case .privateFocus: "Focus follows mouse"
        }
    }

    static func saved(_ value: String?) -> FocusMode? {
        guard let value else { return nil }
        if let mode = FocusMode(rawValue: value) { return mode }
        switch value {
        case "Observe only": return .observe
        case "Accessibility focus": return .accessibility
        case "Activate app (raises)": return .activate
        case "Private focus (experimental)": return .privateFocus
        default: return nil
        }
    }
}

final class Probe {
    private let system = AXUIElementCreateSystemWide()
    private let encoder = JSONEncoder()
    private let mode: FocusMode
    private let privateFocus: PrivateFocus?
    private let routeContentClicks: Bool
    private let clickRouter: ClickRouter?
    private var lastTarget: String?
    private var lastPoint: CGPoint?
    private var pending: Timer?
    private var sampleTimer: Timer?
    private var clickMonitor: Any?
    private(set) var isRunning = false

    init(mode: FocusMode, routeContentClicks: Bool) {
        self.mode = mode
        self.privateFocus = mode == .privateFocus ? PrivateFocus() : nil
        self.routeContentClicks = routeContentClicks
        self.clickRouter = routeContentClicks && mode == .privateFocus ? ClickRouter() : nil
        encoder.outputFormatting = [.sortedKeys]
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        lastTarget = nil
        lastPoint = nil
        let trusted = AXIsProcessTrusted()
        fputs("ZOrderly started. Accessibility trusted: \(trusted). Mode: \(mode.title).\n", stderr)
        if !trusted {
            fputs("Grant Accessibility access from Configure before testing focus policies.\n", stderr)
        }
        if mode == .privateFocus && privateFocus == nil {
            fputs("Private focus symbols unavailable; this mode will only observe.\n", stderr)
        }
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.sample()
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.recordClick(event)
        }
        if let clickRouter {
            if clickRouter.start() {
                fputs("Content-click event tap active.\n", stderr)
            } else {
                fputs("Content-click routing unavailable; native clicks will pass through.\n", stderr)
            }
        }
        sample()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        sampleTimer?.invalidate()
        sampleTimer = nil
        pending?.invalidate()
        pending = nil
        clickRouter?.stop()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        lastTarget = nil
        lastPoint = nil
        fputs("ZOrderly stopped.\n", stderr)
    }

    private func recordClick(_ event: NSEvent) {
        let point = CGEvent(source: nil)?.location
        let before = snapshot(targetPID: nil, targetTitle: nil)
        emit(event: "mouse_down_observed", point: point, action: event.type == .leftMouseDown ? "left" : "right", axResult: nil, activation: nil, snapshot: before)
        Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.emit(event: "click_settled", point: point, action: nil, axResult: nil, activation: nil, snapshot: self.snapshot(targetPID: nil, targetTitle: nil))
        }
    }

    private func sample() {
        guard let point = CGEvent(source: nil)?.location else { return }
        if let previous = lastPoint, hypot(point.x - previous.x, point.y - previous.y) < 2 { return }
        lastPoint = point

        var hit: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit)
        guard result == .success, let hit else { return }
        guard let window = enclosingWindow(of: hit) else { return }
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success, pid != getpid() else { return }
        let title = stringAttribute(window, kAXTitleAttribute as CFString) ?? ""
        if let clickRouter, let id = privateFocus?.id(for: window) {
            clickRouter.update(target: clickTarget(windowID: id, pid: pid), at: point)
        }
        let targetKey = "\(pid):\(CFHash(window))"
        guard targetKey != lastTarget else { return }
        lastTarget = targetKey
        pending?.invalidate()

        let before = snapshot(targetPID: pid, targetTitle: title)
        emit(event: "pointer_enter", point: point, action: nil, axResult: nil, activation: nil, snapshot: before)
        guard mode != .observe else { return }

        var action: String
        var axCode: Int?
        var activated: Bool?
        if mode == .privateFocus {
            action = privateFocus?.focus(window: window, pid: pid) ?? "private-symbols-unavailable"
            fputs("Private focus target pid=\(pid): \(action)\n", stderr)
        } else {
            let app = AXUIElementCreateApplication(pid)
            let axResult = AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, window)
            axCode = Int(axResult.rawValue)
            activated = mode == .activate ? (NSRunningApplication(processIdentifier: pid)?.activate(options: []) ?? false) : nil
            action = mode == .activate ? "set focused window; activate app" : "set focused window only"
        }
        emit(event: "focus_request", point: point, action: action, axResult: axCode, activation: activated, snapshot: snapshot(targetPID: pid, targetTitle: title))
        pending = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.emit(event: "settled", point: point, action: nil, axResult: nil, activation: nil, snapshot: self.snapshot(targetPID: pid, targetTitle: title))
        }
    }

    private func clickTarget(windowID: UInt32, pid: pid_t) -> ClickTarget? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let normal = windows.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
        guard let item = normal.first(where: { ($0[kCGWindowNumber as String] as? UInt32) == windowID }),
              let bounds = item[kCGWindowBounds as String] as? [String: Any],
              let x = bounds["X"] as? Double, let y = bounds["Y"] as? Double,
              let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double else { return nil }
        let frontID = normal.first?[kCGWindowNumber as String] as? UInt32
        return ClickTarget(pid: pid, windowID: windowID,
                           frame: CGRect(x: x, y: y, width: width, height: height),
                           isBehind: frontID != windowID)
    }

    private func enclosingWindow(of element: AXUIElement) -> AXUIElement? {
        if let window = elementAttribute(element, kAXWindowAttribute as CFString) { return window }
        var current: AXUIElement? = element
        for _ in 0..<12 {
            guard let candidate = current else { return nil }
            if stringAttribute(candidate, kAXRoleAttribute as CFString) == (kAXWindowRole as String) { return candidate }
            current = elementAttribute(candidate, kAXParentAttribute as CFString)
        }
        return nil
    }

    private func elementAttribute(_ element: AXUIElement, _ name: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func stringAttribute(_ element: AXUIElement, _ name: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value as? String
    }

    private func snapshot(targetPID: pid_t?, targetTitle: String?) -> Snapshot {
        let active = NSWorkspace.shared.frontmostApplication
        var focusedApp: CFTypeRef?
        var focusedPID: pid_t = 0
        var focusedTitle: String?
        if AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &focusedApp) == .success,
           let focusedApp, CFGetTypeID(focusedApp) == AXUIElementGetTypeID() {
            let app = focusedApp as! AXUIElement
            _ = AXUIElementGetPid(app, &focusedPID)
            if let window = elementAttribute(app, kAXFocusedWindowAttribute as CFString) {
                focusedTitle = stringAttribute(window, kAXTitleAttribute as CFString)
            }
        }
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .enumerated().compactMap { index, item -> WindowInfo? in
                guard let layer = item[kCGWindowLayer as String] as? Int, layer == 0,
                      let id = item[kCGWindowNumber as String] as? Int,
                      let pid = item[kCGWindowOwnerPID as String] as? Int else { return nil }
                return WindowInfo(
                    id: id, pid: pid,
                    owner: item[kCGWindowOwnerName as String] as? String ?? "",
                    title: item[kCGWindowName as String] as? String ?? "",
                    rank: index,
                    bounds: String(describing: item[kCGWindowBounds as String] ?? "")
                )
            }
            .prefix(20)
        return Snapshot(
            activePID: active.map { Int($0.processIdentifier) },
            activeApp: active?.localizedName,
            focusedPID: focusedPID == 0 ? nil : Int(focusedPID),
            focusedWindow: focusedTitle,
            targetPID: targetPID.map(Int.init),
            targetWindow: targetTitle,
            topWindows: Array(windows)
        )
    }

    private func emit(event: String, point: CGPoint?, action: String?, axResult: Int?, activation: Bool?, snapshot: Snapshot) {
        let record = Record(
            time: ISO8601DateFormatter().string(from: Date()), event: event,
            point: point.map { "\(Int($0.x)),\(Int($0.y))" }, action: action,
            axResult: axResult, activationAccepted: activation, snapshot: snapshot
        )
        if let data = try? encoder.encode(record), let line = String(data: data, encoding: .utf8) {
            print(line)
            fflush(stdout)
        }
    }
}

final class MenuBarController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let startItem = NSMenuItem(title: "Start", action: #selector(start), keyEquivalent: "")
    private let stopItem = NSMenuItem(title: "Stop", action: #selector(stop), keyEquivalent: "")
    private var modeItems: [NSMenuItem] = []
    private let clickRoutingItem = NSMenuItem(title: "Raise on content click", action: #selector(toggleClickRouting), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleStartAtLogin), keyEquivalent: "")
    private let accessibilityStatus = NSMenuItem(title: "Accessibility access: Required", action: nil, keyEquivalent: "")
    private let accessibilitySettingsItem = NSMenuItem(title: "Open Accessibility Settings…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
    private var mode: FocusMode
    private var routeContentClicks: Bool
    private var probe: Probe

    override init() {
        let oldPreferences = UserDefaults(suiteName: "window-focus-probe")
        if CommandLine.arguments.contains("--private-focus") {
            mode = .privateFocus
        } else if CommandLine.arguments.contains("--activate") {
            mode = .activate
        } else if CommandLine.arguments.contains("--focus") {
            mode = .accessibility
        } else {
            mode = FocusMode.saved(UserDefaults.standard.string(forKey: "focusMode") ?? oldPreferences?.string(forKey: "focusMode")) ?? .observe
        }
        let savedClickRouting = UserDefaults.standard.object(forKey: "routeContentClicks") as? Bool ?? oldPreferences?.bool(forKey: "routeContentClicks") ?? false
        routeContentClicks = CommandLine.arguments.contains("--route-content-clicks") || savedClickRouting
        probe = Probe(mode: mode, routeContentClicks: routeContentClicks)
        super.init()
        statusItem.button?.image = Self.statusIcon()
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.setAccessibilityLabel("ZOrderly")
        startItem.target = self
        stopItem.target = self
        menu.addItem(NSMenuItem(title: "ZOrderly", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(startItem)
        menu.addItem(stopItem)
        let configure = NSMenuItem(title: "Configure", action: nil, keyEquivalent: "")
        let options = NSMenu(title: "Configure")
        options.delegate = self
        let heading = NSMenuItem(title: "Focus policy", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        options.addItem(heading)
        for (index, focusMode) in FocusMode.allCases.enumerated() {
            let item = NSMenuItem(title: focusMode.title, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            options.addItem(item)
            modeItems.append(item)
        }
        options.addItem(.separator())
        clickRoutingItem.target = self
        options.addItem(clickRoutingItem)
        options.addItem(.separator())
        loginItem.target = self
        options.addItem(loginItem)
        options.addItem(.separator())
        accessibilityStatus.isEnabled = false
        options.addItem(accessibilityStatus)
        accessibilitySettingsItem.target = self
        options.addItem(accessibilitySettingsItem)
        configure.submenu = options
        menu.addItem(configure)
        menu.addItem(.separator())
        let exit = NSMenuItem(title: "Exit", action: #selector(exitApp), keyEquivalent: "")
        exit.target = self
        menu.addItem(exit)
        statusItem.menu = menu
        updateMenu()
    }

    private static func statusIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            NSColor.black.setStroke()
            for (x, y, right) in [(2.0, 18.0, 13.0), (4.0, 16.0, 15.0)] {
                let back = NSBezierPath()
                back.lineWidth = 1.4
                back.lineCapStyle = .round
                back.lineJoinStyle = .round
                back.move(to: NSPoint(x: x, y: y - 10))
                back.line(to: NSPoint(x: x, y: y - 1.5))
                back.curve(to: NSPoint(x: x + 1.5, y: y), controlPoint1: NSPoint(x: x, y: y), controlPoint2: NSPoint(x: x, y: y))
                back.line(to: NSPoint(x: right, y: y))
                back.stroke()
            }

            let front = NSBezierPath(roundedRect: NSRect(x: 5.5, y: 2.5, width: 13, height: 11.5), xRadius: 1.7, yRadius: 1.7)
            front.lineWidth = 1.5
            front.stroke()

            let z = NSBezierPath()
            z.lineWidth = 1.45
            z.lineCapStyle = .round
            z.lineJoinStyle = .round
            z.move(to: NSPoint(x: 7.5, y: 10.5))
            z.line(to: NSPoint(x: 11, y: 10.5))
            z.line(to: NSPoint(x: 7.5, y: 5.5))
            z.line(to: NSPoint(x: 11, y: 5.5))
            z.stroke()

            let o = NSBezierPath(ovalIn: NSRect(x: 12.5, y: 5.5, width: 4, height: 5))
            o.lineWidth = 1.45
            o.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    private func updateMenu() {
        startItem.isEnabled = !probe.isRunning
        stopItem.isEnabled = probe.isRunning
        for (index, item) in modeItems.enumerated() {
            item.state = FocusMode.allCases[index] == mode ? .on : .off
        }
        clickRoutingItem.state = routeContentClicks ? .off : .on
        clickRoutingItem.isEnabled = mode == .privateFocus
        loginItem.isEnabled = Bundle.main.bundleURL.pathExtension == "app"
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let trusted = AXIsProcessTrusted()
        accessibilityStatus.title = "Accessibility access: \(trusted ? "Granted" : "Required")"
        accessibilitySettingsItem.isEnabled = !trusted
        statusItem.button?.toolTip = "ZOrderly — \(probe.isRunning ? "running" : "stopped") (\(mode.title))"
    }

    func menuWillOpen(_ menu: NSMenu) { updateMenu() }

    @objc private func start() {
        probe.start()
        updateMenu()
    }

    @objc private func stop() {
        probe.stop()
        updateMenu()
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard FocusMode.allCases.indices.contains(sender.tag) else { return }
        let selected = FocusMode.allCases[sender.tag]
        let wasRunning = probe.isRunning
        probe.stop()
        mode = selected
        UserDefaults.standard.set(selected.rawValue, forKey: "focusMode")
        probe = Probe(mode: selected, routeContentClicks: routeContentClicks)
        if wasRunning { probe.start() }
        updateMenu()
    }

    @objc private func toggleClickRouting() {
        routeContentClicks.toggle()
        UserDefaults.standard.set(routeContentClicks, forKey: "routeContentClicks")
        let wasRunning = probe.isRunning
        probe.stop()
        probe = Probe(mode: mode, routeContentClicks: routeContentClicks)
        if wasRunning { probe.start() }
        updateMenu()
    }

    @objc private func toggleStartAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not update Start at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        updateMenu()
    }

    @objc private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
        updateMenu()
    }

    @objc private func exitApp() {
        probe.stop()
        NSApp.terminate(nil)
    }

    func startFromCommandLine() { start() }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = MenuBarController()
app.delegate = controller
controller.startFromCommandLine()
app.run()
