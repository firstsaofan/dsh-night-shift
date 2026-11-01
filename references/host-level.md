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
    ├── windows/watchdog-launch.vbs    # 任务入口：wscript 宿主，无窗口拉起 watchdog.ps1
    ├── windows/watchdog.ps1           # 每 10 分钟由任务计划程序（经启动器）调用
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
| `heartbeatSeconds` | `900`（15 分钟） | **skill**（建提醒时读，不写死） | 改小→恢复快但更贵；改大→相反。**建提醒的时序参数必须是 `every_seconds`（周期），不是 `after_seconds`（一次性）**——一次性到点若会话忙则永久错过，2026-11-01 实测两次翻车 |
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
{ "workspace": "<工作区绝对路径>", "sessionId": "session-xxxx", "startedAt": "2026-10-30T23:00:00+08:00", "heartbeatId": "..." }
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

- **Windows**：`pwsh -NoProfile -File scripts/windows/setup.ps1` → 写 config + 注册任务计划（每 10 分钟，经 `watchdog-launch.vbs` 由 `wscript.exe` 无窗口启动）；**不注册开机自启**；
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

## 十、子代理路由：两个真实踩过的坑（2026-11-01）

子代理路由由 `tool-subagent.config.agentOptions` 决定（`provider` + `model`）。这条链上有两个地方会静默失效——**症状都是"子代理报告自己是父代理的模型"**，没有任何报错。

### 坑 1：`provider` 拼写必须与 profile 里的 id 逐字符一致

`agentOptions.provider` 的值必须是 desktop profile `llm-pi-ai.providers` 下**真实存在的键名**。DSH 不存在的 provider **不会报错**，子代理直接退回父代理路由。

```yaml
# ✗ provider: <旧的自定义 provider 名>（profile 里已无此 id）
# ✓ provider: <profile 里真实存在的 provider id>
```

profile 里的 provider 键名是 DSH 升级 + 用户改名共同决定的，**不要靠记忆或旧文档**；改前先查：

```powershell
Select-String -Path "$env:USERPROFILE\.dsh\profiles\desktop\cordis.patch.yml" -Pattern '^\s{6}[a-z0-9\-]+:$' | ForEach-Object { $_.Line.Trim().TrimEnd(':') }
```

### 坑 2：`agentOptions` 必须写在会话实际使用的 preset 里

DSH 的 preset 是**按 `agentPreset` 字段选的**，而新会话默认可能用内置 `standard`（不是你自定义的 preset）。在自定义 preset 里写 `agentOptions`，对 `standard` 会话完全不生效。

查当前会话用了哪个 preset（会话日志首行）：

```powershell
# 取最新会话日志首行（含 agentPreset 字段）
$f = Get-ChildItem "$env:USERPROFILE\.dsh\sessions" -Recurse -Filter 'session.v4.jsonl.zstd' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
# 或直接看最近会话的首行
```

若确认是 `standard`，**覆盖内置预设声明**（在 profile patch 末尾加 `- id: preset-standard` 块，`config` 需完整重述——这是 DSH 的 Loader 行 id 覆盖机制）：

```yaml
# ~/.dsh/profiles/desktop/cordis.patch.yml 末尾追加
# 原因：standard 的 tool-subagent 没有 agentOptions，子代理只能继承父代理模型
# 来源：dsh-web-app/presets/standard.patch.yml（app.asar）→ DSH 升级内置预设后需重新生成
- id: preset-standard
  config:
    id: standard
    order: 1
    plugins:
      # …（完整重述内置 standard 的 22 个 plugins）…
      # 其中 tool-subagent 行加：
      - id: tool-subagent
        name: '@deepseek-ai/dsh-tool-subagent'
        config:
          provider: spawn
          toolName: subagent
          modelSelectionSettings: true
          agentOptions:
            provider: <profile 里真实存在的 provider id>
            model: <最便宜的 model id>
```

> ⚠️ profile patch 里的 `config` 是**完整替换**（不是合并），重述时要带上 `id`、`order`、全部 `plugins`。改完整份 patch 解析 OK、`tool-subagent.config.agentOptions` 存在后才算成功。

### 验证子代理路由（唯一可信方法）

`config.json` 里的 `hostSetup.subagentModel` **只是记录**，不决定行为；真正生效的是 preset / profile patch。验证必须**真派一个子代理**，问它自己的模型标识——子代理的系统提示里 `powered by ... model` 那句是 DSH 按**实际路由**生成的，可信。

