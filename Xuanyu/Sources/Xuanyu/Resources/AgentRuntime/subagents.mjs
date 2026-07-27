// Generated from src/subagents.ts
// 悬屿多智能体层：把一次复杂任务拆给若干带角色的子 agent，各自跑自己的工具循环，
// 再把报告汇回主循环。所有真实能力（模型流、工具执行、权限）都由 runtime.ts 注入。

export const READ_ONLY_BUILTIN_TOOLS = [
  "list_skills",
  "read_skill",
  "file_search",
  "session_search",
  "memory_recall",
  "list_evolution_candidates",
];

// 子 agent 一律不能再派生子 agent（深度锁 1 层），也不碰主循环的计划账本和自演化落盘。
const FORBIDDEN_FOR_SUBAGENTS = new Set([
  "dispatch_agents",
  "engineer_loop",
  "update_plan",
  "apply_skill_evolution",
]);

export const AGENT_ROLES = {
  explorer: {
    id: "explorer",
    title: "探路者",
    maxTurns: 10,
    readOnly: true,
    builtinTools: READ_ONLY_BUILTIN_TOOLS,
    allowMCP: "readOnly",
    prompt: [
      "你是悬屿多智能体编队里的探路者。你的唯一职责是把事实查清楚并如实汇报。",
      "严禁修改任何文件、严禁执行写操作。只用只读工具定位代码、配置和证据。",
      "汇报格式：先给结论，再给证据（文件路径:行号 + 关键片段），最后列出你没能确认的部分。",
      "不要猜测。查不到就明说查不到，并写清你试过哪些路径。",
    ].join("\n"),
  },
  implementer: {
    id: "implementer",
    title: "执行者",
    maxTurns: 14,
    readOnly: false,
    builtinTools: null, // null = 除禁用项外的全部工具
    allowMCP: "all",
    prompt: [
      "你是悬屿多智能体编队里的执行者。你负责真正把改动落到磁盘上。",
      "改文件优先用 apply_patch，它是原子的且会展示 diff 供审批。改动前先用 file_search 确认目标位置。",
      "只做被指派的那件事，不要顺手重构无关代码。",
      "汇报格式：改了哪些文件、每个文件改了什么、你验证过什么、还有什么风险没覆盖。",
    ].join("\n"),
  },
  reviewer: {
    id: "reviewer",
    title: "评审者",
    maxTurns: 10,
    readOnly: true,
    builtinTools: READ_ONLY_BUILTIN_TOOLS,
    allowMCP: "readOnly",
    prompt: [
      "你是悬屿多智能体编队里的评审者。你的立场是对抗性的：默认改动有问题，去找出它。",
      "只读。不要修改任何东西。读真实的文件内容来核对，不要只看别人的描述就下结论。",
      "重点查：改动是否真的落到了文件里、逻辑是否正确、边界条件、是否漏改了调用方、是否破坏了既有行为。",
      "最后一行必须是判定，二选一，单独成行：",
      "VERDICT: APPROVED",
      "VERDICT: CHANGES_REQUIRED",
      "判定为 CHANGES_REQUIRED 时，上面要按严重度列出每条问题：文件:行号 + 问题 + 具体怎么改。",
      "不确定的问题不要报；只报你能用文件内容佐证的问题。",
    ].join("\n"),
  },
  tester: {
    id: "tester",
    title: "验证者",
    maxTurns: 10,
    readOnly: false,
    builtinTools: [...READ_ONLY_BUILTIN_TOOLS, "shell", "run_skill_script"],
    allowMCP: "readOnly",
    prompt: [
      "你是悬屿多智能体编队里的验证者。你通过实际运行来确认改动是否有效。",
      "可以跑构建、测试、语法检查等命令，但不要修改任何文件。",
      "汇报格式：跑了哪些命令、原始输出的关键部分、通过还是失败、失败的话根因指向哪里。",
      "命令失败时如实汇报失败，不要粉饰，也不要替执行者去改代码。",
    ].join("\n"),
  },
  synthesizer: {
    id: "synthesizer",
    title: "汇总者",
    maxTurns: 1,
    readOnly: true,
    builtinTools: [],
    allowMCP: "none",
    prompt: [
      "你是悬屿多智能体编队里的汇总者。你收到若干子 agent 的报告，要合成一份连贯的结论。",
      "去掉重复，标出互相矛盾的地方，保留具体的文件路径和证据。",
      "结论先行，然后是支撑细节，最后是仍然存在的缺口和风险。不要引入报告里没有的新事实。",
    ].join("\n"),
  },
};

