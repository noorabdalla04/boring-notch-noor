//
//  HomeWidgets.swift
//  boringNotch
//
//  Noor custom: the right-hand side of the open notch is a small pager of
//  widgets -- Calendar, Prayers, Pomodoro -- in that order. It opens on
//  Calendar; a horizontal two-finger swipe (or a click on the dots) moves
//  between pages.
//
//  Only clearly horizontal scrolls over the pager are claimed, one page per
//  gesture. Vertical scrolling passes straight through, so the event list,
//  the day dial's scroll-to-change-date and the notch's own open/close
//  gestures keep working. (Horizontal drags on the day dial now turn pages
//  instead of scrolling days; scrolling vertically or clicking a day still
//  picks the date.)
//
//  Drag the grabber at the bottom edge down (or click it) and the widget
//  expands: the notch grows to 640 x 430 and the current page takes the whole
//  panel, with a richer layout for Prayers and Pomodoro. Drag up, click again,
//  or close the notch to fold it back.
//

import AppKit
import Defaults
import SwiftUI

enum HomeWidgetPage: Int, CaseIterable, Identifiable {
    case calendar, prayers, pomodoro

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .calendar: "Calendar"
        case .prayers: "Prayers"
        case .pomodoro: "Pomodoro"
        }
    }
}

/// Per-gesture bookkeeping for the scroll monitor. A class, so the monitor
/// closure mutates one shared instance rather than a captured copy.
private final class PagerSwipeState {
    var accumulated: CGFloat = 0
    var fired = false
    var lastEvent = Date.distantPast
}

struct HomeWidgetPager: View {
    @EnvironmentObject var vm: BoringViewModel

    @State private var page: HomeWidgetPage = .calendar
    @State private var forward = true
    @State private var isHovering = false
    @State private var monitor: Any?
    @State private var swipe = PagerSwipeState()

    /// Horizontal travel, in points, that turns a page.
    private let threshold: CGFloat = 28

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                pageContent(page)
                    .id(page)
                    .transition(.asymmetric(
                        insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
                    ))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            PageDots(page: page) { go(to: $0) }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onAppear {
            installMonitor()
            PrayerTimesManager.shared.refresh()
        }
        .onDisappear(perform: removeMonitor)
        .onChange(of: vm.notchState) { _, state in
            // Every open starts on Calendar.
            if state == .closed { page = .calendar }
        }
    }

    @ViewBuilder
    private func pageContent(_ page: HomeWidgetPage) -> some View {
        let expanded = vm.isWidgetExpanded
        switch page {
        case .calendar:
            CalendarView().environmentObject(vm)
        case .prayers:
            if expanded { PrayerTimesExpandedView() } else { PrayerTimesPageView() }
        case .pomodoro:
            if expanded { PomodoroExpandedView() } else { PomodoroPageView() }
        }
    }

    private func go(to target: HomeWidgetPage) {
        guard target != page else { return }
        forward = target.rawValue > page.rawValue
        withAnimation(.smooth(duration: 0.28)) { page = target }
        if Defaults[.enableHaptics] {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private func move(by delta: Int) {
        guard let target = HomeWidgetPage(rawValue: page.rawValue + delta) else { return }
        go(to: target)
    }

    // MARK: Swipe

    private func installMonitor() {
        guard monitor == nil else { return }
        let state = swipe
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard isHovering else { return event }

            let now = Date()
            // A new trackpad gesture, or a mouse wheel after a pause, starts fresh.
            if event.phase == .began
                || (event.phase.isEmpty && event.momentumPhase.isEmpty && now.timeIntervalSince(state.lastEvent) > 0.35) {
                state.accumulated = 0
                state.fired = false
            }
            state.lastEvent = now

            let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
            guard abs(dx) > 1.5 * abs(dy) else { return event }   // vertical: not ours

            // Swallow the rest of a horizontal swipe (including momentum) so it
            // can't also scroll whatever is underneath.
            if !event.momentumPhase.isEmpty || state.fired { return nil }

            // Physical finger direction, whatever the natural-scrolling setting.
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
            let fingers = (event.isDirectionInvertedFromDevice ? dx : -dx) * scale
            state.accumulated += fingers

            if state.accumulated <= -threshold {
                state.fired = true
                move(by: 1)        // fingers moved left: next page
            } else if state.accumulated >= threshold {
                state.fired = true
                move(by: -1)       // fingers moved right: previous page
            }
            return nil
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

private struct PageDots: View {
    let page: HomeWidgetPage
    let select: (HomeWidgetPage) -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach(HomeWidgetPage.allCases) { item in
                Button { select(item) } label: {
                    Capsule()
                        .fill(item == page ? Color.white.opacity(0.85) : Color.white.opacity(0.25))
                        .frame(width: item == page ? 12 : 5, height: 5)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.title)
            }
        }
        .animation(.smooth(duration: 0.2), value: page)
        .frame(height: 9)
    }
}

// MARK: - Expanding

/// The open notch when the widget is pulled down: about 2.3x the normal height.
let expandedNotchSize = CGSize(width: openNotchSize.width, height: 430)
let expandedWindowSize = CGSize(width: expandedNotchSize.width, height: expandedNotchSize.height + shadowPadding)

extension BoringViewModel {
    /// Height of the open notch right now, following the grabber while it's dragged.
    var liveOpenNotchHeight: CGFloat {
        let base = isWidgetExpanded ? expandedNotchSize.height : openNotchSize.height
        let low = openNotchSize.height - 24, high = expandedNotchSize.height + 24
        return min(high, max(low, base + widgetDragOffset))
    }

    static let widgetSpring = Animation.spring(response: 0.42, dampingFraction: 0.86)

    /// Make the window tall before anything grows into it.
    func beginWidgetDrag() {
        widgetWindowTall = true
        notchSize = expandedNotchSize   // keeps hover tracking covering the pulled area
    }

    func setWidgetExpanded(_ expanded: Bool) {
        guard notchState == .open else { return }
        widgetWindowTall = true
        withAnimation(Self.widgetSpring) {
            isWidgetExpanded = expanded
            widgetDragOffset = 0
        }
        notchSize = expanded ? expandedNotchSize : openNotchSize
        if Defaults[.enableHaptics] {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        if !expanded {
            // Shrink the window once the fold-back animation has finished.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(550))
                guard let self, !self.isWidgetExpanded, self.widgetDragOffset == 0 else { return }
                self.widgetWindowTall = false
            }
        }
    }
}

/// Keeps the notch window's height in step with the expanded widget, anchored
/// at the top edge of the screen so nothing jumps.
struct WindowHeightSync: NSViewRepresentable {
    let height: CGFloat

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let target = height
        DispatchQueue.main.async {
            guard let window = view.window, abs(window.frame.height - target) > 0.5 else { return }
            var frame = window.frame
            frame.origin.y = frame.maxY - target
            frame.size.height = target
            window.setFrame(frame, display: true)
        }
    }
}

