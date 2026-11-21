import AppKit
import SwiftUI
import ServiceManagement

// MARK: - 应用入口

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState()
    private var overlay: DesktopOverlayController!
    private var menuBar: MenuBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppMenus.install()

        state.load()
        overlay = DesktopOverlayController(state: state)
        overlay.rebuild()

        state.seedDemoIfNeeded(on: overlay.screenUnderMouse())
        overlay.rebuild()
        state.refreshAllFolders()

        menuBar = MenuBarController(state: state, overlay: overlay)

        if CommandLine.arguments.contains("--colorpanel") {
            // 调试用：直接打开卡片配色面板，方便核对预览块
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, let first = self.state.partitions.first else { return }
                ColorPickerWindow.show(partitionID: first.id, state: self.state)
            }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func screenParametersChanged() {
        overlay.rebuild()
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.saveNow()
    }
}

// MARK: - 开机自启动

@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "已开启"
        case .requiresApproval: return "等待在「系统设置 → 通用 → 登录项」中允许"
        case .notFound: return "未注册"
        case .notRegistered: return "未开启"
        @unknown default: return "未知"
        }
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

// MARK: - 菜单栏

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let state: AppState
    private let overlay: DesktopOverlayController
    private let statusItem: NSStatusItem
    private let statusMenu = NSMenu()

    init(state: AppState, overlay: DesktopOverlayController) {
        self.state = state
        self.overlay = overlay
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: "DeskDeck")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "DeskDeck · 桌面分区"
        }
        statusMenu.delegate = self
        statusItem.menu = statusMenu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        addItem(to: menu, title: "新建应用分区", action: #selector(newAppsPartition))
        addItem(to: menu, title: "新建文档分区…", action: #selector(newFolderPartition))
        addItem(to: menu, title: "新建 R 函数分区", action: #selector(newRFunctionPartition))
        addItem(to: menu, title: "新建 Python 函数分区", action: #selector(newPythonFunctionPartition))

        menu.addItem(.separator())
        let showItem = addItem(to: menu, title: "显示所有分区", action: #selector(toggleShowAll))
        showItem.state = state.showAll ? .on : .off

        let loginItem = addItem(to: menu, title: "开机自动启动", action: #selector(toggleLaunchAtLogin))
        loginItem.state = LaunchAtLogin.isEnabled ? .on : .off

        menu.addItem(.separator())
        addItem(to: menu, title: "使用说明 / 关于", action: #selector(showHelp))
        addItem(to: menu, title: "打开数据文件夹", action: #selector(revealData))
        menu.addItem(.separator())
        addItem(to: menu, title: "退出 DeskDeck", action: #selector(quitApp))
    }

    @discardableResult
    private func addItem(to menu: NSMenu, title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func newAppsPartition() {
        state.createPartition(on: overlay.screenUnderMouse(), kind: .apps)
    }

    @objc private func newFolderPartition() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.title = "选择文档分区对应的文件夹"
        panel.message = "之后拖进这个分区的文件会被移动到该文件夹"
        panel.prompt = "使用此文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            state.createPartition(on: overlay.screenUnderMouse(), kind: .folder, folderPath: url.path)
        }
    }

    @objc private func newRFunctionPartition() {
        state.createPartition(on: overlay.screenUnderMouse(), kind: .function, language: .r)
    }

    @objc private func newPythonFunctionPartition() {
        state.createPartition(on: overlay.screenUnderMouse(), kind: .function, language: .python)
    }

    @objc private func toggleShowAll() {
        state.showAll.toggle()
        state.requestSave()
        overlay.showAllDidChange()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try LaunchAtLogin.set(!LaunchAtLogin.isEnabled)
            if LaunchAtLogin.statusDescription.contains("等待") {
                Dialogs.info(
                    title: "已加入登录项，需要你确认一次",
                    message: "打开「系统设置 → 通用 → 登录项」，允许「DeskDeck」即可。"
                )
            }
        } catch {
            Dialogs.info(
                title: "开机自启动设置失败",
                message: "\(error.localizedDescription)\n\n建议先把「DeskDeck.app」放在「应用程序」文件夹，再试一次。"
            )
        }
    }

    @objc private func showHelp() {
        Dialogs.info(
            title: "DeskDeck · 使用说明",
            message: """
            · 菜单栏方块图标 →「新建应用分区」或「新建文档分区…」，新分区生成在屏幕中间，按住卡片任意位置即可拖动。
            · 应用分区：把 App、文件、文件夹拖进来，单击图标打开。
            · 文档分区：绑定你选择的文件夹，拖进来的文件会被「移动」到该文件夹里，所以在分区里看到的就是那个文件夹的内容。
            · 分区标题双击可改名；标题右侧的锁可锁定位置与大小，防止误拖。
            · 卡片右上角「⋯」可换颜色、排序、更改目录、添加小宠物、删除分区（不会删除文件）。
            · 小宠物：菜单「添加小宠物图标…」支持 SVG / PNG / GIF；按住它能在卡片内拖动，指针停在它上面滚动滚轮可以放大缩小。
            · 函数分区（R / Python）：在「函数设置」里切换语言并指定 Rscript 或 python3、预先 source / 加载的脚本、函数名和默认工作目录，读取参数后会按类型生成文本/数值输入框、下拉选项或开关；点「提交」即调用该函数并显示结果。
            · 菜单栏图标：显示/隐藏全部分区、开机自动启动、使用说明。
            · 本应用只在指针落到卡片上时才占用鼠标，桌面图标和右键菜单照常可用。

            分区数据：~/Library/Application Support/DeskDeck/state.json

            开发：微信公众号 RStata
            """
        )
    }

    @objc private func revealData() {
        do {
            try FileManager.default.createDirectory(at: state.supportDirectory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(state.supportDirectory)
        } catch {
            NSSound.beep()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

// MARK: - 通用弹窗

@MainActor
enum Dialogs {
    static func confirm(title: String, message: String, confirmTitle: String = "确定") -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func info(title: String, message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
