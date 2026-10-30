# 移植指南：把这个 skill 用到其他 agent

> **一句话**：规则层（怎么做事）跨 agent 通用，照抄；自动化层（心跳/轮次/子代理/崩溃恢复）是 DSH 专属能力，换平台必须换实现。
>
> 本文列出**每一项依赖、DSH 里的实现、其他平台的替代方案、以及具体要改哪个文件哪一条**。

---

## 1. 能力依赖清单

| 能力 | DSH 里的实现 | 可移植性 | 其他平台怎么办 |
|---|---|---|---|
| **skill 加载与触发** | `SKILL.md` frontmatter（name/description）+ `~/.dsh/skills/<name>/` 目录，按需加载 `references/` | 🟡 格式接近 | Claude Code 的 skill 目录格式几乎相同；Codex 等无 skill 系统 → 并入指令文件 |
| **心跳（崩溃续跑）** | `schedule_create`：15 分钟一次，**宿主重启后任务仍可用、到期恢复冷会话** | 🔴 DSH 独有 | 系统 cron / 计划任务调用 agent CLI；**每次是新会话**，靠状态文件重建上下文 |
| **轮次推进** | `goal` + `goal-round-driver`：空闲自动续轮、轮数上限、`blockedAfterConsecutiveRounds` | 🔴 DSH 独有 | 外部循环脚本；或手动说"继续" |
| **子代理与模型路由** | `subagent` 工具 + `agentOptions`（默认继承父模型） | 🟡 有对应物 | Claude Code 的 Task；其他平台查文档 |
| **指令注入** | `AGENTS.md` 加载链（`$DSH_HOME` → 项目根 → cwd，65KB 预算） | 🟢 概念通用 | `CLAUDE.md` / `AGENTS.md` / system prompt |
| **存活信号** | 会话日志 `session.jsonl.zstd` 的 mtime | 🟡 格式不同 | 目标平台的会话日志路径 |
| **审批/重试** | `approval: never`、`retryPolicy`（默认 5 次） | 🟢 配置概念通用 | 目标平台的等价设置 |
| **状态目录** | 项目内 `night-shift/`（纯文件） | 🟢 完全通用 | 直接照搬 |

图例：🟢 直接可用 / 🟡 需要小改 / 🔴 必须重写实现。

---

## 2. 逐项改造指南

### 2.1 skill 加载与触发

- **DSH**：`~/.dsh/skills/night-shift/SKILL.md`，frontmatter 的 `description` 决定何时触发；`references/*.md` 由 agent 按需读取。
- **Claude Code**：格式几乎一致（`~/.claude/skills/<name>/SKILL.md`），**直接复制即可**，只需确认 description 的触发词符合你的说法。
- **Codex / 其他无 skill 系统的 agent**：
  1. 把 `SKILL.md` 正文并入 `AGENTS.md`（或 system prompt）；
  2. `references/` 保持为独立文件，在指令里写清"需要时读 `<路径>/references/xxx.md`"——**不要全文注入**，会撑爆上下文。

**要改的文件**：`SKILL.md` 的 frontmatter（如目标平台要求不同字段）；`README` 的安装路径。

### 2.2 心跳（最关键，DSH 独有）

**DSH 的行为**：提醒持久化在宿主里，重启后仍有效，到期**恢复冷会话**并投递——所以是"同一会话续跑"。

**其他平台的现实**：没有"冷会话恢复"，定时任务只能**新开一个会话**。这意味着：

- 上下文不再连续 → 每次心跳必须**从 `night-shift/` 状态文件重建**；
- 心跳提示词要改：不是"接着跑"，而是"**先读状态再判断**"。

**推荐实现（能跑 CLI 的 agent）**：

```bash
# cron / Task Scheduler 每 15 分钟
cd /path/to/project && <agent-cli> -p "夜班心跳：先读 night-shift/ 下的 briefs/、DECISIONS.md、summaries/ 与 BUG-BOARD.md，判断夜班是否完成；未完成则继续推进；已完成则退出。"
```

**要改的条目**：

- `SKILL.md` §0 第 5 条（心跳保活）：改为"外部定时器 + 新会话 + 读状态重建"；
- 心跳提示词模板：加"先读状态"；
- 删掉对 `schedule_*` 工具的依赖（`HEARTBEAT.md` 可保留为记录，但不再有"提醒 id"）。

**代价要写清**：新会话每次都要重新加载指令 + 读状态，**token 成本高于 DSH 的续跑**；且没有"补发最近一次"的语义，停机期间的心跳直接丢失。

### 2.3 轮次推进（Goal 替代）

**DSH**：`goal` + 驱动器在 agent 空闲时自动开下一轮，轮数耗尽记 `round-limit`，连续 3 轮受阻才允许标 blocked。

**其他平台**：没有等价物。两个选择：

1. **外部循环**（推荐）：

```bash
for i in $(seq 1 20); do
  <agent-cli> -p "读 BUG-BOARD.md 与 night-shift/ 状态，推进下一个未完成任务；若全部完成或已 blocked 则输出 DONE 并退出。"
  # 输出含 DONE 则 break
done
```

