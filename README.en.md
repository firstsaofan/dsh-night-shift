# night-shift — unattended automation pipeline (pure skill)

> **The name is historical.** It applies whenever **the human is away from the device** — night, commute, meetings, lunch. The only criterion: the agent can keep making progress without you.
>
> 中文版（主文档）：[`README.md`](README.md) · 设计说明：[`DESIGN.md`](DESIGN.md)（中文）
> **Not on DSH?** See [`PORTING.md`](PORTING.md) — the skill is **bound to DSH's automation layer** (heartbeat / goal rounds / sub-agents / crash recovery); the rules layer is portable. It includes a per-capability porting checklist for Claude Code, Codex, and any CLI agent.

A DSH skill that makes an agent complete a task list while you are away: implement → verify (evidence-based) → decide by your habits → commit per task (never push) → write summaries → leave you a 5-minute morning brief.

---

## When it applies

Trigger phrases: "night shift", "run unattended", "keep working while I'm away", "finish the BUG-BOARD", or any statement that you are leaving the device.

If you are present, none of the "default decisions" apply — the agent asks as usual.

---

## Install

1. **Skill body** (once): copy this folder to `~/.dsh/skills/night-shift`. DSH hot-reloads it; no restart needed.
2. **Host-level watchdog** (optional, one per machine): `pwsh -NoProfile -File scripts/windows/setup.ps1` (Windows) or `bash scripts/macos/setup.sh` (macOS, untested). Registers a 10-minute scheduled check that starts DSH **only when a night-shift run is registered and the process is gone**. It does **not** register login auto-start.
3. **Sub-agent model** (optional): add `agentOptions` to `tool-subagent` in your user preset so sub-agents run on a cheap model:
   ```yaml
   modelSelectionSettings: true
   agentOptions:
     provider: <your provider id>
     model: <your cheapest model id>
     # maxTokens is optional: omit it to use the model's default output cap
     # (it caps a single reply, NOT the context window)
   ```

   `maxTokens` caps **one reply's output**, not the context window — the context window comes from the model definition and is usually hundreds of thousands to millions of tokens. Prefer omitting it; set it only when you deliberately want to limit output length. If unsure about a model's limit, have the agent look it up and confirm with you.
   Sub-agents inherit the parent model unless configured. Takes effect in **new sessions**.
4. **Retries**: keep the default (5). Do **not** set `retryPolicy: always` globally — it is provider-wide and would affect daytime sessions. Night-shift failures are absorbed by the heartbeat instead.

---

## How it works — four layers

| Layer | Contents | Installed | Owner |
|---|---|---|---|
| **Skill body** | `SKILL.md` + `references/*.md` (pure markdown) | once | repo → copied to `~/.dsh/skills` |
| **Project** | pointer block in project `AGENTS.md`, `night-shift/` state, `knowledge/` | once per project (automatic) | the skill at runtime |
| **Host** | `config.json`, `runs/` registry, watchdog + scheduled task | once per machine | you approve, scripts run |
| **Engine** | heartbeat (`schedule`), goal round driver, approvals, retries | built into DSH | DSH |

---

## One night, in short

```
you: "run night-shift on BUG-BOARD"
  → preflight questions (one shot; unanswered → habit defaults)
  → goal mounted (max_goal_rounds 20–40)
  → heartbeat reminder created (15 min) + run registered
  → per task: research → implement → verify with evidence → commit → summary
  → wrap up: brief written → heartbeat deleted → run entry deleted
```

---

## Failure recovery

| Situation | What happens |
|---|---|
| DSH process crashes | Watchdog (10 min) starts it; next heartbeat restores the cold session and delivers "night-shift heartbeat"; the agent reads state and continues |
| One model call fails | Retried 5 times with backoff |
| All retries exhausted | That round ends in error; the **goal driver** starts the next round automatically |
| 3 consecutive blocked rounds | `blockedAfterConsecutiveRounds=3` lets the model mark the goal blocked |
| Rounds exhausted | Engine records a `round-limit` blocker and stops |
| Model unavailable / out of credit | Skill rule: 3 consecutive same-error rounds → delete heartbeat, mark blocked, write brief (no all-night spin) |

