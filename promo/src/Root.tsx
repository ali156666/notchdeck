import React from "react";
import {
  AbsoluteFill,
  Composition,
  Easing,
  Img,
  interpolate,
  staticFile,
  useCurrentFrame,
  useVideoConfig,
} from "remotion";
import { Audio } from "@remotion/media";

const fps = 30;
const durationInFrames = 30 * fps;

const palette = {
  black: "#f5f5f7",
  ink: "#ffffff",
  text: "#1d1d1f",
  muted: "#6e6e73",
  dim: "#86868b",
  green: "#29c869",
  blue: "#3478f6",
  amber: "#f5a524",
};

type ShotName =
  | "collapsed"
  | "dashboard"
  | "music"
  | "quickapps"
  | "clipboard"
  | "agent-skills";

const shotFile: Record<ShotName, string> = {
  collapsed: "shots/collapsed.png",
  dashboard: "shots/dashboard.png",
  music: "shots/music.png",
  quickapps: "shots/quickapps.png",
  clipboard: "shots/clipboard.png",
  "agent-skills": "shots/agent-skills.png",
};

export const RemotionRoot: React.FC = () => (
  <Composition
    id="XuanyuPromo"
    component={AppleStylePromo}
    durationInFrames={durationInFrames}
    fps={fps}
    width={1920}
    height={1080}
  />
);

const AppleStylePromo: React.FC = () => {
  return (
    <AbsoluteFill style={{ backgroundColor: palette.black }}>
      <Audio
        src={staticFile("audio/3-strikes.mp3")}
        volume={(frame) =>
          interpolate(frame, [0, 24, durationInFrames - 36, durationInFrames], [0, 0.72, 0.72, 0], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
          })
        }
      />
      <Atmosphere />
      <TimelineLayer />
    </AbsoluteFill>
  );
};

const TimelineLayer: React.FC = () => {
  const frame = useCurrentFrame();

  return (
    <AbsoluteFill>
      <Intro frame={frame} />
      <Showcase
        frame={frame}
        start={90}
        end={240}
        shot="agent-skills"
        headline="本地 Agent"
        subline="常驻顶栏。"
        caption="Skills、MCP、文件拖入与确认流。"
        accent={palette.blue}
        scale={0.58}
        y={118}
      />
      <Showcase
        frame={frame}
        start={225}
        end={360}
        shot="dashboard"
        headline="所有状态"
        subline="一眼看见。"
        caption="系统、内存、天气、日程。"
        accent={palette.green}
        scale={0.74}
        y={60}
      />
      <Showcase
        frame={frame}
        start={345}
        end={480}
        shot="music"
        headline="音乐在播"
        subline="电量也在。"
        caption="歌词、进度、AirPods，贴着顶部走。"
        accent={palette.blue}
        scale={0.88}
        y={40}
      />
      <Showcase
        frame={frame}
        start={465}
        end={600}
        shot="quickapps"
        headline="常用 App"
        subline="一触即达。"
        caption="Finder、Chrome、Terminal，都收在岛里。"
        accent={palette.amber}
        scale={0.86}
        y={-240}
      />
      <Showcase
        frame={frame}
        start={585}
        end={750}
        shot="clipboard"
        headline="临时内容"
        subline="自动归档。"
        caption="文本、图片、文件，回填时不用再找。"
        accent={palette.green}
        scale={0.9}
        y={32}
        privacyMask
      />
      <Outro frame={frame} />
    </AbsoluteFill>
  );
};

