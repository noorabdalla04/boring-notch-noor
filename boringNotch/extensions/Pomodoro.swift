//
//  Pomodoro.swift
//  boringNotch
//
//  Noor custom: a Pomodoro timer that plans around prayer.
//
//  Starting a focus block looks at the next adhan in Noor's calendars
//  (PrayerTimes.swift) and splits the time until then into focus blocks as
//  close as possible to the ideal length (60 min by default), with short
//  breaks between them, so the last block ends exactly when it's time to pray
//  and the prayer itself is the long break. 2.5 h before Asr becomes 2 x 70 min
//  rather than 3 x 43 min; 2 h becomes 2 x 55 min.
//
//  The plan is redone at the start of every focus block (and on resume), so a
//  late start, a long break or a pause just reshapes what's left -- the break
//  still lands on the prayer. With no prayer in the next 8 hours (after Isha),
//  or with alignment off, it falls back to plain ideal-length blocks.
//
//  The open notch shows it as the third page of the home widget pager
//  (HomeWidgets.swift). While a block runs or is paused, the closed notch shows
//  a small ring and the time left, the way the music activity shows its bars.
//
//  The manager publishes state changes only; views draw the countdown with
//  TimelineView, so a running timer does not re-render ContentView every second.
//

import AppKit
import Defaults
import SwiftUI

enum PomodoroPhase: String, CaseIterable, Identifiable {
    case focus, shortBreak, prayer

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .focus: Color(red: 1.0, green: 0.42, blue: 0.33)
        case .shortBreak: Color(red: 0.30, green: 0.85, blue: 0.55)
        case .prayer: Color(red: 0.98, green: 0.78, blue: 0.35)
        }
    }
}

// MARK: - Planner

struct PomodoroPlan: Equatable {
    /// The prayer the plan lands on; nil when unaligned.
    var prayerName: String?
    var prayerTime: Date?
    /// When the prayer break starts (adhan minus the lead time).
    var breakStart: Date?
    /// Focus blocks left before the prayer, counting the one about to run.
    var blocks: Int
    var focusMinutes: Double
    var shortBreakMinutes: Double

    var isAligned: Bool { breakStart != nil }
}

enum PomodoroPlanner {
    /// Beyond this, the next prayer is too far off to plan toward (e.g. after Isha).
    static let horizon: TimeInterval = 8 * 3600

    /// Split `available` minutes into n focus blocks with (n - 1) short breaks
    /// between them, choosing n so each block is as close to `ideal` as possible
    /// (closeness measured as a ratio, so 70 vs 60 beats 43 vs 60). Blocks never
    /// shrink below half the ideal unless the whole window is that short.
    static func fit(available: Double, ideal: Double, shortBreak: Double) -> (blocks: Int, focus: Double) {
        guard available > 0, ideal > 0 else { return (1, max(1, ideal)) }
        var best = (blocks: 1, focus: available)
        var bestCost = abs(log(available / ideal))
        let floor = max(15, ideal * 0.5)
        for n in 2...48 {
            let focus = (available - Double(n - 1) * shortBreak) / Double(n)
            if focus < floor { break }
            let cost = abs(log(focus / ideal))
            if cost < bestCost - 1e-9 {
                best = (n, focus)
                bestCost = cost
            }
        }
        return best
    }

    /// The plan for a focus block starting at `start`.
    static func plan(
        from start: Date,
        prayers: [PrayerTime],
        ideal: Double,
        shortBreak: Double,
        leadMinutes: Double,
        align: Bool
    ) -> PomodoroPlan {
        if align {
            for prayer in prayers.sorted(by: { $0.time < $1.time }) where prayer.isPrayer {
                let breakStart = prayer.time.addingTimeInterval(-leadMinutes * 60)
                let available = breakStart.timeIntervalSince(start)
                // Already in this prayer's window: plan toward the one after.
                if available < 2 * 60 { continue }
                if available > horizon { break }
                let fit = fit(available: available / 60, ideal: ideal, shortBreak: shortBreak)
                return PomodoroPlan(
                    prayerName: prayer.name,
                    prayerTime: prayer.time,
                    breakStart: breakStart,
                    blocks: fit.blocks,
                    focusMinutes: fit.focus,
                    shortBreakMinutes: shortBreak
                )
            }
        }
        return PomodoroPlan(blocks: 1, focusMinutes: ideal, shortBreakMinutes: shortBreak)
    }
}

