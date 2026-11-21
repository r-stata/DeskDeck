import AppKit
import SwiftUI

/// 卡片颜色色块：菜单里每个颜色都给一个小圆角色块预览 + 名称
@MainActor
enum TintSwatch {
    private static var cache: [String: NSImage] = [:]

    static func name(for hex: String) -> String {
        switch hex.uppercased() {
        case "#0A84FF": return "蓝色"
        case "#5E5CE6": return "靛蓝"
        case "#BF5AF2": return "紫色"
        case "#FF9F0A": return "橙色"
        case "#FFD60A": return "黄色"
        case "#30D158": return "绿色"
        case "#FF375F": return "玫红"
        case "#64D2FF": return "青色"
        case "#E8E8ED": return "浅灰"
        default: return hex.uppercased()
        }
    }

    static func image(for hex: String, size: CGFloat = 15) -> NSImage {
        let key = "\(hex)-\(size)"
        if let cached = cache[key] { return cached }
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: size / 4, yRadius: size / 4)
        NSColor(hexString: hex).setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.22).setStroke()
        path.lineWidth = 1
        path.stroke()
        image.unlockFocus()
        cache[key] = image
        return image
    }
}

extension NSColor {
    /// "#RRGGBB" → NSColor（sRGB）
    convenience init(hexString: String) {
        var value: UInt64 = 0
        let cleaned = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        Scanner(string: cleaned).scanHexInt64(&value)
        let r = CGFloat((value & 0xFF0000) >> 16) / 255
        let g = CGFloat((value & 0x00FF00) >> 8) / 255
        let b = CGFloat(value & 0x0000FF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
