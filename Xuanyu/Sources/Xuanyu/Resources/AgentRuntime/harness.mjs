// Generated from src/harness.ts
// 悬屿 Agent Harness：在原始模型循环外面套一层可观测、可预算、可自检的脚手架。
// 这里只放纯函数与纯状态，runtime.ts 负责把它们接到真实的工具调用上。

export const HARNESS_DEFAULTS = {
  maxToolTurns: 20,
  maxToolCalls: 120,
  planStepLimit: 16,
  thrashRepeatLimit: 3,
  budgetWarnRatio: 0.7,
};

const PLAN_STATUSES = ["pending", "in_progress", "completed"];
const PLAN_STATUS_SET = new Set(PLAN_STATUSES);

function planStepText(value) {
  return String(value ?? "").replace(/\s+/g, " ").trim().slice(0, 200);
}

export function normalizePlanSteps(steps, limit = HARNESS_DEFAULTS.planStepLimit) {
  const list = Array.isArray(steps) ? steps : [];
  const normalized = [];
  for (const item of list) {
    const step = planStepText(typeof item === "string" ? item : item?.step ?? item?.title);
    if (!step) continue;
    const rawStatus = String(typeof item === "string" ? "" : item?.status ?? "").trim();
    normalized.push({
      step,
      status: PLAN_STATUS_SET.has(rawStatus) ? rawStatus : "pending",
    });
    if (normalized.length >= limit) break;
  }
  return normalized;
}

/**
 * 计划账本更新。拒绝空计划和多个 in_progress，让模型的"待办"始终是单焦点的。
 */
export function applyPlanUpdate(plan, update, limit = HARNESS_DEFAULTS.planStepLimit) {
  const steps = normalizePlanSteps(update?.plan ?? update?.steps, limit);
  if (!steps.length) {
    return { ok: false, error: "plan 至少需要一个非空步骤。", plan: Array.isArray(plan) ? plan : [] };
  }
  const active = steps.filter((step) => step.status === "in_progress");
  if (active.length > 1) {
    return {
      ok: false,
      error: `同时只能有一个 in_progress 步骤，当前有 ${active.length} 个。`,
      plan: Array.isArray(plan) ? plan : [],
    };
  }
  const done = steps.every((step) => step.status === "completed");
  if (!done && !active.length && steps.some((step) => step.status === "completed")) {
    // 允许，但提示模型继续推进：有已完成步骤却没有正在进行的步骤。
    return { ok: true, plan: steps, note: "计划中没有 in_progress 步骤；如果任务未结束，请标记下一步。" };
  }
  return { ok: true, plan: steps };
}

export function planProgress(plan) {
  const steps = Array.isArray(plan) ? plan : [];
  return {
    total: steps.length,
    completed: steps.filter((step) => step.status === "completed").length,
    active: steps.find((step) => step.status === "in_progress")?.step || "",
  };
}

export function renderPlanBlock(plan) {
  const steps = Array.isArray(plan) ? plan : [];
  if (!steps.length) return "";
  const marks = { pending: "[ ]", in_progress: "[~]", completed: "[x]" };
  const progress = planProgress(steps);
  return [
    `════════════════ CURRENT PLAN [${progress.completed}/${progress.total}] ════════════════`,
    ...steps.map((step, index) => `${marks[step.status] || "[ ]"} ${index + 1}. ${step.step}`),
    "保持这个计划最新：开始一步前标记 in_progress，做完立即标记 completed（用 update_plan）。",
  ].join("\n");
}

