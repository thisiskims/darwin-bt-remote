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
    static let ipadVirtualWidthKey = "ipadVirtualWidth"
    static let ipadVirtualHeightKey = "ipadVirtualHeight"
    static let macPointerSensitivityKey = "macPointerSensitivity"

    static let maxAdvertisedNameLength = 26

    static let repoURL = URL(string: "https://github.com/thisiskims/darwin-bt-remote")!
    static let instructionsURL = URL(string: "https://github.com/thisiskims/darwin-bt-remote/blob/main/README.md")!

    static let defaultPointerSensitivity = 5.0
    static let pointerSensitivityRange = 0.5 ... 10.0
    static let defaultScrollSensitivity = 1.0
    static let scrollSensitivityRange = 0.5 ... 3.0
    static let defaultIPadVirtualWidth = 900.0
    static let ipadVirtualWidthRange = 400.0 ... 1600.0
    static let defaultIPadVirtualHeight = 820.0
    static let ipadVirtualHeightRange = 400.0 ... 1600.0
    static let defaultMacPointerSensitivity = 1.5
    static let macPointerSensitivityRange = 0.5 ... 5.0
}