const Atmosphere: React.FC = () => {
  const frame = useCurrentFrame();
  const drift = interpolate(frame, [0, durationInFrames], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  const glow = interpolate(Math.sin(frame / 52), [-1, 1], [0.62, 1]);

  return (
    <AbsoluteFill>
      <div
        style={{
          position: "absolute",
          inset: 0,
          background:
            "radial-gradient(ellipse at 50% -18%, rgba(255,255,255,0.98), transparent 38%), radial-gradient(ellipse at 50% 108%, rgba(210,214,222,0.52), transparent 40%)",
          opacity: glow,
        }}
      />
      <div
        style={{
          position: "absolute",
          inset: 0,
          background: "linear-gradient(180deg, rgba(255,255,255,0.92), rgba(245,245,247,0.96) 34%, rgba(232,235,240,0.54))",
        }}
      />
      <div
        style={{
          position: "absolute",
          inset: 0,
          background:
            "radial-gradient(circle at 18% 18%, rgba(52,120,246,0.10), transparent 24%), radial-gradient(circle at 84% 76%, rgba(41,200,105,0.10), transparent 26%)",
        }}
      />
      <div
        style={{
          position: "absolute",
          left: 180,
          right: 180,
          bottom: 116,
          height: 1,
          background: "linear-gradient(90deg, transparent, rgba(29,29,31,0.14), transparent)",
          transform: `translateX(${(drift - 0.5) * 52}px)`,
        }}
      />
    </AbsoluteFill>
  );
};

const Intro: React.FC<{ frame: number }> = ({ frame }) => {
  const inValue = ease(frame, 8, 38);
  const outValue = 1 - ease(frame, 72, 90);
  const visible = inValue * outValue;
  const notchScale = interpolate(frame, [0, 42, 90], [0.86, 1.1, 1.2], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: Easing.bezier(0.16, 1, 0.3, 1),
  });

  return (
    <AbsoluteFill style={{ opacity: visible }}>
      <div style={{ position: "absolute", left: 0, right: 0, top: 142, display: "grid", placeItems: "center" }}>
        <ShotFrame shot="collapsed" width={440} scale={notchScale} y={0} glowColor={palette.green} cleanCollapsed />
      </div>
      <TitleBlock
        top={540}
        align="center"
        opacity={visible}
        headline="悬屿"
        subline="Mac 顶中工作岛"
        small="for Mac"
      />
    </AbsoluteFill>
  );
};

type ShowcaseProps = {
  frame: number;
  start: number;
  end: number;
  shot: ShotName;
  headline: string;
  subline: string;
  caption: string;
  accent: string;
  scale: number;
  y: number;
  privacyMask?: boolean;
};

