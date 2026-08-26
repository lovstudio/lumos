# Lumos

> 为未完成的事情，留一盏灯。

Lumos 是一款面向长时间任务与 Agent 工作流的 macOS 低功耗防休眠菜单栏工具。

当前版本：**v0.2.1** · Apple Silicon · macOS 14+

[从 Lumos 官网下载](https://lumos.lovstudio.ai/) · [查看更新记录](CHANGELOG.md) · [阅读 v0.2.1 发布说明](docs/releases/v0.2.1.md)

当前项目已完成首轮技术可行性 Spike、D1-D5 原生守护闭环，以及第一版 Apple 风格
主面板与设置中心。产品定义以
[HANDOFF.md](HANDOFF.md) 和 [Lumos PRD v0.2](docs/Lumos-PRD-v0.2.md)
为准；实验性能力仍不会包装成稳定产品承诺。

当前交互范围已于 2026-08-25 收敛为“守护 App + 直接控制”。PRD v0.2 中的
Preset 章节保留早期决策背景，但方案选择、复制、编辑与自定义配置暂不进入当前产品。

## 当前结论

- P0 核心闭环可行：运行中 App/PID/子进程观察、两类空闲休眠断言、Low Power Mode 与 Thermal State 读取均有公开 API 或 SDK 接口，并已在本机验证。
- 两类 IOPM Assertion 可以独立创建和释放，且不需要管理员权限。
- `WakeLeaseEngine` 是进程内唯一 assertion 所有者；多个 receipt 按控制类型共享引用，最后一张归还后才释放系统断言。
- `ProcessObservationProvider` 以 PID + 启动时间区分进程实例，首帧只建立基线，后续输出启动、退出与 PID 复用事件；App 启停同时触发 `NSWorkspace` 即时刷新，并由低频快照校正。
- `SystemSafetyMonitor` 用 ProcessInfo 通知、IOPowerSources 与常驻 NWPathMonitor 监听低功耗、温度、电池/电源和网络变化；状态机按风险动态降低采样频率或撤销高风险 lease。
- App 守护已接入真实 lease 生命周期：有守护 App 时按首个 App 出现/最后一个 App 退出自动启停；没有指定 App 时，用户开启的直接控制立即生效并持续到手动关闭。
- 立即熄屏可通过系统自带 `pmset displaysleepnow` 完成，本机无需管理员权限；它被隔离在适配器中，需逐 macOS 版本回归。
- Low Power Mode 切换需要管理员权限；当前 switch 只修改正在使用的电源来源，并在写入后回读真实状态。
- Apple Silicon 内置屏幕没有暴露旧 `IODisplayConnect` 控制路径；亮度控制仍是实验性能力。
- IOPM 空闲断言不能保证合盖、电量临界、热紧急或用户主动睡眠时继续运行；实验性合盖守护
  通过管理员级 `pmset disablesleep`、真实状态回读与安全 watchdog 实现，不承诺跨版本必定可用。

完整依据、能力矩阵、架构与两周计划见
[技术可行性 Spike](docs/Technical-Feasibility-Spike.md)。本机原始验证摘要见
[Spike Evidence 2026-08-24](docs/spike-evidence/2026-08-24.md)。

## 运行最小实验

要求：Apple Silicon Mac、macOS 14+、Xcode Command Line Tools 或完整 Xcode。

```bash
cd /Users/mark/projects/lumos
swift test
Scripts/run-spike.sh
```

## 注册到 LovStudio

根目录的 `package.json` 是 LovStudio CLI 的 App 身份与命令适配层；SwiftPM
仍然是 Lumos 的实际构建系统。

```bash
npx lovstudio app add ~/projects/lumos
npx lovstudio app path lumos
npx lovstudio app lumos dev
npx lovstudio app lumos test
npx lovstudio app lumos spike
npx lovstudio app lumos probe system-state
npx lovstudio app lumos probe safety-state
npx lovstudio app lumos probe power-source
npx lovstudio app lumos probe clamshell-state
npx lovstudio app lumos probe low-power-state
```

`lovstudio app` 会根据 `packageManager` 使用 pnpm，并把上述命令转发到
`package.json` scripts。`dev` 会增量构建并签名 `.build/LumosDev.app`，监听
`Sources`、`Resources` 与 `Package.swift`；编译成功后平滑替换当前开发实例，编译失败时
保留旧实例继续运行。再次运行 `dev` 会先接管同项目已有的 watcher，避免创建第二个菜单栏图标。

首次运行开发 `.app` 时，macOS 会要求在“系统设置 > 通用 > 登录项与扩展”中允许 Lumos
系统辅助程序。批准一次后，合盖运行与低功耗模式通过受限的 XPC 接口执行，不再为每次开关
重复请求管理员密码。直接使用 `swift run lumos-app` 时没有 `.app` 包结构，因此仍使用逐次
授权的兼容路径。

若升级后 macOS 仍在运行旧版系统辅助程序，主面板与设置页会显示修复提示。用户可以直接
打开登录项设置，关闭后重新允许 LumosPrivilegedHelper，再回到 Lumos 重新检测；连接恢复后
提示会自动隐藏。

当前开发界面包括：

- 主面板把正在守护的 App 提升到控制开关之前，直接显示“守护中”“运行中”或“等待启动”，并提供一级管理入口；
- 保持任务运行、保持屏幕唤醒、合盖运行与低功耗模式四个直接开关；方案选择、复制、编辑与自定义配置已从当前产品范围移除；
- 每个功能项最右侧提供原生 info 图标；点击后显示使用 Markdown 编写的功能解释、实现逻辑与注意事项，移开鼠标不会自动弹出；
- 设置中可直接开启“登录时自动启动”；Lumos 通过 macOS 官方登录项服务登记主应用，并在切换后回读真实状态；
- 可持久化的直接控制和守护 App；运行实例数来自稳定进程身份，权限不足时明确显示身份不可读取；
- 本次守护时长、真实运行目标数，以及实时电源、温度、网络与安全降级状态；
- 能力状态页明确区分直接可用、需要授权与当前不可用的功能。

合盖休眠只有在 `SleepDisabled` 真实回读成功后才显示为已开启。无论当前状态由什么方式
写入，用户都可以通过 switch 直接恢复系统默认；开关同时建立自己的超时、低电量和退出
保护。若状态被相关软件立即写回，则提示先关闭相关防休眠、合盖控制或电源管理工具。
低功耗 switch 只修改当前电源来源，不会覆盖另一种电源来源的既有策略。
能耗变化在完成同一设备、同一负载下的基准采样前显示“暂无基准”。

## 下载与安装

正式版本通过 Developer ID 签名并由 Apple 公证：

```text
https://lumos.lovstudio.ai/downloads/Lumos-0.2.1-arm64.dmg
```

打开 DMG 后，将 Lumos 拖入“应用程序”文件夹。首次启用合盖运行或低功耗切换时，
macOS 会要求在“系统设置 > 通用 > 登录项与扩展”中允许 Lumos 的系统辅助程序。

合盖运行属于实验性能力，受 macOS 版本、机型、供电与散热条件影响；Lumos 会执行
时长、电量、温度和退出恢复保护，但不承诺所有环境下都能持续运行。

单独运行探针：

```bash
.build/debug/lumos-spike system-state
.build/debug/lumos-spike safety-state
.build/debug/lumos-spike power-source
.build/debug/lumos-spike clamshell-state
.build/debug/lumos-spike low-power-state
.build/debug/lumos-spike apps
.build/debug/lumos-spike process <pid>
.build/debug/lumos-spike hold system 10
.build/debug/lumos-spike hold display 10
.build/debug/lumos-spike network
.build/debug/lumos-spike display-brightness
```

以下命令会让屏幕立即熄灭，必须显式确认：

```bash
.build/debug/lumos-spike display-sleep-now --confirmed
```

## 目录

```text
Sources/LumosSpikeCore/       可复用的公开 API 探针与领域原型
Sources/LumosSpike/           命令行入口
Sources/LumosApp/             AppKit 状态栏与 SwiftUI 开发弹窗
Sources/LumosPrivilegedHelper/ 受限的系统电源 XPC 辅助程序
Tests/LumosSpikeCoreTests/    Core、进程观察与断言生命周期测试
Scripts/                      热重载与可重复验证脚本
docs/                         PRD、技术结论与验证证据
visuals/                      交接视觉材料
```
