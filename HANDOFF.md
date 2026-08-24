# Lumos · Codex 会话交接

> 本文件用于将 ChatGPT Work 中的产品讨论迁移到本地 Codex。  
> 请先完整阅读本文件和 `docs/Lumos-PRD-v0.2.md`，再开始设计或编码。

## 1. 项目概述

Lumos 是一款 macOS 菜单栏低功耗防休眠工具。

- 产品名：`Lumos`
- Bundle ID：`ai.lovstudio.lumos`
- Slogan：`为未完成的事情，留一盏灯。`
- 技术核心：Wake Lease（唤醒租约）
- 分发方向：官网 DMG、Developer ID 签名、Apple Notarization、应用内更新；暂不依赖 Mac App Store。

## 2. 已确认的核心理念

Lumos 的核心不是“判断 Mac 还能不能休息”，而是平衡两个天然矛盾的目标：

1. 任务必须持续，Mac 不能休眠；
2. 持续唤醒必须尽量低功耗，避免无意义耗电和发热。

产品定义：

> 在保证任务连续性的前提下，只保留必要的清醒，把功耗压到当前场景允许的最低水平。

用户表达：

> 不让任务睡着，也不让电脑白白醒着。

## 3. 已确认的产品模型

产品采用三层结构，不采用几个互斥的“大模式”。

### 3.1 工作信号 Signals

用户自定义关心的 App、PID、命令或集成，Lumos 判断：

- Running：进程存在；
- Working：正在执行需要保护的任务；
- Waiting：任务未结束，但正在等待网络、模型或批准；
- Finished：任务结束，可以撤销保护。

进程存在不等于任务正在工作。UI 必须展示实际采用的判断规则。

### 3.2 原子控制 Controls

- 防止显示器因空闲熄灭；
- 允许或立即熄屏；
- 防止空闲系统休眠；
- 低电量模式检测／切换；
- 内置显示器亮度；
- 网络可达与 Wake for network access；
- 高级合盖运行策略；
- 电池和 Thermal State 安全边界；
- 完成后恢复原系统设置。

这些能力的技术确定性不同。必须区分：直接支持、需要权限、需要验证、实验性能力。

### 3.3 场景预设 Presets

```text
Preset = Trigger
       + Watched Targets
       + Working Rule
       + Atomic Controls
       + Exit Condition
       + Safety Boundary
```

默认 Presets：

- 任务守护；
- 随时可达；
- 长时导出／渲染；
- 移动守护；
- 保持亮屏。

用户可以展开查看和修改 Preset 使用的原子控制，并另存为自定义 Preset。

## 4. 菜单栏交互方向

菜单栏图标采用“灯芯＋光环”：

- 灯芯表示关注对象是否 Working；
- 光环表示 Lumos 是否正在防休眠或保持可达；
- 缺口／警示点表示电量、温度或能力降级。

菜单展开后的信息顺序：

1. 当前状态：一句话解释正在做什么；
2. 正在关注：App、进程及其 Working 状态；
3. Presets：一键场景方案；
4. 高级控制：可独立调节的原子开关；
5. 电池、功耗、温度与能力降级说明。

可靠感来自可解释，温暖感来自不过度打扰。示例文案：

- `Lumos 正在为 Screen Studio 留灯。`
- `Agent 正在等待回复，连接仍然保持。`
- `没有任务正在计算，但你的 Mac 仍可从手机找到。`
- `所有关注任务已经完成，Mac 恢复原来的休眠设置。`

## 5. 技术边界

已经确认的原则：

- IOKit 可以分别请求防止显示器空闲休眠和防止系统空闲休眠；这些断言仍可被低电量或热紧急状态覆盖。
- NSWorkspace 可以获得运行中 App；PID、子进程、CPU/I/O/网络活动需要独立观察层。
- ProcessInfo 可以读取低电量模式和 Thermal State。
- 切换系统低电量模式、立即熄屏、亮度控制需要验证实现方式与权限。
- Wake for network access 主要面向共享资源，不保证任意 App 都能在睡眠后被远程连接唤醒。
- 电池合盖持续运行必须按 Mac 型号和 macOS 版本建立支持矩阵，不能无条件承诺。
- 软件无法同时保证密闭书包、持续高负载、接近零功耗和完全不发热。

## 6. MVP 优先级

### P0

- SwiftUI/AppKit 原生菜单栏骨架；
- 灯芯＋光环状态模型；
- 添加关注 App、PID 和命令；
- Running / Working / Waiting / Finished 状态；
- 防止息屏与防止空闲系统休眠；
- 任务守护、随时可达、保持亮屏 Presets；
- 电池、低电量状态与 Thermal State；
- 完成后撤销控制；
- 崩溃与重启后的状态恢复；
- Developer ID、Notarization 与自动更新方案。

### P1

- 低电量模式切换；
- 亮度和立即熄屏；
- 长时导出与移动守护；
- ChatGPT/Codex 和 Screen Studio 深度集成；
- CLI、URL Scheme、本地 API；
- 功耗基线和节能效果报告。

## 7. 相关文件

- `docs/Lumos-PRD-v0.2.md`：当前产品需求文档；
- `docs/Agent时代我们重新设计了Mac的休眠机制.md`：产品理念文章；
- `visuals/mac-agent-six-levels.html`：六级场景模型；
- `visuals/mac-wake-lease-product.html`：早期菜单栏交互概念；
- `visuals/images/`：历史、产品情绪与人机共生插画。

早期界面稿仍使用过 `Lease` 字样的结构概念；产品名已经最终确定为 Lumos，后续设计必须统一。

## 8. 本地 Codex 的第一项任务

不要立即实现完整产品。先完成一次技术可行性 Spike：

1. 检查目标 macOS 版本与 Apple Silicon 范围；
2. 验证两类 IOPM Assertion 的独立行为；
3. 验证运行中 App、PID 和子进程观察；
4. 验证 Low Power Mode 与 Thermal State 的读取；
5. 研究低电量模式切换、立即熄屏、亮度和合盖运行所需权限；
6. 给出能力矩阵：`direct / permission / experimental / unsupported`；
7. 根据验证结果，提出最小 SwiftUI/AppKit 架构和两周 MVP 计划；
8. 在用户确认技术边界前，不宣传“合盖必定可用”或“完全不发热”。

## 9. 建议交给 Codex 的首条指令

```text
请阅读 HANDOFF.md 和 docs/Lumos-PRD-v0.2.md，接手 Lumos 项目。

先不要实现完整 App。请执行“技术可行性 Spike”：核实 macOS 电源断言、进程观察、Low Power Mode、Thermal State、熄屏、亮度、网络可达与电池合盖运行的能力及权限边界；输出一份有验证方法和最小实验代码的技术方案。

完成调研后，给出能力矩阵、风险、推荐技术架构与两周 MVP 计划。不要把私有 API 或机型相关行为描述为稳定公开能力。
```

## 10. 协作规则

- 先阅读现有文件，不要重新发明产品定义；
- 修改 PRD 时保留决策背景和版本号；
- 技术结论必须附验证方法；
- 用户已有文件和改动不得覆盖；
- 任何需要管理员权限、特权 Helper 或私有 API 的方案必须单独标记；
- 优先构建可验证的最小实验，再决定正式架构。

