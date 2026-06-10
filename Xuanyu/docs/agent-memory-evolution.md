# Agent 长期记忆与自进化架构

## 目标

让悬屿内的独立 Agent 在不依赖 Codex runtime 的前提下，逐步形成稳定的长期记忆和可审核的流程能力。

设计参考：

- [Hermes Agent Persistent Memory](https://hermes-agent.nousresearch.com/docs/user-guide/features/memory)
- [Hermes Agent Skills System](https://hermes-agent.nousresearch.com/docs/user-guide/features/skills)
- [Hermes Agent Self-Evolution](https://github.com/NousResearch/hermes-agent-self-evolution)

## 分层

### 1. 关键记忆

存储位置：

```text
~/Library/Application Support/Xuanyu/agent/memory/MEMORY.md
~/Library/Application Support/Xuanyu/agent/memory/USER.md
```

- `MEMORY.md`：环境事实、项目约定、纠错、可复用经验。
- `USER.md`：用户偏好、表达方式和工作习惯。
- 两者均有字符上限，避免 prompt 无限制增长。
- 内容通过 `§` 分隔，支持增加、替换和删除。
- 每次 runtime 配置或清空会话时生成冻结快照。会话中写入立即落盘，但下次会话才进入 system prompt。

### 2. 完整会话归档

存储位置：

```text
~/Library/Application Support/Xuanyu/agent/sessions.jsonl
```

- 每条用户消息和最终回复都追加保存。
- `history.json` 继续保存短上下文窗口。
- `session_search` 按需检索完整历史，不把旧聊天常驻塞进 prompt。

### 3. 流程技能

内置 Skills 继续随 App 打包。Agent 生成或审核通过的 Skill 写入：

```text
~/Library/Application Support/Xuanyu/agent/skills/<skill-name>/SKILL.md
```

本地 Skill 优先于 App 内置 Skill，用于覆盖和迭代。

### 4. 自进化候选

候选队列：

```text
~/Library/Application Support/Xuanyu/agent/evolution/candidates.json
```

闭环：

```text
会话证据 -> propose_skill_evolution -> 候选队列 -> 用户审核
         -> apply_skill_evolution -> 权限确认 -> 本地 Skill 生效
```

候选不会自动覆盖线上 Skill。应用候选必须通过悬屿内权限确认。

## Runtime 工具

| 工具 | 用途 |
| --- | --- |
| `memory_manage` | 增加、替换、删除有界关键记忆 |
| `session_search` | 检索完整跨会话归档 |
| `propose_skill_evolution` | 从会话证据生成 Skill 演化候选 |
| `list_evolution_candidates` | 查看待审核和已应用候选 |
| `apply_skill_evolution` | 经权限确认后应用候选 |

## 当前门禁

- MEMORY 默认上限 `2200` 字符。
- USER 默认上限 `1375` 字符。
- 精确重复记忆不重复写入。
- 替换和删除必须命中唯一条目。
- 记忆写入会过滤隐藏字符、常见 prompt 注入句式和密钥形态。
- Skill 候选最大 `15KB`。
- Skill 应用必须人工确认。

## 后续阶段

1. 在 Agent 设置页增加记忆条目浏览、手动删除和候选审核列表。
2. 将 `sessions.jsonl` 升级为 SQLite FTS5，支持更快的全文检索和上下文滚动。
3. 为候选增加基准样例、回放评估、版本差异和回滚。
4. 记录工具调用轨迹，从重复成功路径和重复纠错中自动生成候选。
5. 接入可选的语义记忆 provider，但保留本地 MEMORY、USER 作为稳定核心。