export function listAgentRoles() {
  return Object.values(AGENT_ROLES).map((role) => ({
    id: role.id,
    title: role.title,
    readOnly: role.readOnly,
    maxTurns: role.maxTurns,
  }));
}

export function agentRole(id) {
  const key = String(id || "").trim().toLowerCase();
  return AGENT_ROLES[key] || null;
}

/**
 * 按角色裁剪工具集：只读角色拿不到写工具，MCP 工具按只读判定过滤。
 */
export function selectToolsForRole(role, tools, { isReadOnlyMCPName } = {}) {
  const list = Array.isArray(tools) ? tools : [];
  const allowed = role?.builtinTools;
  return list.filter((tool) => {
    const name = tool?.function?.name || "";
    if (!name) return false;
    if (FORBIDDEN_FOR_SUBAGENTS.has(name)) return false;
    const isMCP = name.startsWith("mcp__");
    if (isMCP) {
      if (role?.allowMCP === "none") return false;
      if (role?.allowMCP === "readOnly") return isReadOnlyMCPName ? isReadOnlyMCPName(name) === true : false;
      return true;
    }
    if (allowed === null || allowed === undefined) return true;
    return allowed.includes(name);
  });
}

export function normalizeDispatchTasks(tasks, { maxTasks = 6 } = {}) {
  const list = Array.isArray(tasks) ? tasks : [];
  const normalized = [];
  for (const task of list) {
    const role = agentRole(task?.role);
    const goal = String(task?.goal ?? task?.prompt ?? "").trim();
    if (!role || !goal) continue;
    normalized.push({
      role: role.id,
      goal: goal.slice(0, 8000),
      label: String(task?.label || role.title).trim().slice(0, 40),
      context: String(task?.context || "").slice(0, 8000),
    });
    if (normalized.length >= maxTasks) break;
  }
  return normalized;
}

export function parseReviewVerdict(text) {
  const value = String(text || "");
  const match = value.match(/VERDICT:\s*(APPROVED|CHANGES_REQUIRED)/i);
  if (match) return match[1].toUpperCase() === "APPROVED" ? "approved" : "changes_required";
  // 没有显式判定时按未通过处理，宁可多跑一轮也不放过问题。
  return "changes_required";
}

export function buildSubAgentMessages(role, task, sharedContext = "") {
  const system = [
    role.prompt,
    "你运行在一个隔离的子会话里：你看不到主对话历史，只有下面给你的任务和上下文。",
    "不要向用户提问——用户看不到你。信息不足时，在报告里写清缺什么。",
    "把报告写完整且可独立阅读，它会被直接交给主 agent。",
  ].join("\n\n");
  const user = [
    `任务：${task.goal}`,
    task.context ? `任务上下文：\n${task.context}` : "",
    sharedContext ? `编队共享上下文：\n${sharedContext}` : "",
  ].filter(Boolean).join("\n\n");
  return [
    { role: "system", content: system },
    { role: "user", content: user },
  ];
}

/**
 * 单个子 agent 的完整工具循环。deps 由 runtime.ts 注入，保证权限/取消/MCP 与主循环一致。
 */
export async function runSubAgent(task, deps) {
  const role = agentRole(task.role);
  if (!role) return { ok: false, role: task.role, label: task.label, report: `未知角色：${task.role}`, turns: 0 };
  const {
    agentId,
    streamChat,
    executeToolCalls,
    tools,
    send,
    sessionId,
    isCancelled = () => false,
    sharedContext = "",
    maxTurnsOverride,
  } = deps;

  const roleTools = selectToolsForRole(role, tools, deps);
  const maxTurns = Math.max(1, Number(maxTurnsOverride) || role.maxTurns);
  const messages = buildSubAgentMessages(role, task, sharedContext);
  const agentContext = { agentId, role: role.id, label: task.label };

  send?.({ type: "subagent_started", sessionId, agentId, role: role.id, label: task.label, goal: task.goal });

  let turns = 0;
  let report = "";
  try {
    for (let turn = 0; turn < maxTurns; turn += 1) {
      if (isCancelled()) {
        report = "子 agent 被用户取消。";
        break;
      }
      turns = turn + 1;
      const result = await streamChat(messages, roleTools, { sessionId, agentContext });
      if (isCancelled()) {
        report = result.text || "子 agent 被用户取消。";
        break;
      }
      if (!result.toolCalls.length) {
        report = result.text || "";
        break;
      }
      messages.push({ role: "assistant", content: result.text || null, tool_calls: result.toolCalls });
      const results = await executeToolCalls(result.toolCalls, sessionId, agentContext);
      for (let index = 0; index < result.toolCalls.length; index += 1) {
        messages.push({ role: "tool", tool_call_id: result.toolCalls[index].id, content: results[index] });
      }
      if (turn === maxTurns - 1) {
        messages.push({
          role: "system",
          content: "工具预算已用尽。立刻基于已有结果输出最终报告，不要再调用工具。",
        });
        const final = await streamChat(messages, [], { sessionId, agentContext, allowTools: false });
        report = final.text || "";
      }
    }
  } catch (error) {
    const message = error?.name === "AbortError" ? "子 agent 被中断。" : (error?.message || String(error));
    send?.({ type: "subagent_done", sessionId, agentId, role: role.id, label: task.label, ok: false, turns });
    return { ok: false, agentId, role: role.id, label: task.label, report: `子 agent 失败：${message}`, turns };
  }

  const finalReport = report.trim() || "子 agent 没有产出报告。";
  send?.({ type: "subagent_done", sessionId, agentId, role: role.id, label: task.label, ok: true, turns, report: finalReport });
  return { ok: true, agentId, role: role.id, label: task.label, report: finalReport, turns };
}

