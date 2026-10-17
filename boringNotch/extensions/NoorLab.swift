//
//  NoorLab.swift
//  boringNotch
//
//  Noor custom: a sandbox for working on the notch UI without touching the real
//  notch or Noor's screen.
//
//  Launched as a second process with `-NoorLab YES -menubarIcon NO` (see
//  noor-lab.sh), the app skips its normal start-up and instead hosts one
//  ContentView, open, in a window kept behind the desktop picture: drawn and
//  capturable, never visible, never in the way of the mouse. Commands arrive as
//  the distributed notification "noor.lab" (the command is the object string):
//
//    open | close | state | quit
//    expand | collapse              call the view model directly
//    page N                         switch the home widget page
//    click X Y                      left click, window points from the top-left
//    drag X1 Y1 X2 Y2 [STEPS]       press, drag, release
//    scroll X Y DY [STEPS]          two-finger scroll (positive DY = down)
//    hold X1 Y1 X2 Y2               press and drag, without releasing
//    release X Y
//    move X Y                       pointer moves there (drives hover)
//    wait MS
//
//  Each command appends "ok <command>" (and `state` a JSON line) to lab.log in
//  the container's tmp/noor-lab/; window-id there holds the window number for
//  `screencapture -l`.
//

import AppKit
import Defaults
import SwiftUI

@MainActor
enum NoorLab {
    nonisolated static var isRequested: Bool { UserDefaults.standard.bool(forKey: "NoorLab") }

    private static var window: NSWindow?
    private static var vm: BoringViewModel?
    private static var observer: NSObjectProtocol?
    private static var queue: [String] = []
    private static var running = false

    static let dir = FileManager.default.temporaryDirectory.appendingPathComponent("noor-lab", isDirectory: true)

