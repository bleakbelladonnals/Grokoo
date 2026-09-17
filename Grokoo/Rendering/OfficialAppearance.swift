import AppKit

enum OfficialShape: String, Codable, CaseIterable, Sendable {
    case blob
    case pebble
    case squircle
    case tablet
    case wedge
    case hex
    case cloud
    case teardrop

    init(gatewayValue: String?) {
        self = gatewayValue.flatMap(Self.init(rawValue:)) ?? .blob
    }
}

enum OfficialColor: String, Codable, CaseIterable, Sendable {
    case black
    case brown
    case red
    case orange
    case yellow
    case green
    case cyan
    case blue
    case violet
    case magenta
    case gray

    var hex: String {
        switch self {
        case .black: "#000000"
        case .brown: "#936439"
        case .red: "#FF263C"
        case .orange: "#FF6700"
        case .yellow: "#FF9800"
        case .green: "#00C972"
        case .cyan: "#00BCA6"
        case .blue: "#1084FE"
        case .violet: "#9159FE"
        case .magenta: "#FF309B"
        case .gray: "#777777"
        }
    }

    var nsColor: NSColor { NSColor(hex: hex) ?? .black }
    var cgColor: CGColor { nsColor.cgColor }

    init(gatewayValue: String?) {
        guard let value = gatewayValue?.lowercased() else {
            self = .black
            return
        }
        if let named = Self(rawValue: value) {
            self = named
            return
        }
        self = Self.allCases.first(where: { $0.hex.lowercased() == value }) ?? .black
    }
}

extension NSColor {
    convenience init?(hex: String) {
        let normalized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard normalized.count == 6, let value = UInt64(normalized, radix: 16) else { return nil }
        self.init(
            calibratedRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }

    var contrastingMonochrome: NSColor {
        guard let rgb = usingColorSpace(.deviceRGB) else { return .white }
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance > 0.55 ? NSColor(calibratedWhite: 0.08, alpha: 0.92) : .white
    }
}
