# PRD: Commandr v0.5 — Local Agent Control Tower

## Problem Statement

Running multiple Claude Code agents locally creates coordination drift. Work gets spread across shell sessions, worktrees, prompts, and partial diffs. The developer has no single flight board showing what is queued, in flight, or landed. Agents can accidentally duplicate work, lose task context, or finish without leaving a durable trail of what changed. Commits also lack a reliable human airlock, so an agent can land changes before the developer has reviewed the diff in context.

Commandr v0.5 solves the first local version of this problem: one machine, no external services, durable task state, atomic claiming, visible progress, append-only event history, and a human approval gate before agent commits.

## Solution

Commandr v0.5 is a filesystem-native control tower for local agent work. It adds a committed `.agents/` control plane to each project repo, plus small shell scripts and global skills that let agents claim, complete, report, and request approval.

The task lifecycle is intentionally simple:

```text
inbox -> claimed -> done
```

The local system uses POSIX `mv` for single-machine atomic claiming. Each task is a self-contained mission packet in Markdown with YAML frontmatter and enough context for a fresh agent session. Agents move mission packets from `.agents/inbox/` to `.agents/claimed/`, append lifecycle events to `.agents/events.jsonl`, and move completed work to `.agents/done/`. The developer can inspect the current state through `/kanban-status` and approve commits through an approval workflow that writes `.agents/approvals/<task>.approved`.

v0.5 does not try to solve multi-machine coordination, hosted observability, dependency scheduling, or council review. It creates the minimum reliable local loop that later versions can extend.

## Product Vocabulary

- **Control tower**: Commandr itself; the local coordination layer for agent work.
- **Mission packet**: A task file containing context, acceptance criteria, allowed files, and forbidden files.
- **Runway**: `.agents/inbox/`; tasks ready for an agent to claim.
- **In flight**: `.agents/claimed/`; tasks currently owned by an agent.
- **Landing**: Completion path from claimed task to `.agents/done/`.
- **Black box**: `.agents/events.jsonl`; append-only record of lifecycle events.
- **Airlock**: Approval workflow before an agent commit.
- **Flight board**: `/kanban-status`; terminal view of inbox, claimed, and done tasks.

## Acceptance Criteria

The following checklist defines the done condition for v0.5. All items must pass before the implementation is considered complete.

- [ ] `.agents/{inbox,claimed,done,approvals}/` directories exist and are bootstrapped by the setup script.
- [ ] `scripts/claim.sh` runs, returns the correct stdout format, and claiming is atomic under concurrent callers.
- [ ] `scripts/complete.sh` runs, moves a claimed file to done, and returns correct exit codes.
- [ ] `events.jsonl` is appended on claim, complete, and session_end.
- [ ] Event log lines parse as valid JSON matching the defined schemas in the Data Format Contracts section.
- [ ] `/kanban-status` renders a three-column board from filesystem state with no registry dependency.
- [ ] Approval workflow writes a token on approval and skips token creation on denial.
- [ ] Commit hook blocks when the approval token for the current task is absent.
- [ ] Stop hook no-ops silently outside Commandr repos; appends `session_end` when `.agents/` is present.
- [ ] End-to-end scenario: a task travels inbox → claimed → done with an intact, parseable event log.

## User Stories