// MARK: - Manager

@MainActor
final class PomodoroManager: ObservableObject {
    static let shared = PomodoroManager()

    @Published private(set) var phase: PomodoroPhase = .focus
    /// Set while running.
    @Published private(set) var endDate: Date?
    /// Set while paused.
    @Published private(set) var pausedRemaining: TimeInterval?
    /// Length of the current block, for the progress ring.
    @Published private(set) var phaseDuration: TimeInterval = 0
    /// The plan the current focus run follows.
    @Published private(set) var plan: PomodoroPlan?
    /// Which prayer the current prayer break is for.
    @Published private(set) var prayerName: String?
    /// The phase that just ended, shown briefly in the closed notch.
    @Published private(set) var justFinished: PomodoroPhase?

    private var timer: Timer?
    private var bannerTask: Task<Void, Never>?
    private let stateKey = "pomodoroState.v2"

    var isRunning: Bool { endDate != nil }
    var isPaused: Bool { pausedRemaining != nil }
    /// Running or paused: what the closed notch timer follows.
    var isActive: Bool { isRunning || isPaused }
    /// Anything worth showing in the closed notch.
    var wantsClosedNotch: Bool { isActive || justFinished != nil }

    private init() {
        phaseDuration = Self.freshDuration(of: .focus)
        restore()
    }

    static func freshDuration(of phase: PomodoroPhase) -> TimeInterval {
        switch phase {
        case .focus: TimeInterval(max(1, Defaults[.pomodoroFocusMinutes]) * 60)
        case .shortBreak: TimeInterval(max(1, Defaults[.pomodoroShortBreakMinutes]) * 60)
        case .prayer: TimeInterval(max(1, Defaults[.pomodoroPrayerBreakMinutes] + Defaults[.pomodoroPrayerLeadMinutes]) * 60)
        }
    }

    func remaining(at now: Date = .now) -> TimeInterval {
        if let endDate { return max(0, endDate.timeIntervalSince(now)) }
        if let pausedRemaining { return pausedRemaining }
        // Idle: whole minutes, so the preview doesn't tick down before you start.
        return phase == .focus ? preview(at: now).focusMinutes.rounded() * 60 : phaseDuration
    }

    func progress(at now: Date = .now) -> Double {
        guard isActive, phaseDuration > 0 else { return 0 }
        return min(1, max(0, 1 - remaining(at: now) / phaseDuration))
    }

    /// What starting a focus block at `start` would do.
    func preview(at start: Date = .now) -> PomodoroPlan {
        PomodoroPlanner.plan(
            from: start,
            prayers: PrayerTimesManager.shared.upcomingPrayers(after: start),
            ideal: Double(max(1, Defaults[.pomodoroFocusMinutes])),
            shortBreak: Double(max(1, Defaults[.pomodoroShortBreakMinutes])),
            leadMinutes: Double(max(0, Defaults[.pomodoroPrayerLeadMinutes])),
            align: Defaults[.pomodoroAlignToPrayers]
        )
    }

    var phaseTitle: String {
        switch phase {
        case .focus: "Focus"
        case .shortBreak: "Break"
        case .prayer: prayerName ?? "Prayer"
        }
    }

    // MARK: Controls

    func start() {
        let now = Date()
        if phase == .focus {
            // Re-plan from when this block (virtually) began, so a resumed block
            // keeps the work already done and the end still lands on prayer.
            let worked = pausedRemaining.map { max(0, phaseDuration - $0) } ?? 0
            let blockStart = now.addingTimeInterval(-worked)
            let plan = preview(at: blockStart)
            var end = blockStart.addingTimeInterval(plan.focusMinutes * 60)
            if plan.blocks == 1, let breakStart = plan.breakStart { end = breakStart }
            end = max(end, now.addingTimeInterval(5))
            self.plan = plan
            phaseDuration = end.timeIntervalSince(blockStart)
            endDate = end
        } else {
            endDate = now.addingTimeInterval(pausedRemaining ?? phaseDuration)
        }
        pausedRemaining = nil
        justFinished = nil
        startTimer()
        persist()
    }

    func pause() {
        guard let endDate else { return }
        pausedRemaining = max(0, endDate.timeIntervalSinceNow)
        self.endDate = nil
        stopTimer()
        persist()
    }

    func toggle() {
        isRunning ? pause() : start()
    }

