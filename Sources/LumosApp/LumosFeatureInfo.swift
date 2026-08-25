import SwiftUI

struct LumosFeatureInfo: Equatable {
    let title: String
    let markdown: String
}

enum LumosFeatureInfoCatalog {
    static let guardedApplications = LumosFeatureInfo(
        title: "守护 App",
        markdown: """
        ## 功能解释
        选择不能因 Mac 空闲休眠而中断的 App。Lumos 会观察这些 App 是否正在运行，并自动决定何时开始或结束守护。

        ## 实现逻辑
        - 使用 NSWorkspace 读取运行中的 App。
        - 结合 **PID 与启动时间** 区分不同进程实例，避免 PID 复用造成误判。
        - 首个守护 App 出现时申请必要的唤醒能力；最后一个退出后自动释放。

        ## 注意事项
        > 检测到 App 正在运行，不等于 Lumos 已理解 App 内部任务是否正在工作。

        - 未选择任何 App 时，已开启的控制会立即生效，直到手动关闭。
        - 当前只观察本机进程，不上传 App 列表或进程状态。
        """
    )

    static let addGuardedApplication = LumosFeatureInfo(
        title: "添加守护 App",
        markdown: guardedApplications.markdown
    )

    static let keepTaskRunning = LumosFeatureInfo(
        title: "保持任务运行",
        markdown: """
        ## 功能解释
        防止 Mac 因长时间无人操作而进入系统空闲休眠，让下载、构建、Agent 和导出任务继续运行；显示器仍可按系统设置熄灭。

        ## 实现逻辑
        - 通过公开 IOKit 能力申请 **PreventUserIdleSystemSleep** 断言。
        - 多个功能共享同一类系统断言，最后一个使用者结束后才释放。
        - 有守护 App 时按 App 生命周期自动启停。

        ## 注意事项
        - 这是对 macOS 的空闲休眠请求，不会阻止用户主动睡眠。
        - 低电量、严重过热等安全状态仍可覆盖请求。
        - 公开空闲断言不能保证合盖后继续运行。
        """
    )

    static let keepDisplayAwake = LumosFeatureInfo(
        title: "保持屏幕唤醒",
        markdown: """
        ## 功能解释
        防止显示器因闲置自动熄灭，适合演示、阅读、监控面板或需要持续可见的任务。

        ## 实现逻辑
        - 通过公开 IOKit 能力申请 **PreventUserIdleDisplaySleep** 断言。
        - 与“保持任务运行”独立管理，可单独开启或关闭。
        - 关闭后立即释放 Lumos 持有的显示器断言。

        ## 注意事项
        - 持续亮屏会明显增加耗电。
        - 用户主动锁屏、关闭显示器或系统安全策略仍可覆盖该请求。
        """
    )

    static let clamshellProtection = LumosFeatureInfo(
        title: "合盖时保持运行",
        markdown: """
        ## 功能解释
        在限定时间和安全边界内，请求 Mac 合盖后继续运行任务。

        ## 实现逻辑
        - 通过受限的特权辅助程序执行系统 pmset disablesleep 控制。
        - 写入后回读 **SleepDisabled** 真实状态，只有确认成功才显示为开启。
        - Lumos 记录本次控制归属，并用超时、电量、温度和退出恢复机制撤销设置。

        ## 注意事项
        > 这是需要管理员授权的实验性能力，不是 Apple 公共 API 对所有机型和系统版本的稳定保证。

        - 合盖和密闭环境会降低散热能力。
        - 高负载时应保持通风，不建议放入密闭包内持续运行。
        - 如果状态并非本次 Lumos 控制，界面只陈述真实状态，不推断来源。
        """
    )

    static let clamshellDuration = LumosFeatureInfo(
        title: "最长持续时间",
        markdown: """
        ## 功能解释
        限制一次合盖守护最多持续多久，避免忘记关闭后长期保持系统睡眠禁用状态。

        ## 实现逻辑
        - 开启合盖守护时同时启动本地 watchdog。
        - 到达时限后撤销 Lumos 持有的合盖设置并恢复系统默认行为。
        - 修改时限会重新建立当前 Lumos 会话的安全边界。

        ## 注意事项
        - 最短 30 分钟，最长 8 小时。
        - App 自身退出时也会尝试提前恢复，不会等待计时结束。
        """
    )

