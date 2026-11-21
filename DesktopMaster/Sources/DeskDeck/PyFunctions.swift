import Foundation
import AppKit

// MARK: - Python 环境

struct PythonEnvironmentInfo {
    let path: String
    let version: String
}

enum PythonSupport {
    static let candidatePaths: [String] = [
        "/usr/local/bin/python3",
        "/opt/homebrew/bin/python3",
        "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
        "/usr/bin/python3",
        NSHomeDirectory() + "/anaconda3/bin/python3",
        NSHomeDirectory() + "/miniconda3/bin/python3",
        NSHomeDirectory() + "/opt/anaconda3/bin/python3",
        NSHomeDirectory() + "/opt/miniconda3/bin/python3"
    ]

    static func detect(preferred: String? = nil) -> PythonEnvironmentInfo? {
        var paths: [String] = []
        if let preferred, !preferred.isEmpty { paths.append(preferred) }
        paths.append(contentsOf: candidatePaths)
        for path in paths where FileManager.default.isExecutableFile(atPath: path) {
            let version = versionLine(at: path) ?? "Python"
            return PythonEnvironmentInfo(path: path, version: version)
        }
        return nil
    }

    private static func versionLine(at path: String) -> String? {
        let result = RSupport.execute(path: path, arguments: ["-VV"], timeout: 10)
        let text = (result.out + "\n" + result.err)
            .split(separator: "\n")
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let line = text.map({ String($0).trimmingCharacters(in: .whitespaces) }) else { return nil }
        // "Python 3.12.5 (v3.12.5:...)" 只保留前面的短版本
        return line.components(separatedBy: " (").first ?? line
    }

    static func writeTemporaryScript(_ script: String, extension ext: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DeskDeck", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("run-\(UUID().uuidString).\(ext)")
        try script.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func pyString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }

    /// 把界面上的值转成 Python 字面量
    static func pyLiteral(_ value: String, kind: RParamKind) -> String {
        switch kind {
        case .logical:
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return (normalized == "TRUE" || normalized == "T" || normalized == "1") ? "True" : "False"
        case .numeric:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, Double(trimmed) != nil { return trimmed }
            return pyString(trimmed)
        case .text, .choice:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            // 没标注类型的参数按文本填写：看起来是数字就按数字传，避免 "10" 变成字符串
            if let intValue = Int(trimmed) { return String(intValue) }
            if let doubleValue = Double(trimmed), !trimmed.isEmpty,
               trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789.").inverted) == nil {
                _ = doubleValue
                return trimmed
            }
            return pyString(value)
        case .code:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "None" : trimmed
        }
    }
}

// MARK: - 参数反射

