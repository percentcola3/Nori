import Foundation
import Darwin

enum TestFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case .failed(let message): return message }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw TestFailure.failed(message) }
}

@main
struct ScheduledAutomationTests {
    @MainActor
    static func main() throws {
        func pass(_ name: String) { print("PASS: \(name)") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 4))!
        let scheduled = SmartTriggerRule(name: "daily", condition: .daily(hour: 3),
                                        action: .quickCleanSafe, scope: .allSafe)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let persistenceBlocker = temp.appendingPathComponent("blocker")
        try Data("block".utf8).write(to: persistenceBlocker)
        let automationFile = temp.appendingPathComponent("automation.json")
        let automationStore = AutomationStore(fileURL: automationFile)
        automationStore.add(SmartTriggerRule(name: "review", isEnabled: true,
                                             condition: .daily(hour: 3),
                                             action: .quickCleanSafe, scope: .allSafe))
        try expect(automationStore.triggers.count == 1 &&
                   !automationStore.triggers[0].isEnabled,
                   "new automation was enabled without review")
        let armedAt = calendar.date(from: DateComponents(
            year: 2027, month: 1, day: 15, hour: 2, minute: 0))!
        let firstSchedule = calendar.date(from: DateComponents(
            year: 2027, month: 1, day: 15, hour: 3, minute: 0))!
        automationStore.setEnabled(true, id: automationStore.triggers[0].id, at: armedAt)
        try expect(automationStore.triggers[0].isEnabled, "valid reviewed trigger could not enable")
        try expect(automationStore.triggers[0].armedAt == armedAt,
                   "enable baseline was not captured")
        let armedRule = automationStore.triggers[0]
        try expect(SmartTriggerEvaluator.evaluate(
            armedRule, context: .init(now: armedAt), calendar: calendar).skipReason
                == .scheduleNotDue,
            "enabling at 02:00 backfilled the previous daily schedule")
        try expect(SmartTriggerEvaluator.evaluate(
            armedRule, context: .init(now: firstSchedule), calendar: calendar).shouldRun,
            "03:00 first normal schedule was postponed")
        try expect(SmartTriggerEvaluator.evaluate(
            armedRule, context: .init(now: firstSchedule.addingTimeInterval(37 * 60)),
            calendar: calendar).shouldRun,
            "03:xx did not consume the first normal schedule")

        // ISO-8601 persistence drops fractional seconds. The stored baseline must
        // round upward so enabling just after 03:00 cannot become 03:00 on reload.
        let justAfterSchedule = firstSchedule.addingTimeInterval(0.25)
        automationStore.setEnabled(true, id: armedRule.id, at: justAfterSchedule)
        let rearmedRule = automationStore.triggers[0]
        try expect(rearmedRule.armedAt == firstSchedule.addingTimeInterval(1),
                   "subsecond enable baseline was rounded backward")
        let reloadedRearmedRule = try requireRule(AutomationStore.load(from: automationFile).first,
                                                 "reloaded re-armed rule")
        try expect(SmartTriggerEvaluator.evaluate(
            reloadedRearmedRule,
            context: .init(now: firstSchedule.addingTimeInterval(37 * 60)),
            calendar: calendar).skipReason == .scheduleNotDue,
            "reload backfilled a schedule from before the enable instant")
        let persistedText = String(decoding: try Data(contentsOf: automationFile), as: UTF8.self)
        try expect(!persistedText.lowercased().contains("script") &&
                   !persistedText.lowercased().contains("command"),
                   "automation persistence contains executable text")

