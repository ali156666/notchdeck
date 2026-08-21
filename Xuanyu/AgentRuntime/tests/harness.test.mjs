import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  applyPlanUpdate,
  budgetNotice,
  createLoopGuardState,
  createRunTelemetry,
  normalizePlanSteps,
  recordMutation,
  recordToolSignature,
  renderPlanBlock,
  toolCallSignature,
  verificationNotice,
} from "../dist/harness.mjs";

import {
  AGENT_ROLES,
  buildSubAgentMessages,
  dispatchAgents,
  normalizeDispatchTasks,
  parseReviewVerdict,
  renderReports,
  runEngineerLoop,
  runSubAgent,
  selectToolsForRole,
} from "../dist/subagents.mjs";

function toolDef(name) {
  return { type: "function", function: { name, description: name, parameters: { type: "object", properties: {} } } };
}

const ALL_TOOLS = [
  "list_skills", "read_skill", "file_search", "session_search", "list_evolution_candidates",
  "shell", "apply_patch", "run_skill_script", "memory_manage", "propose_skill_evolution",
  "apply_skill_evolution", "update_plan", "dispatch_agents", "engineer_loop",
  "mcp__weather__get_forecast", "mcp__deploy__push_release",
].map(toolDef);

const isReadOnlyMCPName = (name) => name === "mcp__weather__get_forecast";

function toolNames(tools) {
  return tools.map((tool) => tool.function.name);
}

// ---------------------------------------------------------------- harness

test("applyPlanUpdate rejects an empty plan and more than one in_progress step", () => {
  assert.equal(applyPlanUpdate([], { plan: [] }).ok, false);
  assert.equal(applyPlanUpdate([], { plan: [{ step: "   ", status: "pending" }] }).ok, false);

  const twoActive = applyPlanUpdate([], {
    plan: [
      { step: "读代码", status: "in_progress" },
      { step: "改代码", status: "in_progress" },
    ],
  });
  assert.equal(twoActive.ok, false);
  assert.match(twoActive.error, /只能有一个 in_progress/);
});

test("applyPlanUpdate normalizes unknown statuses and caps the step count", () => {
  const result = applyPlanUpdate([], {
    plan: [
      { step: "读代码", status: "in_progress" },
      { step: "改代码", status: "banana" },
      { step: "验证", status: "completed" },
    ],
  });
  assert.equal(result.ok, true);
  assert.deepEqual(result.plan.map((step) => step.status), ["in_progress", "pending", "completed"]);

  const many = Array.from({ length: 30 }, (_, index) => ({ step: `step ${index}`, status: "pending" }));
  assert.equal(normalizePlanSteps(many, 16).length, 16);
});

test("renderPlanBlock renders progress and status marks", () => {
  const block = renderPlanBlock([
    { step: "读代码", status: "completed" },
    { step: "改代码", status: "in_progress" },
    { step: "验证", status: "pending" },
  ]);
  assert.match(block, /\[1\/3\]/);
  assert.match(block, /\[x\] 1\. 读代码/);
  assert.match(block, /\[~\] 2\. 改代码/);
  assert.match(block, /\[ \] 3\. 验证/);
  assert.equal(renderPlanBlock([]), "");
});

test("toolCallSignature ignores object key order but not values", () => {
  assert.equal(
    toolCallSignature("file_search", { query: "a", mode: "name" }),
    toolCallSignature("file_search", { mode: "name", query: "a" }),
  );
  assert.notEqual(
    toolCallSignature("file_search", { query: "a" }),
    toolCallSignature("file_search", { query: "b" }),
  );
});

test("recordToolSignature flags thrashing only after the repeat limit", () => {
  const state = createLoopGuardState();
  const signature = toolCallSignature("file_search", { query: "a" });
  const other = toolCallSignature("file_search", { query: "b" });

  assert.equal(recordToolSignature(state, signature, 3).thrashing, false);
  assert.equal(recordToolSignature(state, other, 3).thrashing, false);
  assert.equal(recordToolSignature(state, signature, 3).thrashing, false);
  const third = recordToolSignature(state, signature, 3);
  assert.equal(third.thrashing, true);
  assert.equal(third.count, 3);
});

