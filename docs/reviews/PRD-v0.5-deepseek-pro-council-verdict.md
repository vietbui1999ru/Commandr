# Council Verdict: PRD-v0.5 Review Synthesis

Council chair model: `opencode-go/deepseek-v4-pro`

Source reviews:

- `docs/reviews/PRD-v0.5-local-agent-control-tower-gpt-5.5-review.md` (GPT-5.5)
- `docs/reviews/PRD-v0.5-review.md` (Claude Code, Sonnet 4.6)

## Overall Verdict

PRD is architecturally sound but implementation-precision deficient. Both reviewers independently identify the same root gap: the PRD communicates what clearly but leaves interface contracts too loose for independent agents or implementers to produce compatible outputs.

The PRD is not yet `to-issues` ready. It needs one targeted tightening pass on data formats, command contracts, and the approval gate before vertical slices can be cut safely.

## Consensus Findings

| Finding | GPT-5.5 Priority | Claude Priority | Council Notes |
|---|---|---|---|
| Command contracts for `claim.sh` / `complete.sh` are underspecified | Medium | P2 Blocking | Strongest agreement; blocks implementation |
| Event log schema is undefined | Medium | P1 Blocking | Required before scripts, hooks, or tests can interoperate |
| Approval gate is incomplete without commit hook guard | High | P3 + P7 | GPT-5.5 weights correctly; enforcement must be explicit |
| Stop hook trigger condition is unstated | Medium | P5 Medium | Same finding from both reviews |
| Claimed filename format is not a defined contract | Indirect | P4 High | Claude surfaces it more clearly; must be fixed |

## Unique Findings

### Found By GPT-5.5

- Git tracking policy for `.agents/` runtime files is ambiguous.
- Failed task lifecycle has no storage representation.
- Product vocabulary is not mapped clearly to filesystem names.
- Acceptance criteria are implied rather than explicit.

### Found By Claude

- Concurrent claim test strategy is unspecified.
- v0.5-to-v2 migration needs a quiesce note.
- Main checkout resolution needs exact pseudocode to avoid `git rev-parse --show-toplevel` misuse in worktrees.

## Disagreements And Weighting

GPT-5.5 is slightly over-optimistic on `to-issues` readiness. Claude's caution carries more weight because missing data contracts would cause incompatible implementations and rework.

GPT-5.5 adds one important gap Claude missed: `.agents/` git tracking policy. That decision affects CI, team workflows, and fixtures, so it should be included in the PRD tightening pass.

Claude adds deeper test and future-proofing concerns that GPT-5.5 missed. These are lower severity but worth including because they prevent downstream footguns.

## Final Prioritized Patch Plan

### Block 1: Must Fix Before Implementation

1. Define all data format contracts.
2. Specify `claim.sh` and `complete.sh` command contracts.
3. Add commit hook guard to approval story.

Data contracts must include:

- Mission packet frontmatter schema: field names, types, required vs. reserved.
- Claimed filename format.
- Event log record shapes for `task_claimed`, `task_complete`, `task_failed`, and `session_end`.
- Approval token filename pattern.

Command contracts must include:

- Exact stdout format.
- Exit codes.
- Stderr behavior.
- Missing directory behavior.
- Whether scripts append events themselves.

### Block 2: Should Fix Before `to-issues`

4. Add git tracking policy for `.agents/`.
5. Specify Stop hook opt-in/no-op behavior.
6. Add explicit acceptance criteria checklist.

Git tracking policy must decide whether to commit or ignore:

- Directory placeholders.
- Inbox task files.
- Claimed task files.
- Done task files.
- Approval tokens.
- `events.jsonl`.

Stop hook behavior must specify:

- Global hook no-ops outside Commandr repos.
- `.agents/` presence is the opt-in signal.
- `session_end` is appended only when task context is known or when hook can safely record a partial event.

### Block 3: Nice To Fix

7. Specify concurrent claim test strategy.
8. Add v0.5-to-v2 migration quiesce note.
9. Map product vocabulary to filesystem names.
10. Specify failed task lifecycle.

Recommended failure policy: failed tasks remain in `.agents/claimed/`; `task_failed` is appended to `events.jsonl`. No `failed/` lane in v0.5.

Recommended migration note: drain in-flight v0.5 tasks before switching to v2 git-ref claiming.

## To-Issues Readiness

Current status: not ready.

Ready after Block 1 patches. Best after Block 2 patches.

Recommended issue slices after PRD tightening:

1. Bootstrap `.agents/` store and git tracking policy.
2. Implement `claim.sh` with exact command contract.
3. Implement `complete.sh` and failure policy.
4. Implement event log writer and schema validation.
5. Implement `/kanban-status` renderer.
6. Implement approval workflow and commit hook guard.
7. Implement Stop hook adapter with opt-in/no-op behavior.
8. Add end-to-end local lifecycle test.

## Council Ruling

Patch PRD before running `to-issues`. Do not generate implementation tickets from current PRD because missing contracts would force agents to invent incompatible interfaces.
