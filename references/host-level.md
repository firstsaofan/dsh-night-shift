# 主机级单例：看门狗与跨项目运行登记表

> **设计目标与实测范围（2026-10-30 用户裁定）**：
> - **双系统只做设计层解耦**——脚本/路径/命令按 OS 分开写，保证接口可移植；**不承诺 macOS 实测**（用户只用 Windows）。
> - **不做开机自启**——用户自己打开 DSH；**不打开就说明当前不需要 DSH，任何东西都不得无条件拉起它**。
> - **看门狗用于崩溃恢复（要）**——只在"运行登记表有活动夜班 run **且** DSH 进程不在"时才拉起；运行登记表为空时检查完立即退出。**调度任务常驻 ≠ 开机自启**：它平时只是一次轻量检查。
>
> 为什么单独一层：**看门狗和运行登记表是跨项目的主机能力，不是项目能力**。DSH 只有一个进程，崩了所有项目的会话一起挂 → 看门狗必须**全局唯一**。

## 〇、产物归属（三类别混，先分清）

| 类别 | 产物 | 装几次 | 可执行代码 |
|---|---|---|---|
| **skill 本体** | `SKILL.md` + `references/*.md`（含本文件） | 一次（复制到 `~\.dsh\skills\`） | ❌ 纯 markdown 指令，不含脚本 |
| **项目初始化**（skill 首次进项目自动执行） | 项目 `AGENTS.md` 指针块 + `knowledge/` 骨架 + `night-shift/` 状态目录 | 每项目一次 | ❌ 零脚本 |
| **主机级安装**（用户批准后手动一次） | `config.json` + 看门狗脚本副本 + 一条计划任务 | **每机一次，跨项目共用** | ✅ 有脚本 |

**脚本从哪来、放哪**：源文件放在 skill 仓库的 `night-shift/scripts/`（跟 skill 一起版本管理，是唯一维护点）；`setup` 执行时**复制到** `$DSH_HOME/night-shift/scripts/`，计划任务调用的是**主机副本**——这样既单一真源（改仓库 → 重跑 setup 覆盖副本），又不依赖仓库目录位置。

> **界线**：仓库产物 = 指令（`SKILL.md`/`references/`）+ 可选脚本（`scripts/`，**不被 skill 加载**）；运行时产物 = **只有数据**（项目内 `night-shift/` 状态、`$DSH_HOME/night-shift/` 的 config/运行登记表/日志）。**运行时绝不生成可执行脚本**——脚本必须可 diff、可审查、可回滚，不能每台机器现写一份。

## 一、目录（全局唯一，不在任何项目里）

```
$DSH_HOME/night-shift/                 # Windows: ~\.dsh\night-shift\   macOS: ~/.dsh/night-shift/
├── config.json                        # centralKnowledge / dshExecutable / heartbeatSeconds / stallMinutes / staleHours
├── runs/<sessionId>.json              # 进行中的夜班，每个会话一条
├── watchdog.log                       # 只记状态变化，避免刷屏
├── watchdog.lock                      # 单例锁（防两次唤醒重叠）
└── scripts/
    ├── windows/setup.ps1              # 一次性安装（幂等）
    ├── windows/watchdog.ps1           # 每 10 分钟由任务计划程序调用
    ├── macos/setup.sh                 # 一次性安装（幂等）
    └── macos/watchdog.sh              # 由 launchd 每 600 秒调用
