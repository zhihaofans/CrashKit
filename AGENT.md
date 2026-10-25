# AGENT.md

> 面向在**其他项目**里工作的 AI。接入、升级或修改 CrashKit 之前先读这份。
>
> CrashKit 是「崩溃留痕」库，**不是防崩溃库**：它拦不住 `SIGABRT` 这类进程终止，
> 只负责把「发生过什么」写进磁盘，并在下次启动时读出来。

## 一句话

捕获致命信号与 ObjC 异常 → 落盘 → 下次启动读出 `CrashReport`。
信号路径只有信号编号和时间；调用栈只有 `NSException` 路径拿得到。

## 仓库与版本

- 仓库：<https://github.com/zhihaofans/CrashKit>
- 最新发布：`0.1.2`（watchOS 自动跳过信号捕获）
- Product：`CrashKit`（Swift Package library）
- 工具链：`swift-tools-version: 5.9`，Swift 5 语言模式，零第三方依赖
- 平台：iOS 16+ / macOS 13+ / watchOS 9+。tvOS 没验证过，**不要**自行加进 `platforms`
- watchOS 9+ 只能走异常路径：系统禁止给致命信号挂处理器，`install()` 在手表上自动跳过信号捕获，
  `Options.signals` 被忽略；`crashForTesting()` 在手表上不会留下记录。`0.1.1` 真机已验证异常路径，
  `0.1.2` 把这项兼容处理内置到库里
- 测试：16 个用例，`swift test` 全绿

## 接入（消费方 AI 必读）

### 方式 A：Xcode 工程

1. File → Add Package Dependencies…
2. URL 填 `https://github.com/zhihaofans/CrashKit.git`
3. Dependency Rule 选 **Exact Version**，填 `0.1.2`
4. 把 `CrashKit` product 加到 App target 的 Frameworks, Libraries, and Embedded Content

如果必须直接改 `project.pbxproj`，结构是：

```text
XCRemoteSwiftPackageReference "CrashKit" = {
    isa = XCRemoteSwiftPackageReference;
    repositoryURL = "https://github.com/zhihaofans/CrashKit.git";
    requirement = {
        kind = exactVersion;
        version = 0.1.2;
    };
};
```

同时需要 `XCSwiftPackageProductDependency`（`productName = CrashKit`），
并把 package 挂到 `PBXProject.packageReferences`、product 挂到 target 的
`packageProductDependencies` 和 Frameworks build phase。
object ID 尽量让 Xcode 生成；手改完用 `xcodebuild -resolvePackageDependencies` 和一次构建验证。

### 方式 B：Package.swift

```swift
dependencies: [
    .package(url: "https://github.com/zhihaofans/CrashKit.git", exact: "0.1.2"),
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "CrashKit", package: "CrashKit"),
        ]
    ),
]
```

## 最小接入

### SwiftUI

```swift
import SwiftUI
import CrashKit

@main
struct MyApp: App {
    init() {
        // 越早越好：放在 App.init，不要等 onAppear / task，否则第一帧前的崩溃记不到
        CrashRecorder.shared.install(options: .init(log: { print($0) }))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    // 只在启动后取一次；takePendingReport() 取完即清空，第二次返回 nil
                    if let report = CrashRecorder.shared.takePendingReport() {
                        // report.title / report.details 是现成的中文文案，
                        // 也可以只用结构化字段自己排版、上报、脱敏
                    }
                }
        }
    }
}
```

如果弹窗要等 root view 出现后再展示，把 `report` 存进 `@State`/单例，**不要反复调用**
`takePendingReport()` 试图再拿一次——它是一次性消费。

### UIKit

```swift
import CrashKit

func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
) -> Bool {
    CrashRecorder.shared.install()

    // 先存起来，等 root VC 出现后再弹；不要在 didFinishLaunching 里同步弹窗
    pendingCrashReport = CrashRecorder.shared.takePendingReport()
    return true
}
```