test("budgetNotice stays silent until the warn ratio and reports remaining turns", () => {
  assert.equal(budgetNotice({ turn: 5, maxTurns: 20 }), "");
  assert.match(budgetNotice({ turn: 15, maxTurns: 20 }), /只剩 5\/20/);
  assert.equal(budgetNotice({ turn: 20, maxTurns: 20 }), "");
});

test("verificationNotice fires once, only after a real mutation", () => {
  const telemetry = createRunTelemetry();
  assert.equal(verificationNotice(telemetry), "");

  recordMutation(telemetry, { tool: "apply_patch", detail: "update Sources/App.swift" });
  const notice = verificationNotice(telemetry);
  assert.match(notice, /Sources\/App\.swift/);
  assert.match(notice, /自检/);

  telemetry.verifyRequested = true;
  assert.equal(verificationNotice(telemetry), "");
});

// -------------------------------------------------------------- subagents

test("selectToolsForRole keeps read-only roles read-only", () => {
  const explorer = toolNames(selectToolsForRole(AGENT_ROLES.explorer, ALL_TOOLS, { isReadOnlyMCPName }));
  assert.deepEqual(explorer.filter((name) => !name.startsWith("mcp__")).sort(), [
    "file_search", "list_evolution_candidates", "list_skills", "read_skill", "session_search",
  ]);
  assert.deepEqual(explorer.filter((name) => name.startsWith("mcp__")), ["mcp__weather__get_forecast"]);
  for (const forbidden of ["shell", "apply_patch", "mcp__deploy__push_release"]) {
    assert.equal(explorer.includes(forbidden), false, `explorer must not get ${forbidden}`);
  }
});

test("selectToolsForRole gives the implementer write tools but blocks recursion", () => {
  const implementer = toolNames(selectToolsForRole(AGENT_ROLES.implementer, ALL_TOOLS, { isReadOnlyMCPName }));
  assert.equal(implementer.includes("apply_patch"), true);
  assert.equal(implementer.includes("shell"), true);
  assert.equal(implementer.includes("mcp__deploy__push_release"), true);
  for (const forbidden of ["dispatch_agents", "engineer_loop", "update_plan", "apply_skill_evolution"]) {
    assert.equal(implementer.includes(forbidden), false, `sub-agents must not get ${forbidden}`);
  }
});

test("selectToolsForRole leaves the synthesizer with no tools and the tester without apply_patch", () => {
  assert.deepEqual(selectToolsForRole(AGENT_ROLES.synthesizer, ALL_TOOLS, { isReadOnlyMCPName }), []);
  const tester = toolNames(selectToolsForRole(AGENT_ROLES.tester, ALL_TOOLS, { isReadOnlyMCPName }));
  assert.equal(tester.includes("shell"), true);
  assert.equal(tester.includes("apply_patch"), false);
});

test("normalizeDispatchTasks drops invalid tasks and caps the fan-out", () => {
  const tasks = normalizeDispatchTasks([
    { role: "explorer", goal: "查音乐模块" },
    { role: "nope", goal: "无效角色" },
    { role: "reviewer", goal: "   " },
    { role: "tester", goal: "跑测试", label: "验证" },
  ]);
  assert.deepEqual(tasks.map((task) => task.role), ["explorer", "tester"]);
  assert.equal(tasks[0].label, "探路者");
  assert.equal(tasks[1].label, "验证");

  const many = Array.from({ length: 12 }, () => ({ role: "explorer", goal: "查" }));
  assert.equal(normalizeDispatchTasks(many, { maxTasks: 6 }).length, 6);
});

test("parseReviewVerdict defaults to changes_required when no verdict is stated", () => {
  assert.equal(parseReviewVerdict("看着不错\nVERDICT: APPROVED"), "approved");
  assert.equal(parseReviewVerdict("有问题\nVERDICT: CHANGES_REQUIRED"), "changes_required");
  assert.equal(parseReviewVerdict("我觉得挺好的"), "changes_required");
});

test("buildSubAgentMessages carries goal, task context and shared context", () => {
  const messages = buildSubAgentMessages(AGENT_ROLES.explorer, {
    goal: "定位番茄钟实现",
    context: "只看 Sources 目录",
  }, "本次任务针对 v2 分支");
  assert.equal(messages[0].role, "system");
  assert.match(messages[0].content, /探路者/);
  assert.match(messages[1].content, /定位番茄钟实现/);
  assert.match(messages[1].content, /只看 Sources 目录/);
  assert.match(messages[1].content, /v2 分支/);
});