    static func start(camera: CameraModel) {
        NSApp.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? "".write(to: dir.appendingPathComponent("lab.log"), atomically: true, encoding: .utf8)

        let vm = BoringViewModel(camera: camera)
        // No screen is attached to the lab's view model, so nothing would ever
        // un-hide the closed notch; show it like the real notch does.
        vm.hideOnClosed = false
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: expandedWindowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true          // the real mouse never reaches it
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        // Behind the desktop picture: composited and capturable, never seen.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        panel.contentView = NSHostingView(rootView: ContentView().environmentObject(vm))
        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.frame.midX - panel.frame.width / 2,
                                         y: screen.frame.maxY - panel.frame.height))
        }
        panel.orderFrontRegardless()
        window = panel
        self.vm = vm

        try? String(panel.windowNumber).write(to: dir.appendingPathComponent("window-id"), atomically: true, encoding: .utf8)

        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("noor.lab"), object: nil, queue: .main
        ) { note in
            let command = note.object as? String ?? ""
            Task { @MainActor in enqueue(command) }
        }
        if UserDefaults.standard.bool(forKey: "NoorLabTraceScroll") {
            _ = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                log("scroll window=\(event.window?.windowNumber ?? -1) dy=\(event.scrollingDeltaY) phase=\(event.phase.rawValue) precise=\(event.hasPreciseScrollingDeltas)")
                return event
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { _ = vm.open() }
        log("ready \(panel.windowNumber)")
    }

    // MARK: Commands

    private static func enqueue(_ command: String) {
        queue.append(command)
        guard !running else { return }
        running = true
        Task { @MainActor in
            while !queue.isEmpty {
                let next = queue.removeFirst()
                await run(next)
                log("ok \(next)")
            }
            running = false
        }
    }

    private static func run(_ command: String) async {
        guard let vm, let window else { return }
        let parts = command.split(separator: " ").map(String.init)
        let n = parts.dropFirst().compactMap { Double($0) }
        switch parts.first ?? "" {
        case "open": _ = vm.open()
        case "close": vm.close()
        case "expand": vm.setWidgetExpanded(true)
        case "collapse": vm.setWidgetExpanded(false)
        case "page": HomeWidgetState.shared.select(Int(n.first ?? 0))
        case "wait": try? await Task.sleep(for: .milliseconds(Int(n.first ?? 100)))
        case "click" where n.count >= 2:
            await mouse(.leftMouseDown, at: CGPoint(x: n[0], y: n[1]), in: window)
            await mouse(.leftMouseUp, at: CGPoint(x: n[0], y: n[1]), in: window)
        case "drag" where n.count >= 4:
            await drag(from: CGPoint(x: n[0], y: n[1]), to: CGPoint(x: n[2], y: n[3]), steps: Int(n.count > 4 ? n[4] : 12), release: true, in: window)
        case "hold" where n.count >= 4:
            await drag(from: CGPoint(x: n[0], y: n[1]), to: CGPoint(x: n[2], y: n[3]), steps: 12, release: false, in: window)
        case "move" where n.count >= 2:
            await mouse(.mouseMoved, at: CGPoint(x: n[0], y: n[1]), in: window)
        case "release" where n.count >= 2:
            await mouse(.leftMouseUp, at: CGPoint(x: n[0], y: n[1]), in: window)
        case "scroll" where n.count >= 3:
            await scroll(at: CGPoint(x: n[0], y: n[1]), dy: n[2], steps: Int(n.count > 3 ? n[3] : 10), in: window)
        case "state": log("state " + state(vm))
        case "quit": NSApp.terminate(nil)
        default: log("unknown \(command)")
        }
        // Let SwiftUI settle before the next command or a capture.
        try? await Task.sleep(for: .milliseconds(60))
    }

    /// Points are window points from the top-left, as screenshots read. They're
    /// converted per event, because the window grows (top-anchored) mid-gesture
    /// and a real pointer's position in it would follow.
    private static func windowPoint(_ p: CGPoint, in window: NSWindow) -> NSPoint {
        NSPoint(x: p.x, y: window.frame.height - p.y)
    }

    private static func mouse(_ type: NSEvent.EventType, at p: CGPoint, in window: NSWindow) async {
        guard let event = NSEvent.mouseEvent(
            with: type, location: windowPoint(p, in: window), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
        ) else { return }
        NSApp.postEvent(event, atStart: false)
        try? await Task.sleep(for: .milliseconds(16))
    }

    private static func drag(from a: CGPoint, to b: CGPoint, steps: Int, release: Bool, in window: NSWindow) async {
        await mouse(.leftMouseDown, at: a, in: window)
        for i in 1...max(1, steps) {
            let t = Double(i) / Double(max(1, steps))
            await mouse(.leftMouseDragged, at: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), in: window)
        }
        if release { await mouse(.leftMouseUp, at: b, in: window) }
    }

    /// A trackpad-style scroll: began, changed..., ended, aimed at the lab window.
    private static func scroll(at p: CGPoint, dy: Double, steps: Int, in window: NSWindow) async {
        let screenPoint = window.convertPoint(toScreen: windowPoint(p, in: window))
        let flipped = CGPoint(x: screenPoint.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screenPoint.y)
        let count = max(1, steps)
        for i in 0...count {
            let delta = i == count ? 0 : -dy / Double(count)   // natural scrolling: content follows fingers
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                   wheel1: Int32(delta), wheel2: 0, wheel3: 0) else { continue }
            cg.location = flipped
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase,
                                    value: Int64(i == 0 ? 1 : (i == count ? 4 : 2)))  // began / changed / ended
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
            if let event = NSEvent(cgEvent: cg) { NSApp.postEvent(event, atStart: false) }
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    private static func state(_ vm: BoringViewModel) -> String {
        let fields: [String: Any] = [
            "notch": vm.notchState == .open ? "open" : "closed",
            "expanded": vm.isWidgetExpanded,
            "dragOffset": Double(vm.widgetDragOffset),
            "dragging": vm.isDraggingWidget,
            "notchHeight": Double(vm.notchSize.height),
            "windowHeight": Double(window?.frame.height ?? 0),
            "page": HomeWidgetState.shared.page.rawValue,
            "hoveringCalendar": vm.isHoveringCalendar,
            "pomodoro": PomodoroManager.shared.isRunning ? "running" : (PomodoroManager.shared.isPaused ? "paused" : "idle"),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func log(_ line: String) {
        let url = dir.appendingPathComponent("lab.log")
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        try? handle.close()
    }
}
