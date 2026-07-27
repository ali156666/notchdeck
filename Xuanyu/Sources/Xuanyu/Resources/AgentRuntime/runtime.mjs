// Generated from src/runtime.ts
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { existsSync } from "node:fs";
import { appendFile, mkdir, readFile, readdir, stat, unlink, writeFile } from "node:fs/promises";
import { basename, dirname, join, resolve } from "node:path";
import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";
import {
  HARNESS_DEFAULTS,
  applyPlanUpdate,
  budgetNotice,
  createLoopGuardState,
  createRunTelemetry,
  harnessStatus,
  loopGuardNotice,
  recordMutation,
  recordToolSignature,
  renderPlanBlock,
  toolCallSignature,
  verificationNotice,
} from "./harness.mjs";
import {
  NOTE_LIMITS,
  NOTE_TYPES,
  extractLinks,
  noteAuditEntries,
  noteFromFlatEntry,
  noteQualityHint,
  noteTokens,
  normalizeNoteName,
  normalizeNoteType,
  parseNote,
  renderNoteIndex,
  renderRecalledNotes,
  selectRecallNotes,
  serializeNote,
  upsertNote,
  validateNote,
} from "./memory.mjs";
import {
  dispatchAgents,
  listAgentRoles,
  normalizeDispatchTasks,
  renderReports,
  runEngineerLoop,
} from "./subagents.mjs";

const DEFAULT_CONFIG = {
  providerId: "default",
  apiProtocol: "openai",
  baseURL: "https://api.openai.com/v1",
  model: "gpt-4.1-mini",
  compactModel: "",
  headers: {},
  temperature: 0.2,
  maxTokens: 4096,
  contextLimit: 128_000,
  historyLimit: 40,
  memoryEnabled: true,
  memoryNotesEnabled: true,
  memoryAutoRecallLimit: 3,
  userProfileEnabled: true,
  memoryCharLimit: 2200,
  userCharLimit: 1375,
  sessionSearchLimit: 8,
  semanticSearchEnabled: true,
  embeddingModel: "",
  embeddingBaseURL: "",
  embeddingDimension: 256,
  autoMemoryEnabled: true,
  autoTitleEnabled: true,
  evolutionEnabled: true,
  lazyModeEnabled: false,
  approvalPolicy: "on-request",
  harnessEnabled: true,
  planningEnabled: true,
  verifyGateEnabled: true,
  multiAgentEnabled: true,
  maxToolTurns: HARNESS_DEFAULTS.maxToolTurns,
  subAgentConcurrency: 3,
  subAgentMaxTurns: 0,
  mcpServers: [],
  customSkills: [],
};

const runtime = {
  configured: false,
  config: { ...DEFAULT_CONFIG },
  apiKey: "",
  configDir: "",
  skillsRoot: "",
  managedSkillsRoot: "",
  historyPath: "",
  sessionsPath: "",
  embeddingIndexPath: "",
  memoryPath: "",
  userProfilePath: "",
  evolutionPath: "",
  messages: [],
  contextSummary: "",
  skills: [],
  memorySnapshot: { memory: [], user: [] },
  sessionId: randomUUID(),
  mcpClients: new Map(),
  pendingPermissions: new Map(),
  activeProcesses: new Set(),
  cancelledSessions: new Set(),
  abortController: null,
  abortControllers: new Set(),
  fileSearchCache: new Map(),
  backgroundTasks: new Set(),
  notesRoot: "",
  notes: [],
  recalledNotes: [],
  noteVectorCache: new Map(),
  plan: [],
  telemetry: null,
  loopGuard: createLoopGuardState(),
  activeSubAgents: new Map(),
};

const MAX_ATTACHMENT_TEXT_BYTES = 180_000;
const DEFAULT_LOCAL_PROCESS_TIMEOUT_MS = 30_000;
const MAX_LOCAL_PROCESS_TIMEOUT_MS = 120_000;
const AUTO_COMPACT_RATIO = 0.8;
const COMPACT_KEEP_RECENT_MESSAGES = 12;
const STREAM_DELTA_FLUSH_MS = 40;
const STREAM_DELTA_FLUSH_CHARS = 240;
const FILE_SEARCH_CACHE_TTL_MS = 15_000;
const TEXT_EXTENSIONS = new Set([
  ".c", ".cc", ".cpp", ".css", ".csv", ".go", ".h", ".hpp", ".html", ".java", ".js", ".json", ".jsx",
  ".kt", ".log", ".m", ".md", ".mm", ".php", ".plist", ".py", ".rb", ".rs", ".sh", ".sql", ".swift",
  ".toml", ".ts", ".tsx", ".txt", ".xml", ".yaml", ".yml",
]);

function send(event) {
  process.stdout.write(`${JSON.stringify(event)}\n`);
}

function createAssistantDeltaEmitter(options = {}) {
  const messageId = options.messageId || "assistant-current";
  const sessionId = options.sessionId || runtime.sessionId;
  const agent = options.agentContext || null;
  const emitDelta = options.emitDelta !== false;
  let pending = "";
  let timer = null;

  const flush = () => {
    if (timer) {
      clearTimeout(timer);
      timer = null;
    }
    if (!emitDelta || !pending) return;
    // 子 agent 的输出走独立事件，避免混进主对话的助手气泡。
    if (agent) {
      send({ type: "subagent_delta", sessionId, agentId: agent.agentId, role: agent.role, label: agent.label, delta: pending });
    } else {
      send({ type: "assistant_delta", sessionId, messageId, delta: pending });
    }
    pending = "";
  };

  const schedule = () => {
    if (timer || !emitDelta) return;
    timer = setTimeout(flush, STREAM_DELTA_FLUSH_MS);
    timer.unref?.();
  };

  return {
    push(delta) {
      const value = String(delta || "");
      if (!emitDelta || !value) return;
      pending += value;
      if (pending.length >= STREAM_DELTA_FLUSH_CHARS) flush();
      else schedule();
    },
    flush,
  };
}

function normalizeAssistantText(text) {
  return String(text || "")
    .replace(/([。！？!?])(?=\S)/g, "$1\n\n")
    .replace(/(:)(?=(Now|Let|I\s|Here|下面|现在|接下来|然后)\b)/g, "$1\n\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

export function openAITextContent(value) {
  if (typeof value === "string") return value;
  if (!Array.isArray(value)) return "";
  return value.map((part) => {
    if (typeof part === "string") return part;
    if (typeof part?.text === "string") return part.text;
    if (typeof part?.text?.value === "string") return part.text.value;
    if (typeof part?.content === "string") return part.content;
    return "";
  }).join("");
}

function parseJSON(value, fallback = null) {
  try {
    return JSON.parse(value);
  } catch {
    return fallback;
  }
}

function boundedNumber(value, fallback, min, max) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(Math.max(Math.trunc(parsed), min), max);
}

export function estimateTokens(text, model = "") {
  void model;
  const value = String(text ?? "");
  if (!value) return 0;
  let cjkCount = 0;
  let otherCount = 0;
  for (const char of value) {
    const cp = char.codePointAt(0);
    if ((cp >= 0x1100 && cp <= 0xFFEF) || (cp >= 0x20000 && cp <= 0x2FA1F)) {
      cjkCount += 1;
    } else {
      otherCount += 1;
    }
  }
  return Math.max(1, Math.ceil((cjkCount * 2) / 3 + otherCount / 4));
}

function historyCountLimit() {
  return boundedNumber(runtime.config.historyLimit, DEFAULT_CONFIG.historyLimit, 1, 100_000);
}

function contextCharLimit() {
  const raw = Number(runtime.config.contextLimit);
  let value = Number.isFinite(raw) ? Math.trunc(raw) : DEFAULT_CONFIG.contextLimit;
  // Legacy migration: values above 200_000 came from the old char-based config
  // (previous default was 1_000_000 chars). Convert to tokens (~4 chars/token).
  if (value > 200_000) value = Math.round(value / 4);
  return Math.min(Math.max(value, 1_000), 2_000_000);
}

function normalizeHistoryMessages(messages) {
  return (Array.isArray(messages) ? messages : [])
    .map((message) => ({
      role: message?.role === "assistant" ? "assistant" : message?.role === "user" ? "user" : "",
      content: String(message?.content ?? message?.text ?? ""),
    }))
    .filter((message) => (message.role === "user" || message.role === "assistant") && message.content.trim());
}

function messageContextSize(message) {
  return estimateTokens(String(message?.content ?? "")) + 4;
}

function contextBoundedHistory(messages) {
  const recent = normalizeHistoryMessages(messages).slice(-historyCountLimit());
  const limit = contextCharLimit();
  const selected = [];
  let used = 0;
  for (let index = recent.length - 1; index >= 0; index -= 1) {
    const message = recent[index];
    const size = messageContextSize(message);
    if (selected.length > 0 && used + size > limit) break;
    selected.unshift(message);
    used += size;
  }
  return selected;
}

export function contextUsageFor(messages, contextSummary = "", limit = DEFAULT_CONFIG.contextLimit) {
  const normalized = normalizeHistoryMessages(messages);
  const summaryText = String(contextSummary || "").trim();
  const summarySize = summaryText ? estimateTokens(summaryText) + 4 : 0;
  const used = normalized.reduce((sum, message) => sum + messageContextSize(message), summarySize);
  const boundedLimit = boundedNumber(limit, DEFAULT_CONFIG.contextLimit, 1_000, 2_000_000);
  return {
    used,
    limit: boundedLimit,
    percent: boundedLimit ? Math.min(999, Math.round((used / boundedLimit) * 100)) : 0,
  };
}

export function shouldAutoCompact(messages, contextSummary = "", limit = DEFAULT_CONFIG.contextLimit) {
  const usage = contextUsageFor(messages, contextSummary, limit);
  return usage.used >= Math.floor(usage.limit * AUTO_COMPACT_RATIO);
}

function summarySystemMessage() {
  const summary = String(runtime.contextSummary || "").trim();
  if (!summary) return null;
  return {
    role: "system",
    content: `Conversation context summary from earlier compressed turns:\n${summary}`,
  };
}

function contextMessagesForTurn(userText) {
  return [
    { role: "system", content: systemPromptFor(userText) },
    summarySystemMessage(),
    ...contextBoundedHistory(runtime.messages),
  ].filter(Boolean);
}

function emitContextUsage() {
  send({ type: "context_usage", ...contextUsageFor(runtime.messages, runtime.contextSummary, contextCharLimit()) });
}

function splitEntries(text) {
  return String(text || "")
    .split(/\n\s*§\s*\n/)
    .map((entry) => entry.trim())
    .filter(Boolean);
}

function joinEntries(entries) {
  return entries.map((entry) => String(entry).trim()).filter(Boolean).join("\n§\n");
}

function memoryUsage(entries, limit) {
  const used = joinEntries(entries).length;
  return { used, limit, percent: limit ? Math.round((used / limit) * 100) : 0 };
}

function validateMemoryContent(content) {
  const value = String(content || "").trim();
  if (!value) return "Memory content is empty.";
  if (/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff]/u.test(value)) {
    return "Memory contains hidden or control characters.";
  }
  if (/(ignore|disregard)\s+(all\s+)?((previous|prior)\s+system|previous|prior|system)\s+instructions|begin\s+(rsa|openssh|ec)\s+private\s+key|sk-[a-z0-9_-]{16,}/iu.test(value)) {
    return "Memory content was rejected by the prompt-injection and secret scanner.";
  }
  return "";
}

export function mutateMemoryEntries(entries, request, limit) {
  const current = Array.isArray(entries) ? entries.map(String) : [];
  const action = String(request?.action || "");
  const content = String(request?.content || "").trim();
  const oldText = String(request?.old_text || request?.oldText || "").trim();
  let updated = [...current];

  if (action === "add") {
    const error = validateMemoryContent(content);
    if (error) return { ok: false, error, entries: current };
    if (current.includes(content)) {
      return { ok: true, unchanged: true, message: "Exact duplicate already exists.", entries: current, usage: memoryUsage(current, limit) };
    }
    updated.push(content);
  } else if (action === "replace" || action === "remove") {
    if (!oldText) return { ok: false, error: "old_text is required.", entries: current };
    const matches = current.map((entry, index) => entry.includes(oldText) ? index : -1).filter((index) => index >= 0);
    if (matches.length !== 1) {
      return { ok: false, error: `old_text matched ${matches.length} entries; provide a unique substring.`, entries: current };
    }
    if (action === "replace") {
      const error = validateMemoryContent(content);
      if (error) return { ok: false, error, entries: current };
      updated[matches[0]] = content;
    } else {
      updated.splice(matches[0], 1);
    }
  } else {
    return { ok: false, error: `Unknown memory action: ${action}`, entries: current };
  }

  const usage = memoryUsage(updated, limit);
  if (usage.used > limit) {
    return { ok: false, error: `Memory at ${memoryUsage(current, limit).used}/${limit} chars. This change would exceed the limit. Consolidate or remove entries first.`, entries: current, usage: memoryUsage(current, limit) };
  }
  return { ok: true, entries: updated, usage };
}

function recordSearchText(record) {
  return `${record?.role || ""} ${record?.content || ""}`.toLowerCase();
}

function searchTokens(text) {
  const value = String(text || "").toLowerCase();
  const words = value.match(/[\p{L}\p{N}_./:-]+/gu) || [];
  const han = value.match(/\p{Script=Han}/gu) || [];
  const hanBigrams = [];
  for (let index = 0; index < han.length - 1; index += 1) {
    hanBigrams.push(`${han[index]}${han[index + 1]}`);
  }
  return [...words, ...han, ...hanBigrams].map((token) => token.trim()).filter(Boolean);
}

export function searchSessionRecords(records, query, limit = 8) {
  const tokens = searchTokens(query);
  if (!tokens.length) return [];
  return (Array.isArray(records) ? records : [])
    .map((record) => {
      const haystack = recordSearchText(record);
      const score = tokens.reduce((total, token) => total + (haystack.includes(token) ? 1 : 0), 0);
      return { ...record, score };
    })
    .filter((record) => record.score > 0)
    .sort((left, right) => right.score - left.score || String(right.createdAt || "").localeCompare(String(left.createdAt || "")))
    .slice(0, Math.max(1, Number(limit) || 8));
}

function hashText(value) {
  let hash = 2166136261;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 16777619) >>> 0;
  }
  return hash >>> 0;
}

function normalizeVector(vector) {
  const norm = Math.sqrt(vector.reduce((total, value) => total + value * value, 0));
  if (!norm) return vector;
  return vector.map((value) => Number((value / norm).toFixed(8)));
}

function embeddingTokens(text) {
  const compact = String(text || "").toLowerCase().replace(/\s+/g, " ").trim();
  const base = searchTokens(compact);
  const chars = compact.replace(/\s+/g, "");
  const grams = [];
  for (let size = 2; size <= 4; size += 1) {
    for (let index = 0; index <= chars.length - size; index += 1) {
      grams.push(chars.slice(index, index + size));
    }
  }
  return [...base, ...grams].filter(Boolean).slice(0, 4000);
}

export function localTextEmbedding(text, dimensions = 256) {
  const width = Math.min(Math.max(Number(dimensions) || 256, 64), 2048);
  const vector = Array(width).fill(0);
  for (const token of embeddingTokens(text)) {
    const hash = hashText(token);
    const index = hash % width;
    const sign = (hash >>> 31) ? -1 : 1;
    vector[index] += sign * (1 + Math.min(token.length, 12) / 12);
  }
  return normalizeVector(vector);
}

function cosineSimilarity(left, right) {
  if (!Array.isArray(left) || !Array.isArray(right) || !left.length || left.length !== right.length) return 0;
  let score = 0;
  for (let index = 0; index < left.length; index += 1) {
    score += Number(left[index] || 0) * Number(right[index] || 0);
  }
  return score;
}

export function semanticSearchSessionRecords(records, indexEntries, queryVector, query, limit = 8) {
  const indexByRecordId = new Map((Array.isArray(indexEntries) ? indexEntries : [])
    .filter((entry) => entry?.recordId && Array.isArray(entry.vector))
    .map((entry) => [entry.recordId, entry]));
  const lexical = new Map(searchSessionRecords(records, query, Math.max(50, limit * 4)).map((record) => [record.id, record.score || 0]));
  return (Array.isArray(records) ? records : [])
    .map((record) => {
      const indexed = indexByRecordId.get(record.id);
      const semanticScore = cosineSimilarity(indexed?.vector, queryVector);
      const lexicalScore = lexical.get(record.id) || 0;
      return {
        ...record,
        score: Number((semanticScore + lexicalScore * 0.08).toFixed(6)),
        semanticScore: Number(semanticScore.toFixed(6)),
        lexicalScore,
      };
    })
    .filter((record) => record.score > 0)
    .sort((left, right) => right.score - left.score || String(right.createdAt || "").localeCompare(String(left.createdAt || "")))
    .slice(0, Math.max(1, Number(limit) || 8));
}

export function normalizeBaseURL(baseURL) {
  const value = String(baseURL || "").replace(/\/+$/, "");
  if (!value) return DEFAULT_CONFIG.baseURL;
  if (value.endsWith("/chat/completions")) return value;
  if (/\/v\d+$/i.test(value)) return `${value}/chat/completions`;
  if (/api\.openai\.com$/i.test(value)) return `${value}/v1/chat/completions`;
  return `${value}/chat/completions`;
}

