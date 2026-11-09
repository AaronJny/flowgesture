#!/usr/bin/env swift
// Read-only diagnostic, separate from FlowGestureCapture. This cannot grant
// capture admission. No taps, input, permission preflights/requests, or mutations.
//
// Live: FLOWGESTURE_RUN_CONSOLE_SESSION_PROBE=1 \
//       FLOWGESTURE_PROBE_SOURCE_REVISION=<operator-reported 40-hex revision> \
//       swift scripts/probe-console-session.swift --probe
// Synthetic only: swift scripts/probe-console-session.swift --self-test
//
// Source-backed keys/types and matching, pinned to Apple originals:
// https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/iokit/IOKit/IOKitKeysPrivate.h#L35-L50
// https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/iokit/Kernel/IOService.cpp#L7484-L7553
// https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/iokit/Kernel/IOUserClient.cpp#L1466-L1491
// SessionGetInfo(callerSecuritySession) returns this process's audit session:
// https://github.com/apple-oss-distributions/Security/blob/db15acbe6a7f257a859ad9a3bb86097bfe0679d9/OSX/libsecurity_authorization/lib/Authorization.cpp#L42-L61
// https://github.com/apple-oss-distributions/Security/blob/db15acbe6a7f257a859ad9a3bb86097bfe0679d9/OSX/libsecurity_utilities/lib/ccaudit.h#L89-L96
// https://github.com/apple-oss-distributions/Security/blob/db15acbe6a7f257a859ad9a3bb86097bfe0679d9/OSX/libsecurity_utilities/lib/ccaudit.cpp#L54-L58
// Single-property API and OSBoolean -> CFBoolean mapping:
// https://github.com/apple-oss-distributions/IOKitUser/blob/323ead896d04424f87184d8f6ff0cce811aab106/IOKitLib.h#L1177-L1192

import CoreFoundation
import Foundation
#if os(macOS)
import Darwin
import IOKit
import Security
#elseif canImport(Glibc)
import Glibc
#endif

private enum Keys {
    static let users = "IOConsoleUsers"
    static let audit = "kCGSSessionAuditIDKey"
    static let uid = "kCGSSessionUserIDKey"
    static let onConsole = "kCGSSessionOnConsoleKey"
    static let loginDone = "kCGSessionLoginDoneKey"
    static let locked = "CGSSessionScreenIsLocked"
}

private enum BooleanObservation: Equatable {
    case notInspected, missing, unexpectedType, boolean(Bool)

    init(_ value: Any?) {
        guard let value else { self = .missing; return }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            self = .unexpectedType
            return
        }
        self = .boolean(number.boolValue)
    }

    var isExplicitBoolean: Bool {
        if case .boolean = self { return true }
        return false
    }

    var json: [String: Any] {
        switch self {
        case .notInspected:
            return ["present": NSNull(), "type": "not_inspected", "value": NSNull()]
        case .missing:
            return ["present": false, "type": "missing", "value": NSNull()]
        case .unexpectedType:
            // Never serialize the original value, its description, or class name.
            return ["present": true, "type": "unexpected_type", "value": NSNull()]
        case .boolean(let value):
            return ["present": true, "type": "CFBoolean", "value": value]
        }
    }
}

private struct Selection {
    let status: String
    let matchCount: Int?
    var onConsole: BooleanObservation = .notInspected
    var loginDone: BooleanObservation = .notInspected
    var locked: BooleanObservation = .notInspected

    var allFieldsObserved: Bool {
        onConsole.isExplicitBoolean && loginDone.isExplicitBoolean && locked.isExplicitBoolean
    }

    var fields: [String: Any] {
        ["onConsole": onConsole.json, "loginDone": loginDone.json, "screenLocked": locked.json]
    }
}

private enum SessionSelection {
    static let maximumRecords = 256

