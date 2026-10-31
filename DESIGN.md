# Night Shift 设计说明（给人和给未来的维护者）

> **English abstract**: This document explains the structure of the night-shift skill — four layers (skill body / project / host / engine), one-night sequence, per-task loop, crash recovery (watchdog + heartbeat), dependency decision tree, knowledge layers, file map, parameters, and common misconceptions. Full English manual: [`README.en.md`](README.en.md). Diagrams use Mermaid; an ASCII overview is at the top for viewers without Mermaid support.

> 本文回答三个问题：**它由哪些部分组成**、**一夜是怎么跑的**、**出问题时谁兜底**。
> 规则细节见 `SKILL.md`（agent 手册）与 `README.md`（人用手册）；本文只讲结构与流向。
> **适用范围**：名字叫 night-shift，但触发条件是"**人不在设备前**"（出门/开会/通勤/吃饭/睡觉），不限夜间。

---

## 一页看懂（ASCII）

```
                          ┌──────────────────────────────────────────┐
   你（睡前 3 分钟）       │  任务清单 BUG-BOARD.md / TODO            │
        │                 └──────────────────────────────────────────┘
        ▼
  「按 night-shift 挂机」
        │
        ▼
 ┌───────────────┐   一次性    ┌────────────────────────────────────┐
 │ 预检单         │──────────▶ │ 你能拍板的：需求歧义/设计取舍/依赖预授权 │
 └───────────────┘             └────────────────────────────────────┘
        │ 没答的落回习惯默认
        ▼
 ┌──────────────────────────────────────────────────────────────────┐
 │ 主循环（你选的模型）：项目初始化 → 挂 Goal → 建心跳 → 写运行登记表   │
 │   ┌──────────────────────────────────────────────────────────┐   │
 │   │ 任务 N：调研 → 实现 → 验证出证据 → commit → 写总结          │   │
 │   │         ↑________ 失败就修，串行留在主循环 ________|        │   │
 │   └──────────────────────────────────────────────────────────┘   │
 └──────────────────────────────────────────────────────────────────┘
        │                                    ▲
        │ 独立可并行任务 → 子代理（便宜模型）  │ 心跳 15 分钟 / Goal 续轮
        ▼                                    │
 ┌──────────────────────────┐        ┌───────┴──────────────┐
 │ 收尾：写简报 → 删心跳     │        │ DSH 引擎（schedule）  │
 │       → 删运行登记表      │        └───────┬──────────────┘
 └──────────────────────────┘                │ 进程死了？
                                             ▼
                              ┌──────────────────────────────┐
                              │ 看门狗（每 10 分钟，主机级）    │
                              │ 有活动夜班 + 进程不在 → 拉起   │
                              └──────────────────────────────┘
```

---

## 一、全景架构：四层 + 两条外部依赖

```mermaid
graph TB
    subgraph USER["你（人）"]
        U1["睡前：任务清单 + 预检单回答"]
        U2["晨间：读简报 + 抽查证据 + 看 diff"]
    end

    subgraph SKILL["skill 本体（纯 markdown，装一次）"]
        S1["SKILL.md 主流程/红线/运行期保障"]
        S2["references/habits.md 习惯决策树"]
        S3["references/verification.md 证据标准"]
        S4["references/templates.md 产出物模板"]
        S5["references/project-init.md 项目初始化"]
        S6["references/host-level.md 主机级设计"]
    end

    subgraph PROJ["项目级（每个项目一份）"]
        P1["项目 AGENTS.md 指针块"]
        P2["night-shift/ 状态目录"]
        P3["knowledge/ 原始层+派生层"]
    end

    subgraph HOST["主机级（每机一次，跨项目共用）"]
        H1["config.json（含 hostSetup）"]
        H2["runs/ 运行登记表"]
        H3["看门狗 + 计划任务"]
    end

    subgraph ENGINE["DSH 引擎（不可改，只能用）"]
        E1["schedule 心跳：15 分钟，重启后补发+恢复冷会话"]
        E2["goal-round-driver：空闲自动续轮（重启后需人 resume）"]
        E3["审批 never / 默认 5 次重试 / 会话日志"]
    end

    U1 --> S1
    S1 --> P1
    S1 --> P2
    S1 --> P3
    S1 --> H2
    E1 --> S1
    E2 --> S1
    H3 -->|进程不在时拉起| E1
    U2 --> P2
```

