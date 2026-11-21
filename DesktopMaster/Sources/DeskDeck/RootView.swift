import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - 每块屏幕的根视图

struct DesktopRootView: View {
    @Bindable var state: AppState
    let screen: ScreenSnapshot

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear

            ForEach($state.partitions) { $partition in
                if state.showAll, partition.screenID == screen.displayID {
                    PartitionCardView(partition: $partition, state: state, screen: screen)
                }
            }
        }
        .frame(width: screen.frameSize.width, height: screen.frameSize.height, alignment: .topLeading)
        .ignoresSafeArea()
    }
}

// MARK: - 拖放解析

enum DropLoader {
    static func urls(from providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        guard !providers.isEmpty else { return }
        let group = DispatchGroup()
        let lock = NSLock()
        var found: [URL] = []

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                switch item {
                case let data as Data:
                    url = URL(dataRepresentation: data, relativeTo: nil)
                case let string as String:
                    url = URL(string: string)
                case let nsURL as NSURL:
                    url = nsURL as URL
                case let u as URL:
                    url = u
                default:
                    break
                }
                if let url {
                    lock.lock()
                    found.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            let unique = Array(Set(found)).sorted { $0.path < $1.path }
            MainActor.assumeIsolated {
                completion(unique)
            }
        }
    }
}
