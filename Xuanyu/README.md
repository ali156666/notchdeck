# 悬屿

<p align="center">
  <strong>把 MacBook 顶部变成一个轻量、常驻、可操作的工作入口。</strong>
</p>

<p align="center">
  <a href="https://github.com/ali156666/notchdeck/releases/latest"><img alt="Release" src="https://img.shields.io/github/v/release/ali156666/notchdeck?display_name=tag&sort=semver"></a>
  <a href="../LICENSE"><img alt="License" src="https://img.shields.io/badge/license-MIT-green"></a>
  <img alt="macOS" src="https://img.shields.io/badge/macOS-26%2B-black">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-5.9-orange">
  <img alt="Node" src="https://img.shields.io/badge/Node.js-18%2B-339933">
</p>

<p align="center">
  <a href="#下载安装">下载安装</a>
  ·
  <a href="#快速开始">快速开始</a>
  ·
  <a href="#功能">功能</a>
  ·
  <a href="#开发">开发</a>
  ·
  <a href="#交流与赞赏">交流与赞赏</a>
  ·
  <a href="#贡献">贡献</a>
</p>

<p align="center">
  <a href="https://github.com/ali156666/notchdeck/releases/download/v1.0.27/NotchDeck-1.0.27.dmg"><strong>下载悬屿 v1.0.27</strong></a>
  ·
  <a href="https://github.com/ali156666/notchdeck/releases/latest">查看最新版本</a>
</p>

<p align="center">
  <img src="./docs/images/hero.png" alt="悬屿官网首屏截图" width="860">
</p>

悬屿是一个 macOS 顶栏悬浮面板应用。它贴着 MacBook 顶部运行，把音乐控制、AirPods 电量、剪贴板、快捷启动、系统看板、番茄钟、Command 语音输入和本地 Agent 收在一个干净入口里。当前版本面向 macOS 26+，界面采用 SwiftUI 原生 Liquid Glass：透明面板、玻璃卡片、柔和背景模糊和统一的语音输入 HUD。

<p align="center">
  官网地址：<a href="https://notchdeck.xyz/">https://notchdeck.xyz/</a>
  <br>
  API 推荐：<a href="https://shop.xuedingtoken.com/?dist=KDLDYHBS">https://shop.xuedingtoken.com/?dist=KDLDYHBS</a>
</p>

## 功能

### 顶栏面板

- 贴合 MacBook 刘海区域的展开/收起面板
- Dashboard、音乐、快捷应用、剪贴板、Agent 多模式切换
- macOS 26 原生 Liquid Glass 透明玻璃底板，保留桌面背景透光与轻微模糊
- 系统看板、剪贴板、快捷启动和媒体卡片使用统一玻璃卡片样式
- 收起状态下保留轻量提醒，不打断当前窗口

### 媒体与设备

- Apple Music 与 Spotify 播放状态读取
- 播放、暂停、上一首、下一首控制
- 当前歌词展示
- 收起状态歌词悬浮展示
- AirPods 左耳、右耳与充电盒电量读取

### 工作流

- 快捷启动常用应用
- 剪贴板历史面板
- 系统看板、天气、日历与番茄钟
- 专注/休息计时、暂停、重置和完成提醒

### Agent

- 编码会话监控：实时显示本机 Claude Code / Codex 会话状态，带像素吉祥物与 8-bit 音效
- 内置独立 Node Agent runtime，不依赖外部 CLI
- 分层长期记忆：有界热记忆 + 不限量的记忆笔记，索引常驻、正文按相关性召回
- 任务脚手架（Harness）：计划账本、重复调用检测、工具轮次预算、改完文件强制自检
- 多智能体编队：把独立子任务分给探路/执行/评审/验证/汇总五种角色的子 agent 并行或串行处理
- 工程师循环：实现 → 对抗性评审 → 带评审意见返工，直到通过或用完轮次
- 支持 OpenAI-compatible 与 Anthropic-compatible 模型接口
- 应用内配置模型、API key、自定义 skills 和本地 MCP servers
- 工具调用确认、文件上传、桌面文件拖入识别和附件对话
- 本地对话、记忆与会话管理
- 长按左右 Command 0.5 秒开始语音输入，松开后进入审核，确认后发送给 Agent
- 语音输入准备、录音、审核和发送状态使用与主面板一致的 Liquid Glass HUD
- 支持 Apple 语音识别与按需下载的离线 SenseVoice 本地语音模型

