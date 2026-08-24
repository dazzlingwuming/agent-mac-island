# Agent Mac Island

这是我基于
[Open Island](https://github.com/Octane0411/open-vibe-island)
制作的 macOS 个人修改版。这个版本主要解决一个问题：平时不要让灵动岛一直占着屏幕顶部，
真正有通知或者我主动悬停时再出现。

**简体中文** | [English](README.md)

> [!IMPORTANT]
> 这不是我原创的项目，也不是 Open Island 的官方版本。原项目由
> [Octane0411](https://github.com/Octane0411) 及
> [原项目贡献者](https://github.com/Octane0411/open-vibe-island/graphs/contributors)
> 创作和维护。我只维护下方列出的修改内容。完整来源与授权说明见
> [FORK_NOTICE.md](FORK_NOTICE.md)。

## 界面预览

**展开后的会话总览**

![Agent Mac Island 在当前工作区顶部展开，显示运行中和空闲的 Codex 会话](images/session-overview.png)

**本地空闲记录清理**

![Agent Mac Island 的空闲会话列表，每条记录右侧都有单独的清理按钮](images/idle-record-cleanup.png)

## 我为什么修改这个版本

上游 v1.1.6 在鼠标离开后，会把面板收成顶部的小胶囊，但小胶囊仍会一直显示，例如：

```text
••• Codex ×7
```

我的目标是把它改成“通知驱动”的使用方式：

- 空闲时顶部完全干净，不保留常驻小胶囊；
- 隐藏区域不能影响 Chrome、PyCharm 或菜单栏区域的点击；
- 在多个 macOS Space 和全屏窗口中仍然可以唤醒；
- Codex 完成、失败、请求权限或等待回答时自动出现；
- 可以手动清理长期堆积的本地空闲记录；
- UI 隐藏不等于退出，后台监控和 bridge 必须继续运行。

## 我改了什么

| 修改项 | 这个版本的行为 |
|---|---|
| 自动隐藏开关 | 在“设置 → 通用 → 行为”中增加持久化的“自动隐藏（悬停或通知时显示）”开关。默认关闭，保留上游原有行为。 |
| 空闲时完全隐藏 | 开启自动隐藏后，不再留下顶部小胶囊。窗口视觉上完全透明并允许点击穿透，但 App、hooks、会话监控和 bridge socket 继续运行。 |
| 只允许悬停唤醒 | 鼠标在屏幕顶部中央连续停留约 **1.5 秒**后打开。点击隐藏触发区域不会唤醒，还会取消尚未完成的悬停计时。 |
| 延迟隐藏 | 鼠标离开后等待约 **1.5 秒**再隐藏；在倒计时内重新进入会取消隐藏。 |
| 跨 Space 和全屏 | 隐藏时不再对 `NSPanel` 调用 `orderOut`，而是保持窗口 ordered，并保留 `.canJoinAllSpaces` 与 `.fullScreenAuxiliary`，解决切换 Space 后无法再次唤醒的问题。 |
| 通知自动出现 | Codex 完成、失败、请求权限、等待回答等事件可以在隐藏状态下自动显示。普通通知约 10 秒后关闭；权限和问题卡片在处理前不会自动消失。 |
| Codex 用量速度提醒 | 只保存本地聚合后的额度百分比和时间戳，判断 7 天额度是否消耗过快；偏快时临时弹出琥珀色、橙色或红色 Island，显示今日增量、最近速度、重置时间和轻量模型建议。关闭后的顶部不会留下警告颜色。 |
| Codex `/plan` 提问 | 识别 Codex rollout JSONL 中当前格式的 `request_user_input`，完整展示问题和选项，并提供“返回 Codex”。由于该事件没有回答 hook，答案仍在 Codex 中提交；Codex 继续运行后通知自动解除。 |
| 本地空闲记录清理 | 空闲会话行增加单条清理入口，列表顶部增加批量清理入口。清理只影响 Island 的展示记录，不删除原始 Agent 会话，也不会终止进程。 |
| 清理状态持久化 | 已清理的空闲记录在 App 重启后仍保持隐藏；同一会话出现新活动时会自动重新显示。 |
| 超大 rollout 性能 | 冷启动发现超大 Codex JSONL 时只读取有界的头部元数据与尾部当前状态，之后只处理新增字节；重新发现采用 single-flight，避免多个扫描重叠占满 CPU。 |
| 三语文案 | 补充和调整 English、简体中文、繁体中文的自动隐藏与空闲清理文案。 |
| 开发启动脚本 | 本机没有 Pillow 时，`scripts/launch-dev-app.sh` 可以直接使用仓库中已提交的图标继续构建和启动。 |
| Smoke/Harness 验证 | 增加隐藏视觉状态与 ordered 状态分离、点击穿透、悬停计时、延迟隐藏取消、通知打断隐藏、需要操作的通知和空闲清理等场景。 |

## 现在的实际行为

| 场景 | 结果 |
|---|---|
| 关闭自动隐藏 | 保留原来的常驻小胶囊行为。 |
| 开启自动隐藏且当前空闲 | UI 完全不可见，也不会拦截鼠标点击。 |
| 顶部中央悬停约 1.5 秒 | 手动打开 Island。 |
| 点击隐藏状态下的顶部中央 | 点击继续交给下面的应用，Island 不会出现。 |
| Codex 完成或失败 | 通知自动出现，普通通知展示结束后自动隐藏。 |
| Codex 7 天用量增加到新的整数百分点 | 当前百分点弹出一次彩色提醒；速度越快颜色越醒目，鼠标停留在卡片上时暂停关闭。 |
| Codex 请求权限或等待回答 | 通知持续显示，直到用户完成处理。 |
| Codex `/plan` 调用 `request_user_input` | Island 完整显示问题与选项；点击“返回 Codex”并在那里作答，Codex 继续运行后通知自动解除。 |
| 切换桌面、PyCharm 全屏或 Chrome 全屏 Space | 仍然可以在当前 Space 悬停唤醒或接收通知。 |
| Island UI 已隐藏 | App、hooks、session monitoring 和 `OpenIsland/bridge.sock` 继续运行。 |

## 如何安装和使用

### 环境要求

- macOS 14 或更高版本
- 安装包含 Swift 6.2 或更高版本的 Xcode

### 启动开发版

```bash
git clone https://github.com/dazzlingwuming/agent-mac-island.git
cd agent-mac-island
zsh scripts/launch-dev-app.sh
```

脚本会构建并启动：

```text
~/Applications/Open Island Dev.app
```

### 开启自动隐藏

进入：

```text
Open Island 设置 → 通用 → 行为
```

开启：

```text
自动隐藏（悬停或通知时显示）
```

这个设置会在退出并重新启动后保留，默认值仍然是关闭。

### Codex 用量速度提醒

用量速度提醒默认开启，位置是：

```text
Open Island 设置 → 通用 → 行为 → Codex 用量速度提醒
```

本地历史只保存聚合后的额度百分比、窗口长度、重置时间和提醒去重状态，
不会保存 prompt、会话正文或项目路径。

普通 7 天额度每增加一个整数百分点都会弹出提醒。如果两次采样之间跨过多个百分点，
只弹出一张卡片汇总本次变化；卡片若在实际可见约两秒前被关闭或替换，下次刷新会重试。

### 清理本地空闲记录

展开会话列表后：

- 点击某条空闲记录右侧的垃圾桶，可以只清理这一条；
- 点击列表顶部带数量的垃圾桶，可以确认后批量清理全部符合条件的本地空闲记录。

清理不会终止 Agent、删除原始会话或停止后台进程。会话产生新活动时会自动重新出现。

## 验证方式

这个修改版使用项目原有测试框架并补充了对应的 smoke/harness 场景：

```bash
swift build --product OpenIslandApp
zsh scripts/harness.sh smoke
zsh scripts/harness.sh smoke-all
```

验证范围包括：完全隐藏、透明窗口点击穿透、跨 Space、1.5 秒悬停、离开延迟隐藏、
通知自动显示、权限/问题卡片不超时、独立的 Codex 用量速度提醒，以及隔离环境中的空闲记录清理。

源码中继续保留上游技术文档索引 [docs/index.md](docs/index.md)，用于查询架构和维护资料。

## 当前范围

这个仓库目前只支持 macOS。Windows 可以实现类似交互，但需要单独开发 Windows
窗口管理层，当前代码不能直接在 Windows 上运行。

原项目的完整功能列表、支持的 Agent/终端、架构、正式 Release 和社区信息，请查看：

[Octane0411/open-vibe-island](https://github.com/Octane0411/open-vibe-island)

## 原项目来源与许可证

- 原项目：
  [Octane0411/open-vibe-island](https://github.com/Octane0411/open-vibe-island)
- 原作者和贡献者：
  [原项目贡献者列表](https://github.com/Octane0411/open-vibe-island/graphs/contributors)
- 本修改版的具体改动：以本仓库保留的 Git 提交历史为准
- 完整修改版说明：[FORK_NOTICE.md](FORK_NOTICE.md)
- 许可证：[GNU GPL v3](LICENSE)

本修改版产生的问题不应归责于上游作者。修改版相关问题请提交到：

[`dazzlingwuming/agent-mac-island`](https://github.com/dazzlingwuming/agent-mac-island/issues)