function fakeDeps(script, { send = () => {} } = {}) {
  const calls = [];
  let index = 0;
  return {
    calls,
    deps: {
      send,
      sessionId: "session-1",
      tools: ALL_TOOLS,
      isReadOnlyMCPName,
      isCancelled: () => false,
      makeAgentId: (suffix) => `agent-${suffix}`,
      streamChat: async (messages, tools, options) => {
        calls.push({ messages: messages.map((m) => m.content), tools: toolNames(tools), options });
        const step = script[Math.min(index, script.length - 1)];
        index += 1;
        return { text: step.text || "", toolCalls: step.toolCalls || [] };
      },
      executeToolCalls: async (toolCalls) => toolCalls.map((call) => `result of ${call.function.name}`),
    },
  };
}

test("runSubAgent runs its tool loop and returns the final report", async () => {
  const events = [];
  const { deps, calls } = fakeDeps([
    { toolCalls: [{ id: "c1", type: "function", function: { name: "file_search", arguments: "{}" } }] },
    { text: "找到了 Sources/Pomodoro.swift:42" },
  ], { send: (event) => events.push(event) });

  const result = await runSubAgent(
    { role: "explorer", goal: "定位番茄钟", label: "探路", context: "" },
    { ...deps, agentId: "agent-1" },
  );

  assert.equal(result.ok, true);
  assert.equal(result.role, "explorer");
  assert.equal(result.turns, 2);
  assert.match(result.report, /Pomodoro\.swift:42/);
  // 探路者拿到的工具集必须是被裁剪过的
  assert.equal(calls[0].tools.includes("apply_patch"), false);
  assert.deepEqual(events.map((event) => event.type), ["subagent_started", "subagent_done"]);
  assert.equal(events[1].agentId, "agent-1");
});

test("runSubAgent forces a tool-free final answer when its turn budget runs out", async () => {
  const { deps, calls } = fakeDeps([
    { toolCalls: [{ id: "c1", type: "function", function: { name: "file_search", arguments: "{}" } }] },
    { text: "预算用尽后的结论" },
  ]);

  const result = await runSubAgent(
    { role: "explorer", goal: "查东西", label: "探路", context: "" },
    { ...deps, agentId: "agent-1", maxTurnsOverride: 1 },
  );

  assert.equal(result.report, "预算用尽后的结论");
  // 最后一次调用必须禁用工具
  assert.equal(calls.at(-1).options.allowTools, false);
  assert.deepEqual(calls.at(-1).tools, []);
});

test("runSubAgent reports failure instead of throwing when the model errors", async () => {
  const result = await runSubAgent(
    { role: "explorer", goal: "查东西", label: "探路", context: "" },
    {
      send: () => {},
      sessionId: "s",
      tools: ALL_TOOLS,
      isReadOnlyMCPName,
      agentId: "agent-1",
      streamChat: async () => { throw new Error("provider exploded"); },
      executeToolCalls: async () => [],
    },
  );
  assert.equal(result.ok, false);
  assert.match(result.report, /provider exploded/);
});

test("dispatchAgents in sequential mode feeds earlier reports to later agents", async () => {
  const { deps, calls } = fakeDeps([{ text: "报告内容" }]);
  const reports = await dispatchAgents(
    [
      { role: "explorer", goal: "第一个任务", label: "A", context: "" },
      { role: "explorer", goal: "第二个任务", label: "B", context: "" },
    ],
    { ...deps, mode: "sequential" },
  );

  assert.equal(reports.length, 2);
  assert.deepEqual(reports.map((report) => report.agentId), ["agent-0", "agent-1"]);
  // 第二个 agent 的用户消息里必须带上第一个 agent 的报告
  assert.match(calls[1].messages.join("\n"), /前序子 agent 的报告/);
  assert.match(calls[1].messages.join("\n"), /报告内容/);
  assert.match(renderReports(reports), /子 agent 2 · B/);
});

test("dispatchAgents in parallel mode keeps agents isolated from each other", async () => {
  const { deps, calls } = fakeDeps([{ text: "独立报告" }]);
  const reports = await dispatchAgents(
    [
      { role: "explorer", goal: "任务 A", label: "A", context: "" },
      { role: "explorer", goal: "任务 B", label: "B", context: "" },
    ],
    { ...deps, mode: "parallel", concurrency: 2 },
  );

  assert.equal(reports.length, 2);
  for (const call of calls) {
    assert.equal(/前序子 agent 的报告/.test(call.messages.join("\n")), false);
  }
});

