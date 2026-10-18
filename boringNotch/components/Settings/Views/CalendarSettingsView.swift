//
//  CalendarSettingsView.swift
//  boringNotch
//
//  Created by Richard Kunkli on 07/08/2024.
//

import Defaults
import EventKit
import SwiftUI

struct CalendarSettings: View {
    @ObservedObject private var calendarManager = CalendarManager.shared
    @Default(.showCalendar) var showCalendar: Bool
    @Default(.hideCompletedReminders) var hideCompletedReminders
    @Default(.hideAllDayEvents) var hideAllDayEvents
    @Default(.autoScrollToNextEvent) var autoScrollToNextEvent
    @Default(.calendarWeekView) var calendarWeekView
    @Default(.weekStartDay) var weekStartDay

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .showCalendar) {
                    Text("Show calendar")
                }
                Defaults.Toggle(key: .calendarWeekView) {
                    Text("Weekly view")
                }
                if calendarWeekView {
                    Picker("Week starts on", selection: $weekStartDay) {
                        ForEach(WeekStartDay.allCases) { day in
                            Text(day.localizedString).tag(day)
                        }
                    }
                }
            } header: {
                Text("General")
            } footer: {
                Text("Choose how the calendar is displayed in the notch.")
            }

            Section {
                Defaults.Toggle(key: .hideCompletedReminders) {
                    Text("Hide completed reminders")
                }
                Defaults.Toggle(key: .hideAllDayEvents) {
                    Text("Hide all-day events")
                }
                Defaults.Toggle(key: .autoScrollToNextEvent) {
                    Text("Auto-scroll to next event")
                }
                Defaults.Toggle(key: .showFullEventTitles) {
                    Text("Always show full event titles")
                }
                Defaults.Toggle(key: .joinMeetingOnEventTap) {
                    Text("Join meeting when tapping an event")
                }
            } header: {
                Text("Events")
            }

            Section {
                Defaults.Toggle(key: .showRemindersWidget) { Text("Reminders") }
                Defaults.Toggle(key: .showPrayersWidget) { Text("Prayer times") }
                Defaults.Toggle(key: .showPomodoroWidget) { Text("Pomodoro") }
            } header: {
                Text("Notch widgets")
            } footer: {
                Text("Pages you can swipe to next to the calendar. Pull the open notch down (drag the strip at its bottom edge, or scroll down) to see Pomodoro and prayer times as cards under the music player.")
            }

            TaskBlockSettingsSection()

            PrayerSettingsSection()

            PomodoroSettingsSection()

            Section {
                Defaults.Toggle(key: .remindersShowUndated) {
                    Text("Show reminders with no due date")
                }
            } header: {
                Text("Reminders widget")
            } footer: {
                Text("The Reminders page shows incomplete reminders from the lists ticked under Reminders below: late, today, the next 7 days, and (optionally) undated.")
            }

            Section(header: Text("Calendars")) {
                if calendarManager.calendarAuthorizationStatus != .fullAccess {
                    PermissionDeniedNotice(
                        message: "Calendar access is denied. Please enable it in System Settings.",
                        buttonTitle: "Open Calendar Settings",
                        privacyPane: .calendars
                    )
                } else {
                    CalendarList(
                        calendars: calendarManager.eventCalendars,
                        calendarManager: calendarManager,
                        isEnabled: showCalendar
                    )
                }
            }
            Section(header: Text("Reminders")) {
                if calendarManager.reminderAuthorizationStatus != .fullAccess {
                    PermissionDeniedNotice(
                        message: "Reminder access is denied. Please enable it in System Settings.",
                        buttonTitle: "Open Reminder Settings",
                        privacyPane: .reminders
                    )
                } else {
                    CalendarList(
                        calendars: calendarManager.reminderLists,
                        calendarManager: calendarManager,
                        isEnabled: showCalendar
                    )
                }
            }
        }
        .formStyle(.grouped)
        .accentColor(.effectiveAccent)
        .navigationTitle("Calendar")
        .onAppear {
            Task {
                await calendarManager.checkCalendarAuthorization()
                await calendarManager.checkReminderAuthorization()
            }
        }
    }
}

/// The Privacy & Security panes relevant to calendar data.
private enum PrivacyPane {
    case calendars
    case reminders

    /// System Settings deep link for the pane.
    var settingsURL: URL? {
        switch self {
        case .calendars:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
        case .reminders:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")
        }
    }
}

/// An access-denied explanation with a shortcut to the relevant pane of
/// System Settings → Privacy & Security.
private struct PermissionDeniedNotice: View {
    let message: LocalizedStringKey
    let buttonTitle: LocalizedStringKey
    let privacyPane: PrivacyPane

