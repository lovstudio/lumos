# Lumos 技术可行性 Spike

> 状态：完成首轮单机验证  
> 日期：2026-08-24  
> 产品依据：`HANDOFF.md`、`docs/Lumos-PRD-v0.2.md`  
> 原始证据：`docs/spike-evidence/2026-08-24.md`

## 1. 结论

Lumos 的 P0 核心闭环技术上可行，而且不需要管理员权限或特权 Helper：

1. 用 `NSWorkspace` 枚举运行中 App；
2. 用 libproc 观察 PID、父子关系和启动时间；
3. 用两个独立的 IOPM Assertion 表达“只防系统空闲休眠”和“保持显示器亮起”；
4. 用 `ProcessInfo` 读取 Low Power Mode 与 Thermal State；
5. 用 `NWPathMonitor` 解释当前网络路径；
6. 任务结束后引用计数归零并释放 assertion，进程崩溃时 assertion 也随进程自动撤销。

P1 中有三项不能混入 P0 承诺：

- 切换 Low Power Mode：需要管理员权限，且模式集合与机型相关；
- 内置屏幕亮度：当前 Apple Silicon 内置屏没有暴露旧公开控制路径；
- 电池合盖持续运行：公开 idle assertion 明确不能阻止 lid-close sleep，不能承诺“合盖必定可用”。

“随时可达”的 P0 实现应明确为“保持整机必要唤醒”，不是把 Wake for network access 宣传为任意 App 的远程唤醒保证。

## 2. 建议支持范围

### 2.1 产品基线

| 项目 | 建议 |
| --- | --- |
| CPU | Apple Silicon only，arm64 |
| 最低系统 | macOS 14.0 |
| 当前开发验证 | macOS 26.6 / M3 Pro |
| 分发 | Developer ID + Notarization + 官网 DMG |
| App Sandbox | 首版不启用；仍坚持最小权限与本地数据 |

选择 macOS 14 而不是更低版本的原因：覆盖 M1 起的 Apple Silicon 主线，同时把首版验证矩阵控制在 macOS 14、15、26 三个系统代际；当前 Swift Package 已以 macOS 14 deployment target 编译和测试。核心 API 本身多数更早可用，但“API 可用”不等于完整产品已在更早系统验证。

