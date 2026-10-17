//
//  RemindersWidget.swift
//  boringNotch
//
//  Noor custom: a Reminders page for the home widget pager (HomeWidgets.swift),
//  next to the calendar. Incomplete reminders from the lists ticked in
//  Settings > Calendar, in four sections: Late, Today, Next 7 days, No date.
//
//  Ticking a reminder shows it done for a moment, then completes it in
//  Reminders and drops it from the list; ticking again in that moment undoes
//  it. Clicking a title opens the reminder in Reminders. "+" adds a reminder
//  due today to the default list.
//
//  In the UI sandbox (NoorLab) nothing is ever written to Reminders: ticks
//  and adds only change what the lab shows.
//

import AppKit
import Defaults
import EventKit
import SwiftUI

struct ReminderItem: Identifiable, Equatable {
    let id: String
    let title: String
    let due: Date?
    /// False for all-day reminders, which are due "that day" rather than at a time.
    let dueHasTime: Bool
    let listTitle: String
    let listColor: Color
    /// EventKit priority: 1-4 high, 5 medium, 6-9 low, 0 none.
    let priority: Int

    var isHighPriority: Bool { (1...4).contains(priority) }
    var isMediumPriority: Bool { priority == 5 }
}

enum ReminderSection: String, CaseIterable, Identifiable {
    case late, today, week, undated

    var id: String { rawValue }

    var title: String {
        switch self {
        case .late: "Late"
        case .today: "Today"
        case .week: "Next 7 days"
        case .undated: "No date"
        }
    }
}

@MainActor
final class RemindersManager: ObservableObject {
    static let shared = RemindersManager()

    @Published private(set) var items: [ReminderItem] = []
    @Published private(set) var loaded = false
    /// Ticked, waiting a moment before they're completed (so a tick can be undone).
    @Published private(set) var pendingDone: Set<String> = []

    private let store = EKEventStore()
    private var observer: NSObjectProtocol?
    private var commitTasks: [String: Task<Void, Never>] = [:]

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    /// The reminder lists the calendar settings have ticked.
    private var lists: [EKCalendar] {
        let selected = CalendarManager.shared.selectedCalendarIDs
        return store.calendars(for: .reminder).filter { selected.isEmpty || selected.contains($0.calendarIdentifier) }
    }

    func refresh() {
        guard hasAccess else { loaded = true; return }
        let calendars = lists
        guard !calendars.isEmpty else { items = []; loaded = true; return }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
        store.fetchReminders(matching: predicate) { reminders in
            let mapped = (reminders ?? []).map(Self.item(from:))
            Task { @MainActor in
                // Keep lab-only additions (ids starting "lab-") across refreshes.
                let labOnly = NoorLab.isRequested ? self.items.filter { $0.id.hasPrefix("lab-") } : []
                self.items = mapped + labOnly
                self.loaded = true
            }
        }
    }