test("runEngineerLoop stops as soon as the reviewer approves", async () => {
  const events = [];
  let turn = 0;
  const deps = {
    send: (event) => events.push(event),
    sessionId: "s",
    tools: ALL_TOOLS,
    isReadOnlyMCPName,
    makeAgentId: (suffix) => `agent-${suffix}`,
    isCancelled: () => false,
    streamChat: async () => {
      turn += 1;
      return turn === 1
        ? { text: "改好了 Sources/App.swift", toolCalls: [] }
        : { text: "核对无误\nVERDICT: APPROVED", toolCalls: [] };
    },
    executeToolCalls: async () => [],
  };

  const result = await runEngineerLoop({ goal: "修一个 bug", rounds: 3 }, deps);
  assert.equal(result.verdict, "approved");
  assert.equal(result.rounds, 1);
  assert.equal(result.history.length, 2);
  assert.equal(turn, 2, "通过后不应再开新一轮");
  assert.equal(events.some((event) => event.type === "engineer_loop_verdict" && event.verdict === "approved"), true);
});

test("runEngineerLoop retries with the reviewer feedback and gives up after the round cap", async () => {
  const seenContexts = [];
  const deps = {
    send: () => {},
    sessionId: "s",
    tools: ALL_TOOLS,
    isReadOnlyMCPName,
    makeAgentId: (suffix) => `agent-${suffix}`,
    isCancelled: () => false,
    streamChat: async (messages) => {
      seenContexts.push(messages.map((m) => m.content).join("\n"));
      const isReviewer = messages[0].content.includes("评审者");
      return isReviewer
        ? { text: "第 12 行漏改了\nVERDICT: CHANGES_REQUIRED", toolCalls: [] }
        : { text: "尝试修复", toolCalls: [] };
    },
    executeToolCalls: async () => [],
  };

  const result = await runEngineerLoop({ goal: "修一个 bug", rounds: 2 }, deps);
  assert.equal(result.verdict, "changes_required");
  assert.equal(result.rounds, 2);
  // 第二轮的执行者必须收到第一轮评审的意见
  assert.match(seenContexts[2], /第 12 行漏改了/);
});

// -------------------------------------------------------------------- e2e

function startRuntimeChild() {
  const child = spawn(process.execPath, [fileURLToPath(new URL("../dist/runtime.mjs", import.meta.url))], {
    stdio: ["pipe", "pipe", "pipe"],
  });
  const events = [];
  let stdoutBuffer = "";
  let stderr = "";
  child.stdout.on("data", (chunk) => {
    stdoutBuffer += chunk.toString();
    const lines = stdoutBuffer.split("\n");
    stdoutBuffer = lines.pop() || "";
    for (const line of lines) {
      if (line.trim()) events.push(JSON.parse(line));
    }
  });
  child.stderr.on("data", (chunk) => { stderr += chunk.toString(); });
  return {
    child,
    events,
    send(event) { child.stdin.write(`${JSON.stringify(event)}\n`); },
    async waitFor(predicate, timeoutMs = 4000) {
      const started = Date.now();
      while (Date.now() - started < timeoutMs) {
        const matched = events.find(predicate);
        if (matched) return matched;
        await new Promise((resolve) => setTimeout(resolve, 10));
      }
      throw new Error(`Timed out. stderr=${stderr} events=${JSON.stringify(events)}`);
    },
  };
}

function sseToolCall(name, args) {
  return [
    `data: ${JSON.stringify({ choices: [{ delta: { tool_calls: [{ index: 0, id: `call-${name}`, type: "function", function: { name, arguments: JSON.stringify(args) } }] } }] })}`,
    "",
    "data: [DONE]",
    "",
  ].join("\n");
}

function sseText(text) {
  return [
    `data: ${JSON.stringify({ choices: [{ delta: { content: text } }] })}`,
    "",
    "data: [DONE]",
    "",
  ].join("\n");
}

