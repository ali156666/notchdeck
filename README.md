# 悬屿

<p align="center">
  <strong>把 MacBook 顶部变成一个轻量、常驻、可操作的工作入口。</strong>
</p>

<p align="center">
  官网地址：<a href="https://notchdeck.xyz/">https://notchdeck.xyz/</a>
  <br>
  API 推荐：<a href="https://shop.xuedingtoken.com/?dist=KDLDYHBS">https://shop.xuedingtoken.com/?dist=KDLDYHBS</a>
</p>

<p align="center">
  <img src="./Xuanyu/docs/images/hero.png" alt="悬屿官网首屏截图" width="860">
</p>

悬屿是一个 macOS 顶栏悬浮面板应用。它贴着 MacBook 顶部运行，把音乐控制、AirPods 电量、剪贴板、快捷启动、系统看板、番茄钟和本地 Agent 收在一个干净入口里。

## 功能

- 贴合 MacBook 刘海区域的展开/收起面板
- Apple Music 与 Spotify 播放控制、歌词展示和 AirPods 电量读取
- 收起状态歌词悬浮展示
- 快捷应用启动、剪贴板历史、系统看板、天气、日历与番茄钟
- 独立 Node Agent runtime
- OpenAI-compatible 与 Anthropic-compatible 模型接口
- 应用内配置模型、API key、自定义 skills 和本地 MCP servers
- 工具调用确认、文件上传、桌面文件拖入识别和附件对话

## 截图

| 系统看板 | 剪贴板 |
| --- | --- |
| <img src="./Xuanyu/docs/images/dashboard.png" alt="系统看板" width="420"> | <img src="./Xuanyu/docs/images/clipboard.png" alt="剪贴板历史" width="420"> |

| 音乐控制 | 歌词悬浮 |
| --- | --- |
| <img src="./Xuanyu/docs/images/music.png" alt="音乐控制" width="420"> | <img src="./Xuanyu/docs/images/lyrics-floating.png" alt="歌词悬浮" width="420"> |

## 快速开始

### 环境要求

- macOS 14 或更新版本
- Xcode Command Line Tools
- Node.js 18 或更新版本

### 从源码运行

```bash
git clone https://github.com/ali156666/notchdeck.git
cd notchdeck/Xuanyu
./build.sh
```

### 打包 DMG

```bash
cd Xuanyu
./scripts/package-dmg.sh
```

输出文件位于 `Xuanyu/dist/`。DMG 内包含 `使用说明.txt`，其中写了首次打开、权限授权、打不开和音乐连接失败的处理办法。

## 项目结构

```text
.
├── Xuanyu/              # macOS 应用源码、Agent runtime、README 和打包脚本
├── promo/               # 官网与宣传素材
└── script/              # 本地辅助脚本
```

## 交流与赞赏

QQ 交流群：`782676841`

<p>
  <img src="./Xuanyu/docs/images/donate.jpg" alt="星忆的赞赏码" width="260">
</p>

## 许可证

本项目使用 MIT License。见 [LICENSE](./LICENSE)。

## 友情链接

- [LINUX DO](https://linux.do/)