function stableStringify(value) {
  if (value === null || typeof value !== "object") return JSON.stringify(value ?? null);
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(",")}]`;
  const keys = Object.keys(value).sort();
  return `{${keys.map((key) => `${JSON.stringify(key)}:${stableStringify(value[key])}`).join(",")}}`;
}

export function toolCallSignature(name, args) {
  return `${String(name || "")}::${stableStringify(args ?? {})}`.slice(0, 2000);
}

export function createLoopGuardState() {
  return { counts: new Map(), lastSignature: "", consecutive: 0 };
}

/**
 * 记录一次工具调用签名，判断 agent 是否在原地打转。
 */
export function recordToolSignature(state, signature, limit = HARNESS_DEFAULTS.thrashRepeatLimit) {
  const key = String(signature || "");
  const count = (state.counts.get(key) || 0) + 1;
  state.counts.set(key, count);
  if (state.lastSignature === key) state.consecutive += 1;
  else state.consecutive = 1;
  state.lastSignature = key;
  return {
    count,
    consecutive: state.consecutive,
    thrashing: count >= limit,
  };
}

export function loopGuardNotice(repeats) {
  const offenders = (Array.isArray(repeats) ? repeats : []).filter((item) => item?.thrashing);
  if (!offenders.length) return "";
  const list = offenders.map((item) => `- ${item.tool}（已重复 ${item.count} 次）`).join("\n");
  return [
    "检测到重复的工具调用，参数完全一致，说明当前路径没有产生新信息：",
    list,
    "换一个方法：换关键词或换目录搜索、读取相邻文件、或者直接把已知信息与缺口告诉用户。不要再用同样的参数重试。",
  ].join("\n");
}

export function budgetNotice({ turn, maxTurns, ratio = HARNESS_DEFAULTS.budgetWarnRatio }) {
  const total = Math.max(1, Number(maxTurns) || HARNESS_DEFAULTS.maxToolTurns);
  const used = Math.max(0, Number(turn) || 0);
  const remaining = total - used;
  if (remaining <= 0) return "";
  if (used < Math.floor(total * ratio)) return "";
  return `工具轮次预算只剩 ${remaining}/${total}。收敛：先完成最关键的一步，然后直接给结论，不要开新的探索分支。`;
}

export function createRunTelemetry(limits = {}) {
  return {
    startedAt: Date.now(),
    turn: 0,
    toolCalls: 0,
    mutations: [],
    verifyRequested: false,
    phase: "explore",
    limits: { ...HARNESS_DEFAULTS, ...limits },
  };
}

export function recordMutation(telemetry, mutation) {
  const entry = {
    tool: String(mutation?.tool || ""),
    detail: String(mutation?.detail || "").slice(0, 300),
  };
  if (!entry.tool) return telemetry.mutations;
  telemetry.mutations.push(entry);
  if (telemetry.mutations.length > 40) telemetry.mutations.shift();
  return telemetry.mutations;
}

/**
 * 收尾自检闸门：一轮里改过文件/跑过写操作，就在给最终答复前强制自检一次。
 */
export function verificationNotice(telemetry) {
  if (!telemetry || telemetry.verifyRequested) return "";
  const mutations = Array.isArray(telemetry.mutations) ? telemetry.mutations : [];
  if (!mutations.length) return "";
  const seen = new Set();
  const list = mutations
    .filter((item) => {
      const key = `${item.tool}:${item.detail}`;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    })
    .slice(-8)
    .map((item) => `- ${item.tool}: ${item.detail}`)
    .join("\n");
  return [
    "本轮已经产生了实际改动：",
    list,
    "在给最终答复前先自检一次：确认改动落到了正确的文件、语法/格式没问题、没有遗漏被引用处；能跑的检查就跑一下（构建、测试、语法检查）。",
    "自检完成后再给结论，并如实说明验证过了什么、没验证什么。",
  ].join("\n");
}

export function inferPhase(telemetry, plan) {
  if (telemetry?.verifyRequested) return "verify";
  if ((telemetry?.mutations?.length || 0) > 0) return "execute";
  if (planProgress(plan).total > 0) return "plan";
  return "explore";
}

export function harnessStatus(telemetry, plan) {
  const progress = planProgress(plan);
  return {
    phase: inferPhase(telemetry, plan),
    turn: telemetry?.turn || 0,
    maxTurns: telemetry?.limits?.maxToolTurns || HARNESS_DEFAULTS.maxToolTurns,
    toolCalls: telemetry?.toolCalls || 0,
    mutations: telemetry?.mutations?.length || 0,
    elapsedMs: telemetry?.startedAt ? Date.now() - telemetry.startedAt : 0,
    plan: Array.isArray(plan) ? plan : [],
    planProgress: progress,
  };
}