## API 速查

| API | 说明 |
| --- | --- |
| `CrashRecorder.shared` | 全局单例 |
| `install(options:)` | 安装捕获。幂等，重复调用只有第一次生效；越早越好 |
| `takePendingReport() -> CrashReport?` | 取**最新**一条并清空所有待读记录，同一份只返回一次 |
| `clearPendingReports()` | 丢弃所有待读记录，不提示 |
| `isInstalled` | 是否已安装 |
| `crashForTesting()` | **仅 DEBUG**，真的 `raise(SIGABRT)`；watchOS 上只崩溃、不落盘 |

`Options`：

| 字段 | 默认值 | 说明 |
| --- | --- | --- |
| `directory` | `Application Support/CrashKit` | 记录目录；**每次启动必须一致**，否则旧记录找不到 |
| `signals` | 6 个致命信号 | `SIGABRT` / `SIGSEGV` / `SIGBUS` / `SIGILL` / `SIGFPE` / `SIGTRAP`；watchOS 上忽略 |
| `maxStackLines` | `6` | 仅异常路径的调用栈截断行数 |
| `log` | `nil` | 库日志出口；不要在这里打印敏感信息 |

`CrashReport`：

- `kind`：`.signal` / `.exception`
- `date`、`signalCode`、`exceptionName`、`reason`、`stackLines`、`olderRecordCount`
- `title` / `details`：现成的中文弹窗文案
- `signalName`：信号可读名与一句解释
- `Sendable`，可跨并发域传递；`CrashRecorder` 本身建议在启动阶段/主线程调用

## 行为细节（不要误解）

- **`takePendingReport()` 是一次性消费**：返回最新记录并清空文件；崩溃循环留下的多条记录
  只返回最新一条，其余数量在 `olderRecordCount`。
- 异常记录优先于信号记录：`NSException` 通常紧接着就是 `abort`，两者描述同一次崩溃；
  返回异常报告时会一并清空信号文件，避免下次启动重复提示。
- 信号路径的 `stackLines` 永远为空，`exceptionName` / `reason` 也为空；这是能力边界，不是 bug。
- `olderRecordCount` 只在信号路径有意义；异常路径恒为 `0`。
- 读不懂/损坏的文件会被清掉（可能写一条 `log`），不会让 App 每次启动都卡在坏记录上。
- 记录只在本机，不包含上传逻辑；是否上报、如何脱敏由宿主决定。
- 磁盘文件：`pending-signal.bin`（16 字节定长记录，可追加）、`pending-exception.json`；
  watchOS 只有后者，不会创建或写入信号文件。

## 验证接入是否生效

1. iOS/macOS：DEBUG 构建，在 App 启动后调用一次 `CrashRecorder.shared.crashForTesting()`。
2. 进程会立刻终止（这是预期的）；重新启动 App，`takePendingReport()` 应返回一条 `.signal` 记录。
3. watchOS：信号路径被系统禁止，`crashForTesting()` 不会落盘；改用
   `NSException(name: .internalInconsistencyException, reason: "test", userInfo: nil).raise()`，
   重新启动后应返回一条 `.exception` 记录。
4. 换成真机/Release 前，确认测试入口不会出现在正式流程里（`crashForTesting()` 本身有 `#if DEBUG`）。

## 修改库代码时的硬约束

这四条改错就会**静默失效**，不要为了“优化”掉。以下针对 iOS/macOS 的信号路径；
watchOS 没有信号路径，`install()` 里的 `#if os(watchOS)` 分支不能删，否则会启动即 SIGTRAP：

1. **fd 必须用 `O_APPEND` 打开，绝不能用 `O_TRUNC`**。启动时截断会清掉上次崩溃记录，
   表现是「永远弹不出提示」。
2. **信号处理器里只写 install 时预分配的缓冲区，再 `write(fd)`**。不 malloc、不打印、
   不建 `FileManager`、不做 JSON 序列化、不拿锁——否则可能二次崩溃。