1. As a developer, I want one local directory that stores agent task state, so that task coordination survives terminal restarts.
2. As a developer, I want task state committed with the project, so that agent work coordination is auditable in git history.
3. As a developer, I want a clear inbox for unclaimed tasks, so that I can prepare work before spawning agents.
4. As a developer, I want a clear claimed lane for running tasks, so that I know which work is already owned.
5. As a developer, I want a clear done lane for completed tasks, so that I can see landed work without reading event logs.
6. As a developer, I want each task file to be self-contained, so that an agent never depends on prior chat context.
7. As a developer, I want task files to include acceptance criteria, so that completion can be judged against explicit expectations.
8. As a developer, I want task files to list files to touch, so that parallel agents avoid accidental overlap.
9. As a developer, I want task files to list files not to touch, so that critical or concurrently owned areas are protected.
10. As a developer, I want agents to claim tasks atomically, so that two agents do not work on the same mission packet.
11. As an agent, I want a single claim command, so that session startup is consistent and scriptable.
12. As an agent, I want claim output to include the claimed path, so that I can read and preserve the task identity.
13. As an agent, I want claim output to return `inbox:empty` when no tasks exist, so that I do not invent work.
14. As an agent, I want claimed filenames to include machine and process identity, so that debugging ownership is easier.
15. As an agent, I want a single complete command, so that task landing is consistent and scriptable.
16. As an agent, I want completion to move my mission packet to done, so that task state reflects actual lifecycle progress.
17. As a developer, I want an append-only event log, so that I can reconstruct what happened after a session ends.
18. As a developer, I want claim events recorded, so that I can see when work started and by whom.
19. As a developer, I want completion events recorded, so that I can see when work landed and with what result.
20. As a developer, I want session-end events recorded by the Stop hook, so that agent sessions leave a final black-box entry.
21. As a developer, I want event log lines to be valid JSON, so that later tooling can parse and replay them.
22. As a developer, I want event log writes to append without rewriting prior events, so that history cannot be silently changed.
23. As a developer, I want a terminal Kanban view, so that I can inspect agent state without opening multiple directories.
24. As a developer, I want the Kanban view to handle an empty inbox, so that a fresh project does not look broken.
25. As a developer, I want the Kanban view to handle missing v1 registry data, so that v0.5 works before registry exists.
26. As a developer, I want claimed tasks to show machine or process identity when possible, so that I can track active agents.
27. As a developer, I want a human approval gate before agent commits, so that no agent lands changes without review.
28. As a developer, I want the approval gate to show changed files and diff context, so that I can make a real decision.
29. As a developer, I want approval to create a token file, so that the commit hook has a simple local contract.
30. As a developer, I want denial to avoid creating an approval token, so that unsafe changes remain blocked.
31. As an agent, I want a clear approval-token path, so that I can know whether committing is allowed.
32. As a developer, I want v0.5 to avoid external services, so that setup works offline and across any local repo.
33. As a developer, I want v0.5 to use ordinary shell and filesystem primitives, so that failure modes are inspectable.
34. As a developer, I want worktrees to locate the main checkout queue, so that isolated agents still share the same control tower.
35. As a developer, I want implementation to preserve the future v2 path, so that local design does not block multi-machine git-ref claiming later.

## Implementation Decisions

### Task Store

Commandr v0.5 creates a `.agents/` directory in the main project checkout. The local control plane contains `inbox`, `claimed`, `done`, `approvals`, and `events.jsonl`.

The `.agents/` directory is project state, not global tool state. It belongs to each repo that uses Commandr. Global skills and hooks may read or write it, but the canonical task state lives inside the project.

### Mission Packet Format

A mission packet is a Markdown file with YAML frontmatter and structured body sections. Frontmatter identifies the task and reserves fields needed by later versions, including task type, blocking tasks, blocked-by tasks, and scope.

The body must contain enough context for a fresh agent. The required sections are context, acceptance criteria, files to touch, and files not to touch. The mission packet is the agent contract; chat history is not part of the contract.

### Claim Protocol

The claim protocol uses POSIX `mv` from inbox to claimed. A successful move means the agent owns the task. A failed move means another agent won the race and the claimer should try the next task or return empty.

Claimed filenames include local identity, such as hostname and process ID, to make active ownership inspectable. The command prints a machine-readable status prefix and the claimed mission packet content.

### Main Checkout Resolution

Commandr v0.5 must support agents running from git worktrees. Scripts locate the main checkout through the shared git common directory, then derive `.agents/` from that path. Worktrees must not maintain separate task queues.

### Complete Protocol

Completion moves a claimed mission packet to done. Completion is not a commit and not an approval. It only records that the agent believes the task lifecycle has landed. Commit approval remains a separate airlock.

### Event Log Writer

Lifecycle events are appended as one JSON object per line. Events include claim, completion, failure, and session end. The event log is append-only. Implementations must never rewrite or compact it in v0.5.

### Kanban Renderer

The `/kanban-status` skill reads inbox, claimed, and done lanes and renders a terminal flight board. It must not require registry data. If registry data is absent, it falls back to filenames and counts.

### Approval Gate

The approval workflow presents task identity, agent identity when available, changed files, and diff context. Approval writes `.agents/approvals/<task-id>.approved`, where `task-id` is the frontmatter `id` field from the mission packet, not the filename. Denial exits without creating the token. A diff request shows full diff context without approving.

