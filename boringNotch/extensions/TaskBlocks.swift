//
//  TaskBlocks.swift
//  boringNotch
//
//  Checking off FlowSavvy / FlowLocal task blocks straight from the notch.
//
//  An auto-scheduler puts a task on the calendar as one or more blocks. Ticking
//  a block here means "this sitting is done": its minutes become progress on
//  the task, and the scheduler re-plans the rest from now. If that was the
//  task's only block -- or its last remaining minutes -- the task is completed
//  outright instead. The ticked row disappears immediately; the calendar
//  catches up on its next sync.
//
//  Two backends, told apart by what the calendar event carries:
//  - FlowSavvy (cloud): the event's URL is https://my.flowsavvy.app/app/item/{id}/...
//    The exact block is resolved from FlowSavvy's own schedule by start time.
//  - FlowLocal (this Mac): the event's UID is blk-{id}-{occurrence}-{part}@flowlocal,
//    and FlowLocal's /api/x/items/{id}/blocks/done does the arithmetic server-side.
//

import Foundation
import Security

// MARK: - Which block an event is

enum TaskBlockBackend: String {
    case flowSavvy
    case flowLocal

    var displayName: String {
        switch self {
        case .flowSavvy: return "FlowSavvy"
        case .flowLocal: return "FlowLocal"
        }
    }
}

struct TaskBlockRef: Equatable {
    let backend: TaskBlockBackend
    let itemId: String
    /// FlowLocal only (from the UID). FlowSavvy's is read from its schedule.
    let occurrenceDate: String?
    /// FlowLocal only (from the UID).
    let partIndex: Int?

    /// `blk-{ULID}-{yyyy-MM-dd | -}-{part}@flowlocal`. ULIDs never contain a hyphen,
    /// so the split is unambiguous.
    static func flowLocal(uid: String) -> TaskBlockRef? {
        let pattern = #"^blk-([0-9A-Z]{26})-(\d{4}-\d{2}-\d{2}|-)-(\d+)@flowlocal$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: uid, range: NSRange(uid.startIndex..., in: uid)),
              let idRange = Range(match.range(at: 1), in: uid),
              let occRange = Range(match.range(at: 2), in: uid),
              let partRange = Range(match.range(at: 3), in: uid),
              let part = Int(uid[partRange])
        else { return nil }
        let occurrence = String(uid[occRange])
        return TaskBlockRef(
            backend: .flowLocal,
            itemId: String(uid[idRange]),
            occurrenceDate: occurrence == "-" ? nil : occurrence,
            partIndex: part
        )
    }

    static func isFlowSavvyTaskStamp(_ notes: String) -> Bool {
        notes.range(
            of: #"represents an? (auto-scheduled )?task from FlowSavvy"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    /// `https://my.flowsavvy.app/app/item/{id}[/...]`
    static func flowSavvy(url: URL) -> TaskBlockRef? {
        guard url.host?.lowercased() == "my.flowsavvy.app" else { return nil }
        let parts = url.pathComponents
        guard let index = parts.firstIndex(of: "item"), index + 1 < parts.count else { return nil }
        let id = parts[index + 1]
        guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return TaskBlockRef(backend: .flowSavvy, itemId: id, occurrenceDate: nil, partIndex: nil)
    }
}

extension EventModel {
    /// The scheduler block this event represents, if any.
    ///
    /// FlowSavvy links *events* to `/app/item/{id}` exactly like task blocks, so the
    /// link alone would put a checkbox on prayers, lectures and the gym. Task blocks are
    /// the ones FlowSavvy stamps: "This event represents an auto-scheduled task from FlowSavvy."
    var taskBlock: TaskBlockRef? {
        guard !type.isReminder, !isAllDay else { return nil }
        if let uid = externalId, let ref = TaskBlockRef.flowLocal(uid: uid) { return ref }
        if let url, let ref = TaskBlockRef.flowSavvy(url: url) { return ref }
        return nil
    }

    /// Auto-scheduled FlowSavvy blocks carry this note. Fixed-time tasks do NOT (verified
    /// live), which is why FlowSavvy's schedule is also consulted -- see TaskBlockCompleter.
    var hasFlowSavvyTaskStamp: Bool {
        guard let notes else { return false }
        return TaskBlockRef.isFlowSavvyTaskStamp(notes)
    }

    /// Identity of this block *at this time*. If the scheduler later moves the same
    /// calendar event to a new slot for the remaining work, it is a different key and
    /// shows again rather than staying hidden.
    var taskBlockKey: String { "\(id)|\(Int(start.timeIntervalSince1970))" }
}

// MARK: - Wall-clock stamps (both APIs use local time with no offset)

enum LocalStamp {
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = format
        return f
    }

    static func dateTime(_ date: Date) -> String { formatter("yyyy-MM-dd'T'HH:mm:ss").string(from: date) }
    static func day(_ date: Date) -> String { formatter("yyyy-MM-dd").string(from: date) }
    /// Minute precision, for matching a block whose seconds may be rendered either way.
    static func minute(_ text: String) -> String { String(text.prefix(16)) }
}

// MARK: - Credentials

enum FlowSavvyKeychain {
    private static let service = "boringnotch.flowsavvy"
    private static let account = "api-key"

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty
        else { return nil }
        return key
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        delete()
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum FlowLocalKey {
    /// The real home directory. In the sandbox `NSHomeDirectory()` is the container,
    /// which is not where FlowLocal keeps its secrets.
    private static var realHome: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }

