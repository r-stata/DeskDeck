import Foundation
import AppKit

// MARK: - 参数与配置模型

enum RParamKind: String, Codable, Hashable, CaseIterable {
    case text
    case numeric
    case logical
    case choice
    /// 直接当 R 表达式求值（用于 NULL、对象、复杂默认值）
    case code

    var label: String {
        switch self {
        case .text: return "文本"
        case .numeric: return "数值"
        case .logical: return "开关"
        case .choice: return "选项"
        case .code: return "表达式"
        }
    }
}

struct RParamSpec: Codable, Hashable, Identifiable {
    var name: String
    var kind: RParamKind
    var options: [String]
    var defaultValue: String
    /// 是否显示在卡片上；隐藏的参数照旧参与调用（用设置里的值或函数默认值）
    var visible: Bool
    /// 稳定标识：改名不会让 SwiftUI 把它当成另一行（也不会因同名参数导致 id 冲突）
    var pid: UUID

    var id: UUID { pid }

    init(name: String, kind: RParamKind, options: [String] = [], defaultValue: String = "", visible: Bool = true) {
        self.name = name
        self.kind = kind
        self.options = options
        self.defaultValue = defaultValue
        self.visible = visible
        self.pid = UUID()
    }

    enum CodingKeys: String, CodingKey { case name, kind, options, defaultValue, visible, pid }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try c.decodeIfPresent(RParamKind.self, forKey: .kind) ?? .text
        options = try c.decodeIfPresent([String].self, forKey: .options) ?? []
        defaultValue = try c.decodeIfPresent(String.self, forKey: .defaultValue) ?? ""
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        pid = (try? c.decodeIfPresent(UUID.self, forKey: .pid)) .flatMap { $0 } ?? UUID()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encode(options, forKey: .options)
        try c.encode(defaultValue, forKey: .defaultValue)
        try c.encode(visible, forKey: .visible)
        try c.encode(pid, forKey: .pid)
    }
}

/// 函数分区使用的语言
enum FuncLanguage: String, Codable, Hashable {
    case r
    case python

    var label: String { self == .r ? "R" : "Python" }
    var partitionName: String { self == .r ? "R 函数" : "Python 函数" }
}

struct RConfig: Codable, Hashable {
    var language: FuncLanguage = .r
    var functionName: String = ""
    /// 调用函数前预先 source / exec 的文件
    var sourceFiles: [String] = []
    /// 运行时的默认工作目录
    var workingDirectory: String?
    /// 自定义 Rscript 路径，留空则用自动检测
    var rscriptPath: String?
    /// 自定义 python3 路径，留空则用自动检测
    var pythonPath: String?
    /// 由反射得到的参数表
    var params: [RParamSpec] = []
    /// 用户填写的参数值
    var values: [String: String] = [:]

    init() {}

    enum CodingKeys: String, CodingKey {
        case language, functionName, sourceFiles, workingDirectory
        case rscriptPath, pythonPath, params, values
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        language = try c.decodeIfPresent(FuncLanguage.self, forKey: .language) ?? .r
        functionName = try c.decodeIfPresent(String.self, forKey: .functionName) ?? ""
        sourceFiles = try c.decodeIfPresent([String].self, forKey: .sourceFiles) ?? []
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
        rscriptPath = try c.decodeIfPresent(String.self, forKey: .rscriptPath)
        pythonPath = try c.decodeIfPresent(String.self, forKey: .pythonPath)
        params = try c.decodeIfPresent([RParamSpec].self, forKey: .params) ?? []
        values = try c.decodeIfPresent([String: String].self, forKey: .values) ?? [:]
    }

    /// 当前语言对应的可执行文件路径
    var executablePath: String? {
        get { language == .r ? rscriptPath : pythonPath }
        set {
            if language == .r { rscriptPath = newValue } else { pythonPath = newValue }
        }
    }

    func value(for name: String) -> String {
        if let v = values[name] { return v }
        if let spec = params.first(where: { $0.name == name }) { return spec.defaultValue }
        return ""
    }
}

// MARK: - R 环境

struct REnvironmentInfo {
    let path: String
    let version: String
}