```

### config.json 字段表（每个字段都有人消费，别写"没人读"的值）

| 字段 | 默认 | 谁消费 | 改它要注意 |
|---|---|---|---|
| `version` | `1` | 脚本（保留，供未来 schema 判断） | — |
| `centralKnowledge` | `$DSH_HOME/night-shift/central-knowledge` | **skill**（项目初始化的指针块） | 改后已初始化项目的指针要重写 |
| `dshExecutable` | 自动探测 | **看门狗**（拉起进程） | 路径错 → 崩溃时拉不起来 |
| `dshProcessName` | `DeepSeek Harness` | **看门狗**（进程检测） | 应用改名后要同步 |
| `heartbeatSeconds` | `900`（15 分钟） | **skill**（建提醒时读，不写死） | 改小→恢复快但更贵；改大→相反 |
| `stallMinutes` | `40` | 看门狗（仅 `enableStallCheck=true`） | **应与心跳联动**：≈ 2×`heartbeatSeconds`/60 + 10 |
| `enableStallCheck` | `false` | 看门狗 | 开了才判卡死；长任务多的项目别开 |
| `staleHours` | `18` | 看门狗（清陈旧 run） | 夜班可能超 18 小时时才调大 |
| `hostSetup.subagentModel` | — | **skill**（初始化检查） | `maxTokens` 建议省略（用模型默认） |
| `hostSetup.watchdog` | — | skill（初始化检查）+ `setup` 脚本 | 安装/卸载时脚本自动改，别手改 |

> **不在 config.json 里的两个参数**：`max_goal_rounds`（建 goal 时给，建议 20~40）和 `blockedAfterConsecutiveRounds`（引擎配置，默认 3）。别把它们写进 config.json——没人读。

## 二、运行登记表协议（skill 侧，多项目并发的基础）

> **术语澄清**：这里的"运行登记表"指 `$DSH_HOME/night-shift/runs/` 目录下的 **JSON 文件清单**（每个进行中的夜班一条），**与 Windows 系统注册表（regedit）完全无关**——本方案不读写任何系统注册表项。

**开工**（进入夜班、建心跳后）写一条：

```json
{ "workspace": "<绝对路径，如 /home/me/projA 或 D:\\work\\projA>", "sessionId": "session-xxxx", "startedAt": "2026-10-30T23:00:00+08:00", "heartbeatId": "..." }
```

- 文件名用 `<sessionId>.json` → 多项目并发互不覆盖；
- **收尾必须删除自己的条目**（与心跳同生共死：删心跳 = 删 run = 删项目内标记）；
- `startedAt` 超过 `staleHours`（默认 18）→ 看门狗视为陈旧，忽略并在日志记一条（防收尾漏删导致白天反复重启）。

## 三、看门狗算法（每次唤醒执行，全程幂等）

1. **拿锁**（`watchdog.lock`）——拿不到说明上一轮未结束 → 退出（防重叠）。
2. **读 config**——不存在 → 未安装，退出。
3. **扫 `runs/`**——剔除陈旧条目；**为空 → 退出**（这就是"普通打开 DSH 不跑夜班，绝不会被动"的保证）。
4. **查 DSH 进程**：
   - 不在 → 启动（Windows `Start-Process <dshExecutable>`；macOS `open -a "DeepSeek Harness"`）；
   - 在 → 可选"停滞判定"：读该会话的 `session.jsonl.zstd` 最后写入时间，超过 `stallMinutes`（默认 40）→ 先优雅关闭，再强杀，再启动。
5. **写日志**：只在状态变化时写（崩溃拉起 / 停滞重启 / 清理陈旧），不刷屏。

**判定信号铁律**：存活只能用**引擎写的**会话日志 mtime（心跳每 15 分钟投递一次会产生写入）；**不能用模型写的文件，也不能用任务时长**——长任务（>1 小时）期间模型在忙，用模型写的信号判存活会把"忙"误判成"死"。

## 四、OS 差异（设计层解耦，macOS 未实测）

| 关注点 | Windows（本机，实际使用） | macOS（仅设计对齐，不实测） |
|---|---|---|
| 启动 DSH | `Start-Process "<安装目录>\DeepSeek Harness.exe"` | `open -a "DeepSeek Harness"` |
| 进程检测 | `Get-Process -Name "DeepSeek Harness"` | `pgrep -f "DeepSeek Harness"` |
| 定时调度 | 任务计划程序：`schtasks /sc minute /mo 10` | `~/Library/LaunchAgents/<label>.plist`，`StartInterval 600` |
| 会话日志 | `$DSH_HOME\sessions\--<编码工作区>--\session-<uuid>\session.jsonl.zstd` | `~/.dsh/sessions/--<编码工作区>--/session-<uuid>/session.jsonl.zstd` |
| 脚本语言 | PowerShell | bash / zsh |
| 强杀 | `Stop-Process -Force` | `kill -9` |

> 不做开机自启（任何 OS）：用户自己启动 DSH。上表只覆盖"看门狗拉起进程"所需的最小差异。

## 五、安装（一次性、幂等）

**装什么、不装什么**：

| 组件 | 要不要 | 作用 | 依赖 |
|---|---|---|---|
| **看门狗 + 一条调度任务** | ✅ **要**（崩溃恢复） | 每 10 分钟检查：运行登记表有活动夜班 且 DSH 不在 → 拉起；运行登记表为空 → 直接退出 | 一条计划任务（Win）/ LaunchAgent（Mac） |
| **开机自启** | ❌ **不要** | 登录时无条件启动 DSH——不打开=不需要，禁止无条件拉起 | — |

**安装**（只装看门狗，不装自启）：

- **Windows**：`powershell -ExecutionPolicy Bypass -File scripts/windows/setup.ps1` → 写 config + 注册任务计划（每 10 分钟）；**不注册开机自启**；
- **macOS**：`bash scripts/macos/setup.sh` → 写 config + 写 LaunchAgent（`StartInterval 600`）；**不设 RunAtLoad**；
- **幂等**：已存在则更新，不重复注册；`--uninstall` 卸载；
- **重启/杀进程不需要重新初始化**：看门狗只启动进程，不写任何项目文件；skill 靠标记跳过已完成的初始化。

> 未安装看门狗时的降级：崩溃后你手动打开 DSH，心跳提醒会自动恢复冷会话并续跑（不需发指令、不需重新初始化）——只是失去"自动拉起"这一层。

## 六、与项目初始化的边界（重要）

| 事项 | 归属 | 谁做 |
|---|---|---|
| 项目 AGENTS.md 注入知识沉淀规则 | 项目级 | skill 首次进项目（`project-init.md`） |
| `knowledge/` 骨架 | 项目级 | 同上 |
| `night-shift/` 状态目录（preflights/briefs/DECISIONS…） | 项目级 | 同上 |
| 看门狗 / 调度 / 运行登记表 / config | **主机级** | **一次性安装脚本**（本文件） |
| 子代理模型路由（`agentOptions`） | **主机级配置** | 一次性改用户 preset（见下 §八） |
| 集中通用层路径 | 主机级配置 | `config.json` 的 `centralKnowledge` |

**项目初始化只检查、不安装**：读 `config.json`（不存在 → 提示"主机级未安装"）并检查其中的 `hostSetup` 块——已配项（如 `hostSetup.subagentModel.configured=true`、`hostSetup.watchdog.installed=true`）直接跳过，不再询问用户。

## 八、hostSetup 记录（替代"全局 AGENTS.md 标签"）

**结论：不在全局 AGENTS.md 里加标记。** 原因：

1. 全局 AGENTS.md 会进入**每个会话的上下文**，永久占用 token；而"装没装"属于机器状态，应该机器可读；
2. 这些配置本来就是**主机级一次安装、全局生效**——不是每项目初始化的事，加标签没有"跳过"的对象；
3. 两处记录必然漂移（改了 preset 忘了改标签）。

**做法**：状态写进 `$DSH_HOME/night-shift/config.json` 的 `hostSetup` 块，skill 初始化时读一次即知：

```json
"hostSetup": {
  "subagentModel": { "configured": true, "provider": "<provider>", "model": "<cheap-model>", "where": "~/.dsh/.agent-presets/<preset>/agent.cordis.yml -> tool-subagent.agentOptions" },
  "watchdog": { "installed": false }
}
```

- 改 preset 后同步改 `config.json`（同一个动作里的两步，脚本化后可自动做）；
- 项目初始化读 `hostSetup`：已配 → 跳过询问；未配 → 预检单提示并给命令。

## 九、可移植性约定

- skill 与项目模板里**不写死绝对路径**：集中通用层统一写成 `<centralKnowledge>`，由 `config.json` 提供；项目路径一律相对工作区。
- 模板里的命令**按 OS 分支给两条**（Windows / macOS），不假设平台。