    static var path: String { realHome + "/Library/Application Support/flowlocal/secrets.toml" }

    /// Read fresh on every tick so a rotated key just works.
    static func read() -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #"(?m)^\s*api_key\s*=\s*"([^"]+)""#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }
}

// MARK: - Errors and outcomes

enum TaskTickError: LocalizedError {
    case noFlowSavvyKey
    case noFlowLocalKey
    case blockMoved
    case notATask
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noFlowSavvyKey:
            return "Add your FlowSavvy API key in Settings → Calendar."
        case .noFlowLocalKey:
            return "Couldn't read FlowLocal's API key. Is FlowLocal set up on this Mac?"
        case .blockMoved:
            return "The schedule moved since this was shown. It'll refresh shortly."
        case .notATask:
            return "That's an event, not a task block."
        case .http(let status, let message):
            return message.isEmpty ? "Request failed (\(status))." : "\(message) (\(status))"
        case .badResponse:
            return "Unexpected response from the scheduler."
        }
    }
}

enum TaskTickOutcome: Equatable {
    case completed
    case progress(credited: Int, remaining: Int)
}

// MARK: - HTTP

private struct SchedulerAPI {
    let base: String
    let key: String

    func send(
        _ method: String,
        _ path: String,
        query: [String: String?] = [:],
        json: Any? = nil
    ) async throws -> Data {
        guard var components = URLComponents(string: base + path) else { throw TaskTickError.badResponse }
        let items = query.compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
        if !items.isEmpty { components.queryItems = items.sorted { $0.name < $1.name } }
        guard let url = components.url else { throw TaskTickError.badResponse }

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TaskTickError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 404, path.contains("/blocks/done") { throw TaskTickError.blockMoved }
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw TaskTickError.http(http.statusCode, body?["message"] as? String ?? "")
        }
        return data
    }

    func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TaskTickError.badResponse
        }
        return object
    }
}

// MARK: - The two ticks

enum TaskTicker {
    /// FlowSavvy item ids that are tasks (not events) on a day, from FlowSavvy's own schedule.
    static func flowSavvyTaskIds(day: String) async throws -> Set<String> {
        guard let key = FlowSavvyKeychain.read() else { throw TaskTickError.noFlowSavvyKey }
        let api = SchedulerAPI(base: "https://my.flowsavvy.app", key: key)
        let schedule = try api.object(
            try await api.send("GET", "/api/schedule", query: ["startDate": day, "endDate": day])
        )
        let items = schedule["scheduleItems"] as? [[String: Any]] ?? []
        return Set(items.compactMap { item in
            (item["itemType"] as? String) == "task" ? item["itemId"] as? String : nil
        })
    }

    static func tick(_ ref: TaskBlockRef, start: Date, end: Date) async throws -> TaskTickOutcome {
        switch ref.backend {
        case .flowSavvy: return try await tickFlowSavvy(ref, start: start, end: end)
        case .flowLocal: return try await tickFlowLocal(ref, start: start)
        }
    }

    /// FlowLocal does the arithmetic itself (FR-API-020).
    private static func tickFlowLocal(_ ref: TaskBlockRef, start: Date) async throws -> TaskTickOutcome {
        guard let key = FlowLocalKey.read() else { throw TaskTickError.noFlowLocalKey }
        let api = SchedulerAPI(base: "http://127.0.0.1:7373", key: key)
        let data = try await api.send(
            "POST",
            "/api/x/items/\(ref.itemId)/blocks/done",
            query: [
                "partIndex": String(ref.partIndex ?? 1),
                "startDateTime": LocalStamp.dateTime(start),
                "occurrenceDate": ref.occurrenceDate,
            ]
        )
        let body = try api.object(data)
        if body["action"] as? String == "completed" { return .completed }
        return .progress(
            credited: body["creditedMinutes"] as? Int ?? 0,
            remaining: body["remainingMinutes"] as? Int ?? 0
        )
    }

