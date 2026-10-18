//
//  PrayerSources.swift
//  boringNotch
//
//  Where the Prayers widget gets its times (PrayerTimes.swift shows them).
//
//  - Calculated (default for new users): the free AlAdhan API
//    (https://aladhan.com/prayer-times-api) for a location the user picks, with
//    the calculation method suggested from the country (ISNA in North America,
//    Umm al-Qura in Saudi Arabia, ...). A month is fetched at a time and cached
//    on disk, so the widget keeps working offline for the rest of the month.
//  - From a calendar: any subscribed prayer-times calendar whose events are named
//    Fajr / Sunrise / Dhuhr / Asr / Maghrib / Isha (for example one from
//    prayerwebcal.dsultan.com). Useful when a local mosque publishes its own.
//  - Automatic: a prayer-times calendar if one exists, otherwise calculated.
//
//  Iqama times are read from calendar events like "Isha at My Mosque · iqama 19:45"
//  whichever source gives the adhan times.
//

import Defaults
import Foundation
import MapKit
import SwiftUI

enum PrayerSource: String, CaseIterable, Identifiable, Defaults.Serializable {
    case automatic, calculated, calendar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .calculated: "Calculated for my location"
        case .calendar: "From a prayer-times calendar"
        }
    }
}

struct PrayerLocation: Codable, Equatable, Defaults.Serializable {
    var name: String
    var latitude: Double
    var longitude: Double
    var timeZone: String
    var countryCode: String?
}

/// AlAdhan calculation methods (https://aladhan.com/calculation-methods).
enum PrayerMethod {
    static let all: [(id: Int, name: String)] = [
        (2, "ISNA (North America)"),
        (3, "Muslim World League"),
        (5, "Egyptian General Authority"),
        (4, "Umm al-Qura, Makkah"),
        (1, "University of Islamic Sciences, Karachi"),
        (15, "Moonsighting Committee Worldwide"),
        (8, "Gulf Region"),
        (9, "Kuwait"),
        (10, "Qatar"),
        (16, "Dubai"),
        (11, "Singapore (MUIS)"),
        (17, "Malaysia (JAKIM)"),
        (20, "Indonesia (KEMENAG)"),
        (13, "Turkey (Diyanet)"),
        (12, "France (UOIF)"),
        (14, "Russia (Spiritual Administration)"),
        (18, "Tunisia"),
        (19, "Algeria"),
        (21, "Morocco"),
        (22, "Portugal"),
        (23, "Jordan"),
        (7, "Tehran (Institute of Geophysics)"),
        (0, "Shia Ithna-Ashari (Jafari)"),
    ]

    static func name(_ id: Int) -> String { all.first { $0.id == id }?.name ?? "Method \(id)" }

    /// The method most mosques in a country follow; Muslim World League otherwise.
    static func suggested(forCountry code: String?) -> Int {
        switch (code ?? "").uppercased() {
        case "US", "CA": 2
        case "SA", "YE": 4
        case "EG", "SD", "SY", "LB", "LY", "IQ", "PS": 5
        case "PK", "IN", "BD", "AF": 1
        case "AE": 16
        case "KW": 9
        case "QA": 10
        case "BH", "OM": 8
        case "SG": 11
        case "MY": 17
        case "ID": 20
        case "TR": 13
        case "FR": 12
        case "RU": 14
        case "TN": 18
        case "DZ": 19
        case "MA": 21
        case "PT": 22
        case "JO": 23
        case "IR": 7
        default: 3
        }
    }
}

// MARK: - Calculated times (AlAdhan)