### 语音输入

- 长按左或右 Command 0.5 秒进入语音输入；短按 Command、`⌘C`、`⌘V`、`⌘Tab` 等组合键不会触发。
- 按住 Command 说话，松开后进入识别与审核；用户点击“发送”后，文本才会交给当前 Agent 会话。
- 默认使用 Apple 语音识别，适合中英混合输入，需要系统语音识别权限。
- 可在 Agent 设置中下载本地 SenseVoice 模型离线识别；模型约 239.5 MB，只需要麦克风权限。
- 录音、准备和审核状态都会显示 Liquid Glass 语音 HUD；识别失败、空文本或权限拒绝不会发送空任务。

### 编码会话监控（CodeWatch）

顶栏「编码」页列出本机所有运行中的 Claude Code / ChatGPT.app / Codex 会话：项目名、状态、当前工具、最近提问、模型、活跃时间。可使用按来源切换的 Clawd / Dex，也可从 `~/.codex/pets` 自选 Codex Pet；兼容 8×9 v1 和 8×11 v2 atlas。

两条数据通道汇进同一份会话表：

- **进程发现（零配置）**：扫描进程表找出 claude / codex 进程，也识别 `ChatGPT.app/Contents/Resources/codex` → 取其 cwd 或 rollout 元数据 → 定位对应 transcript（Claude 是 `~/.claude/projects/<编码后的cwd>/<session>.jsonl`，Codex/ChatGPT 是 `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`）→ 用 `DispatchSource` 尾随增量。装不装 hooks 都能看到会话
- **Hook 事件（可选，更实时）**：点「安装 Claude hooks」会往 `~/.claude/settings.json` 写入 10 个非阻塞 hook，hook 脚本用 `nc -U` 把事件发到 `/tmp/xuanyu-codewatch-<uid>.sock`。有了它才能看到「正在执行哪个工具」「等待审批/回答」这类实时状态

当 Claude Code 或 ChatGPT 正在执行时，缩小态直接显示运行来源和所选 Pet；任务从活跃转为完成时，悬屿显示完成提醒并发送 macOS 系统通知。编码页的铃铛和扬声器按钮分别控制系统完成通知与 8-bit 事件音效。

安装器有两条硬约束：**绝不安装 `PermissionRequest` hook**（那是审批拦截，悬屿只旁观不介入），以及 **`settings.json` 解析失败时拒绝写入**（宁可报错也不覆盖你的配置）。写入走最小 diff，你自己的 hooks 和键序原样保留，卸载时只摘掉悬屿这几条。

调试口：`/tmp/xuanyu-codewatch-status-<uid>.json` 是当前会话表的快照，可直接 `cat` 核对监控是否在工作。