    static let batteryFloor = LumosFeatureInfo(
        title: "电池安全线",
        markdown: """
        ## 功能解释
        设置电池供电时允许合盖守护继续运行的最低电量。

        ## 实现逻辑
        - 使用 macOS 电源来源接口持续回读供电方式和电池百分比。
        - 仅在电池供电时应用该阈值；接通电源或 UPS 时不会套用电池下限。
        - 达到安全线后结束高风险合盖控制，并保留可解释的状态。

        ## 注意事项
        - 电池百分比无法可靠读取时，Lumos 不会把未知状态当作安全。
        - 该阈值只约束 Lumos 的控制，不能限制其他 App 的耗电。
        """
    )

    static let lowPowerMode = LumosFeatureInfo(
        title: "低功耗模式",
        markdown: """
        ## 功能解释
        直接切换 macOS 当前电源来源对应的低功耗模式，减少后台活动和部分性能消耗。

        ## 实现逻辑
        - 根据当前是接通电源、电池还是 UPS，选择对应的 pmset 范围。
        - 通过受限的特权辅助程序执行切换。
        - 写入后重新读取系统状态；只有真实状态一致才视为成功。

        ## 注意事项
        - 切换时可能需要管理员授权。
        - 只修改当前电源来源，不覆盖另一种电源来源的既有策略。
        - 低功耗模式的具体效果由 macOS、机型和任务负载决定。
        """
    )

    static let displaySleepNow = LumosFeatureInfo(
        title: "立即关闭显示器",
        markdown: """
        ## 功能解释
        立即让显示器进入休眠，任务是否继续运行由“保持任务运行”等控制决定。

        ## 实现逻辑
        - 调用 macOS 自带的 pmset displaysleepnow。
        - 命令结果和错误信息会被真实回读并显示。
        - 移动鼠标或按下键盘可重新点亮显示器。

        ## 注意事项
        - 这是一次性操作，不会修改系统的自动熄屏时间。
        - 如果同时开启“保持屏幕唤醒”，系统行为可能受两项请求的时序影响。
        """
    )

    static let guardStatus = LumosFeatureInfo(
        title: "守护状态",
        markdown: """
        ## 功能解释
        汇总本次守护的持续时间、当前匹配的进程数量和能耗对比状态。

        ## 实现逻辑
        - 守护时长从系统断言真实生效时开始计算。
        - 运行中目标按守护 App 的进程实例数量统计。
        - 电源、温度、网络和安全降级来自系统实时回读。

        ## 注意事项
        - “运行中目标”表示进程存在，不等于内部任务正在计算。
        - 能耗变化需要同一设备、同一负载的可靠基准；基准完成前显示“暂无基准”。
        """
    )

    static let thermalState = LumosFeatureInfo(
        title: "温度与低功耗状态",
        markdown: """
        ## 功能解释
        展示 macOS 当前热状态，并在系统过热时降低或停止高风险守护能力。

        ## 实现逻辑
        - 通过 ProcessInfo 读取 Low Power Mode 与 Thermal State。
        - 监听系统状态变化，并根据风险调整轮询频率。
        - 严重或临界热状态可撤销显示器、合盖或系统唤醒请求。

        ## 注意事项
        - macOS 提供的是分级状态，不是具体温度数值。
        - Lumos 的保护不能替代良好通风和正常使用环境。
        """
    )

    static let powerSource = LumosFeatureInfo(
        title: "电源与电池",
        markdown: """
        ## 功能解释
        显示当前供电方式、电池电量和充电状态，为低电量保护与合盖安全线提供依据。

        ## 实现逻辑
        - 通过 IOPowerSources 读取 AC、电池或 UPS 状态。
        - 根据实时供电来源选择对应的低功耗控制范围。
        - 电池供电时参与安全边界计算。

        ## 注意事项
        - 系统暂时无法返回电池数据时会明确显示未知，不会推断数值。
        - 外接电源不代表任务一定处于安全散热环境。
        """
    )