enum CalculatedPrayerTimes {
    /// Prayer times for one day at the chosen location, from the month cache or the API.
    @MainActor
    static func prayers(on day: Date) async -> [PrayerTime]? {
        guard let location = PrayerLocationStore.current else { return nil }
        let method = Defaults[.prayerMethod] >= 0 ? Defaults[.prayerMethod] : PrayerMethod.suggested(forCountry: location.countryCode)
        let school = Defaults[.prayerSchool]
        guard let zone = TimeZone(identifier: location.timeZone) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        // Midday of the requested day names the same date almost everywhere,
        // even when the location is many hours away from this Mac.
        let parts = calendar.dateComponents([.year, .month, .day], from: day.addingTimeInterval(12 * 3600))
        guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day else { return nil }

        guard let monthTimes = await fetchMonth(year: year, month: month, location: location, method: method, school: school) else { return nil }
        let key = String(format: "%02d-%02d-%04d", dayOfMonth, month, year)
        guard let timings = monthTimes[key] else { return nil }

        return PrayerParsing.order.compactMap { name in
            guard let text = timings[name],
                  let time = date(text, day: dayOfMonth, month: month, year: year, calendar: calendar) else { return nil }
            return PrayerTime(name: name, time: time)
        }
    }

    /// "05:52" on a given day, in the location's time zone.
    private static func date(_ text: String, day: Int, month: Int, year: Int, calendar: Calendar) -> Date? {
        let hm = text.split(separator: ":").compactMap { Int($0) }
        guard hm.count == 2 else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hm[0], minute: hm[1]))
    }

    // MARK: Month cache

    @MainActor private static var memory: [String: [String: [String: String]]] = [:]

    private static func cacheKey(_ location: PrayerLocation, method: Int, school: Int, year: Int, month: Int) -> String {
        String(format: "%.3f_%.3f_m%d_s%d_%04d-%02d", location.latitude, location.longitude, method, school, year, month)
    }

    private static var cacheDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("prayer-times", isDirectory: true)
    }

    /// date "dd-MM-yyyy" -> prayer name -> "HH:mm"
    @MainActor
    static func fetchMonth(year: Int, month: Int, location: PrayerLocation, method: Int, school: Int) async -> [String: [String: String]]? {
        let key = cacheKey(location, method: method, school: school, year: year, month: month)
        if let cached = memory[key] { return cached }
        let file = cacheDirectory?.appendingPathComponent("\(key).json")
        if let file, let data = try? Data(contentsOf: file),
           let cached = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
            memory[key] = cached
            return cached
        }

        var components = URLComponents(string: "https://api.aladhan.com/v1/calendar/\(year)/\(month)")!
        components.queryItems = [
            .init(name: "latitude", value: String(location.latitude)),
            .init(name: "longitude", value: String(location.longitude)),
            .init(name: "method", value: String(method)),
            .init(name: "school", value: String(school)),
            .init(name: "timezonestring", value: location.timeZone),
        ]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let parsed = parse(data) else { return nil }

        memory[key] = parsed
        if let file, let directory = cacheDirectory,
           let encoded = try? JSONEncoder().encode(parsed) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? encoded.write(to: file)
        }
        return parsed
    }

    private static func parse(_ data: Data) -> [String: [String: String]]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let days = json["data"] as? [[String: Any]] else { return nil }
        var out: [String: [String: String]] = [:]
        for day in days {
            guard let timings = day["timings"] as? [String: String],
                  let date = day["date"] as? [String: Any],
                  let gregorian = date["gregorian"] as? [String: Any],
                  let key = gregorian["date"] as? String else { continue }
            var kept: [String: String] = [:]
            for name in PrayerParsing.order {
                if let value = timings[name] { kept[name] = String(value.prefix(5)) }
            }
            out[key] = kept
        }
        return out.isEmpty ? nil : out
    }
}

// MARK: - Picking a location

/// City search for the prayer location: type a place, pick a suggestion.
@MainActor
final class PrayerLocationSearch: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var query = "" {
        didSet { completer.queryFragment = query }
    }
    @Published private(set) var results: [MKLocalSearchCompletion] = []
    @Published private(set) var resolving = false

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = .address
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let found = Array(completer.results.prefix(5))
        Task { @MainActor in self.results = found }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.results = [] }
    }

    /// Save the picked place as the prayer location (its country picks the method).
    func choose(_ completion: MKLocalSearchCompletion) async -> Bool {
        resolving = true
        defer { resolving = false }
        let request = MKLocalSearch.Request(completion: completion)
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { return false }
        let placemark = item.placemark
        let name = [completion.title, completion.subtitle].filter { !$0.isEmpty }.joined(separator: ", ")
        PrayerLocationStore.save(PrayerLocation(
            name: name,
            latitude: placemark.coordinate.latitude,
            longitude: placemark.coordinate.longitude,
            timeZone: (item.timeZone ?? .current).identifier,
            countryCode: placemark.isoCountryCode
        ))
        query = ""
        results = []
        return true
    }
}

