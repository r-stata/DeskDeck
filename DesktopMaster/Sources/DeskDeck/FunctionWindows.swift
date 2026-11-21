import SwiftUI
import AppKit

/// 函数分区的设置与结果都放在独立的普通窗口里：
/// 桌面卡片所在的窗口是桌面层级的无边框穿透窗口，SwiftUI 的 sheet 挂在上面会显示异常。
@MainActor
enum FunctionWindows {
    private static var openWindows: [NSWindow] = []

    static func showSettings(partitionID: UUID, state: AppState) {
        guard let index = state.partitions.firstIndex(where: { $0.id == partitionID }) else { return }
        let binding = Binding<Partition>(
            get: { state.partitions[index] },
            set: { state.partitions[index] = $0 }
        )
        present(title: "函数设置",
                size: NSSize(width: 620, height: 780),
                content: FunctionSettingsView(partition: binding, state: state))
    }

    static func showResult(_ result: FunctionRunResult) {
        present(title: "运行日志",
                size: NSSize(width: 560, height: 460),
                content: FunctionResultView(result: result))
    }

    private static func present<Content: View>(title: String, size: NSSize, content: Content) {
        openWindows.removeAll { !$0.isVisible }

        var window: NSWindow!
        let close: () -> Void = { window?.close() }
        let wrapped = AnyView(content)

        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: AnyView(
            CloseWrapper(content: wrapped, onClose: close)
        ))
        window.minSize = size
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        openWindows.append(window)
    }
}

private struct CloseWrapper<Content: View>: View {
    let content: Content
    let onClose: () -> Void

    var body: some View {
        content.environment(\.functionWindowClose, onClose)
    }
}

private struct FunctionWindowCloseKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var functionWindowClose: () -> Void {
        get { self[FunctionWindowCloseKey.self] }
        set { self[FunctionWindowCloseKey.self] = newValue }
    }
}