3. **解析一律 `loadUnaligned`**。时间戳落在偏移 8，`Data` 基地址不保证 8 字节对齐，
   用 `load` 会直接 trap。
4. **读完用 `ftruncate(fd, 0)` 清空，不要 `unlink`**。文件被删后 fd 指向不可见的 inode，
   下一次崩溃写进去就丢了。

另外：

- 记录格式是 16 字节定长：`CK01` + `Int32` 信号 + `Int64` 时间戳。改布局必须同时改 magic。
- 信号处理器记完后要恢复 `SIG_DFL` 并重新 `raise`，不要假装能恢复进程。
- 不要新增未验证的平台；tvOS 需要真实构建和崩溃路径验证后再写进 `platforms`。
- 改动信号或文件路径代码后，至少用 watchOS SDK 构建一次，别只跑 macOS 测试。
- 公共 API 或磁盘格式变化时，升版本号并打新 tag；**不要移动已发布的 tag（如 `0.1.0` / `0.1.1` / `0.1.2`）**。

## 库自己的测试

不要直接 `swift test`，用下面这条（缓存重定向 + 关闭 SwiftPM 沙箱）：

```bash
TMPDIR="$PWD/.build/tmp" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/modulecache" \
CLANG_MODULE_CACHE_PATH="$PWD/.build/modulecache" \
swift test --scratch-path .build/scratch --cache-path .build/cache \
  --manifest-cache none --disable-sandbox
```

如果报 `precompiled file ... was compiled with module cache path ...`，说明 `.build/modulecache`
是从别的路径搬来的，删掉该目录后重跑。

watchOS 交叉构建（设备架构；模拟器把 triple 换成
`arm64-apple-watchos9.0-simulator`、SDK 换成 `watchsimulator`）：

```bash
TMPDIR="$PWD/.build/tmp" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/watchos-modulecache" \
CLANG_MODULE_CACHE_PATH="$PWD/.build/watchos-modulecache" \
swift build --triple arm64_32-apple-watchos9.0 \
  --sdk "$(xcrun --sdk watchos --show-sdk-path)" \
  --scratch-path .build/watchos-scratch --cache-path .build/watchos-cache \
  --manifest-cache none --disable-sandbox
```

watchOS 交叉构建只证明编译；信号路径在手表上被系统禁止，真机只能验证异常路径。

## 常见坑

- 把 `install` 放进 `.onAppear` / 异步任务：启动早期的崩溃会漏记。
- 在多个页面调用 `takePendingReport()`：第一次已经消费掉，后面全是 `nil`。
- 先 `clearPendingReports()` 再展示：记录直接丢了。
- 期待信号路径有调用栈：没有；要符号化堆栈请走 MetricKit / PLCrashReporter。
- 在 watchOS 上期待 `SIGABRT` 记录：系统禁止挂致命信号处理器；手表只走 `NSException`。
- 用 `unlink` 或 `O_TRUNC` “清理”记录文件：下一次崩溃静默写丢。
- 中途改 `Options.directory`：旧记录还在原目录，看起来像“没记到”。
- 把 `CrashReport` 当成防崩溃/恢复机制：它只做事后记录与提示。

## 给消费方 AI 的检查清单

- [ ] 依赖使用 remote URL + Exact Version `0.1.2`
- [ ] `install` 放在 App 启动最早处
- [ ] `takePendingReport()` 只消费一次，结果存起来再展示
- [ ] 弹窗使用 `title` / `details`，或安全地使用结构化字段
- [ ] 没有向用户承诺“不会闪退”
- [ ] 平台最低版本满足 iOS 16+ / macOS 13+ / watchOS 9+
- [ ] iOS/macOS DEBUG 下用 `crashForTesting()` 做过真实自检
- [ ] watchOS 只用 `NSException` 验证异常路径，不把 `crashForTesting()` 当有效自检