    /// FlowSavvy's public API has no part-completion call, so the same rule is applied
    /// through the documented operations: progress via a full-replace PUT of the task
    /// exactly as GET returned it (only `progressMinutes` changes), or `complete`.
    private static func tickFlowSavvy(_ ref: TaskBlockRef, start: Date, end: Date) async throws -> TaskTickOutcome {
        guard let key = FlowSavvyKeychain.read() else { throw TaskTickError.noFlowSavvyKey }
        let api = SchedulerAPI(base: "https://my.flowsavvy.app", key: key)

        // 1. Which block, and which occurrence, this is -- from FlowSavvy's own schedule.
        let day = LocalStamp.day(start)
        let schedule = try api.object(
            try await api.send("GET", "/api/schedule", query: ["startDate": day, "endDate": day])
        )
        let wanted = LocalStamp.minute(LocalStamp.dateTime(start))
        let items = schedule["scheduleItems"] as? [[String: Any]] ?? []
        guard let block = items.first(where: { item in
            (item["itemId"] as? String) == ref.itemId
                && LocalStamp.minute(item["startTime"] as? String ?? "") == wanted
        }) else { throw TaskTickError.blockMoved }
        guard (block["itemType"] as? String ?? "task") == "task" else { throw TaskTickError.notATask }

        let occurrence = block["occurrenceDate"] as? String
        let isAuto = block["isAutoScheduled"] as? Bool ?? true
        let minutes = max(1, Int(end.timeIntervalSince(start) / 60))

        // 2. How much of the task is left.
        let taskPath = "/api/tasks/\(ref.itemId)"
        var task = try api.object(
            try await api.send("GET", "/api/items/\(ref.itemId)", query: ["occurrenceDate": occurrence])
        )
        let duration = task["durationMinutes"] as? Int ?? 0
        let progress = task["progressMinutes"] as? Int ?? 0
        let remaining = max(0, duration - progress)

        // 3. Last of it (or a fixed-time task): complete. Otherwise: credit the minutes.
        if !isAuto || minutes >= remaining {
            _ = try await api.send("POST", taskPath + "/complete", query: ["occurrenceDate": occurrence])
            return .completed
        }
        task["progressMinutes"] = progress + minutes
        _ = try await api.send(
            "PUT",
            taskPath,
            query: [
                "occurrenceDate": occurrence,
                "scope": occurrence == nil ? nil : "thisOccurrence",
            ],
            json: task
        )
        return .progress(credited: minutes, remaining: remaining - minutes)
    }
}

// MARK: - State the calendar view observes

@MainActor
final class TaskBlockCompleter: ObservableObject {
    static let shared = TaskBlockCompleter()

    struct Failure: Equatable {
        let eventID: String
        let message: String
    }

    /// Ticked successfully: hidden until the calendar sync removes the block for real.
    @Published private(set) var done: Set<String> = []
    @Published private(set) var pending: Set<String> = []
    @Published private(set) var failure: Failure?

    /// Per day: FlowSavvy item ids that are tasks, and when that was fetched.
    @Published private(set) var flowSavvyTasks: [String: (ids: Set<String>, at: Date)] = [:]
    private var fetching: Set<String> = []
    private static let cacheLifetime: TimeInterval = 300

    private init() {}

    /// Whether a row gets a checkbox. FlowLocal blocks always (their UID only exists on
    /// task blocks). FlowSavvy: if the note says so, or FlowSavvy's schedule lists the
    /// item as a task -- which also covers fixed-time tasks, whose notes carry no stamp.
    func showsCheckbox(_ event: EventModel) -> Bool {
        guard let ref = event.taskBlock else { return false }
        switch ref.backend {
        case .flowLocal:
            return true
        case .flowSavvy:
            if event.hasFlowSavvyTaskStamp { return true }
            return flowSavvyTasks[LocalStamp.day(event.start)]?.ids.contains(ref.itemId) ?? false
        }
    }

    /// Learn which FlowSavvy-linked rows are tasks, for the days on screen.
    func prefetch(for events: [EventModel]) {
        guard FlowSavvyKeychain.read() != nil else { return }
        let days = Set(events.compactMap { event -> String? in
            guard let ref = event.taskBlock, ref.backend == .flowSavvy, !event.hasFlowSavvyTaskStamp
            else { return nil }
            return LocalStamp.day(event.start)
        })
        for day in days {
            if let cached = flowSavvyTasks[day], Date().timeIntervalSince(cached.at) < Self.cacheLifetime { continue }
            guard !fetching.contains(day) else { continue }
            fetching.insert(day)
            Task { @MainActor in
                if let ids = try? await TaskTicker.flowSavvyTaskIds(day: day) {
                    flowSavvyTasks[day] = (ids, Date())
                }
                fetching.remove(day)
            }
        }
    }

    func tick(_ event: EventModel) {
        let key = event.taskBlockKey
        guard showsCheckbox(event), let ref = event.taskBlock, !pending.contains(key), !done.contains(key) else { return }
        pending.insert(key)
        if failure?.eventID == key { failure = nil }

        Task { @MainActor in
            do {
                _ = try await TaskTicker.tick(ref, start: event.start, end: event.end)
                done.insert(key)
            } catch {
                failure = Failure(
                    eventID: key,
                    message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }
            pending.remove(key)
        }
    }

    func isHidden(_ event: EventModel) -> Bool { done.contains(event.taskBlockKey) }
    func isPending(_ event: EventModel) -> Bool { pending.contains(event.taskBlockKey) }
    func failureMessage(for event: EventModel) -> String? {
        failure?.eventID == event.taskBlockKey ? failure?.message : nil
    }
}
