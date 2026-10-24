# CrashKit

崩溃留痕：进程被系统杀掉之前尽量把「发生了什么」写到磁盘，下次启动读出来提示用户。

## 能力边界（先看这个）

- **拦不住崩溃**。`SIGABRT` 这类信号意味着进程已经被终止，本库只做「记录 + 下次启动提示」。
- 信号路径**只有编号和时间**。信号处理器里能用的只有 async-signal-safe 调用，取不了调用栈；
  要符号化堆栈得靠 MetricKit（次日系统回调）或 PLCrashReporter。
- ObjC 异常（`NSException`）路径能拿到 `name` / `reason` / `stack`，因为那条路不在信号上下文里。
- 只声明 **iOS 16+ / macOS 13+**。watchOS / tvOS 理论上可用但没有验证，所以没写进 `platforms`。

## 接入

```swift
// Package.swift
.package(path: "../CrashKit")            // 本地
.package(url: "https://github.com/<you>/CrashKit", exact: "0.1.0")   // 独立仓库

// 目标依赖
.product(name: "CrashKit", package: "CrashKit")
```

越早安装越好，最好在 `App.init()`：

```swift
import CrashKit

@main
struct MyApp: App {
    init() {
        CrashRecorder.shared.install(options: .init(log: { print($0) }))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    if let report = CrashRecorder.shared.takePendingReport() {
                        // report.title / report.details 是现成的中文文案；
                        // 也可以只用结构化字段（kind / date / signalCode / exceptionName / reason / stackLines）
                        showAlert(report)
                    }
                }
        }
    }
}
```

`Options`：`directory`（默认 `Application Support/CrashKit`）、`signals`（默认 6 个致命信号）、
`maxStackLines`（默认 6）、`log`（默认丢弃）。

## 验证接入是否生效

```swift
#if DEBUG
CrashRecorder.shared.crashForTesting()   // 真的 abort 当前进程
#endif
```

进程会立刻终止；下次启动 `takePendingReport()` 应该返回一条 `.signal` 记录。

## 四条硬约束（改错就静默失效，别"优化"掉）

1. **fd 必须用 `O_APPEND` 打开，绝不能用 `O_TRUNC`** —— 启动时截断会把上次崩溃的记录清掉，
   表现是「永远弹不出提示」。
2. **信号处理器里只写预分配缓冲区 + `write(fd)`** —— 不 malloc、不打印、不建 `FileManager`，
   否则二次崩溃，连记录都留不下。
3. **解析一律 `loadUnaligned`** —— 时间戳落在偏移 8，`Data` 基地址不保证 8 字节对齐，
   用 `load` 会直接 trap（真机上踩过）。
4. **读完用 `ftruncate(fd, 0)` 清空，不要 `unlink`** —— 文件被删后 fd 指向不可见的 inode，
   下一次崩溃就写丢了。

## 磁盘格式

每条 16 字节，可连续追加：

```
0..3   magic      "CK01"
4..7   signal     Int32
8..15  timestamp  Int64（Unix 秒）
```

magic 不符的块（老版本文件 / 写坏的残片）解析时会被跳过，不会崩。
异常记录是另一个文件 `pending-exception.json`。

## 测试

```bash
swift test
```

16 个用例覆盖：格式编解码、未对齐读取、残片容忍、重装不丢记录（`O_TRUNC` 回归）、
读后清空、崩溃循环取最新一条、异常栈截断、损坏文件清理。
