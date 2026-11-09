import Foundation

/// Int64/UInt64 identifiers and nanoseconds use decimal strings in JSON, so tools
/// with IEEE-754 JSON numbers cannot silently equate or truncate identity values.
struct CaptureDevice: Codable, Equatable {
    let opaqueSessionDeviceID: String
    let registryEntryID: String?
    let multitouchFrameworkDeviceID: String?
    let kindCode: UInt32
    let classificationEvidenceCode: UInt32
    let vendorID: UInt32?
    let productID: UInt32?
    let builtIn: Bool?
    let started: Bool
    let startError: Int32
}

struct CaptureContact: Codable, Equatable {
    let identifier: Int32
    let state: UInt32
    let normalizedX: Double
    let normalizedY: Double
    var isActive: Bool { state == 3 || state == 4 }
    var isValid: Bool {
        identifier >= 0 && state <= 7 && normalizedX.isFinite && normalizedY.isFinite &&
        (0...1).contains(normalizedX) && (0...1).contains(normalizedY)
    }
}

struct CapturePrivateFields: Codable, Equatable {
    let selector55: Int64
    let hidType110: Int64
    let axis123: Int64
    let progress124: Double?
    let velocityX129: Double?
    let phase132: Int64
    let invalidNumericFields: [String]
    let selectorMatchesCallbackClass: Bool
    let matchesSourceBackedHorizontalFingerprint: Bool
    let recognizedPhaseName: String?
    // CGEvent getters cannot distinguish missing fields from zero-valued fields.
    let fieldPresence: String
    let semanticsOnThisBuild: String

    init(callbackClass: UInt32, selector: Int64, hidType: Int64, axis: Int64,
         progress: Double, velocityX: Double, phase: Int64) {
        selector55 = selector; hidType110 = hidType; axis123 = axis
        progress124 = progress.isFinite ? progress : nil
        velocityX129 = velocityX.isFinite ? velocityX : nil
        phase132 = phase
        invalidNumericFields = (progress.isFinite ? [] : ["progress124_nonfinite"]) + (velocityX.isFinite ? [] : ["velocityX129_nonfinite"])
        selectorMatchesCallbackClass = selector == Int64(callbackClass)
        matchesSourceBackedHorizontalFingerprint = (callbackClass == 29 || callbackClass == 30) &&
            selectorMatchesCallbackClass && hidType == 23 && axis == 1
        let names: [Int64: String] = [0: "none", 1: "began", 2: "changed", 4: "ended", 8: "cancelled", 128: "mayBegin"]
        recognizedPhaseName = matchesSourceBackedHorizontalFingerprint ? names[phase] : nil
        fieldPresence = "unverified_getters_cannot_distinguish_absent_from_zero"
        semanticsOnThisBuild = "unverified_source_backed_field_numbers_only"
    }
}

struct CaptureQuartzFields: Codable, Equatable {
    let callbackClass: UInt32
    let eventClass: UInt32
    let sourceTimestampNanoseconds: String
    let sourceTimestampClock: String
    let sourcePID: Int64
    let flagsRawValue: String
    let sourceUserDataSignedDecimal: String
    let senderAPIAvailable: Bool
    let ioHIDSenderID: String?
    let physicalProvenance: String
    let senderToRawDeviceAssociation: String
    let classificationStatus: String
    let privateFields: CapturePrivateFields?
    let scrollPhase: Int64?
    let momentumPhase: Int64?

