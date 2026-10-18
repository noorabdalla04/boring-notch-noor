//
//  WidgetsTests.swift
//  boringNotchTests
//
//  The pure logic behind the widgets fork: the prayer-aware Pomodoro planner,
//  prayer-time parsing from calendar events, iqama pairing, reading a
//  prayerwebcal.dsultan.com location, and the per-country calculation method.
//

import Foundation
import XCTest
@testable import boringNotch

final class PomodoroPlannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testFitsBlocksAroundTheIdeal() {
        // (minutes until the prayer break, blocks, minutes per block)
        let cases: [(Double, Int, Int)] = [
            (150, 2, 70),   // 2.5 h: 2 x 70, not 3 x 43
            (120, 2, 55),
            (90, 1, 90),
            (393, 6, 57),   // Fajr -> Dhuhr
            (176, 3, 52),   // Dhuhr -> Asr
            (81, 1, 81),    // Maghrib -> Isha
            (40, 1, 40),
            (7, 1, 7),
        ]
        for (available, blocks, minutes) in cases {
            let fit = PomodoroPlanner.fit(available: available, ideal: 60, shortBreak: 10)
            XCTAssertEqual(fit.blocks, blocks, "window \(available)")
            XCTAssertEqual(Int(fit.focus.rounded()), minutes, "window \(available)")
        }
    }

    func testBlocksAndBreaksFillTheWindowExactly() {
        for available in stride(from: 30.0, through: 420.0, by: 7.0) {
            let fit = PomodoroPlanner.fit(available: available, ideal: 60, shortBreak: 10)
            let used = fit.focus * Double(fit.blocks) + 10 * Double(fit.blocks - 1)
            XCTAssertEqual(used, available, accuracy: 0.001, "window \(available)")
        }
    }

    func testPlansTowardTheNextPrayerAndSkipsOneAboutToStart() {
        let soon = PrayerTime(name: "Asr", time: now.addingTimeInterval(60))
        let later = PrayerTime(name: "Maghrib", time: now.addingTimeInterval(150 * 60))
        let plan = PomodoroPlanner.plan(from: now, prayers: [soon, later], ideal: 60,
                                        shortBreak: 10, leadMinutes: 0, align: true)
        XCTAssertEqual(plan.prayerName, "Maghrib")
        XCTAssertEqual(plan.blocks, 2)
        XCTAssertEqual(plan.breakStart, later.time)
    }

    func testLeadTimeMovesTheBreakBeforeTheAdhan() {
        let maghrib = PrayerTime(name: "Maghrib", time: now.addingTimeInterval(130 * 60))
        let plan = PomodoroPlanner.plan(from: now, prayers: [maghrib], ideal: 60,
                                        shortBreak: 10, leadMinutes: 10, align: true)
        XCTAssertEqual(plan.breakStart, maghrib.time.addingTimeInterval(-600))
        XCTAssertEqual(plan.blocks, 2)
        XCTAssertEqual(Int(plan.focusMinutes.rounded()), 55)
    }

    func testNoPrayerWithinEightHoursFallsBackToPlainBlocks() {
        let fajr = PrayerTime(name: "Fajr", time: now.addingTimeInterval(10 * 3600))
        let plan = PomodoroPlanner.plan(from: now, prayers: [fajr], ideal: 60,
                                        shortBreak: 10, leadMinutes: 0, align: true)
        XCTAssertFalse(plan.isAligned)
        XCTAssertEqual(plan.focusMinutes, 60)
    }

    func testSunriseIsNeverABreakTarget() {
        let sunrise = PrayerTime(name: "Sunrise", time: now.addingTimeInterval(3600))
        let dhuhr = PrayerTime(name: "Dhuhr", time: now.addingTimeInterval(5 * 3600))
        let plan = PomodoroPlanner.plan(from: now, prayers: [sunrise, dhuhr], ideal: 60,
                                        shortBreak: 10, leadMinutes: 0, align: true)
        XCTAssertEqual(plan.prayerName, "Dhuhr")
    }

    func testAlignmentOffIgnoresPrayers() {
        let asr = PrayerTime(name: "Asr", time: now.addingTimeInterval(150 * 60))
        let plan = PomodoroPlanner.plan(from: now, prayers: [asr], ideal: 45,
                                        shortBreak: 10, leadMinutes: 0, align: false)
        XCTAssertFalse(plan.isAligned)
        XCTAssertEqual(plan.focusMinutes, 45)
    }

    func testClockFormatting() {
        XCTAssertEqual(PomodoroFormat.clock(25 * 60), "25:00")
        XCTAssertEqual(PomodoroFormat.clock(70 * 60), "1:10:00")
        XCTAssertEqual(PomodoroFormat.clock(59.2), "1:00")
    }
}