    /// Stop and go back to a fresh focus block.
    func stop() {
        endDate = nil
        pausedRemaining = nil
        phase = .focus
        phaseDuration = Self.freshDuration(of: .focus)
        plan = nil
        prayerName = nil
        stopTimer()
        persist()
    }

    /// End this block now and move on (a break starts if auto-start is on).
    func skip() {
        justFinished = nil
        let wasRunning = isRunning
        advance()
        if wasRunning && Defaults[.pomodoroAutoStartNext] && phase != .focus { start() }
    }

    // MARK: Ticking

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let endDate, Date() >= endDate else { return }
        let finished = phase
        advance()
        if Defaults[.pomodoroSound] {
            NSSound(named: phase == .prayer ? "Hero" : "Glass")?.play()
        }
        showBanner(for: finished)
        // Focus -> break and break -> focus run on; after prayer, wait for Noor.
        if Defaults[.pomodoroAutoStartNext] && finished != .prayer { start() }
    }

    private func advance() {
        switch phase {
        case .focus:
            if let plan, plan.isAligned, plan.blocks <= 1 {
                phase = .prayer
                prayerName = plan.prayerName
            } else {
                phase = .shortBreak
            }
        case .shortBreak:
            phase = .focus
        case .prayer:
            phase = .focus
            prayerName = nil
            plan = nil
        }
        phaseDuration = Self.freshDuration(of: phase)
        endDate = nil
        pausedRemaining = nil
        stopTimer()
        persist()
    }

    private func showBanner(for finished: PomodoroPhase) {
        justFinished = finished
        bannerTask?.cancel()
        bannerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            self?.justFinished = nil
        }
    }

    // MARK: Persistence (a relaunch or rebuild mid-session keeps the timer)

    private func persist() {
        // The UI sandbox shares this app's settings; it must never overwrite the real timer.
        guard !NoorLab.isRequested else { return }
        var state: [String: Any] = ["phase": phase.rawValue, "duration": phaseDuration]
        if let endDate { state["end"] = endDate.timeIntervalSince1970 }
        if let pausedRemaining { state["paused"] = pausedRemaining }
        if let prayerName { state["prayerName"] = prayerName }
        if let plan {
            state["planBlocks"] = plan.blocks
            state["planFocus"] = plan.focusMinutes
            state["planBreak"] = plan.shortBreakMinutes
            if let name = plan.prayerName { state["planPrayer"] = name }
            if let time = plan.prayerTime { state["planPrayerTime"] = time.timeIntervalSince1970 }
            if let breakStart = plan.breakStart { state["planBreakStart"] = breakStart.timeIntervalSince1970 }
        }
        UserDefaults.standard.set(state, forKey: stateKey)
    }

    private func restore() {
        guard let state = UserDefaults.standard.dictionary(forKey: stateKey) else { return }
        phase = (state["phase"] as? String).flatMap(PomodoroPhase.init(rawValue:)) ?? .focus
        phaseDuration = state["duration"] as? TimeInterval ?? Self.freshDuration(of: phase)
        prayerName = state["prayerName"] as? String
        if let blocks = state["planBlocks"] as? Int {
            plan = PomodoroPlan(
                prayerName: state["planPrayer"] as? String,
                prayerTime: (state["planPrayerTime"] as? TimeInterval).map(Date.init(timeIntervalSince1970:)),
                breakStart: (state["planBreakStart"] as? TimeInterval).map(Date.init(timeIntervalSince1970:)),
                blocks: blocks,
                focusMinutes: state["planFocus"] as? Double ?? 60,
                shortBreakMinutes: state["planBreak"] as? Double ?? 10
            )
        }
        if let paused = state["paused"] as? TimeInterval {
            pausedRemaining = paused
        } else if let end = state["end"] as? TimeInterval {
            let date = Date(timeIntervalSince1970: end)
            if date > Date() {
                endDate = date
                startTimer()
            } else {
                // Ended while the app was closed: move on, stopped.
                advance()
            }
        }
    }
}

// MARK: - Formatting

enum PomodoroFormat {
    static func clock(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded(.up))
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }

    static func minutes(_ value: Double) -> String {
        "\(Int(value.rounded()))m"
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "2 × 70m focus, 10m breaks · Asr break at 3:44 PM"
    static func summary(_ plan: PomodoroPlan) -> String {
        let blocks = plan.blocks == 1
            ? "\(minutes(plan.focusMinutes)) focus"
            : "\(plan.blocks) × \(minutes(plan.focusMinutes)) focus, \(minutes(plan.shortBreakMinutes)) breaks"
        guard let name = plan.prayerName, let breakStart = plan.breakStart else {
            return "\(blocks) · no prayer in the next 8h"
        }
        return "\(blocks) · \(name) break at \(time(breakStart))"
    }
}

