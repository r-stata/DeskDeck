import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - 玻璃分区卡片

struct PartitionCardView: View {
    @Binding var partition: Partition
    let state: AppState
    let screen: ScreenSnapshot

    @State private var isHovering = false
    @State private var isDropTargeted = false
    @State private var resizeDelta: CGSize = .zero
    @State private var pointer: CGPoint = CGPoint(x: 0.28, y: 0.18)
    @State private var isEditingName = false
    @State private var nameEditStartedAt = Date.distantPast
    @State private var nameEditRefocused = false
    @FocusState private var nameFocused: Bool

    private let cornerRadius: CGFloat = 26
    private let minWidth: CGFloat = 210
    private let minHeight: CGFloat = 170

    private var tint: Color { Color(hex: partition.tintHex) }

    /// 外部拖拽悬停在这张卡片上（AppKit 拖放回调或 SwiftUI drop 任一命中）
    private var dropTargeted: Bool {
        isDropTargeted || state.dropTargetID == partition.id
    }

    private var liveSize: CGSize {
        CGSize(width: max(minWidth, partition.width + resizeDelta.width),
               height: max(minHeight, partition.height + resizeDelta.height))
    }

    private var liveOrigin: CGPoint {
        CGPoint(x: partition.x, y: partition.y)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            GlassCardBackground(
                tint: tint,
                cornerRadius: cornerRadius,
                isHovering: isHovering,
                isDropTargeted: dropTargeted,
                pointer: pointer
            )

            VStack(spacing: 0) {
                header
                Rectangle()
                    .fill(.white.opacity(0.09))
                    .frame(height: 1)
                    .padding(.horizontal, 12)
                itemsArea
            }
            .padding(.bottom, 10)

            if let mascot = partition.mascot {
                MascotLayer(spec: mascot, cardSize: liveSize) { updated in
                    state.setMascot(clampMascot(updated), for: partition.id)
                }
            }
        }
        .coordinateSpace(name: "deskdeck-card")
        .frame(width: liveSize.width, height: liveSize.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if !partition.locked {
                resizeHandle
            }
        }
        .shadow(color: .black.opacity(isHovering ? 0.38 : 0.28), radius: isHovering ? 28 : 18, y: isHovering ? 14 : 9)
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
        .shadow(color: tint.opacity(isHovering ? 0.38 : 0.0), radius: 24)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: isHovering)
        .animation(.easeOut(duration: 0.3), value: isHovering)
        .offset(x: liveOrigin.x, y: liveOrigin.y)
        .onHover { hovering in
            if !state.isDraggingCard { isHovering = hovering }
        }
        .onContinuousHover { phase in
            guard !state.isDraggingCard else { return }
            if case .active(let location) = phase {
                let next = CGPoint(
                    x: max(0, min(1, location.x / max(1, liveSize.width))),
                    y: max(0, min(1, location.y / max(1, liveSize.height)))
                )
                if abs(next.x - pointer.x) > 0.02 || abs(next.y - pointer.y) > 0.02 {
                    pointer = next
                }
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            DropLoader.urls(from: providers) { urls in
                handleDrop(urls)
            }
            return true
        }
        .contextMenu { cardMenu }
        .onChange(of: state.renameRequest) { _, requested in
            guard requested == partition.id else { return }
            state.renameRequest = nil
            beginNameEditing()
        }
    }

    // MARK: 标题栏

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: partition.kind == .function
                                    ? (partition.rConfig?.language == .python ? "curlybraces" : "function")
                                    : partition.kind.symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))

                if isEditingName {
                    TextField("分区名称", text: $partition.name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                        .focused($nameFocused)
                        .onSubmit { commitName() }
                        .onExitCommand { cancelNameEditing() }
                        .onChange(of: nameFocused) { _, focused in
                            guard isEditingName else { return }
                            if focused {
                                nameEditRefocused = true
                                return
                            }
                            // 刚进入编辑时窗口可能还没成为 key 窗口，这一下失焦不算数，
                            // 补一次聚焦，避免输入框刚出现就被判为失焦而退出编辑
                            if Date().timeIntervalSince(nameEditStartedAt) < 0.35 && !nameEditRefocused {
                                DispatchQueue.main.async { if isEditingName { nameFocused = true } }
                            } else if nameEditRefocused {
                                commitName()
                            }
                        }
                } else {
                    Text(partition.name)
                        .onTapGesture(count: 2) {
                            // 窗口层监听之外的第二条路径：直接双击标题文字也能改名
                            state.renameRequest = nil
                            beginNameEditing()
                        }
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                        .help("按住卡片任意位置拖动；双击标题改名")
                }

                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())

            Text("\(partition.items.count)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.62))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(.white.opacity(0.12)))

            Button {
                state.setLocked(!partition.locked, for: partition.id)
            } label: {
                Image(systemName: partition.locked ? "lock.fill" : "lock.open")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(partition.locked ? 0.72 : (isHovering ? 0.5 : 0.24)))
                    .frame(width: 16, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(partition.locked ? "已锁定，取消后才能拖动或缩放" : "锁定位置与大小")

            if partition.kind == .apps {
                Button {
                    chooseFiles()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(isHovering ? 0.78 : 0.55))
                }
                .buttonStyle(.plain)
                .help("添加应用或文件")
            }

            if partition.kind == .function {
                Button {
                    openFunctionSettings()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(isHovering ? 0.78 : 0.55))
                        .frame(width: 16, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("函数设置")
            }

            Menu {
                cardMenu
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(isHovering ? 0.78 : 0.55))
                    .frame(width: 16, height: 14)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 9)
    }

    // MARK: 内容区

    private var itemsArea: some View {
        Group {
            if partition.kind == .function {
                FunctionPanelView(partition: $partition, state: state) {
                    openFunctionSettings()
                }
            } else if partition.items.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 68, maximum: 80), spacing: 6, alignment: .leading)],
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ForEach(partition.items) { item in
                            ItemTileView(
                                item: item,
                                allowsRemove: partition.kind == .apps,
                                allowsDragOut: partition.kind == .folder,
                                isSelected: state.selectedItemPath == item.path,
                                singleClickOpens: partition.kind == .apps,
                                onSelect: { state.selectedItemPath = item.path },
                                onOpen: { open(item) },
                                onReveal: { reveal(item) },
                                onRemove: { remove(item) },
                                onHoverChanged: { hovering in
                                    guard partition.kind == .folder else { return }
                                    if hovering {
                                        state.hoveredItemPath = item.path
                                    } else if state.hoveredItemPath == item.path {
                                        state.hoveredItemPath = nil
                                    }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: emptySymbol)
                .font(.system(size: 22, weight: .light))
            Text(emptyTitle)
                .font(.system(size: 11, weight: .medium))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10)

            if partition.kind == .folder && partition.folderPath == nil {
                Button("选择文件夹…") { chooseFolder() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.white.opacity(0.16)))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
            }
        }
        .foregroundStyle(.white.opacity(isDropTargeted ? 0.9 : 0.42))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    .white.opacity(isDropTargeted ? 0.6 : 0.18),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        )
    }

    private var emptySymbol: String {
        if isDropTargeted { return "arrow.down.circle.fill" }
        if partition.kind == .folder {
            return partition.folderPath == nil ? "folder.badge.plus" : "folder"
        }
        return "arrow.down.doc"
    }

    private var emptyTitle: String {
        if isDropTargeted {
            return partition.kind == .folder ? "松手即移入文件夹" : "松手即可加入"
        }
        if partition.kind == .folder {
            if partition.folderPath == nil { return "先选一个文件夹\n之后拖入的文件会移动到这里" }
            return "文件夹是空的\n拖文件或文件夹进来会移动到此"
        }
        return "把应用或文件拖到这里"
    }

    // MARK: 缩放手柄

    private var resizeHandle: some View {
        Image(systemName: "arrow.down.right")
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(.white.opacity(isHovering ? 0.5 : 0.22))
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .padding(6)
            .gesture(resizeGesture)
            .help("拖动调整分区大小")
    }

    // MARK: 手势

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if !state.isDraggingCard { state.isDraggingCard = true }
                resizeDelta = value.translation
            }
            .onEnded { value in
                let v = screen.visible
                let newWidth = max(minWidth, partition.width + Double(value.translation.width))
                let newHeight = max(minHeight, partition.height + Double(value.translation.height))
                partition.width = min(newWidth, Double(v.width - 12))
                partition.height = min(newHeight, Double(v.height - 12))
                resizeDelta = .zero
                state.isDraggingCard = false
                state.requestSave()
            }
    }

    // MARK: 菜单

    @ViewBuilder
    private var cardMenu: some View {
        Button("重命名") { beginNameEditing() }
        Toggle("锁定位置与大小", isOn: Binding(
            get: { partition.locked },
            set: { state.setLocked($0, for: partition.id) }
        ))

        if partition.kind == .function {
            Button("函数设置…") { openFunctionSettings() }
            Button("在访达中显示工作目录") { revealWorkingDirectory() }
        } else if partition.kind == .folder {
            Button("更改文件夹…") { chooseFolder() }
            Button("在访达中显示文件夹") { revealFolder() }
            Button("刷新内容") { state.refreshFolder(partition.id) }
        } else {
            Button("添加文件…") { chooseFiles() }
        }

        Button("按名称排序") { state.sortItems(in: partition.id) }
        Divider()
        Button(partition.mascot == nil ? "添加小宠物图标…" : "更换小宠物图标…") { chooseMascot() }
        if partition.mascot != nil {
            Toggle("固定小宠物位置（不影响卡片操作）", isOn: Binding(
                get: { partition.mascot?.pinned ?? true },
                set: { newValue in
                    guard var m = partition.mascot else { return }
                    m.pinned = newValue
                    state.setMascot(m, for: partition.id)
                }
            ))
            Menu("小宠物大小") {
                Button("很小（32 pt）") { resizeMascot(to: 32) }
                Button("小（48 pt）") { resizeMascot(to: 48) }
                Button("中（64 pt）") { resizeMascot(to: 64) }
                Button("大（96 pt）") { resizeMascot(to: 96) }
                Button("特大（140 pt）") { resizeMascot(to: 140) }
            }
            Button("把小宠物放回右下角") {
                if var m = partition.mascot {
                    m.size = min(m.size, Double(liveSize.width) - 16)
                    m.x = Double(liveSize.width) - m.size - 12
                    m.y = Double(liveSize.height) - m.size - 12
                    state.setMascot(clampMascot(m), for: partition.id)
                }
            }
            Button("移除小宠物", role: .destructive) { state.setMascot(nil, for: partition.id) }
        }
        Divider()
        Button("卡片颜色…") {
            ColorPickerWindow.show(partitionID: partition.id, state: state)
        }
        Divider()
        if partition.kind == .apps {
            Button("移出所有项目") {
                withAnimation(.easeOut(duration: 0.2)) {
                    for item in partition.items {
                        state.removeItem(item.path, from: partition.id)
                    }
                }
            }
        }
        Button("删除分区", role: .destructive) { deleteCard() }
    }

    // MARK: 小宠物

    private func chooseMascot() {
        let panel = NSOpenPanel()
        panel.title = "选择小宠物图标"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .gif, .jpeg, .svg, .heic, .tiff, .webP].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let prepared = MascotImages.prepare(fileURL: url) else {
            Dialogs.info(title: "这个图标读不出来", message: "换一个 png / gif / svg 文件试试。")
            return
        }
        let size = min(56, Double(min(liveSize.width, liveSize.height)) * 0.25)
        var spec = MascotSpec(
            path: url.path,
            renderPath: prepared == url.path ? nil : prepared,
            x: Double(liveSize.width) - size - 12,
            y: Double(liveSize.height) - size - 12,
            size: size
        )
        spec = clampMascot(spec)
        MascotImages.forget(prepared)
        state.setMascot(spec, for: partition.id)
    }

    private func resizeMascot(to size: Double) {
        guard var spec = partition.mascot else { return }
        spec.size = size
        state.setMascot(clampMascot(spec), for: partition.id)
    }

    /// 把位置和大小夹在卡片内部
    private func clampMascot(_ spec: MascotSpec) -> MascotSpec {
        var m = spec
        m.size = min(max(24, m.size), Double(min(liveSize.width, liveSize.height) * 0.9))
        m.x = min(max(0, m.x), max(0, Double(liveSize.width) - m.size))
        m.y = min(max(0, m.y), max(0, Double(liveSize.height) - m.size))
        return m
    }

    private func openFunctionSettings() {
        state.editingCardID = nil
        FunctionWindows.showSettings(partitionID: partition.id, state: state)
    }

    private func revealWorkingDirectory() {
        guard let path = partition.rConfig?.workingDirectory, !path.isEmpty else {
            Dialogs.info(title: "还没有设置工作目录", message: "在「函数设置」里选择一个默认工作目录。")
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    // MARK: 命名

    private func beginNameEditing() {
        guard !isEditingName else { return }
        // 桌面层窗口属于配件型 App：先把 App 激活、把这一层窗口设成 key 窗口，
        // 键盘输入才会进到标题输入框里（否则只有光标闪、打不进字）
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window is DesktopOverlayWindow {
            window.makeKeyAndOrderFront(nil)
        }
        nameEditStartedAt = Date()
        nameEditRefocused = false
        isEditingName = true
        state.editingCardID = partition.id
        DispatchQueue.main.async { nameFocused = true }
        // 让要改的文字整段高亮：直接打字就是替换，不用先手动全选
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard isEditingName else { return }
            let editor = NSApp.keyWindow?.firstResponder as? NSTextView
                ?? NSApp.windows.compactMap({ $0.firstResponder as? NSTextView }).first
            editor?.selectAll(nil)
        }
    }

    private func cancelNameEditing() {
        isEditingName = false
        nameFocused = false
        if state.editingCardID == partition.id { state.editingCardID = nil }
        state.requestSave()
    }

    private func commitName() {
        let trimmed = partition.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { partition.name = trimmed }
        isEditingName = false
        nameFocused = false
        if state.editingCardID == partition.id { state.editingCardID = nil }
        state.requestSave()
    }

    // MARK: 拖放 / 打开

    private func handleDrop(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        switch partition.kind {
        case .apps:
            state.addItems(urls, to: partition.id)
        case .folder:
            if partition.folderPath == nil {
                guard chooseFolder() else { return }
            }
            let errors = state.moveIntoFolder(urls, to: partition.id)
            if !errors.isEmpty {
                Dialogs.info(
                    title: "部分文件没能移入",
                    message: errors.joined(separator: "\n")
                )
            }
        case .function:
            break
        }
    }

    private func open(_ item: StoredItem) {
        guard FileManager.default.fileExists(atPath: item.path) else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(item.url)
    }

    private func reveal(_ item: StoredItem) {
        guard FileManager.default.fileExists(atPath: item.path) else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    private func remove(_ item: StoredItem) {
        withAnimation(.easeOut(duration: 0.2)) {
            state.removeItem(item.path, from: partition.id)
        }
    }

    private func revealFolder() {
        guard let path = partition.folderPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func chooseFiles() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.title = "添加到「\(partition.name)」"
        panel.prompt = "加入分区"
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first
        if panel.runModal() == .OK {
            state.addItems(panel.urls, to: partition.id)
        }
    }

    @discardableResult
    private func chooseFolder() -> Bool {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.title = "选择文档分区对应的文件夹"
        panel.message = "拖入这个分区的文件会被移动到该文件夹"
        panel.prompt = "使用此文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            state.setFolder(url.path, for: partition.id)
            return true
        }
        return false
    }

    private func deleteCard() {
        let ok = Dialogs.confirm(
            title: "删除分区「\(partition.name)」？",
            message: partition.kind == .folder
                ? "只会移除桌面上的这个区块，文件夹和里面的文件都保持原样。"
                : "只会移除桌面上的这个玻璃分区，里面的应用和文件不会被删除。",
            confirmTitle: "删除分区"
        )
        if ok {
            withAnimation(.easeOut(duration: 0.2)) {
                state.deletePartition(partition.id)
            }
        }
    }
}

