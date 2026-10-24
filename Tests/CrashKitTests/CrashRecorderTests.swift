//
//  CrashRecorderTests.swift
//  CrashKitTests
//
//  安装 / 读取 / 清空这条主链路。每个用例用独立临时目录，靠 resetForTesting 重装。
//

import XCTest
@testable import CrashKit

final class CrashRecorderTests: XCTestCase {
    private var directory: URL!
    private var recorder: CrashRecorder!

    private var signalFile: URL {
        directory.appendingPathComponent("pending-signal.bin")
    }

    private var exceptionFile: URL {
        directory.appendingPathComponent("pending-exception.json")
    }

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("crashkit-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        CrashRecorder.resetForTesting()
        recorder = CrashRecorder()
    }

    override func tearDown() {
        CrashRecorder.resetForTesting()
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func append(_ record: SignalRecord) throws {
        let handle = try FileHandle(forWritingTo: signalFile)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(CrashRecordFormat.encode(record)))
    }

    // MARK: - 安装

    func testInstallIsIdempotent() {
        recorder.install(options: .init(directory: directory))
        XCTAssertTrue(recorder.isInstalled)
        recorder.install(options: .init(directory: directory))
        XCTAssertTrue(recorder.isInstalled, "重复 install 不应该崩，也不该把状态搞坏")
    }

    /// 回归：install 曾经用过 O_TRUNC，每次启动都把上次的崩溃记录清空，
    /// 表现为"永远弹不出提示"。
    func testInstallDoesNotTruncateExistingRecords() throws {
        recorder.install(options: .init(directory: directory))
        try append(SignalRecord(code: SIGSEGV, timestamp: 1_700_000_000))

        // 模拟"进程重启后再次 install"
        CrashRecorder.resetForTesting()
        let second = CrashRecorder()
        second.install(options: .init(directory: directory))

        let report = second.takePendingReport()
        XCTAssertEqual(report?.signalCode, SIGSEGV, "重装后旧记录必须还在")
    }

    // MARK: - 读取

    func testTakePendingReportReturnsNewestAndClearsFile() throws {
        recorder.install(options: .init(directory: directory))
        try append(SignalRecord(code: SIGSEGV, timestamp: 1_700_000_000))
        try append(SignalRecord(code: SIGABRT, timestamp: 1_700_000_100))
        try append(SignalRecord(code: SIGBUS, timestamp: 1_700_000_050))

        let report = recorder.takePendingReport()
        XCTAssertEqual(report?.kind, .signal)
        XCTAssertEqual(report?.signalCode, SIGABRT, "应该给最新那条（时间戳最大）")
        XCTAssertEqual(report?.date, Date(timeIntervalSince1970: 1_700_000_100))
        XCTAssertEqual(report?.olderRecordCount, 2)

        // 读完清空：文件还在（fd 仍指向它），但长度为 0
        XCTAssertEqual(try Data(contentsOf: signalFile).count, 0)
        XCTAssertNil(recorder.takePendingReport(), "同一份记录只提示一次")
    }

    func testCorruptSignalFileIsClearedWithoutCrash() throws {
        recorder.install(options: .init(directory: directory))
        try Data(repeating: 0xAB, count: 100).write(to: signalFile)

        XCTAssertNil(recorder.takePendingReport())
        XCTAssertEqual(try Data(contentsOf: signalFile).count, 0, "读不懂的内容也要清掉，别每次启动都沉默")
    }

    func testClearPendingReportsDropsEverything() throws {
        recorder.install(options: .init(directory: directory))
        try append(SignalRecord(code: SIGTRAP, timestamp: 1_700_000_000))
        try Data("{}".utf8).write(to: exceptionFile)

        recorder.clearPendingReports()
        XCTAssertNil(recorder.takePendingReport())
        XCTAssertFalse(FileManager.default.fileExists(atPath: exceptionFile.path))
    }

    // MARK: - 异常记录

    func testExceptionReportParsesAndTruncatesStack() throws {
        recorder.install(options: .init(directory: directory, maxStackLines: 3))
        let stack = (0 ..< 10).map { "frame \($0)" }
        let payload: [String: Any] = [
            "version": 1,
            "date": 1_700_000_123.0,
            "name": "NSInternalInconsistencyException",
            "reason": "boom",
            "stack": stack,
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: exceptionFile)

        let report = recorder.takePendingReport()
        XCTAssertEqual(report?.kind, .exception)
        XCTAssertEqual(report?.exceptionName, "NSInternalInconsistencyException")
        XCTAssertEqual(report?.reason, "boom")
        XCTAssertEqual(report?.stackLines.count, 3, "栈必须按 maxStackLines 截断")
        XCTAssertFalse(FileManager.default.fileExists(atPath: exceptionFile.path), "读完要删掉")
    }

    func testUnparsableExceptionFileIsRemoved() throws {
        recorder.install(options: .init(directory: directory))
        try Data("not json".utf8).write(to: exceptionFile)

        XCTAssertNil(recorder.takePendingReport())
        XCTAssertFalse(FileManager.default.fileExists(atPath: exceptionFile.path))
    }

    /// 异常记录优先于信号记录（异常上下文信息更多）
    func testExceptionReportWinsOverSignalReport() throws {
        recorder.install(options: .init(directory: directory))
        try append(SignalRecord(code: SIGSEGV, timestamp: 1_700_000_000))
        let payload: [String: Any] = [
            "date": 1_700_000_200.0,
            "name": "NSRangeException",
            "reason": "out of bounds",
            "stack": ["a"],
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: exceptionFile)

        let report = recorder.takePendingReport()
        XCTAssertEqual(report?.kind, .exception)
        XCTAssertEqual(try Data(contentsOf: signalFile).count, 0, "信号记录也要一起清掉，不能留成下一次的重复提示")
    }

    // MARK: - 崩溃报告的可读文案

    func testUserFacingTextMentionsSignal() {
        let report = CrashReport(kind: .signal, date: Date(), signalCode: SIGABRT)
        XCTAssertTrue(report.title.contains("SIGABRT"), "标题要能看出是哪个信号")
        XCTAssertTrue(report.details.contains("SIGABRT"))
    }

    func testOlderRecordCountShowsUpInDetails() {
        let report = CrashReport(kind: .signal, date: Date(), signalCode: SIGSEGV, olderRecordCount: 2)
        XCTAssertTrue(report.details.contains("2 条更早"), "崩溃循环时用户要知道还有别的记录")
    }
}
