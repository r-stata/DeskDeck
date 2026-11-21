import AppKit
import SwiftUI
import os

private let mouseLog = Logger(subsystem: "com.ac.desktopmaster", category: "mouse")
private let dragLog = Logger(subsystem: "com.ac.desktopmaster", category: "drag")

// MARK: - 桌面级窗口

final class DesktopOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// 只在卡片区域拦截鼠标事件，空白桌面区域点击穿透给 Finder；同时作为文件拖放的目的视图
final class DesktopHostingView: NSHostingView<AnyView> {
    var hitRectProvider: () -> [CGRect] = { [] }
    /// 系统里正有拖拽进行中（含其他 App 发起的）
    var externalDragActive: () -> Bool = { false }
    /// 某个窗口坐标点落在哪张卡片上
    var partitionIDAt: (CGPoint) -> UUID? = { _ in nil }
    var handleDrop: (UUID, [URL]) -> Bool = { _, _ in false }
    var dropTargetChanged: (UUID?) -> Void = { _ in }

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func topDownPoint(_ point: CGPoint) -> CGPoint {
        let local = convert(point, from: nil)
        return CGPoint(x: local.x, y: isFlipped ? local.y : bounds.height - local.y)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local: NSPoint
        if let superview {
            local = convert(point, from: superview)
        } else {
            local = point
        }
        let y = isFlipped ? local.y : bounds.height - local.y
        let topDown = CGPoint(x: local.x, y: y)
        guard hitRectProvider().contains(where: { $0.contains(topDown) }) else { return nil }
        // 拖拽进行中直接返回自己，让 AppKit 的拖放回调落到这里，而不是被 SwiftUI 内部视图吃掉
        if externalDragActive() { return self }
        return super.hitTest(point) ?? self
    }

