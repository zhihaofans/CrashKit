//
//  CrashRecordFormat.swift
//  CrashKit
//
//  磁盘格式：定长记录，可连续追加。
//
//  为什么是二进制而不是 JSON：信号处理器里不能 malloc、不能建对象、不能 JSON 序列化，
//  只能往一个**启动时就分配好**的缓冲区里写字节，然后 write(fd)。
//
//  格式（每条 16 字节）：
//  ```
//  0..3   magic      "CK01"  ← 4 个 ASCII 字节，按字节比对，不涉及字节序
//  4..7   signal     Int32，本机字节序
//  8..15  timestamp  Int64，Unix 秒，本机字节序
//  ```
//  解析时一律用 `loadUnaligned`：Int64 落在偏移 8，`Data` 的基地址不保证 8 字节对齐，
//  用 `load` 会直接 trap（真机上踩过：Swift/UnsafeRawPointer.swift:450
//  Fatal error: load from misaligned raw pointer）。
//

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// 一条信号记录
struct SignalRecord: Equatable {
    let code: Int32
    let timestamp: Int64

    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(timestamp))
    }
}

enum CrashRecordFormat {
    /// 记录长度。改格式时**必须**同时改 magic，否则老文件会被当成新格式读。
    static let recordSize = 16
    static let magic: [UInt8] = Array("CK01".utf8)

    /// 编码一条记录（测试与"非信号上下文"使用）
    static func encode(_ record: SignalRecord) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: recordSize)
        bytes.replaceSubrange(0 ..< 4, with: magic)
        var code = record.code
        var stamp = record.timestamp
        withUnsafeBytes(of: &code) { raw in
            for (offset, byte) in raw.enumerated() { bytes[4 + offset] = byte }
        }
        withUnsafeBytes(of: &stamp) { raw in
            for (offset, byte) in raw.enumerated() { bytes[8 + offset] = byte }
        }
        return bytes
    }

    /// 解析整份文件。magic 不符的块直接跳过（老版本文件 / 写坏的残片），**不抛错也不崩**。
    static func decode(_ data: Data) -> [SignalRecord] {
        guard data.count >= recordSize else { return [] }
        var records: [SignalRecord] = []
        records.reserveCapacity(data.count / recordSize)
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset + recordSize <= raw.count {
                let start = offset
                if raw[start] == magic[0], raw[start + 1] == magic[1],
                   raw[start + 2] == magic[2], raw[start + 3] == magic[3]
                {
                    let code = raw.loadUnaligned(fromByteOffset: start + 4, as: Int32.self)
                    let stamp = raw.loadUnaligned(fromByteOffset: start + 8, as: Int64.self)
                    records.append(SignalRecord(code: code, timestamp: stamp))
                }
                offset += recordSize
            }
        }
        return records
    }
}

/// 信号处理器专用写入器。
///
/// 缓冲区在 `install` 时一次性分配好，处理器里只做「改 12 个字节 + write」：
/// 不分配、不建对象、不打印。写共享缓冲不加锁——崩溃时进程已经要死了，
/// 拿锁反而可能卡住；这里最坏情况是两条记录交错，而被截成残片的记录会被 magic 校验跳过。
enum SignalRecordWriter {
    /// 处理器要用，必须是全局可访问的裸指针（闭包不能捕获上下文）
    static var storage: UnsafeMutablePointer<UInt8>?

    /// install 时调用：分配并写好 magic
    static func prepare() {
        guard storage == nil else { return }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: CrashRecordFormat.recordSize)
        for (index, byte) in CrashRecordFormat.magic.enumerated() {
            buffer[index] = byte
        }
        storage = buffer
    }

    /// 信号处理器里调用。`fd` 是 install 时用 `O_APPEND` 打开的那个，这里绝不能自己 open。
    static func write(code: Int32, to fd: Int32) {
        guard let buffer = storage else { return }
        var signalCode = code
        var stamp = Int64(time(nil))
        withUnsafeBytes(of: &signalCode) { raw in
            for (offset, byte) in raw.enumerated() { buffer[4 + offset] = byte }
        }
        withUnsafeBytes(of: &stamp) { raw in
            for (offset, byte) in raw.enumerated() { buffer[8 + offset] = byte }
        }
        _ = Darwin.write(fd, buffer, CrashRecordFormat.recordSize)
    }

    /// 测试用：释放缓冲区，让下一个用例重新 prepare
    static func resetForTesting() {
        storage?.deallocate()
        storage = nil
    }
}