enum RSupport {
    static let candidatePaths: [String] = [
        "/usr/local/bin/Rscript",
        "/opt/homebrew/bin/Rscript",
        "/Library/Frameworks/R.framework/Resources/bin/Rscript",
        "/usr/bin/Rscript"
    ]

    static func detect(preferred: String? = nil) -> REnvironmentInfo? {
        var paths: [String] = []
        if let preferred, !preferred.isEmpty { paths.append(preferred) }
        paths.append(contentsOf: candidatePaths)
        for path in paths where FileManager.default.isExecutableFile(atPath: path) {
            let version = versionLine(at: path) ?? "R"
            return REnvironmentInfo(path: path, version: version)
        }
        return nil
    }

    private static func versionLine(at path: String) -> String? {
        let result = execute(path: path, arguments: ["--version"], timeout: 10)
        let text = (result.out + "\n" + result.err)
            .split(separator: "\n")
            .first(where: { $0.lowercased().contains("version") })
        return text.map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    struct Result {
        var status: Int32
        var out: String
        var err: String
    }

    /// 同步执行 Rscript（在后台队列调用，不要阻塞主线程）
    static func execute(path: String, arguments: [String], timeout: TimeInterval = 120) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["R_ENABLE_JIT"] = "3"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        // App 从 Finder 启动时 PATH 只有 /usr/bin 等，Homebrew / TeX 都在 PATH 外，
        // 会导致 rmarkdown 找不到 pandoc、xelatex 等
        let extraPaths = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin",
            "/usr/local/bin", "/usr/local/sbin",
            "/Library/TeX/texbin", "/usr/texbin",
            "/Library/Frameworks/R.framework/Resources/bin",
            NSHomeDirectory() + "/.local/bin",
            NSHomeDirectory() + "/bin"
        ]
        let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")
        if env["RSTUDIO_PANDOC"] == nil || env["RSTUDIO_PANDOC"]!.isEmpty {
            for candidate in ["/opt/homebrew/bin/pandoc", "/usr/local/bin/pandoc"] where FileManager.default.isExecutableFile(atPath: candidate) {
                env["RSTUDIO_PANDOC"] = (candidate as NSString).deletingLastPathComponent
                break
            }
        }
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        var outData = Data()
        var errData = Data()
        let lock = NSLock()

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let d = handle.availableData
            if d.isEmpty { handle.readabilityHandler = nil; return }
            lock.lock(); outData.append(d); lock.unlock()
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let d = handle.availableData
            if d.isEmpty { handle.readabilityHandler = nil; return }
            lock.lock(); errData.append(d); lock.unlock()
        }

        do {
            try process.run()
        } catch {
            return Result(status: -1, out: "", err: "无法启动 Rscript：\(error.localizedDescription)")
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return Result(status: -2, out: "", err: "运行超时（超过 \(Int(timeout)) 秒），已终止")
        }
        process.waitUntilExit()
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        lock.lock()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""
        lock.unlock()
        return Result(status: process.terminationStatus, out: out, err: err)
    }

    static func writeTemporaryScript(_ script: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeskDeck", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("run-\(UUID().uuidString).R")
        try script.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// R 字符串转义
    static func rString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }

    static func rLiteral(_ value: String, kind: RParamKind) -> String {
        switch kind {
        case .logical:
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return (normalized == "TRUE" || normalized == "T" || normalized == "1") ? "TRUE" : "FALSE"
        case .numeric:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let _ = Double(trimmed), !trimmed.isEmpty { return trimmed }
            return rString(trimmed)
        case .text, .choice:
            return rString(value)
        case .code:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "NULL" : trimmed
        }
    }
}

// MARK: - 参数反射

enum RIntrospector {
    struct Outcome {
        var params: [RParamSpec]
        var error: String?
        var log: String
    }

