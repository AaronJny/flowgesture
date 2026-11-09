import Foundation

/// The CLI self-test never constructs LiveCapture, probes permissions, opens a
/// tap, loads the MT framework, enumerates hardware, or posts any event.
enum CaptureSelfTest {
    static let environment = CaptureEnvironment(osVersion: "synthetic_fixture", exactOSBuild: nil,
                                                architecture: "synthetic_fixture", executableSHA256: nil,
                                                executableHashStatus: "not_read_in_synthetic_self_test",
                                                operatorReportedSourceRevision: nil,
                                                sourceRevisionVerification: "unknown")
    static func run(options: CaptureOptions) -> CaptureReport {
        let origin: UInt64 = 1_000_000
        let store = CaptureStore(options: options, originNanoseconds: origin)
        store.observeRaw(deviceID: 7, sourceTimestamp: 10, frameNumber: 1,
                         bridgeContactCount: 0, contacts: [], cancelled: false, acquiredAt: origin + 1)
        store.observeRaw(deviceID: 7, sourceTimestamp: 10.01, frameNumber: 2,
                         bridgeContactCount: 3, contacts: (1...3).map {
                            CaptureContact(identifier: Int32($0), state: 4, normalizedX: Double($0) / 5, normalizedY: 0.5)
                         }, cancelled: false, acquiredAt: origin + 2)
        store.observeQuartz(CaptureQuartzFields(callbackClass: 30, eventClass: 30,
                                               sourceTimestamp: 99_999_999, sourcePID: 0, sourceUserData: -42,
                                               senderAPIAvailable: true, senderID: 123,
                                               privateFields: CapturePrivateFields(callbackClass: 30, selector: 30,
                                                                                   hidType: 23, axis: 1, progress: 0.2,
                                                                                   velocityX: 0, phase: 1)), acquiredAt: origin + 3)
        store.observeRaw(deviceID: 7, sourceTimestamp: 10.02, frameNumber: 3,
                         bridgeContactCount: 0, contacts: [], cancelled: false, acquiredAt: origin + 4)
        store.finish(.selfTestComplete, at: origin + 5)
        let device = CaptureDevice(opaqueSessionDeviceID: "7", registryEntryID: "123", multitouchFrameworkDeviceID: "987",
                                   kindCode: 2, classificationEvidenceCode: 2, vendorID: nil, productID: nil,
                                   builtIn: nil, started: true, startError: 0)
        return store.report(environment: environment, devices: [device])
    }
}