本功能的会话状态机、transcript 尾随和像素吉祥物来自 [CodeIsland](https://github.com/wxtsky/CodeIsland)（MIT，Copyright (c) 2026 wxtsky），见 `Sources/CodeWatchCore/LICENSE.CodeIsland`。

### 长期记忆

记忆分成冷热两层，解决的是同一个问题：热记忆整块注入系统提示，所以必须有界，记满了只能删——冷存档把这个天花板拿掉了。

- **热记忆**：`memory/MEMORY.md` 和 `memory/USER.md`，每轮完整注入，有字符上限，放每次都用得上的短事实，由 `memory_manage` 维护
- **记忆笔记（冷存档）**：`memory/notes/*.md`，一条事实一个文件，条数不限。上下文里常驻的只有「名字 + 类型 + 描述」组成的索引，正文按当前问题的相关性召回

笔记带 frontmatter，类型分 `user` / `feedback` / `project` / `reference`，正文里写 `[[另一条笔记名]]` 即互相关联：

```markdown
---
name: pomodoro-length
description: 番茄钟默认时长是 45 分钟，不是 25
type: feedback
createdAt: 2026-07-27
updatedAt: 2026-07-27
---

用户要求番茄钟默认 45 分钟。

**Why:** 他的工作块是 45 分钟一段，25 分钟会打断心流。
**How to apply:** 改默认值时不要回退到 25；新增计时预设也以 45 为中心。
```

三个工具：`memory_write` 写入或更新一条笔记（`promote_from_memory` 可以顺手把一条写满的热记忆搬进冷存档）、`memory_recall` 按需取正文、`memory_forget` 删除确认错误的笔记。自动召回默认每轮最多带 3 条正文进上下文，走词面匹配（刻意不把单个汉字当匹配依据，否则「多久」会撞上「最多」）；`memory_recall` 则会叠加向量相似度，能召回用词不同但语义相关的笔记。

设置里可以关闭笔记层，或把自动召回条数调成 0，改由 agent 自己决定何时召回。

### Agent 脚手架与多智能体

Agent 循环外面套了一层脚手架（`AgentRuntime/src/harness.ts`），它做四件事：

- **计划账本**：多步任务先用 `update_plan` 立 3-7 步计划，每步的状态变化都会推到岛内显示；同一时刻只允许一个步骤处于进行中
- **重复调用检测**：同名同参的工具调用重复三次会被判定为原地打转，下一轮注入提示要求换路径
- **轮次预算**：用掉 70% 工具轮次后开始提醒收敛，用尽后强制给出不带工具的最终答复
- **收尾自检闸门**：本轮真正改过文件或跑过写命令时，在给最终答复前强制自检一次，每轮只注入一次

多智能体层（`AgentRuntime/src/subagents.ts`）提供两个工具：

- `dispatch_agents`：把彼此独立的子任务分给带角色的子 agent。`parallel` 模式并行跑（默认上限 3 个），`sequential` 模式让后一个 agent 看到前面所有报告
- `engineer_loop`：执行者改 → 评审者对着真实文件对抗性验收 → 未通过就带着评审意见再来一轮，最多 4 轮

五种角色的工具集是按职责裁剪的：探路者、评审者、汇总者只读；验证者能跑命令但不能改文件；只有执行者拿得到写工具。子 agent 一律不能再派发子 agent（深度锁一层），它们调用的危险工具仍然逐个弹权限确认，且确认框全局排队，不会互相覆盖。

这些能力都能在设置的「任务脚手架与多智能体」里单独开关。

## 截图

| 系统看板                                                           | 剪贴板                                                             |
| -------------------------------------------------------------- | --------------------------------------------------------------- |
| <img src="./docs/images/dashboard.png" alt="系统看板" width="420"> | <img src="./docs/images/clipboard.png" alt="剪贴板历史" width="420"> |
|                                                                |                                                                 |

| 音乐控制 | 歌词悬浮 |
| --- | --- |
| <img src="./docs/images/music.png" alt="音乐控制" width="420"> | <img src="./docs/images/lyrics-floating.png" alt="歌词悬浮" width="420"> |

| Agent 设置 |
| --- |
| <img src="./docs/images/agent-skills.png" alt="Agent skills 设置" width="420"> |

## 下载安装

1. 下载 [NotchDeck-1.0.27.dmg](https://github.com/ali156666/notchdeck/releases/download/v1.0.27/NotchDeck-1.0.27.dmg)。
2. 打开 DMG，把「悬屿.app」拖入「Applications」。
3. 首次启动时，在「应用程序」中按住 Control 点击「悬屿.app」，选择「打开」。
4. 悬屿是顶栏常驻应用，不会出现在 Dock；启动后在屏幕顶部中央展开它。

SHA-256 校验值和完整更新内容见 [v1.0.27 Release](https://github.com/ali156666/notchdeck/releases/tag/v1.0.27) 与仓库根目录的 [CHANGELOG.md](../CHANGELOG.md)。

## 快速开始

### 环境要求

- macOS 26 或更新版本
- Xcode 26 或匹配 macOS 26 SDK 的 Command Line Tools
- Node.js 18 或更新版本

### 从源码运行

```bash
git clone https://github.com/ali156666/notchdeck.git
cd notchdeck/Xuanyu
./build.sh
```

`build.sh` 会完成三件事：

- 构建 `AgentRuntime/dist/*.mjs`（runtime、memory、harness、subagents）
- 编译 Swift 应用
- 生成并启动 `dist/悬屿.app`

### 打包 DMG

```bash
./scripts/package-dmg.sh
```

生成的安装包位于 `dist/`。

## 配置

Agent 配置保存在本机应用支持目录：

```text
~/Library/Application Support/Xuanyu/agent/config.json
```

API key 由应用内 Agent 设置面板写入本机配置文件。这个文件不属于仓库内容。

## 权限

悬屿会按功能请求 macOS 权限：

| 权限 | 用途 |
| --- | --- |
| Apple Events | 读取和控制 Apple Music、Spotify |
| Bluetooth | 读取 AirPods 连接状态与电量 |
| Calendar | 在系统看板显示近期日程 |
| Location | 获取当前位置，用于天气信息 |
| Input Monitoring | 监听左右 Command 长按触发语音输入 |
| Microphone | 采集语音输入 |
| Speech Recognition | Apple 语音识别后端需要；本地 SenseVoice 不需要 |
| Network | 请求歌词、天气和模型接口 |

## 项目结构

```text
Xuanyu/
├── AgentRuntime/              # Node Agent runtime
├── Sources/Xuanyu/            # macOS Swift 应用源码
├── Sources/XuanyuApp/         # SwiftPM App 入口
├── Tests/XuanyuRegressionTests/      # 不依赖 XCTest 的回归测试可执行目标
├── Tests/SwiftPMPlaceholderTests/    # SwiftPM 占位测试目标
├── docs/                      # 设计和实现文档
├── scripts/                   # 打包脚本
├── Info.plist                 # App bundle 配置
├── Package.swift              # SwiftPM manifest
└── build.sh                   # 本地构建与运行脚本
```

## 开发

### Swift 应用

```bash
./build.sh                 # 推荐：自动处理下面两个环境问题
swift build
swift build -c release
```

只装了 Command Line Tools（没有完整 Xcode）时，直接 `swift build` 会遇到两个互相独立的问题，`build.sh` 已经自动绕开，手动构建时需要自己加参数：

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
    swift build --build-system native
```

- **`error: Multiple commands produce .../include/module.modulemap`**：SwiftPM 新的 swiftbuild 构建系统会把两个 binaryTarget 各自的 `Headers/module.modulemap` 拷进同一个 `include/` 目录。加 `--build-system native` 回到旧构建系统即可，与 SDK 无关。
- **`external macro implementation type 'SwiftUIMacros.StateMacro' could not be found`**：Command Line Tools 自带的 macOS 27 SDK 把 `@State` 改成了宏，而展开它需要的宏插件只随完整 Xcode 分发。用同一份 CLT 里自带的 macOS 26.x SDK 构建即可（`Package.swift` 的部署目标本来就是 macOS 26.0）。装了完整 Xcode 的话这条不需要。

### Agent runtime

```bash
cd AgentRuntime
npm test
```

### 测试

```bash
swift run XuanyuRegressionTests
```

当前仓库保留了 `SwiftPMPlaceholderTests` 作为 SwiftPM 测试占位；真实断言集中在 `XuanyuRegressionTests` 可执行目标里，避免本地 Command Line Tools 缺少 XCTest 时出现 `no such module 'XCTest'`。

## 常见问题

### 应用启动后没有出现在 Dock

悬屿是顶栏常驻应用，`Info.plist` 中启用了 `LSUIElement`，不会作为普通 Dock 应用显示。

### 音乐控制不可用

确认系统已经授权悬屿控制 Apple Music 或 Spotify。也可以在系统设置里重新打开自动化权限。

### AirPods 电量为空

确认 AirPods 已连接当前 Mac。部分 macOS 版本返回的蓝牙字段会延迟刷新，可以重新打开面板或等待系统更新蓝牙状态。

### Agent 无响应

先检查 Agent 设置里的模型地址和 API key，再运行：

```bash
cd AgentRuntime
npm test
```

### 长按 Command 没有进入语音输入

先确认系统设置里已经允许“输入监控”和“麦克风”。如果使用 Apple 后端，还需要允许“语音识别”；如果使用本地 SenseVoice 后端，请先在 Agent 设置里下载模型。

## 贡献

欢迎提交 issue 和 pull request。提交前请先跑：

```bash
swift build
swift build -c release
swift run XuanyuRegressionTests
(cd AgentRuntime && npm test)
```

适合优先贡献的方向：

- 更多 macOS 设备状态卡片
- 更稳定的 AirPods 状态解析
- Agent runtime 测试用例
- UI 细节、无障碍和多屏适配
- 文档、截图和安装说明

## 交流与赞赏

QQ 交流群：`782676841`

如果悬屿对你有帮助，可以请作者喝杯茶。

<p>
  <img src="./docs/images/donate.jpg" alt="星忆的赞赏码" width="260">
</p>

## 许可证

本项目使用 MIT License。见 [LICENSE](./LICENSE)。