export function normalizeAnthropicURL(baseURL) {
  const value = String(baseURL || "").replace(/\/+$/, "");
  const base = value || "https://api.anthropic.com/v1";
  if (base.endsWith("/messages")) return base;
  if (/\/anthropic$/i.test(base)) return `${base}/v1/messages`;
  if (/\/anthropic\/v\d+$/i.test(base)) return `${base}/messages`;
  if (/\/v\d+$/i.test(base)) return `${base}/messages`;
  if (/api\.anthropic\.com$/i.test(base)) return `${base}/v1/messages`;
  return `${base}/anthropic/v1/messages`;
}

function modelProtocol() {
  const configured = String(runtime.config.apiProtocol || runtime.config.protocol || "").trim().toLowerCase();
  if (configured === "anthropic" || configured === "claude") return "anthropic";
  if (configured === "openai") return "openai";
  const provider = `${runtime.config.providerId || ""} ${runtime.config.baseURL || ""}`.toLowerCase();
  return /anthropic|claude/.test(provider) ? "anthropic" : "openai";
}

function normalizeEmbeddingsURL(baseURL) {
  const configured = String(runtime.config.embeddingBaseURL || "").trim();
  const value = (configured || String(baseURL || "")).replace(/\/+$/, "");
  if (!value) return "";
  if (value.endsWith("/embeddings")) return value;
  if (value.endsWith("/chat/completions")) return value.replace(/\/chat\/completions$/, "/embeddings");
  return `${value}/embeddings`;
}

function sanitizeToolName(value) {
  return String(value).replace(/[^a-zA-Z0-9_-]/g, "_").slice(0, 64);
}

function formatBytes(value) {
  const bytes = Number(value || 0);
  if (!Number.isFinite(bytes) || bytes <= 0) return "0 B";
  const units = ["B", "KB", "MB", "GB"];
  let size = bytes;
  let index = 0;
  while (size >= 1024 && index < units.length - 1) {
    size /= 1024;
    index += 1;
  }
  return `${size.toFixed(index === 0 ? 0 : 1)} ${units[index]}`;
}

function looksTextual(buffer, filePath) {
  const lower = filePath.toLowerCase();
  if ([...TEXT_EXTENSIONS].some((extension) => lower.endsWith(extension))) return true;
  if (!buffer.length) return true;
  const sample = buffer.subarray(0, Math.min(buffer.length, 4096));
  let suspicious = 0;
  for (const byte of sample) {
    if (byte === 0) return false;
    if (byte < 7 || (byte > 14 && byte < 32)) suspicious += 1;
  }
  return suspicious / sample.length < 0.02;
}

async function describeAttachment(attachment, index) {
  const filePath = String(attachment?.path || "");
  const displayName = String(attachment?.name || basename(filePath) || `file-${index + 1}`);
  if (!filePath) return `### ${index + 1}. ${displayName}\n- status: missing path`;
  const absolutePath = resolve(filePath);
  if (!existsSync(absolutePath)) {
    return `### ${index + 1}. ${displayName}\n- path: ${absolutePath}\n- status: file not found`;
  }

  const info = await stat(absolutePath);
  const header = [
    `### ${index + 1}. ${displayName}`,
    `- path: ${absolutePath}`,
    `- type: ${attachment?.typeIdentifier || (info.isDirectory() ? "directory" : "file")}`,
    `- size: ${formatBytes(info.size)}`,
  ];

  if (info.isDirectory()) {
    const entries = await readdir(absolutePath, { withFileTypes: true });
    const listed = entries
      .slice(0, 80)
      .map((entry) => `${entry.isDirectory() ? "dir " : "file"} ${entry.name}`)
      .join("\n");
    return `${header.join("\n")}\n- directory entries shown: ${Math.min(entries.length, 80)} of ${entries.length}\n\n\`\`\`text\n${listed}\n\`\`\``;
  }

  if (info.size > MAX_ATTACHMENT_TEXT_BYTES) {
    return `${header.join("\n")}\n- content: skipped because file is larger than ${formatBytes(MAX_ATTACHMENT_TEXT_BYTES)}.`;
  }

  const data = await readFile(absolutePath);
  if (!looksTextual(data, absolutePath)) {
    return `${header.join("\n")}\n- content: binary or non-text file; identified by path, type and size only.`;
  }

  const text = data.toString("utf8").replace(/\u0000/g, "");
  const preview = text.length > 120_000 ? `${text.slice(0, 120_000)}\n...[truncated]` : text;
  return `${header.join("\n")}\n- content: readable text\n\n\`\`\`text\n${preview}\n\`\`\``;
}

export async function buildAttachmentContext(attachments) {
  const values = (Array.isArray(attachments) ? attachments : []).filter((attachment) => attachment && attachment.path);
  if (!values.length) return "";
  const descriptions = await Promise.all(values.map(async (attachment, index) => {
    try {
      return await describeAttachment(attachment, index);
    } catch (error) {
      return `### ${index + 1}. ${attachment?.name || attachment?.path || "file"}\n- status: read failed: ${error.message || String(error)}`;
    }
  }));
  return [
    "用户上传或拖入了以下本机文件。先根据文件类型、路径、大小和可读取内容识别文件，再回答用户问题。",
    ...descriptions,
  ].join("\n\n");
}

function isReadOnlyTool(tool) {
  const annotations = tool.annotations || {};
  if (annotations.readOnlyHint === true || annotations.readOnly === true) return true;
  const name = String(tool.name || "").toLowerCase();
  return /^(list|get|read|search|find|inspect|describe|status|weather|time)/.test(name);
}

export function classifyToolRisk(tool, args = {}, policyOverride) {
  if (!tool) return "confirm";
  const policy = String(policyOverride || runtime.config.approvalPolicy || "on-request").toLowerCase();
  const lazy = runtime.config.lazyModeEnabled === true;
  // Global auto-approve modes (only when no explicit policy override is forcing a base evaluation).
  if (!policyOverride && (lazy || policy === "never" || policy === "on-failure")) return "auto";
  if (policyOverride === "never" || policyOverride === "on-failure") return "auto";
  if (
    tool.kind === "skill_read" ||
    tool.kind === "list_skills" ||
    tool.kind === "file_search" ||
    tool.kind === "memory_manage" ||
    tool.kind === "memory_note_write" ||
    tool.kind === "memory_recall" ||
    tool.kind === "session_search" ||
    tool.kind === "propose_skill_evolution" ||
    tool.kind === "list_evolution_candidates" ||
    tool.kind === "update_plan" ||
    // 派发本身不做任何事；子 agent 调用的每个危险工具仍会各自弹权限确认。
    tool.kind === "dispatch_agents" ||
    tool.kind === "engineer_loop"
  ) return "auto";
  if (tool.kind === "apply_skill_evolution") return "confirm";
  if (tool.kind === "shell" || tool.kind === "skill_script") {
    const analysis = analyzeCommand(String(args?.command ?? args?.script ?? ""));
    return (analysis.writes || analysis.network || analysis.destructive || analysis.unknown) ? "confirm" : "auto";
  }
  if (tool.kind === "apply_patch") return "confirm";
  if (tool.kind === "mcp" && isReadOnlyTool(tool)) return "auto";
  return "confirm";
}

const NETWORK_BINS = new Set([
  "curl", "wget", "nc", "ncat", "netcat", "ssh", "scp", "sftp", "telnet", "ftp",
  "rsync", "ping", "dig", "nslookup", "host", "http", "https",
]);
const WRITE_BINS = new Set([
  "cp", "mv", "mkdir", "touch", "ln", "install", "dd", "tee", "truncate",
  "chmod", "chown", "chgrp", "patch", "apply_patch", "npm", "pip", "pip3",
]);
const DESTRUCTIVE_BINS = new Set([
  "rm", "rmdir", "shred", "unlink", "mkfs", "fdisk", "kill", "killall", "pkill",
  "reboot", "shutdown", "halt", "diskutil",
]);