// MARK: - 单个项目

struct ItemTileView: View {
    let item: StoredItem
    let allowsRemove: Bool
    var allowsDragOut: Bool = false
    var isSelected: Bool = false
    /// 应用分区保持老习惯：单击直接打开；文档分区是单击选中、双击打开
    var singleClickOpens: Bool = false
    var onSelect: () -> Void = {}
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onRemove: () -> Void
    let onHoverChanged: (Bool) -> Void

    @State private var isHovering = false
    @State private var isMissing = false

    var body: some View {
        tile
    }

    private func copyPath() {
        Clipboard.copyPath(item.path)
    }

    private func copyItem() {
        onSelect()
        Clipboard.copyFiles([item.path])
    }

    private var dragPreview: some View {
        VStack(spacing: 2) {
            Image(nsImage: FileIconProvider.icon(for: item.path))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 44, height: 44)
            Text(item.displayName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(.black.opacity(0.5)))
        }
        .padding(4)
    }

    private var tile: some View {
        VStack(spacing: 4) {
            Image(nsImage: FileIconProvider.icon(for: item.path))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 46, height: 46)
                .opacity(isMissing ? 0.4 : 1)

            Text(item.displayName)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(isMissing ? 0.4 : 0.9))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .frame(height: 25, alignment: .top)
                .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 2)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(isSelected ? 0.26 : (isHovering ? 0.14 : 0.0)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(isSelected ? 0.55 : (isHovering ? 0.18 : 0.0)), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering in
            isHovering = hovering
            onHoverChanged(hovering)
        }
        .onAppear { isMissing = !item.exists }
        // 文档分区：单击 = 选中（不打开），双击 = 打开
        // 应用分区：单击 = 打开（原来的习惯）
        .onTapGesture(count: 2) { onSelect(); onOpen() }
        .onTapGesture(count: 1) {
            onSelect()
            if singleClickOpens { onOpen() }
        }
        .contextMenu {
            Button("打开") { onOpen() }
            Button("在访达中显示") { onReveal() }
            Button("复制") { copyItem() }
            Button("复制完整路径") { copyPath() }
            if allowsRemove {
                Divider()
                if let name = NSWorkspace.shared.urlForApplication(toOpen: item.url)?.lastPathComponent {
                    Text("默认打开：\(name)")
                }
                Button("移出分区") { onRemove() }
            }
        }
        .help(isMissing ? "文件已移动或删除：\(item.path)" : item.path)
        .animation(.easeOut(duration: 0.16), value: isHovering)
    }
}