    static func inspect(config: RConfig, rscript: String) -> Outcome {
        let wd = config.workingDirectory ?? ""
        let sources = config.sourceFiles.map { RSupport.rString($0) }.joined(separator: ", ")
        let fn = RSupport.rString(config.functionName)

        // 注意：formals() 里「没有默认值」的参数是被占位符号表示的，
        // 一旦绑定到变量再求值就会报 argument "x" is missing，所以只能用 identical(x, quote(expr=))
        // 判断是否缺失，缺省时才读取其值。
        let script = """
        options(warn = 1)
        local({
          wd <- \(RSupport.rString(wd))
          if (nzchar(wd)) setwd(wd)
          for (f in c(\(sources))) {
            if (nzchar(f)) source(f, encoding = "UTF-8")
          }
          fn <- \(fn)
          obj <- tryCatch(get(fn, mode = "function"), error = function(e) NULL)
          if (is.null(obj)) {
            cat("DESKDECK_ERROR\t找不到函数：", fn, "\n", sep = "")
            quit(save = "no", status = 3)
          }
          fs <- formals(obj)
          esc <- function(x) {
            x <- gsub("%", "%25", x, fixed = TRUE)
            x <- gsub("\t", "%09", x, fixed = TRUE)
            x <- gsub("\n", "%0A", x, fixed = TRUE)
            x <- gsub("\r", "%0D", x, fixed = TRUE)
            x <- gsub("\\u001f", "%1F", x, fixed = TRUE)
            x
          }
          emit <- function(nm, kind, def, opts) {
            cat("PARAM\t", esc(nm), "\t", kind, "\t", esc(def), "\t",
                paste(esc(opts), collapse = "\\u001f"), "\n", sep = "")
          }
          for (nm in names(fs)) {
            if (nm == "...") next
            if (identical(fs[[nm]], quote(expr = ))) {
              emit(nm, "text", "", character(0))
              next
            }
            failed <- FALSE
            v <- tryCatch(fs[[nm]], error = function(e) { failed <<- TRUE; NULL })
            code <- tryCatch(paste(deparse(fs[[nm]]), collapse = " "), error = function(e) "")
            if (is.logical(v) && length(v) == 1 && !is.na(v)) {
              emit(nm, "logical", if (isTRUE(v)) "TRUE" else "FALSE", character(0))
            } else if (is.numeric(v) && length(v) == 1) {
              emit(nm, "numeric", format(v, scientific = FALSE, trim = TRUE), character(0))
            } else if (is.character(v) && length(v) == 1) {
              emit(nm, "text", v, character(0))
            } else if (is.character(v) && length(v) > 1 && length(v) <= 9) {
              emit(nm, "choice", v[1], v)
            } else if (is.call(v) && identical(v[[1]], as.name("c")) && length(v) >= 3 && length(v) <= 10 &&
                       all(vapply(as.list(v)[-1], is.character, logical(1)))) {
              opts <- unlist(as.list(v)[-1], use.names = FALSE)
              emit(nm, "choice", opts[1], opts)
            } else if (is.null(v) && !failed) {
              emit(nm, "code", "NULL", character(0))
            } else {
              emit(nm, "code", if (nzchar(code)) code else "", character(0))
            }
          }
          cat("DESKDECK_DONE\n")
        })
        """

        guard let url = try? RSupport.writeTemporaryScript(script) else {
            return Outcome(params: [], error: "无法写入临时脚本", log: "")
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let result = RSupport.execute(path: rscript, arguments: ["--vanilla", url.path], timeout: 60)
        let errorFlagged = result.out
            .split(separator: "\n")
            .first(where: { $0.hasPrefix("DESKDECK_ERROR") })
            .map { String($0.replacingOccurrences(of: "DESKDECK_ERROR\t", with: "")) }

        if result.status != 0 {
            let message = result.err.trimmingCharacters(in: .whitespacesAndNewlines)
            return Outcome(params: [], error: errorFlagged ?? (message.isEmpty ? "读取失败（退出码 \(result.status)）" : message), log: result.out + result.err)
        }

        var params: [RParamSpec] = []
        for line in result.out.split(separator: "\n") where line.hasPrefix("PARAM\t") {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 5 else { continue }
            let name = unescape(parts[1])
            let kind = RParamKind(rawValue: parts[2]) ?? .text
            let def = unescape(parts[3])
            let opts = parts[4].isEmpty ? [] : parts[4].components(separatedBy: "\u{1f}").map(unescape)
            params.append(RParamSpec(name: name, kind: kind, options: opts, defaultValue: def))
        }
        return Outcome(params: params, error: params.isEmpty ? "这个函数没有可填写的参数" : errorFlagged, log: result.out)
    }

    static func unescape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "%1F", with: "\u{1f}")
            .replacingOccurrences(of: "%0D", with: "\r")
            .replacingOccurrences(of: "%0A", with: "\n")
            .replacingOccurrences(of: "%09", with: "\t")
            .replacingOccurrences(of: "%25", with: "%")
    }
}

