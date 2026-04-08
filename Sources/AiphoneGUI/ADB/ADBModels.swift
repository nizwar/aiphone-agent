import Foundation

enum ADBConnectionType: String, Codable, CaseIterable, Sendable {
    case usb
    case wifi
    case remote
}

struct ADBDeviceInfo: Identifiable, Codable, Hashable, Sendable {
    var id: String { deviceID }

    let deviceID: String
    let status: String
    let connectionType: ADBConnectionType
    let model: String?
    let androidVersion: String?

    var isAvailable: Bool {
        status == "device"
    }
}

struct ADBCommandResult: Sendable {
    let standardOutput: String
    let standardError: String
    let exitCode: Int32

    var combinedOutput: String {
        [standardOutput, standardError]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var succeeded: Bool {
        exitCode == 0
    }
}

struct ADBScreenshot: Sendable {
    let pngData: Data
    let base64Data: String
    let imageMimeType: String
    let width: Int
    let height: Int
    let isSensitive: Bool
}

struct ADBDeviceRuntimeStatus: Sendable {
    let batteryLevel: Int?
    let wifiStatus: String?
    let dataStatus: String?
    let currentApp: String?
}

struct ADBDeviceDetails: Sendable {
    let deviceID: String
    let status: String
    let connectionType: ADBConnectionType
    let model: String?
    let manufacturer: String?
    let brand: String?
    let productName: String?
    let deviceName: String?
    let androidVersion: String?
    let sdkVersion: String?
    let cpuABI: String?
    let buildFingerprint: String?
    let securityPatch: String?
    let screenResolution: String?
    let screenDensity: String?
    let batteryLevel: Int?
    let wifiStatus: String?
    let dataStatus: String?
    let currentApp: String?
    let packageCount: Int
    let playStoreInstalled: Bool
    let installedAppsPreview: [String]
}

struct ADBAppLaunchResult: Sendable {
    let succeeded: Bool
    let appName: String
    let packageName: String?
    let didOpenStore: Bool
    let message: String
}

enum ADBProviderError: LocalizedError, Sendable {
    case commandTimedOut(String)
    case commandFailed(String)
    case missingOutput(String)
    case invalidImageData

    var errorDescription: String? {
        switch self {
        case let .commandTimedOut(command):
            return "ADB command timed out: \(command)"
        case let .commandFailed(message):
            return message
        case let .missingOutput(message):
            return message
        case .invalidImageData:
            return "Failed to decode screenshot image data."
        }
    }
}

enum ADBTiming {
    static let textClearDelay: TimeInterval = 1.0
    static let textInputDelay: TimeInterval = 1.0

    static let defaultTapDelay: TimeInterval = 1.0
    static let defaultDoubleTapDelay: TimeInterval = 1.0
    static let doubleTapInterval: TimeInterval = 0.1
    static let defaultLongPressDelay: TimeInterval = 1.0
    static let defaultSwipeDelay: TimeInterval = 1.0
    static let defaultBackDelay: TimeInterval = 1.0
    static let defaultHomeDelay: TimeInterval = 1.0
    static let defaultLaunchDelay: TimeInterval = 1.0

    static let adbRestartDelay: TimeInterval = 2.0
    static let serverRestartDelay: TimeInterval = 1.0
}