enum PrayerDisplay {
    /// Times are shown in the prayer location's own clock when it's in another
    /// time zone than this Mac (someone checking a city they're travelling to).
    @MainActor
    static var timeZone: TimeZone {
        guard PrayerTimesManager.shared.activeSource == .calculated,
              let id = PrayerLocationStore.current?.timeZone,
              let zone = TimeZone(identifier: id) else { return .current }
        return zone
    }

    @MainActor
    static var isAway: Bool { timeZone.secondsFromGMT() != TimeZone.current.secondsFromGMT() }
}

enum PrayerLocationStore {
    /// The UI sandbox shares this app's settings, so it keeps its location in
    /// memory (and, with -NoorLabFreshPrayer YES, starts with none, like a new user).
    @MainActor private static var labLocation: PrayerLocation?

    @MainActor
    static var current: PrayerLocation? {
        guard NoorLab.isRequested else { return Defaults[.prayerLocation] }
        if let labLocation { return labLocation }
        return UserDefaults.standard.bool(forKey: "NoorLabFreshPrayer") ? nil : Defaults[.prayerLocation]
    }

    @MainActor
    static func save(_ location: PrayerLocation) {
        if NoorLab.isRequested {
            labLocation = location
        } else {
            Defaults[.prayerLocation] = location
            Defaults[.prayerMethod] = -1   // follow the country's usual method until changed
        }
        PrayerTimesManager.shared.refresh()
    }

    /// A prayerwebcal.dsultan.com calendar carries its location in each event's URL:
    /// .../loc/Ottawa_Ottawa_ON_Canada/cq=0:ct=0:ee=0:tz=America%2FToronto:x=45.422:y=-75.697
    static func location(fromPrayerWebcal url: URL?) -> PrayerLocation? {
        guard let url, url.host?.contains("prayerwebcal") == true else { return nil }
        let text = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        func value(_ key: String) -> String? {
            text.components(separatedBy: ":").first { $0.hasPrefix("\(key)=") }.map { String($0.dropFirst(key.count + 1)) }
        }
        guard let x = value("x").flatMap(Double.init), let y = value("y").flatMap(Double.init) else { return nil }
        let place = url.pathComponents.count > 2 ? url.pathComponents[2].replacingOccurrences(of: "_", with: " ") : "Calendar location"
        return PrayerLocation(name: place, latitude: x, longitude: y,
                              timeZone: value("tz") ?? TimeZone.current.identifier, countryCode: nil)
    }
}

