//
//  CrashReport.swift
//  CrashKit
//
//  一次崩溃的记录。库只产出数据，弹不弹窗、怎么弹由宿主决定。
//

import Foundation

/// 一次崩溃的记录。
///
/// 字段设计成**结构化**而不是拼好的字符串：宿主想自己排版、上报、脱敏都可以；
/// `title` / `details` 只是给"直接丢进弹窗"用的默认中文文案。
public struct CrashReport: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// ObjC 异常（`NSSetUncaughtExceptionHandler`）。非信号上下文，能安全拿到 name / reason / 堆栈
        case exception
        /// 信号（`SIGABRT` 等）。信号处理器里只能写定长二进制，所以只有编号和时间
        case signal
    }

    public let kind: Kind
    public let date: Date
    /// 信号编号，仅 `.signal`
    public let signalCode: Int32?
    /// 异常名（如 `NSInternalInconsistencyException`），仅 `.exception`
    public let exceptionName: String?
    /// 异常原因，仅 `.exception`
    public let reason: String?
    /// 调用栈，已按 `Options.maxStackLines` 截断
    public let stackLines: [String]
    /// 磁盘上还有几条更早的记录（崩溃循环时会出现多条；这些记录会被一并清掉）
    public let olderRecordCount: Int

    public init(kind: Kind,
                date: Date,
                signalCode: Int32? = nil,
                exceptionName: String? = nil,
                reason: String? = nil,
                stackLines: [String] = [],
                olderRecordCount: Int = 0)
    {
        self.kind = kind
        self.date = date
        self.signalCode = signalCode
        self.exceptionName = exceptionName
        self.reason = reason
        self.stackLines = stackLines
        self.olderRecordCount = olderRecordCount
    }

    /// 信号的可读名（带一句人话解释）
    public var signalName: String? {
        guard let signalCode else { return nil }
        switch signalCode {
        case SIGABRT: return "SIGABRT，通常是断言失败或被系统终止"
        case SIGSEGV: return "SIGSEGV，野指针 / 内存访问越界"
        case SIGBUS: return "SIGBUS，内存对齐或映射错误"
        case SIGILL: return "SIGILL，非法指令"
        case SIGFPE: return "SIGFPE，算术异常"
        case SIGTRAP: return "SIGTRAP，调试陷阱"
        default: return "未知信号"
        }
    }

    /// 弹窗标题（中文，宿主可直接用，也可自己拼）
    public var title: String {
        switch kind {
        case .exception:
            return "上次因异常退出（\(exceptionName ?? "未知异常")）"
        case .signal:
            return "上次闪退（\(signalCode.map { _ in String(signalName?.prefix(while: { $0 != "，" }) ?? "") } ?? "未知信号")）"
        }
    }

    /// 弹窗正文（中文，宿主可直接用，也可自己拼）
    public var details: String {
        var lines: [String] = []
        switch kind {
        case .exception:
            if let reason, !reason.isEmpty { lines.append(reason) }
            if !stackLines.isEmpty { lines.append(stackLines.joined(separator: "\n")) }
        case .signal:
            lines.append("收到信号 \(signalCode ?? -1)（\(signalName ?? "未知信号")）。")
            lines.append("这类崩溃通常发生在系统强制终止进程时（例如权限、内存、断言失败），进程无法恢复。")
        }
        if olderRecordCount > 0 {
            lines.append("另外还有 \(olderRecordCount) 条更早的崩溃记录，已一并清除。")
        }
        return lines.joined(separator: "\n\n")
    }
}
