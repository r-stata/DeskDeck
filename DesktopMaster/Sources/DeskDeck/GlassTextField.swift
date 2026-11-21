import SwiftUI
import AppKit

/// 卡片上的参数输入框：SwiftUI 的 .plain 输入框在深色玻璃底上光标几乎看不见，
/// 这里直接包一层 NSTextField，把插入点染成亮色、选中高亮调亮，并放大字体让光标更高更醒目。
struct GlassTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var fontSize: CGFloat = 14
    var onFocusChange: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> CaretTextField {
        let field = CaretTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: fontSize, weight: .regular)
        field.textColor = NSColor.white.withAlphaComponent(0.96)
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.lineBreakMode = .byClipping
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.38),
                .font: NSFont.systemFont(ofSize: fontSize, weight: .regular)
            ]
        )
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: CaretTextField, context: Context) {
        context.coordinator.parent = self
        field.font = .systemFont(ofSize: fontSize, weight: .regular)
        if field.stringValue != text, field.currentEditor() == nil {
            field.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: GlassTextField

        init(_ parent: GlassTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            if let field = notification.object as? CaretTextField {
                field.applyCaretStyle()
            }
            parent.onFocusChange?(true)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            if let field = notification.object as? NSTextField {
                parent.text = field.stringValue
            }
            parent.onFocusChange?(false)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                control.window?.makeFirstResponder(nil)
                return true
            }
            return false
        }
    }
}

final class CaretTextField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        applyCaretStyle()
        return ok
    }

    func applyCaretStyle() {
        guard let editor = currentEditor() as? NSTextView else { return }
        // 亮色细竖线在深色玻璃上最醒目；字体 14 让光标更高
        editor.insertionPointColor = NSColor.white
        editor.selectedTextAttributes = [
            .backgroundColor: NSColor.white.withAlphaComponent(0.28),
            .foregroundColor: NSColor.white
        ]
        editor.font = font
    }
}
