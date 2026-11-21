import Foundation
import Observation
import AppKit

// MARK: - 数据模型

struct StoredItem: Codable, Hashable, Identifiable {
    var path: String

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }

    var displayName: String {
        let last = (path as NSString).lastPathComponent
        if last.isEmpty { return path }
        guard last.hasSuffix(".app") else { return last }
        if let bundle = Bundle(url: url) {
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let name = bundle.object(forInfoDictionaryKey: key) as? String, !name.isEmpty {
                    return name
                }
            }
        }
        return String(last.dropLast(4))
    }

    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

enum PartitionKind: String, Codable {
    /// 应用分区：存放 App 与文件引用，点击打开
    case apps
    /// 文档分区：绑定一个文件夹，拖入的文件会被移动到该文件夹
    case folder
    /// 函数分区：填写参数后调用指定的 R 函数
    case function

    var title: String {
        switch self {
        case .apps: return "应用分区"
        case .folder: return "文档分区"
        case .function: return "函数分区"
        }
    }

    var symbol: String {
        switch self {
        case .apps: return "circle.grid.3x3.fill"
        case .folder: return "folder.fill"
        case .function: return "function"
        }
    }
}

struct Partition: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    /// 所属屏幕的 CGDirectDisplayID
    var screenID: UInt32
    /// 相对该屏幕左上角的坐标（y 向下）
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var tintHex: String
    var kind: PartitionKind
    /// 文档分区绑定的文件夹绝对路径
    var folderPath: String?
    var locked: Bool
    var items: [StoredItem]
    /// 函数分区配置
    var rConfig: RConfig?
    /// 卡片上的小宠物（可拖动、可缩放的小图标）
    var mascot: MascotSpec?

    init(
        id: UUID = UUID(),
        name: String,
        screenID: UInt32,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        tintHex: String,
        kind: PartitionKind = .apps,
        folderPath: String? = nil,
        locked: Bool = false,
        items: [StoredItem] = [],
        rConfig: RConfig? = nil,
        mascot: MascotSpec? = nil
    ) {
        self.id = id
        self.name = name
        self.screenID = screenID
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.tintHex = tintHex
        self.kind = kind
        self.folderPath = folderPath
        self.locked = locked
        self.items = items
        self.rConfig = rConfig
        self.mascot = mascot
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, screenID, x, y, width, height, tintHex, kind, folderPath, locked, items, rConfig, mascot
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "分区"
        screenID = try c.decodeIfPresent(UInt32.self, forKey: .screenID) ?? 0
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 60
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 60
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 340
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 240
        tintHex = try c.decodeIfPresent(String.self, forKey: .tintHex) ?? "#0A84FF"
        kind = try c.decodeIfPresent(PartitionKind.self, forKey: .kind) ?? .apps
        folderPath = try c.decodeIfPresent(String.self, forKey: .folderPath)
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        items = try c.decodeIfPresent([StoredItem].self, forKey: .items) ?? []
        rConfig = try c.decodeIfPresent(RConfig.self, forKey: .rConfig)
        mascot = try c.decodeIfPresent(MascotSpec.self, forKey: .mascot)
    }
}

struct ScreenSnapshot: Hashable {
    let displayID: UInt32
    let frameSize: CGSize
    /// visibleFrame 换算到「以屏幕左上角为原点、y 向下」的坐标系
    let visible: CGRect

    static func make(_ screen: NSScreen) -> ScreenSnapshot {
        let f = screen.frame
        let vf = screen.visibleFrame
        let visible = CGRect(
            x: vf.minX - f.minX,
            y: f.maxY - vf.maxY,
            width: vf.width,
            height: vf.height
        )
        return ScreenSnapshot(
            displayID: AppState.displayID(of: screen),
            frameSize: f.size,
            visible: visible
        )
    }
}

// MARK: - 全局状态

@MainActor
@Observable
final class AppState {
    var partitions: [Partition] = []
    var showAll: Bool = true

    /// 卡片正在被拖动/缩放，用于暂停桌面命中检测
    var isDraggingCard = false
    /// 双击标题请求改名
    var renameRequest: UUID?
    /// 正在编辑名称的卡片（编辑时禁止拖动）
    var editingCardID: UUID?
    /// 指针正悬停在某个图标上（此时按下是要把文件拖出去，不移动卡片）
    var hoveredItemPath: String?
    /// 当前选中的图标（单击选中，双击打开；⌘C 复制文件本身，菜单里另有「复制完整路径」）
    var selectedItemPath: String?
    /// 外部拖拽当前悬停的分区（用于高亮）
    var dropTargetID: UUID?

