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
        switch page {
        case .calendar:
            CalendarView().environmentObject(vm)
        case .prayers:
            PrayerTimesPageView()
        case .pomodoro:
            PomodoroPageView()
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
