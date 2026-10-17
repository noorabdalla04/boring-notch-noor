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
//  Pulling the notch down expands it to 640 x 430: the music player stays where
//  it is, the Pomodoro and Prayers cards fill the space under it, and the
//  calendar runs the full height on the right. Pull down by dragging the strip
//  along the bottom edge, clicking it, or two-finger scrolling down outside the
//  calendar; fold it back the same ways (or close the notch).
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

/// Which page the pager shows. Shared, so the page survives layout changes.
@MainActor
final class HomeWidgetState: ObservableObject {
    static let shared = HomeWidgetState()

    @Published private(set) var page: HomeWidgetPage = .calendar
    /// Direction of the last page turn, for the slide transition.
    @Published private(set) var forward = true

    func select(_ index: Int) {
        guard let target = HomeWidgetPage(rawValue: index) else { return }
        go(to: target)
    }

    func go(to target: HomeWidgetPage, animated: Bool = true) {
        guard target != page else { return }
        forward = target.rawValue > page.rawValue
        if animated {
            withAnimation(.smooth(duration: 0.28)) { page = target }
        } else {
            page = target
        }
        if animated && Defaults[.enableHaptics] {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    func move(by delta: Int) {
        if let target = HomeWidgetPage(rawValue: page.rawValue + delta) { go(to: target) }
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
    @ObservedObject private var state = HomeWidgetState.shared

    @State private var isHovering = false
    @State private var monitor: Any?
    @State private var swipe = PagerSwipeState()

    /// Horizontal travel, in points, that turns a page.
    private let threshold: CGFloat = 28

    var body: some View {
        VStack(spacing: 3) {
            if vm.isWidgetExpanded {
                // Expanded: Pomodoro and Prayers live under the music player,
                // so this column is the calendar, full height.
                CalendarView().environmentObject(vm)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ZStack {
                    pageContent(state.page)
                        .id(state.page)
                        .transition(.asymmetric(
                            insertion: .move(edge: state.forward ? .trailing : .leading).combined(with: .opacity),
                            removal: .move(edge: state.forward ? .leading : .trailing).combined(with: .opacity)
                        ))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                PageDots(page: state.page) { state.go(to: $0) }
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onAppear {
            installMonitor()
            PrayerTimesManager.shared.refresh()
        }
        .onDisappear(perform: removeMonitor)
        .onChange(of: vm.notchState) { _, notchState in
            // Every open starts on Calendar.
            if notchState == .closed { state.go(to: .calendar, animated: false) }
        }
    }

    @ViewBuilder
    private func pageContent(_ page: HomeWidgetPage) -> some View {
        switch page {
        case .calendar:
            CalendarView().environmentObject(vm)
        case .prayers:
            PrayerTimesPageView()
        case .pomodoro:
            PomodoroPageView()
        }
    }

    // MARK: Swipe

    private func installMonitor() {
        guard monitor == nil else { return }
        let swipe = swipe
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard isHovering, !vm.isWidgetExpanded else { return event }

            let now = Date()
            // A new trackpad gesture, or a mouse wheel after a pause, starts fresh.
            if event.phase == .began
                || (event.phase.isEmpty && event.momentumPhase.isEmpty && now.timeIntervalSince(swipe.lastEvent) > 0.35) {
                swipe.accumulated = 0
                swipe.fired = false
            }
            swipe.lastEvent = now

            let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
            guard abs(dx) > 1.5 * abs(dy) else { return event }   // vertical: not ours

            // Swallow the rest of a horizontal swipe (including momentum) so it
            // can't also scroll whatever is underneath.
            if !event.momentumPhase.isEmpty || swipe.fired { return nil }

            // Physical finger direction, whatever the natural-scrolling setting.
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
            let fingers = (event.isDirectionInvertedFromDevice ? dx : -dx) * scale
            swipe.accumulated += fingers

            if swipe.accumulated <= -threshold {
                swipe.fired = true
                state.move(by: 1)        // fingers moved left: next page
            } else if swipe.accumulated >= threshold {
                swipe.fired = true
                state.move(by: -1)       // fingers moved right: previous page
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

/// What fills the space under the music player when the notch is pulled down.
struct ExpandedWidgetCards: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PomodoroCardView()
            PrayerCardView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The rounded tile both cards sit on.
struct WidgetCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)))
    }
}

// MARK: - Expanding

/// The open notch when pulled down: about 2.3x the normal height.
let expandedNotchSize = CGSize(width: openNotchSize.width, height: 430)
let expandedWindowSize = CGSize(width: expandedNotchSize.width, height: expandedNotchSize.height + shadowPadding)

extension BoringViewModel {
    static let widgetSpring = Animation.spring(response: 0.4, dampingFraction: 0.86)

    /// Height of the open notch right now, following the strip while it's dragged.
    var liveOpenNotchHeight: CGFloat {
        let base = isWidgetExpanded ? expandedNotchSize.height : openNotchSize.height
        let low = openNotchSize.height - 20, high = expandedNotchSize.height + 20
        return min(high, max(low, base + widgetDragOffset))
    }

    /// 0 when folded, 1 when fully pulled down; follows a drag in between.
    var widgetExpansionProgress: CGFloat {
        let span = expandedNotchSize.height - openNotchSize.height
        return min(1, max(0, (liveOpenNotchHeight - openNotchSize.height) / span))
    }

    /// While a drag is in flight, and for a moment after, leaving the notch with
    /// the pointer must not close it: the pointer is usually below the notch
    /// when a pull-down ends.
    var holdsOpenForWidget: Bool {
        isDraggingWidget || Date() < widgetHoldUntil
    }

    /// Make the window tall before anything grows into it. Called when the
    /// pointer reaches the pull strip, so the window never resizes mid-drag.
    func prepareWidgetSpace() {
        guard notchState == .open, !widgetWindowTall else { return }
        widgetWindowTall = true
    }

    /// Give the room back if the pointer left the strip without pulling.
    func releaseWidgetSpaceIfIdle() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard let self, !self.isWidgetExpanded, !self.isDraggingWidget, self.widgetDragOffset == 0 else { return }
            self.widgetWindowTall = false
        }
    }

    func updateWidgetDrag(_ translation: CGFloat) {
        if !isDraggingWidget {
            isDraggingWidget = true
            widgetWindowTall = true
            notchSize = expandedNotchSize   // hover tracking covers the pulled area
        }
        widgetDragOffset = translation
    }

    /// Settle a drag: past 50 pt (or a flick) changes state, otherwise it springs back.
    func endWidgetDrag(translation: CGFloat, predicted: CGFloat) {
        isDraggingWidget = false
        widgetHoldUntil = Date().addingTimeInterval(1.5)
        let commit: CGFloat = 50
        if isWidgetExpanded {
            setWidgetExpanded(!(translation < -commit || predicted < -commit * 3))
        } else {
            setWidgetExpanded(translation > commit || predicted > commit * 3)
        }
    }

    func setWidgetExpanded(_ expanded: Bool) {
        guard notchState == .open else { return }
        let changed = expanded != isWidgetExpanded
        widgetWindowTall = true
        withAnimation(Self.widgetSpring) {
            isWidgetExpanded = expanded
            widgetDragOffset = 0
        }
        notchSize = expanded ? expandedNotchSize : openNotchSize
        if changed && Defaults[.enableHaptics] {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        if expanded {
            PrayerTimesManager.shared.refresh()
        } else {
            releaseWidgetSpaceIfIdle()
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

/// The strip along the bottom edge of the open notch: drag it down to pull the
/// notch open, up to fold it; click to toggle.
struct WidgetExpandGrabber: View {
    @EnvironmentObject var vm: BoringViewModel
    @State private var hovering = false

    var body: some View {
        let active = hovering || vm.isDraggingWidget
        Capsule()
            .fill(Color.white.opacity(active ? 0.65 : 0.25))
            .frame(width: active ? 48 : 36, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: 18)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { vm.prepareWidgetSpace() } else { vm.releaseWidgetSpaceIfIdle() }
            }
            .animation(.smooth(duration: 0.18), value: active)
            .help(vm.isWidgetExpanded ? "Drag up or click to fold" : "Drag down or click to expand")
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .onChanged { vm.updateWidgetDrag($0.translation.height) }
                    .onEnded { vm.endWidgetDrag(translation: $0.translation.height,
                                                predicted: $0.predictedEndTranslation.height) }
            )
            .simultaneousGesture(
                TapGesture().onEnded { vm.setWidgetExpanded(!vm.isWidgetExpanded) }
            )
    }
}