// MARK: - 调用

enum RRunner {
    struct Outcome {
        var ok: Bool
        var output: String
        var error: String
        var resultPath: String?
        var duration: TimeInterval
    }

    static func run(config: RConfig, rscript: String) -> Outcome {
        let start = Date()
        let wd = config.workingDirectory ?? ""
        let sources = config.sourceFiles.map { RSupport.rString($0) }.joined(separator: ", ")
        let fn = RSupport.rString(config.functionName)

        var argLines: [String] = []
        for spec in config.params {
            let value = config.value(for: spec.name)
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            // 空值一律不传：交给函数自己的默认值（默认值可能是依赖其他参数的表达式）
            if trimmed.isEmpty { continue }
            argLines.append("  \(rStringName(spec.name)) = \(RSupport.rLiteral(value, kind: spec.kind))")
        }
        let argsBody = argLines.isEmpty ? "" : "\n" + argLines.joined(separator: ",\n") + "\n"

        let resultDir = FileManager.default.temporaryDirectory.appendingPathComponent("DeskDeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)
        let resultPath = resultDir.appendingPathComponent("last-result.rds").path

        let script = """
        options(warn = 1)
        local({
          wd <- \(RSupport.rString(wd))
          if (nzchar(wd)) setwd(wd)
          for (f in c(\(sources))) {
            if (nzchar(f)) source(f, encoding = "UTF-8")
          }
          fn <- \(fn)
          if (!exists(fn, mode = "function")) {
            cat("DESKDECK_ERROR\\t", "找不到函数：", fn, "\\n", sep = "")
            quit(save = "no", status = 3)
          }
          res <- tryCatch(
            do.call(fn, list(\(argsBody))),
            error = function(e) {
              cat("DESKDECK_ERROR\\t", conditionMessage(e), "\\n", sep = "")
              quit(save = "no", status = 4)
            }
          )
          saveRDS(res, file = \(RSupport.rString(resultPath)))
          cat("DESKDECK_OUTPUT_BEGIN\\n")
          if (is.null(res)) {
            cat("（函数返回 NULL）\\n")
          } else {
            print(res)
          }
          cat("\\nDESKDECK_OUTPUT_END\\n")
        })
        """

        guard let url = try? RSupport.writeTemporaryScript(script) else {
            return Outcome(ok: false, output: "", error: "无法写入临时脚本", resultPath: nil, duration: 0)
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let result = RSupport.execute(path: rscript, arguments: ["--vanilla", url.path], timeout: 300)
        let duration = Date().timeIntervalSince(start)

        if result.status != 0 {
            let flagged = result.out
                .split(separator: "\n")
                .first(where: { $0.hasPrefix("DESKDECK_ERROR") })
                .map { String($0.replacingOccurrences(of: "DESKDECK_ERROR\t", with: "")) }
            let stderr = result.err.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = flagged ?? stderr
            return Outcome(ok: false, output: result.out, error: text.isEmpty ? "运行失败（退出码 \(result.status)）" : text, resultPath: nil, duration: duration)
        }

        var output = result.out
        if let begin = output.range(of: "DESKDECK_OUTPUT_BEGIN\n"),
           let end = output.range(of: "\nDESKDECK_OUTPUT_END", range: begin.upperBound..<output.endIndex) {
            output = String(output[begin.upperBound..<end.lowerBound])
        }
        output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return Outcome(ok: true, output: output, error: "", resultPath: resultPath, duration: duration)
    }

    private static func rStringName(_ name: String) -> String {
        if name.rangeOfCharacter(from: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._")).inverted) == nil {
            return name
        }
        return "`\(name)`"
    }
}
