//
//  CrashRecorder.swift
//  CrashKit
//
//  崩溃留痕：进程被系统杀掉之前，尽量把"发生了什么"写到磁盘；下次启动读出来。
//
//  先说清能力边界：
//  - 绝大多数崩溃（`SIGABRT` 这类，例如隐私违规被系统直接 abort）**拦不住也恢复不了**，
//    进程已经被终止。这里做的是「记录 + 下次启动提示」，不是"拦截不闪退"。
//  - 信号处理器里只能用 async-signal-safe 调用：只做 `write` 到一个**启动时就打开**的 fd，
//    不分配内存、不打印、不建 FileManager。复杂逻辑会引入二次崩溃。
//  - 信号路径拿不到调用栈，只有编号和时间；要符号化堆栈得靠 MetricKit 或 PLCrashReporter。
//  - watchOS 禁止给致命信号挂处理器，只有 NSException 路径可用；install 在手表上自动跳过信号捕获。
//

import Foundation
#if canImport(Darwin)
import Darwin
#endif

public final class CrashRecorder {
    // MARK: - 配置

    public struct Options {
        /// 记录存放目录。默认 `Application Support/CrashKit`
        public var directory: URL?
        /// 要捕获的信号。默认 6 个常见致命信号。
        /// - Note: watchOS 上**始终忽略**（系统禁止给致命信号挂处理器），传了也不会生效
        public var signals: [Int32]
        /// 异常调用栈最多保留几行
        public var maxStackLines: Int
        /// 库自己的日志出口（默认丢弃）。宿主可接自己的日志系统，注意别在这里打印敏感信息
        public var log: (@Sendable (String) -> Void)?

