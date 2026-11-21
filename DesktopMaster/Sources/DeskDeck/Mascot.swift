import SwiftUI
import AppKit
import ImageIO

// MARK: - 小宠物（卡片上的可拖动 / 可缩放贴图）

/// 记录在分区状态里的小宠物参数。坐标以卡片左上角为原点（pt，y 向下）。
struct MascotSpec: Codable, Hashable {
    /// 用户选择的原始文件（svg / png / gif / jpg …）
    var path: String
    /// 系统读不了的格式（退到 QuickLook 转出来的 png）
    var renderPath: String?
    var x: Double
    var y: Double
    var size: Double
    /// 固定位置：不再吃鼠标事件，点它等于点卡片，不影响卡片拖动
    var pinned: Bool

    init(path: String, renderPath: String? = nil, x: Double, y: Double, size: Double = 56, pinned: Bool = true) {
        self.path = path
        self.renderPath = renderPath
        self.x = x
        self.y = y
        self.size = size
        self.pinned = pinned
    }

    enum CodingKeys: String, CodingKey { case path, renderPath, x, y, size, pinned }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        renderPath = try c.decodeIfPresent(String.self, forKey: .renderPath)
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 12
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 12
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 56
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path)
        try c.encodeIfPresent(renderPath, forKey: .renderPath)
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
        try c.encode(size, forKey: .size)
        try c.encode(pinned, forKey: .pinned)
    }

    /// 实际用来显示的文件
    var displayPath: String { renderPath ?? path }

    var rect: CGRect { CGRect(x: x, y: y, width: size, height: size) }
}

// MARK: - 素材加载（含 GIF 拆帧）

@MainActor
enum MascotImages {
    private static var imageCache: [String: NSImage] = [:]
    private static var frameCache: [String: [NSImage]] = [:]
    private static var intervalCache: [String: Double] = [:]
    /// SVG 等系统读不了的素材，做一次 QuickLook 转 PNG 后记住结果
    private static var resolvedCache: [String: String] = [:]

    /// 真正用来读文件的路径：优先用已经转好的 PNG；
    /// 否则先用原文件试一次，读不出来再交给 QuickLook 转换（转完缓存，避免每次重转）。
    static func displayPath(for spec: MascotSpec) -> String {
        if let render = spec.renderPath, FileManager.default.fileExists(atPath: render) {
            return render
        }
        if let resolved = resolvedCache[spec.path], FileManager.default.fileExists(atPath: resolved) {
            return resolved
        }
        let original = spec.path
        if FileManager.default.fileExists(atPath: original), canLoad(original) {
            resolvedCache[original] = original
            return original
        }
        if FileManager.default.fileExists(atPath: original),
           let prepared = prepare(fileURL: URL(fileURLWithPath: original)) {
            resolvedCache[original] = prepared
            return prepared
        }
        return original
    }

    /// CoreGraphics / AppKit 能不能直接解出这个文件
    private static func canLoad(_ path: String) -> Bool {
        if CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) != nil { return true }
        return NSImage(contentsOfFile: path) != nil
    }

    static func image(for spec: MascotSpec) -> NSImage? {
        let path = displayPath(for: spec)
        if let cached = imageCache[path] { return cached }
        guard FileManager.default.fileExists(atPath: path),
              let image = NSImage(contentsOfFile: path) else { return nil }
        imageCache[path] = image
        return image
    }

    /// GIF 的每一帧；静态图只返回一帧
    static func frames(for spec: MascotSpec) -> [NSImage] {
        let path = displayPath(for: spec)
        if let cached = frameCache[path] { return cached }
        var result: [NSImage] = []
        let url = URL(fileURLWithPath: path)
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let count = CGImageSourceGetCount(source)
            if count > 1 {
                var total = 0.0
                for index in 0..<count {
                    if let cg = CGImageSourceCreateImageAtIndex(source, index, nil) {
                        result.append(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
                    }
                    let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
                    let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                    let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                        ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
                    total += max(0.02, delay)
                }
                if !result.isEmpty {
                    intervalCache[path] = max(0.02, total / Double(result.count))
                }
            }
        }
        if result.isEmpty, let single = image(for: spec) { result = [single] }
        frameCache[path] = result
        return result
    }

    static func frameInterval(for spec: MascotSpec) -> Double {
        intervalCache[displayPath(for: spec)] ?? 0.1
    }

    static func forget(_ path: String) {
        imageCache.removeValue(forKey: path)
        frameCache.removeValue(forKey: path)
        intervalCache.removeValue(forKey: path)
    }

    /// 小宠物素材目录（只有 QuickLook 兜底转换时才用到）
    static var storeDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeskDeck", isDirectory: true)
            .appendingPathComponent("Mascots", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// 返回可以直接显示的路径。SVG 走系统原生渲染（透明通道保留），
    /// 只有系统真读不了的格式才退回 QuickLook 转 png。
    static func prepare(fileURL: URL) -> String? {
        if NSImage(contentsOfFile: fileURL.path) != nil {
            return fileURL.path
        }
        let outDir = storeDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-t", "-s", "512", "-o", outDir.path, fileURL.path]
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        let contents = (try? FileManager.default.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil)) ?? []
        guard let png = contents.first(where: { $0.pathExtension.lowercased() == "png" }) else { return nil }
        let target = storeDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try? FileManager.default.moveItem(at: png, to: target)
        try? FileManager.default.removeItem(at: outDir)
        return target.path
    }
}