    // MARK: 拖放目的

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDragTarget(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDragTarget(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropTargetChanged(nil)
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        dropTargetChanged(nil)
    }

    private func updateDragTarget(_ sender: NSDraggingInfo) -> NSDragOperation {
        let id = partitionIDAt(topDownPoint(sender.draggingLocation))
        dropTargetChanged(id)
        return id == nil ? [] : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let point = topDownPoint(sender.draggingLocation)
        guard let id = partitionIDAt(point) else {
            dragLog.notice("performDragOperation no target")
            return false
        }
        let urls = (sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
        dragLog.notice("performDragOperation urls=\(urls.count, privacy: .public)")
        return handleDrop(id, urls)
    }
}

// MARK: - 覆盖层控制器

@MainActor
final class DesktopOverlayController: NSObject, NSDraggingSource {
    private let state: AppState
    private var windows: [UInt32: DesktopOverlayWindow] = [:]
    private var pollTimer: Timer?
    private var mouseAccepted: [UInt32: Bool] = [:]
    private var doubleClickMonitor: Any?
    private var dragMonitor: Any?
    private var scrollMonitor: Any?
    private var keyMonitor: Any?

    /// 窗口层拖动会话：完全接管移动，不依赖 SwiftUI 手势，避免与图标点击/滚动区抢手势
    private struct DragSession {
        let id: UUID
        let startMouse: CGPoint
        let startOrigin: CGPoint
        let screenFrame: NSRect
        let displayID: UInt32
        let visible: CGRect
    }
    private var dragSession: DragSession?
    private var dragMoved = false

    /// 小宠物拖动会话（移动 / 缩放都由窗口层接管，宠物视图不参与命中测试）
    private enum PetMode { case move, resize }
    private struct PetSession {
        let id: UUID
        let mode: PetMode
        let startMouse: CGPoint
        let startOrigin: CGPoint
        let startSize: Double
        var moved = false
    }
    private var petSession: PetSession?

    /// 待启动的文件拖出（按下时落在可拖出的图标上）
    private struct PendingDragOut {
        let url: URL
        let partitionID: UUID
        let event: NSEvent
        let startMouse: CGPoint
    }
    private var pendingDragOut: PendingDragOut?

    /// 系统里是否有拖拽正在进行（用拖拽专用剪贴板的变更次数判断）
    private var dragPasteboardCount = NSPasteboard(name: .drag).changeCount
    private var externalDrag = false

    init(state: AppState) {
        self.state = state
        super.init()
        startMouseTracking()
        startDoubleClickMonitor()
        startDragMonitor()
        startScrollMonitor()
        startKeyMonitor()
    }

    // MARK: 拖动

    /// 在窗口层直接接管拖动：整张卡片任意位置按下即可移动，鼠标事件不经过 SwiftUI 手势竞争
    private func startDragMonitor() {
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            var swallow = false
            MainActor.assumeIsolated {
                swallow = self.handleDragEvent(event)
            }
            return swallow ? nil : event
        }
    }

    /// 返回 true 表示吞掉事件（正在拖动时不再触发图标点击等）
    private func handleDragEvent(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown:
            dragSession = nil
            dragMoved = false
            pendingDragOut = nil
            petSession = nil
            guard let window = event.window as? DesktopOverlayWindow,
                  let screen = window.screen ?? NSScreen.main else { return false }
            let snap = ScreenSnapshot.make(screen)
            let location = NSEvent.mouseLocation
            let point = CGPoint(x: location.x - screen.frame.minX, y: screen.frame.maxY - location.y)

            // 先看这一下是不是按在小宠物上（未固定时）：是的话挪/缩放宠物，不动卡片
            for partition in state.partitions where partition.screenID == snap.displayID {
                guard let mascot = partition.mascot, !mascot.pinned else { continue }
                let frame = CGRect(x: partition.x + mascot.x, y: partition.y + mascot.y,
                                   width: mascot.size, height: mascot.size)
                guard frame.insetBy(dx: -4, dy: -4).contains(point) else { continue }
                // 右下角 26pt 内算“拉手柄改大小”，其余区域是“挪位置”
                let handle = CGRect(x: frame.maxX - 26, y: frame.maxY - 26, width: 26, height: 26)
                petSession = PetSession(
                    id: partition.id,
                    mode: handle.contains(point) ? .resize : .move,
                    startMouse: location,
                    startOrigin: CGPoint(x: mascot.x, y: mascot.y),
                    startSize: mascot.size
                )
                return true
            }

            for partition in state.partitions where partition.screenID == snap.displayID {
                guard state.editingCardID != partition.id else { continue }
                let rect = CGRect(x: partition.x, y: partition.y, width: partition.width, height: partition.height)
                guard rect.contains(point) else { continue }
                let dx = point.x - partition.x
                let dy = point.y - partition.y
                if !partition.locked {
                    // 右上角按钮条与右下角缩放手柄不参与整体拖动
                    if dy < 44 && dx > partition.width - 126 { continue }
                    if dx > partition.width - 42 && dy > partition.height - 42 { continue }
                    // 指针压在小宠物上：这一下用来挪宠物，不移动卡片
                    if let mascot = mascotHitRect(partition), mascot.contains(point) { continue }
                } else if dy < 44 {
                    // 锁定的卡片：标题栏上的按钮照常可点，只是不参与整体拖动
                    continue
                }
                // 只有落点在图标网格区域里才算拖出文件（标题栏按下不该拖文件）
                if dy < 44 { state.hoveredItemPath = nil }
                // 指针正停在可拖出的图标上：这一下用来把文件拖出去，不移动卡片
                if partition.kind == .folder, dy >= 44, let path = state.hoveredItemPath,
                   FileManager.default.fileExists(atPath: path) {
                    pendingDragOut = PendingDragOut(
                        url: URL(fileURLWithPath: path),
                        partitionID: partition.id,
                        event: event,
                        startMouse: location
                    )
                    return false
                }
                // 卡片已锁定：文件拖出照常，但整张卡不能被拖走
                if partition.locked { continue }
                dragSession = DragSession(
                    id: partition.id,
                    startMouse: location,
                    startOrigin: CGPoint(x: partition.x, y: partition.y),
                    screenFrame: screen.frame,
                    displayID: snap.displayID,
                    visible: snap.visible
                )
                return false
            }
            return false

        case .leftMouseDragged:
            if var pet = petSession {
                guard let partition = state.partitions.first(where: { $0.id == pet.id }),
                      var mascot = partition.mascot else {
                    petSession = nil
                    return false
                }
                let location = NSEvent.mouseLocation
                let dx = location.x - pet.startMouse.x
                let dy = pet.startMouse.y - location.y
                if !pet.moved {
                    guard abs(dx) > 1 || abs(dy) > 1 else { return true }
                    pet.moved = true
                }
                switch pet.mode {
                case .move:
                    mascot.x = min(max(0, Double(pet.startOrigin.x) + Double(dx)), max(0, partition.width - mascot.size))
                    mascot.y = min(max(0, Double(pet.startOrigin.y) + Double(dy)), max(0, partition.height - mascot.size))
                case .resize:
                    let maxSide = Double(min(partition.width, partition.height)) * 0.9
                    let next = min(max(20, pet.startSize + Double(max(dx, dy))), maxSide)
                    mascot.size = next
                    mascot.x = min(max(0, mascot.x), max(0, partition.width - next))
                    mascot.y = min(max(0, mascot.y), max(0, partition.height - next))
                }
                state.setMascot(mascot, for: partition.id, save: false)
                petSession = pet
                return true
            }
            if let pending = pendingDragOut {
                let location = NSEvent.mouseLocation
                let dx = location.x - pending.startMouse.x
                let dy = location.y - pending.startMouse.y
                guard abs(dx) > 4 || abs(dy) > 4 else { return true }
                pendingDragOut = nil
                startFileDragging(pending)
                return true
            }
            guard let session = dragSession else { return false }
            let location = NSEvent.mouseLocation
            let delta = CGSize(width: location.x - session.startMouse.x,
                               height: session.startMouse.y - location.y)
            if !dragMoved {
                guard abs(delta.width) > 2 || abs(delta.height) > 2 else { return false }
                dragMoved = true
                state.isDraggingCard = true
                state.editingCardID = nil
            }
            let visible = session.visible
            let size = state.partitions.first(where: { $0.id == session.id })
            let w = size?.width ?? 340
            let h = size?.height ?? 230
            let maxX = Double(max(visible.minX + 6, visible.maxX - CGFloat(w) - 6))
            let maxY = Double(max(visible.minY + 6, visible.maxY - CGFloat(h) - 6))
            let x = min(max(Double(session.startOrigin.x + delta.width), Double(visible.minX + 6)), maxX)
            let y = min(max(Double(session.startOrigin.y + delta.height), Double(visible.minY + 6)), maxY)
            state.setOrigin(id: session.id, x: x, y: y)
            return true

        case .leftMouseUp:
            if let pet = petSession {
                petSession = nil
                if pet.moved { state.requestSave() }
                return pet.moved
            }
            pendingDragOut = nil
            guard let session = dragSession else { return false }
            let moved = dragMoved
            dragSession = nil
            dragMoved = false
            state.isDraggingCard = false
            if moved {
                state.requestSave()
                return true
            }
            _ = session
            return false

        default:
            return false
        }
    }