    private nonisolated static func item(from reminder: EKReminder) -> ReminderItem {
        let components = reminder.dueDateComponents
        let due = components.flatMap { Calendar.current.date(from: $0) }
        return ReminderItem(
            id: reminder.calendarItemIdentifier,
            // Some lists are written by tools that use markdown bold; show plain text.
            title: (reminder.title ?? "").replacingOccurrences(of: "**", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            due: due,
            dueHasTime: components?.hour != nil,
            listTitle: reminder.calendar?.title ?? "",
            listColor: Color(nsColor: reminder.calendar?.color ?? .systemBlue),
            priority: reminder.priority
        )
    }

    // MARK: Grouping

    func section(of item: ReminderItem, now: Date = .now) -> ReminderSection {
        guard let due = item.due else { return .undated }
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let late = item.dueHasTime ? due < now : due < startOfToday
        if late { return .late }
        if calendar.isDate(due, inSameDayAs: now) { return .today }
        return .week   // anything later than a week is filtered out by `sections`
    }

    func sections(now: Date = .now) -> [(ReminderSection, [ReminderItem])] {
        let weekEnd = Calendar.current.date(byAdding: .day, value: 8, to: Calendar.current.startOfDay(for: now)) ?? now
        let showUndated = Defaults[.remindersShowUndated]
        var groups: [ReminderSection: [ReminderItem]] = [:]
        for item in items {
            if let due = item.due, due >= weekEnd { continue }
            let section = section(of: item, now: now)
            if section == .undated && !showUndated { continue }
            groups[section, default: []].append(item)
        }
        return ReminderSection.allCases.compactMap { section in
            guard let list = groups[section], !list.isEmpty else { return nil }
            let sorted = list.sorted { a, b in
                switch (a.due, b.due) {
                case let (x?, y?) where x != y: return x < y
                case (nil, _?): return false
                case (_?, nil): return true
                default:
                    if (a.priority == 0) != (b.priority == 0) { return a.priority != 0 }
                    if a.priority != b.priority { return a.priority < b.priority }
                    return a.title.localizedStandardCompare(b.title) == .orderedAscending
                }
            }
            return (section, sorted)
        }
    }

    func counts(now: Date = .now) -> (late: Int, today: Int) {
        var late = 0, today = 0
        for item in items where !pendingDone.contains(item.id) {
            switch section(of: item, now: now) {
            case .late: late += 1
            case .today: today += 1
            default: break
            }
        }
        return (late, today)
    }

    // MARK: Actions

    /// Tick (or untick, within the grace moment).
    func toggle(_ item: ReminderItem) {
        if pendingDone.contains(item.id) {
            commitTasks[item.id]?.cancel()
            commitTasks[item.id] = nil
            withAnimation(.smooth(duration: 0.2)) { _ = pendingDone.remove(item.id) }
            return
        }
        withAnimation(.smooth(duration: 0.2)) { _ = pendingDone.insert(item.id) }
        commitTasks[item.id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1400))
            guard !Task.isCancelled, let self else { return }
            self.complete(item.id)
        }
    }

    private func complete(_ id: String) {
        commitTasks[id] = nil
        if !NoorLab.isRequested, !id.hasPrefix("lab-"),
           let reminder = store.calendarItem(withIdentifier: id) as? EKReminder {
            reminder.isCompleted = true
            do { try store.save(reminder, commit: true) } catch { NSLog("Reminder completion failed: \(error)") }
        }
        withAnimation(.smooth(duration: 0.3)) {
            items.removeAll { $0.id == id }
            _ = pendingDone.remove(id)
        }
    }

    /// A new reminder, due today (no time), in the default list.
    func add(_ title: String) {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let today = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        if NoorLab.isRequested {
            withAnimation(.smooth(duration: 0.25)) {
                items.append(ReminderItem(id: "lab-\(UUID().uuidString)", title: text,
                                          due: Calendar.current.date(from: today), dueHasTime: false,
                                          listTitle: "Lab", listColor: .blue, priority: 0))
            }
            return
        }
        guard hasAccess, let list = store.defaultCalendarForNewReminders() else { return }
        let reminder = EKReminder(eventStore: store)
        reminder.title = text
        reminder.calendar = list
        reminder.dueDateComponents = today
        do {
            try store.save(reminder, commit: true)
            refresh()
        } catch {
            NSLog("Reminder add failed: \(error)")
        }
    }

    func open(_ item: ReminderItem) {
        guard !NoorLab.isRequested,
              let id = item.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "x-apple-reminderkit://remcdreminder/\(id)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Section counts for the lab log (counts only, no titles).
    func stats() -> String {
        var counts: [String: Int] = Dictionary(uniqueKeysWithValues: sections().map { ($0.0.rawValue, $0.1.count) })
        counts["total"] = items.count
        counts["pending"] = pendingDone.count
        let data = (try? JSONSerialization.data(withJSONObject: counts, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

// MARK: - Page

struct RemindersPageView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var reminders = RemindersManager.shared
    /// Two-line rows with the list name, for the pulled-down notch.
    var roomy = false

    @State private var adding = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool
    @State private var hostWindow: NSWindow?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(now: context.date)
        }
        .background(WindowReader(window: $hostWindow))
        .onAppear { reminders.refresh() }
        .onChange(of: vm.notchState) { _, state in
            if state == .closed { endAdding() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .noorLabAddReminder)) { note in
            // Lab only: drive the add field like typing would.
            guard NoorLab.isRequested else { return }
            if !adding { beginAdding() }
            if let text = note.object as? String {
                draft = text
                reminders.add(draft)
                draft = ""
            }
        }
    }

    private func content(now: Date) -> some View {
        let sections = reminders.sections(now: now)
        let counts = reminders.counts(now: now)
        return VStack(alignment: .leading, spacing: 4) {
            header(counts: counts)

            if adding { addField }

            if !reminders.loaded {
                placeholder("Loading…")
            } else if sections.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(.gray)
                    Text("All done")
                        .font(.system(size: 11))
                        .foregroundStyle(.gray)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(sections, id: \.0) { section, items in
                            Text(section.title.uppercased())
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(section == .late ? Color.red.opacity(0.85) : .gray)
                                .padding(.top, 4)
                                .padding(.leading, 2)
                            ForEach(items) { item in
                                row(item, section: section, now: now)
                            }
                        }
                    }
                    .padding(.bottom, 6)
                }
            }
        }
        .padding(.horizontal, 2)
        .padding(.top, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func header(counts: (late: Int, today: Int)) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Reminders")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
            if counts.late > 0 {
                Text("\(counts.late) late")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.red)
            }
            if counts.today > 0 {
                Text("\(counts.today) today")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.effectiveAccent)
            }
            Button(action: { adding ? endAdding() : beginAdding() }) {
                Image(systemName: adding ? "xmark" : "plus")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.white.opacity(0.12)))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help(adding ? "Cancel" : "New reminder for today")
        }
    }

    private var addField: some View {
        TextField("New reminder for today", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)))
            .focused($fieldFocused)
            .onSubmit {
                reminders.add(draft)
                draft = ""
                fieldFocused = true      // ready for the next one
            }
            .onExitCommand(perform: endAdding)
    }

    private func row(_ item: ReminderItem, section: ReminderSection, now: Date) -> some View {
        let done = reminders.pendingDone.contains(item.id)
        return HStack(alignment: roomy ? .top : .center, spacing: 7) {
            Button { reminders.toggle(item) } label: {
                ZStack {
                    Circle()
                        .stroke(item.listColor, lineWidth: 1.5)
                        .frame(width: 13, height: 13)
                    if done {
                        Circle().fill(item.listColor).frame(width: 13, height: 13)
                        Image(systemName: "checkmark")
                            .font(.system(size: 7, weight: .heavy))
                            .foregroundStyle(.black)
                    }
                }
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(done ? "Undo" : "Mark done")

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    if item.isHighPriority || item.isMediumPriority {
                        Text(item.isHighPriority ? "!!" : "!")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(.orange)
                    }
                    Text(item.title)
                        .font(.system(size: 12))
                        .foregroundStyle(done ? .gray : .white)
                        .strikethrough(done, color: .gray)
                        .lineLimit(roomy ? 2 : 1)
                }
                if roomy {
                    Text(item.listTitle)
                        .font(.system(size: 9.5))
                        .foregroundStyle(item.listColor.opacity(0.9))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { reminders.open(item) }

            if let label = dueLabel(item, section: section, now: now) {
                Text(label)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(section == .late ? Color.red.opacity(0.9) : .gray)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.vertical, roomy ? 3 : 1.5)
        .opacity(done ? 0.55 : 1)
    }

    private func dueLabel(_ item: ReminderItem, section: ReminderSection, now: Date) -> String? {
        guard let due = item.due else { return nil }
        let calendar = Calendar.current
        switch section {
        case .late:
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: due), to: calendar.startOfDay(for: now)).day ?? 0
            if days == 0, item.dueHasTime { return due.formatted(date: .omitted, time: .shortened) }
            if days == 1 { return "yesterday" }
            if days < 7 { return "\(days)d ago" }
            return due.formatted(.dateTime.month(.abbreviated).day())
        case .today:
            return item.dueHasTime ? due.formatted(date: .omitted, time: .shortened) : nil
        case .week:
            if calendar.isDateInTomorrow(due) {
                return item.dueHasTime ? "tmrw " + due.formatted(date: .omitted, time: .shortened) : "tmrw"
            }
            return due.formatted(.dateTime.weekday(.abbreviated))
        case .undated:
            return nil
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.gray)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Typing

    /// The notch panel only takes the keyboard while a field is actually being
    /// typed into (BoringNotchSkyLightWindow.wantsKeyForTextInput), and the notch
    /// stays open while it does.
    private func beginAdding() {
        adding = true
        vm.isTypingInWidget = true
        if let notch = hostWindow as? BoringNotchSkyLightWindow {
            notch.wantsKeyForTextInput = true
        } else {
            hostWindow?.makeKey()
        }
        DispatchQueue.main.async { fieldFocused = true }
    }

    private func endAdding() {
        guard adding else { return }
        adding = false
        draft = ""
        fieldFocused = false
        vm.isTypingInWidget = false
        (hostWindow as? BoringNotchSkyLightWindow)?.wantsKeyForTextInput = false
        // Give the keyboard straight back to the app being worked in.
        if hostWindow?.isKeyWindow == true { hostWindow?.resignKey() }
    }
}

extension Notification.Name {
    /// NoorLab: add a reminder through the page, as typing would.
    static let noorLabAddReminder = Notification.Name("noorLabAddReminder")
}

/// Hands a SwiftUI view the NSWindow it's in.
struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if window !== view.window {
            DispatchQueue.main.async { window = view.window }
        }
    }
}