**Two independent drivers** — do not confuse them:

- **Goal round driver**: same session, "one round done → next round". Disabled after session resume/fork until you explicitly resume.
- **Heartbeat**: cross-process wake-up. Restores a cold session after a crash and delivers a prompt.

---

## Knowledge layers

| Layer | Where | Rule |
|---|---|---|
| **Raw** | `knowledge/{summaries,pitfalls,research}/`, `night-shift/{summaries,briefs,preflights,evidence}` | append-only: never rewrite, never delete; yearly archive migration allowed |
| **Derived** | `knowledge/patterns/` | editable, must point back to raw sources |
| **Universal** | `<centralKnowledge>` (host config) | admission gate: ≥2–3 independent occurrences, same root cause, valid across projects, with provenance; retired entries are status-marked, never deleted |

---

## Key parameters

| Parameter | Value | Where |
|---|---|---|
| Heartbeat interval | 15 min (default) | `config.json.heartbeatSeconds` — the skill reads it when creating the reminder |
| Watchdog interval | 10 min | scheduled task |
| Stale run | 18 h | `config.json.staleHours` |
| Stall check | off by default (40 min) | `config.json.enableStallCheck` / `stallMinutes` (keep ≈ 2× heartbeat + 10 min) |
| Model retries | 5 (default) | profile `retryPolicy.maxRetries` |
| Research time box | ~10 min per task | project template |
| Goal rounds | 20–40 | `max_goal_rounds` at goal creation |

---

## Outputs

- `night-shift/preflights/<date>.md` — questions asked before starting
- `night-shift/briefs/<date>.md` — morning brief (includes a "run integrity" field)
- `night-shift/DECISIONS.md` — decision log (including habit rewrites)
- `night-shift/ESCALATION.md` — candidates for escalation
- `night-shift/summaries/` — one summary per task
- `night-shift/evidence/<date>/` — test output and screenshots
- `night-shift/HEARTBEAT.md` — heartbeat reminder id

---

## Hard limits

- The `schedule` heartbeat only exists in the **Web host (desktop GUI)**; headless profiles cannot mount it.
- Timers do not run while the machine sleeps — keep it awake (screen off is fine).
- The watchdog only acts while a night-shift run is registered; it never touches DSH otherwise.
- macOS scripts are design-aligned but **untested**.
- Heartbeat cost ≈ the whole session context per idle round, not the 100-token reminder text.

---

## Portability

This skill is **DSH-bound**, but only in its automation layer:

| Layer | Portable? | What to change on another agent |
|---|---|---|
| Rules (habits, verification, templates, dependency/git policy, knowledge layers) | ✅ copy as-is | nothing |
| Heartbeat (crash resume) | ❌ DSH-only | cron/scheduler + agent CLI; **new session each time**, rebuild context from `night-shift/` state |
| Goal rounds | ❌ DSH-only | external loop script, or manual "continue" |
| Sub-agents + model routing | 🟡 platform-specific | use the platform's sub-agent mechanism; drop the parallel section if none |
| Instruction injection (`AGENTS.md`) | 🟢 concept is common | rename to `CLAUDE.md` / keep `AGENTS.md` |
| Liveness signal | 🟡 different format | the platform's session log path |

Full checklist: [`PORTING.md`](PORTING.md) (Chinese).

---

## Files

```
night-shift/
├── SKILL.md              agent manual (loaded by DSH)
├── README.md             human manual (Chinese)
├── README.en.md          human manual (English, this file)
├── DESIGN.md             design notes: diagrams, flows, file map (Chinese)
├── PORTING.md            porting guide: what to change on another agent (Chinese)
├── references/           habits / verification / templates / project-init / host-level
└── scripts/              optional host scripts (not loaded by the skill)
    ├── windows/{setup.ps1, watchdog.ps1}
    └── macos/{setup.sh, watchdog.sh}
```
