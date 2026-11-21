import SwiftUI
import AppKit

// MARK: - 颜色

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        if s.count == 8 {
            let a = Double((value >> 24) & 0xFF) / 255
            let r = Double((value >> 16) & 0xFF) / 255
            let g = Double((value >> 8) & 0xFF) / 255
            let b = Double(value & 0xFF) / 255
            self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
        } else {
            let r = Double((value >> 16) & 0xFF) / 255
            let g = Double((value >> 8) & 0xFF) / 255
            let b = Double(value & 0xFF) / 255
            self = Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
        }
    }
}

// MARK: - 图标

enum FileIconProvider {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for path: String) -> NSImage {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 64, height: 64)
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}

// MARK: - 壁纸级背景模糊（真实采样桌面壁纸）

struct BackdropBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var cornerRadius: CGFloat = 24
    var alpha: CGFloat = 1

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        view.wantsLayer = true
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        view.layer?.cornerRadius = cornerRadius
        view.alphaValue = alpha
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.layer?.cornerRadius = cornerRadius
        view.alphaValue = alpha
    }
}

// MARK: - 卡片玻璃底

struct GlassCardBackground: View {
    var tint: Color
    var cornerRadius: CGFloat
    var isHovering: Bool
    var isDropTargeted: Bool
    var pointer: CGPoint = CGPoint(x: 0.28, y: 0.18)

    var body: some View {
        ZStack {
            if #available(macOS 26.0, *) {
                // 壁纸模糊打底，保证卡片背后是真实桌面而不是空洞
                BackdropBlur(cornerRadius: cornerRadius, alpha: 0.72)
                // 系统原生 Liquid Glass：折射 + 高光 + 交互反馈
                Color.clear
                    .glassEffect(
                        .regular.tint(tint.opacity(0.22)),
                        in: .rect(cornerRadius: cornerRadius)
                    )
            } else {
                BackdropBlur(cornerRadius: cornerRadius)
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.42), tint.opacity(0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }

            // 色彩染色
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            tint.opacity(isHovering ? 0.30 : 0.24),
                            .white.opacity(0.05),
                            tint.opacity(0.10)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            // 液体高光 / 折射边
            LiquidHighlights(
                cornerRadius: cornerRadius,
                tint: tint,
                intensity: isHovering ? 1.0 : 0.82,
                pointer: pointer
            )

            // 描边
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(isHovering ? 0.62 : 0.48), location: 0.0),
                            .init(color: .white.opacity(0.06), location: 0.42),
                            .init(color: .white.opacity(0.02), location: 0.72),
                            .init(color: .white.opacity(0.30), location: 1.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.20)],
                        startPoint: .center,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
                .padding(0.5)

            if isDropTargeted {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(tint.opacity(0.9), lineWidth: 2)
                    .shadow(color: tint.opacity(0.7), radius: 10)
            }
        }
        .compositingGroup()
    }
}

// MARK: - 液体高光层

struct LiquidHighlights: View {
    var cornerRadius: CGFloat
    var tint: Color
    var intensity: Double
    var pointer: CGPoint = CGPoint(x: 0.28, y: 0.16)

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                // 跟随鼠标的柔光
                RadialGradient(
                    colors: [.white.opacity(0.34 * intensity), .white.opacity(0.0)],
                    center: .center,
                    startRadius: 2,
                    endRadius: max(70, min(size.width, size.height) * 0.55)
                )
                .frame(width: size.width * 1.2, height: size.height * 1.2)
                .offset(
                    x: size.width * (pointer.x - 0.6),
                    y: size.height * (pointer.y - 0.6)
                )
                .blendMode(.plusLighter)

                // 底部液体反光
                RadialGradient(
                    colors: [tint.opacity(0.34 * intensity), .clear],
                    center: .center,
                    startRadius: 2,
                    endRadius: max(60, size.width * 0.45)
                )
                .frame(width: size.width * 1.1, height: size.height * 0.8)
                .offset(x: -size.width * 0.12, y: size.height * 0.42)
                .blendMode(.plusLighter)

                // 顶部弧形液体亮带
                Ellipse()
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.20 * intensity), .white.opacity(0.0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: size.width * 0.78, height: 26)
                    .offset(y: -size.height * 0.5 + 6)
                    .blur(radius: 8)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.22), value: pointer)
            .animation(.easeInOut(duration: 0.35), value: intensity)
        }
    }
}

// MARK: - 小型玻璃胶囊（用于「新建分区」等工具条）

struct GlassCapsule: View {
    var tint: Color = .white
    var cornerRadius: CGFloat = 18

    var body: some View {
        ZStack {
            if #available(macOS 26.0, *) {
                Color.clear
                    .glassEffect(.regular.tint(tint.opacity(0.20)).interactive(), in: .capsule)
            } else {
                BackdropBlur(material: .popover, cornerRadius: cornerRadius)
            }
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.26), lineWidth: 1)
        }
        .compositingGroup()
    }
}