// MARK: - 图片（纯 SwiftUI 绘制：卡片拖动时不会错位，也不吃鼠标）

struct MascotPicture: View {
    let spec: MascotSpec
    let side: CGFloat

    var body: some View {
        let frames = MascotImages.frames(for: spec)
        if frames.count > 1 {
            let interval = MascotImages.frameInterval(for: spec)
            TimelineView(.periodic(from: .now, by: interval)) { context in
                let index = Int(context.date.timeIntervalSinceReferenceDate / interval) % frames.count
                Image(nsImage: frames[index])
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: side, height: side)
            }
        } else {
            Image(nsImage: frames.first ?? MascotImages.image(for: spec) ?? NSImage(size: NSSize(width: 1, height: 1)))
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: side, height: side)
        }
    }
}

// MARK: - 卡片上的小宠物层

struct MascotLayer: View {
    let spec: MascotSpec
    let cardSize: CGSize
    let onCommit: (MascotSpec) -> Void

    @State private var hovering = false

    private var size: CGFloat { CGFloat(spec.size) }

    private var origin: CGPoint {
        CGPoint(x: CGFloat(spec.x), y: CGFloat(spec.y))
    }

    private var sizeLimit: CGFloat { max(20, min(cardSize.width, cardSize.height) * 0.9) }

    private var resolvedOrigin: CGPoint {
        CGPoint(x: min(max(0, origin.x), max(0, cardSize.width - size)),
                y: min(max(0, origin.y), max(0, cardSize.height - size)))
    }

    var body: some View {
        content
    }

    private var content: some View {
        MascotPicture(spec: spec, side: size)
            .shadow(color: .black.opacity(spec.pinned ? 0.16 : 0.26), radius: 3, y: 2)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(.white.opacity(hovering && !spec.pinned ? 0.55 : 0), lineWidth: 1)
            )
            .frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) {
                if !spec.pinned {
                    resizeHandle
                }
            }
            .contentShape(Rectangle())
            .offset(x: resolvedOrigin.x, y: resolvedOrigin.y)
            .onHover { hovering = spec.pinned ? false : $0 }
            .help(spec.pinned ? "小宠物已固定，点它等于点卡片" : "拖动图片挪位置，拖右下角小圆点改大小，滚轮也能缩放")
            // 宠物永远不参与命中测试：点它一定落到卡片上，交互交给窗口层判断
            .allowsHitTesting(false)
    }

    /// 右下角的手柄（纯视觉提示；真正的拖动由窗口层处理）
    private var resizeHandle: some View {
        ZStack {
            Circle().fill(.white.opacity(0.95))
            Circle().stroke(.black.opacity(0.22), lineWidth: 0.5)
            Image(systemName: "arrow.down.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.black.opacity(0.72))
        }
        .frame(width: 15, height: 15)
        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
        .padding(1)
    }

}