    static let networkState = LumosFeatureInfo(
        title: "网络状态",
        markdown: """
        ## 功能解释
        显示当前网络是否可达、受限或属于计费网络，帮助判断远程连接和在线任务的环境。

        ## 实现逻辑
        - 使用 NWPathMonitor 持续监听系统网络路径。
        - 网络变化会更新状态说明，但不会把短暂断网误判为本地任务结束。
        - 守护逻辑仍以本地 App 和进程状态为主。

        ## 注意事项
        - 网络可达不等于某个服务端点一定可用。
        - “网络访问唤醒”也不能保证任意 App 在系统睡眠后都能被远程唤醒。
        """
    )

    static let energyComparison = LumosFeatureInfo(
        title: "能耗对比",
        markdown: """
        ## 功能解释
        用一致的硬件和任务负载，对比 Lumos 守护策略与基准状态的能耗变化。

        ## 实现逻辑
        - 需要固定设备、供电方式、任务和采样时长。
        - 只有建立可重复基准后才计算差异。
        - 当前尚未完成可靠基准，因此显示“暂无基准”。

        ## 注意事项
        > 没有统一实验条件时，单次电量变化不能作为节能结论。

        - 屏幕亮度、网络、温度和第三方任务都会影响结果。
        """
    )
}

struct LumosInfoButton: View {
    let info: LumosFeatureInfo

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: isPresented ? "info.circle.fill" : "info.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isPresented ? Color.accentColor : Color.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(info.title)说明")
        .accessibilityValue(isPresented ? "说明已打开" : "点击查看说明")
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            LumosFeatureInfoPopover(info: info)
        }
    }
}

private struct LumosFeatureInfoPopover: View {
    let info: LumosFeatureInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(Color.accentColor)
                Text(info.title)
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            Divider()

            ScrollView {
                LumosMarkdownView(markdown: info.markdown)
                    .padding(16)
            }
            .frame(maxHeight: 390)
        }
        .frame(width: 360)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct LumosMarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private var blocks: [MarkdownBlock] {
        MarkdownBlock.parse(markdown)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inlineMarkdown(text))
                .font(headingFont(level))
                .padding(.top, level == 2 ? 2 : 0)
        case .paragraph(let text):
            Text(inlineMarkdown(text))
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 4, height: 4)
                Text(inlineMarkdown(text))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 3)
        case .numbered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number).")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(minWidth: 16, alignment: .trailing)
                Text(inlineMarkdown(text))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor.opacity(0.7))
                    .frame(width: 3)
                Text(inlineMarkdown(text))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 9)
            .background(Color.accentColor.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        case .divider:
            Divider()
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title3.weight(.bold)
        case 2: .headline
        default: .subheadline.weight(.semibold)
        }
    }

    private func inlineMarkdown(_ source: String) -> AttributedString {
        (
            try? AttributedString(
                markdown: source,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
        ) ?? AttributedString(source)
    }
}

private enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(String)
    case numbered(number: Int, text: String)
    case quote(String)
    case divider

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        markdown
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { rawLine in
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { return nil }
                if line == "---" || line == "***" {
                    return .divider
                }
                if line.hasPrefix("### ") {
                    return .heading(level: 3, text: String(line.dropFirst(4)))
                }
                if line.hasPrefix("## ") {
                    return .heading(level: 2, text: String(line.dropFirst(3)))
                }
                if line.hasPrefix("# ") {
                    return .heading(level: 1, text: String(line.dropFirst(2)))
                }
                if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    return .bullet(String(line.dropFirst(2)))
                }
                if line.hasPrefix("> ") {
                    return .quote(String(line.dropFirst(2)))
                }
                if let numbered = parseNumbered(line) {
                    return numbered
                }
                return .paragraph(line)
            }
    }

    private static func parseNumbered(_ line: String) -> MarkdownBlock? {
        guard let period = line.firstIndex(of: "."),
              period != line.startIndex,
              let number = Int(line[..<period])
        else {
            return nil
        }
        let contentStart = line.index(after: period)
        let content = line[contentStart...].trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return nil }
        return .numbered(number: number, text: content)
    }
}