        // schema v1 rules had no armedAt. Keep them enabled but re-arm from migration
        // time, then persist the baseline so relaunches do not keep postponing it.
        let legacyFile = temp.appendingPathComponent("automation-legacy.json")
        try AutomationStore.save([armedRule], to: legacyFile)
        var legacyPayload = try requireJSONObject(at: legacyFile)
        var legacyTriggers = legacyPayload["triggers"] as? [[String: Any]] ?? []
        try expect(legacyTriggers.count == 1, "legacy fixture lost its rule")
        legacyTriggers[0].removeValue(forKey: "armedAt")
        legacyPayload["triggers"] = legacyTriggers
        try JSONSerialization.data(withJSONObject: legacyPayload, options: [.sortedKeys])
            .write(to: legacyFile, options: .atomic)
        let migrationTime = armedAt.addingTimeInterval(30 * 60)
        let migratedStore = AutomationStore(fileURL: legacyFile, now: migrationTime)
        try expect(migratedStore.triggers.first?.isEnabled == true &&
                   migratedStore.triggers.first?.armedAt == migrationTime,
                   "legacy enabled rule was not conservatively re-armed")
        try expect(AutomationStore.load(from: legacyFile).first?.armedAt == migrationTime,
                   "migrated enable baseline was not persisted")
        let corruptAutomationFile = temp.appendingPathComponent("automation-corrupt.json")
        try Data("not-json".utf8).write(to: corruptAutomationFile)
        let corruptAutomationStore = AutomationStore(fileURL: corruptAutomationFile)
        try expect(corruptAutomationStore.triggers.isEmpty
                   && corruptAutomationStore.lastError != nil,
                   "corrupt automation data was silently treated as empty")
        let failingAutomationStore = AutomationStore(
            fileURL: persistenceBlocker.appendingPathComponent("automation.json"))
        try expect(!failingAutomationStore.add(scheduled)
                   && failingAutomationStore.triggers.isEmpty
                   && failingAutomationStore.lastError != nil,
                   "failed automation mutation was published")

        let cooldownFile = temp.appendingPathComponent("cooldown.json")
        let cooldownStore = AutomationStore(fileURL: cooldownFile)
        try expect(cooldownStore.add(scheduled), "cooldown test rule was not stored")
        let cooldownID = cooldownStore.triggers[0].id
        try expect(cooldownStore.setEnabled(true, id: cooldownID, at: armedAt),
                   "cooldown test rule was not enabled")
        try FileManager.default.removeItem(at: cooldownFile)
        try FileManager.default.createDirectory(at: cooldownFile,
                                                withIntermediateDirectories: false)
        try expect(!cooldownStore.markFired(id: cooldownID, at: now)
                   && cooldownStore.triggers[0].lastFiredAt == now
                   && cooldownStore.lastError != nil,
                   "persistence failure allowed an in-process trigger refire")
        pass("automation store is separate, review-gated, and non-executable")


        var mixed = try requireJSONObject(at: automationFile)
        var records = mixed["triggers"] as! [[String: Any]]
        var retired = records[0]
        retired["action"] = "hibernateProjectSafeArtifacts"
        retired["condition"] = ["kind": "projectInactive", "days": 30]
        records.append(retired)
        retired["action"] = "cleanSavedLocationSafe"
        records.append(retired)
        mixed["triggers"] = records
        try JSONSerialization.data(withJSONObject: mixed).write(to: automationFile)
        let mixedStore = AutomationStore(fileURL: automationFile)
        try expect(mixedStore.triggers.count == 1 && mixedStore.lastError == nil,
                   "retired rules must not disable supported schedules")
        let weekly = SmartTriggerRule(name: "weekly", isEnabled: true,
            condition: .weekly(weekday: 6, hour: 3), action: .quickCleanSafe,
            scope: .allSafe, armedAt: armedAt)
        try expect(SmartTriggerEvaluator.evaluate(weekly, context: .init(now: now),
                   calendar: calendar).shouldRun, "weekly schedule stopped working")
        print("Scheduled automation tests passed")
    }

    private static func requireJSONObject(at url: URL) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let dictionary = object as? [String: Any] else {
            throw TestFailure.failed("automation fixture was not a JSON object")
        }
        return dictionary
    }

    private static func requireRule(_ rule: SmartTriggerRule?,
                                    _ name: String) throws -> SmartTriggerRule {
        guard let rule else { throw TestFailure.failed("missing \(name)") }
        return rule
    }
}