// MARK: - Ring

struct PomodoroRing: View {
    let progress: Double
    let color: Color
    var lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, progress))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

// MARK: - Open notch page

struct PomodoroPageView: View {
    @ObservedObject private var pomodoro = PomodoroManager.shared
    @ObservedObject private var prayers = PrayerTimesManager.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
        .onAppear { prayers.refresh() }
    }

    private func content(now: Date) -> some View {
        let color = pomodoro.isPaused ? Color.gray : pomodoro.phase.color
        return VStack(alignment: .leading, spacing: 6) {
            Text(planLine(now: now))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.gray)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                ZStack {
                    PomodoroRing(progress: pomodoro.progress(at: now), color: color, lineWidth: 5)
                    VStack(spacing: 0) {
                        Text(PomodoroFormat.clock(pomodoro.remaining(at: now)))
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                        Text(statusText)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(pomodoro.isActive ? color : .gray)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                }
                .frame(width: 82, height: 82)

                VStack(alignment: .leading, spacing: 8) {
                    Button(action: pomodoro.toggle) {
                        Label(pomodoro.isRunning ? "Pause" : (pomodoro.isPaused ? "Resume" : "Start"),
                              systemImage: pomodoro.isRunning ? "pause.fill" : "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 88, height: 26)
                            .background(Capsule().fill(pomodoro.phase.color.opacity(0.9)))
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 8) {
                        smallButton("stop.fill", help: "Stop and reset", action: pomodoro.stop)
                            .disabled(!pomodoro.isActive && pomodoro.phase == .focus)
                            .opacity(pomodoro.isActive || pomodoro.phase != .focus ? 1 : 0.4)
                        smallButton("forward.end.fill", help: "End this block now", action: pomodoro.skip)
                            .disabled(!pomodoro.isActive)
                            .opacity(pomodoro.isActive ? 1 : 0.4)
                    }

                    blockDots
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// What will happen (idle) or what is happening (running), in one line.
    private func planLine(now: Date) -> String {
        if pomodoro.phase == .prayer {
            return "Time for \(pomodoro.phaseTitle). Start the next focus run when you're back."
        }
        if pomodoro.isActive, let plan = pomodoro.plan {
            if let name = plan.prayerName, let breakStart = plan.breakStart {
                let left = pomodoro.phase == .focus ? plan.blocks : plan.blocks - 1
                let blocks = left <= 1 ? (pomodoro.phase == .focus ? "Last block" : "1 block left")
                                       : "\(left) blocks left"
                return "\(blocks) · \(name) break at \(PomodoroFormat.time(breakStart))"
            }
            return PomodoroFormat.summary(plan)
        }
        return "Start now: " + PomodoroFormat.summary(pomodoro.preview(at: now))
    }

    private var statusText: String {
        if pomodoro.isPaused { return "paused" }
        if pomodoro.isRunning { return pomodoro.phaseTitle.lowercased() }
        return pomodoro.phase == .focus ? "ready" : "\(pomodoro.phaseTitle.lowercased()) next"
    }

    /// One dot per focus block until the prayer; filled ones are done.
    private var blockDots: some View {
        let plan = pomodoro.isActive ? pomodoro.plan : nil
        let left = (plan?.blocks ?? 0) - (pomodoro.phase == .focus ? 0 : 1)
        let total = min(max(0, left), 8)
        return HStack(spacing: 4) {
            ForEach(0..<total, id: \.self) { index in
                Circle()
                    .fill(index == 0 && pomodoro.phase == .focus ? PomodoroPhase.focus.color : Color.white.opacity(0.2))
                    .frame(width: 6, height: 6)
            }
            if plan?.isAligned == true {
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(PomodoroPhase.prayer.color)
            }
        }
        .frame(height: 8)
    }

    private func smallButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 40, height: 22)
                .background(Capsule().fill(Color.white.opacity(0.1)))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Closed notch activity

/// The closed-notch timer: ring left of the cutout, time left on the right.
struct PomodoroLiveActivity: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var pomodoro = PomodoroManager.shared

    /// Width reserved right of the cutout for "1:10:00"; ContentView sizes the chin with it.
    static let labelWidth: CGFloat = 50

    private var itemSize: CGFloat { max(0, vm.effectiveClosedNotchHeight - 12) }
    private var showingBanner: Bool { pomodoro.justFinished != nil && !pomodoro.isActive }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack {
                Group {
                    if showingBanner {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: itemSize * 0.8))
                            .foregroundStyle(pomodoro.justFinished?.color ?? .white)
                    } else {
                        PomodoroRing(
                            progress: pomodoro.progress(at: context.date),
                            color: pomodoro.isPaused ? .gray : pomodoro.phase.color,
                            lineWidth: 2.5
                        )
                        .frame(width: max(0, itemSize - 4), height: max(0, itemSize - 4))
                    }
                }
                .frame(width: itemSize, height: itemSize)

                Rectangle()
                    .fill(.black)
                    .frame(width: vm.closedNotchSize.width - cornerRadiusInsets.closed.top)

                Group {
                    if showingBanner {
                        // What comes next, now that a block has ended.
                        Text(pomodoro.phaseTitle)
                            .foregroundStyle(pomodoro.phase.color)
                    } else if pomodoro.isPaused {
                        Image(systemName: "pause.fill")
                            .foregroundStyle(.gray)
                    } else {
                        Text(PomodoroFormat.clock(pomodoro.remaining(at: context.date)))
                            .foregroundStyle(pomodoro.phase.color)
                    }
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: Self.labelWidth, alignment: .center)
            }
        }
        .frame(height: vm.effectiveClosedNotchHeight)
    }
}

