import AppKit

// 引擎自检：DeskDeck --selftest config.json（只跑 R 反射与调用，不开界面）
if let index = CommandLine.arguments.firstIndex(of: "--selftest"),
   CommandLine.arguments.count > index + 1 {
    MainActor.assumeIsolated {
        let path = CommandLine.arguments[index + 1]
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let config = try? JSONDecoder().decode(RConfig.self, from: data) else {
            print("SELFTEST_ERROR 无法读取配置 \(path)")
            exit(2)
        }
        guard let env = FunctionEngine.detect(language: config.language, preferred: config.executablePath) else {
            print("SELFTEST_ERROR 未检测到执行环境")
            exit(3)
        }
        print("SELFTEST_ENV \(env.path) | \(env.version)")
        let inspect = FunctionEngine.inspect(config: config, executable: env.path)
        print("SELFTEST_PARAMS \(inspect.params.map { "\($0.name):\($0.kind.rawValue)=\($0.defaultValue)" }.joined(separator: ", "))")
        if let error = inspect.error { print("SELFTEST_INSPECT_ERROR \(error)") }
        let run = FunctionEngine.run(config: config, executable: env.path)
        print("SELFTEST_RUN ok=\(run.ok) duration=\(String(format: "%.2f", run.duration))s")
        if !run.error.isEmpty { print("SELFTEST_RUN_ERROR \(run.error)") }
        if !run.output.isEmpty { print("SELFTEST_RUN_OUTPUT\n\(run.output)") }
        exit(run.ok ? 0 : 1)
    }
}

// 调试用：DeskDeck --menucheck（打印主菜单里的快捷键，确认编辑菜单存在）
if CommandLine.arguments.contains("--menucheck") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        AppMenus.install()
        func dump(_ menu: NSMenu, _ prefix: String) {
            for item in menu.items {
                let key = item.keyEquivalent.isEmpty ? "" : " ⌘" + item.keyEquivalent.uppercased()
                if let sub = item.submenu {
                    print("\(prefix)[\(item.title)]")
                    dump(sub, prefix + "  ")
                } else if !item.title.isEmpty {
                    print("\(prefix)\(item.title)\(key)  action=\(item.action.map(NSStringFromSelector) ?? "-")")
                }
            }
        }
        if let main = NSApp.mainMenu { dump(main, "") } else { print("NO MAIN MENU") }
        exit(0)
    }
}

MainActor.assumeIsolated {
    // 只允许一个实例：重复启动会叠出两层桌面窗口，拖动和拖放都会互相挡住
    let bundleID = Bundle.main.bundleIdentifier ?? "com.ac.desktopmaster"
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    if let other = others.first {
        other.activate()
        exit(0)
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