        public init(directory: URL? = nil,
                    signals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP],
                    maxStackLines: Int = 6,
                    log: (@Sendable (String) -> Void)? = nil)
        {
            self.directory = directory
            self.signals = signals
            self.maxStackLines = maxStackLines
            self.log = log
        }
    }

    public static let shared = CrashRecorder()

    // MARK: - 处理器要用的全局状态

    // 下面两个必须是 static 全局：`@convention(c)` 的处理函数不能捕获上下文
    private static var signalFileDescriptor: Int32 = -1
    private static var installed = false
    private static let lock = NSLock()

    private var options = Options()
    private var exceptionFile: URL?
    private var signalFile: URL?

    public init() {}

    public var isInstalled: Bool {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return Self.installed
    }

    // MARK: - 安装

    /// 安装崩溃捕获。重复调用只有第一次生效。
    ///
    /// - Important: 越早调用越好（`App.init()` 里），否则第一帧之前的崩溃记不到。
    /// - Note: watchOS 只安装异常处理器，信号捕获被系统禁止，`Options.signals` 会被忽略。
    public func install(options: Options = Options()) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard !Self.installed else {
            options.log?("[CrashKit] 已经安装过，本次调用忽略")
            return
        }

        self.options = options
        let directory = options.directory ?? Self.defaultDirectory()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            options.log?("[CrashKit] 创建目录失败：\(error.localizedDescription)")
        }
        let exceptionFile = directory.appendingPathComponent("pending-exception.json")
        let signalFile = directory.appendingPathComponent("pending-signal.bin")
        self.exceptionFile = exceptionFile
        self.signalFile = signalFile

        NSSetUncaughtExceptionHandler { exception in
            CrashRecorder.shared.record(exception: exception)
        }

        #if os(watchOS)
        // watchOS 禁止给致命信号挂处理器：libsystem_c 会直接以
        // "sigaction on fatal signals is not supported" 抛 SIGTRAP 杀掉进程。
        // 所以这里连记录文件都不创建，只保留异常路径。
        Self.signalFileDescriptor = -1
        if !options.signals.isEmpty {
            options.log?("[CrashKit] watchOS 不支持信号捕获，已忽略 signals=\(options.signals)")
        }
        // 让安装日志反映真实生效的配置，而不是原样打印传进来的 6 个信号
        self.options.signals = []
        // 清掉 0.1.1 在手表上留下的 0 字节信号文件；这里没有打开的 fd，unlink 是安全的
        try? FileManager.default.removeItem(at: signalFile)
        #else
        SignalRecordWriter.prepare()

        // **不要**用 O_TRUNC：启动时截断会把上次崩溃留下的记录清掉，
        // 结果就是"永远弹不出提示"。追加写即可，读完由 takePendingReport 清空。
        Self.signalFileDescriptor = open(signalFile.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        if Self.signalFileDescriptor < 0 {
            options.log?("[CrashKit] 打开信号记录文件失败，errno=\(errno)")
        }

        for signalNumber in options.signals {
            signal(signalNumber, crashKitSignalHandler)
        }
        #endif

        Self.installed = true
        options.log?("[CrashKit] 已安装，目录=\(directory.lastPathComponent)，信号=\(self.options.signals)，fd=\(Self.signalFileDescriptor)")
    }

    // MARK: - 读取（下次启动）

    /// 取回上次崩溃的记录并**清空**，保证同一份记录只提示一次。
    /// 有多条时返回最新的一条，其余条数记在 `olderRecordCount`。
    public func takePendingReport() -> CrashReport? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        if let report = takeExceptionReport() {
            // 异常通常紧接着就是 abort，信号记录描述的是**同一次**崩溃；
            // 不清掉的话，下次启动会再弹一次"上次闪退"的重复提示
            truncateSignalFile()
            return report
        }
        return takeSignalReport()
    }

    /// 丢掉所有未读记录（不提示）。用户已经看过、或者宿主自己上报完了，都可以调它。
    public func clearPendingReports() {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        if let exceptionFile {
            try? FileManager.default.removeItem(at: exceptionFile)
        }
        truncateSignalFile()
    }

    // MARK: - 写入：ObjC 异常

    /// 非信号上下文，可以安全地取 name / reason / 堆栈
    private func record(exception: NSException) {
        guard let exceptionFile else { return }
        let payload: [String: Any] = [
            "version": 1,
            "date": Date().timeIntervalSince1970,
            "name": exception.name.rawValue,
            "reason": exception.reason ?? "",
            "stack": exception.callStackSymbols,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8)
        else {
            options.log?("[CrashKit] 异常记录序列化失败：\(exception.name.rawValue)")
            return
        }
        do {
            try text.write(to: exceptionFile, atomically: true, encoding: .utf8)
        } catch {
            options.log?("[CrashKit] 异常记录写入失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 内部：信号

    /// 信号处理器里调用，只读静态 fd + 写预分配缓冲区
    fileprivate static func handleSignal(_ signalNumber: Int32) {
        SignalRecordWriter.write(code: signalNumber, to: signalFileDescriptor)
    }

    // MARK: - 内部：读

    private func takeExceptionReport() -> CrashReport? {
        guard let exceptionFile,
              let text = try? String(contentsOf: exceptionFile, encoding: .utf8)
        else { return nil }
        defer { try? FileManager.default.removeItem(at: exceptionFile) }

        guard let data = text.data(using: .utf8),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            // 文件在但读不懂：清掉并留日志，别让它变成"每次启动都沉默"的垃圾文件
            options.log?("[CrashKit] 异常记录无法解析，已清除")
            return nil
        }
        let stamp = payload["date"] as? TimeInterval ?? 0
        let name = payload["name"] as? String ?? "未知异常"
        let reason = payload["reason"] as? String
        let stack = (payload["stack"] as? [String] ?? []).prefix(max(options.maxStackLines, 0))
        return CrashReport(kind: .exception,
                           date: Date(timeIntervalSince1970: stamp),
                           exceptionName: name,
                           reason: reason,
                           stackLines: Array(stack))
    }

    private func takeSignalReport() -> CrashReport? {
        guard let signalFile,
              let data = try? Data(contentsOf: signalFile),
              data.count >= CrashRecordFormat.recordSize
        else {
            // 文件存在但长度不够：可能是写了一半就被杀掉，清掉它
            truncateSignalFile()
            return nil
        }
        let records = CrashRecordFormat.decode(data)
        truncateSignalFile()
        guard let newest = records.max(by: { $0.timestamp < $1.timestamp }) else {
            options.log?("[CrashKit] 信号记录 magic 不匹配（老版本文件？），已清空")
            return nil
        }
        return CrashReport(kind: .signal,
                           date: newest.date,
                           signalCode: newest.code,
                           olderRecordCount: max(records.count - 1, 0))
    }

    /// 清空而不是删除：信号处理器写的是启动时打开的 fd，
    /// 文件被 unlink 之后 fd 指向的还是那个"看不见的 inode"，下一次崩溃就会写丢。
    private func truncateSignalFile() {
        if Self.signalFileDescriptor >= 0 {
            ftruncate(Self.signalFileDescriptor, 0)
        } else if let signalFile {
            truncate(signalFile.path, 0)
        }
    }

    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("CrashKit", isDirectory: true)
    }

    // MARK: - 自测

    /// 让当前进程真的崩一次，用来验证接入是否生效（**只在 Debug 可用**）。
    ///
    /// 用法：接入后调一次，进程会立刻终止；下次启动 `takePendingReport()` 应该返回 `.signal` 记录。
    /// - Note: watchOS 上没有信号处理器，只会崩溃、不会留下记录。
    #if DEBUG
    public func crashForTesting() {
        raise(SIGABRT)
    }
    #endif

    #if DEBUG
    /// 测试用：拆掉安装状态，让下一个用例能重新 install（**不要**在 App 代码里调）
    static func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        installed = false
        if signalFileDescriptor >= 0 {
            close(signalFileDescriptor)
            signalFileDescriptor = -1
        }
        SignalRecordWriter.resetForTesting()
    }
    #endif
}

/// `signal()` 要的函数指针：不能捕获上下文，所以必须是文件级函数。
/// 记完之后**交回默认处理**，让进程照常终止 —— 我们不假装能恢复。
private func crashKitSignalHandler(_ signalNumber: Int32) {
    CrashRecorder.handleSignal(signalNumber)
    signal(signalNumber, SIG_DFL)
    raise(signalNumber)
}