enum PythonIntrospector {
    static func inspect(config: RConfig, python: String) -> RIntrospector.Outcome {
        let wd = config.workingDirectory ?? ""
        let files = config.sourceFiles.map { PythonSupport.pyString($0) }.joined(separator: ", ")
        let name = PythonSupport.pyString(config.functionName)

        let script = """
        import os, sys, inspect, importlib, typing

        SEP, TAB, NL, CR = chr(31), chr(9), chr(10), chr(13)

        def esc(v):
            return (str(v).replace("%", "%25").replace(TAB, "%09")
                      .replace(NL, "%0A").replace(CR, "%0D").replace(SEP, "%1F"))

        def emit(nm, kind, dv, opts):
            print("PARAM" + TAB + esc(nm) + TAB + kind + TAB + esc(dv) + TAB
                  + SEP.join(esc(o) for o in opts))

        wd = \(PythonSupport.pyString(wd))
        if wd:
            os.chdir(wd)
        files = [\(files)]
        ns = {"__name__": "__deskdeck__"}
        for f in files:
            if not f:
                continue
            with open(f, "rb") as fh:
                exec(compile(fh.read(), f, "exec"), ns)

        name = \(name)
        fn = ns.get(name)
        if fn is None and "." in name:
            mod, attr = name.rsplit(".", 1)
            try:
                fn = getattr(importlib.import_module(mod), attr)
            except Exception:
                fn = None
        if not callable(fn):
            print("DESKDECK_ERROR" + TAB + "找不到函数：" + name)
            sys.exit(3)

        try:
            sig = inspect.signature(fn)
        except Exception as e:
            print("DESKDECK_ERROR" + TAB + "读不到函数签名：" + str(e))
            sys.exit(4)

        for p in sig.parameters.values():
            if p.kind in (p.VAR_POSITIONAL, p.VAR_KEYWORD):
                continue
            d = p.default
            ann = p.annotation
            ann_name = ann if isinstance(ann, str) else getattr(ann, "__name__", "")
            try:
                lit = list(typing.get_args(ann)) if typing.get_origin(ann) is typing.Literal else []
            except Exception:
                lit = []
            if lit:
                opts = [str(a) for a in lit]
                dv = str(d) if d is not inspect.Parameter.empty and str(d) in opts else opts[0]
                emit(p.name, "choice", dv, opts)
                continue
            if d is inspect.Parameter.empty:
                if ann_name == "bool":
                    emit(p.name, "logical", "TRUE", [])
                elif ann_name in ("int", "float"):
                    emit(p.name, "numeric", "", [])
                else:
                    emit(p.name, "text", "", [])
                continue
            if isinstance(d, bool):
                emit(p.name, "logical", "TRUE" if d else "FALSE", [])
            elif isinstance(d, (int, float)):
                emit(p.name, "numeric", repr(d), [])
            elif isinstance(d, (list, tuple)) and 1 < len(d) <= 9 and all(isinstance(x, str) for x in d):
                emit(p.name, "choice", d[0], list(d))
            elif isinstance(d, str):
                emit(p.name, "text", d, [])
            elif d is None:
                emit(p.name, "code", "None", [])
            else:
                emit(p.name, "code", repr(d), [])

        print("DESKDECK_DONE")
        """

        guard let url = try? PythonSupport.writeTemporaryScript(script, extension: "py") else {
            return RIntrospector.Outcome(params: [], error: "无法写入临时脚本", log: "")
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let result = RSupport.execute(path: python, arguments: ["-u", url.path], timeout: 60)
        let flagged = result.out
            .split(separator: "\n")
            .first { $0.hasPrefix("DESKDECK_ERROR") }
            .map { String($0.replacingOccurrences(of: "DESKDECK_ERROR\t", with: "")) }

        if result.status != 0 {
            let stderr = result.err.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = flagged ?? (stderr.isEmpty ? "读取失败（退出码 \(result.status)）" : stderr)
            return RIntrospector.Outcome(params: [], error: message, log: result.out + result.err)
        }

        var params: [RParamSpec] = []
        for line in result.out.split(separator: "\n") where line.hasPrefix("PARAM\t") {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 5 else { continue }
            let name = RIntrospector.unescape(parts[1])
            let kind = RParamKind(rawValue: parts[2]) ?? .text
            let def = RIntrospector.unescape(parts[3])
            let opts = parts[4].isEmpty ? [] : parts[4].components(separatedBy: "\u{1f}").map(RIntrospector.unescape)
            params.append(RParamSpec(name: name, kind: kind, options: opts, defaultValue: def))
        }
        return RIntrospector.Outcome(
            params: params,
            error: params.isEmpty ? "这个函数没有可填写的参数" : flagged,
            log: result.out
        )
    }
}

// MARK: - 调用

enum PythonRunner {
    static func run(config: RConfig, python: String) -> RRunner.Outcome {
        let start = Date()
        let wd = config.workingDirectory ?? ""
        let files = config.sourceFiles.map { PythonSupport.pyString($0) }.joined(separator: ", ")
        let name = PythonSupport.pyString(config.functionName)

        var argLines: [String] = []
        for spec in config.params {
            let value = config.value(for: spec.name)
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            argLines.append("  \(PythonSupport.pyString(spec.name)): \(PythonSupport.pyLiteral(value, kind: spec.kind))")
        }
        let argsBody = argLines.isEmpty ? "{}" : "{\n" + argLines.joined(separator: ",\n") + "\n}"

        let script = """
        import os, sys, importlib

        wd = \(PythonSupport.pyString(wd))
        if wd:
            os.chdir(wd)
        files = [\(files)]
        ns = {"__name__": "__deskdeck__"}
        for f in files:
            if not f:
                continue
            with open(f, "rb") as fh:
                exec(compile(fh.read(), f, "exec"), ns)

        name = \(name)
        fn = ns.get(name)
        if fn is None and "." in name:
            mod, attr = name.rsplit(".", 1)
            try:
                fn = getattr(importlib.import_module(mod), attr)
            except Exception:
                fn = None
        if not callable(fn):
            print("DESKDECK_ERROR" + chr(9) + "找不到函数：" + name)
            sys.exit(3)

        args = \(argsBody)
        try:
            res = fn(**args)
        except Exception as e:
            import traceback
            traceback.print_exc()
            print("DESKDECK_ERROR" + chr(9) + str(e))
            sys.exit(4)

        print("DESKDECK_OUTPUT_BEGIN")
        if res is None:
            print("（函数返回 None）")
        else:
            print(res)
        print("DESKDECK_OUTPUT_END")
        """

        guard let url = try? PythonSupport.writeTemporaryScript(script, extension: "py") else {
            return RRunner.Outcome(ok: false, output: "", error: "无法写入临时脚本", resultPath: nil, duration: 0)
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let result = RSupport.execute(path: python, arguments: ["-u", url.path], timeout: 300)
        let duration = Date().timeIntervalSince(start)

        if result.status != 0 {
            let flagged = result.out
                .split(separator: "\n")
                .first { $0.hasPrefix("DESKDECK_ERROR") }
                .map { String($0.replacingOccurrences(of: "DESKDECK_ERROR\t", with: "")) }
            let stderr = result.err.trimmingCharacters(in: .whitespacesAndNewlines)
            return RRunner.Outcome(
                ok: false,
                output: result.out + (stderr.isEmpty ? "" : "\n" + stderr),
                error: flagged ?? (stderr.isEmpty ? "运行失败（退出码 \(result.status)）" : stderr),
                resultPath: nil,
                duration: duration
            )
        }

        var output = result.out
        if let begin = output.range(of: "DESKDECK_OUTPUT_BEGIN\n"),
           let end = output.range(of: "\nDESKDECK_OUTPUT_END", range: begin.upperBound..<output.endIndex) {
            output = String(output[begin.upperBound..<end.lowerBound])
        }
        return RRunner.Outcome(
            ok: true,
            output: output.trimmingCharacters(in: .whitespacesAndNewlines),
            error: "",
            resultPath: nil,
            duration: duration
        )
    }
}

// MARK: - 统一入口（R / Python）

enum FunctionEngine {
    static func detect(language: FuncLanguage, preferred: String?) -> REnvironmentInfo? {
        switch language {
        case .r: return RSupport.detect(preferred: preferred)
        case .python:
            guard let info = PythonSupport.detect(preferred: preferred) else { return nil }
            return REnvironmentInfo(path: info.path, version: info.version)
        }
    }

    static func inspect(config: RConfig, executable: String) -> RIntrospector.Outcome {
        switch config.language {
        case .r: return RIntrospector.inspect(config: config, rscript: executable)
        case .python: return PythonIntrospector.inspect(config: config, python: executable)
        }
    }

    static func run(config: RConfig, executable: String) -> RRunner.Outcome {
        switch config.language {
        case .r: return RRunner.run(config: config, rscript: executable)
        case .python: return PythonRunner.run(config: config, python: executable)
        }
    }
}