/// Search field + suggestions, used in Settings and as the first-run prompt in the widget.
struct PrayerLocationPicker: View {
    @StateObject private var search = PrayerLocationSearch()
    var compact = false
    var maxResults = 5
    /// The widget hands the notch the keyboard while the field is in use.
    var onFocusChange: (Bool) -> Void = { _ in }
    var onChosen: () -> Void = {}

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: compact ? 10 : 12))
                    .foregroundStyle(.secondary)
                TextField("City, e.g. Ottawa", text: $search.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: compact ? 11.5 : 13))
                    .focused($focused)
                if search.resolving { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, compact ? 5 : 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.08)))
            .contentShape(Rectangle())
            .onTapGesture { onFocusChange(true); focused = true }
            .onChange(of: focused) { _, value in onFocusChange(value) }

            ForEach(Array(search.results.prefix(maxResults).enumerated()), id: \.offset) { _, result in
                Button {
                    Task {
                        if await search.choose(result) {
                            focused = false
                            onChosen()
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(result.title).font(.system(size: compact ? 11.5 : 12.5, weight: .medium))
                        if !result.subtitle.isEmpty {
                            Text(result.subtitle).font(.system(size: compact ? 9.5 : 10.5)).foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .noorLabPrayerSearch)) { note in
            // Lab only: type into the search like a user would.
            guard NoorLab.isRequested, let text = note.object as? String else { return }
            search.query = text
        }
        .onReceive(NotificationCenter.default.publisher(for: .noorLabPrayerPick)) { note in
            guard NoorLab.isRequested, let index = note.object as? Int, search.results.indices.contains(index) else { return }
            let result = search.results[index]
            Task { if await search.choose(result) { onChosen() } }
        }
    }
}

extension Notification.Name {
    static let noorLabPrayerSearch = Notification.Name("noorLabPrayerSearch")
    static let noorLabPrayerPick = Notification.Name("noorLabPrayerPick")
}

/// First run: no prayer-times calendar and no location yet, so the widget asks.
/// The notch takes the keyboard only while the search field is in use, and
/// stays open meanwhile (like the new-reminder field).
struct PrayerLocationPrompt: View {
    @EnvironmentObject var vm: BoringViewModel
    @State private var hostWindow: NSWindow?
    /// The pulled-down card has room for more suggestions than the pager page.
    var roomy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Pick your city for local prayer times")
                .font(.system(size: 10.5))
                .foregroundStyle(.gray)
                .fixedSize(horizontal: false, vertical: true)
            PrayerLocationPicker(compact: true, maxResults: roomy ? 4 : 2,
                                 onFocusChange: keyboard, onChosen: { keyboard(false) })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WindowReader(window: $hostWindow))
        .onDisappear { keyboard(false) }
    }

    private func keyboard(_ wanted: Bool) {
        vm.isTypingInWidget = wanted
        if let notch = hostWindow as? BoringNotchSkyLightWindow {
            notch.wantsKeyForTextInput = wanted
            if !wanted, notch.isKeyWindow { notch.resignKey() }
        } else if wanted {
            hostWindow?.makeKey()
        }
    }
}

/// Settings > Calendar > Prayer times.
struct PrayerSettingsSection: View {
    @Default(.prayerSource) private var source
    @Default(.prayerLocation) private var location
    @Default(.prayerMethod) private var method
    @Default(.prayerSchool) private var school
    @ObservedObject private var prayers = PrayerTimesManager.shared

    var body: some View {
        Section {
            Picker("Source", selection: $source) {
                ForEach(PrayerSource.allCases) { Text($0.title).tag($0) }
            }
            if source != .calendar {
                LabeledContent("Location") {
                    Text(location?.name ?? "Not set").foregroundStyle(.secondary)
                }
                PrayerLocationPicker()
                Picker("Calculation method", selection: $method) {
                    Text("Usual for \(location?.countryCode ?? "my country") (\(PrayerMethod.name(PrayerMethod.suggested(forCountry: location?.countryCode))))").tag(-1)
                    ForEach(PrayerMethod.all, id: \.id) { Text($0.name).tag($0.id) }
                }
                Picker("Asr", selection: $school) {
                    Text("Standard (Shafi'i, Maliki, Hanbali)").tag(0)
                    Text("Hanafi").tag(1)
                }
            }
            LabeledContent("Showing") {
                Text(prayers.activeSource == .calendar ? "Times from a calendar" : (location == nil ? "Waiting for a location" : "Calculated times"))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Prayer times")
        } footer: {
            Text("Calculated times come from the free AlAdhan API (aladhan.com) and are cached a month at a time. A calendar works too: subscribe to one whose events are named Fajr, Sunrise, Dhuhr, Asr, Maghrib and Isha (prayerwebcal.dsultan.com makes them). Automatic uses such a calendar if you have one. Events like \"Isha at My Mosque · iqama 19:45\" add iqama times either way.")
        }
        .onChange(of: source) { _, _ in prayers.refresh() }
        .onChange(of: method) { _, _ in prayers.refresh() }
        .onChange(of: school) { _, _ in prayers.refresh() }
    }
}
