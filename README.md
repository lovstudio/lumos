# Lumos

> 为未完成的事情，留一盏灯。

Lumos 是一款面向长时间任务与 Agent 工作流的 macOS 低功耗防休眠菜单栏工具。

当前项目处于技术可行性 Spike 阶段。产品定义以 [HANDOFF.md](HANDOFF.md) 和
[Lumos PRD v0.2](docs/Lumos-PRD-v0.2.md) 为准；此阶段没有把实验性能力包装成完整 App。

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
Tests/LumosSpikeCoreTests/    Core 与断言生命周期测试
Scripts/                      可重复验证脚本
docs/                         PRD、技术结论与验证证据
visuals/                      交接视觉材料
```