**分层职责（关键：别混层）**

| 层 | 内容 | 装几次 | 谁维护 |
|---|---|---|---|
| **skill 本体** | `SKILL.md` + `references/*.md`（纯 markdown） | 一次（复制到 `~/.dsh/skills/`） | 你/我，改仓库后复制 |
| **项目级** | 项目 `AGENTS.md` 指针块、`night-shift/` 状态、`knowledge/` | 每项目一次（skill 自动做） | skill 运行时自动写 |
| **主机级** | `config.json`、`runs/`、看门狗 + 计划任务 | 每机一次（手动装） | 你批准后执行脚本 |
| **引擎** | 心跳、Goal 续轮、审批、重试、会话日志 | 不装（DSH 自带） | DSH |

**两条外部依赖（缺了会怎样）**

| 依赖 | 缺了会怎样 | 替代 |
|---|---|---|
| `schedule`（心跳） | 崩溃重启后没人叫醒会话 → 停到早上 | 无（这是唯一的自动续跑机制） |
| 看门狗（计划任务） | DSH 进程崩了不会自己回来 | 你手动打开 DSH，心跳会自动接上 |

---

## 二、一夜的完整时序

```mermaid
sequenceDiagram
    autonumber
    participant U as 你
    participant A as 主循环(贵模型)
    participant G as Goal 驱动
    participant H as 心跳(schedule)
    participant W as 看门狗
    participant F as 文件系统

    U->>A: "按 night-shift 挂机，完成 BUG-BOARD"
    A->>F: 项目初始化（注入指针块，幂等）
    A->>F: 写 preflights/<日期>.md
    A->>U: 一次性问完预检问题
    U-->>A: 回答（可只回"都按你建议的"）
    A->>G: 挂 Goal（max_goal_rounds）
    A->>H: schedule_create(15 分钟心跳)
    A->>F: 写 runs/<sessionId>.json + HEARTBEAT.md
    loop 每个任务
        A->>F: 调研（通用层→项目 knowledge→外部，限 10 分钟）
        A->>A: 实现（串行修复留主循环）
        opt 独立可并行
            A->>A: spawn 子代理（便宜模型，可选）
        end
        A->>F: 验证 → 证据存 evidence/<日期>/
        A->>F: commit（一任务一提交，不 push）
        A->>F: 写 summaries/ + DECISIONS.md
    end
    A->>F: 写 briefs/<日期>.md（含运行完整性）
    A->>H: 删除心跳
    A->>F: 删除 runs/<sessionId>.json
    Note over W: 全程每 10 分钟检查：<br/>有活动 run 且 DSH 不在 → 拉起
```

---

## 三、单任务闭环（为什么"证据"是唯一裁判）

```mermaid
flowchart TD
    T["任务开始"] --> R["调研<br/>① 通用层 ② 项目 knowledge ③ 外部<br/>限 ~10 分钟"]
    R --> Q{"有现成方案？"}
    Q -- 有 --> I["实现/接入"]
    Q -- 无/超时 --> I2["按最合理假设实现<br/>记『查过 X 无』"]
    I --> V["跑验收命令"]
    I2 --> V
    V --> C{"证据绿？"}
    C -- 否 --> FIX["修复（留在主循环，不委派）"]
    FIX --> V
    C -- 是 --> E["证据落盘<br/>night-shift/evidence/&lt;日期&gt;/"]
    E --> CM["commit（一任务一提交）"]
    CM --> S["写总结五件套"]
    S --> N["下一个任务 / 收尾"]
```

**红线（任何情况下不越）**：`git push`、C 级禁区、**修复类任务装新依赖**。

---

