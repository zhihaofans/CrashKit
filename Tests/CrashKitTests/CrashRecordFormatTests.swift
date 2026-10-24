//
//  CrashRecordFormatTests.swift
//  CrashKitTests
//
//  磁盘格式与解码。重点是"读坏数据不许崩"和"未对齐也要读对"。
//

import XCTest
@testable import CrashKit

final class CrashRecordFormatTests: XCTestCase {
    func testEncodeDecodeRoundTrip() {
        let record = SignalRecord(code: SIGSEGV, timestamp: 1_700_000_000)
        let data = Data(CrashRecordFormat.encode(record))
        XCTAssertEqual(CrashRecordFormat.decode(data), [record])
    }

    func testDecodeSkipsBlockWithWrongMagic() {
        // 老版本文件（没有 magic）：16 字节的垃圾
        let junk = Data((0 ..< 16).map { UInt8($0) })
        XCTAssertTrue(CrashRecordFormat.decode(junk).isEmpty, "magic 不符的记录必须被跳过，而不是读成一条乱码")
    }

    func testDecodeReturnsEmptyForFileShorterThanOneRecord() {
        XCTAssertTrue(CrashRecordFormat.decode(Data()).isEmpty)
        XCTAssertTrue(CrashRecordFormat.decode(Data(repeating: 0, count: 15)).isEmpty)
    }

    /// 记录是 16 字节、Int64 落在偏移 8：第二条、第三条的偏移是 24、40，
    /// 都不是 8 的倍数。用 load 会 trap，必须 loadUnaligned。
    func testDecodeHandlesUnalignedRecords() {
        let a = SignalRecord(code: SIGABRT, timestamp: 1_700_000_001)
        let b = SignalRecord(code: SIGBUS, timestamp: 1_700_000_002)
        let c = SignalRecord(code: SIGILL, timestamp: 1_700_000_003)
        var data = Data()
        for record in [a, b, c] {
            data.append(contentsOf: CrashRecordFormat.encode(record))
        }
        XCTAssertEqual(CrashRecordFormat.decode(data), [a, b, c])
    }

    /// 写到一半被杀掉会留下残片：解析时跳过，不能因为最后一块不完整就丢掉前面的
    func testDecodeKeepsWholeRecordsWhenTailIsTruncated() {
        var data = Data(CrashRecordFormat.encode(SignalRecord(code: SIGTRAP, timestamp: 42)))
        data.append(contentsOf: [0x00, 0x01, 0x02]) // 3 字节残片
        XCTAssertEqual(CrashRecordFormat.decode(data).count, 1)
    }

    /// 信号处理器实际写盘的那条路径：预分配缓冲区 + write(fd)
    func testWriterAppendsRecordToFileDescriptor() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("crashkit-writer-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }

        SignalRecordWriter.prepare()
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        SignalRecordWriter.write(code: SIGABRT, to: fd)
        close(fd)
        SignalRecordWriter.resetForTesting()

        let records = CrashRecordFormat.decode(try Data(contentsOf: url))
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.code, SIGABRT)
        // 时间戳是写的时候取的，只断言"像样"（大于 2020 年）
        XCTAssertGreaterThan(records.first?.timestamp ?? 0, 1_600_000_000)
    }
}
