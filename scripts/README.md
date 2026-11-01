# scripts/ — 可选主机级组件（不被 skill 加载）

> 这里的东西**不是 skill 指令**，skill 加载时不会读它们。它们是"崩溃恢复"这一主机能力的实现，装一次、跨项目共用。
> 完整设计见 [`references/host-level.md`](../references/host-level.md)。

## 目录

```
scripts/
├── windows/
│   ├── setup.ps1       # 一次性安装/卸载（幂等）：复制看门狗 + 写 config + 注册计划任务
│   ├── watchdog-launch.vbs  # 计划任务的入口（wscript 宿主）：无窗口启动 watchdog.ps1
│   └── watchdog.ps1    # 每 10 分钟跑一次：只在"有活动夜班且 DSH 不在"时拉起
└── macos/
    ├── setup.sh        # 同上（LaunchAgent，StartInterval 600）
    └── watchdog.sh     # 同上
```

## Windows 用法

> **需要管理员权限（UAC）**：注册/卸载计划任务要提权——在"以管理员身份运行"的终端里执行，或从普通终端用 `Start-Process pwsh -Verb RunAs` 拉起。

```powershell
# 先看会做什么（不改任何东西）
pwsh -NoProfile -File setup.ps1 -DryRun

# 安装（注册计划任务：每 10 分钟，经 wscript 启动器无窗口运行；不注册开机自启）
pwsh -NoProfile -File setup.ps1

# 如果自动探测不到 DSH 路径
pwsh -NoProfile -File setup.ps1 -DshExecutable "D:\...\DeepSeek Harness.exe"

# 卸载（移除计划任务，脚本与 config 留在磁盘）
pwsh -NoProfile -File setup.ps1 -Uninstall

# 手动跑一次看门狗（验证用）
pwsh -NoProfile -File "$env:USERPROFILE\.dsh\night-shift\scripts\watchdog.ps1" -DryRun
```

## macOS 用法（设计对齐，**未实测**）

```bash
bash setup.sh -n    # dry-run
bash setup.sh       # 安装 LaunchAgent（每 600 秒；RunAtLoad=false）
bash setup.sh -u    # 卸载
```

## 行为契约（两个平台一致）

1. `config.json` 不存在 → 直接退出（未安装，什么都不做）；
2. 单实例锁（防两次触发重叠）；
3. 扫 `runs/*.json`：`startedAt` 超过 `staleHours`（默认 18h）→ 清理并记日志；
4. **没有活动 run → 退出，绝不碰 DSH**（普通打开 DSH、不跑夜班时完全不受影响）；
5. 有活动 run 且 DSH 进程不在 → 启动 DSH；
6. `enableStallCheck=true` 时才做卡死判定：**只看引擎写的会话日志**（`session.jsonl.zstd` 最后写入时间），超过 `stallMinutes`（默认 40）→ 强杀 + 重启；
7. 日志只记状态变化（`watchdog.log`）。

## 注意

- **不做开机自启**（设计如此）：不打开 DSH = 当前不需要。
- **计划任务常驻 ≠ 开机自启**：前者每 10 分钟检查一次，无活动夜班立即退出。
- **任务入口必须是 `watchdog-launch.vbs`，不要直接指向 `pwsh.exe`**：控制台程序启动瞬间会闪一个黑窗（`-WindowStyle Hidden` 只是"建完再藏"），每 10 分钟一次会打断正常使用；`wscript.exe` 是 GUI 子系统宿主，整条链路不创建控制台。若机器上 WSH 被禁用/移除，任务会失败且不闪窗——`watchdog.log` 里会留 `launcher: ...` 记录，`setup.ps1` 也会在注册前直接报错。
- **本机统一用 PowerShell 7（`pwsh`），不用 5.1（`powershell.exe`）**（全局 AGENTS.md §9）：脚本 `#Requires -Version 7.0`，`setup.ps1` 找不到 `pwsh` 会直接报错而不是退回 5.1；计划任务也用 `pwsh` 运行。
- 脚本内容为 ASCII，`config.json` 以 **UTF-8 无 BOM** 读写（仍显式指定编码，防止将来有人用 5.1 跑出乱码）。
- 改脚本的正确方式：改仓库 → 重跑 `setup`（覆盖主机副本），不要直接改 `~/.dsh/night-shift/scripts/` 里的副本。
- **改 night-shift 的唯一入口是私有库仓库**：`SKILL.md`、`references/`、`scripts/`、文档一律先在 `firstsaofanskills/night-shift/` 里改，改完再同步覆盖出去；**安装副本（`~/.dsh/skills/night-shift/`）只能由「仓库 → 安装副本」的同步覆盖，不要手改**——手改会被下次同步冲掉，而且两份一旦漂移，DSH 实际加载的就是旧版本（2026-11-01 实测踩过：安装副本的 `SKILL.md` 正文比仓库旧一行）。同步命令（私有库维护者工具，`_tools/` 不随本 skill 分发）：`pwsh -NoProfile -File _tools/sync-night-shift-install.ps1`（加 `-DryRun` 先预演）；公开库一侧用 `_tools/sync-night-shift-public.ps1`。
