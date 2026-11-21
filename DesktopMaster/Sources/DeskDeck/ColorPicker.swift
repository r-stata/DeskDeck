import SwiftUI
import AppKit

/// 卡片配色面板：每个颜色都给一个「按卡片实际质感渲染」的预览块，点一下即时生效
@MainActor
enum ColorPickerWindow {
    private static var window: NSWindow?

    static func show(partitionID: UUID, state: AppState) {
        guard let index = state.partitions.firstIndex(where: { $0.id == partitionID }) else { return }
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let binding = Binding<Partition>(
            get: { state.partitions[index] },
            set: { state.partitions[index] = $0 }
        )
        var created: NSWindow!
        let close: () -> Void = { created?.close() }
        created = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        created.title = "卡片颜色"
        created.isReleasedWhenClosed = false
        created.level = .floating
        created.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        created.contentView = NSHostingView(rootView: ColorPickerView(partition: binding, state: state, close: close))
        created.center()
        created.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = created
    }
}

struct ColorPickerView: View {
    @Binding var partition: Partition
    let state: AppState
    let close: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 128), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("给「\(partition.name)」选一个颜色")
                .font(.system(size: 13, weight: .semibold))
            Text("预览块按卡片实际的液态玻璃质感渲染，点一下立即生效。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(AppState.palette, id: \.self) { hex in
                        swatch(hex)
                    }
                }
                .padding(2)
            }

            HStack {
                Spacer()
                Button("完成") { close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 460, height: 420)
    }

    private func swatch(_ hex: String) -> some View {
        let isCurrent = partition.tintHex.uppercased() == hex.uppercased()
        return Button {
            state.setTint(hex, for: partition.id)
        } label: {
            VStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(hex: hex).opacity(0.92),
                                Color(hex: hex).opacity(0.42),
                                Color(hex: hex).opacity(0.16)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(height: 54)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.white.opacity(0.28), lineWidth: 1)
                    )
                    .overlay(alignment: .topTrailing) {
                        if isCurrent {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                                .padding(5)
                        }
                    }
                    .shadow(color: Color(hex: hex).opacity(0.35), radius: 6, y: 2)

                Text(TintSwatch.name(for: hex))
                    .font(.system(size: 11.5, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? .primary : .secondary)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(isCurrent ? 0.07 : 0.0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
