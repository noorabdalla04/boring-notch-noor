//
//  PrayerTimes.swift
//  boringNotch
//
//  Noor custom: the Prayers page of the home widget pager. Times come from
//  Noor's own calendars rather than a calculation method, so the notch always
//  agrees with what the calendar says:
//
//  - adhan times: the prayer-times subscription, events titled exactly
//    "Fajr", "Sunrise", "Dhuhr", "Asr", "Maghrib", "Isha"
//  - iqama times: mosque events titled like "Isha at BIC · iqama 19:45"
//
//  Every calendar is read (not only the ones ticked for the calendar page),
//  and duplicates of the same prayer collapse to one.
//

import Defaults
import EventKit
import SwiftUI

struct PrayerTime: Identifiable, Equatable {
    let name: String
    let time: Date
    var iqama: Date?
    var place: String?

    var id: String { "\(name)-\(Int(time.timeIntervalSince1970))" }
    /// Sunrise ends Fajr's time; it is shown but is not itself a prayer.
    var isPrayer: Bool { name != "Sunrise" }
}

enum PrayerParsing {
    static let order = ["Fajr", "Sunrise", "Dhuhr", "Asr", "Maghrib", "Isha"]

    /// The canonical name for an adhan event title, or nil if it isn't one.
    static func canonicalName(_ raw: String) -> String? {
        // Letters only: the subscription titles Sunrise "🌅 Sunrise".
        let key = String(raw.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) }.map(Character.init))
        switch key {
        case "fajr", "fajar": return "Fajr"
        case "sunrise", "shuruq", "shurooq": return "Sunrise"
        case "dhuhr", "duhr", "zuhr", "zohr", "thuhr", "dhuhur": return "Dhuhr"
        case "asr": return "Asr"
        case "maghrib", "magrib": return "Maghrib"
        case "isha", "ishaa": return "Isha"
        default: return nil
        }
    }

    private static let iqamaPattern = try! NSRegularExpression(
        pattern: #"^\s*(\w+)\s+at\s+(.+?)\s*[·\-–|,]\s*iqama\s+(\d{1,2}):(\d{2})"#,
        options: [.caseInsensitive]
    )

    /// "Isha at BIC · iqama 19:45" on a given day -> ("Isha", "BIC", 19:45 that day).
    static func iqama(from title: String, on day: Date) -> (name: String, place: String, time: Date)? {
        let range = NSRange(title.startIndex..., in: title)
        guard let match = iqamaPattern.firstMatch(in: title, range: range),
              let nameRange = Range(match.range(at: 1), in: title),
              let placeRange = Range(match.range(at: 2), in: title),
              let hourRange = Range(match.range(at: 3), in: title),
              let minuteRange = Range(match.range(at: 4), in: title),
              let name = canonicalName(String(title[nameRange])),
              let hour = Int(title[hourRange]), let minute = Int(title[minuteRange]),
              let time = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: day)
        else { return nil }
        return (name, String(title[placeRange]), time)
    }

    /// One day's prayers, in order, from that day's events.
    static func prayers(from events: [EventModel], on day: Date) -> [PrayerTime] {
        let calendar = Calendar.current
        let dayEvents = events.filter { calendar.isDate($0.start, inSameDayAs: day) && !$0.isAllDay }

        var byName: [String: (prayer: PrayerTime, fromPrayerCalendar: Bool)] = [:]
        for event in dayEvents {
            guard let name = canonicalName(event.title) else { continue }
            // Prefer the prayer-times calendar if the same prayer shows up twice.
            let fromPrayerCalendar = event.calendar.title.localizedCaseInsensitiveContains("prayer")
            if let existing = byName[name], existing.fromPrayerCalendar || !fromPrayerCalendar { continue }
            byName[name] = (PrayerTime(name: name, time: event.start), fromPrayerCalendar)
        }
        for event in dayEvents {
            guard let found = iqama(from: event.title, on: event.start),
                  var entry = byName[found.name], entry.prayer.iqama == nil else { continue }
            entry.prayer.iqama = found.time
            entry.prayer.place = found.place
            byName[found.name] = entry
        }
        return order.compactMap { byName[$0]?.prayer }
    }
}