test("the runtime drives update_plan and dispatch_agents end to end", async () => {
  const configDir = await mkdtemp(join(tmpdir(), "xuanyu-harness-"));
  const subAgentToolSets = [];
  const mainSystemPrompts = [];
  let mainTurn = 0;

  const server = createServer((request, response) => {
    let body = "";
    request.on("data", (chunk) => { body += chunk.toString(); });
    request.on("end", () => {
      const payload = JSON.parse(body);
      const system = payload.messages.find((message) => message.role === "system")?.content || "";
      response.writeHead(200, { "content-type": "text/event-stream" });

      // 子 agent 的 system prompt 带角色名，据此区分主/子请求。
      if (system.includes("探路者")) {
        subAgentToolSets.push((payload.tools || []).map((tool) => tool.function.name));
        response.end(sseText("探路完成：番茄钟在 Sources/Pomodoro.swift"));
        return;
      }

      mainSystemPrompts.push(system);
      mainTurn += 1;
      if (mainTurn === 1) {
        response.end(sseToolCall("update_plan", {
          plan: [
            { step: "摸清番茄钟实现", status: "in_progress" },
            { step: "汇总结论", status: "pending" },
          ],
        }));
        return;
      }
      if (mainTurn === 2) {
        response.end(sseToolCall("dispatch_agents", {
          mode: "parallel",
          tasks: [{ role: "explorer", goal: "定位番茄钟实现", label: "番茄钟" }],
        }));
        return;
      }
      response.end(sseText("番茄钟在 Sources/Pomodoro.swift。"));
    });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();

  const runtimeChild = startRuntimeChild();
  runtimeChild.send({
    type: "configure",
    apiKey: "test-key",
    configDir,
    config: { baseURL: `http://127.0.0.1:${port}/v1`, model: "fake-model" },
  });
  await runtimeChild.waitFor((event) => event.type === "ready" && event.memoryUsage);
  runtimeChild.send({ type: "user_message", text: "番茄钟是怎么实现的" });

  const planEvent = await runtimeChild.waitFor((event) => event.type === "plan_updated");
  assert.deepEqual(planEvent.plan.map((step) => step.status), ["in_progress", "pending"]);
  assert.equal(planEvent.plan[0].step, "摸清番茄钟实现");

  const started = await runtimeChild.waitFor((event) => event.type === "subagent_started");
  assert.equal(started.role, "explorer");
  assert.equal(started.label, "番茄钟");

  const done = await runtimeChild.waitFor((event) => event.type === "subagent_done");
  assert.equal(done.ok, true);
  assert.match(done.report, /Pomodoro\.swift/);

  await runtimeChild.waitFor((event) => event.type === "dispatch_done");
  await runtimeChild.waitFor((event) => event.type === "assistant_done");

  runtimeChild.child.stdin.end();
  await new Promise((resolve) => runtimeChild.child.on("close", resolve));
  await new Promise((resolve) => server.close(resolve));

  // 第一轮还没有计划，之后每轮的系统提示都要带上刷新后的计划块
  assert.equal(mainSystemPrompts[0].includes("CURRENT PLAN"), false);
  assert.match(mainSystemPrompts[1], /CURRENT PLAN \[0\/2\]/);
  assert.match(mainSystemPrompts[1], /\[~\] 1\. 摸清番茄钟实现/);

  assert.equal(subAgentToolSets.length, 1);
  assert.equal(subAgentToolSets[0].includes("file_search"), true);
  assert.equal(subAgentToolSets[0].includes("apply_patch"), false, "探路者不该拿到写工具");
  assert.equal(subAgentToolSets[0].includes("dispatch_agents"), false, "子 agent 不该能再派发子 agent");
});

test("parallel sub-agents queue their permission prompts one at a time", async () => {
  const configDir = await mkdtemp(join(tmpdir(), "xuanyu-permqueue-"));
  let mainTurn = 0;
  const subAgentShellSent = new Set();

  const server = createServer((request, response) => {
    let body = "";
    request.on("data", (chunk) => { body += chunk.toString(); });
    request.on("end", () => {
      const payload = JSON.parse(body);
      const messages = payload.messages;
      const system = messages.find((message) => message.role === "system")?.content || "";
      response.writeHead(200, { "content-type": "text/event-stream" });

      if (system.includes("执行者")) {
        // 每个执行者先要一次 shell（需要确认），拿到结果后收尾。
        const goal = messages.find((message) => message.role === "user")?.content || "";
        const tag = goal.includes("任务 A") ? "A" : "B";
        if (!subAgentShellSent.has(tag)) {
          subAgentShellSent.add(tag);
          response.end(sseToolCall("shell", { command: `touch ${tag}.txt` }));
          return;
        }
        response.end(sseText(`执行者 ${tag} 完成`));
        return;
      }

      mainTurn += 1;
      if (mainTurn === 1) {
        response.end(sseToolCall("dispatch_agents", {
          mode: "parallel",
          tasks: [
            { role: "implementer", goal: "任务 A", label: "A" },
            { role: "implementer", goal: "任务 B", label: "B" },
          ],
        }));
        return;
      }
      response.end(sseText("两个子 agent 都完成了。"));
    });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();

  const runtimeChild = startRuntimeChild();
  runtimeChild.send({
    type: "configure",
    apiKey: "test-key",
    configDir,
    config: { baseURL: `http://127.0.0.1:${port}/v1`, model: "fake-model", subAgentConcurrency: 2 },
  });
  await runtimeChild.waitFor((event) => event.type === "ready" && event.memoryUsage);
  runtimeChild.send({ type: "user_message", text: "并行跑两个任务" });

  const first = await runtimeChild.waitFor((event) => event.type === "permission_request");
  // 两个子 agent 都已启动，但只允许有一个确认框在等
  await runtimeChild.waitFor((event) => event.type === "subagent_started" && event.label === "B");
  await new Promise((resolve) => setTimeout(resolve, 250));
  const queued = runtimeChild.events.filter((event) => event.type === "permission_request");
  assert.equal(queued.length, 1, `只应有一个待确认请求，实际 ${queued.length} 个`);

  runtimeChild.send({ type: "approve_tool", id: first.id });
  const second = await runtimeChild.waitFor((event) =>
    event.type === "permission_request" && event.id !== first.id);
  runtimeChild.send({ type: "approve_tool", id: second.id });

  await runtimeChild.waitFor((event) => event.type === "dispatch_done", 6000);
  await runtimeChild.waitFor((event) => event.type === "assistant_done", 6000);

  runtimeChild.child.stdin.end();
  await new Promise((resolve) => runtimeChild.child.on("close", resolve));
  await new Promise((resolve) => server.close(resolve));

  const doneEvents = runtimeChild.events.filter((event) => event.type === "subagent_done");
  assert.equal(doneEvents.length, 2);
  assert.equal(doneEvents.every((event) => event.ok), true);
});

test("the verify gate makes the agent self-check before answering after a write", async () => {
  const configDir = await mkdtemp(join(tmpdir(), "xuanyu-verifygate-"));
  const patch = "*** Begin Patch\n*** Add File: gate.txt\n+content\n*** End Patch";
  const systemPrompts = [];
  let mainTurn = 0;

  const server = createServer((request, response) => {
    let body = "";
    request.on("data", (chunk) => { body += chunk.toString(); });
    request.on("end", () => {
      const payload = JSON.parse(body);
      systemPrompts.push(payload.messages.filter((m) => m.role === "system").map((m) => m.content).join("\n"));
      response.writeHead(200, { "content-type": "text/event-stream" });
      mainTurn += 1;
      if (mainTurn === 1) {
        response.end(sseToolCall("apply_patch", { input: patch }));
        return;
      }
      response.end(sseText("写好了。"));
    });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();

  const runtimeChild = startRuntimeChild();
  runtimeChild.send({
    type: "configure",
    apiKey: "test-key",
    configDir,
    config: {
      baseURL: `http://127.0.0.1:${port}/v1`,
      model: "fake-model",
      approvalPolicy: "never",
      sandboxWorkspacePath: configDir,
    },
  });
  await runtimeChild.waitFor((event) => event.type === "ready" && event.memoryUsage);
  runtimeChild.send({ type: "user_message", text: "建个 gate.txt" });
  await runtimeChild.waitFor((event) => event.type === "assistant_done");

  runtimeChild.child.stdin.end();
  await new Promise((resolve) => runtimeChild.child.on("close", resolve));
  await new Promise((resolve) => server.close(resolve));

  // 第 3 次请求（写入后的那一轮）必须带上自检指令，且整轮只注入一次。
  const gated = systemPrompts.filter((prompt) => prompt.includes("在给最终答复前先自检一次"));
  assert.equal(gated.length, 1, `verify gate should be injected exactly once, got ${gated.length}`);
  assert.match(gated[0], /gate\.txt/);
  assert.equal(mainTurn, 3, "写入 → 自检 → 收尾，一共三轮");
});