export function analyzeCommand(command) {
  const cmd = String(command || "");
  const result = { writes: false, network: false, destructive: false, unknown: false, reason: "" };
  const trimmed = cmd.trim();
  if (!trimmed) {
    result.unknown = true;
    result.reason = "empty";
    return result;
  }
  const reasons = [];
  // Output redirection (> or >>) implies a write, ignoring 2>&1-style fd dups.
  if (/(^|[^0-9>&])>>?\s*[^&\s]/.test(cmd)) {
    result.writes = true;
    reasons.push("redirect");
  }
  const segments = cmd.split(/(?:&&|\|\||[;|\n])/).map((seg) => seg.trim()).filter(Boolean);
  for (const seg of segments) {
    const tokens = seg.split(/\s+/);
    let bin = (tokens[0] || "").replace(/^.*\//, "").toLowerCase();
    let rest = tokens.slice(1);
    if (bin === "sudo") {
      result.destructive = true;
      reasons.push("sudo");
      bin = (rest[0] || "").replace(/^.*\//, "").toLowerCase();
      rest = rest.slice(1);
    }
    if (!bin) continue;
    if (NETWORK_BINS.has(bin)) { result.network = true; reasons.push(`network:${bin}`); }
    if (DESTRUCTIVE_BINS.has(bin)) { result.destructive = true; result.writes = true; reasons.push(`destructive:${bin}`); }
    if (WRITE_BINS.has(bin)) { result.writes = true; reasons.push(`write:${bin}`); }
    if (bin === "sed" && rest.some((token) => /^-[a-z]*i/i.test(token) || token === "--in-place")) {
      result.writes = true;
      reasons.push("write:sed-i");
    }
    if (bin === "git") {
      const sub = (rest[0] || "").toLowerCase();
      if (["push", "commit", "reset", "clean", "rm", "checkout", "merge", "rebase", "apply", "stash"].includes(sub)) {
        result.writes = true;
        if (sub === "push") result.network = true;
        if (["reset", "clean", "rm", "checkout"].includes(sub)) result.destructive = true;
        reasons.push(`git:${sub}`);
      }
    }
  }
  result.reason = reasons.join(",") || "read-only";
  return result;
}

export function fuzzyRank(names, query) {
  if (!query) return (Array.isArray(names) ? names.slice() : []);
  const q = String(query).toLowerCase();
  const scored = [];
  const list = Array.isArray(names) ? names : [];
  for (let i = 0; i < list.length; i += 1) {
    const name = list[i];
    const lower = String(name).toLowerCase();
    let qi = 0;
    let first = -1;
    let last = -1;
    for (let ni = 0; ni < lower.length && qi < q.length; ni += 1) {
      if (lower[ni] === q[qi]) {
        if (first === -1) first = ni;
        last = ni;
        qi += 1;
      }
    }
    if (qi < q.length) continue;
    scored.push({ name, span: last - first, index: i });
  }
  scored.sort((a, b) => a.span - b.span || a.index - b.index);
  return scored.map((item) => item.name);
}

const FILE_SEARCH_SKIP_DIRS = new Set(["node_modules", ".git", ".build", "dist", ".swiftpm"]);
const FILE_SEARCH_DEFAULT_LIMIT = 50;
const FILE_SEARCH_HARD_CAP = 200;

async function walkFilePaths(root, current, acc) {
  let entries;
  try {
    entries = await readdir(current, { withFileTypes: true });
  } catch {
    return acc;
  }
  for (const entry of entries) {
    if (entry.isDirectory()) {
      if (FILE_SEARCH_SKIP_DIRS.has(entry.name)) continue;
      await walkFilePaths(root, join(current, entry.name), acc);
    } else if (entry.isFile()) {
      acc.push(join(current, entry.name).slice(root.length + 1));
    }
  }
  return acc;
}

async function cachedFilePaths(root) {
  const absoluteRoot = resolve(root);
  const cached = runtime.fileSearchCache.get(absoluteRoot);
  if (cached && Date.now() - cached.createdAt < FILE_SEARCH_CACHE_TTL_MS) {
    return cached.paths;
  }
  const paths = await walkFilePaths(absoluteRoot, absoluteRoot, []);
  runtime.fileSearchCache.set(absoluteRoot, { createdAt: Date.now(), paths });
  return paths;
}

function fileSearchLimit(limit) {
  return Math.min(Math.max(Number(limit) || FILE_SEARCH_DEFAULT_LIMIT, 1), FILE_SEARCH_HARD_CAP);
}

export async function searchFileNames(root, query, { limit = FILE_SEARCH_DEFAULT_LIMIT } = {}) {
  const cap = fileSearchLimit(limit);
  const allPaths = await cachedFilePaths(root);
  return fuzzyRank(allPaths, query).slice(0, cap);
}

export async function searchFileContent(root, query, { limit = FILE_SEARCH_DEFAULT_LIMIT } = {}) {
  const cap = fileSearchLimit(limit);
  const allPaths = await cachedFilePaths(root);
  const lowerQuery = String(query).toLowerCase();
  const results = [];
  for (const rel of allPaths) {
    if (results.length >= cap) break;
    let text;
    try {
      text = await readFile(join(root, rel), "utf8");
    } catch {
      continue;
    }
    const lines = text.split("\n");
    for (let i = 0; i < lines.length && results.length < cap; i += 1) {
      if (lines[i].toLowerCase().includes(lowerQuery)) {
        results.push(`${rel}:${i + 1}: ${lines[i].trim()}`);
      }
    }
  }
  return results;
}

async function runFileSearch(args) {
  const root = resolve(String(args.path || runtime.configDir || process.cwd()));
  const query = String(args.query || "");
  const mode = String(args.mode || "name");
  const limit = fileSearchLimit(args.limit);
  if (!query) return { ok: false, content: "file_search requires a non-empty query." };
  try {
    const results = mode === "content"
      ? await searchFileContent(root, query, { limit })
      : await searchFileNames(root, query, { limit });
    return { ok: true, content: JSON.stringify({ query, mode, root, count: results.length, results }) };
  } catch (error) {
    return { ok: false, content: error?.message || String(error) };
  }
}

async function walkSkills(root, current = root, found = []) {
  if (!existsSync(current)) return found;
  const entries = await readdir(current, { withFileTypes: true });
  for (const entry of entries) {
    const fullPath = join(current, entry.name);
    if (entry.isDirectory()) {
      await walkSkills(root, fullPath, found);
    } else if (entry.isFile() && entry.name === "SKILL.md") {
      const text = await readFile(fullPath, "utf8");
      const rel = fullPath.slice(root.length + 1);
      const folder = basename(dirname(fullPath));
      const titleMatch = text.match(/^#\s+(.+)$/m);
      const firstParagraph = text
        .replace(/^#.*$/m, "")
        .split(/\n\s*\n/)
        .map((part) => part.trim())
        .find(Boolean) || "";
      found.push({
        name: folder,
        title: titleMatch ? titleMatch[1].trim() : folder,
        path: rel,
        absolutePath: fullPath,
        summary: firstParagraph.slice(0, 600),
        content: text,
      });
    }
  }
  return found;
}

export async function discoverSkills(root) {
  return walkSkills(root);
}

export function normalizeConfiguredSkills(skills) {
  return (Array.isArray(skills) ? skills : [])
    .filter((skill) => skill && skill.enabled !== false && skill.name && skill.content)
    .map((skill) => {
      const content = String(skill.content);
      const title = String(skill.title || skill.name);
      const summary = content
        .replace(/^#.*$/m, "")
        .split(/\n\s*\n/)
        .map((part) => part.trim())
        .find(Boolean) || "";
      return {
        name: sanitizeToolName(skill.name),
        title,
        path: `config:${skill.id || skill.name}`,
        absolutePath: "",
        summary: summary.slice(0, 600),
        content,
      };
    });
}

async function readEntries(path) {
  if (!path || !existsSync(path)) return [];
  return splitEntries(await readFile(path, "utf8"));
}

async function writeEntries(path, entries) {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, joinEntries(entries));
}

async function ensureFile(path, initialContent = "") {
  await mkdir(dirname(path), { recursive: true });
  if (!existsSync(path)) await writeFile(path, initialContent);
}

async function initializePersistentStores() {
  await mkdir(runtime.managedSkillsRoot, { recursive: true });
  await ensureFile(runtime.sessionsPath);
  await ensureFile(runtime.embeddingIndexPath);
  await ensureFile(runtime.evolutionPath, "[]\n");
  if (runtime.config.memoryEnabled !== false) await ensureFile(runtime.memoryPath);
  if (runtime.config.userProfileEnabled !== false) await ensureFile(runtime.userProfilePath);
}

function memoryPathFor(target) {
  return target === "user" ? runtime.userProfilePath : runtime.memoryPath;
}

function memoryLimitFor(target) {
  return target === "user" ? Number(runtime.config.userCharLimit) : Number(runtime.config.memoryCharLimit);
}

async function loadMemorySnapshot() {
  runtime.memorySnapshot = {
    memory: runtime.config.memoryEnabled === false ? [] : await readEntries(runtime.memoryPath),
    user: runtime.config.userProfileEnabled === false ? [] : await readEntries(runtime.userProfilePath),
  };
}

async function manageMemory(args) {
  const target = args.target === "user" ? "user" : "memory";
  if ((target === "memory" && runtime.config.memoryEnabled === false) || (target === "user" && runtime.config.userProfileEnabled === false)) {
    return { ok: false, content: `${target} memory is disabled.` };
  }
  const path = memoryPathFor(target);
  const entries = await readEntries(path);
  const result = mutateMemoryEntries(entries, args, memoryLimitFor(target));
  if (result.ok && !result.unchanged) {
    await writeEntries(path, result.entries);
    await loadMemorySnapshot();
    send({ type: "memory_updated", target, usage: result.usage });
    await sendMemoryAudit();
  }
  return { ok: result.ok, content: JSON.stringify({ target, ...result }) };
}

function memoryEntryObjects(target, entries) {
  return entries.map((text, index) => ({ id: `${target}:${index}`, target, index, text }));
}

async function sendMemoryAudit() {
  const memory = runtime.config.memoryEnabled === false ? [] : await readEntries(runtime.memoryPath);
  const user = runtime.config.userProfileEnabled === false ? [] : await readEntries(runtime.userProfilePath);
  send({
    type: "memory_audit",
    memory: memoryEntryObjects("memory", memory),
    user: memoryEntryObjects("user", user),
    notes: notesEnabled() ? noteAuditEntries(runtime.notes) : [],
    memoryUsage: {
      memory: memoryUsage(memory, memoryLimitFor("memory")),
      user: memoryUsage(user, memoryLimitFor("user")),
    },
  });
}

async function mutateMemoryEntryByIndex(args, action) {
  const target = args.target === "user" ? "user" : "memory";
  const path = memoryPathFor(target);
  const entries = await readEntries(path);
  const index = Number(args.index);
  if (!Number.isInteger(index) || index < 0 || index >= entries.length) {
    send({ type: "error", message: `Memory entry index is out of range: ${args.index}` });
    return;
  }
  const oldText = String(args.oldText || args.old_text || args.text || "");
  if (oldText && entries[index] !== oldText) {
    send({ type: "error", message: "Memory entry changed before this edit. Refresh and try again." });
    return;
  }
  const request = action === "remove"
    ? { action: "remove", old_text: entries[index] }
    : { action: "replace", old_text: entries[index], content: args.content };
  const result = mutateMemoryEntries(entries, request, memoryLimitFor(target));
  if (!result.ok) {
    send({ type: "error", message: result.error || "Memory edit failed." });
    return;
  }
  await writeEntries(path, result.entries);
  await loadMemorySnapshot();
  send({ type: "memory_updated", target, usage: result.usage });
  await sendMemoryAudit();
}

function todayStamp() {
  return new Date().toISOString().slice(0, 10);
}

function noteFilePath(name) {
  return join(runtime.notesRoot, `${name}.md`);
}

async function loadNotes() {
  runtime.notes = [];
  if (!runtime.notesRoot || !existsSync(runtime.notesRoot)) return;
  const entries = await readdir(runtime.notesRoot, { withFileTypes: true });
  const notes = [];
  for (const entry of entries) {
    if (!entry.isFile() || !entry.name.endsWith(".md")) continue;
    try {
      const note = parseNote(
        await readFile(join(runtime.notesRoot, entry.name), "utf8"),
        entry.name.replace(/\.md$/, ""),
      );
      if (note) notes.push(note);
    } catch {
      // 单个笔记读坏不该拖垮整个记忆层。
    }
  }
  runtime.notes = notes.sort((left, right) =>
    String(right.updatedAt || "").localeCompare(String(left.updatedAt || "")));
}

function notesEnabled() {
  return runtime.config.memoryEnabled !== false && runtime.config.memoryNotesEnabled !== false;
}

/** 自动召回只用词面匹配：确定、够快，且不需要在建提示时等网络。 */
function recallNotesForText(text, limit) {
  if (!notesEnabled()) return [];
  return selectRecallNotes(runtime.notes, text, { limit });
}

async function noteSemanticScores(query) {
  if (runtime.config.semanticSearchEnabled === false || !runtime.notes.length) return null;
  const queryVector = await textEmbedding(query);
  if (!queryVector?.length) return null;
  const scores = new Map();
  for (const note of runtime.notes) {
    const key = `${note.name}:${note.updatedAt}`;
    let vector = runtime.noteVectorCache.get(key);
    if (!vector) {
      vector = await textEmbedding(`${note.name}\n${note.description}\n${note.body.slice(0, 4000)}`);
      if (vector?.length) runtime.noteVectorCache.set(key, vector);
    }
    if (vector?.length) scores.set(note.name, cosineSimilarity(vector, queryVector));
  }
  return scores;
}

async function recallMemoryNotes(args) {
  if (!notesEnabled()) return { ok: false, content: "记忆笔记已关闭。" };
  const query = String(args?.query || "").trim();
  if (!query) return { ok: false, content: "memory_recall 需要一个非空 query。" };
  const limit = boundedNumber(args?.limit, NOTE_LIMITS.recallNotes, 1, 12);
  const semanticScores = await noteSemanticScores(query);
  const matches = selectRecallNotes(runtime.notes, query, { limit, semanticScores });
  if (!matches.length) {
    return { ok: true, content: JSON.stringify({ query, count: 0, notes: [], hint: "没有匹配的记忆笔记。" }) };
  }
  return {
    ok: true,
    content: JSON.stringify({
      query,
      count: matches.length,
      notes: matches.map((note) => ({
        name: note.name,
        type: note.type,
        description: note.description,
        updatedAt: note.updatedAt,
        links: note.links,
        content: note.body,
      })),
    }),
  };
}

async function writeMemoryNote(args) {
  if (!notesEnabled()) return { ok: false, content: "记忆笔记已关闭。" };
  const name = normalizeNoteName(args?.name);
  if (!name) return { ok: false, content: "name 需要是可作文件名的短标识（会被规范成 kebab-case）。" };
  const existing = runtime.notes.find((note) => note.name === name);
  const now = todayStamp();
  const body = String(args?.content || "").trim();
  const note = {
    name,
    description: String(args?.description || "").replace(/\s+/g, " ").trim().slice(0, NOTE_LIMITS.description),
    type: normalizeNoteType(args?.type),
    createdAt: existing?.createdAt || now,
    updatedAt: now,
    body,
    links: extractLinks(body),
  };

  const error = validateNote(note, { scanContent: validateMemoryContent });
  if (error) return { ok: false, content: JSON.stringify({ error }) };

  const result = upsertNote(runtime.notes, note);
  if (result.error) return { ok: false, content: JSON.stringify({ error: result.error }) };

  await mkdir(runtime.notesRoot, { recursive: true });
  await writeFile(noteFilePath(name), serializeNote(note));
  runtime.notes = result.notes;

  // 热记忆写满时，可以顺手把一条旧的 MEMORY.md 条目搬进笔记腾位置。
  let promoted = "";
  const promoteFrom = String(args?.promote_from_memory || args?.promoteFromMemory || "").trim();
  if (promoteFrom && runtime.config.memoryEnabled !== false) {
    const entries = await readEntries(runtime.memoryPath);
    const removal = mutateMemoryEntries(entries, { action: "remove", old_text: promoteFrom }, memoryLimitFor("memory"));
    if (removal.ok) {
      await writeEntries(runtime.memoryPath, removal.entries);
      await loadMemorySnapshot();
      send({ type: "memory_updated", target: "memory", usage: removal.usage });
      promoted = promoteFrom;
    }
  }

  send({ type: "memory_notes_updated", count: runtime.notes.length, name });
  await sendMemoryAudit();
  return {
    ok: true,
    content: JSON.stringify({
      name,
      type: note.type,
      created: result.created,
      total: runtime.notes.length,
      promotedFromMemory: promoted,
      hint: noteQualityHint(note),
    }),
  };
}

async function forgetMemoryNote(args) {
  if (!notesEnabled()) return { ok: false, content: "记忆笔记已关闭。" };
  const name = normalizeNoteName(args?.name);
  const note = runtime.notes.find((item) => item.name === name);
  if (!note) return { ok: false, content: `没有名为 ${name || args?.name} 的记忆笔记。` };
  const path = noteFilePath(name);
  if (existsSync(path)) await unlink(path);
  runtime.notes = runtime.notes.filter((item) => item.name !== name);
  send({ type: "memory_notes_updated", count: runtime.notes.length, name, removed: true });
  await sendMemoryAudit();
  return { ok: true, content: JSON.stringify({ name, removed: true, total: runtime.notes.length }) };
}

function renderMemoryBlock(target, entries) {
  const label = target === "user" ? "USER PROFILE" : "MEMORY";
  const usage = memoryUsage(entries, memoryLimitFor(target));
  return [
    `════════════════ ${label} [${usage.percent}% — ${usage.used}/${usage.limit} chars] ════════════════`,
    joinEntries(entries) || "(empty)",
  ].join("\n");
}

function embeddingProviderId() {
  const model = String(runtime.config.embeddingModel || "").trim();
  return model ? `remote:${model}` : `local-hash-v1:${Math.min(Math.max(Number(runtime.config.embeddingDimension) || 256, 64), 2048)}`;
}

export function retryDelays({ attempt, retryAfterHeader = null, random = Math.random }) {
  const RETRY_AFTER_CAP_MS = 30_000;
  if (retryAfterHeader != null && retryAfterHeader !== "") {
    const numeric = Number(retryAfterHeader);
    if (Number.isFinite(numeric) && numeric >= 0) {
      return Math.min(numeric * 1000, RETRY_AFTER_CAP_MS);
    }
    const parsed = Date.parse(retryAfterHeader);
    if (!Number.isNaN(parsed)) {
      return Math.min(Math.max(parsed - Date.now(), 0), RETRY_AFTER_CAP_MS);
    }
  }
  const BASE_MS = 500;
  const FACTOR = 2;
  const CAP_MS = 8_000;
  const base = Math.min(BASE_MS * Math.pow(FACTOR, attempt - 1), CAP_MS);
  const jitter = base * 0.5 * random();
  return Math.round(base * 0.75 + jitter);
}

function abortableSleep(ms, signal) {
  return new Promise((resolveSleep, rejectSleep) => {
    if (signal?.aborted) {
      rejectSleep(new DOMException("Aborted", "AbortError"));
      return;
    }
    const id = setTimeout(resolveSleep, ms);
    signal?.addEventListener("abort", () => {
      clearTimeout(id);
      rejectSleep(new DOMException("Aborted", "AbortError"));
    }, { once: true });
  });
}

export async function requestWithRetry(makeRequest, { retries = 3, signal, onRetry, _sleep = abortableSleep } = {}) {
  let lastError;
  for (let attempt = 0; attempt <= retries; attempt += 1) {
    let response;
    try {
      response = await makeRequest();
    } catch (error) {
      if (error?.name === "AbortError" || signal?.aborted) throw error;
      lastError = error;
      if (attempt >= retries) throw error;
      const delayMs = retryDelays({ attempt: attempt + 1 });
      onRetry?.({ attempt: attempt + 1, delayMs, status: null });
      await _sleep(delayMs, signal);
      continue;
    }
    if (response.ok) return response;
    const status = response.status;
    if ((status === 429 || status >= 500) && attempt < retries) {
      const retryAfterHeader = response.headers?.get?.("Retry-After");
      const delayMs = retryDelays({ attempt: attempt + 1, retryAfterHeader });
      onRetry?.({ attempt: attempt + 1, delayMs, status });
      try { await response.body?.cancel(); } catch { /* ignore */ }
      await _sleep(delayMs, signal);
      continue;
    }
    return response;
  }
  throw lastError;
}

async function remoteTextEmbedding(text) {
  const model = String(runtime.config.embeddingModel || "").trim();
  const endpoint = normalizeEmbeddingsURL(runtime.config.baseURL);
  if (!model || !endpoint || !runtime.apiKey) return null;
  const response = await requestWithRetry(
    () => fetch(endpoint, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${runtime.apiKey}`,
        ...(runtime.config.headers || {}),
      },
      body: JSON.stringify({
        model,
        input: String(text || "").slice(0, 12_000),
      }),
    }),
    {
      retries: 3,
      signal: runtime.abortController?.signal,
      onRetry: ({ attempt, delayMs, status }) => send({ type: "model_retry", attempt, delayMs, status }),
    },
  );
  if (!response.ok) throw new Error(`Embedding HTTP ${response.status}: ${(await response.text()).slice(0, 500)}`);
  const parsed = await response.json();
  const vector = parsed?.data?.[0]?.embedding;
  return Array.isArray(vector) ? normalizeVector(vector.map(Number)) : null;
}

async function textEmbedding(text) {
  if (runtime.config.semanticSearchEnabled === false) return null;
  try {
    const remote = await remoteTextEmbedding(text);
    if (remote?.length) return remote;
  } catch (error) {
    // Local hashing keeps recall available when an OpenAI-compatible provider has no embeddings endpoint.
  }
  return localTextEmbedding(text, runtime.config.embeddingDimension);
}

async function readEmbeddingIndex() {
  if (!runtime.embeddingIndexPath || !existsSync(runtime.embeddingIndexPath)) return [];
  const text = await readFile(runtime.embeddingIndexPath, "utf8");
  return text.split(/\n/).map((line) => parseJSON(line)).filter((entry) => entry?.recordId && Array.isArray(entry.vector));
}

async function appendEmbeddingIndex(entry) {
  if (!runtime.embeddingIndexPath) return;
  await mkdir(dirname(runtime.embeddingIndexPath), { recursive: true });
  await appendFile(runtime.embeddingIndexPath, `${JSON.stringify(entry)}\n`);
}

async function indexSessionRecord(record) {
  if (runtime.config.semanticSearchEnabled === false || !record?.id || !record?.content) return;
  const vector = await textEmbedding(`${record.role || ""}\n${String(record.content).slice(0, 20_000)}`);
  if (!vector?.length) return;
  await appendEmbeddingIndex({
    id: randomUUID(),
    recordId: record.id,
    sessionId: record.sessionId,
    provider: embeddingProviderId(),
    createdAt: new Date().toISOString(),
    vector,
  });
}

async function ensureSessionEmbeddingIndex(records) {
  if (runtime.config.semanticSearchEnabled === false) return [];
  const indexEntries = await readEmbeddingIndex();
  const indexedIds = new Set(indexEntries.map((entry) => entry.recordId));
  const missing = records.filter((record) => record?.id && record?.content && !indexedIds.has(record.id));
  for (const record of missing.slice(-200)) {
    await indexSessionRecord(record);
  }
  return missing.length ? await readEmbeddingIndex() : indexEntries;
}

async function appendSessionMessage(message, sessionId = runtime.sessionId) {
  if (!runtime.sessionsPath) return;
  await mkdir(dirname(runtime.sessionsPath), { recursive: true });
  const record = {
    id: randomUUID(),
    sessionId,
    createdAt: new Date().toISOString(),
    ...message,
  };
  await appendFile(runtime.sessionsPath, `${JSON.stringify(record)}\n`);
  scheduleBackgroundTask(indexSessionRecord(record));
  return record;
}

function isCurrentSession(sessionId) {
  return String(sessionId || "") === String(runtime.sessionId || "");
}

function isCancelledSession(sessionId) {
  return runtime.cancelledSessions.has(String(sessionId || ""));
}

function scheduleBackgroundTask(promise) {
  const task = Promise.resolve(promise).catch((error) => {
    send({ type: "tool_result", id: randomUUID(), tool: "background", ok: false, content: error?.message || String(error) });
  });
  runtime.backgroundTasks.add(task);
  task.finally(() => runtime.backgroundTasks.delete(task));
  return task;
}

async function readSessionRecords() {
  if (!runtime.sessionsPath || !existsSync(runtime.sessionsPath)) return [];
  const text = await readFile(runtime.sessionsPath, "utf8");
  return text.split(/\n/).map((line) => parseJSON(line)).filter(Boolean);
}

async function searchSessions(args) {
  const records = await readSessionRecords();
  const limit = Math.min(Math.max(Number(args.limit) || Number(runtime.config.sessionSearchLimit) || 8, 1), 30);
  if (runtime.config.semanticSearchEnabled !== false) {
    const indexEntries = await ensureSessionEmbeddingIndex(records);
    const queryVector = await textEmbedding(String(args.query || ""));
    const matches = semanticSearchSessionRecords(records, indexEntries, queryVector, args.query, limit);
    if (matches.length) {
      return { ok: true, content: JSON.stringify({ query: args.query, mode: "semantic", count: matches.length, matches }) };
    }
  }
  const matches = searchSessionRecords(records, args.query, limit);
  return { ok: true, content: JSON.stringify({ query: args.query, mode: "lexical", count: matches.length, matches }) };
}

function stripAttachmentContext(text) {
  return String(text || "")
    .split(/\n\n用户上传或拖入了以下本机文件。/)[0]
    .replace(/```[\s\S]*?```/g, "")
    .trim();
}

function cleanOneLine(text) {
  return String(text || "")
    .replace(/\s+/g, " ")
    .replace(/^[，。！？、；：\s]+|[，。！？、；：\s]+$/g, "")
    .trim();
}

function firstMeaningfulSentence(text) {
  const value = stripAttachmentContext(text);
  const parts = value.split(/[。！？!?;\n]/).map(cleanOneLine).filter(Boolean);
  return parts[0] || cleanOneLine(value);
}

function truncateHumanText(text, limit = 84) {
  const value = cleanOneLine(text);
  return value.length > limit ? `${value.slice(0, limit)}...` : value;
}

export function generateConversationTitle(userText, assistantText = "") {
  const user = firstMeaningfulSentence(userText)
    .replace(/^(请|请你|帮我|现在|然后|就是|能不能|可以|麻烦你|给我)\s*/u, "")
    .replace(/^(把|将)\s*/u, "");
  const lower = `${userText}\n${assistantText}`.toLowerCase();
  if (/embedding|语义检索|向量/.test(lower) && /记忆|memory/.test(lower)) return "悬屿语义记忆";
  if (/embedding|语义检索|向量/.test(lower)) return "悬屿语义检索";
  if (/置顶|归档|搜索/.test(lower) && /对话|conversation/.test(lower)) return "对话列表管理";
  if (/标题/.test(user) && /自动/.test(user)) return "自动对话标题";
  if (/文件|文件夹|拖/.test(user) && /识别|读取|分析/.test(user)) return "文件识别分析";
  if (!user) return "新对话";
  return truncateHumanText(user, 18);
}

function memoryDedupeKey(text) {
  return cleanOneLine(text).toLowerCase().replace(/[^\p{L}\p{N}]+/gu, "");
}

function shouldRememberUserPreference(text) {
  return /(以后|每次|默认|不要|别|不需要|保留|我想|我要|我希望|偏好|喜欢|不喜欢|不用|必须|要支持)/u.test(text);
}

function shouldRememberProjectFact(text) {
  return /(悬屿|xuanyu|agent|mcp|skill|记忆|上下文|embedding|语义检索|对话|标题|置顶|归档|搜索|airpods|音乐|歌词|番茄钟|快捷|日程|天气|日历)/iu.test(text);
}

export function extractAutomaticMemoryCandidates(userText, assistantText = "") {
  const sentence = firstMeaningfulSentence(userText);
  if (!sentence) return [];
  const candidates = [];
  if (shouldRememberUserPreference(sentence)) {
    candidates.push({
      target: "user",
      content: `用户偏好/要求：${truncateHumanText(sentence, 180)}`,
    });
  }
  if (shouldRememberProjectFact(sentence)) {
    candidates.push({
      target: "memory",
      content: `悬屿需求/事实：${truncateHumanText(sentence, 220)}`,
    });
  }
  const assistant = firstMeaningfulSentence(assistantText);
  if (/已(实现|修复|完成|加入|支持)|通过|打包|验证/.test(assistant) && shouldRememberProjectFact(`${sentence}\n${assistant}`)) {
    candidates.push({
      target: "memory",
      content: `悬屿进展：${truncateHumanText(assistant, 220)}`,
    });
  }
  const seen = new Set();
  return candidates.filter((candidate) => {
    const key = `${candidate.target}:${memoryDedupeKey(candidate.content)}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  }).slice(0, 4);
}

async function addMemoryCandidate(candidate) {
  const target = candidate.target === "user" ? "user" : "memory";
  if ((target === "memory" && runtime.config.memoryEnabled === false) || (target === "user" && runtime.config.userProfileEnabled === false)) return false;
  const content = cleanOneLine(candidate.content);
  if (!content) return false;
  const path = memoryPathFor(target);
  const entries = await readEntries(path);
  const candidateKey = memoryDedupeKey(content);
  if (entries.some((entry) => {
    const entryKey = memoryDedupeKey(entry);
    return entryKey === candidateKey || entryKey.includes(candidateKey) || candidateKey.includes(entryKey);
  })) {
    return false;
  }
  const result = mutateMemoryEntries(entries, { action: "add", content }, memoryLimitFor(target));
  if (!result.ok || result.unchanged) return false;
  await writeEntries(path, result.entries);
  send({ type: "memory_updated", target, usage: result.usage });
  return true;
}

async function autoExtractMemoryAfterTurn(userText, assistantText) {
  if (runtime.config.autoMemoryEnabled === false) return;
  const candidates = extractAutomaticMemoryCandidates(userText, assistantText);
  if (!candidates.length) return;
  let changed = false;
  for (const candidate of candidates) {
    changed = await addMemoryCandidate(candidate) || changed;
  }
  if (changed) {
    await loadMemorySnapshot();
    await sendMemoryAudit();
  }
}

async function loadEvolutionCandidates() {
  if (!runtime.evolutionPath || !existsSync(runtime.evolutionPath)) return [];
  const parsed = parseJSON(await readFile(runtime.evolutionPath, "utf8"), []);
  return Array.isArray(parsed) ? parsed : [];
}

async function saveEvolutionCandidates(candidates) {
  await mkdir(dirname(runtime.evolutionPath), { recursive: true });
  await writeFile(runtime.evolutionPath, JSON.stringify(candidates.slice(-100), null, 2));
}

function normalizeSkillSlug(value) {
  return sanitizeToolName(value).replace(/_+/g, "-").toLowerCase().slice(0, 48);
}

function skillListItem({ name, title, summary, path }) {
  return { name, title, summary, path };
}

async function proposeSkillEvolution(args) {
  if (runtime.config.evolutionEnabled === false) return { ok: false, content: "Skill evolution is disabled." };
  const skillName = normalizeSkillSlug(args.skill || args.name);
  const content = String(args.content || "").trim();
  if (!skillName || !content) return { ok: false, content: "skill and content are required." };
  if (content.length > 15_000) return { ok: false, content: "Skill candidate exceeds the 15KB limit." };
  const candidates = await loadEvolutionCandidates();
  const candidate = {
    id: randomUUID(),
    kind: "skill",
    skill: skillName,
    title: String(args.title || skillName).trim(),
    content,
    reason: String(args.reason || "").trim(),
    evidence: (Array.isArray(args.evidence) ? args.evidence : []).map(String).slice(0, 12),
    status: "proposed",
    createdAt: new Date().toISOString(),
  };
  candidates.push(candidate);
  await saveEvolutionCandidates(candidates);
  send({ type: "evolution_candidates_updated", count: candidates.filter((item) => item.status === "proposed").length });
  return { ok: true, content: JSON.stringify(candidate) };
}

async function listEvolutionCandidates(args) {
  const candidates = await loadEvolutionCandidates();
  const status = String(args.status || "").trim();
  const filtered = status ? candidates.filter((candidate) => candidate.status === status) : candidates;
  return { ok: true, content: JSON.stringify(enrichEvolutionCandidates(filtered.slice(-30))) };
}

function enrichEvolutionCandidates(candidates) {
  return candidates.map((candidate) => {
    const current = runtime.skills.find((skill) => skill.name === candidate.skill);
    return {
      ...candidate,
      currentContent: current?.content || "",
      currentSummary: current?.summary || "",
    };
  });
}

async function sendEvolutionAudit() {
  const candidates = await loadEvolutionCandidates();
  const enriched = enrichEvolutionCandidates(candidates.slice(-30));
  send({
    type: "evolution_candidates",
    candidates: enriched,
    count: candidates.filter((candidate) => candidate.status === "proposed").length,
  });
}

async function rejectEvolutionCandidate(args) {
  const candidates = await loadEvolutionCandidates();
  const candidate = candidates.find((item) => item.id === args.id);
  if (!candidate) {
    send({ type: "error", message: `Unknown evolution candidate: ${args.id}` });
    return;
  }
  if (candidate.status !== "proposed") {
    send({ type: "error", message: `Candidate is already ${candidate.status}.` });
    return;
  }
  candidate.status = "rejected";
  candidate.rejectedAt = new Date().toISOString();
  candidate.rejectionReason = String(args.reason || "").trim();
  await saveEvolutionCandidates(candidates);
  send({ type: "evolution_candidates_updated", count: candidates.filter((item) => item.status === "proposed").length });
  await sendEvolutionAudit();
}

async function refreshSkills() {
  const discovered = [
    ...(await discoverSkills(runtime.managedSkillsRoot)),
    ...(await discoverSkills(runtime.skillsRoot)),
    ...normalizeConfiguredSkills(runtime.config.customSkills),
  ];
  const seen = new Set();
  runtime.skills = discovered.filter((skill) => {
    const name = sanitizeToolName(skill.name);
    if (!name || seen.has(name)) return false;
    seen.add(name);
    return true;
  });
}

async function applySkillEvolution(args, sessionId = runtime.sessionId) {
  const candidates = await loadEvolutionCandidates();
  const candidate = candidates.find((item) => item.id === args.id);
  if (!candidate) return { ok: false, content: `Unknown evolution candidate: ${args.id}` };
  if (candidate.status !== "proposed") return { ok: false, content: `Candidate is already ${candidate.status}.` };
  return runWithPermission(
    { kind: "skill_write", name: "apply_skill_evolution", displayName: "应用 Skill 演化", source: "self-evolution" },
    args,
    `${candidate.skill}: ${candidate.reason || "promote reviewed skill candidate"}`,
    async () => {
      const skillDir = join(runtime.managedSkillsRoot, candidate.skill);
      await mkdir(skillDir, { recursive: true });
      await writeFile(join(skillDir, "SKILL.md"), candidate.content);
      candidate.status = "applied";
      candidate.appliedAt = new Date().toISOString();
      await saveEvolutionCandidates(candidates);
      await refreshSkills();
      send({ type: "evolution_candidates_updated", count: candidates.filter((item) => item.status === "proposed").length });
      send({ type: "skills_updated", skills: runtime.skills.map(skillListItem) });
      await sendEvolutionAudit();
      return { ok: true, content: JSON.stringify({ id: candidate.id, skill: candidate.skill, status: candidate.status }) };
    },
    sessionId,
  );
}

function selectSkillsForMessage(text, skills) {
  const lower = text.toLowerCase();
  return skills.filter((skill) => {
    const name = String(skill.name).toLowerCase();
    const title = String(skill.title).toLowerCase();
    return lower.includes(`$${name}`) || lower.includes(name) || lower.includes(title);
  });
}

function memoryNotesInstruction() {
  if (!notesEnabled()) return "";
  return [
    "长期记忆分两层，别混用：",
    "- MEMORY.md / USER.md 是有界的热记忆，只放每轮都需要的短事实，用 memory_manage 维护。写满时不要急着删——用 memory_write 的 promote_from_memory 把旧条目搬进笔记。",
    "- 记忆笔记是不限量的冷存档，用 memory_write，一条事实一个笔记。纠正、项目约束、决定及其理由、外部资源指针都归这里。",
    "你的上下文里始终有笔记索引，但那只有名字和描述。要用某条笔记的细节前，先 memory_recall 取正文，不要照着描述猜。",
    "写笔记时：描述要写成事实本身而不是标题（『番茄钟默认 45 分钟』而不是『番茄钟设置』）；feedback 和 project 类型补上 **Why:** 和 **How to apply:**；日期写绝对日期；相关笔记之间用 [[名字]] 互链。",
    "已经能从代码、git 记录或 skills 里读到的东西不要存成记忆。发现某条笔记过时了就用 memory_write 更新它，确认错了就 memory_forget。",
  ].join("\n");
}

function planningInstruction() {
  if (runtime.config.harnessEnabled === false || runtime.config.planningEnabled === false) return "";
  return [
    "多步任务先用 update_plan 立一个 3-7 步的计划，然后每完成一步立刻更新状态；同一时刻只能有一个步骤是 in_progress。",
    "单步就能答完的问题不要立计划——那只是噪音。",
    runtime.config.verifyGateEnabled === false
      ? ""
      : "改过文件或执行过写操作后，在给最终答复前必须自检一次，并如实说明验证过什么、没验证什么。",
  ].filter(Boolean).join("\n");
}

function multiAgentInstruction() {
  if (runtime.config.multiAgentEnabled === false) return "";
  return [
    "你可以带一支子 agent 编队：",
    "- dispatch_agents：把彼此独立的子任务并行分给 explorer/implementer/reviewer/tester，或用 sequential 让后一个接着前一个的结论往下做。适合『同时摸清好几个模块』这类扇出工作。",
    "- engineer_loop：实现→对抗性评审→带着评审意见重做，直到评审通过。适合正确性比速度更重要的改动。",
    "子 agent 看不到当前对话，它们需要的背景必须全部写进 goal / context / shared_context。",
    "简单任务自己动手就行，别为一次查找开编队——派发有真实的时间和 token 成本。",
  ].join("\n");
}

function systemPromptFor(userText = "") {
  const skills = runtime.skills;
  const selectedSkills = selectSkillsForMessage(userText, skills);
  const skillList = skills
    .map((skill) => `- ${skill.name}: ${skill.title} (${skill.summary.replace(/\s+/g, " ")})`)
    .join("\n");
  const selected = selectedSkills
    .map((skill) => `\n## Skill: ${skill.name}\n${skill.content}`)
    .join("\n");
  return [
    "You are 悬屿, an independent local agent running inside a macOS dynamic island app.",
    "You are not Codex and must not assume Codex runtime, Codex tools, or Codex configuration.",
    "To create or edit files, prefer the apply_patch tool over shell here-docs, sed, or echo redirection: it shows a diff for approval and applies atomically. Use file_search to locate files or code before editing.",
    runtime.config.lazyModeEnabled
      ? "Use MCP tools and built-in skills when they help. The user enabled lazy mode, so the runtime auto-approves dangerous tools. Keep tool usage purposeful and concise."
      : "Use MCP tools and built-in skills when they help. Use read-only tools freely. Ask for permission before dangerous tools; the runtime enforces this.",
    runtime.config.autoMemoryEnabled === false
      ? "Maintain durable knowledge with memory_manage when the user asks. Skip transient details and raw dumps. Search prior sessions with session_search when recall would help."
      : "Durable memory is also extracted automatically after each completed turn. You may still call memory_manage for explicit corrections. Skip transient details and raw dumps. Search prior sessions with session_search; it uses semantic embedding search when enabled and falls back to lexical search.",
    runtime.config.lazyModeEnabled
      ? "Treat skills as procedural memory. When a repeatable workflow or correction deserves a reusable skill, call propose_skill_evolution with evidence. Never overwrite a skill directly. Only call apply_skill_evolution after the user explicitly asks to promote a reviewed candidate; lazy mode will auto-approve the runtime permission gate."
      : "Treat skills as procedural memory. When a repeatable workflow or correction deserves a reusable skill, call propose_skill_evolution with evidence. Never overwrite a skill directly. Only call apply_skill_evolution after the user explicitly asks to promote a reviewed candidate; runtime permission confirmation is still required.",
    memoryNotesInstruction(),
    planningInstruction(),
    multiAgentInstruction(),
    runtime.config.memoryEnabled === false ? "" : renderMemoryBlock("memory", runtime.memorySnapshot.memory),
    runtime.config.userProfileEnabled === false ? "" : renderMemoryBlock("user", runtime.memorySnapshot.user),
    notesEnabled() ? renderNoteIndex(runtime.notes) : "",
    notesEnabled() ? renderRecalledNotes(runtime.recalledNotes) : "",
    renderPlanBlock(runtime.plan),
    "Available built-in skills:\n" + (skillList || "- none"),
    selected ? "Selected skill instructions:\n" + selected : "",
  ].filter(Boolean).join("\n\n");
}

function openAITools() {
  const tools = [
    {
      type: "function",
      function: {
        name: "list_skills",
        description: "List built-in 悬屿 skills.",
        parameters: { type: "object", properties: {}, additionalProperties: false },
      },
    },
    {
      type: "function",
      function: {
        name: "read_skill",
        description: "Read a built-in skill by name.",
        parameters: {
          type: "object",
          properties: { name: { type: "string" } },
          required: ["name"],
          additionalProperties: false,
        },
      },
    },
    {
      type: "function",
      function: {
        name: "run_skill_script",
        description: "Run a script inside a built-in skill directory. Requires user approval.",
        parameters: {
          type: "object",
          properties: {
            skill: { type: "string" },
            script: { type: "string" },
            args: { type: "array", items: { type: "string" } },
            timeoutMs: { type: "integer", minimum: 1000, maximum: MAX_LOCAL_PROCESS_TIMEOUT_MS },
          },
          required: ["skill", "script"],
          additionalProperties: false,
        },
      },
    },
    {
      type: "function",
      function: {
        name: "shell",
        description: "Run a local shell command. Requires user approval.",
        parameters: {
          type: "object",
          properties: {
            command: { type: "string" },
            cwd: { type: "string" },
            timeoutMs: { type: "integer", minimum: 1000, maximum: MAX_LOCAL_PROCESS_TIMEOUT_MS },
          },
          required: ["command"],
          additionalProperties: false,
        },
      },
    },
    {
      type: "function",
      function: {
        name: "apply_patch",
        description: "Create, edit, or delete files via a structured patch. Preferred over shell for file edits: it shows a diff for approval and applies atomically. Format: '*** Begin Patch' then one or more of '*** Add File: <path>' (lines prefixed with +), '*** Update File: <path>' (@@ hunks using ' ' context, '-' removed, '+' added), '*** Delete File: <path>', then '*** End Patch'.",
        parameters: {
          type: "object",
          properties: {
            input: { type: "string", description: "Full patch text from *** Begin Patch to *** End Patch." },
            cwd: { type: "string", description: "Base directory for relative paths. Defaults to the agent config directory." },
          },
          required: ["input"],
          additionalProperties: false,
        },
      },
    },
    {
      type: "function",
      function: {
        name: "file_search",
        description: "Read-only local file search. In name mode (default) fuzzy-matches file paths; in content mode does a case-insensitive substring search through file contents. Never writes or modifies files.",
        parameters: {
          type: "object",
          properties: {
            query: { type: "string" },
            mode: { type: "string", enum: ["name", "content"] },
            path: { type: "string" },
            limit: { type: "integer", minimum: 1, maximum: 200 },
          },
          required: ["query"],
          additionalProperties: false,
        },
      },
    },
    {
      type: "function",
      function: {
        name: "memory_manage",
        description: "Curate durable bounded memory. Use target=user for stable user preferences and target=memory for environment facts, conventions, corrections, and reusable lessons.",
        parameters: {
          type: "object",
          properties: {
            action: { type: "string", enum: ["add", "replace", "remove"] },
            target: { type: "string", enum: ["memory", "user"] },
            content: { type: "string" },
            old_text: { type: "string" },
          },
          required: ["action", "target"],
          additionalProperties: false,
        },
      },
    },
    {
      type: "function",
      function: {
        name: "session_search",
        description: "Search the complete local cross-session archive for prior discussions. Use when the user refers to earlier work or specific past context.",
        parameters: {
          type: "object",
          properties: {
            query: { type: "string" },
            limit: { type: "integer", minimum: 1, maximum: 30 },
          },
          required: ["query"],
          additionalProperties: false,
        },
      },
    },
    {
      type: "function",
      function: {
        name: "propose_skill_evolution",
        description: "Create an auditable candidate for a new or improved reusable skill from session evidence. This records a proposal and does not change live skills.",
        parameters: {
          type: "object",
          properties: {
            skill: { type: "string" },
            title: { type: "string" },
            content: { type: "string" },
            reason: { type: "string" },
            evidence: { type: "array", items: { type: "string" } },
          },
          required: ["skill", "content", "reason"],
          additionalProperties: false,
        },
      },
    },
    {
      type: "function",
      function: {
        name: "list_evolution_candidates",
        description: "List auditable self-evolution candidates and their promotion status.",
        parameters: {
          type: "object",
          properties: { status: { type: "string", enum: ["proposed", "applied"] } },
          additionalProperties: false,
        },
      },
    },
    {
      type: "function",
      function: {
        name: "apply_skill_evolution",
        description: "Promote a reviewed skill evolution candidate into the mutable local skills directory. Call only after explicit user request. Requires permission confirmation.",
        parameters: {
          type: "object",
          properties: { id: { type: "string" } },
          required: ["id"],
          additionalProperties: false,
        },
      },
    },
  ];

  if (runtime.config.memoryEnabled !== false && runtime.config.memoryNotesEnabled !== false) {
    tools.push({
      type: "function",
      function: {
        name: "memory_write",
        description: `Save one durable fact as its own memory note. Use this instead of memory_manage for anything with substance: a correction worth keeping, a project constraint, a decision and its reason, a pointer to an external resource. One fact per note — split compound knowledge into several. Writing an existing name updates that note in place. Types: ${NOTE_TYPES.join(" | ")}. Only the description is always visible to you later, so make it a precise retrieval hook, not a teaser. Link related notes by writing [[other-note-name]] in the content.`,
        parameters: {
          type: "object",
          properties: {
            name: { type: "string", description: "Short kebab-case identifier, unique per fact." },
            description: { type: "string", description: "One line stating the fact itself — this is the only thing you see when deciding whether to recall it." },
            type: { type: "string", enum: NOTE_TYPES },
            content: { type: "string", description: "The fact. For feedback and project notes, follow it with **Why:** and **How to apply:** lines. Use absolute dates, never 'yesterday' or 'last week'." },
            promote_from_memory: { type: "string", description: "Optional unique substring of a MEMORY.md entry to remove after this note is written; use it to move a fact out of the bounded hot memory." },
          },
          required: ["name", "description", "type", "content"],
          additionalProperties: false,
        },
      },
    });
    tools.push({
      type: "function",
      function: {
        name: "memory_recall",
        description: "Read the full content of memory notes matching a query. The memory index in your context shows only names and descriptions — call this before relying on any note's details, and whenever the index hints that something relevant exists.",
        parameters: {
          type: "object",
          properties: {
            query: { type: "string" },
            limit: { type: "integer", minimum: 1, maximum: 12 },
          },
          required: ["query"],
          additionalProperties: false,
        },
      },
    });
    tools.push({
      type: "function",
      function: {
        name: "memory_forget",
        description: "Delete a memory note that turned out to be wrong or obsolete. Prefer updating via memory_write when the fact merely changed.",
        parameters: {
          type: "object",
          properties: {
            name: { type: "string" },
            reason: { type: "string" },
          },
          required: ["name"],
          additionalProperties: false,
        },
      },
    });
  }

  if (runtime.config.planningEnabled !== false && runtime.config.harnessEnabled !== false) {
    tools.push({
      type: "function",
      function: {
        name: "update_plan",
        description: "Maintain the visible task plan for a multi-step job. Call it once early with the full step list, then again after each step to flip its status. Exactly one step may be in_progress. Skip it for single-step questions.",
        parameters: {
          type: "object",
          properties: {
            plan: {
              type: "array",
              items: {
                type: "object",
                properties: {
                  step: { type: "string" },
                  status: { type: "string", enum: ["pending", "in_progress", "completed"] },
                },
                required: ["step", "status"],
                additionalProperties: false,
              },
            },
            explanation: { type: "string", description: "Optional one-line note about why the plan changed." },
          },
          required: ["plan"],
          additionalProperties: false,
        },
      },
    });
  }

  if (runtime.config.multiAgentEnabled !== false) {
    const roleList = listAgentRoles().map((role) => `${role.id}（${role.title}${role.readOnly ? "，只读" : ""}）`).join("、");
    tools.push({
      type: "function",
      function: {
        name: "dispatch_agents",
        description: `Delegate independent sub-tasks to role-scoped sub-agents that each run their own tool loop and report back. Available roles: ${roleList}. Use parallel mode for independent work (e.g. searching several subsystems at once) and sequential mode when a later task needs earlier findings. Sub-agents cannot see this conversation, so put everything they need in goal and context. Do not use it for a single trivial lookup you can do yourself.`,
        parameters: {
          type: "object",
          properties: {
            mode: { type: "string", enum: ["parallel", "sequential"] },
            shared_context: { type: "string", description: "Background every sub-agent should receive." },
            tasks: {
              type: "array",
              items: {
                type: "object",
                properties: {
                  role: { type: "string", enum: listAgentRoles().map((role) => role.id) },
                  goal: { type: "string" },
                  label: { type: "string", description: "Short display name, e.g. 音乐模块." },
                  context: { type: "string" },
                },
                required: ["role", "goal"],
                additionalProperties: false,
              },
            },
          },
          required: ["tasks"],
          additionalProperties: false,
        },
      },
    });
    tools.push({
      type: "function",
      function: {
        name: "engineer_loop",
        description: "Run an implement-then-review loop: an implementer sub-agent makes the change, a reviewer sub-agent adversarially verifies it against the real files, and the loop repeats with the review feedback until the reviewer approves or rounds run out. Use for changes where correctness matters more than speed.",
        parameters: {
          type: "object",
          properties: {
            goal: { type: "string", description: "The change to make, stated precisely enough to implement and to verify." },
            context: { type: "string" },
            rounds: { type: "integer", minimum: 1, maximum: 4 },
          },
          required: ["goal"],
          additionalProperties: false,
        },
      },
    });
  }

  for (const client of runtime.mcpClients.values()) {
    for (const tool of client.tools) {
      tools.push({
        type: "function",
        function: {
          name: tool.openAIName,
          description: `[MCP:${client.name}] ${tool.description || tool.name}`,
          parameters: tool.inputSchema || { type: "object", properties: {} },
        },
      });
    }
  }
  return tools;
}

function parseToolArgs(text) {
  return parseJSON(text || "{}", {});
}

// 界面同一时刻只能展示一个确认框，而并行子 agent 可能同时请求权限，
// 所以把提示排成一条队列：前一个有结果之前不发下一个。
let permissionQueue = Promise.resolve();

function promptPermission(tool, args, summary, sessionId) {
  const id = randomUUID();
  send({
    type: "permission_request",
    sessionId,
    id,
    tool: tool.displayName || tool.name,
    source: tool.source || tool.kind,
    summary,
    arguments: args,
  });
  return new Promise((resolvePermission) => {
    runtime.pendingPermissions.set(id, resolvePermission);
  });
}

async function askPermission(tool, args, summary, sessionId = runtime.sessionId) {
  const run = () => (isCancelledSession(sessionId)
    ? Promise.resolve(false)
    : promptPermission(tool, args, summary, sessionId));
  const next = permissionQueue.then(run, run);
  permissionQueue = next.then(() => {}, () => {});
  return next;
}

async function runWithPermission(tool, args, summary, action, sessionId = runtime.sessionId) {
  if (classifyToolRisk(tool, args) === "confirm") {
    const approved = await askPermission(tool, args, summary, sessionId);
    if (!approved) {
      return { ok: false, denied: true, content: "User denied this tool call." };
    }
    return action();
  }
  // Auto path: if an auto-approve policy (lazy mode / never / on-failure) bypassed
  // a tool that would otherwise need confirmation, surface that to the island UI.
  if (classifyToolRisk(tool, args, "on-request") === "confirm") {
    send({
      type: "permission_auto_approved",
      sessionId,
      tool: tool.displayName || tool.name,
      source: tool.source || tool.kind,
      summary,
      arguments: args,
    });
  }
  return action();
}

function terminateChild(child, signal = "SIGTERM") {
  if (!child || child.killed) return;
  try {
    if (child.pid) process.kill(-child.pid, signal);
  } catch {
    try { child.kill(signal); } catch { /* ignore */ }
  }
}

function terminateActiveProcesses(signal = "SIGTERM") {
  for (const child of [...runtime.activeProcesses]) {
    terminateChild(child, signal);
  }
}

function localProcessTimeoutMs(value) {
  return boundedNumber(value, DEFAULT_LOCAL_PROCESS_TIMEOUT_MS, 1_000, MAX_LOCAL_PROCESS_TIMEOUT_MS);
}

function captureChild(child, { timeoutMs = DEFAULT_LOCAL_PROCESS_TIMEOUT_MS } = {}) {
  return new Promise((resolveResult) => {
    let stdout = "";
    let stderr = "";
    let settled = false;
    let timedOut = false;
    const timeout = setTimeout(() => {
      timedOut = true;
      terminateChild(child, "SIGTERM");
      const killTimer = setTimeout(() => {
        if (!settled) terminateChild(child, "SIGKILL");
      }, 1_000);
      killTimer.unref?.();
    }, localProcessTimeoutMs(timeoutMs));
    timeout.unref?.();

    const resolveOnce = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      runtime.activeProcesses.delete(child);
      resolveResult(result);
    };

    child.on("error", (error) => {
      resolveOnce({ ok: false, content: JSON.stringify({ error: error?.message || String(error), timedOut, timeoutMs: localProcessTimeoutMs(timeoutMs) }) });
    });
    if (child.stdout) child.stdout.on("data", (chunk) => { stdout += chunk.toString(); });
    if (child.stderr) child.stderr.on("data", (chunk) => { stderr += chunk.toString(); });
    child.on("close", (code, signal) => {
      resolveOnce({
        ok: code === 0 && !timedOut,
        content: JSON.stringify({
          exitCode: code,
          signal,
          timedOut,
          timeoutMs: localProcessTimeoutMs(timeoutMs),
          stdout: stdout.slice(-12000),
          stderr: stderr.slice(-8000),
        }),
      });
    });
  });
}

function spawnLocal(file, argv, { cwd } = {}) {
  const workdir = cwd || runtime.configDir || process.cwd();
  const child = spawn(file, argv, { cwd: workdir, env: process.env, detached: true });
  runtime.activeProcesses.add(child);
  child.on("close", () => runtime.activeProcesses.delete(child));
  child.on("error", () => runtime.activeProcesses.delete(child));
  return child;
}

function runLocalProcess(file, argv, options) {
  return captureChild(spawnLocal(file, argv, options), { timeoutMs: options?.timeoutMs });
}

async function runShell(args, sessionId = runtime.sessionId) {
  return runWithPermission(
    { kind: "shell", name: "shell", displayName: "shell", source: "local" },
    args,
    args.command,
    () => runLocalProcess("/bin/zsh", ["-lc", String(args.command || "")], { cwd: args.cwd, timeoutMs: args.timeoutMs }),
    sessionId,
  );
}

async function runSkillScript(args, sessionId = runtime.sessionId) {
  const skill = runtime.skills.find((item) => item.name === args.skill);
  if (!skill) return { ok: false, content: `Unknown skill: ${args.skill}` };
  if (!skill.absolutePath) {
    return { ok: false, content: "Configured skills do not have a local script directory." };
  }
  const skillDir = dirname(skill.absolutePath);
  const scriptPath = resolve(skillDir, String(args.script || ""));
  if (!scriptPath.startsWith(skillDir) || !existsSync(scriptPath)) {
    return { ok: false, content: "Script does not exist inside the skill directory." };
  }
  return runWithPermission(
    { kind: "skill_script", name: "run_skill_script", displayName: "skill script", source: skill.name },
    args,
    `${skill.name}/${args.script}`,
    () => runLocalProcess(scriptPath, Array.isArray(args.args) ? args.args.map(String) : [], { cwd: skillDir, timeoutMs: args.timeoutMs }),
    sessionId,
  );
}

export function parseApplyPatch(text) {
  const lines = String(text || "").split(/\r?\n/);
  let i = 0;
  while (i < lines.length && lines[i].trim() === "") i += 1;
  if (lines[i] === undefined || lines[i].trim() !== "*** Begin Patch") {
    return { ok: false, error: "Patch must start with '*** Begin Patch'." };
  }
  i += 1;
  const ops = [];
  let sawEnd = false;
  while (i < lines.length) {
    const line = lines[i];
    if (line.trim() === "*** End Patch") { sawEnd = true; i += 1; break; }
    const addMatch = line.match(/^\*\*\* Add File: (.+)$/);
    const updateMatch = line.match(/^\*\*\* Update File: (.+)$/);
    const deleteMatch = line.match(/^\*\*\* Delete File: (.+)$/);
    if (addMatch) {
      const path = addMatch[1].trim();
      i += 1;
      const contentLines = [];
      while (i < lines.length && !/^\*\*\* /.test(lines[i])) {
        const current = lines[i];
        if (current.startsWith("+")) contentLines.push(current.slice(1));
        else if (current === "") contentLines.push("");
        else return { ok: false, error: `Add File '${path}': content lines must be prefixed with '+'.` };
        i += 1;
      }
      ops.push({ type: "add", path, content: contentLines.join("\n") });
    } else if (deleteMatch) {
      ops.push({ type: "delete", path: deleteMatch[1].trim() });
      i += 1;
    } else if (updateMatch) {
      const path = updateMatch[1].trim();
      i += 1;
      const hunks = [];
      let current = null;
      while (i < lines.length && !/^\*\*\* /.test(lines[i])) {
        const l = lines[i];
        if (/^@@/.test(l)) {
          current = { context: l.replace(/^@@/, "").trim(), lines: [] };
          hunks.push(current);
        } else {
          if (!current) { current = { context: "", lines: [] }; hunks.push(current); }
          if (l.startsWith("+")) current.lines.push({ op: "+", text: l.slice(1) });
          else if (l.startsWith("-")) current.lines.push({ op: "-", text: l.slice(1) });
          else if (l.startsWith(" ")) current.lines.push({ op: " ", text: l.slice(1) });
          else if (l === "") current.lines.push({ op: " ", text: "" });
          else return { ok: false, error: `Update File '${path}': unexpected line '${l}'.` };
        }
        i += 1;
      }
      if (!hunks.length) return { ok: false, error: `Update File '${path}': no hunks provided.` };
      ops.push({ type: "update", path, hunks });
    } else if (line.trim() === "") {
      i += 1;
    } else {
      return { ok: false, error: `Unexpected patch line: '${line}'.` };
    }
  }
  if (!sawEnd) return { ok: false, error: "Patch must end with '*** End Patch'." };
  if (!ops.length) return { ok: false, error: "Patch contains no file operations." };
  return { ok: true, ops };
}

function indexOfBlock(haystack, needle) {
  if (!needle.length) return -1;
  for (let i = 0; i + needle.length <= haystack.length; i += 1) {
    let match = true;
    for (let j = 0; j < needle.length; j += 1) {
      if (haystack[i + j] !== needle[j]) { match = false; break; }
    }
    if (match) return i;
  }
  return -1;
}

export function applyHunksToContent(content, hunks) {
  let lines = String(content).split("\n");
  let added = 0;
  let removed = 0;
  for (const hunk of hunks) {
    const oldLines = hunk.lines.filter((l) => l.op === " " || l.op === "-").map((l) => l.text);
    const newLines = hunk.lines.filter((l) => l.op === " " || l.op === "+").map((l) => l.text);
    added += hunk.lines.filter((l) => l.op === "+").length;
    removed += hunk.lines.filter((l) => l.op === "-").length;
    if (oldLines.length === 0) {
      lines = lines.concat(newLines);
      continue;
    }
    const at = indexOfBlock(lines, oldLines);
    if (at < 0) {
      return { ok: false, error: `could not locate context for hunk near ${JSON.stringify(oldLines[0] ?? "")}` };
    }
    lines = lines.slice(0, at).concat(newLines, lines.slice(at + oldLines.length));
  }
  return { ok: true, content: lines.join("\n"), added, removed };
}

function renderPatchHunks(hunks) {
  return hunks.map((hunk) => {
    const header = hunk.context ? `@@ ${hunk.context}` : "@@";
    return `${header}\n${hunk.lines.map((l) => `${l.op}${l.text}`).join("\n")}`;
  }).join("\n");
}

async function planApplyPatch(ops, { cwd }) {
  const plan = [];
  const diffParts = [];
  const summary = [];
  for (const op of ops) {
    const absPath = resolve(cwd, op.path);
    if (op.type === "add") {
      if (existsSync(absPath)) return { ok: false, error: `Add File target already exists: ${op.path}` };
      const lineCount = op.content === "" ? 0 : op.content.split("\n").length;
      plan.push({ type: "add", absPath, path: op.path, content: op.content });
      diffParts.push(`*** Add File: ${op.path}\n${op.content.split("\n").map((l) => `+${l}`).join("\n")}`);
      summary.push({ path: op.path, action: "add", added: lineCount, removed: 0 });
    } else if (op.type === "delete") {
      if (!existsSync(absPath)) return { ok: false, error: `Delete File target does not exist: ${op.path}` };
      let removed = 0;
      try { removed = (await readFile(absPath, "utf8")).split("\n").length; } catch { removed = 0; }
      plan.push({ type: "delete", absPath, path: op.path });
      diffParts.push(`*** Delete File: ${op.path}`);
      summary.push({ path: op.path, action: "delete", added: 0, removed });
    } else if (op.type === "update") {
      if (!existsSync(absPath)) return { ok: false, error: `Update File target does not exist: ${op.path}` };
      let currentContent;
      try { currentContent = await readFile(absPath, "utf8"); }
      catch (error) { return { ok: false, error: `cannot read ${op.path}: ${error?.message || error}` }; }
      const applied = applyHunksToContent(currentContent, op.hunks);
      if (!applied.ok) return { ok: false, error: `Update File '${op.path}': ${applied.error}` };
      plan.push({ type: "update", absPath, path: op.path, content: applied.content });
      diffParts.push(`*** Update File: ${op.path}\n${renderPatchHunks(op.hunks)}`);
      summary.push({ path: op.path, action: "update", added: applied.added, removed: applied.removed });
    }
  }
  return { ok: true, plan, diff: diffParts.join("\n\n"), summary };
}

async function commitApplyPatch(plan) {
  const written = [];
  for (const item of plan) {
    if (item.type === "add" || item.type === "update") {
      await mkdir(dirname(item.absPath), { recursive: true });
      await writeFile(item.absPath, item.content, "utf8");
    } else if (item.type === "delete") {
      await unlink(item.absPath);
    }
    written.push({ path: item.path, action: item.type });
  }
  return { written };
}

async function runApplyPatch(args, sessionId = runtime.sessionId) {
  const parsed = parseApplyPatch(String(args.input ?? args.patch ?? ""));
  if (!parsed.ok) return { ok: false, content: JSON.stringify({ error: parsed.error }) };
  const cwd = resolve(String(args.cwd || runtime.configDir || process.cwd()));
  const planned = await planApplyPatch(parsed.ops, { cwd });
  if (!planned.ok) return { ok: false, content: JSON.stringify({ error: planned.error }) };
  send({ type: "patch_preview", sessionId, diff: planned.diff, files: planned.summary });
  return runWithPermission(
    { kind: "apply_patch", name: "apply_patch", displayName: "apply_patch", source: "local" },
    args,
    `apply_patch (${planned.summary.length} file${planned.summary.length === 1 ? "" : "s"})`,
    async () => {
      try {
        const result = await commitApplyPatch(planned.plan);
        return { ok: true, content: JSON.stringify({ files: planned.summary, ...result }) };
      } catch (error) {
        return { ok: false, content: JSON.stringify({ error: error?.message || String(error) }) };
      }
    },
    sessionId,
  );
}

function emitHarnessStatus(sessionId = runtime.sessionId) {
  if (!runtime.telemetry || runtime.config.harnessEnabled === false) return;
  send({ type: "harness_status", sessionId, ...harnessStatus(runtime.telemetry, runtime.plan) });
}

async function updatePlan(args, sessionId = runtime.sessionId) {
  const result = applyPlanUpdate(runtime.plan, args);
  if (!result.ok) return { ok: false, content: JSON.stringify({ error: result.error }) };
  runtime.plan = result.plan;
  send({
    type: "plan_updated",
    sessionId,
    plan: runtime.plan,
    explanation: String(args?.explanation || "").slice(0, 300),
  });
  emitHarnessStatus(sessionId);
  return { ok: true, content: JSON.stringify({ plan: runtime.plan, note: result.note || "" }) };
}

function isReadOnlyMCPName(name) {
  for (const client of runtime.mcpClients.values()) {
    const tool = client.tools.find((item) => item.openAIName === name);
    if (tool) return isReadOnlyTool(tool);
  }
  return false;
}

function subAgentDeps(sessionId) {
  const runId = randomUUID().slice(0, 8);
  return {
    streamChat,
    executeToolCalls,
    tools: openAITools(),
    send,
    sessionId,
    isCancelled: () => isCancelledSession(sessionId),
    isReadOnlyMCPName,
    maxTurnsOverride: boundedNumber(runtime.config.subAgentMaxTurns, 0, 0, 40),
    makeAgentId: (suffix) => `${runId}-${suffix}`,
  };
}

async function runDispatchAgents(args, sessionId = runtime.sessionId) {
  if (runtime.config.multiAgentEnabled === false) {
    return { ok: false, content: "多智能体协同已在设置中关闭。" };
  }
  const tasks = normalizeDispatchTasks(args?.tasks, { maxTasks: 6 });
  if (!tasks.length) {
    return { ok: false, content: "dispatch_agents 需要至少一个同时带合法 role 和非空 goal 的任务。" };
  }
  const mode = args?.mode === "sequential" ? "sequential" : "parallel";
  const concurrency = boundedNumber(runtime.config.subAgentConcurrency, 3, 1, 6);
  send({
    type: "dispatch_started",
    sessionId,
    mode,
    count: tasks.length,
    tasks: tasks.map((task) => ({ role: task.role, label: task.label })),
  });
  const reports = await dispatchAgents(tasks, {
    ...subAgentDeps(sessionId),
    mode,
    concurrency,
    sharedContext: String(args?.shared_context || args?.sharedContext || "").slice(0, 8000),
  });
  const failed = reports.filter((report) => !report.ok).length;
  send({ type: "dispatch_done", sessionId, mode, count: reports.length, failed });
  return {
    ok: failed < reports.length,
    content: renderReports(reports) || "所有子 agent 都没有产出报告。",
  };
}

async function runEngineerLoopTool(args, sessionId = runtime.sessionId) {
  if (runtime.config.multiAgentEnabled === false) {
    return { ok: false, content: "多智能体协同已在设置中关闭。" };
  }
  const goal = String(args?.goal || "").trim();
  if (!goal) return { ok: false, content: "engineer_loop 需要一个非空的 goal。" };
  send({ type: "engineer_loop_started", sessionId, goal: goal.slice(0, 200) });
  const result = await runEngineerLoop(
    { goal, context: String(args?.context || "").slice(0, 8000), rounds: args?.rounds },
    subAgentDeps(sessionId),
  );
  send({ type: "engineer_loop_done", sessionId, verdict: result.verdict, rounds: result.rounds });
  const header = result.verdict === "approved"
    ? `工程师循环在第 ${result.rounds} 轮通过评审。`
    : `工程师循环跑满 ${result.rounds} 轮仍未通过评审，下面是最后一轮的问题清单，需要你决定怎么处理。`;
  return {
    ok: result.verdict === "approved",
    content: [header, renderReports(result.history)].filter(Boolean).join("\n\n"),
  };
}

// 记录本轮真实发生的写操作，供收尾自检闸门使用。
function trackMutation(name, args, result) {
  if (!runtime.telemetry || !result?.ok) return;
  if (name === "apply_patch") {
    const files = parseJSON(result.content, {})?.files || [];
    const detail = files.map((file) => `${file.action} ${file.path}`).join(", ") || "patch applied";
    recordMutation(runtime.telemetry, { tool: "apply_patch", detail });
    return;
  }
  if (name === "shell" || name === "run_skill_script") {
    const command = String(args?.command ?? args?.script ?? "");
    if (name === "shell" && !analyzeCommand(command).writes) return;
    recordMutation(runtime.telemetry, { tool: name, detail: command });
  }
}

async function runBuiltInTool(name, args, sessionId = runtime.sessionId) {
  if (name === "update_plan") return updatePlan(args, sessionId);
  if (name === "dispatch_agents") return runDispatchAgents(args, sessionId);
  if (name === "engineer_loop") return runEngineerLoopTool(args, sessionId);
  if (name === "list_skills") {
    return { ok: true, content: JSON.stringify(runtime.skills.map(({ name: skillName, title, summary, path }) => ({ name: skillName, title, summary, path }))) };
  }
  if (name === "read_skill") {
    const skill = runtime.skills.find((item) => item.name === args.name);
    return skill ? { ok: true, content: skill.content } : { ok: false, content: `Unknown skill: ${args.name}` };
  }
  if (name === "run_skill_script") return runSkillScript(args, sessionId);
  if (name === "shell") return runShell(args, sessionId);
  if (name === "apply_patch") return runApplyPatch(args, sessionId);
  if (name === "file_search") return runFileSearch(args);
  if (name === "memory_manage") return manageMemory(args);
  if (name === "memory_write") return writeMemoryNote(args);
  if (name === "memory_recall") return recallMemoryNotes(args);
  if (name === "memory_forget") return forgetMemoryNote(args);
  if (name === "session_search") return searchSessions(args);
  if (name === "propose_skill_evolution") return proposeSkillEvolution(args);
  if (name === "list_evolution_candidates") return listEvolutionCandidates(args);
  if (name === "apply_skill_evolution") return applySkillEvolution(args, sessionId);
  return null;
}

function encodeRpc(payload) {
  const body = JSON.stringify(payload);
  return `Content-Length: ${Buffer.byteLength(body, "utf8")}\r\n\r\n${body}`;
}

function extractRpcFrames(state, chunk) {
  state.buffer += chunk.toString();
  const frames = [];
  while (state.buffer.length) {
    const headerEnd = state.buffer.indexOf("\r\n\r\n");
    if (headerEnd >= 0) {
      const header = state.buffer.slice(0, headerEnd);
      const match = header.match(/Content-Length:\s*(\d+)/i);
      if (!match) break;
      const length = Number(match[1]);
      const start = headerEnd + 4;
      if (Buffer.byteLength(state.buffer.slice(start), "utf8") < length) break;
      const body = state.buffer.slice(start, start + length);
      state.buffer = state.buffer.slice(start + length);
      const parsed = parseJSON(body);
      if (parsed) frames.push(parsed);
      continue;
    }
    const lineEnd = state.buffer.indexOf("\n");
    if (lineEnd < 0) break;
    const line = state.buffer.slice(0, lineEnd).trim();
    state.buffer = state.buffer.slice(lineEnd + 1);
    if (line.startsWith("{")) {
      const parsed = parseJSON(line);
      if (parsed) frames.push(parsed);
    }
  }
  return frames;
}

class StdioMCPClient {
  constructor(config) {
    this.name = config.name;
    this.config = config;
    this.process = null;
    this.nextId = 1;
    this.pending = new Map();
    this.tools = [];
    this.parser = { buffer: "" };
  }

  async start() {
    this.process = spawn(this.config.command, this.config.args || [], {
      cwd: this.config.cwd || runtime.configDir || process.cwd(),
      env: { ...process.env, ...(this.config.env || {}) },
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.process.stdout.on("data", (chunk) => {
      for (const frame of extractRpcFrames(this.parser, chunk)) this.handleFrame(frame);
    });
    this.process.stderr.on("data", (chunk) => {
      send({ type: "tool_result", id: randomUUID(), tool: `mcp:${this.name}:stderr`, ok: false, content: chunk.toString().slice(-1000) });
    });
    await this.request("initialize", {
      protocolVersion: "2024-11-05",
      capabilities: {},
      clientInfo: { name: "悬屿", version: "0.1.0" },
    });
    this.notify("notifications/initialized", {});
    const listed = await this.request("tools/list", {});
    this.tools = (listed.tools || []).map((tool) => ({
      ...tool,
      serverName: this.name,
      openAIName: sanitizeToolName(`mcp__${this.name}__${tool.name}`),
    }));
  }

  handleFrame(frame) {
    if (!Object.prototype.hasOwnProperty.call(frame, "id")) return;
    const pending = this.pending.get(frame.id);
    if (!pending) return;
    this.pending.delete(frame.id);
    if (frame.error) pending.reject(new Error(frame.error.message || JSON.stringify(frame.error)));
    else pending.resolve(frame.result || {});
  }

  request(method, params) {
    const id = this.nextId++;
    const payload = { jsonrpc: "2.0", id, method, params };
    this.process.stdin.write(encodeRpc(payload));
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      setTimeout(() => {
        if (this.pending.has(id)) {
          this.pending.delete(id);
          reject(new Error(`MCP ${this.name} ${method} timed out`));
        }
      }, this.config.timeoutMs || 30000);
    });
  }

  notify(method, params) {
    this.process.stdin.write(encodeRpc({ jsonrpc: "2.0", method, params }));
  }

  async call(tool, args) {
    return this.request("tools/call", { name: tool.name, arguments: args });
  }

  stop() {
    this.process?.kill();
  }
}

class HTTPMCPClient {
  constructor(config) {
    this.name = config.name;
    this.config = config;
    this.nextId = 1;
    this.tools = [];
    this.endpoint = config.url;
  }

  async start() {
    await this.request("initialize", {
      protocolVersion: "2024-11-05",
      capabilities: {},
      clientInfo: { name: "悬屿", version: "0.1.0" },
    });
    const listed = await this.request("tools/list", {});
    this.tools = (listed.tools || []).map((tool) => ({
      ...tool,
      serverName: this.name,
      openAIName: sanitizeToolName(`mcp__${this.name}__${tool.name}`),
    }));
  }

  async request(method, params) {
    const payload = { jsonrpc: "2.0", id: this.nextId++, method, params };
    const response = await fetch(this.endpoint, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        accept: "application/json, text/event-stream",
        ...(this.config.headers || {}),
      },
      body: JSON.stringify(payload),
    });
    const text = await response.text();
    if (!response.ok) throw new Error(`MCP ${this.name} HTTP ${response.status}: ${text.slice(0, 500)}`);
    const result = text.includes("event:") ? parseSSEJSON(text).at(-1) : parseJSON(text);
    if (!result) return {};
    if (result.error) throw new Error(result.error.message || JSON.stringify(result.error));
    return result.result || result;
  }

  async call(tool, args) {
    return this.request("tools/call", { name: tool.name, arguments: args });
  }

  stop() {}
}

function parseSSEJSON(text) {
  const events = [];
  for (const block of text.split(/\n\n+/)) {
    const data = block.split(/\n/).filter((line) => line.startsWith("data:")).map((line) => line.slice(5).trim()).join("\n");
    if (!data || data === "[DONE]") continue;
    const parsed = parseJSON(data);
    if (parsed) events.push(parsed);
  }
  return events;
}

async function connectSSEMCP(config) {
  const controller = new AbortController();
  const response = await fetch(config.url, {
    headers: { accept: "text/event-stream", ...(config.headers || {}) },
    signal: controller.signal,
  });
  if (!response.ok) throw new Error(`MCP ${config.name} SSE ${response.status}`);
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let text = "";
  let endpoint = "";
  const timeout = setTimeout(() => controller.abort(), config.timeoutMs || 10000);
  try {
    while (!endpoint) {
      const { done, value } = await reader.read();
      if (done) break;
      text += decoder.decode(value, { stream: true });
      const endpointBlock = text.split(/\n\n+/).find((block) => block.includes("event: endpoint"));
      endpoint = endpointBlock?.split(/\n/).find((line) => line.startsWith("data:"))?.slice(5).trim() || "";
    }
  } finally {
    clearTimeout(timeout);
    controller.abort();
  }
  if (!endpoint) throw new Error(`MCP ${config.name} SSE endpoint not found`);
  return new HTTPMCPClient({ ...config, transport: "streamable_http", url: new URL(endpoint, config.url).toString() });
}

async function startMCPServers() {
  for (const client of runtime.mcpClients.values()) client.stop();
  runtime.mcpClients.clear();
  const servers = Array.isArray(runtime.config.mcpServers) ? runtime.config.mcpServers : [];
  const enabledServers = servers.filter((server) => server.enabled !== false);
  const connected = await Promise.all(enabledServers.map(async (server, index) => {
    try {
      const name = sanitizeToolName(server.name || server.id || `server_${index + 1}`);
      let client;
      if (server.transport === "stdio" || server.type === "stdio") client = new StdioMCPClient({ ...server, name });
      else if (server.transport === "sse" || server.type === "sse") client = await connectSSEMCP({ ...server, name });
      else client = new HTTPMCPClient({ ...server, name });
      await client.start();
      send({ type: "tool_result", id: randomUUID(), tool: `mcp:${name}`, ok: true, content: `connected ${client.tools.length} tools` });
      return [name, client];
    } catch (error) {
      send({ type: "error", message: `MCP ${server.name || server.id || "server"} failed: ${error.message}` });
      return null;
    }
  }));
  for (const entry of connected.filter(Boolean)) {
    runtime.mcpClients.set(entry[0], entry[1]);
  }
}

function accumulateToolCall(toolCalls, deltaCalls) {
  for (const call of deltaCalls || []) {
    const index = call.index ?? toolCalls.length;
    const current = toolCalls[index] || { id: "", type: "function", function: { name: "", arguments: "" } };
    current.id = call.id || current.id;
    current.type = call.type || current.type || "function";
    current.function.name += call.function?.name || "";
    current.function.arguments += call.function?.arguments || "";
    toolCalls[index] = current;
  }
}

function anthropicToolsFromOpenAI(tools) {
  return (Array.isArray(tools) ? tools : [])
    .map((tool) => tool?.function)
    .filter((tool) => tool?.name)
    .map((tool) => ({
      name: tool.name,
      description: tool.description || tool.name,
      input_schema: tool.parameters || { type: "object", properties: {}, additionalProperties: false },
    }));
}

function textBlock(text) {
  const value = String(text || "");
  return value.trim() ? [{ type: "text", text: value }] : [];
}

function appendAnthropicMessage(messages, role, blocks) {
  const content = (Array.isArray(blocks) ? blocks : []).filter(Boolean);
  if (!content.length) return;
  const last = messages[messages.length - 1];
  if (last?.role === role && Array.isArray(last.content)) {
    last.content.push(...content);
  } else {
    messages.push({ role, content });
  }
}

function anthropicInputForToolCall(call) {
  const parsed = parseJSON(call?.function?.arguments || "{}", {});
  return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
}

function anthropicPayloadMessages(openAIMessages) {
  const system = [];
  const messages = [];
  for (const message of openAIMessages || []) {
    const role = message?.role;
    if (role === "system") {
      const content = String(message.content || "").trim();
      if (content) system.push(content);
      continue;
    }
    if (role === "tool") {
      appendAnthropicMessage(messages, "user", [{
        type: "tool_result",
        tool_use_id: String(message.tool_call_id || ""),
        content: String(message.content || ""),
      }]);
      continue;
    }
    if (role === "assistant") {
      const blocks = [
        ...textBlock(message.content || ""),
        ...((message.tool_calls || []).map((call) => ({
          type: "tool_use",
          id: String(call.id || randomUUID()),
          name: call.function?.name || "",
          input: anthropicInputForToolCall(call),
        })).filter((block) => block.name)),
      ];
      appendAnthropicMessage(messages, "assistant", blocks);
      continue;
    }
    if (role === "user") {
      appendAnthropicMessage(messages, "user", textBlock(message.content || ""));
    }
  }
  while (messages[0]?.role === "assistant") messages.shift();
  return { system: system.join("\n\n"), messages };
}

function accumulateAnthropicEvent(event, blocks, toolCalls) {
  if (event?.type === "content_block_start") {
    const index = event.index ?? blocks.size;
    const block = event.content_block || {};
    blocks.set(index, {
      type: block.type || "",
      id: block.id || "",
      name: block.name || "",
      text: block.text || "",
      inputJson: block.input && Object.keys(block.input).length ? JSON.stringify(block.input) : "",
    });
    return block.type === "text" ? String(block.text || "") : "";
  }
  if (event?.type === "content_block_delta") {
    const index = event.index ?? 0;
    const current = blocks.get(index) || { type: "", id: "", name: "", text: "", inputJson: "" };
    const delta = event.delta || {};
    if (delta.type === "text_delta") {
      current.text += delta.text || "";
      blocks.set(index, current);
      return delta.text || "";
    }
    if (delta.type === "input_json_delta") {
      current.inputJson += delta.partial_json || "";
      blocks.set(index, current);
    }
    return "";
  }
  if (event?.type === "content_block_stop") {
    const index = event.index ?? 0;
    const current = blocks.get(index);
    if (current?.type === "tool_use" && current.name) {
      toolCalls.push({
        id: current.id || randomUUID(),
        type: "function",
        function: {
          name: current.name,
          arguments: current.inputJson || "{}",
        },
      });
    }
  }
  return "";
}

// 并行子 agent 会同时打开多个模型请求，取消时必须能一次性中止全部。
function createRequestAbort() {
  const controller = new AbortController();
  runtime.abortControllers.add(controller);
  runtime.abortController = controller;
  return controller;
}

function releaseRequestAbort(controller) {
  runtime.abortControllers.delete(controller);
  if (runtime.abortController === controller) {
    runtime.abortController = [...runtime.abortControllers].at(-1) || null;
  }
}

function abortAllRequests() {
  for (const controller of [...runtime.abortControllers]) {
    try { controller.abort(); } catch { /* ignore */ }
  }
  runtime.abortControllers.clear();
  runtime.abortController = null;
}

async function streamAnthropicMessages(messages, tools, options = {}) {
  const abort = createRequestAbort();
  try {
    return await streamAnthropicMessagesInner(messages, tools, options, abort);
  } finally {
    releaseRequestAbort(abort);
  }
}

async function streamAnthropicMessagesInner(messages, tools, options, abort) {
  const sessionId = options.sessionId || runtime.sessionId;
  const deltaEmitter = createAssistantDeltaEmitter(options);
  const activeTools = options.allowTools === false ? [] : anthropicToolsFromOpenAI(tools);
  const payload = anthropicPayloadMessages(messages);
  const model = options.modelOverride || runtime.config.model;
  const maxTokens = options.maxTokensOverride || runtime.config.maxTokens;
  const makeBody = (includeTools) => {
    const body = {
      model,
      system: payload.system || undefined,
      messages: payload.messages,
      stream: true,
      temperature: runtime.config.temperature,
      max_tokens: maxTokens,
    };
    if (includeTools && activeTools.length) {
      body.tools = activeTools;
    }
    return body;
  };
  const request = (includeTools) => fetch(normalizeAnthropicURL(runtime.config.baseURL), {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-api-key": runtime.apiKey,
      "anthropic-version": "2023-06-01",
      ...(runtime.config.headers || {}),
    },
    body: JSON.stringify(makeBody(includeTools)),
    signal: abort.signal,
  });

  let response = await requestWithRetry(
    () => request(activeTools.length > 0),
    {
      retries: 3,
      signal: abort.signal,
      onRetry: ({ attempt, delayMs, status }) => send({ type: "model_retry", sessionId, attempt, delayMs, status }),
    },
  );
  if (!response.ok && activeTools.length) {
    const firstError = await response.text();
    if (/tool|schema|input_schema/i.test(firstError)) {
      response = await request(false);
    } else {
      throw new Error(`Anthropic HTTP ${response.status}: ${firstError.slice(0, 1000)}`);
    }
  }
  if (!response.ok) throw new Error(`Anthropic HTTP ${response.status}: ${(await response.text()).slice(0, 1000)}`);

  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  let text = "";
  const blocks = new Map();
  const toolCalls = [];
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    const parts = buffer.split(/\n\n+/);
    buffer = parts.pop() || "";
    for (const part of parts) {
      for (const line of part.split(/\n/)) {
        if (!line.startsWith("data:")) continue;
        const data = line.slice(5).trim();
        if (!data || data === "[DONE]") continue;
        const event = parseJSON(data);
        const deltaText = accumulateAnthropicEvent(event, blocks, toolCalls);
        if (deltaText) {
          text += deltaText;
          deltaEmitter.push(deltaText);
        }
      }
    }
  }
  deltaEmitter.flush();
  const normalizedText = normalizeAssistantText(text);
  return { text: normalizedText, toolCalls };
}

