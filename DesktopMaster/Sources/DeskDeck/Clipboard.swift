import AppKit

/// 剪贴板写入：区分「复制文件本身」和「复制路径文本」两种语义
enum Clipboard {
    /// 把真实文件/文件夹放进剪贴板
    /// - 在访达里 ⌘V = 复制文件本身（和访达自己的复制一致）
    /// - 在文本框里 ⌘V = 得到路径
    static func copyFiles(_ paths: [String]) {
        let items: [NSPasteboardItem] = paths.compactMap { path in
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            item.setString(path, forType: .string)
            return item
        }
        guard !items.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
    }

    /// 只写路径文本（老行为，菜单里作为单独一项保留）
    static func copyPath(_ path: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
    }
}