    /// 用 AppKit 原生拖拽会话把文件拖出去，拖到桌面/访达即执行移动
    private func startFileDragging(_ pending: PendingDragOut) {
        guard let window = pending.event.window as? DesktopOverlayWindow,
              let view = window.contentView else { return }
        let item = NSDraggingItem(pasteboardWriter: pending.url as NSURL)
        let icon = FileIconProvider.icon(for: pending.url.path)
        let size = CGSize(width: 52, height: 52)
        let local = view.convert(pending.event.locationInWindow, from: nil)
        item.setDraggingFrame(
            NSRect(x: local.x - size.width / 2,
                   y: (view.isFlipped ? local.y : view.bounds.height - local.y) - size.height / 2,
                   width: size.width, height: size.height),
            contents: icon
        )
        dragLog.notice("begin file drag \(pending.url.lastPathComponent, privacy: .public)")
        view.beginDraggingSession(with: [item], event: pending.event, source: self)
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .move, .generic, .link]
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            dragLog.notice("file drag ended op=\(operation.rawValue, privacy: .public)")
            self.externalDrag = false
            for id in self.state.partitions.filter({ $0.kind == .folder }).map({ $0.id }) {
                self.state.refreshFolder(id)
            }
        }
    }

    /// 窗口坐标（左上原点）落在哪张卡片上
    func partitionID(atTopDown point: CGPoint, displayID: UInt32? = nil) -> UUID? {
        guard state.showAll else { return nil }
        for p in state.partitions {
            if let displayID, p.screenID != displayID { continue }
            let rect = CGRect(x: p.x, y: p.y, width: p.width, height: p.height)
            if rect.contains(point) { return p.id }
        }
        return nil
    }

    /// 外部文件拖入卡片后的处理
    func performExternalDrop(on id: UUID, urls: [URL]) -> Bool {
        guard !urls.isEmpty, let partition = state.partitions.first(where: { $0.id == id }) else { return false }
        switch partition.kind {
        case .apps:
            state.addItems(urls, to: id)
        case .folder:
            let errors = state.moveIntoFolder(urls, to: id)
            if !errors.isEmpty {
                Dialogs.info(title: "部分文件没有移入", message: errors.joined(separator: "\n"))
            }
        case .function:
            return false
        }
        return true
    }

    /// SwiftUI 的 tap 手势会和拖动争夺点击，双击改名改在窗口层识别
    private func startDoubleClickMonitor() {
        doubleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                self.handleDoubleClick(event)
            }
            return event
        }
    }

    private func handleDoubleClick(_ event: NSEvent) {
        guard event.clickCount == 2, let window = event.window as? DesktopOverlayWindow else { return }
        guard let screen = window.screen ?? NSScreen.main else { return }
        let localInWindow = window.convertPoint(toScreen: event.locationInWindow)
        let topDown = CGPoint(x: localInWindow.x - screen.frame.minX, y: screen.frame.maxY - localInWindow.y)

        for partition in state.partitions {
            if let mascot = mascotHitRect(partition), mascot.contains(topDown) { continue }
            let header = CGRect(x: partition.x, y: partition.y, width: partition.width, height: 50)
            if header.contains(topDown) {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                state.renameRequest = partition.id
                break
            }
        }
    }

    /// ⌘C：把选中的文件/文件夹本身拷进剪贴板（粘贴到访达即复制文件；输入框有焦点时不拦）
    private func startKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            var swallow = false
            MainActor.assumeIsolated { swallow = self.handleKey(event) }
            return swallow ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              event.charactersIgnoringModifiers?.lowercased() == "c",
              let path = state.selectedItemPath else { return false }
        if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView {
            return false   // 文本编辑中，交回系统处理
        }
        Clipboard.copyFiles([path])
        return true
    }

    /// 小宠物在屏幕坐标系里的矩形（top-down）
    private func mascotHitRect(_ partition: Partition) -> CGRect? {
        // 固定位置的宠物不吃鼠标：点它等于点卡片
        guard let m = partition.mascot, !m.pinned else { return nil }
        return CGRect(x: partition.x + m.x, y: partition.y + m.y, width: m.size, height: m.size)
    }

    /// 指针压在小宠物上时，滚轮用来放大/缩小宠物
    private func startScrollMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            guard let self else { return event }
            var swallowed = false
            MainActor.assumeIsolated { swallowed = self.handleScroll(event) }
            return swallowed ? nil : event
        }
    }

    private func handleScroll(_ event: NSEvent) -> Bool {
        guard let window = event.window as? DesktopOverlayWindow,
              let screen = window.screen ?? NSScreen.main else { return false }
        let location = NSEvent.mouseLocation
        let point = CGPoint(x: location.x - screen.frame.minX, y: screen.frame.maxY - location.y)
        for partition in state.partitions where partition.screenID == ScreenSnapshot.make(screen).displayID {
            guard var mascot = partition.mascot, let hit = mascotHitRect(partition), hit.contains(point) else { continue }
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 3
            guard abs(delta) > 0.4 else { return true }
            let maxSide = min(partition.width, partition.height) * 0.9
            let next = min(max(24, mascot.size + delta), maxSide)
            guard abs(next - mascot.size) > 0.5 else { return true }
            mascot.size = next
            mascot.x = min(max(0, mascot.x), max(0, partition.width - next))
            mascot.y = min(max(0, mascot.y), max(0, partition.height - next))
            state.setMascot(mascot, for: partition.id)
            return true
        }
        return false
    }

    /// 只有指针落在卡片/工具条上时窗口才接收鼠标，其余时候整层窗口对鼠标透明，
    /// 桌面图标、右键菜单、访达拖拽都保持原样可用。
    private func startMouseTracking() {
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateMouseAcception()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func updateMouseAcception() {
        // 跟踪系统拖拽状态
        let pasteboardCount = NSPasteboard(name: .drag).changeCount
        if pasteboardCount != dragPasteboardCount {
            dragPasteboardCount = pasteboardCount
            externalDrag = NSEvent.pressedMouseButtons != 0
        }
        if externalDrag && NSEvent.pressedMouseButtons == 0 {
            externalDrag = false
        }
        // 拖动中窗口必须持续接收鼠标，否则指针跑出原卡片矩形就会丢失后续事件
        if dragSession != nil {
            if NSEvent.pressedMouseButtons == 0 {
                dragSession = nil
                dragMoved = false
                state.isDraggingCard = false
            } else {
                return
            }
        }
        // 兜底：拖动状态卡住时，鼠标一松开就恢复命中检测
        if state.isDraggingCard && NSEvent.pressedMouseButtons == 0 {
            state.isDraggingCard = false
        }
        if state.isDraggingCard { return }
        let location = NSEvent.mouseLocation
        var hoveredAnyCard = false

        for (displayID, window) in windows {
            guard let screen = NSScreen.screens.first(where: { AppState.displayID(of: $0) == displayID }) else { continue }
            let snap = ScreenSnapshot.make(screen)
            let local = CGPoint(x: location.x - screen.frame.minX, y: screen.frame.maxY - location.y)
            let inside = hitRects(for: snap).contains { $0.contains(local) }

            if inside { hoveredAnyCard = true }
            // 指针不在卡片上就必须彻底穿透，拖拽中也不例外，
            // 否则整层窗口会盖住桌面，把「拖到桌面松手」的落点吞掉
            if inside {
                if window.ignoresMouseEvents { window.ignoresMouseEvents = false }
            } else {
                if !window.ignoresMouseEvents { window.ignoresMouseEvents = true }
            }

            let accepted = !window.ignoresMouseEvents
            if mouseAccepted[displayID] != accepted {
                mouseAccepted[displayID] = accepted
                mouseLog.notice("mouse accept \(accepted, privacy: .public) screen \(displayID, privacy: .public)")
            }
        }
        if !hoveredAnyCard { state.dropTargetID = nil }
    }

    func rebuild() {
        let screens = NSScreen.screens
        let snapshots = screens.map { ScreenSnapshot.make($0) }
        state.normalize(with: snapshots)

        var needed = Set<UInt32>()
        for screen in screens {
            let snap = ScreenSnapshot.make(screen)
            needed.insert(snap.displayID)

            if let window = windows[snap.displayID] {
                window.setFrame(screen.frame, display: false)
                window.contentView = makeHosting(snap)
            } else {
                let window = makeWindow(screen: screen, snap: snap)
                windows[snap.displayID] = window
                window.orderFrontRegardless()
            }
        }

        for (id, window) in windows where !needed.contains(id) {
            window.orderOut(nil)
            windows.removeValue(forKey: id)
        }

        for (_, window) in windows {
            window.orderFrontRegardless()
        }
    }

    func showAllDidChange() {
        // SwiftUI 视图由状态驱动刷新，这里只需要重排，避免窗口掉层
        for (_, window) in windows {
            window.orderFrontRegardless()
        }
    }

    func screenUnderMouse() -> ScreenSnapshot {
        let location = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) } ?? NSScreen.main
        if let screen { return ScreenSnapshot.make(screen) }
        let fallback = NSScreen.screens.first
        return ScreenSnapshot.make(fallback ?? NSScreen.main ?? NSScreen.screens[0])
    }

    func screenSnapshot(for displayID: UInt32) -> ScreenSnapshot? {
        guard let screen = NSScreen.screens.first(where: { AppState.displayID(of: $0) == displayID }) else { return nil }
        return ScreenSnapshot.make(screen)
    }

    // MARK: 构造窗口

    private func makeWindow(screen: NSScreen, snap: ScreenSnapshot) -> DesktopOverlayWindow {
        let window = DesktopOverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.setFrame(screen.frame, display: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.isMovable = false
        window.isMovableByWindowBackground = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.animationBehavior = .none
        window.contentView = makeHosting(snap)
        window.orderFrontRegardless()
        return window
    }

    private func makeHosting(_ snap: ScreenSnapshot) -> DesktopHostingView {
        let root = AnyView(
            DesktopRootView(state: state, screen: snap)
                .environment(\.colorScheme, .dark)
        )
        let hosting = DesktopHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: snap.frameSize)
        hosting.hitRectProvider = { [weak self] in
            guard let self else { return [] }
            return self.hitRects(for: snap)
        }
        hosting.externalDragActive = { [weak self] in self?.externalDrag ?? false }
        hosting.partitionIDAt = { [weak self] point in
            self?.partitionID(atTopDown: point, displayID: snap.displayID)
        }
        hosting.handleDrop = { [weak self] id, urls in
            self?.performExternalDrop(on: id, urls: urls) ?? false
        }
        hosting.dropTargetChanged = { [weak self] id in
            self?.state.dropTargetID = id
        }
        return hosting
    }

    /// 卡片在窗口坐标系（翻转后即左上角原点）中的矩形
    private func hitRects(for snap: ScreenSnapshot) -> [CGRect] {
        var rects: [CGRect] = []
        if state.showAll {
            for p in state.partitions where p.screenID == snap.displayID {
                rects.append(CGRect(x: p.x, y: p.y, width: p.width, height: p.height))
            }
        }
        return rects
    }
}
