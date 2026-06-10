# 悬屿宣传片

输出文件：

- `dist/xuanyu-promo.mp4`：30 秒白色苹果风横版宣传片，1920x1080，H.264。
- `dist/checks/`：关键时间点检查帧。

素材来源：

- `assets/raw/`：Computer Use 点击真实应用后，用窗口 ID 截取的原始窗口图。
- `public/shots/`：Remotion 使用的截图素材。
- `public/audio/`：Remotion 使用的音频素材。`3-strikes.*` 不随仓库发布，请在本地自行放入同名音频后渲染。

工程入口：

- `src/Root.tsx`：Remotion 成片。
- `landing/index.html`：旧版宣传网页。
- `hyperframes/index.html`：HyperFrames + GSAP 动态分镜源文件。
- `DESIGN.md`：视觉规则。

复现：

```bash
/opt/homebrew/bin/npm install
/opt/homebrew/bin/npm run render
```

验证：

```bash
/opt/homebrew/bin/npm exec tsc -- --noEmit
/opt/homebrew/bin/npm exec --yes hyperframes -- lint hyperframes
```