final class PrayerParsingTests: XCTestCase {
    func testCanonicalNames() {
        let cases = [("Fajr", "Fajr"), ("🌅 Sunrise", "Sunrise"), ("Zuhr", "Dhuhr"), ("Dhuhr", "Dhuhr"),
                     ("Asr", "Asr"), ("Magrib", "Maghrib"), ("Isha'a", "Isha"), ("  isha ", "Isha")]
        for (raw, expected) in cases {
            XCTAssertEqual(PrayerParsing.canonicalName(raw), expected, raw)
        }
    }

    func testNonPrayerTitlesAreIgnored() {
        for raw in ["Gym", "Fajr at Mosque", "Lecture: Asr physiology", ""] {
            XCTAssertNil(PrayerParsing.canonicalName(raw), raw)
        }
    }

    func testReadsIqamaFromMosqueEvents() throws {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let found = try XCTUnwrap(PrayerParsing.iqama(from: "Isha at My Mosque · iqama 19:45", on: day))
        XCTAssertEqual(found.name, "Isha")
        XCTAssertEqual(found.place, "My Mosque")
        let parts = Calendar.current.dateComponents([.hour, .minute], from: found.time)
        XCTAssertEqual(parts.hour, 19)
        XCTAssertEqual(parts.minute, 45)
        XCTAssertEqual(PrayerParsing.iqama(from: "Fajr at Masjid - iqama 6:30", on: day)?.name, "Fajr")
        XCTAssertNil(PrayerParsing.iqama(from: "Isha at My Mosque", on: day))
    }

    func testIqamaMustFollowItsAdhanWithinTwoHours() {
        let adhan = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(PrayerParsing.plausibleIqama(adhan.addingTimeInterval(15 * 60), after: adhan))
        XCTAssertFalse(PrayerParsing.plausibleIqama(adhan.addingTimeInterval(-3 * 60), after: adhan))
        XCTAssertFalse(PrayerParsing.plausibleIqama(adhan.addingTimeInterval(3 * 3600), after: adhan))
    }
}

final class PrayerLocationTests: XCTestCase {
    func testReadsLocationFromAPrayerwebcalEventURL() throws {
        let url = URL(string: "https://prayerwebcal.dsultan.com/loc/Ottawa_Ottawa_ON_Canada/cq=0:ct=0:ee=0:tz=America%2FToronto:x=45.422:y=-75.697")
        let location = try XCTUnwrap(PrayerLocationStore.location(fromPrayerWebcal: url))
        XCTAssertEqual(location.name, "Ottawa Ottawa ON Canada")
        XCTAssertEqual(location.latitude, 45.422, accuracy: 1e-9)
        XCTAssertEqual(location.longitude, -75.697, accuracy: 1e-9)
        XCTAssertEqual(location.timeZone, "America/Toronto")
        XCTAssertNil(PrayerLocationStore.location(fromPrayerWebcal: URL(string: "https://example.com/x=1:y=2")))
    }

    func testSuggestsTheCountrysUsualMethod() {
        let cases: [(String?, Int)] = [("CA", 2), ("US", 2), ("SA", 4), ("EG", 5), ("PK", 1), ("TR", 13), ("GB", 3), (nil, 3)]
        for (country, method) in cases {
            XCTAssertEqual(PrayerMethod.suggested(forCountry: country), method, country ?? "nil")
        }
    }
}