// MARK: - Card (pulled-down notch)

/// The Pomodoro card under the music player when the notch is pulled down.
struct PomodoroCardView: View {
    @ObservedObject private var pomodoro = PomodoroManager.shared
    @ObservedObject private var prayers = PrayerTimesManager.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            WidgetCard { content(now: context.date) }
        }
    }

    private func content(now: Date) -> some View {
        let color = pomodoro.isPaused ? Color.gray : pomodoro.phase.color
        let plan = (pomodoro.isActive ? pomodoro.plan : nil) ?? pomodoro.preview(at: now)
        return VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Pomodoro")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.gray)
                Spacer(minLength: 4)
                if let name = plan.prayerName, let breakStart = plan.breakStart {
                    Label("\(name) \(PomodoroFormat.time(breakStart))", systemImage: "moon.stars.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(PomodoroPhase.prayer.color)
                        .lineLimit(1)
                }
            }

            ZStack {
                PomodoroRing(progress: pomodoro.progress(at: now), color: color, lineWidth: 6)
                VStack(spacing: 0) {
                    Text(PomodoroFormat.clock(pomodoro.remaining(at: now)))
                        .font(.system(size: 21, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text(statusText)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(pomodoro.isActive ? color : .gray)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
            }
            .frame(width: 96, height: 96)

            Text(planLine(plan))
                .font(.system(size: 10))
                .foregroundStyle(.gray)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            HStack(spacing: 6) {
                Button(action: pomodoro.toggle) {
                    Image(systemName: pomodoro.isRunning ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background(Capsule().fill(pomodoro.phase.color.opacity(0.9)))
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                .help(pomodoro.isRunning ? "Pause" : (pomodoro.isPaused ? "Resume" : "Start"))
                smallButton("stop.fill", help: "Stop and reset", enabled: pomodoro.isActive || pomodoro.phase != .focus, action: pomodoro.stop)
                smallButton("forward.end.fill", help: "End this block now", enabled: pomodoro.isActive, action: pomodoro.skip)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var statusText: String {
        if pomodoro.isPaused { return "paused" }
        if pomodoro.isRunning { return pomodoro.phaseTitle.lowercased() }
        return "ready"
    }

    private func planLine(_ plan: PomodoroPlan) -> String {
        if pomodoro.phase == .prayer { return "Back after \(pomodoro.phaseTitle)" }
        let blocks = plan.blocks == 1
            ? "\(PomodoroFormat.minutes(plan.focusMinutes)) focus"
            : "\(plan.blocks) × \(PomodoroFormat.minutes(plan.focusMinutes)) focus"
        return pomodoro.isActive ? blocks + " planned" : "Start: " + blocks
    }

    private func smallButton(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 30, height: 26)
                .background(Capsule().fill(Color.white.opacity(0.1)))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help(help)
    }
}