    init(callbackClass: UInt32, eventClass: UInt32, sourceTimestamp: UInt64,
         sourcePID: Int64, sourceUserData: Int64, flagsRawValue: UInt64 = 0, senderAPIAvailable: Bool,
         senderID: UInt64?, privateFields: CapturePrivateFields? = nil,
         scrollPhase: Int64? = nil, momentumPhase: Int64? = nil) {
        self.callbackClass = callbackClass; self.eventClass = eventClass
        sourceTimestampNanoseconds = String(sourceTimestamp)
        sourceTimestampClock = "CGEvent_timestamp_nanoseconds_not_aligned_to_capture_clock"
        self.sourcePID = sourcePID; sourceUserDataSignedDecimal = String(sourceUserData)
        self.flagsRawValue = String(flagsRawValue)
        self.senderAPIAvailable = senderAPIAvailable
        ioHIDSenderID = senderID.flatMap { $0 == 0 ? nil : String($0) }
        physicalProvenance = "unverified_including_PID_zero"
        senderToRawDeviceAssociation = "unverified_no_namespace_substitution_or_session_match"
        let isPrivateClass = callbackClass == 29 || callbackClass == 30
        self.privateFields = isPrivateClass ? privateFields : nil
        self.scrollPhase = callbackClass == 22 ? scrollPhase : nil
        self.momentumPhase = callbackClass == 22 ? momentumPhase : nil
        classificationStatus = isPrivateClass ? "source_backed_fields_build_semantics_unverified" :
            (callbackClass == 22 ? "public_scroll_phase_getters" : "unclassified_metadata_only")
    }
}

struct CaptureRawFields: Codable, Equatable {
    let opaqueSessionDeviceID: String
    let sourceFrameNumber: String
    let bridgeTimestampSeconds: Double?
    let sourceTimestampStatus: String
    let sourceTimestampClock: String
    let bridgeCancelled: Bool
    let bridgeContactCount: Int
    let activeContactCount: Int?
    let contacts: [CaptureContact]
    let observedSessionID: String?
    let boundary: String
}

struct CaptureRecord: Codable {
    let ordinal: Int
    let channel: String
    let acquiredElapsedNanoseconds: String
    let quartz: CaptureQuartzFields?
    let raw: CaptureRawFields?
}

struct CaptureCounts: Codable, Equatable {
    var observedQuartz: UInt64 = 0
    var observedRaw: UInt64 = 0
    var storedQuartz: UInt64 = 0
    var storedRaw: UInt64 = 0
    var droppedRecordLimit: UInt64 = 0
    var droppedAfterDeadline: UInt64 = 0
    var droppedAfterStop: UInt64 = 0
    var droppedInvalidRecord: UInt64 = 0
    var droppedUnexpectedClass: UInt64 = 0
    var rejectedRawFrames: UInt64 = 0
    var unknownPrivatePhase: UInt64 = 0
    var nonfinitePrivateFields: UInt64 = 0
    var timestampRegressions: UInt64 = 0
}

struct CaptureEnvironment: Codable {
    let osVersion: String
    let exactOSBuild: String?
    let architecture: String
    let executableSHA256: String?
    let executableHashStatus: String
    let operatorReportedSourceRevision: String?
    let sourceRevisionVerification: String
}

struct CaptureRuntime: Codable {
    var listenPermissionPreflight: Bool?
    var consoleSessionActive: Bool?
    var sessionScreenLocked: Bool?
    var sessionLockStateSource: String?
    var senderAPIAvailable: Bool?
    var quartzTapEnabledElapsedNanoseconds: String?
    var touchStartReturnedElapsedNanoseconds: String?
    var touchStatusCode: Int32?
    var bridgeReceivedFrames: UInt64 = 0
    var bridgeRejectedFrames: UInt64 = 0
}

struct CaptureReport: Codable {
    let schemaVersion: Int
    let mode: CaptureOptions.Mode
    let evidenceScope: String
    let requestedDurationSeconds: Double
    let maximumRecords: Int
    let operatorSelectedScenario: CaptureScenario
    let scenarioVerified: Bool
    let environment: CaptureEnvironment
    let acquisitionClock: String
    let acquisitionPoint: String
    let identityNamespaces: [String: String]
    let privacy: [String]
    let limitations: [String]
    let tapLocation: String
    let tapOptions: String
    let eventClassesRequested: [UInt32]
    let eventClassesExcluded: [UInt32]
    let eventMaskHex: String
    let outcome: String
    let stopReason: String
    let stoppedElapsedNanoseconds: String
    let failureReasons: [String]
    let runtime: CaptureRuntime
    let devices: [CaptureDevice]
    let counts: CaptureCounts
    let records: [CaptureRecord]
}
