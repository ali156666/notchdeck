// Generated from src/memory.ts
// 悬屿长期记忆的笔记层：一条事实一个文件，带类型和描述。
// 索引常驻系统提示，正文按相关性召回——这样记忆条数可以增长而不挤占上下文。
// 这里只放纯函数，落盘和向量检索由 runtime.ts 负责。

export const NOTE_TYPES = ["user", "feedback", "project", "reference"];
const NOTE_TYPE_SET = new Set(NOTE_TYPES);

export const NOTE_LIMITS = {
  name: 48,
  description: 200,
  body: 4000,
  maxNotes: 500,
  indexNotes: 120,
  indexChars: 9000,
  recallNotes: 4,
  recallChars: 6000,
  links: 12,
};

export function normalizeNoteName(value) {
  return String(value || "")
    .trim()
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, NOTE_LIMITS.name);
}

export function normalizeNoteType(value) {
  const type = String(value || "").trim().toLowerCase();
  return NOTE_TYPE_SET.has(type) ? type : "project";
}

function oneLine(value, limit) {
  return String(value || "").replace(/\s+/g, " ").trim().slice(0, limit);
}

/** 正文里的 [[name]] 就是笔记之间的关联，不额外开一个字段。 */
export function extractLinks(body) {
  const found = [];
  const seen = new Set();
  for (const match of String(body || "").matchAll(/\[\[([^\]]+)\]\]/g)) {
    const name = normalizeNoteName(match[1]);
    if (!name || seen.has(name)) continue;
    seen.add(name);
    found.push(name);
    if (found.length >= NOTE_LIMITS.links) break;
  }
  return found;
}

export function serializeNote(note) {
  const front = [
    "---",
    `name: ${note.name}`,
    `description: ${note.description}`,
    `type: ${note.type}`,
    `createdAt: ${note.createdAt}`,
    `updatedAt: ${note.updatedAt}`,
    "---",
  ].join("\n");
  return `${front}\n\n${String(note.body || "").trim()}\n`;
}

export function parseNote(text, fallbackName = "") {
  const raw = String(text || "");
  const match = raw.match(/^---\n([\s\S]*?)\n---\n?([\s\S]*)$/);
  const front = {};
  let body = raw;
  if (match) {
    body = match[2] || "";
    for (const line of match[1].split("\n")) {
      const pair = line.match(/^([a-zA-Z]+):\s*(.*)$/);
      if (pair) front[pair[1]] = pair[2].trim();
    }
  }
  const name = normalizeNoteName(front.name || fallbackName);
  if (!name) return null;
  const trimmedBody = body.trim();
  return {
    name,
    description: oneLine(front.description, NOTE_LIMITS.description),
    type: normalizeNoteType(front.type),
    createdAt: front.createdAt || "",
    updatedAt: front.updatedAt || front.createdAt || "",
    body: trimmedBody,
    links: extractLinks(trimmedBody),
  };
}

/**
 * 复用 MEMORY.md 那套注入扫描规则，笔记正文同样不允许藏指令和密钥。
 */
export function validateNote(note, { scanContent } = {}) {
  if (!note.name) return "name 不能为空。";
  if (!note.description) return "description 不能为空，它是召回时唯一可见的线索。";
  if (!note.body) return "笔记正文不能为空。";
  if (note.body.length > NOTE_LIMITS.body) {
    return `笔记正文 ${note.body.length} 字符，超过 ${NOTE_LIMITS.body} 上限。拆成多条更小的事实。`;
  }
  if (scanContent) {
    const problem = scanContent(`${note.description}\n${note.body}`);
    if (problem) return problem;
  }
  return "";
}

/** feedback / project 类型没写清楚原因和用法时给个软提醒，不阻断写入。 */
export function noteQualityHint(note) {
  if (note.type !== "feedback" && note.type !== "project") return "";
  const hasWhy = /\*\*Why:\*\*/i.test(note.body);
  const hasHow = /\*\*How to apply:\*\*/i.test(note.body);
  if (hasWhy && hasHow) return "";
  const missing = [!hasWhy ? "**Why:**" : "", !hasHow ? "**How to apply:**" : ""].filter(Boolean).join(" 和 ");
  return `建议补上 ${missing}：${note.type} 类型的记忆只有说清原因和适用方式，以后召回时才用得上。`;
}

export function upsertNote(notes, note) {
  const list = Array.isArray(notes) ? [...notes] : [];
  const index = list.findIndex((item) => item.name === note.name);
  if (index >= 0) {
    list[index] = note;
    return { notes: list, created: false };
  }
  if (list.length >= NOTE_LIMITS.maxNotes) {
    return { notes: list, created: false, error: `记忆笔记已达 ${NOTE_LIMITS.maxNotes} 条上限，先清理再写入。` };
  }
  list.push(note);
  return { notes: list, created: true };
}

export function noteIndexLine(note) {
  return `- ${note.name} (${note.type}) — ${note.description}`;
}

/**
 * 常驻系统提示的索引：每条只占一行，让 agent 知道自己"知道什么"，
 * 需要细节时再用 memory_recall 取正文。
 */
