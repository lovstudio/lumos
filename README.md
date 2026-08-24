# Lumos

> 为未完成的事情，留一盏灯。

Lumos 是一款面向长时间任务与 Agent 工作流的 macOS 低功耗防休眠菜单栏工具。

当前项目已完成首轮技术可行性 Spike，并进入 D1 原生菜单栏骨架阶段。产品定义以
[HANDOFF.md](HANDOFF.md) 和 [Lumos PRD v0.2](docs/Lumos-PRD-v0.2.md)
为准；实验性能力仍不会包装成稳定产品承诺。

## 当前结论

- P0 核心闭环可行：运行中 App/PID/子进程观察、两类空闲休眠断言、Low Power Mode 与 Thermal State 读取均有公开 API 或 SDK 接口，并已在本机验证。
- 两类 IOPM Assertion 可以独立创建和释放，且不需要管理员权限。
- 立即熄屏可通过系统自带 `pmset displaysleepnow` 完成，本机无需管理员权限；它被隔离在适配器中，需逐 macOS 版本回归。
- Low Power Mode 切换需要管理员权限；不进入 P0，也不在首版安装特权 Helper。
- Apple Silicon 内置屏幕没有暴露旧 `IODisplayConnect` 控制路径；亮度控制仍是实验性能力。
- IOPM 空闲断言不能保证合盖、电量临界、热紧急或用户主动睡眠时继续运行；不承诺电池合盖必定可用。

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
```

`lovstudio app` 会根据 `packageManager` 使用 pnpm，并把上述命令转发到
`package.json` scripts。`dev` 会启动原生 AppKit 状态栏进程与 SwiftUI 弹窗；
它是单实例 MVP 开发骨架，不是已签名或可发布的 `.app` 包。再次运行 `dev` 会
明确提示已有实例，而不会创建第二个菜单栏图标。

单独运行探针：

```bash
.build/debug/lumos-spike system-state
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
Tests/LumosSpikeCoreTests/    Core 与断言生命周期测试
Scripts/                      可重复验证脚本
docs/                         PRD、技术结论与验证证据
visuals/                      交接视觉材料
```