    /// 拖动过程中实时更新卡片左上角坐标
    func setOrigin(id: UUID, x: Double, y: Double) {
        guard let index = partitions.firstIndex(where: { $0.id == id }) else { return }
        if partitions[index].x == x && partitions[index].y == y { return }
        partitions[index].x = x
        partitions[index].y = y
    }

    static let palette: [String] = [
        "#0A84FF", "#5E5CE6", "#BF5AF2", "#FF375F", "#FF9F0A", "#FFD60A", "#30D158", "#64D2FF", "#E8E8ED"
    ]

    private var saveWork: DispatchWorkItem?
    private var folderWatchers: [UUID: DispatchSourceFileSystemObject] = [:]
    private var folderRefreshWork: [UUID: DispatchWorkItem] = [:]

    // MARK: 存储

    var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("DeskDeck", isDirectory: true)
    }

    /// 从旧版本「桌面管理大师」的数据目录迁移一次
    private func migrateLegacyStoreIfNeeded() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let legacy = base.appendingPathComponent("DesktopMaster", isDirectory: true)
        guard !fm.fileExists(atPath: storeURL.path),
              fm.fileExists(atPath: legacy.appendingPathComponent("state.json").path) else { return }
        try? fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try? fm.copyItem(at: legacy.appendingPathComponent("state.json"), to: storeURL)
    }

    var storeURL: URL { supportDirectory.appendingPathComponent("state.json") }

    private struct Snapshot: Codable {
        var partitions: [Partition]
        var showAll: Bool
    }

    func load() {
        migrateLegacyStoreIfNeeded()
        guard let data = try? Data(contentsOf: storeURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            syncFolderWatchers()
            return
        }
        partitions = snapshot.partitions
        showAll = snapshot.showAll
        syncFolderWatchers()
    }

    func requestSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        let snapshot = Snapshot(partitions: partitions, showAll: showAll)
        do {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            NSLog("DeskDeck 保存失败: \(error)")
        }
    }

    // MARK: 分区

    func index(of id: UUID) -> Int? { partitions.firstIndex(where: { $0.id == id }) }

    @discardableResult
    func createPartition(on screen: ScreenSnapshot, kind: PartitionKind, folderPath: String? = nil, language: FuncLanguage = .r) -> UUID {
        let v = screen.visible
        let w = kind == .function ? min(380, max(300, v.width * 0.3)) : min(340, max(250, v.width * 0.28))
        let h = kind == .function ? min(380, max(300, v.height * 0.42)) : min(260, max(210, v.height * 0.32))
        let count = partitions.filter { $0.screenID == screen.displayID }.count
        let cascade = CGFloat(count % 5) * 22

        let originX = clamp(v.midX - w / 2 + cascade, lower: v.minX + 8, upper: max(v.minX + 8, v.maxX - w - 8))
        let originY = clamp(v.midY - h / 2 + cascade, lower: v.minY + 8, upper: max(v.minY + 8, v.maxY - h - 8))

        var functionConfig = RConfig()
        functionConfig.language = language

        var partition = Partition(
            name: kind == .function
                ? language.partitionName
                : (kind == .folder
                ? ((folderPath.map { ($0 as NSString).lastPathComponent }) ?? "文档分区")
                : "分区 \(partitions.count + 1)"),
            screenID: screen.displayID,
            x: Double(originX),
            y: Double(originY),
            width: Double(w),
            height: Double(h),
            tintHex: Self.palette[(partitions.count + 1) % Self.palette.count],
            kind: kind,
            folderPath: folderPath,
            rConfig: kind == .function ? functionConfig : nil
        )
        if kind == .folder, let folderPath {
            partition.items = Self.scanFolder(folderPath)
        }
        partitions.append(partition)
        requestSave()
        syncFolderWatchers()
        return partition.id
    }

    func deletePartition(_ id: UUID) {
        if editingCardID == id { editingCardID = nil }
        partitions.removeAll { $0.id == id }
        folderRefreshWork[id]?.cancel()
        folderRefreshWork[id] = nil
        requestSave()
        syncFolderWatchers()
    }

    func setMascot(_ mascot: MascotSpec?, for id: UUID, save: Bool = true) {
        guard let index = partitions.firstIndex(where: { $0.id == id }) else { return }
        partitions[index].mascot = mascot
        if save { requestSave() }
    }

    func setLocked(_ locked: Bool, for id: UUID) {
        guard let idx = index(of: id) else { return }
        partitions[idx].locked = locked
        requestSave()
    }

    func setTint(_ hex: String, for id: UUID) {
        guard let idx = index(of: id) else { return }
        partitions[idx].tintHex = hex
        requestSave()
    }

    func sortItems(in id: UUID) {
        guard let idx = index(of: id) else { return }
        if partitions[idx].kind == .folder, let path = partitions[idx].folderPath {
            partitions[idx].items = Self.scanFolder(path)
        } else {
            partitions[idx].items.sort {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
        }
        requestSave()
    }

    // MARK: 应用分区：加入引用

    func addItems(_ urls: [URL], to id: UUID) {
        guard let idx = index(of: id), partitions[idx].kind == .apps else { return }
        var known = Set(partitions[idx].items.map { $0.path })
        var added = 0
        for url in urls {
            let path = url.path
            guard !path.isEmpty, !known.contains(path) else { continue }
            known.insert(path)
            partitions[idx].items.append(StoredItem(path: path))
            added += 1
        }
        if added > 0 { requestSave() }
    }

    func removeItem(_ path: String, from id: UUID) {
        guard let idx = index(of: id) else { return }
        partitions[idx].items.removeAll { $0.path == path }
        requestSave()
    }

    // MARK: 文档分区：绑定文件夹与移入

    func updateRConfig(_ config: RConfig, for id: UUID) {
        guard let idx = index(of: id) else { return }
        partitions[idx].rConfig = config
        requestSave()
    }

    func setParamValue(_ value: String, name: String, for id: UUID) {
        guard let idx = index(of: id) else { return }
        if partitions[idx].rConfig == nil { partitions[idx].rConfig = RConfig() }
        partitions[idx].rConfig?.values[name] = value
        requestSave()
    }

    func setFolder(_ path: String, for id: UUID) {
        guard let idx = index(of: id) else { return }
        partitions[idx].folderPath = path
        if partitions[idx].name.hasPrefix("文档分区") || partitions[idx].name.isEmpty {
            partitions[idx].name = (path as NSString).lastPathComponent
        }
        partitions[idx].items = Self.scanFolder(path)
        requestSave()
        syncFolderWatchers()
    }

    /// 把文件/文件夹移动到文档分区对应的文件夹，返回失败说明
    func moveIntoFolder(_ urls: [URL], to id: UUID) -> [String] {
        guard let idx = index(of: id), partitions[idx].kind == .folder else { return [] }
        guard let folder = partitions[idx].folderPath else { return ["还没有设置文件夹"] }
        var errors: [String] = []
        let folderURL = URL(fileURLWithPath: folder)

        for url in urls {
            let src = url.standardizedFileURL
            let target = folderURL.standardizedFileURL
            if src.path == target.path || src.path.hasPrefix(target.path + "/") { continue }
            // 避免把 /Applications 里的 App 移走导致应用损坏
            if src.pathExtension.lowercased() == "app" {
                errors.append("\(src.lastPathComponent)：App 建议放进「应用分区」，已跳过")
                continue
            }

            var destination = target.appendingPathComponent(src.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                destination = Self.uniqueDestination(for: destination)
            }
            do {
                try FileManager.default.moveItem(at: src, to: destination)
            } catch {
                errors.append("\(src.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        refreshFolder(id)
        return errors
    }

    func refreshFolder(_ id: UUID, save: Bool = true) {
        guard let idx = index(of: id), partitions[idx].kind == .folder else { return }
        guard let path = partitions[idx].folderPath else {
            if !partitions[idx].items.isEmpty {
                partitions[idx].items = []
                if save { requestSave() }
            }
            return
        }
        let items = Self.scanFolder(path)
        if partitions[idx].items != items {
            partitions[idx].items = items
            if save { requestSave() }
        }
    }

    func refreshAllFolders() {
        for p in partitions where p.kind == .folder {
            refreshFolder(p.id)
        }
    }

    // MARK: 文件夹监听

    func syncFolderWatchers() {
        // 清理失效的监听
        for (id, source) in folderWatchers {
            let stillNeeded: Bool
            if let idx = index(of: id), partitions[idx].kind == .folder, partitions[idx].folderPath != nil {
                stillNeeded = true
            } else {
                stillNeeded = false
            }
            if !stillNeeded {
                source.cancel()
                folderWatchers.removeValue(forKey: id)
            }
        }

        for p in partitions where p.kind == .folder {
            guard let path = p.folderPath else { continue }
            if folderWatchers[p.id] != nil { continue }
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete],
                queue: .main
            )
            let pid = p.id
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.scheduleFolderRefresh(pid)
                }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            folderWatchers[pid] = source
            refreshFolder(pid, save: false)
        }
    }

    private func scheduleFolderRefresh(_ id: UUID) {
        folderRefreshWork[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refreshFolder(id) }
        }
        folderRefreshWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: 屏幕变化

    func normalize(with screens: [ScreenSnapshot]) {
        guard !screens.isEmpty else { return }
        let fallback = screens[0]
        var changed = false
        for i in partitions.indices {
            let p = partitions[i]
            let target = screens.first(where: { $0.displayID == p.screenID }) ?? fallback
            if screens.first(where: { $0.displayID == p.screenID }) == nil {
                partitions[i].screenID = target.displayID
                changed = true
            }
            let v = target.visible
            let w = min(max(200, CGFloat(p.width)), max(200, v.width - 16))
            let h = min(max(180, CGFloat(p.height)), max(180, v.height - 16))
            let x = clamp(CGFloat(p.x), lower: v.minX + 8, upper: max(v.minX + 8, v.maxX - w - 8))
            let y = clamp(CGFloat(p.y), lower: v.minY + 8, upper: max(v.minY + 8, v.maxY - h - 8))
            if p.x != Double(x) || p.y != Double(y) || p.width != Double(w) || p.height != Double(h) {
                partitions[i].x = Double(x)
                partitions[i].y = Double(y)
                partitions[i].width = Double(w)
                partitions[i].height = Double(h)
                changed = true
            }
        }
        if changed { requestSave() }
    }

    // MARK: 首次演示内容

    func seedDemoIfNeeded(on screen: ScreenSnapshot) {
        guard partitions.isEmpty, !FileManager.default.fileExists(atPath: storeURL.path) else { return }

        let apps = [
            "/Applications/Safari.app",
            "/System/Applications/Notes.app",
            "/System/Applications/Calendar.app",
            "/System/Applications/Music.app",
            "/System/Applications/Mail.app",
            "/System/Applications/Photos.app"
        ].filter { FileManager.default.fileExists(atPath: $0) }

        let v = screen.visible
        let w = min(340, max(250, v.width * 0.28))
        let h: CGFloat = 230

        let main = Partition(
            name: "常用工具",
            screenID: screen.displayID,
            x: Double(clamp(v.midX - w / 2 - w / 2 - 12, lower: v.minX + 8, upper: v.maxX - w - 8)),
            y: Double(clamp(v.midY - h / 2, lower: v.minY + 8, upper: v.maxY - h - 8)),
            width: Double(w),
            height: Double(h),
            tintHex: "#0A84FF",
            items: apps.map { StoredItem(path: $0) }
        )

        let second = Partition(
            name: "待整理",
            screenID: screen.displayID,
            x: Double(clamp(v.midX + 12, lower: v.minX + 8, upper: v.maxX - w - 8)),
            y: Double(clamp(v.midY - h / 2, lower: v.minY + 8, upper: v.maxY - h - 8)),
            width: Double(w),
            height: Double(h),
            tintHex: "#BF5AF2"
        )

        partitions = [main, second]
        saveNow()
    }

    // MARK: 工具

    nonisolated static func displayID(of screen: NSScreen) -> UInt32 {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
    }

    static func scanFolder(_ path: String) -> [StoredItem] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls
            .filter { $0.lastPathComponent != ".DS_Store" && $0.lastPathComponent != ".localized" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { StoredItem(path: $0.path) }
    }

    static func uniqueDestination(for url: URL) -> URL {
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var index = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}

// MARK: - 小工具

func clamp<T: Comparable>(_ value: T, lower: T, upper: T) -> T {
    min(max(value, lower), upper)
}
