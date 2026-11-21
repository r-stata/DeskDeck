import SwiftUI
import AppKit

// MARK: - 运行结果

struct FunctionRunResult: Identifiable {
    let id = UUID()
    var ok: Bool
    var text: String
    var error: String
    var duration: Double
    var resultPath: String?
    var workingDirectory: String?
}

// MARK: - 函数分区面板

struct FunctionPanelView: View {
    @Binding var partition: Partition
    let state: AppState
    let onOpenSettings: () -> Void

    @State private var isRunning = false
    @State private var hint: String?
    @State private var focusedParam: String?
    @State private var lastResult: FunctionRunResult?

    private var config: RConfig { partition.rConfig ?? RConfig() }
    private var runnable: Bool {
        !config.functionName.trimmingCharacters(in: .whitespaces).isEmpty && !config.params.isEmpty && !isRunning
    }

    var body: some View {
        VStack(spacing: 0) {
            if config.functionName.isEmpty || config.params.filter(\.visible).isEmpty {
                emptyHint
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 10) {
                        ForEach(config.params.filter(\.visible)) { spec in
                            paramRow(spec)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                footer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyHint: some View {
        VStack(spacing: 9) {
            Image(systemName: "function")
                .font(.system(size: 20, weight: .light))
            Text(config.functionName.isEmpty ? "选一个 R 函数开始" : "还没读取参数")
                .font(.system(size: 12.5, weight: .medium))
            Text("在「函数设置」里选好 R 环境、source 文件和函数名，再读取参数")
                .font(.system(size: 11.5))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.45))
                .padding(.horizontal, 14)
            Button("函数设置…") { onOpenSettings() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(.white.opacity(0.16)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
        }
        .foregroundStyle(.white.opacity(0.75))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
    }

    @ViewBuilder
    private func paramRow(_ spec: RParamSpec) -> some View {
        HStack(spacing: 10) {
            Text(spec.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
                .frame(width: 112, alignment: .leading)
                .help("\(spec.name)：\(spec.kind.label)\(spec.defaultValue.isEmpty ? "" : "，默认 \(spec.defaultValue)")")

            switch spec.kind {
            case .logical:
                Toggle("", isOn: Binding(
                    get: { config.value(for: spec.name).uppercased() == "TRUE" },
                    set: { state.setParamValue($0 ? "TRUE" : "FALSE", name: spec.name, for: partition.id) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                Text(config.value(for: spec.name).uppercased() == "TRUE" ? "TRUE" : "FALSE")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))

            case .choice:
                Picker("", selection: Binding(
                    get: { config.value(for: spec.name) },
                    set: { state.setParamValue($0, name: spec.name, for: partition.id) }
                )) {
                    ForEach(spec.options, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.regular)
                .frame(maxWidth: 220)

            case .text, .numeric, .code:
                GlassTextField(
                    text: Binding(
                        get: { config.value(for: spec.name) },
                        set: { state.setParamValue($0, name: spec.name, for: partition.id) }
                    ),
                    placeholder: spec.kind == .numeric ? "数字" : (spec.kind == .code ? "R 表达式" : "文本"),
                    fontSize: 14,
                    onFocusChange: { focused in
                        if focused {
                            focusedParam = spec.name
                        } else if focusedParam == spec.name {
                            focusedParam = nil
                        }
                    }
                )
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.white.opacity(focusedParam == spec.name ? 0.22 : 0.13)))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(focusedParam == spec.name
                                      ? Color(red: 0.42, green: 0.85, blue: 1.0).opacity(0.85)
                                      : .white.opacity(0.22),
                                      lineWidth: focusedParam == spec.name ? 1.6 : 1)
                )
            }

            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        VStack(spacing: 5) {
            if let hint {
                Text(hint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange.opacity(0.95))
                    .lineLimit(1)
            }
            HStack(spacing: 8) {
                Button {
                    submit()
                } label: {
                    HStack(spacing: 5) {
                        if isRunning {
                            ProgressView().controlSize(.small).scaleEffect(0.6)
                        }
                        Text(isRunning ? "运行中…" : "提交")
                            .font(.system(size: 13.5, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(.white.opacity(runnable ? 0.2 : 0.08))
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(runnable ? 0.95 : 0.4))
                .disabled(!runnable)

                if let lastResult {
                    Button {
                        FunctionWindows.showResult(lastResult)
                    } label: {
                        Image(systemName: lastResult.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(lastResult.ok
                                             ? Color(red: 0.42, green: 0.95, blue: 0.55)
                                             : Color(red: 1.0, green: 0.45, blue: 0.42))
                            .padding(.vertical, 3)
                            .padding(.horizontal, 2)
                    }
                    .buttonStyle(.plain)
                    .help(lastResult.ok ? "运行成功，点这里看运行日志" : "运行失败，点这里看报错日志")
                }

                Button {
                    onOpenSettings()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help("函数设置")
            }
            Text(config.functionName)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .padding(.top, 4)
    }

    private func submit() {
        guard !isRunning else { return }
        guard let env = FunctionEngine.detect(language: config.language, preferred: config.executablePath) else {
            hint = config.language == .r ? "没找到 Rscript，请在函数设置里检测" : "没找到 python3，请在函数设置里指定"
            return
        }
        hint = nil
        isRunning = true
        let snapshot = config
        let envPath = env.path

        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = FunctionEngine.run(config: snapshot, executable: envPath)
            DispatchQueue.main.async {
                isRunning = false
                lastResult = FunctionRunResult(
                    ok: outcome.ok,
                    text: outcome.ok ? (outcome.output.isEmpty ? "（没有输出）" : outcome.output) : outcome.output,
                    error: outcome.ok ? "" : outcome.error,
                    duration: outcome.duration,
                    resultPath: outcome.ok ? outcome.resultPath : nil,
                    workingDirectory: snapshot.workingDirectory
                )
            }
        }
    }
}

// MARK: - 结果窗口

struct FunctionResultView: View {
    let result: FunctionRunResult
    @Environment(\.functionWindowClose) private var close

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(result.ok ? .green : .orange)
                Text(result.ok ? "运行完成" : "运行失败")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(String(format: "%.2f 秒", result.duration))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !result.error.isEmpty {
                        Text(result.error)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    if !result.text.isEmpty {
                        Text(result.text)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }

            Divider()

            HStack(spacing: 10) {
                if let path = result.resultPath {
                    Button("显示结果对象") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                }
                if let wd = result.workingDirectory, !wd.isEmpty {
                    Button("打开工作目录") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: wd))
                    }
                }
                Spacer()
                Button("复制输出") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.error.isEmpty ? result.text : result.text + "\n" + result.error, forType: .string)
                }
                Button("关闭") { close() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 440)
    }
}

// MARK: - 函数设置

struct FunctionSettingsView: View {
    @Binding var partition: Partition
    let state: AppState
    @Environment(\.functionWindowClose) private var close

    @State private var draft: RConfig = RConfig()
    @State private var env: REnvironmentInfo?
    @State private var inspectMessage: String?
    @State private var isInspecting = false
    @State private var draftName = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(draftName.isEmpty ? partition.name : draftName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("改完点右下角「保存」生效")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section("卡片名称") {
                        TextField("卡片上显示的标题", text: $draftName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12.5, weight: .semibold))
                            .frame(maxWidth: 320)
                    }

                    section("函数语言") {
                        Picker("", selection: Binding(
                            get: { draft.language },
                            set: { newValue in
                                guard newValue != draft.language else { return }
                                draft.language = newValue
                                draft.params = []
                                inspectMessage = nil
                                detect()
                            }
                        )) {
                            Text("R").tag(FuncLanguage.r)
                            Text("Python").tag(FuncLanguage.python)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 240)
                    }

                    section(draft.language == .r ? "R 语言环境" : "Python 环境") {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(env == nil ? Color.orange : Color.green)
                                .frame(width: 7, height: 7)
                            if let env {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(env.version)
                                        .font(.system(size: 11, weight: .medium))
                                    Text(env.path)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            } else {
                                Text(draft.language == .r
                                     ? "未检测到 Rscript，请安装 R 或手动指定路径"
                                     : "未检测到 python3，请安装 Python 或手动指定路径")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                            Button("重新检测") { detect() }
                            Button("指定…") { chooseRscript() }
                        }
                    }

                    section(draft.language == .r ? "函数" : "函数（Python）") {
                        HStack(spacing: 8) {
                            TextField(draft.language == .r ? "例如 my_analysis" : "例如 compute_score", text: $draft.functionName)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                            Button(isInspecting ? "读取中…" : "读取参数") { inspect() }
                                .disabled(isInspecting || draft.functionName.isEmpty)
                        }
                        if let inspectMessage {
                            Text(inspectMessage)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                    }

                    section(draft.language == .r ? "预先 source 的文件" : "预先加载的脚本") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(draft.sourceFiles, id: \.self) { path in
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.text")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                    Text(path)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .help(path)
                                    Spacer()
                                    Button {
                                        draft.sourceFiles.removeAll { $0 == path }
                                    } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                }
                            }
                            Button(draft.language == .r ? "添加 R 脚本…" : "添加 .py 脚本…") { addSourceFiles() }
                                .font(.system(size: 11))
                        }
                    }

                    section("默认工作目录（不在卡片上显示）") {
                        HStack(spacing: 8) {
                            TextField("~/Documents 或绝对路径", text: Binding(
                                get: { draft.workingDirectory ?? "" },
                                set: { draft.workingDirectory = $0.isEmpty ? nil : $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                            Button("选择…") { chooseWorkingDirectory() }
                            if draft.workingDirectory != nil {
                                Button("清除") { draft.workingDirectory = nil }
                            }
                        }
                    }

                    if !draft.params.isEmpty {
                        section("参数（可增删；眼睛关掉的参数不显示在卡片上）") {
                            VStack(alignment: .leading, spacing: 9) {
                                ForEach($draft.params) { $spec in
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack(spacing: 8) {
                                            Button {
                                                spec.visible.toggle()
                                            } label: {
                                                Image(systemName: spec.visible ? "eye" : "eye.slash")
                                                    .font(.system(size: 12))
                                                    .foregroundStyle(spec.visible ? Color.primary : Color.secondary)
                                                    .frame(width: 22)
                                            }
                                            .buttonStyle(.plain)
                                            .help(spec.visible ? "点一下隐藏这个参数" : "点一下显示在卡片上")

                                            TextField("参数名", text: $spec.name)
                                                .textFieldStyle(.roundedBorder)
                                                .font(.system(size: 12, design: .monospaced))
                                                .frame(width: 132)

                                            Picker("", selection: $spec.kind) {
                                                ForEach(RParamKind.allCases, id: \.self) { kind in
                                                    Text(kind.label).tag(kind)
                                                }
                                            }
                                            .labelsHidden()
                                            .pickerStyle(.menu)
                                            .frame(width: 96)

                                            TextField("默认值（可空）", text: $spec.defaultValue)
                                                .textFieldStyle(.roundedBorder)
                                                .font(.system(size: 12))

                                            Button {
                                                // 先取出值再删：删完还读 spec.name 会访问到已失效的绑定，直接崩
                                                let key = spec.name
                                                let targetID = spec.id
                                                draft.values.removeValue(forKey: key)
                                                draft.params.removeAll { $0.id == targetID }
                                            } label: {
                                                Image(systemName: "minus.circle")
                                                    .foregroundStyle(.secondary)
                                            }
                                            .buttonStyle(.plain)
                                            .help("删除这个参数")
                                        }
                                        if spec.kind == .choice {
                                            TextField("可选项，用逗号分隔", text: Binding(
                                                get: { spec.options.joined(separator: ", ") },
                                                set: { text in
                                                    spec.options = text
                                                        .split(separator: ",")
                                                        .map { $0.trimmingCharacters(in: .whitespaces) }
                                                        .filter { !$0.isEmpty }
                                                    if !spec.options.isEmpty, !spec.options.contains(spec.defaultValue) {
                                                        spec.defaultValue = spec.options[0]
                                                    }
                                                }
                                            ))
                                            .textFieldStyle(.roundedBorder)
                                            .font(.system(size: 11.5))
                                            .padding(.leading, 30)
                                        }
                                    }
                                }

                                HStack(spacing: 8) {
                                    Button("添加参数") {
                                        let base = "param"
                                        var index = draft.params.count + 1
                                        while draft.params.contains(where: { $0.name == base + String(index) }) { index += 1 }
                                        draft.params.append(RParamSpec(name: base + String(index), kind: .text))
                                    }
                                    .font(.system(size: 11.5))
                                    Spacer()
                                    Text("\(draft.params.filter(\.visible).count) 个显示在卡片上 / 共 \(draft.params.count) 个")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }

            Divider()

            HStack {
                Button("取消") { close() }
                Spacer()
                Button("保存") {
                    let trimmedName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedName.isEmpty { partition.name = trimmedName }
                    state.updateRConfig(draft, for: partition.id)
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 520)
        .onAppear {
            draftName = partition.name
            draft = partition.rConfig ?? RConfig()
            detect()
            if env != nil && draft.params.isEmpty && !draft.functionName.isEmpty {
                inspect()
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func detect() {
        env = FunctionEngine.detect(language: draft.language, preferred: draft.executablePath)
    }

    private func chooseRscript() {
        let panel = NSOpenPanel()
        panel.title = draft.language == .r ? "选择 Rscript" : "选择 python3"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            draft.executablePath = url.path
            detect()
        }
    }

    private func addSourceFiles() {
        let panel = NSOpenPanel()
        panel.title = draft.language == .r ? "选择要预先 source 的 R 文件" : "选择要预先加载的 Python 脚本"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.sourceCode, .plainText, .text]
        if panel.runModal() == .OK {
            for url in panel.urls where !draft.sourceFiles.contains(url.path) {
                draft.sourceFiles.append(url.path)
            }
        }
    }

    private func chooseWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择默认工作目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            draft.workingDirectory = url.path
        }
    }

    private func inspect() {
        guard let env else {
            inspectMessage = draft.language == .r ? "先检测 R 环境" : "先检测 Python 环境"
            return
        }
        isInspecting = true
        inspectMessage = nil
        let snapshot = draft
        let path = env.path

        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = FunctionEngine.inspect(config: snapshot, executable: path)
            DispatchQueue.main.async {
                isInspecting = false
                if let error = outcome.error {
                    inspectMessage = error
                } else {
                    var newParams = outcome.params
                    let old = Dictionary(uniqueKeysWithValues: draft.params.map { ($0.name, $0) })
                    for i in newParams.indices {
                        guard let previous = old[newParams[i].name] else { continue }
                        newParams[i].visible = previous.visible
                        if newParams[i].defaultValue.isEmpty {
                            newParams[i].defaultValue = previous.defaultValue
                        }
                    }
                    draft.params = newParams
                    // 已经填过的值优先，其余用函数默认值
                    var values = draft.values
                    for spec in newParams where values[spec.name] == nil {
                        values[spec.name] = spec.defaultValue
                    }
                    draft.values = values
                    inspectMessage = "已读取 \(newParams.count) 个参数"
                }
            }
        }
    }
}