2. **手动**：每轮结束你自己说"继续"。

**要改的条目**：

- `SKILL.md` §2 第 1 步（挂 Goal）：改为"由外部循环驱动"或"人工推进"；
- "连续 ≥3 轮同类失败 → 标 blocked"：DSH 靠引擎，其他平台**靠脚本计数**（把失败次数写进 `night-shift/DECISIONS.md` 或一个计数文件）。

### 2.4 子代理与模型路由

- **DSH**：`subagent`（spawn 新上下文）/ `subagent_fork`（继承对话）；默认**继承父模型**，配 `agentOptions` 才便宜。
- **Claude Code**：用其 Task/子代理机制；模型选择看其配置。
- **没有子代理的平台**：串行做，`SKILL.md` 里"独立可并行任务 spawn"的段落删掉即可——不影响主流程。

**要改的条目**：`SKILL.md` §2 第 4 条；`README` 的"模型路由"章节。

### 2.5 指令注入（AGENTS.md → 目标平台）

- DSH 读 `AGENTS.md`（`$DSH_HOME` → 项目根 → cwd）；
- Claude Code 读 `CLAUDE.md`；Codex 读 `AGENTS.md`（同名）；其他看文档。

**要改的条目**：`references/project-init.md` 里所有 `AGENTS.md` 字样（改成目标文件名）；幂等标记 `<!-- night-shift-knowledge:v0 ... -->` 不用改。

### 2.6 存活信号与看门狗

- DSH 用会话日志 mtime；其他平台换成**目标平台的会话/日志文件**，找不到就用"心跳脚本自己的运行记录"（更弱，不推荐）。
- 看门狗脚本（`scripts/`）本身是通用的，只需改三处：
  1. `dshProcessName`（进程名）；
  2. `dshExecutable`（可执行文件路径）；
  3. 启动命令（Windows `Start-Process` / macOS `open` 之外的情况）。

**要改的条目**：`config.json` 的两个字段；`scripts/README.md` 的说明。

### 2.7 审批与重试

- DSH：`approval: never`（敏感操作确定性拒绝）+ `retryPolicy` 默认 5 次；
- 其他平台：找等价设置；没有就靠"规则里禁止危险操作"+ 人工守夜。

**要改的条目**：`README` 的"一次性配置"章节。

---

## 3. 按平台的最小改造清单

### Claude Code

| 步骤 | 动作 |
|---|---|
| 1 | 复制 `night-shift/` 到 `~/.claude/skills/night-shift/`（格式兼容） |
| 2 | `project-init.md`：`AGENTS.md` → `CLAUDE.md` |
| 3 | 心跳：cron + `claude -p "..."`（新会话，读状态重建） |
| 4 | 轮次：外部循环或手动 |
| 5 | 子代理：换成 Task 工具（或删掉并行段落） |
| 6 | 看门狗：改进程名与启动命令 |

### Codex / 其他 CLI agent

| 步骤 | 动作 |
|---|---|
| 1 | `SKILL.md` 正文并入 `AGENTS.md`（或 system prompt） |
| 2 | `references/` 保持独立文件，指令里写"按需读取路径" |
| 3 | 心跳/轮次：全部用外部脚本（cron + 循环） |
| 4 | 删除所有 `schedule_*`、`goal_*`、`subagent` 工具调用说明 |
| 5 | 保留 `night-shift/` 状态目录结构（这是唯一的跨平台资产） |

### 任何平台都通用的部分（照抄不改）

- `references/habits.md`（习惯决策树）
- `references/verification.md`（证据标准）
- `references/templates.md`（产出物模板）
- 依赖分治、git 红线、知识三层结构
- `night-shift/` 目录布局与文件命名

---

## 4. 移植后必须验证的 5 件事

1. **触发**：说"挂机/我不在"时 agent 真的进入该模式；
2. **状态重建**：新会话能读懂 `night-shift/` 并接着干（这是 cron 方案的核心）；
3. **证据**：验收命令能跑、证据落到 `evidence/<日期>/`；
4. **崩溃恢复**：杀掉进程后，定时器/看门狗能把它拉回来；
5. **成本**：量一下每轮心跳的 token（新会话模式通常比 DSH 续跑贵）。

---

## 5. 已知不兼容点（诚实清单）

| 差异 | 影响 | 缓解 |
|---|---|---|
| 没有"冷会话恢复" | 每次心跳都是新会话，上下文要重建 | 状态文件写全；心跳提示词强制"先读状态" |
| 没有"补发最近一次" | 停机期间的心跳直接丢失 | 定时器频率别太低；开机后手动触发一次 |
| 没有 `blockedAfterConsecutiveRounds` | 模型可能过早/过晚放弃 | 脚本计数，达到 3 次自动停 |
| 子代理默认模型行为不同 | 可能很贵 | 查目标平台文档，显式指定便宜模型 |
| 看门狗依赖进程名/路径 | 换平台/改安装路径就失效 | 装好后先手动跑一次验证 |
