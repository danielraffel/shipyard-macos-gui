import SwiftUI

/// macOS-native accent palette matching the Claude design prototype.
/// Uses system-defined colors where possible so dark/light mode switches
/// for free; hardcodes only where the system doesn't have a close match.
enum ShipyardColors {
    static let green = Color(red: 52/255, green: 199/255, blue: 89/255)   // #34c759
    static let red = Color(red: 255/255, green: 59/255, blue: 48/255)     // #ff3b30
    static let blue = Color(red: 0/255, green: 122/255, blue: 255/255)    // #007aff
    static let orange = Color(red: 255/255, green: 149/255, blue: 0/255)  // #ff9500
    static let purple = Color(red: 130/255, green: 80/255, blue: 223/255) // #8250df
}

extension RunnerProvider {
    var tint: Color {
        switch self {
        case .local: return ShipyardColors.green
        case .ssh: return ShipyardColors.blue
        case .github: return ShipyardColors.purple
        case .namespace: return ShipyardColors.orange
        }
    }
}

extension FailureClass {
    var tint: Color {
        switch self {
        case .infra, .timeout: return ShipyardColors.orange
        case .contract, .test: return ShipyardColors.red
        case .unknown: return .secondary
        }
    }
}