    var body: some View {
        VStack(spacing: 8) {
            Text(message)
                .foregroundColor(.red)
                .multilineTextAlignment(.center)
                .padding()
            Button(buttonTitle) {
                if let settingsURL = privacyPane.settingsURL {
                    NSWorkspace.shared.open(settingsURL)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// A selectable list of calendars (or reminder lists) with their accent-colored
/// toggles. Shared by the Calendars and Reminders sections.
private struct CalendarList: View {
    let calendars: [CalendarModel]
    @ObservedObject var calendarManager: CalendarManager
    let isEnabled: Bool

    var body: some View {
        List {
            ForEach(calendars, id: \.id) { calendar in
                Toggle(
                    isOn: Binding(
                        get: { calendarManager.getCalendarSelected(calendar) },
                        set: { isSelected in
                            Task {
                                await calendarManager.setCalendarSelected(
                                    calendar, isSelected: isSelected)
                            }
                        }
                    )
                ) {
                    Text(calendar.title)
                }
                .accentColor(lighterColor(from: calendar.color))
                .disabled(!isEnabled)
            }
        }
    }
}

func lighterColor(from nsColor: NSColor, amount: CGFloat = 0.14) -> Color {
    let srgb = nsColor.usingColorSpace(.sRGB) ?? nsColor
    var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
    srgb.getRed(&r, green: &g, blue: &b, alpha: &a)

    func lighten(_ c: CGFloat) -> CGFloat {
        let increased = c + (1.0 - c) * amount
        return min(max(increased, 0), 1)
    }

    let nr = lighten(r)
    let ng = lighten(g)
    let nb = lighten(b)

    return Color(red: Double(nr), green: Double(ng), blue: Double(nb), opacity: Double(a))
}

/// FlowSavvy API key, kept in the app's private storage. The field never shows the saved key.
private struct FlowSavvyKeyField: View {
    @State private var draft = ""
    @State private var isSaved = FlowSavvyKeychain.exists

    var body: some View {
        HStack {
            SecureField(
                "FlowSavvy API key",
                text: $draft,
                prompt: Text(isSaved ? "Saved — paste a new one to replace" : "FlowSavvy → Settings → API")
            )
            Button("Save") {
                isSaved = FlowSavvyKeychain.save(draft)
                if isSaved { Defaults[.taskBlockCheckboxes] = true }
                draft = ""
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if isSaved {
                Button("Remove") {
                    FlowSavvyKeychain.delete()
                    isSaved = false
                }
            }
        }
    }
}

/// Noor custom: Pomodoro settings (extensions/Pomodoro.swift). The timer lives on the
/// third page of the open notch, after Calendar and Prayers.
struct PomodoroSettingsSection: View {
    @Default(.pomodoroFocusMinutes) private var focus
    @Default(.pomodoroShortBreakMinutes) private var shortBreak
    @Default(.pomodoroPrayerBreakMinutes) private var prayerBreak
    @Default(.pomodoroAlignToPrayers) private var align
    @Default(.pomodoroPrayerLeadMinutes) private var lead
    @Default(.pomodoroAutoStartNext) private var autoStart
    @Default(.pomodoroSound) private var sound
    @Default(.pomodoroClosedNotchTimer) private var closedTimer

    var body: some View {
        Section {
            Stepper("Ideal focus block: \(focus) min", value: $focus, in: 20...120, step: 5)
            Stepper("Short break: \(shortBreak) min", value: $shortBreak, in: 3...30)
            Toggle("Line breaks up with prayer times", isOn: $align)
            Stepper("Prayer break: \(prayerBreak) min", value: $prayerBreak, in: 5...60, step: 5)
                .disabled(!align)
            Stepper(lead == 0 ? "Prayer break starts at the adhan" : "Prayer break starts \(lead) min before the adhan",
                    value: $lead, in: 0...30, step: 5)
                .disabled(!align)
            Toggle("Run blocks and breaks back to back", isOn: $autoStart)
            Toggle("Play a sound when a block ends", isOn: $sound)
            Toggle("Show the timer in the closed notch", isOn: $closedTimer)
        } header: {
            Text("Pomodoro")
        } footer: {
            Text("Starting a focus run splits the time until the next adhan into blocks as close to the ideal as possible, so the last one ends when it's time to pray. Adhan times come from your prayer times calendar. After a prayer break, start the next run yourself.")
        }
    }
}

/// Optional: FlowSavvy / FlowLocal auto-scheduler integration (extensions/TaskBlocks.swift).
/// Off, the calendar is a plain Apple calendar and nothing talks to either service.
struct TaskBlockSettingsSection: View {
    @Default(.taskBlockCheckboxes) private var enabled

    var body: some View {
        Section {
            Toggle("Tick off FlowSavvy / FlowLocal task blocks", isOn: $enabled)
            if enabled {
                FlowSavvyKeyField()
                HStack {
                    Text("FlowLocal")
                    Spacer()
                    Text(FlowLocalKey.read() != nil ? "Connected (key found)" : "Not set up on this Mac")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Auto-scheduler integration (optional)")
        } footer: {
            Text(enabled
                 ? "Task blocks that FlowSavvy or FlowLocal put on your calendar get a checkbox. Ticking one marks that sitting done: its time counts toward the task and the rest re-plans; ticking a task's only or last block completes it."
                 : "Off: the calendar shows your Apple Calendar as it is. Turn this on only if you use the FlowSavvy or FlowLocal auto-schedulers.")
        }
    }
}