Apple 当前官方电源模式文档列出的设备已经横跨 M1 至 M5，但 Low/High Power Mode 的具体行为和可选项随型号变化。因此“arm64 可安装”与“某个电源模式可切换”必须分成两个 capability check。参考：[About Power Modes on your Mac](https://support.apple.com/en-us/101613)。

### 2.2 发布前最低矩阵

| 维度 | 最低样本 |
| --- | --- |
| macOS | 14.x、15.x、26.x 最新补丁 |
| 芯片 | M1/M2 一台、M3 一台、M4/M5 一台 |
| 形态 | MacBook Air（无风扇）、MacBook Pro、桌面 Mac |
| 显示 | 仅内置、Apple 外显、第三方 DDC 外显 |
| 电源 | AC、电池、Low Power Mode 开/关 |
| 热状态 | nominal/fair 的自然状态；serious/critical 用可控测试注入或策略单测 |

当前只有 M3 Pro/macOS 26.6 的直接证据，不能把单机结果外推为矩阵已通过。

## 3. 能力矩阵

定级定义：

- `direct`：公开 API/系统工具可直接使用，普通用户权限下已验证或有明确 SDK 合同；
- `permission`：需要管理员授权、特权 Helper 或额外系统配置；
- `experimental`：机型/系统差异显著，或只能依赖不稳定实现路径；
- `unsupported`：不能稳定实现产品承诺，必须从默认能力中排除。

| 能力 | 定级 | 验证与边界 | MVP 决策 |
| --- | --- | --- | --- |
| 枚举运行中 App | `direct` | `NSWorkspace.runningApplications` 本机读到 165 项 | P0；事件 + 快照差分 |
| 指定 PID 存在与身份 | `direct` | `proc_pidinfo(PROC_PIDTBSDINFO)` 读取 PID、PPID、启动时间 | P0；用 PID+start time 防复用 |
| 子进程/命令观察 | `direct` | 实测识别 `zsh -> sleep`；受保护进程可能信息不全 | P0；不可见时显示 unknown |
| CPU/I/O/网络推断 Working | `experimental` | 只能是活动信号，不能证明业务任务存在 | P0 仅作为可解释规则，不默认“理解任务” |
| 防系统空闲休眠 | `direct` | `PreventUserIdleSystemSleep` 创建/可见/释放成功，无特殊权限 | P0 |
| 防显示器空闲熄灭 | `direct` | `PreventUserIdleDisplaySleep` 独立创建/释放成功 | P0 |
| Low Power Mode 读取 | `direct` | `ProcessInfo.isLowPowerModeEnabled` 实测成功，可监听通知 | P0 展示与降频 |
| Thermal State 读取 | `direct` | `ProcessInfo.thermalState` 实测 nominal，可监听通知 | P0 安全降级 |
| Low Power Mode 切换 | `permission` | `pmset` 非 root 退出 1；Apple 也明确模式随机型变化 | P1；首版不装 Helper |
| 当前网络路径 | `direct` | `NWPathMonitor` 实测 Wi-Fi satisfied | P0 状态解释 |
| 读取 Wake for network 配置 | `direct` | `pmset -g custom` 可读 `womp` | P0 只读说明 |
| 修改 Wake for network 配置 | `permission` | `pmset` 修改电源设置要求 root | P1，单独授权 |
| 睡眠后唤醒任意 App | `unsupported` | Apple 将该设置描述为访问共享资源，不是通用 App 唤醒 SLA | 不承诺 |
| 立即熄屏 | `direct` | `pmset displaysleepnow` 本机实际成功、无需 root | P1；系统 CLI 适配器逐版本回归 |
| 内置显示器亮度写入 | `experimental` | M3 Pro 上 `IODisplayConnect` 为空；仅内部 registry 可读，setter unsupported | P1 继续矩阵，不用私有 API发布 |
| 第三方外显亮度 | `experimental` | DDC/CI、USB、Thunderbolt 能力不一致 | 作为独立 provider，不做统一承诺 |
| 官方闭盖外显模式 | `permission` | 需要外显、键鼠/触控板与已允许的附件；部分机型还要求供电 | 只识别条件，不由 Lumos“解锁” |
| 电池合盖持续任务 | `unsupported` | idle assertion 明确不阻止 lid close；私有/机型路径不稳定 | 不进入 P0/P1 的稳定承诺 |

## 4. 关键技术结论

### 4.1 两类 IOPM Assertion 必须是两个原子控制

`IOPMAssertionCreateWithName` 不需要特殊权限。Apple 对两类断言的合同不同：

- `PreventUserIdleSystemSleep` 只阻止因用户空闲触发的系统休眠，显示器仍可熄灭；合盖、Apple 菜单主动睡眠、低电量等仍可让系统睡眠。
- `PreventUserIdleDisplaySleep` 阻止因空闲导致的显示器熄灭；显示器保持亮起时系统也不能进入 idle sleep，但合盖和整机其他睡眠原因仍可覆盖。

参考：[IOPMAssertionCreateWithName](https://developer.apple.com/documentation/iokit/1557134-iopmassertioncreatewithname)、[display idle assertion](https://developer.apple.com/documentation/iokit/kiopmassertiontypepreventuseridledisplaysleep)、[system idle assertion](https://developer.apple.com/documentation/iokit/kiopmassertiontypepreventuseridlesystemsleep)。

实现要求：

- 每一份 lease 记录来源、原因、创建时间和可选 deadline；
- 控制器按 assertion kind 引用计数，不因一个关注对象结束而误释放其他对象的保护；
- 失败必须返回 IOReturn 并在 UI 标记 degraded；
- P0 不修改持久 `pmset` 设置，崩溃时由进程生命周期自动释放 assertion；
- 长时 lease 仍设置产品级 safety deadline/确认，不依赖永不超时的匿名开关。

### 4.2 App、PID 与子进程观察

`NSWorkspace.runningApplications` 是 App 层快照来源。Apple 文档指出普通 terminate notification 不覆盖后台 App 和 `LSUIElement` App，需要对 `runningApplications` 做 KVO 或快照差分。参考：[NSWorkspace](https://developer.apple.com/documentation/appkit/nsworkspace)、[didTerminateApplicationNotification](https://developer.apple.com/documentation/appkit/nsworkspace/didterminateapplicationnotification)。

正式实现采用两条路径：

1. App：Workspace 初始快照 + launch/terminate 事件 + 低频快照校正；
2. PID：libproc 快照 + `DispatchSourceProcess` 退出事件 + PID/start-time 身份检查。

只凭进程存在只能产生 Running。Working/Waiting/Finished 必须带 `WorkingRule`：命令存在、子进程模板、阈值窗口、集成上报或用户手动声明。观察权限不足时是 `unknown/degraded`，不是 Finished。

### 4.3 Low Power Mode 与 Thermal State

`ProcessInfo` 可以读取两者并接收变化通知。Apple 建议在 Low Power Mode 降低可选活动，在 thermal serious/critical 减少或停止计算、网络和显示更新。参考：[ProcessInfo](https://developer.apple.com/documentation/foundation/processinfo)、[Responding to power notifications](https://developer.apple.com/documentation/xcode/responding-to-power-notifications)。

Lumos 的 P0 行为：

- Low Power Mode：只读并降低自身采样、动画与非必要网络；
- thermal fair：降低活动采样频率；
- thermal serious：提示并撤销非关键 display lease；
- thermal critical：释放可撤销 lease，把决策交还系统，并明确说明任务连续性可能中断。

切换 Low Power Mode 不进入 P0。本机实测 `/usr/bin/pmset` 修改需要 root；若未来引入 Helper，必须单独做 threat model、安装/卸载/回滚和用户授权 UX。

### 4.4 熄屏与亮度

`pmset displaysleepnow` 在本机无需 root，实际熄屏成功。它是系统 CLI，不是 App framework API，因此放在 `DisplaySleepControlling` adapter 后面，启动时 capability probe，执行后观察 workspace screen sleep/wake 通知；失败不显示成功。

亮度不能复用同样结论。虽然 SDK 仍声明 `IODisplaySetFloatParameter`，M3 Pro/macOS 26.6 的内置屏没有 `IODisplayConnect` service。`AppleARMBacklight` registry 可读到 0.5，但公开 getter 返回 unsupported。私有 CoreDisplay/DisplayServices 或直接写内部 registry 不进入发布代码。

### 4.5 网络可达与合盖

`NWPathMonitor` 只能说明当前网络路径。Apple 对 Wake for network access 的用户文档描述是：睡眠中为共享打印机、Music 播放列表等共享资源唤醒 Mac。它不能推出 ChatGPT Remote 或任意本地端口一定可唤醒。参考：[Mac Battery settings](https://support.apple.com/guide/mac-help/change-battery-settings-mchlfc3b7879/mac)。

P0“随时可达”使用 system idle lease 保持必要唤醒，并如实显示耗电；Wake for network 只做配置解释。

Apple Silicon MacBook 的官方闭盖使用也依赖已允许的外接显示器、鼠标和键盘；Apple 的部分机型说明还要求外接供电。参考：[Allow accessories to connect](https://support.apple.com/en-gb/102282)、[M3 dual displays with lid closed](https://support.apple.com/en-gb/117373)。Lumos 不绕过 lid-close sleep，也不承诺电池合盖。

## 5. 推荐的最小架构

```text
LumosApp (NSStatusItem + SwiftUI popover)
├── AppStateStore @MainActor
│   └── 把可解释状态映射为灯芯、光环、风险文案
├── WakeLeaseEngine actor
│   ├── PolicyEvaluator        Signals -> Preset -> Desired Controls
│   ├── LeaseRegistry          多目标引用计数、deadline、退出条件
│   └── SafetyGovernor         电量、供电、Thermal、能力降级
├── Signal Providers
│   ├── WorkspaceAppProvider   NSWorkspace 事件 + 快照校正
│   ├── ProcessProvider        libproc + DispatchSourceProcess
│   └── Manual/Integration     用户声明与未来 App 主动上报
├── Atomic Control Drivers
│   ├── IOPMAssertionDriver    system/display idle assertions
│   ├── DisplaySleepDriver     pmset displaysleepnow，capability-gated
│   └── ReadOnlySystemDriver   ProcessInfo/NWPath/IOPowerSources
└── Persistence
    ├── Preset/WatchedTarget 的版本化 Codable 文件
    └── 只持久化用户意图；启动后重新评估，不伪造“仍在生效”
```

为什么用 `NSStatusItem + SwiftUI popover`：灯芯/光环需要动态图标和细粒度菜单状态，AppKit 负责可靠的菜单栏生命周期，SwiftUI 负责内容与状态绑定。P0 不需要 XPC、LaunchDaemon 或特权 Helper。

核心协议建议：

```swift
protocol SignalProvider: Sendable {
    func snapshots() -> AsyncStream<SignalSnapshot>
}

protocol AtomicControlDriver: Sendable {
    associatedtype Request: Sendable
    func apply(_ request: Request) async throws -> ControlReceipt
    func revoke(_ receipt: ControlReceipt) async
}
```

`WakeLeaseEngine` 是唯一能创建/释放 control receipt 的所有者。UI、Provider 和持久化层都不能直接调用 IOKit，从结构上避免“显示开着但引擎不知道”的孤儿状态。

## 6. 状态恢复策略

P0 的 assertion 是进程作用域，崩溃不会永久修改系统设置。恢复的对象不是旧 assertion ID，而是用户意图：

1. 原子写入 `WatchedTarget`、Preset、用户是否允许自动恢复；
2. 正常退出先释放 receipt，再记录 stopped；
3. 异常退出后下次启动把上次状态标记为 interrupted；
4. 重新观察目标并要求规则重新满足，才创建新 lease；
5. UI 明确显示“已恢复观察”或“上次守护已中断”，不伪造连续保护。

未来若修改持久系统设置，必须额外保存 before/desired/applied 三态并提供独立 repair tool；这也是 P0 不引入 Low Power Mode 切换的原因。

## 7. 两周 MVP 计划

执行进度：D1 的 `NSStatusItem + SwiftUI` 开发骨架已于 2026-08-24 落地，可通过
`npx lovstudio app lumos dev` 启动；签名 `.app`、完整状态模型和后续 D2-D10
仍按下表推进。

### 第 1 周：建立可信的守护闭环

| 天 | 输出 | 验证 |
| --- | --- | --- |
| D1 | Xcode App、`NSStatusItem + SwiftUI` 骨架、领域类型 | App 可启动/退出，菜单栏状态可测 |
| D2 | `WakeLeaseEngine`、引用计数、IOPM driver | 两类断言集成测试；多 lease 不误释放 |
| D3 | Workspace/PID/子进程 provider | App 启停、真实命令树、PID 复用测试 |
| D4 | ProcessInfo、IOPowerSources、NWPath safety monitors | Low Power/Thermal/电源变化状态机测试 |
| D5 | 任务守护/保持亮屏/随时可达三个 Preset | 从 trigger 到 lease 到 exit 的端到端测试 |

### 第 2 周：解释、恢复与可分发性

| 天 | 输出 | 验证 |
| --- | --- | --- |
| D6 | 灯芯+光环图标、当前状态/关注对象/降级文案 | VoiceOver、非颜色状态、两次点击内可解释 |
| D7 | 版本化持久化与异常恢复 | kill -9、重启、目标已结束/仍运行四组合 |
| D8 | 低频/事件驱动采样与能耗基线工具 | idle CPU 目标 <0.5%；与裸 caffeinate 同场景记录 |
| D9 | Developer ID、Notarization、Sparkle 2 更新骨架 | 签名、公证、更新清单与失败回滚测试 |
| D10 | macOS 14/15/26 + 至少两类芯片 beta 矩阵 | 结果写入 capability registry；阻断虚假绿色状态 |

两周结束的 definition of done：三个 P0 Preset 在已验证配置上形成 trigger → explain → assert → release → recover 闭环；P1 权限能力保持 feature flag 关闭。

## 8. 风险与门禁

| 风险 | 影响 | 门禁 |
| --- | --- | --- |
| 把 Running 当 Working | 任务完成后仍耗电 | UI 永远展示 WorkingRule；无规则只显示 Running |
| 单个目标结束误释放 | 其他任务中断 | kind 级引用计数 + 多目标并发测试 |
| 后台 App 事件缺失 | 错误 Finished | NSWorkspace 事件 + 快照差分 |
| PID 复用 | 监控到错误进程 | PID + start time + executable identity |
| 系统拒绝 assertion | 虚假安全感 | 检查 IOReturn，状态 degraded，禁止绿色成功态 |
| Helper 扩大攻击面 | 安全与卸载风险 | P0 不安装；P1 独立 threat model 和用户确认 |
| 亮度私有路径失效 | 发布后功能坏 | 没有公开可写 capability 就保持 experimental |
| 合盖/密闭高负载 | 过热与任务中断 | 不承诺；thermal safety 优先；文案明确通风 |

## 9. 需要确认的产品边界

在进入完整 App 开发前，建议确认以下三项：

1. 首版支持 Apple Silicon + macOS 14+；
2. P0 不切换 Low Power Mode、不调亮度、不提供电池合盖保证；
3. “随时可达”P0 明确定义为保持整机必要唤醒，Wake for network 只做设置解释。

这三项不会削弱 Lumos 的核心价值；它们把已验证的任务连续性与尚未稳定的系统控制分开，保证 UI 的每个绿色状态都有真实依据。