const Showcase: React.FC<ShowcaseProps> = ({
  frame,
  start,
  end,
  shot,
  headline,
  subline,
  caption,
  accent,
  scale,
  y,
  privacyMask = false,
}) => {
  const enter = ease(frame, start, start + 30);
  const exit = 1 - ease(frame, end - 28, end);
  const visible = enter * exit;
  const local = frame - start;
  const productDrift = interpolate(local, [0, end - start], [26, -14], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  const textDrift = interpolate(local, [0, end - start], [0, -18], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  return (
    <AbsoluteFill style={{ opacity: visible }}>
      <div
        style={{
          position: "absolute",
          left: 150,
          top: 118 + textDrift,
          width: 700,
          color: palette.text,
          fontFamily: "SF Pro Display, PingFang SC, system-ui, sans-serif",
          transform: `translateY(${(1 - enter) * 22}px)`,
        }}
      >
        <div
          style={{
            width: 9,
            height: 9,
            borderRadius: 999,
            backgroundColor: accent,
            boxShadow: `0 0 28px ${hexToRgba(accent, 0.42)}`,
            marginBottom: 24,
          }}
        />
        <div style={{ fontSize: 78, lineHeight: 0.96, fontWeight: 860, letterSpacing: 0 }}>{headline}</div>
        <div style={{ marginTop: 10, fontSize: 78, lineHeight: 0.96, fontWeight: 860, letterSpacing: 0 }}>{subline}</div>
        <div style={{ marginTop: 34, fontSize: 27, lineHeight: 1.35, fontWeight: 560, color: palette.muted }}>
          {caption}
        </div>
      </div>

      <div
        style={{
          position: "absolute",
          left: 0,
          right: 0,
          bottom: 84 + productDrift,
          display: "grid",
          placeItems: "center",
          transform: `scale(${scale + enter * 0.025})`,
          transformOrigin: "center bottom",
        }}
      >
        <ShotFrame shot={shot} width={shot === "agent-skills" ? 1840 : 1920} scale={1} y={y} glowColor={accent} privacyMask={privacyMask} />
      </div>
      <LightSweep progress={enter} accent={accent} />
    </AbsoluteFill>
  );
};

const Outro: React.FC<{ frame: number }> = ({ frame }) => {
  const enter = ease(frame, 742, 778);
  const visible = enter;
  const notchY = interpolate(frame, [742, durationInFrames], [-12, -44], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  return (
    <AbsoluteFill style={{ opacity: visible }}>
      <div style={{ position: "absolute", left: 0, right: 0, top: 136 + notchY, display: "grid", placeItems: "center" }}>
        <ShotFrame shot="collapsed" width={440} scale={1.12} y={0} glowColor={palette.green} cleanCollapsed />
      </div>
      <TitleBlock
        top={486}
        align="center"
        opacity={visible}
        headline="少切换。"
        subline="多完成。"
        small="悬屿"
      />
    </AbsoluteFill>
  );
};

type ShotFrameProps = {
  shot: ShotName;
  width: number;
  scale: number;
  y: number;
  glowColor: string;
  privacyMask?: boolean;
  cleanCollapsed?: boolean;
};

const ShotFrame: React.FC<ShotFrameProps> = ({
  shot,
  width,
  scale,
  y,
  glowColor,
  privacyMask = false,
  cleanCollapsed = false,
}) => (
  <div
    style={{
      position: "relative",
      width,
      maxWidth: "calc(100vw - 110px)",
      transform: `translateY(${y}px) scale(${scale})`,
      transformOrigin: "center",
      filter: `drop-shadow(0 0 42px ${hexToRgba(glowColor, 0.13)}) drop-shadow(0 38px 72px rgba(29,29,31,0.22))`,
    }}
  >
    <Img src={staticFile(shotFile[shot])} style={{ width: "100%", display: "block" }} />
    {cleanCollapsed ? <CollapsedCleanText /> : null}
    {privacyMask ? <ClipboardPrivacyMask /> : null}
  </div>
);

const TitleBlock: React.FC<{
  top: number;
  align: "center" | "left";
  opacity: number;
  headline: string;
  subline: string;
  small: string;
}> = ({ top, align, opacity, headline, subline, small }) => (
  <div
    style={{
      position: "absolute",
      top,
      left: align === "center" ? 0 : 150,
      right: align === "center" ? 0 : undefined,
      textAlign: align,
      color: palette.text,
      fontFamily: "SF Pro Display, PingFang SC, system-ui, sans-serif",
      transform: `translateY(${(1 - opacity) * 22}px)`,
    }}
  >
    <div style={{ color: palette.dim, fontSize: 22, fontWeight: 700, marginBottom: 22, letterSpacing: 0 }}>{small}</div>
    <div style={{ fontSize: 104, lineHeight: 0.96, fontWeight: 880, letterSpacing: 0 }}>{headline}</div>
    <div style={{ marginTop: 14, fontSize: 104, lineHeight: 0.96, fontWeight: 880, letterSpacing: 0 }}>{subline}</div>
  </div>
);

const LightSweep: React.FC<{ progress: number; accent: string }> = ({ progress, accent }) => (
  <div
    style={{
      position: "absolute",
      top: 0,
      bottom: 0,
      width: 240,
      left: interpolate(progress, [0, 1], [-260, 1940]),
      transform: "skewX(-18deg)",
      background: `linear-gradient(90deg, transparent, ${hexToRgba(accent, 0.13)}, transparent)`,
      opacity: Math.max(0, 1 - Math.abs(progress - 0.45) * 2.1),
    }}
  />
);

const ClipboardPrivacyMask: React.FC = () => (
  <div
    style={{
      position: "absolute",
      left: "2.6%",
      right: "2.6%",
      top: "28%",
      height: "70%",
      borderRadius: 24,
      background: "#ffffff",
      border: "1px solid rgba(29,29,31,0.10)",
      boxShadow: "0 28px 70px rgba(29,29,31,0.16)",
      display: "grid",
      placeItems: "center",
      color: palette.text,
      fontFamily: "SF Pro Display, PingFang SC, system-ui, sans-serif",
      fontSize: 28,
      fontWeight: 780,
      letterSpacing: 0,
    }}
  >
    内容已遮罩 · 能力保留
  </div>
);

const CollapsedCleanText: React.FC = () => (
  <div
    style={{
      position: "absolute",
      left: "14%",
      right: "13%",
      top: "7%",
      bottom: "7%",
      borderRadius: 18,
      background: "#030303",
      display: "grid",
      placeItems: "center",
      color: "#f5f5f7",
      fontFamily: "SF Pro Display, PingFang SC, system-ui, sans-serif",
      fontSize: 24,
      fontWeight: 820,
      letterSpacing: 0,
    }}
  >
    悬屿运行中
  </div>
);

const ease = (frame: number, start: number, end: number) =>
  interpolate(frame, [start, end], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: Easing.bezier(0.16, 1, 0.3, 1),
  });

const hexToRgba = (hex: string, alpha: number) => {
  const normalized = hex.replace("#", "");
  const bigint = Number.parseInt(normalized, 16);
  const red = (bigint >> 16) & 255;
  const green = (bigint >> 8) & 255;
  const blue = bigint & 255;
  return `rgba(${red}, ${green}, ${blue}, ${alpha})`;
};