    // OSNumber IDs must be actual integral CFNumbers in UInt32 range. Reject
    // CFBoolean, strings, floating point, and truncation rather than coerce them.
    static func identifier(_ value: Any?) -> UInt32? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFNumberGetTypeID(),
              ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"].contains(String(cString: number.objCType)),
              number.compare(NSNumber(value: 0)) != .orderedAscending,
              number.compare(NSNumber(value: UInt32.max)) != .orderedDescending else { return nil }
        return number.uint32Value
    }

    static func inspect(_ property: Any?, currentUID: UInt32, currentAuditSession: UInt32) -> Selection {
        guard let property else { return Selection(status: "property_missing", matchCount: nil) }
        guard let records = property as? NSArray else {
            return Selection(status: "property_unexpected_type", matchCount: nil)
        }
        guard records.count <= maximumRecords else {
            return Selection(status: "record_limit_exceeded", matchCount: nil)
        }
        var matches = [NSDictionary]()
        for item in records {
            guard let record = item as? NSDictionary,
                  let uid = identifier(record[Keys.uid]),
                  let audit = identifier(record[Keys.audit]) else {
                // An unparseable identity might be another matching record. Do
                // not report a partial count or inspect any record's booleans.
                return Selection(status: "record_identity_unknown", matchCount: nil)
            }
            if uid == currentUID && audit == currentAuditSession { matches.append(record) }
        }
        guard matches.count == 1, let record = matches.first else {
            return Selection(status: matches.isEmpty ? "no_current_session_match" : "ambiguous_current_session_match",
                             matchCount: matches.count)
        }
        // Only now read the three fields, and only from this process's unique
        // UID + audit-session record. Other sessions' state is never inspected.
        return Selection(status: "unique_current_session_match", matchCount: 1,
                         onConsole: BooleanObservation(record[Keys.onConsole]),
                         loginDone: BooleanObservation(record[Keys.loginDone]),
                         locked: BooleanObservation(record[Keys.locked]))
    }
}

private struct ReadStatus {
    var callerSession = "not_attempted"
    var ioConsoleUsers = "not_attempted"
    var callerIdentityRecheck = "not_attempted"

    var json: [String: String] {
        ["callerSession": callerSession, "ioConsoleUsers": ioConsoleUsers,
         "callerIdentityRecheck": callerIdentityRecheck]
    }
}

private enum Report {
    static func sourceRevision(_ value: String?) -> String? {
        guard let value, value.utf8.count == 40,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        return value.lowercased()
    }

    static func make(selection: Selection, reads: ReadStatus, osVersion: String, osBuild: String?,
                     sourceRevision: String?) -> [String: Any] {
        [
            "schemaVersion": 1,
            "mode": "read_only_console_session_probe",
            "scope": "one_instantaneous_IOConsoleUsers_snapshot_current_process_UID_and_audit_session_only_not_unlock_authorization_or_physical_input_validation",
            "reads": reads.json,
            "selectionStatus": selection.status,
            "currentRecordMatchCount": selection.matchCount.map { $0 as Any } ?? NSNull(),
            "fieldStatus": selection.allFieldsObserved ? "three_explicit_booleans_observed" : "unknown",
            "fields": selection.fields,
            "osVersion": osVersion,
            "osBuild": osBuild.map { $0 as Any } ?? NSNull(),
            "sourceRevision": sourceRevision.map { $0 as Any } ?? NSNull(),
            "sourceRevisionVerification": sourceRevision == nil ? "unknown" : "operator_reported_unverified_not_binary_attestation"
        ]
    }

    static func write(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
}

#if os(macOS)
private enum LiveProbe {
    static func ownIdentity() -> (uid: UInt32, audit: UInt32)? {
        let uid = getuid()
        guard uid == geteuid() else { return nil }
        var audit: SecuritySessionId = 0
        guard SessionGetInfo(callerSecuritySession, &audit, nil) == errSecSuccess,
              audit != noSecuritySession, audit != callerSecuritySession,
              uid == getuid(), uid == geteuid() else { return nil }
        return (uid, audit)
    }