/// The pill at the bottom edge of the open notch: drag down to expand, up to fold.
struct WidgetExpandGrabber: View {
    @EnvironmentObject var vm: BoringViewModel
    @State private var hovering = false
    @State private var dragging = false

    /// How far past the edge a drag has to go to change state.
    private let commitDistance: CGFloat = 50

    var body: some View {
        Capsule()
            .fill(Color.white.opacity(hovering || dragging ? 0.6 : 0.22))
            .frame(width: hovering || dragging ? 46 : 34, height: 4)
            .frame(width: 180, height: 16)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.smooth(duration: 0.18), value: hovering)
            .help(vm.isWidgetExpanded ? "Drag up or click to fold the widget" : "Drag down or click to expand the widget")
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        if !dragging {
                            dragging = true
                            vm.beginWidgetDrag()
                        }
                        vm.widgetDragOffset = value.translation.height
                    }
                    .onEnded { value in
                        dragging = false
                        let travel = value.translation.height
                        let flung = value.predictedEndTranslation.height
                        if vm.isWidgetExpanded {
                            vm.setWidgetExpanded(!(travel < -commitDistance || flung < -commitDistance * 3))
                        } else {
                            vm.setWidgetExpanded(travel > commitDistance || flung > commitDistance * 3)
                        }
                    }
            )
            .onTapGesture {
                vm.beginWidgetDrag()
                vm.setWidgetExpanded(!vm.isWidgetExpanded)
            }
    }
}

// MARK: - Offscreen snapshots (visual checks)

/// Renders the widget pages to PNGs without a display, so their layout can be
/// checked even when the notch's screen is asleep or mirrored. Triggered by the
/// distributed notification "noor.notch.snapshot" (see noor-snapshot.sh).
/// Files land in the app container's tmp/noor-snapshots/.
@MainActor
enum WidgetSnapshots {
    private static var observer: NSObjectProtocol?

    static func install() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("noor.notch.snapshot"), object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await render() }
        }
    }

    static func render() async {
        PrayerTimesManager.shared.refresh()
        try? await Task.sleep(for: .seconds(1.5))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("noor-snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let collapsed = CGSize(width: 215, height: 142)
        let expanded = CGSize(width: expandedNotchSize.width - 62, height: expandedNotchSize.height - 80)
        save(PrayerTimesPageView(), size: collapsed, name: "collapsed-prayers", in: dir)
        save(PomodoroPageView(), size: collapsed, name: "collapsed-pomodoro", in: dir)
        save(PrayerTimesExpandedView(), size: expanded, name: "expanded-prayers", in: dir)
        save(PomodoroExpandedView(), size: expanded, name: "expanded-pomodoro", in: dir)
        NSLog("noor snapshots written to \(dir.path)")
    }

    private static func save<V: View>(_ view: V, size: CGSize, name: String, in dir: URL) {
        let framed = view
            .frame(width: size.width, height: size.height)
            .padding(16)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: dir.appendingPathComponent("\(name).png"))
    }
}