@MainActor
final class PrayerTimesManager: ObservableObject {
    static let shared = PrayerTimesManager()

    @Published private(set) var today: [PrayerTime] = []
    @Published private(set) var tomorrow: [PrayerTime] = []
    @Published private(set) var loadedDay: Date?

    private let service = CalendarService()
    private var observer: NSObjectProtocol?
    private var refreshTask: Task<Void, Never>?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Re-read today and tomorrow. Cheap enough to call on every page appearance.
    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: .now)
            guard let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: start),
                  let end = calendar.date(byAdding: .day, value: 2, to: start) else { return }
            let events = await service.events(from: start, to: end, calendars: [])
            guard !Task.isCancelled else { return }
            today = PrayerParsing.prayers(from: events, on: start)
            tomorrow = PrayerParsing.prayers(from: events, on: tomorrowStart)
            loadedDay = start
        }
    }

    /// The next adhan (Sunrise counts: it is when Fajr's time ends).
    func next(after now: Date) -> PrayerTime? {
        (today + tomorrow).first { $0.time > now }
    }

    /// Upcoming prayers (Sunrise excluded) after a moment, soonest first.
    func upcomingPrayers(after now: Date) -> [PrayerTime] {
        (today + tomorrow).filter { $0.isPrayer && $0.time > now }
    }

    /// The prayer whose time it is now: the last prayer (not Sunrise) already called today.
    func current(at now: Date) -> PrayerTime? {
        guard let last = today.last(where: { $0.time <= now }), last.isPrayer else { return nil }
        return last
    }
}

// MARK: - Page

struct PrayerTimesPageView: View {
    @ObservedObject private var prayers = PrayerTimesManager.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .onAppear { prayers.refresh() }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let next = prayers.next(after: now)
        let current = prayers.current(at: now)
        // After Isha, show tomorrow's list so the next prayer is on the page.
        let showingTomorrow = !prayers.today.isEmpty && prayers.today.allSatisfy { $0.time <= now }
        let list = showingTomorrow ? prayers.tomorrow : prayers.today