## 四、崩溃恢复链路（这是"无人值守"的真正含义）

```mermaid
flowchart TD
    START["夜班运行中"] --> CRASH{"发生什么？"}
    CRASH -- "进程崩溃/被杀" --> W1["看门狗 10 分钟内发现<br/>进程不在"]
    W1 --> W2["Start-Process 拉起 DSH"]
    W2 --> H1["心跳到期（≤15 分钟）<br/>宿主恢复冷会话"]
    H1 --> R1["agent 收到『夜班心跳』<br/>读状态接着跑"]

    CRASH -- "模型重试耗尽(5次)" --> R2["该轮失败，会话空闲"]
    R2 --> H2["下一轮心跳继续<br/>（不重启进程）"]
    H2 --> R3{"连续≥3轮同类失败？"}
    R3 -- 是 --> B1["判环境不可用<br/>删心跳 + 标 blocked + 写简报"]
    R3 -- 否 --> R1

    CRASH -- "进程卡死" --> S1["默认不处理（v1 只判进程存在）<br/>可选 enableStallCheck"]
    S1 --> S2["开启后：会话日志 40 分钟无写入<br/>→ 强杀 + 重启"]
```

**为什么不用 Goal 续轮兜底**：`goal-round-driver` 在会话 resume/fork 后**保持停用**，必须人明确授权 resume——引擎不会自己复活工作。所以崩溃恢复靠"心跳"这条独立驱动源，不依赖 Goal。

**为什么"卡死判定"默认关闭**：存活信号只能用引擎写的（会话日志 mtime）。任务时长不能当阈值——跑 1 小时的长任务期间模型在忙，用"多久没动静"判死会误杀。

---

## 五、依赖决策树（修复类红线 vs 功能类豁免）

```mermaid
flowchart TD
    A["任务要装新依赖"] --> B{"任务性质？"}
    B -- "修 bug / 重构 / 性能" --> C["红线：禁止<br/>→ blocked + 简报『待定性』"]
    C --> C2{"用户预检时明确同意<br/>重新定性为功能？"}
    C2 -- 否 --> C3["等白天裁定"]
    C2 -- 是 --> D
    B -- "新增功能" --> D{"四条件同时满足？"}
    D -- "① 有出处（调研记录/预授权）" --> D2{"② 精确锁版本"}
    D2 -- 是 --> D3{"③ 卫生（默认源/防拼写/禁force）"}
    D3 -- 是 --> D4{"④ 可回滚（单独 chore(deps) commit）"}
    D4 -- 是 --> OK["自主安装 → 验证 → 简报单列依赖变更"]
    D -- 否 --> NO["不装 → blocked + 简报说明缺什么"]
    D2 -- 否 --> NO
    D3 -- 否 --> NO
    D4 -- 否 --> NO
```

---

## 六、知识沉淀流向（原始层是唯一事实源）

```mermaid
flowchart LR
    subgraph RAW["原始层（append-only，永不删改）"]
        R1["knowledge/summaries/"]
        R2["knowledge/pitfalls/"]
        R3["knowledge/research/"]
        R4["night-shift/summaries/"]
        R5["night-shift/briefs/ · preflights/ · evidence/"]
        R6["DECISIONS.md · ESCALATION.md（单文件，不迁移）"]
    end

    subgraph DER["派生层（可编辑，带出处指针）"]
        D1["knowledge/patterns/"]
    end

    subgraph UNI["通用层（跨项目，月度提炼）"]
        U1["&lt;centralKnowledge&gt;/<br/>过准入门槛 + 带出处链"]
    end

    R1 -->|"月度提炼 pass"| D1
    R2 --> D1
    R3 --> D1
    R4 --> D1
    D1 -->|"≥2~3 次独立出现<br/>+ 根因一致<br/>+ 换项目成立<br/>+ 带出处"| U1
    R1 -.->|"每年整体归档<br/>archive/&lt;年&gt;/ + INDEX"| ARCH["归档（结构不变，索引保留）"]

    U1 -->|"新项目开工第 1 步"| NEW["新项目不从零开始"]
```