async function runWithConcurrency(items, limit, worker) {
  const results = new Array(items.length);
  let cursor = 0;
  const size = Math.max(1, Math.min(Number(limit) || 1, items.length || 1));
  const runners = Array.from({ length: size }, async () => {
    while (cursor < items.length) {
      const index = cursor;
      cursor += 1;
      results[index] = await worker(items[index], index);
    }
  });
  await Promise.all(runners);
  return results;
}

export function renderReports(reports) {
  return (Array.isArray(reports) ? reports : [])
    .map((item, index) => [
      `### 子 agent ${index + 1} · ${item.label}（${item.role}，${item.turns} 轮，${item.ok ? "完成" : "失败"}）`,
      item.report,
    ].join("\n"))
    .join("\n\n---\n\n");
}

/**
 * 并行 / 串行派发。串行时后一个 agent 能看到前面所有报告，用于需要递进的任务。
 */
export async function dispatchAgents(tasks, deps) {
  const { mode = "parallel", concurrency = 3, makeAgentId, ...rest } = deps;
  if (mode === "sequential") {
    const reports = [];
    for (let index = 0; index < tasks.length; index += 1) {
      const priorContext = reports.length ? `前序子 agent 的报告：\n${renderReports(reports)}` : "";
      const shared = [rest.sharedContext, priorContext].filter(Boolean).join("\n\n");
      reports.push(await runSubAgent(tasks[index], { ...rest, sharedContext: shared, agentId: makeAgentId(index) }));
    }
    return reports;
  }
  return runWithConcurrency(tasks, concurrency, (task, index) =>
    runSubAgent(task, { ...rest, agentId: makeAgentId(index) }));
}

/**
 * 工程师循环：执行者改 → 评审者对抗性验收 → 未通过就带着评审意见再来一轮。
 * 这是"loop engineers"的核心：不靠单次输出，靠迭代收敛。
 */
export async function runEngineerLoop(spec, deps) {
  const rounds = Math.max(1, Math.min(Number(spec?.rounds) || 2, 4));
  const goal = String(spec?.goal || "").trim();
  const { makeAgentId, send, sessionId, isCancelled = () => false } = deps;
  const history = [];
  let feedback = "";
  let verdict = "changes_required";

  for (let round = 0; round < rounds; round += 1) {
    if (isCancelled()) break;
    send?.({ type: "engineer_loop_round", sessionId, round: round + 1, rounds });

    const implementer = await runSubAgent(
      {
        role: "implementer",
        goal,
        label: `执行 R${round + 1}`,
        context: feedback ? `上一轮评审提出的必须修复的问题：\n${feedback}` : String(spec?.context || ""),
      },
      { ...deps, agentId: makeAgentId(`impl-${round + 1}`) },
    );
    history.push(implementer);
    if (isCancelled()) break;

    const reviewer = await runSubAgent(
      {
        role: "reviewer",
        goal: `验收下面这个任务的改动是否真正完成且正确：\n${goal}`,
        label: `评审 R${round + 1}`,
        context: `执行者的报告：\n${implementer.report}`,
      },
      { ...deps, agentId: makeAgentId(`review-${round + 1}`) },
    );
    history.push(reviewer);

    verdict = parseReviewVerdict(reviewer.report);
    send?.({ type: "engineer_loop_verdict", sessionId, round: round + 1, verdict });
    if (verdict === "approved") break;
    feedback = reviewer.report;
  }

  return { verdict, rounds: history.length / 2, history };
}