        VStack(alignment: .leading, spacing: 3) {
            header(next: next, now: now, tomorrow: showingTomorrow)

            if list.isEmpty {
                Text(prayers.loadedDay == nil ? "Loading…" : "No prayer times in your calendars for today.")
                    .font(.system(size: 11))
                    .foregroundStyle(.gray)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                VStack(spacing: 1) {
                    ForEach(list) { prayer in
                        row(prayer,
                            isNext: prayer.id == next?.id,
                            isCurrent: !showingTomorrow && prayer.id == current?.id,
                            isPast: !showingTomorrow && prayer.time <= now && prayer.id != current?.id)
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: Calendar.current.startOfDay(for: now)) { _, _ in prayers.refresh() }
    }

    private func header(next: PrayerTime?, now: Date, tomorrow: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(tomorrow ? "Tomorrow" : "Prayers")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
            if let next {
                Text("\(next.name) in \(Self.until(next.time, from: now))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.effectiveAccent)
                    .lineLimit(1)
            }
        }
    }

    private func row(_ prayer: PrayerTime, isNext: Bool, isCurrent: Bool, isPast: Bool) -> some View {
        let color: Color = isNext ? .effectiveAccent : (isPast ? .gray : .white)
        return HStack(spacing: 6) {
            Text(prayer.name)
                .font(.system(size: 12, weight: isNext || isCurrent ? .semibold : .regular))
                .foregroundStyle(color)
            if isCurrent {
                Circle().fill(Color.effectiveAccent).frame(width: 4, height: 4)
                    .help("Current prayer time")
            }
            Spacer(minLength: 0)
            if let iqama = prayer.iqama {
                Text("iqama \(Self.clock(iqama))")
                    .font(.system(size: 10))
                    .foregroundStyle(.gray)
                    .help(prayer.place.map { "Iqama at \($0)" } ?? "Iqama")
            }
            Text(Self.clock(prayer.time))
                .font(.system(size: 12, weight: isNext ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(color)
                .frame(width: 58, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isNext ? Color.effectiveAccent.opacity(0.15) : .clear)
        )
        .opacity(prayer.isPrayer ? 1 : 0.7)
    }

    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func until(_ date: Date, from now: Date) -> String {
        let minutes = max(0, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}

// MARK: - Card (pulled-down notch)

/// The Prayers card under the music player when the notch is pulled down.
struct PrayerCardView: View {
    @ObservedObject private var prayers = PrayerTimesManager.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            WidgetCard { content(now: context.date) }
        }
        .onAppear { prayers.refresh() }
    }

    private func content(now: Date) -> some View {
        let next = prayers.next(after: now)
        let current = prayers.current(at: now)
        let showingTomorrow = !prayers.today.isEmpty && prayers.today.allSatisfy { $0.time <= now }
        let list = showingTomorrow ? prayers.tomorrow : prayers.today

        return VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text(next.map { "\($0.name) in" } ?? (showingTomorrow ? "Tomorrow" : "Prayers"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.gray)
                if let next {
                    Text(PrayerTimesPageView.until(next.time, from: now))
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.effectiveAccent)
                }
            }

            if list.isEmpty {
                Text(prayers.loadedDay == nil ? "Loading…" : "No prayer times today.")
                    .font(.system(size: 11))
                    .foregroundStyle(.gray)
            } else {
                VStack(spacing: 1) {
                    HStack(spacing: 4) {
                        Spacer()
                        Text("iqama").frame(width: 34, alignment: .trailing)
                        Text("adhan").frame(width: 38, alignment: .trailing)
                    }
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(Color.gray.opacity(0.7))
                    .padding(.horizontal, 5)
                    ForEach(list) { prayer in
                        row(prayer,
                            isNext: prayer.id == next?.id,
                            isCurrent: !showingTomorrow && prayer.id == current?.id,
                            isPast: !showingTomorrow && prayer.time <= now && prayer.id != current?.id)
                    }
                }
            }
        }
    }

    private func row(_ prayer: PrayerTime, isNext: Bool, isCurrent: Bool, isPast: Bool) -> some View {
        let tint: Color = isNext ? .effectiveAccent : (isPast ? .gray : .white)
        return HStack(spacing: 4) {
            Text(prayer.name)
                .font(.system(size: 11.5, weight: isNext || isCurrent ? .semibold : .regular))
            if isCurrent { Circle().fill(Color.effectiveAccent).frame(width: 4, height: 4) }
            Spacer(minLength: 2)
            Text(prayer.iqama.map(Self.short) ?? "")
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.gray)
                .frame(width: 34, alignment: .trailing)
                .help(prayer.iqama == nil ? "" : "Iqama\(prayer.place.map { " at \($0)" } ?? "")")
            Text(Self.short(prayer.time))
                .font(.system(size: 11.5, weight: isNext ? .semibold : .regular))
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
        }
        .foregroundStyle(tint)
        .lineLimit(1)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5).fill(isNext ? Color.effectiveAccent.opacity(0.16) : .clear))
        .opacity(prayer.isPrayer ? 1 : 0.7)
        .help("\(prayer.name) \(PrayerTimesPageView.clock(prayer.time))")
    }

    /// "6:00", "12:48": the card is narrow, and which half of the day is obvious.
    static func short(_ date: Date) -> String {
        shortFormatter.string(from: date)
    }

    private static let shortFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"
        return formatter
    }()
}
