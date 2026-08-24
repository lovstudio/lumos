# Lumos 合盖守护事实核验

检索与实测日期：2026-08-24

## 结论

“macOS 公共 IOPM Assertion 不能阻止合盖休眠”成立；“因此 Lumos 无法实现合盖守护”不成立。

管理员级系统设置 `pmset -a disablesleep 1` 构成了可工作的反例，但它不是普通 App
可直接持有的公开 power assertion：它修改全局设置、需要 root 权限、会影响所有系统休眠，
并且 `disablesleep` 没有出现在当前 `pmset(1)` 手册的稳定设置列表中。因此 Lumos 将其定义为
`permission + experimental`，而不是 `direct`。

## 更精确的说法

Lumos 可以提供“防止合盖休眠（实验性）”，但必须同时满足：

1. 用户明确开启并完成 macOS 管理员授权；
2. 启用后回读到真实的 `SleepDisabled=1`，否则不得显示成功；
3. 只恢复 Lumos 自己开启的设置，不接管其他工具已有的全局状态；
4. 用独立 root watchdog 在 App 退出、崩溃、超时或电量低于安全线时恢复
   `pmset -a disablesleep 0`；
5. UI 明确说明密闭环境、持续负载、热状态与跨版本兼容风险。

## 证据链

1. `[一手]` Apple Xcode SDK `IOPMLib.h`：
   `PreventUserIdleSystemSleep` 的合同明确写明系统仍可因 lid close、Apple 菜单、低电量等原因休眠；
   `PreventUserIdleDisplaySleep` 也明确允许因关闭便携 Mac 上盖而熄屏。
   对应在线入口：[Apple IOPM Assertion Types](https://developer.apple.com/documentation/iokit/iopmlib_h/iopmassertiontypes)。
2. `[一手]` [Apple Support：Allow accessories to connect](https://support.apple.com/en-ie/102282)：
   Apple Silicon 官方闭盖使用依赖已允许的外接显示器、鼠标和键盘；这不能覆盖“仅电池、无外显”的移动场景。
3. `[一手]` [Apple Support：M3 双外显闭盖要求](https://support.apple.com/en-gb/117373)：
   指定场景还要求外接输入设备、对应 macOS 版本和供电。
4. `[实测]` MacBook Pro `Mac15,6`、Apple M3 Pro、macOS 26.6：
   `IOPMrootDomain` 与 `pmset -g` 均回读到 `SleepDisabled=1`；非 root 执行修改命令输出
   “must be run as root”。当前状态在 Lumos 实现前已经存在，因此属于外部所有权，不能由 Lumos 关闭。
5. `[准一手]` [macowl 源码](https://github.com/rgcsekaraa/macowl/blob/main/main.swift)：
   公开实现使用 `NSAppleScript` 管理员授权执行 `pmset -a disablesleep`，并用 marker 处理崩溃恢复，
   证明“完全不能做”存在反例；同时也暴露了全局设置残留风险。
6. `[准一手]` [Amphetamine Enhancer](https://github.com/X74353/amphetamine-enhancer)：
   主项目之外需要非沙盒 helper 为 closed-display mode 提供 fail-safe，说明该能力跨越普通沙盒 App 边界。
7. `[一手]` [AppleScript `do shell script`](https://developer.apple.com/library/archive/documentation/AppleScript/Conceptual/AppleScriptLangGuide/reference/ASLR_cmds.html)：
   `with administrator privileges` 是 Apple 文档提供的一次性管理员授权路径；授权成功不替代
   `pmset -g` 的执行后回读。
8. `[一手]` [Apple Service Management](https://developer.apple.com/documentation/servicemanagement/smappservice)：
   正式发行版若需要常驻 root helper，应使用 app bundle 内的 `SMAppService` LaunchDaemon 并由用户批准。

## 反例与边界

- 官方外显闭盖模式是系统支持场景，不等于 App 可以任意关闭 lid sleep。
- `pmset disablesleep` 会阻止所有系统休眠，不只合盖休眠；普通 IOPM assertion 没有这个副作用。
- 该 flag 是全局、无引用计数的；多个工具同时控制时无法可靠判断最后一个使用者。
- 当前系统手册没有把 `disablesleep` 列为稳定设置项，未来 macOS 可能改变语义或移除它。
- 管理员授权不是能力证明；执行后必须回读 `SleepDisabled`。
- 软件不能保证密闭包内持续高负载安全。Lumos 的 thermal 降级、超时和低电量回退只能降低风险，
  不能替代通风与用户判断。

## 置信度

- 公开 IOPM assertion 不覆盖 lid close：高。Apple SDK 直接说明。
- 当前 macOS 26.6 支持 `pmset disablesleep` 且需要 root：高。本机直接回读和权限实测。
- 该路径能跨所有 Apple Silicon 与未来 macOS 稳定工作：中低。缺少 Apple 的稳定公开合同，仍需机型矩阵。

## 实现决策

当前开发版采用一次性管理员授权加临时 root watchdog，不安装持久 sudoers 规则，也不把外部
`SleepDisabled=1` 当成 Lumos 所有。正式签名 `.app` 发布前，再将权限层迁移到经过代码签名校验、
命令白名单和 XPC 协议约束的 `SMAppService` helper。