**Commit hook guard**: Agents must install a commit hook that checks for the approval token before proceeding. The hook reads `.agents/approvals/{task-id}.approved`. If the file is absent, the hook exits non-zero and blocks the commit. The hook is installed per-worktree at `.git/hooks/pre-commit`.

### Stop Hook Adapter

The Stop hook appends a session-end event to `.agents/events.jsonl`. The event should include session identity when available, task identity when available, changed-file count when available, test-result summary when available, and exit status when available.

The hook is a global hook installed in dotfiles. It no-ops silently when `.agents/` is not present in the main checkout — `.agents/` presence is the opt-in signal. The `session_end` event is always appended when opt-in is detected, even if task context is unknown. Unknown or unavailable fields are omitted rather than causing the hook to fail.

### Design Invariants

- No lock files for local claiming.
- No database.
- No hosted service.
- No background daemon.
- No registry dependency in v0.5.
- No council dependency in v0.5.
- `.agents/` lives in the main checkout, not inside per-agent worktrees.
- Event log is append-only.
- Approval token is represented by file existence.

### Data Format Contracts

This section defines the exact on-disk formats that all scripts, skills, and hooks must produce and consume. Any implementation that deviates from these shapes will produce incompatible output.

#### Mission Packet Frontmatter Schema

Mission packets use YAML frontmatter delimited by `---`. The following fields are defined for v0.5:

| Field | Type | Status | Description |
|---|---|---|---|
| `id` | string | Required | Unique task identifier (e.g. `TASK-001`). Used as the approval token basename. |
| `type` | enum | Required | Task classification. Allowed values: `implementation`, `research`, `review`. |
| `scope` | string | Required | Glob path defining the primary filesystem area the agent may modify (e.g. `src/agents/**`). |
| `blocking` | string[] | Reserved (v1+) | IDs of tasks that this task blocks. Default empty array. |
| `blocked-by` | string[] | Reserved (v1+) | IDs of tasks that must complete before this task begins. Default empty array. |

All other frontmatter fields are ignored in v0.5 and must not be relied upon by scripts or skills.

#### Claimed Filename Format

When `claim.sh` moves a task from inbox to claimed, it renames the file using the following pattern:

```
{hostname}-{pid}-{original-task-filename}
```

Example: `mbp-12345-TASK-001.md`

The Kanban renderer parses ownership identity by splitting on `-` with a maximum of 3 parts from the left. The third part and beyond is the original filename. Implementations must not use a different separator or ordering.

#### Event Log Record Shapes

Each line in `events.jsonl` is a single JSON object. The following event types are defined. All timestamps use ISO 8601 format. Fields marked with `?` are optional and may be omitted when the value is unavailable.

**task_claimed**
```json
{"ts": "<ISO8601>", "event": "task_claimed", "task": "<task-id>", "agent": "<agent-id>", "machine": "<hostname>"}
```

**task_complete**
```json
{"ts": "<ISO8601>", "event": "task_complete", "task": "<task-id>", "result": "pass" | "fail"}
```

**task_failed**
```json
{"ts": "<ISO8601>", "event": "task_failed", "task": "<task-id>", "agent": "<agent-id>", "reason": "<description>"}
```

**session_end**
```json
{"ts": "<ISO8601>", "event": "session_end", "session": "<session-id>", "task?": "<task-id>", "files_changed?": <number>, "tests_summary?": "<string>", "exit_status?": <number>}
```

No other event types are defined in v0.5. Writers must not emit undefined event types. Readers must tolerate unknown event types without failing.

#### Approval Token Path

The approval token for a task is located at:

```
.agents/approvals/{task-id}.approved
```

where `task-id` is the `id` field from the mission packet frontmatter, not the claimed filename. For example, a task with `id: TASK-001` writes a token at `.agents/approvals/TASK-001.approved`. The commit hook reads this path; the approval workflow writes to this path. Both must use the frontmatter `id`, not any derived filename component.

### Command Contracts

This section defines the exact interface for `scripts/claim.sh` and `scripts/complete.sh`. Agents and tests must rely only on these contracts, not on implementation internals.

#### `claim.sh`

**Invocation**: `scripts/claim.sh` (no arguments)