async function streamChat(messages, tools, options = {}) {
  if (modelProtocol() === "anthropic") {
    return streamAnthropicMessages(messages, tools, options);
  }
  const abort = createRequestAbort();
  try {
    return await streamOpenAIChatInner(messages, tools, options, abort);
  } finally {
    releaseRequestAbort(abort);
  }
}

async function streamOpenAIChatInner(messages, tools, options, abort) {
  const sessionId = options.sessionId || runtime.sessionId;
  const deltaEmitter = createAssistantDeltaEmitter(options);
  const activeTools = options.allowTools === false ? [] : tools;
  const model = options.modelOverride || runtime.config.model;
  const maxTokens = options.maxTokensOverride || runtime.config.maxTokens;
  const makeBody = (includeTools) => {
    const body = {
      model,
      messages,
      stream: true,
      temperature: runtime.config.temperature,
      max_tokens: maxTokens,
    };
    if (includeTools && activeTools.length) {
      body.tools = activeTools;
      body.tool_choice = "auto";
    }
    return body;
  };
  const request = (includeTools) => fetch(normalizeBaseURL(runtime.config.baseURL), {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${runtime.apiKey}`,
      ...(runtime.config.headers || {}),
    },
    body: JSON.stringify(makeBody(includeTools)),
    signal: abort.signal,
  });

  let response = await requestWithRetry(
    () => request(activeTools.length > 0),
    {
      retries: 3,
      signal: abort.signal,
      onRetry: ({ attempt, delayMs, status }) => send({ type: "model_retry", sessionId, attempt, delayMs, status }),
    },
  );
  if (!response.ok && activeTools.length) {
    const firstError = await response.text();
    if (/tool|function|schema|tool_choice/i.test(firstError)) {
      send({ type: "tool_result", sessionId, id: randomUUID(), tool: "model", ok: false, content: "model does not support tools; falling back to plain chat" });
      response = await request(false);
    } else {
      throw new Error(`Model HTTP ${response.status}: ${firstError.slice(0, 1000)}`);
    }
  }
  if (!response.ok) throw new Error(`Model HTTP ${response.status}: ${(await response.text()).slice(0, 1000)}`);
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  let text = "";
  let reasoningText = "";
  let toolCalls = [];
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    const parts = buffer.split(/\n\n+/);
    buffer = parts.pop() || "";
    for (const part of parts) {
      for (const line of part.split(/\n/)) {
        if (!line.startsWith("data:")) continue;
        const data = line.slice(5).trim();
        if (!data || data === "[DONE]") continue;
        const event = parseJSON(data);
        const delta = event?.choices?.[0]?.delta || {};
        const contentDelta = openAITextContent(delta.content);
        if (contentDelta) {
          text += contentDelta;
          deltaEmitter.push(contentDelta);
        }
        const reasoningDelta = openAITextContent(delta.reasoning_content ?? delta.reasoningContent);
        if (reasoningDelta) {
          reasoningText += reasoningDelta;
        }
        accumulateToolCall(toolCalls, delta.tool_calls);
      }
    }
  }
  const filteredToolCalls = toolCalls.filter((call) => call.function?.name);
  const normalizedText = normalizeAssistantText(
    text || (filteredToolCalls.length === 0 ? reasoningText : ""),
  );
  if (!text && normalizedText) {
    deltaEmitter.push(normalizedText);
  }
  deltaEmitter.flush();
  return { text: normalizedText, toolCalls: filteredToolCalls };
}

async function finishWithoutMoreTools(loopMessages, sessionId = runtime.sessionId) {
  const finalMessages = [
    ...loopMessages,
    {
      role: "system",
      content: "The tool turn budget is exhausted. Do not call any more tools. Give the user the best concise answer from the tool results already available. If evidence is incomplete, say exactly what is missing and ask for the next instruction.",
    },
  ];
  const messageId = randomUUID();
  const result = await streamChat(finalMessages, [], { allowTools: false, sessionId, messageId });
  const text = result.text || "工具调用已达到上限。我已经停止继续调用工具；请告诉我下一步要继续查什么，或让我基于已有结果整理结论。";
  if (!result.text) {
    send({ type: "assistant_delta", sessionId, messageId, delta: text });
  }
  if (isCurrentSession(sessionId)) {
    runtime.messages.push({ role: "assistant", content: text });
    await saveHistory();
  }
  await appendSessionMessage({ role: "assistant", content: text }, sessionId);
  if (runtime.config.autoTitleEnabled !== false && isCurrentSession(sessionId)) {
    const firstUser = runtime.messages.find((message) => message.role === "user")?.content || "";
    send({ type: "conversation_title", sessionId: runtime.sessionId, title: generateConversationTitle(firstUser, text) });
  }
  if (isCurrentSession(sessionId)) {
    const lastUser = [...runtime.messages].reverse().find((message) => message.role === "user")?.content || "";
    await autoExtractMemoryAfterTurn(lastUser, text);
  }
  send({ type: "assistant_done", sessionId, messageId });
}

async function executeToolCall(call, sessionId = runtime.sessionId, agentContext = null) {
  const name = call.function.name;
  const args = parseToolArgs(call.function.arguments);
  const id = call.id || randomUUID();
  // agentId/agentLabel 让界面能把子 agent 的工具调用归到它自己的分组下。
  const origin = agentContext
    ? { agentId: agentContext.agentId, agentRole: agentContext.role, agentLabel: agentContext.label }
    : {};
  if (runtime.telemetry) runtime.telemetry.toolCalls += 1;
  send({ type: "tool_pending", sessionId, id, tool: name, arguments: args, ...origin });
  try {
    const builtIn = await runBuiltInTool(name, args, sessionId);
    if (builtIn) {
      trackMutation(name, args, builtIn);
      send({ type: "tool_result", sessionId, id, tool: name, ok: builtIn.ok, content: builtIn.content, ...origin });
      return builtIn.content;
    }
    for (const client of runtime.mcpClients.values()) {
      const tool = client.tools.find((item) => item.openAIName === name);
      if (!tool) continue;
      const result = await runWithPermission(
        { ...tool, kind: "mcp", displayName: tool.name, source: `mcp:${client.name}` },
        args,
        `${client.name}.${tool.name}`,
        async () => {
          const response = await client.call(tool, args);
          return { ok: true, content: JSON.stringify(response) };
        },
        sessionId,
      );
      send({ type: "tool_result", sessionId, id, tool: name, ok: result.ok, content: result.content, ...origin });
      return result.content;
    }
    const content = `Unknown tool: ${name}`;
    send({ type: "tool_result", sessionId, id, tool: name, ok: false, content, ...origin });
    return content;
  } catch (error) {
    const content = error.message || String(error);
    send({ type: "tool_result", sessionId, id, tool: name, ok: false, content, ...origin });
    return content;
  }
}

function builtInToolDescriptor(name) {
  if (name === "update_plan") return { kind: "update_plan", name, displayName: "更新计划", source: "harness" };
  if (name === "dispatch_agents") return { kind: "dispatch_agents", name, displayName: "派发子 agent", source: "harness" };
  if (name === "engineer_loop") return { kind: "engineer_loop", name, displayName: "工程师循环", source: "harness" };
  if (name === "list_skills") return { kind: "list_skills", name, displayName: name, source: "local" };
  if (name === "read_skill") return { kind: "skill_read", name, displayName: name, source: "local" };
  if (name === "run_skill_script") return { kind: "skill_script", name, displayName: name, source: "local" };
  if (name === "shell") return { kind: "shell", name, displayName: name, source: "local" };
  if (name === "apply_patch") return { kind: "apply_patch", name, displayName: name, source: "local" };
  if (name === "file_search") return { kind: "file_search", name, displayName: name, source: "local" };
  if (name === "memory_manage") return { kind: "memory_manage", name, displayName: name, source: "local" };
  if (name === "memory_write") return { kind: "memory_note_write", name, displayName: "写入记忆笔记", source: "memory" };
  if (name === "memory_recall") return { kind: "memory_recall", name, displayName: "召回记忆", source: "memory" };
  if (name === "memory_forget") return { kind: "memory_note_write", name, displayName: "删除记忆笔记", source: "memory" };
  if (name === "session_search") return { kind: "session_search", name, displayName: name, source: "local" };
  if (name === "propose_skill_evolution") return { kind: "propose_skill_evolution", name, displayName: name, source: "local" };
  if (name === "list_evolution_candidates") return { kind: "list_evolution_candidates", name, displayName: name, source: "local" };
  if (name === "apply_skill_evolution") return { kind: "apply_skill_evolution", name, displayName: "应用 Skill 演化", source: "self-evolution" };
  return null;
}

function descriptorForToolCall(call) {
  const name = call?.function?.name || "";
  const builtIn = builtInToolDescriptor(name);
  if (builtIn) return builtIn;
  for (const client of runtime.mcpClients.values()) {
    const tool = client.tools.find((item) => item.openAIName === name);
    if (tool) return { ...tool, kind: "mcp", displayName: tool.name, source: `mcp:${client.name}` };
  }
  return { kind: "unknown", name, displayName: name, source: "model" };
}

// 同名同参的调用反复出现，说明 agent 在原地打转，需要在下一轮提示它换路径。
function trackToolRepeats(calls) {
  return (Array.isArray(calls) ? calls : []).map((call) => {
    const name = call?.function?.name || "";
    const record = recordToolSignature(
      runtime.loopGuard,
      toolCallSignature(name, parseToolArgs(call?.function?.arguments)),
    );
    return { tool: name, ...record };
  });
}

function toolCallNeedsSequentialExecution(call) {
  const descriptor = descriptorForToolCall(call);
  const args = parseToolArgs(call?.function?.arguments);
  return classifyToolRisk(descriptor, args) === "confirm";
}

async function executeToolCalls(calls, sessionId = runtime.sessionId, agentContext = null) {
  const toolCalls = Array.isArray(calls) ? calls : [];
  const results = new Array(toolCalls.length);
  let parallel = [];

  const flushParallel = async () => {
    if (!parallel.length) return;
    const batch = parallel;
    parallel = [];
    await Promise.all(batch.map(async ({ call, index }) => {
      results[index] = await executeToolCall(call, sessionId, agentContext);
    }));
  };

  for (let index = 0; index < toolCalls.length; index += 1) {
    const call = toolCalls[index];
    if (toolCallNeedsSequentialExecution(call)) {
      await flushParallel();
      results[index] = await executeToolCall(call, sessionId, agentContext);
    } else {
      parallel.push({ call, index });
    }
  }
  await flushParallel();
  return results;
}

function compactModelName() {
  return String(runtime.config.compactModel || "").trim() || runtime.config.model;
}

function compactMaxTokens() {
  return boundedNumber(runtime.config.maxTokens, DEFAULT_CONFIG.maxTokens, 512, 8192);
}

function messagesForSummary(messages) {
  return normalizeHistoryMessages(messages)
    .map((message) => `${message.role.toUpperCase()}:\n${message.content}`)
    .join("\n\n---\n\n");
}

async function compactHistory(reason = "manual", sessionId = runtime.sessionId) {
  if (!runtime.configured) throw new Error("悬屿 runtime is not configured.");
  if (!runtime.apiKey) throw new Error("Missing API key.");
  const compactSessionId = String(sessionId || runtime.sessionId || "");

  const normalized = normalizeHistoryMessages(runtime.messages).slice(-historyCountLimit());
  const keepCount = Math.min(COMPACT_KEEP_RECENT_MESSAGES, normalized.length);
  const oldMessages = normalized.slice(0, Math.max(0, normalized.length - keepCount));
  const recentMessages = normalized.slice(Math.max(0, normalized.length - keepCount));
  if (!oldMessages.length) {
    send({ type: "compact_error", reason, message: "没有足够的旧上下文可压缩。" });
    return false;
  }

  send({
    type: "compact_started",
    reason,
    sessionId: compactSessionId,
    beforeCount: normalized.length,
    keepCount,
  });

  const existingSummary = String(runtime.contextSummary || "").trim();
  const prompt = [
    "Compress the earlier conversation into a durable context summary for a coding agent.",
    "Preserve concrete user preferences, project facts, decisions, file paths, unresolved tasks, tool results, and constraints.",
    "Do not add new facts. Keep it concise, Chinese when possible, with compact bullets.",
    existingSummary ? `Existing summary to update:\n${existingSummary}` : "",
    `Older messages to compress:\n${messagesForSummary(oldMessages)}`,
  ].filter(Boolean).join("\n\n");

  const result = await streamChat([
    {
      role: "system",
      content: "You are a context compactor. Return only the updated summary. Do not call tools.",
    },
    { role: "user", content: prompt },
  ], [], {
    allowTools: false,
    emitDelta: false,
    sessionId: compactSessionId,
    modelOverride: compactModelName(),
    maxTokensOverride: compactMaxTokens(),
  });

  const summary = normalizeAssistantText(result.text || existingSummary);
  if (!summary) {
    send({ type: "compact_error", reason, message: "压缩模型没有返回摘要。" });
    return false;
  }

  if (isCurrentSession(compactSessionId)) {
    runtime.contextSummary = summary;
    runtime.messages = recentMessages;
    await saveHistory();
  }
  send({
    type: "history_compacted",
    reason,
    sessionId: compactSessionId,
    contextSummary: summary,
    messages: recentMessages,
    beforeCount: normalized.length,
    afterCount: recentMessages.length,
    usage: contextUsageFor(recentMessages, summary, contextCharLimit()),
  });
  return true;
}

async function compactIfNeeded(sessionId = runtime.sessionId) {
  const usage = contextUsageFor(runtime.messages, runtime.contextSummary, contextCharLimit());
  send({ type: "context_usage", sessionId, ...usage });
  if (!shouldAutoCompact(runtime.messages, runtime.contextSummary, contextCharLimit())) return false;
  if (normalizeHistoryMessages(runtime.messages).length <= COMPACT_KEEP_RECENT_MESSAGES) return false;
  try {
    return await compactHistory("auto", sessionId);
  } catch (error) {
    send({ type: "compact_error", sessionId, reason: "auto", message: error.message || String(error) });
    return false;
  }
}

async function saveHistory() {
  if (!runtime.historyPath) return;
  await mkdir(dirname(runtime.historyPath), { recursive: true });
  await writeFile(
    runtime.historyPath,
    JSON.stringify({
      messages: runtime.messages.slice(-historyCountLimit()),
      contextSummary: runtime.contextSummary,
    }, null, 2),
  );
}

async function loadHistory() {
  if (!runtime.historyPath || !existsSync(runtime.historyPath)) return;
  const data = parseJSON(await readFile(runtime.historyPath, "utf8"), {});
  runtime.messages = normalizeHistoryMessages(data.messages);
  runtime.contextSummary = String(data.contextSummary || "");
}

async function replaceHistory(event) {
  runtime.messages = normalizeHistoryMessages(event.messages).slice(-historyCountLimit());
  runtime.contextSummary = String(event.contextSummary || "");
  runtime.sessionId = String(event.sessionId || runtime.sessionId || randomUUID());
  await saveHistory();
  send({
    type: "history_loaded",
    historyCount: runtime.messages.length,
    sessionId: runtime.sessionId,
    contextSummary: runtime.contextSummary,
  });
}

async function configure(payload) {
  runtime.config = { ...DEFAULT_CONFIG, ...(payload.config || {}) };
  runtime.apiKey = payload.apiKey || runtime.apiKey || "";
  runtime.configDir = payload.configDir || runtime.configDir || process.cwd();
  runtime.skillsRoot = payload.skillsRoot || runtime.skillsRoot || join(process.cwd(), "skills");
  runtime.historyPath = join(runtime.configDir, "history.json");
  runtime.sessionsPath = join(runtime.configDir, "sessions.jsonl");
  runtime.embeddingIndexPath = join(runtime.configDir, "session-embeddings.jsonl");
  runtime.memoryPath = join(runtime.configDir, "memory", "MEMORY.md");
  runtime.userProfilePath = join(runtime.configDir, "memory", "USER.md");
  runtime.evolutionPath = join(runtime.configDir, "evolution", "candidates.json");
  runtime.notesRoot = join(runtime.configDir, "memory", "notes");
  runtime.managedSkillsRoot = join(runtime.configDir, "skills");
  await mkdir(runtime.configDir, { recursive: true });
  await initializePersistentStores();
  await refreshSkills();
  await loadMemorySnapshot();
  await loadNotes();
  await loadHistory();
  await startMCPServers();
  runtime.configured = true;
  const candidates = await loadEvolutionCandidates();
  send({
    type: "ready",
    skills: runtime.skills.map(skillListItem),
    mcpServers: [...runtime.mcpClients.values()].map((client) => ({ name: client.name, toolCount: client.tools.length })),
    historyCount: runtime.messages.length,
    memoryUsage: {
      memory: memoryUsage(runtime.memorySnapshot.memory, memoryLimitFor("memory")),
      user: memoryUsage(runtime.memorySnapshot.user, memoryLimitFor("user")),
    },
    evolutionCandidateCount: candidates.filter((candidate) => candidate.status === "proposed").length,
  });
  await sendMemoryAudit();
  await sendEvolutionAudit();
}

async function runAgent(userText, attachments = [], sessionId = runtime.sessionId) {
  if (!runtime.configured) throw new Error("悬屿 runtime is not configured.");
  if (!runtime.apiKey) throw new Error("Missing API key.");
  const runSessionId = String(sessionId || runtime.sessionId || randomUUID());
  runtime.cancelledSessions.delete(runSessionId);
  const attachmentContext = await buildAttachmentContext(attachments);
  const messageText = attachmentContext ? `${userText}\n\n${attachmentContext}` : userText;
  if (isCurrentSession(runSessionId)) {
    runtime.messages.push({ role: "user", content: messageText });
  }
  await appendSessionMessage({ role: "user", content: messageText }, runSessionId);
  if (isCurrentSession(runSessionId)) {
    await compactIfNeeded(runSessionId);
  }
  // 按本轮提问召回相关笔记，正文只在这一轮进上下文。
  const recallLimit = boundedNumber(runtime.config.memoryAutoRecallLimit, 3, 0, 8);
  runtime.recalledNotes = recallLimit > 0 ? recallNotesForText(messageText, recallLimit) : [];
  if (runtime.recalledNotes.length) {
    send({
      type: "memory_recalled",
      sessionId: runSessionId,
      notes: runtime.recalledNotes.map((note) => ({ name: note.name, type: note.type, description: note.description })),
    });
  }
  const tools = openAITools();
  const harnessOn = runtime.config.harnessEnabled !== false;
  const maxTurns = boundedNumber(runtime.config.maxToolTurns, HARNESS_DEFAULTS.maxToolTurns, 1, 60);
  runtime.plan = [];
  runtime.loopGuard = createLoopGuardState();
  runtime.telemetry = createRunTelemetry({ maxToolTurns: maxTurns });
  emitHarnessStatus(runSessionId);

  let loopMessages = contextMessagesForTurn(messageText);
  for (let turn = 0; turn < maxTurns; turn += 1) {
    if (isCancelledSession(runSessionId)) return;
    runtime.telemetry.turn = turn + 1;
    const messageId = randomUUID();
    const result = await streamChat(loopMessages, tools, { sessionId: runSessionId, messageId });
    if (isCancelledSession(runSessionId)) return;
    if (!result.toolCalls.length) {
      // 收尾自检闸门：本轮真改过东西却还没自检，就退回循环里先验证一次。
      const verifyNotice = harnessOn && runtime.config.verifyGateEnabled !== false
        ? verificationNotice(runtime.telemetry)
        : "";
      if (verifyNotice && turn < maxTurns - 1) {
        runtime.telemetry.verifyRequested = true;
        if (result.text) {
          loopMessages.push({ role: "assistant", content: result.text });
          send({ type: "assistant_segment_done", sessionId: runSessionId, messageId });
        }
        loopMessages.push({ role: "system", content: verifyNotice });
        emitHarnessStatus(runSessionId);
        continue;
      }
      const assistantText = result.text
        || "模型返回了空响应。请重试；如果持续发生，请检查当前模型的 OpenAI 兼容流格式。";
      if (!result.text) {
        send({ type: "assistant_delta", sessionId: runSessionId, messageId, delta: assistantText });
      }
      if (isCurrentSession(runSessionId)) {
        runtime.messages.push({ role: "assistant", content: assistantText });
        await saveHistory();
      }
      await appendSessionMessage({ role: "assistant", content: assistantText }, runSessionId);
      if (runtime.config.autoTitleEnabled !== false && isCurrentSession(runSessionId)) {
        const firstUser = runtime.messages.find((message) => message.role === "user")?.content || userText;
        send({ type: "conversation_title", sessionId: runSessionId, title: generateConversationTitle(firstUser, assistantText) });
      }
      if (isCurrentSession(runSessionId)) {
        await autoExtractMemoryAfterTurn(messageText, assistantText);
      }
      send({ type: "assistant_done", sessionId: runSessionId, messageId });
      return;
    }
    const assistant = { role: "assistant", content: result.text || null, tool_calls: result.toolCalls };
    loopMessages.push(assistant);
    if (result.text) {
      send({ type: "assistant_segment_done", sessionId: runSessionId, messageId });
    }
    const repeats = harnessOn ? trackToolRepeats(result.toolCalls) : [];
    const toolResults = await executeToolCalls(result.toolCalls, runSessionId);
    if (isCancelledSession(runSessionId)) return;
    for (let index = 0; index < result.toolCalls.length; index += 1) {
      const call = result.toolCalls[index];
      loopMessages.push({ role: "tool", tool_call_id: call.id, content: toolResults[index] });
    }
    if (harnessOn) {
      const notices = [loopGuardNotice(repeats), budgetNotice({ turn: turn + 1, maxTurns })].filter(Boolean);
      if (notices.length) loopMessages.push({ role: "system", content: notices.join("\n\n") });
      // 计划会在循环中途被 update_plan 改写，系统提示要跟着刷新，否则模型看不到自己的最新计划。
      if (loopMessages[0]?.role === "system") {
        loopMessages[0] = { role: "system", content: systemPromptFor(messageText) };
      }
      emitHarnessStatus(runSessionId);
    }
  }
  await finishWithoutMoreTools(loopMessages, runSessionId);
}

async function reset(event = {}) {
  runtime.messages = [];
  runtime.contextSummary = "";
  runtime.plan = [];
  runtime.telemetry = null;
  runtime.loopGuard = createLoopGuardState();
  runtime.sessionId = String(event.sessionId || randomUUID());
  runtime.cancelledSessions.delete(runtime.sessionId);
  await loadMemorySnapshot();
  await saveHistory();
  const candidates = await loadEvolutionCandidates();
  send({
    type: "ready",
    historyCount: 0,
    skills: runtime.skills.map(skillListItem),
    mcpServers: [...runtime.mcpClients.values()].map((client) => ({ name: client.name, toolCount: client.tools.length })),
    memoryUsage: {
      memory: memoryUsage(runtime.memorySnapshot.memory, memoryLimitFor("memory")),
      user: memoryUsage(runtime.memorySnapshot.user, memoryLimitFor("user")),
    },
    evolutionCandidateCount: candidates.filter((candidate) => candidate.status === "proposed").length,
  });
  await sendMemoryAudit();
  await sendEvolutionAudit();
}

async function applyEvolutionCandidateFromUI(event) {
  const candidateId = event.candidateId || event.id;
  if (!candidateId) {
    send({ type: "error", message: "Missing evolution candidate id." });
    return;
  }
  const toolEventId = event.toolEventId || randomUUID();
  send({
    type: "tool_pending",
    id: toolEventId,
    tool: "apply_skill_evolution",
    arguments: { id: candidateId },
  });
  const result = await applySkillEvolution({ id: candidateId });
  send({
    type: "tool_result",
    id: toolEventId,
    tool: "apply_skill_evolution",
    ok: result.ok,
    content: result.content,
  });
  await sendEvolutionAudit();
}

async function handleInput(event) {
  if (event.type === "configure") return configure(event);
  if (event.type === "list_memory_audit") return sendMemoryAudit();
  if (event.type === "delete_memory_entry") return mutateMemoryEntryByIndex(event, "remove");
  if (event.type === "delete_memory_note") return forgetMemoryNote(event);
  if (event.type === "replace_memory_entry") return mutateMemoryEntryByIndex(event, "replace");
  if (event.type === "list_evolution_candidates") return sendEvolutionAudit();
  if (event.type === "reject_evolution_candidate") return rejectEvolutionCandidate(event);
  if (event.type === "apply_evolution_candidate") return applyEvolutionCandidateFromUI(event);
  if (event.type === "replace_history") return replaceHistory(event);
  if (event.type === "compact") {
    try {
      return compactHistory(event.reason || "manual", event.sessionId || runtime.sessionId);
    } catch (error) {
      return send({ type: "compact_error", sessionId: event.sessionId || runtime.sessionId, reason: event.reason || "manual", message: error.message || String(error) });
    }
  }
  if (event.type === "user_message") return runAgent(event.text || "", event.attachments || [], event.sessionId || runtime.sessionId);
  if (event.type === "approve_tool" || event.type === "deny_tool") {
    const resolver = runtime.pendingPermissions.get(event.id);
    if (resolver) {
      runtime.pendingPermissions.delete(event.id);
      resolver(event.type === "approve_tool");
    }
    return;
  }
  if (event.type === "cancel") {
    const sessionId = String(event.sessionId || runtime.sessionId);
    runtime.cancelledSessions.add(sessionId);
    abortAllRequests();
    terminateActiveProcesses();
    for (const resolver of runtime.pendingPermissions.values()) {
      resolver(false);
    }
    runtime.pendingPermissions.clear();
    send({ type: "assistant_done", sessionId, messageId: "assistant-current" });
    return;
  }
  if (event.type === "reset") return reset(event);
}

export function parseRuntimeLine(line) {
  return parseJSON(line, null);
}

if (fileURLToPath(import.meta.url) === process.argv[1]) {
  const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });
  rl.on("line", async (line) => {
    const event = parseRuntimeLine(line);
    if (!event) return send({ type: "error", message: "Invalid JSONL input." });
    try {
      await handleInput(event);
    } catch (error) {
      if (error?.name === "AbortError") return;
      send({ type: "error", sessionId: event.sessionId || runtime.sessionId, message: error.message || String(error) });
    }
  });
  send({ type: "ready", skills: [], mcpServers: [], historyCount: 0 });
}
