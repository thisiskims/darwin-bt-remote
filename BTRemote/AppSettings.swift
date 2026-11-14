import Foundation

enum AppSettings {
    static let touchpadSensitivityKey = "touchpadSensitivity"
    static let scrollSensitivityKey = "scrollSensitivity"
    static let autoAdvertiseKey = "autoAdvertise"
    static let deviceNamesKey = "deviceNames"
    static let hasSeenWelcomeKey = "hasSeenWelcome"
    static let liveTypingKey = "liveTyping"
    static let remoteModeKey = "remoteMode"
    static let transportKey = "transport"
    static let topEdgeCrossingKey = "topEdgeCrossing"
    static let ipadVirtualHeightKey = "ipadVirtualHeight"
    static let macPointerSensitivityKey = "macPointerSensitivity"

    static let maxAdvertisedNameLength = 26

    static let repoURL = URL(string: "https://github.com/thisiskims/darwin-bt-remote")!
    static let instructionsURL = URL(string: "https://github.com/thisiskims/darwin-bt-remote/blob/main/README.md")!

    static let defaultPointerSensitivity = 5.0
    static let pointerSensitivityRange = 0.5 ... 10.0
    static let defaultScrollSensitivity = 1.0
    static let scrollSensitivityRange = 0.5 ... 3.0
    static let defaultIPadVirtualHeight = 600.0
    static let ipadVirtualHeightRange = 300.0 ... 1200.0
    static let defaultMacPointerSensitivity = 3.0
    static let macPointerSensitivityRange = 1.0 ... 8.0
}