**准入门槛四条**：≥2~3 次独立出现（不同项目，或间隔 ≥7 天的不同任务）→ 根因确认一致 → 换个项目还成立 → 带出处链。
**退役不删除**：证伪条目 `refuted + 日期 + 证据指针`，原件永远在。

---

## 七、文件地图

```
仓库（`<skill-repo>/night-shift/`）                      ← 唯一维护点
├── SKILL.md               agent 主手册
├── README.md              人用手册
├── DESIGN.md              本文（设计说明）
├── references/
│   ├── habits.md          习惯决策树（自由区/禁区/默认表）
│   ├── verification.md    证据标准与失败处置
│   ├── templates.md       预检单/总结/决策日志/简报模板
│   ├── project-init.md    项目初始化（指针块 + 三层结构）
│   └── host-level.md      主机级（登记表/看门狗/OS 差异）
└── scripts/               可选主机脚本（不被 skill 加载）
    ├── windows/{setup.ps1, watchdog-launch.vbs, watchdog.ps1}
    └── macos/{setup.sh, watchdog.sh}

安装副本（~\.dsh\skills\night-shift\）                       ← DSH 实际加载
（与仓库逐文件一致；改仓库后重新复制）

主机级（~\.dsh\night-shift\）                                ← 跨项目共用
├── config.json            centralKnowledge / dshExecutable / 心跳与阈值 / hostSetup
├── runs/<sessionId>.json  运行登记表（夜班进行中才有）
├── watchdog.log           只在状态变化时写
└── scripts/               主机副本（计划任务 → watchdog-launch.vbs → watchdog.ps1）

项目级（各项目工作区）                                        ← 每项目一份
├── AGENTS.md              + 指针块（类型/集中层路径/规则正文指针/项目差量）
├── knowledge/
│   ├── summaries/ pitfalls/ research/   ← 原始层
│   ├── patterns/                        ← 派生层（提炼 pass 写）
│   └── archive/<年>/                    ← 年度归档
└── night-shift/
    ├── preflights/<日期>.md
    ├── briefs/<日期>.md
    ├── DECISIONS.md
    ├── ESCALATION.md
    ├── HEARTBEAT.md
    ├── summaries/
    └── evidence/<日期>/
```

---

## 八、状态与幂等（为什么重启不需要重新初始化）

| 状态 | 标记 | 谁写 | 何时失效 |
|---|---|---|---|
| 项目已初始化 | 项目 AGENTS.md 里 `<!-- night-shift-knowledge:v0 项目类型=… -->` | skill | 类型判定变化时才重写 |
| 子代理模型已配 | `config.json` → `hostSetup.subagentModel.configured` | 你/脚本 | 换 preset 时 |
| 看门狗已装 | `config.json` → `hostSetup.watchdog.installed` | setup.ps1 | 卸载时 |
| 夜班进行中 | `runs/<sessionId>.json`（`startedAt` 18 小时内） | skill | 收尾删除 / 超 18h 视为陈旧 |
| 心跳在跑 | `HEARTBEAT.md` 记的提醒 id | skill | 收尾删除 |

**重启只做三件事**：启动进程 → 心跳到期恢复冷会话 → agent 读状态接着跑。**不写任何项目文件、不重新初始化。**

---

## 九、关键参数

| 参数 | 值 | 在哪改 | 为什么 |
|---|---|---|---|
| 心跳间隔 | 15 分钟（默认） | `config.json.heartbeatSeconds`（SKILL 建提醒时读） | 改小→恢复快但更贵；改大→相反 |
| 看门狗周期 | 10 分钟 | 计划任务 | 与心跳错开，崩溃后 10 分钟内发现 |
| 陈旧 run | 18 小时 | `config.json.staleHours` | 防收尾漏删导致白天反复重启 |
| 卡死阈值 | 40 分钟（默认关） | `config.json.stallMinutes` + `enableStallCheck` | ≈2×心跳 + 10 分钟余量；默认关避免误杀长任务 |
| 模型重试 | 5 次（默认） | profile `retryPolicy.maxRetries` | 不改全局 `always`；耗尽由心跳接管 |
| 调研时间盒 | ~10 分钟/任务 | project-init 模板 | 防止整晚卡在调研 |
| 子代理模型 | 由你的 preset 决定（选个便宜的） | 用户 preset `tool-subagent.agentOptions` | 默认继承父模型，必须显式配置才便宜 |
| 子代理输出上限 | 省略（= 模型默认） | preset `agentOptions.maxTokens` | 是**单次输出上限**，不是上下文窗口 |