**在要验证的会话里发送：**

```text
帮我做一个「子代理路由自检」。只做这几步，不要修改任何文件、不要提交、不要安装任何东西、不要派第二个子代理：

1. 调用 subagent 工具派一个子代理，它的 prompt 用这一段（原样）：
   不要调用任何工具、不要读取任何文件。用一句话回答两件事：
   ① 你系统提示开头 "powered by … model" 那句的原文是什么？
   ② 你能看到的模型标识是什么？

2. 等它返回，把它的话原样贴出来，不要改写、不要总结。

3. 按下面规则给出结论行：
   - 子代理报告的模型标识含 <期望的便宜 model id> → RESULT: PASS
   - 报告的是 <父代理模型 id> 或其它值 → RESULT: FAIL
   - subagent 工具本身报错 → 原样贴出错误信息，打印 RESULT: ERROR

最后只回：子代理原话 / RESULT 行。
```

判读：

| RESULT | 含义 | 处理 |
|---|---|---|
| `PASS` | agentOptions 生效 | 收工 |
| `FAIL` | 坑 1 或坑 2 → 查 provider 拼写 + 当前会话 preset | 见上方 §十 |
| `ERROR` | 路由预检失败 | 错误信息通常点名 provider，贴回排查 |

> **改 profile patch 后必须完全退出 DSH 再重开**（preset 声明在启动时加载，不热更新）。旧会话不受影响，只有新会话生效。

## 十一、安装后验证清单（给 Agent 直接抄作业）

> 新用户装完 night-shift 后，按下面 **两道自检** 逐条跑。每条都是"粘进新会话就能执行"的完整 prompt，Agent 照抄即可，无需再解释。

### 自检 A：子代理路由是否真生效（必做，1 分钟）

**为什么必须做**：`agentOptions` 配错（provider 拼写 / 写错 preset）**不会报错**，子代理会静默退回父代理模型，你以为配了便宜模型其实没配。唯一可信的验证是**真派一个子代理问它自己的模型标识**。

**操作**：新开一个会话，整段粘贴：

```text
帮我做一个「子代理路由自检」。只做这几步，不要修改任何文件、不要提交、不要安装任何东西、不要派第二个子代理：

1. 调用 subagent 工具派一个子代理，它的 prompt 用这一段（原样）：
   不要调用任何工具、不要读取任何文件。用一句话回答两件事：
   ① 你系统提示开头 "powered by … model" 那句的原文是什么？
   ② 你能看到的模型标识是什么？

2. 等它返回，把它的话原样贴出来，不要改写、不要总结。

3. 按下面规则给出结论行：
   - 子代理报告的模型标识 == 你在 agentOptions 里配的那个便宜模型 → RESULT: PASS
   - 报告的是父代理的模型或其它值 → RESULT: FAIL
   - subagent 工具本身报错 → 原样贴出错误信息，打印 RESULT: ERROR

最后只回：子代理原话 / RESULT 行。
```

判读与处理见 §十。`FAIL` 时按 §十 的两个坑逐条查（provider 拼写 → 当前会话 preset）。

### 自检 B：skill 主链路是否可用（必做，约 10 分钟）

**为什么必须做**：skill 的价值在"我走了它自己跑"。所以必须实测**挂机门禁 → 杀进程 → 看门狗拉起 → 心跳续跑 → 任务完成 → 自清**这条完整链路，而不是只看它能读文件。

**前置**：随便准备一个 5–10 分钟能做完的小任务（例：在工作区 `.tmp\smoke\` 写一个含 3 段文字的 `index.html`）。任务清单**写进文件**（不要粘进对话），例：

```markdown
# 冒烟任务
- [ ] 1. 生成 .tmp\smoke\index.html：单文件、无外部依赖、内联样式，含 3 段说明文字
- [ ] 2. 用 pwsh 统计文件大小并写进 night-shift/summaries 的任务总结
- [ ] 3. 在文件里把两条任务标 ✅ 并附总结链接
```

**操作**：新开会话，粘这一段（把路径换成你的）：

```text
按 night-shift skill 进入无人值守夜班模式，完成 <你的工作区>/.tmp/smoke-plan.md 里的全部任务。
清单就在那个文件里。我现在离开设备，不会回答任何问题；拿不准按 skill 的习惯默认处置并记 DECISIONS.md。
做完输出 === DONE === 加产物路径与文件大小。
```

**测试前先调短两个间隔（强烈建议，否则一次测试要等十几分钟）**——真机跑之前，让 agent 或你自己把间隔临时改成：**看门狗 3 分钟、心跳 1 分钟（60 秒）**。

```powershell
# 看门狗：3 分钟（提权，改计划任务触发器；setup.ps1 默认 10 分钟）
pwsh -NoProfile -Command "`$t=Get-ScheduledTask -TaskName 'DSH Night Watchdog'; `$a=$t.Actions; `$tr=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 3); `$s=Get-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew; Set-ScheduledTask -TaskName 'DSH Night Watchdog' -Action `$a -Trigger `$tr -Settings `$s"