export function renderNoteIndex(notes, limits = NOTE_LIMITS) {
  const list = Array.isArray(notes) ? notes : [];
  if (!list.length) return "";
  const sorted = [...list].sort((left, right) =>
    String(right.updatedAt || "").localeCompare(String(left.updatedAt || "")));
  const lines = [];
  let used = 0;
  let dropped = 0;
  for (const note of sorted) {
    const line = noteIndexLine(note);
    if (lines.length >= limits.indexNotes || used + line.length > limits.indexChars) {
      dropped += 1;
      continue;
    }
    lines.push(line);
    used += line.length;
  }
  return [
    `════════════════ MEMORY INDEX [${lines.length}/${list.length} 条] ════════════════`,
    ...lines,
    dropped ? `（另有 ${dropped} 条较早的笔记未列出，用 memory_recall 搜索）` : "",
    "这些只是标题和摘要。需要某条的完整内容时用 memory_recall 取，不要凭描述猜正文。",
  ].filter(Boolean).join("\n");
}

export function renderRecalledNotes(notes, heading = "AUTO-RECALLED MEMORY") {
  const list = Array.isArray(notes) ? notes : [];
  if (!list.length) return "";
  return [
    `════════════════ ${heading} ════════════════`,
    ...list.map((note) => [
      `## ${note.name} (${note.type})`,
      note.updatedAt ? `更新于 ${note.updatedAt}` : "",
      note.body,
    ].filter(Boolean).join("\n")),
  ].join("\n\n");
}

/**
 * 刻意不把单个汉字当 token：「多久」和「最多」共用一个「多」就会误召回。
 * 二元组对中文已经足够有区分度，英文数字仍按整词匹配。
 */
export function noteTokens(text) {
  const value = String(text || "").toLowerCase();
  const words = (value.match(/[\p{L}\p{N}_./:-]+/gu) || [])
    .filter((word) => word.length > 1 || !/\p{Script=Han}/u.test(word));
  const han = value.match(/\p{Script=Han}/gu) || [];
  const bigrams = [];
  for (let index = 0; index < han.length - 1; index += 1) {
    bigrams.push(`${han[index]}${han[index + 1]}`);
  }
  return [...new Set([...words, ...bigrams])].filter(Boolean);
}

/**
 * 词面相关性。name 和 description 的权重高于正文：
 * 它们是人写给召回用的线索，正文里的偶然词命中不该压过它们。
 */
export function scoreNote(note, queryTokens) {
  const tokens = Array.isArray(queryTokens) ? queryTokens : [];
  if (!tokens.length) return 0;
  const name = `${note.name}`.toLowerCase();
  const description = `${note.description}`.toLowerCase();
  const body = `${note.body}`.toLowerCase();
  let score = 0;
  for (const token of tokens) {
    if (name.includes(token)) score += 3;
    if (description.includes(token)) score += 2;
    if (body.includes(token)) score += 1;
  }
  return score;
}

export function selectRecallNotes(notes, query, options = {}) {
  const limits = { ...NOTE_LIMITS, ...(options.limits || {}) };
  const tokens = noteTokens(query);
  const semantic = options.semanticScores instanceof Map ? options.semanticScores : null;
  const maxNotes = Math.max(1, Number(options.limit) || limits.recallNotes);
  const scored = (Array.isArray(notes) ? notes : [])
    .map((note) => {
      const lexical = scoreNote(note, tokens);
      const vector = semantic?.get(note.name) || 0;
      return { note, score: lexical + vector * 6, lexical, semantic: vector };
    })
    .filter((item) => item.score > 0)
    .sort((left, right) => right.score - left.score
      || String(right.note.updatedAt || "").localeCompare(String(left.note.updatedAt || "")));

  const selected = [];
  let used = 0;
  for (const item of scored) {
    if (selected.length >= maxNotes) break;
    const size = item.note.body.length;
    if (selected.length > 0 && used + size > limits.recallChars) continue;
    selected.push(item.note);
    used += size;
  }
  return selected;
}

/**
 * 把一条 MEMORY.md 扁平条目提升成笔记，用于热记忆写满时腾地方。
 * 名字从内容里取，去掉"用户偏好："这类前缀；重名时自动加序号。
 */
export function noteFromFlatEntry(text, { now = "", existingNames = [] } = {}) {
  const value = String(text || "").trim();
  if (!value) return null;
  const taken = new Set(existingNames);
  const seed = value.replace(/^[^：:]{0,12}[：:]/, "").trim() || value;
  let name = normalizeNoteName(seed.slice(0, 24)) || "note";
  let suffix = 2;
  while (taken.has(name)) {
    name = `${normalizeNoteName(seed.slice(0, 20)) || "note"}-${suffix}`;
    suffix += 1;
  }
  return {
    name,
    description: oneLine(value, NOTE_LIMITS.description),
    type: "project",
    createdAt: now,
    updatedAt: now,
    body: value,
    links: extractLinks(value),
  };
}

export function noteAuditEntries(notes) {
  return (Array.isArray(notes) ? notes : []).map((note, index) => ({
    id: `note:${note.name}`,
    target: "note",
    index,
    text: note.body,
    name: note.name,
    description: note.description,
    noteType: note.type,
    updatedAt: note.updatedAt,
    links: note.links || [],
  }));
}