**Behavior**:
- Attempts to atomically claim the next task from `.agents/inbox/` using POSIX `mv`.
- On success, prints `claimed:{absolute-path-to-claimed-file}\n` followed by the full contents of the claimed mission packet.
- On empty inbox, prints `inbox:empty\n`.
- Exits 0 in both cases. An empty inbox is not an error.
- Prints to stderr only on unexpected filesystem errors (e.g., permission denied, missing `.agents/` directory).
- Does **not** append events to `events.jsonl`. The caller (agent or harness) is responsible for appending a `task_claimed` event after a successful claim.

#### `complete.sh {claimed-path}`

**Invocation**: `scripts/complete.sh <absolute-or-relative-path-to-claimed-file>`

**Behavior**:
- Moves the specified claimed file from `.agents/claimed/` to `.agents/done/`.
- On success, prints `done:{absolute-path-to-done-file}\n` and exits 0.
- If the specified claimed path does not exist, exits 1. No output is written to stdout on failure.
- Does **not** append events to `events.jsonl`. The caller is responsible for appending a `task_complete` or `task_failed` event.

### Git Tracking Policy

The following table defines what in `.agents/` is committed to the repository versus gitignored. This decision affects CI fixtures, team workflows, and reproducible test state.

| Path | Policy | Rationale |
|---|---|---|
| `inbox/*.md` | Committed | Task definitions are authored intent; they belong in git history. |
| `done/*.md` | Committed | Completed task files are the audit trail; they should survive `git clone`. |
| `.gitkeep` files | Committed | Directory placeholders ensure the folder structure exists after checkout. |
| `claimed/*.md` | Gitignored | Runtime state that changes per session; meaningless outside the owning machine. |
| `approvals/*.approved` | Gitignored | Ephemeral tokens that are session-scoped; re-approval is required each time. |
| `events.jsonl` | Gitignored | Runtime log that is appended continuously; committing it would cause constant conflicts. |
| `council/` | Gitignored | Runtime vote files; ephemeral and session-scoped. |

The `.gitignore` entry for the project should include:

```
.agents/claimed/
.agents/approvals/
.agents/events.jsonl
.agents/council/
```

## Testing Decisions

Good tests validate external behavior, not implementation details. Tests should treat scripts and skills as command surfaces: given filesystem state and command input, verify filesystem output, stdout, stderr, and exit status.

Modules to test:

- **Task store setup**: required directories exist; `events.jsonl` can be created and appended.
- **Claim protocol**: one task can be claimed; empty inbox returns `inbox:empty`; claimed filename includes identity; claimed content is printed.
- **Concurrent claim behavior**: multiple claimers racing for one task result in exactly one successful claim.
- **Complete protocol**: claimed task moves to done; invalid or missing claimed path fails clearly.
- **Event log**: appended lines parse as JSON; claim and completion events include required fields; previous lines are not rewritten.
- **Kanban renderer**: renders correct lane counts; handles empty lanes; handles missing registry data; parses claimed filenames.
- **Approval gate**: approval creates token; denial does not; diff request does not create token; changed-file summary is shown.
- **Stop hook adapter**: appends a session-end event; handles missing optional metadata without failing the whole hook.

Testing should include at least one end-to-end local scenario:

1. Create a mission packet in inbox.
2. Claim it.
3. Confirm it appears in claimed.
4. Append or observe claim event.
5. Render Kanban status.
6. Complete it.
7. Confirm it appears in done.
8. Confirm event log remains parseable.

## Out Of Scope

- Multi-machine claiming through git refs.
- Timeout recovery for stale claimed tasks.
- Agent registry.
- Council quality gate.
- `blocked-by` dependency enforcement.
- Schema validation beyond the minimal mission packet contract.
- Hosted dashboard or web UI.
- GitHub Projects sync.
- Langfuse traces.
- Slack, mobile, or push notifications.
- Windows support.
- External workflow engines such as LangGraph.

## Further Notes

v0.5 should bias toward boring primitives because this is coordination infrastructure. A small set of transparent shell scripts and files is easier to debug than a hidden service. The important product promise is not automation volume; it is reliable local control over agent work.

The PRD intentionally preserves later evolution paths. The local inbox, claimed, and done lanes map cleanly to future git ref namespaces. The append-only event log can later drive replay or observability. The approval token can later become a richer review object without changing the core commit-hook contract.

Once this PRD is accepted, the next step is to split it into vertical implementation slices: task store bootstrap, claim/complete scripts, event log writer, Kanban renderer, approval workflow, and Stop hook adapter.