    static func osBuild() -> String? {
        var length = 0
        guard sysctlbyname("kern.osversion", nil, &length, nil, 0) == 0,
              length > 0, length <= 256 else { return nil }
        var bytes = [CChar](repeating: 0, count: length)
        guard sysctlbyname("kern.osversion", &bytes, &length, nil, 0) == 0,
              let end = bytes.firstIndex(of: 0) else { return nil }
        return String(decoding: bytes.prefix(end).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func run(revision: String?) -> [String: Any] {
        var reads = ReadStatus()
        var selection = Selection(status: "not_inspected", matchCount: nil)
        // No process or session identifiers are returned in the report.
        func finish() -> [String: Any] {
            let version = ProcessInfo.processInfo.operatingSystemVersion
            return Report.make(selection: selection, reads: reads,
                               osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
                               osBuild: osBuild(), sourceRevision: revision)
        }
        guard let before = ownIdentity() else {
            reads.callerSession = "failed_or_current_identity_unknown"
            return finish()
        }
        reads.callerSession = "success"
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else {
            reads.ioConsoleUsers = "registry_root_unavailable"
            return finish()
        }
        defer { IOObjectRelease(root) }
        // Read ONLY this named property. Do not dump the registry, dictionaries,
        // usernames, or other sessions, and do not use aggregate IOConsoleLocked.
        guard let property = IORegistryEntryCreateCFProperty(root, Keys.users as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            reads.ioConsoleUsers = "property_unavailable"
            return finish()
        }
        reads.ioConsoleUsers = "success"
        guard let after = ownIdentity(), before.uid == after.uid, before.audit == after.audit else {
            reads.callerIdentityRecheck = "failed_or_changed"
            return finish()
        }
        reads.callerIdentityRecheck = "success_unchanged"
        selection = SessionSelection.inspect(property, currentUID: before.uid, currentAuditSession: before.audit)
        return finish()
    }
}
#endif

private enum SyntheticTests {
    struct Failure: Error {}

    static func run() throws -> Int {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool) throws {
            guard condition() else { throw Failure() }
            checks += 1
        }
        func record(uid: Any = NSNumber(value: 501), audit: Any = NSNumber(value: 123)) -> [String: Any] {
            [Keys.uid: uid, Keys.audit: audit, Keys.onConsole: true, Keys.loginDone: true, Keys.locked: false,
             "kCGSSessionUserNameKey": "PRIVATE_FIXTURE_MUST_NOT_ESCAPE", "otherPayload": "PRIVATE_FIXTURE_MUST_NOT_ESCAPE"]
        }
        func inspect(_ property: Any?) -> Selection {
            SessionSelection.inspect(property, currentUID: 501, currentAuditSession: 123)
        }
        let valid = inspect([record()])
        try expect(valid.status == "unique_current_session_match" && valid.matchCount == 1)
        try expect(valid.allFieldsObserved && valid.locked == .boolean(false))
        var missing = record()
        missing.removeValue(forKey: Keys.locked)
        let absent = inspect([missing])
        try expect(absent.locked == .missing && !absent.allFieldsObserved)
        for key in [Keys.onConsole, Keys.loginDone, Keys.locked] {
            for wrong in [NSNumber(value: 1), "false", NSNull(), ["private": "PRIVATE_FIXTURE_MUST_NOT_ESCAPE"]] as [Any] {
                var malformed = record()
                malformed[key] = wrong
                let result = inspect([malformed])
                try expect(!result.allFieldsObserved && result.fields.values.contains { value in
                    (value as? [String: Any])?["type"] as? String == "unexpected_type"
                })
            }
        }
        var locked = record()
        locked[Keys.locked] = true
        try expect(inspect([locked]).locked == .boolean(true))
        var notConsole = record()
        notConsole[Keys.onConsole] = false
        try expect(inspect([notConsole]).onConsole == .boolean(false))
        try expect(inspect([record(), record()]).status == "ambiguous_current_session_match")
        try expect(inspect([record(), record()]).matchCount == 2)
        try expect(inspect([record(), record()]).locked == .notInspected)
        let otherAudit = record(audit: NSNumber(value: 124))
        let otherUser = record(uid: NSNumber(value: 502))
        try expect(inspect([otherAudit, record(), otherUser]).matchCount == 1)
        try expect(inspect([otherAudit, otherUser]).status == "no_current_session_match")
        try expect(inspect([otherAudit, otherUser]).matchCount == 0)
        for badID in [true, "501", NSNumber(value: -1), NSNumber(value: UInt64(UInt32.max) + 1), NSNumber(value: 501.5), NSNull()] as [Any] {
            try expect(inspect([record(uid: badID)]).status == "record_identity_unknown")
            try expect(inspect([record(audit: badID)]).matchCount == nil)
        }
        // An identity-malformed second record invalidates an otherwise exact match.
        try expect(inspect([record(), record(audit: "unverified")]).locked == .notInspected)
        try expect(inspect(nil).status == "property_missing")
        try expect(inspect("PRIVATE_FIXTURE_MUST_NOT_ESCAPE").status == "property_unexpected_type")
        try expect(inspect(["PRIVATE_FIXTURE_MUST_NOT_ESCAPE"]).status == "record_identity_unknown")
        try expect(inspect([]).matchCount == 0)
        try expect(inspect(Array(repeating: otherAudit, count: SessionSelection.maximumRecords)).matchCount == 0)
        try expect(inspect(Array(repeating: record(), count: SessionSelection.maximumRecords + 1)).status == "record_limit_exceeded")
        try expect(SessionSelection.identifier(NSNumber(value: UInt32.max)) == UInt32.max)
        try expect(SessionSelection.identifier(NSNumber(value: 0)) == 0)
        try expect(Report.sourceRevision(String(repeating: "A", count: 40)) == String(repeating: "a", count: 40))
        try expect(Report.sourceRevision("PRIVATE_FIXTURE_MUST_NOT_ESCAPE") == nil)
        try expect(Report.sourceRevision(String(repeating: "g", count: 40)) == nil)
        try expect(Report.sourceRevision(nil) == nil)

        let expectedTopKeys: Set<String> = ["schemaVersion", "mode", "scope", "reads", "selectionStatus", "currentRecordMatchCount", "fieldStatus", "fields", "osVersion", "osBuild", "sourceRevision", "sourceRevisionVerification"]
        for selection in [valid, absent, inspect([record(), record()]), inspect([otherAudit]), inspect(nil)] {
            let report = Report.make(selection: selection, reads: ReadStatus(), osVersion: "synthetic", osBuild: nil, sourceRevision: nil)
            try expect(Set(report.keys) == expectedTopKeys)
            try expect(Set((report["reads"] as? [String: String] ?? [:]).keys) == ["callerSession", "ioConsoleUsers", "callerIdentityRecheck"])
            let encoded = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            let decoded = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            let text = String(decoding: encoded, as: UTF8.self)
            try expect(decoded != nil && !text.contains("PRIVATE_FIXTURE_MUST_NOT_ESCAPE"))
            try expect(!text.contains(Keys.uid) && !text.contains(Keys.audit) && !text.contains("kCGSSessionUserNameKey"))
            try expect(Set(selection.fields.keys) == ["onConsole", "loginDone", "screenLocked"])
            for field in selection.fields.values {
                guard let object = field as? [String: Any] else { throw Failure() }
                try expect(Set(object.keys) == ["present", "type", "value"])
                if object["type"] as? String != "CFBoolean" { try expect(object["value"] is NSNull) }
            }
        }
        return checks
    }
}

private func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--self-test"] {
    // This branch precedes environment inspection and every macOS session,
    // registry, or OS-build call. All observations here are invented fixtures.
    do {
        let checks = try SyntheticTests.run()
        try Report.write(["mode": "self_test", "scope": "synthetic_in_memory_only_no_session_or_registry_reads",
                          "result": "passed", "checks": checks])
    } catch {
        fail("Synthetic console-session probe checks failed.", code: 1)
    }
} else if arguments == ["--probe"] {
    guard ProcessInfo.processInfo.environment["FLOWGESTURE_RUN_CONSOLE_SESSION_PROBE"] == "1" else {
        fail("Refusing console-session read without FLOWGESTURE_RUN_CONSOLE_SESSION_PROBE=1.")
    }
    #if os(macOS)
    let revision = Report.sourceRevision(ProcessInfo.processInfo.environment["FLOWGESTURE_PROBE_SOURCE_REVISION"])
    do { try Report.write(LiveProbe.run(revision: revision)) }
    catch { fail("Console-session probe JSON serialization failed.", code: 1) }
    #else
    fail("Live console-session probing is supported only on macOS.")
    #endif
} else {
    fail("Usage: swift scripts/probe-console-session.swift --self-test | --probe (requires explicit environment opt-in).")
}