---

## 十、常见误解

| 误解 | 实际 |
|---|---|
| "看门狗是常驻进程，一直在监控" | 不是。计划任务每 10 分钟启动它一次，检查完毫秒级退出 |
| "没有 RUNNING 文件所以不监控" | 用的是**运行登记表** `runs/*.json`，不是文件标记 |
| "开机自启 DSH" | 不做。不打开 DSH = 你不需要；看门狗只在"夜班进行中"才拉起 |
| "Goal 续轮能兜住崩溃" | 不能。重启后 Goal 续行停用，必须靠心跳 |
| "重启要重新初始化" | 不用。项目级靠标记、主机级靠 config，全幂等 |
| "子代理自动就便宜" | 不是。默认继承父模型，必须配 `agentOptions` |
| "重试无限更保险" | 不是。provider 级配置会拖累白天；且余额不足时无限重试无意义 |
| "原始层永不移动" | 已修订为"永不删除；允许按年整体归档迁移" |
| **"模型重试 5 次失败后夜班就停了"** | **不停**。单轮失败 → 会话空闲 → **Goal 驱动器自动开下一轮**继续尝试。三道刹车防整夜空转：`blockedAfterConsecutiveRounds=3`（连续 3 轮受阻必须标 blocked）、`max_goal_rounds`（耗尽记 `round-limit`）、心跳规则（连续 ≥3 轮同类失败 → 删心跳 + blocked + 简报） |
| "Goal 续轮和心跳是一回事" | 不是，是**两条独立驱动源**：Goal 续轮管"一轮干完接着下一轮"（同会话内）；心跳管"会话被冷启动/重启后重新叫醒"（跨进程）。Goal 重启后停用，心跳不会 |

---

## 十一、两条驱动源的分工（最容易被混淆的点）

```
正常一夜：
  Goal 驱动器 ──"一轮干完 → 自动下一轮"──▶ 主循环（同会话内，进程活着）

进程崩溃/重启后：
  Goal 驱动器 ✗（resume 后停用，需人授权）
  心跳 ──"15 分钟到点 → 恢复冷会话 → 投递『夜班心跳』"──▶ 主循环（跨进程）

模型重试耗尽：
  该轮报错结束 → 会话空闲 → Goal 驱动器自动开下一轮（同会话内继续）
  连续 ≥3 轮同类失败 → 心跳规则要求 agent 标 blocked + 删心跳 + 写简报（止损）
```

**为什么不能只留一条**：

- 只留 Goal：崩溃后没人叫醒（Goal 停用），夜班停到早上；
- 只留心跳：15 分钟才推一轮，任务推进太慢（Goal 是"干完立刻下一轮"）。

**为什么要设 `max_goal_rounds`**：它是最后一道机械保险——额度耗尽时引擎记 `round-limit` blocker 并停止续行，不依赖模型"自觉"踩刹车。建议值 20~40（够干完一批任务，又不至于整夜空转）。

**一个已知不确定点（如实记录）**：引擎文档说"只有进入模型历史的 goal Round 才消耗额度"。若某次 LLM 调用在重试耗尽后**没有进入模型历史**，理论上存在"驱动器反复起轮、每轮失败、额度不减"的窗口。缓解：`max_goal_rounds` 设保守值 + SKILL 要求连续 3 轮同类失败主动标 blocked + v1 不开卡死自动重启（避免重启循环）；首夜观察 token 统计与简报。