# 心跳：900 → 60 秒（写主机级 config.json；skill 建心跳时读它）
(Get-Content "$env:USERPROFILE\.dsh\night-shift\config.json" -Raw) -replace '"heartbeatSeconds": \d+', '"heartbeatSeconds": 60' | Set-Content "$env:USERPROFILE\.dsh\night-shift\config.json" -Encoding utf8
```

> **测完必须改回**：看门狗 10 分钟、心跳 900 秒（真实夜班用大值，间隔太小会烧 token，见 §十二）。改回就是同样两条命令把 `-Minutes 3` 换回 `-Minutes 10`、`60` 换回 `900`。
> **不要直接跑 `setup.ps1` 来"改回"**：它会把看门狗重置成 10 分钟（这是对的），但它同时覆盖主机副本脚本——如果你改了本地脚本，会被冲掉。

然后**按门禁信号操作**（门禁是**三重信号**，任一缺失都算没执行）：

1. **看聊天窗口**：应弹出一张 `present` 卡片 + 正文里出现 `✅ NIGHT-SHIFT READY TO LEAVE` 块。这是你"可以走"的**可视信号**；
2. **看磁盘**：`night-shift/GATE.md` 存在且内容就是门禁块——这是**硬留证**；
3. 核对块里 `heartbeat: every_seconds=…` 与 `~/.dsh/night-shift/runs/` 出现**本会话**的 JSON；
4. 在它干活途中杀 DSH：`Stop-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue`
5. 等**看门狗间隔**（测试建议 3 分钟），确认 `~/.dsh/night-shift/watchdog.log` 出现新的 `starting` 行；
6. DSH 自动弹回后打开该会话，确认它自己接着干完（轮到 `=== DONE ===`）。

**判读**：

| 现象 | 结论 |
|---|---|
| 聊天里有门禁卡片/正文块 **且** `night-shift/GATE.md` 存在 **且** 看门狗拉起、任务续完、收尾删心跳/run + 调了 sweep | ✅ PASS |
| 聊天里什么都没有，但 `GATE.md` 存在 | 门禁"做了但没让你看见" → 顺手把 `GATE.md` 给用户看即可，不影响挂机 |
| **没有 `night-shift/GATE.md`**（哪怕任务做完了） | **门禁没执行** → 模型跳过了 §0.8。先查安装副本是否最新；若最新仍跳过，说明 prompt/模型轨迹过于工具化，需要换更强的约束 |
| 有 `GATE.md` 但任务做完后仍反复被唤醒 | 装了插件却没调 `sweep_schedule_inbox` → 见 §十二 |
| 看门狗没拉起 | 查计划任务 `DSH Night Watchdog` 是否存在、间隔、动作是否 wscript |
| 拉起后不续跑 | 查 `HEARTBEAT.md` 是否有 id、`schedule_list` 是否还在、`runs/` 是否还在 |
| 任务完成后仍被反复唤醒 | 装了插件却没调 `sweep_schedule_inbox` → 见 §十二（积压排空） |

### 自检 C：可选增强——装 `dsh-plugin-schedule-sweep` 消除积压（可选）

见 §十二。**不装也能用**，只是任务完成前堆积的心跳会在完成后空转几轮。

插件开源地址：<https://github.com/firstsaofan/dsh-plugin-schedule-sweep>

安装（装完**重启 DSH** 生效，装载进 desktop profile 的 bundles）：

```powershell
# 从 Git 仓库直接装（推荐，仓库内已带构建产物，无需本地 build）：
dsh plugin --profile desktop add https://github.com/firstsaofan/dsh-plugin-schedule-sweep
# 若从本地源码目录安装（路径换成你自己的插件目录）：
# dsh plugin --profile desktop add <你的插件本地路径>
```

然后把 `dsh-plugin-schedule-sweep` 加进 `$DSH_HOME\profiles\desktop\package.json` 的
`dsh.profile.bundles` 数组（`dsh plugin add` 只装依赖，`bundles` 决定它是否被加载）。

#### 插件装好没装好，怎么验（两级）

**第一级：确认工具在（30 秒）** —— 重启 DSH 后新开会话，让 agent 调用：

```text
调用 sweep_schedule_inbox，dry_run=true，把结果原样贴出来
```

- 返回类似 `{removed: 0, remaining: 0, scannedKinds: ["schedule"]}` → 工具在，✅ 装好了。
- agent 说"没有这个工具" → 没加载成功（查：是否重启 DSH、`bundles` 是否加了）。
- 报 `tool "sweep_schedule_inbox" is already registered` → 同一 composition 装了两份（查 `bundles` 是否重复）。

**第二级：确认真的能删（约 5 分钟，可选但推荐）** —— `dry_run` 只证明"能读不写"，
真删路径要制造积压才能验：

1. 建一个 `every_seconds=60` 的心跳，让它忙几分钟（跑个小任务），收件箱会堆几条；
2. 调 `sweep_schedule_inbox`（不带 dry_run），看返回 `removed > 0`；
3. 再调一次确认 `remaining` 归零，且之后不再有新的空转轮。

> 本机实测（2026-11-01）：sweep 后 3 条排队消息被 `agent/inbox/spliced {outcome: canceled}` 持久取消，
> 之后 0 条新 reminder、0 个新 turn —— 这就是"任务完成后不再空转"的效果。

## 十二、已知问题：任务完成前的心跳积压（有解，但需可选插件）

**现象**：任务完成、删掉心跳后，仍会连开若干轮空转（每轮约 10 秒、0 次工具调用）。

**根因（读源码确认）**：心跳每 N 秒把一条提醒 `followup()` 推进 **agent 收件箱**；模型忙时消息堆在收件箱，空闲后**每条各起一轮 turn**。`schedule_delete` 只删任务行（平台文档原话 `leaving queued messages intact`），**清不掉已进的收件箱**。

**影响量化**：积压轮数 ≈ 任务连续工作时长 ÷ 心跳间隔。60s + 2 小时 ≈ 120 轮；900s + 2 小时 ≈ 8 轮。

**缓解与间隔选择（分"装没装插件"两种）**：

| 是否装插件 | 推荐 `heartbeatSeconds` | 理由 |
|---|---|---|
| **已装 `dsh-plugin-schedule-sweep`** | **300 秒（5 分钟）** | 完成后积压由 `sweep_schedule_inbox` 一次性清空，间隔的价值回到"任务推进节奏"上；300s 让任务间隙最多等 5 分钟，又不会堆太多（6 小时 ≈ 72 条），内存/崩溃面可控。**推荐这个值**。 |
| **没装插件** | **900 秒（15 分钟，skill 默认）** | 没有 sweep 兜底，完成后的空转只能靠"间隔大"来压。此时小间隔会让完成后空转成倍增加（60s + 2 小时 ≈ 120 轮空转烧 token）。**所以没装插件就用默认 900s，并强烈建议装插件。** |

> 一句话：**装了插件 → 300s；没装插件 → 900s（并建议去装插件）。** 不要用 60s 跑真实夜班（除非在测试）。

**其他缓解手段（两种都要做）**：
1. 排空轮已写死"不读文件、不调工具，只回一行"（成本 = 一次历史 input，不是任务本身）；
2. 任务完成即删心跳（停掉后续触发）。

**根治（插件）**：装 [`dsh-plugin-schedule-sweep`](https://github.com/firstsaofan/dsh-plugin-schedule-sweep) 后，skill 收尾时**必须调用** `sweep_schedule_inbox`（SKILL §0.5 已写成硬要求：工具在列表里就必须调），把收件箱里 `source.kind==='schedule'` 的待处理消息全部删掉——**只删心跳消息，不动用户真消息**。不装则跳过这一步（工具不在列表里，自然不调）。

收尾完整顺序（四步，不可颠倒）：

```text
1. 任务全 ✅ → 写 brief / summary / DECISIONS
2. 在 HEARTBEAT.md 历史区追加一行删除记录
3. schedule_delete(<心跳 id>)
4. sweep_schedule_inbox()   ← 工具在列表里就必须调；不在就跳过
```

> 2026-11-01 实测：插件装好了，但模型从没主动调过（文档当时写的是"可选"）→ 残留心跳继续空转。所以 SKILL §0.5 已把这一步改成"**有工具就必调**"，不再依赖模型自觉。
