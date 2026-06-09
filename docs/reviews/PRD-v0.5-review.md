# PRD Review: Commandr v0.5 — Local Agent Control Tower

**Document reviewed:** `docs/prds/PRD-v0.5-local-agent-control-tower.md`
**Review date:** 2026-05-29
**Reviewer:** Claude Code (Sonnet 4.6)

---

## Summary Verdict

The PRD is well-conceived and well-scoped for a v0.5 cut. The problem statement is crisp, the vocabulary section is genuinely useful, and the Out of Scope list is one of the stronger parts of the document. The main gaps are in the *implementation precision* layer: enough is said to understand the design, but not enough to implement it without a follow-up design session. A motivated implementer would get stuck on at least four concrete questions. The testing section is structurally sound but thin on specifics. No major contradictions exist.

---

## 1. Completeness

**Rating: Adequate**

- The problem, solution, vocabulary, and user stories are all present and coherent. A reader can understand what the system does and why.
- Mission packet format is described in prose but the actual frontmatter schema is never shown. The required fields (task type, blocking tasks, blocked-by, scope) are named in passing but not defined. An implementer cannot write a mission packet template without guessing field names, types, and whether they are optional or required in v0.5.
- The claim command interface (name, arguments, expected stdout format) is described behaviorally ("prints a machine-readable status prefix") but never specified. The same gap exists for the complete command.
- The Stop hook's trigger condition is not stated. It is described as recording "session-end events," but it is not clear whether it fires on every Claude Code session end, only on sessions that have a claimed task, or only on sessions that explicitly called claim.
- The approval workflow interaction model is missing. The PRD says it "presents" information and asks the user to approve or deny, but the mechanism (interactive prompt? shell script? Claude skill?) is unclear enough that two implementers could build incompatible versions.

**Recommendations:**
1. Add a minimal mission packet YAML frontmatter schema with field names, types, and which fields are required versus reserved for later versions.
2. Specify the CLI surface of `claim` and `complete`: exact command name, arguments, and stdout contract (e.g., `CLAIMED:<path>` or `inbox:empty`).
3. Clarify the Stop hook trigger: does it fire unconditionally or only when `.agents/` is present in the repo?

---

## 2. Consistency

**Rating: Strong**

- User stories and implementation decisions are well-aligned. Every story maps to at least one implementation section without contradiction.
- The "no lock files for local claiming" invariant is consistent with the POSIX `mv` protocol described in the Claim Protocol section.
- User story 25 ("handle missing v1 registry data") and user story 35 ("preserve future v2 path") are both addressed in the Kanban Renderer and Further Notes sections without tension.
- One minor inconsistency: user story 14 says "claimed filenames include machine and process identity," and the Claim Protocol section says "hostname and process ID." These are consistent, but the approval workflow section says "agent identity when available" without specifying the same format. The approval gate should reference the same identity fields explicitly to avoid divergent implementations.
- The Complete Protocol section says completion "is not a commit and not an approval," which correctly separates concerns, but the relationship between the approval gate and the commit hook is described only at the token-file level. The hook itself (what intercepts the commit and checks for the token) is not mentioned anywhere in the document. This is not an inconsistency per se, but the missing piece means the approval story is incomplete.

**Recommendations:**
1. Align the "agent identity" terminology in the approval gate section with the explicit "hostname and process ID" language in the Claim Protocol section.
2. Add a brief note or user story covering the commit hook that reads the approval token — even if the hook is a one-liner, its existence should be acknowledged so the approval gate story is complete.

---

## 3. Scope Discipline

**Rating: Strong**

- The Out of Scope list is explicit, specific, and well-chosen. It names real temptations (timeout recovery, dependency enforcement, Langfuse, Slack) that a less disciplined PRD would have folded in.
- `blocked-by` dependency enforcement is correctly deferred. The frontmatter reserves the field without requiring the enforcement logic.
- Schema validation is scoped to "minimal mission packet contract," which is the right call for v0.5, though the minimal contract is not yet defined (see Completeness finding above).
- One potential scope creep to watch: user story 26 says "claimed tasks show machine or process identity when possible." The phrase "when possible" is fine for a user story, but the Kanban Renderer section says it "parses claimed filenames." If the parser must extract identity from filenames, that requires a defined filename format — which is currently underspecified. Implementers may over-engineer parsing logic to handle ambiguous formats.

**Recommendations:**
1. Define the claimed filename format (e.g., `<original-name>.<hostname>.<pid>.md`) as an invariant rather than leaving it to implementer discretion. This keeps scope tight by preventing each implementer from inventing their own format.

---

## 4. Implementability

**Rating: Needs Work**

This is the primary gap. The PRD communicates the *what* clearly but leaves too many *how* questions open for a first-time implementer.

- **Mission packet schema:** No template, no field definitions. An implementer cannot write a mission packet without guessing. At minimum, the PRD needs to show the frontmatter skeleton with field names and indicate which are required now versus reserved.
- **Claim command contract:** "Machine-readable status prefix" is underspecified. Is the prefix `CLAIMED:`, `STATUS:CLAIMED`, or something else? Does the command print the full file content after the prefix, or just the path? What is the exit code on empty inbox versus claim failure?
- **Claimed filename format:** Described as "hostname and process ID" but the separator, ordering, and extension are not defined. The Kanban renderer must parse this, so the format must be a defined contract, not a convention.
- **Event log schema:** The PRD says events include claim, completion, failure, and session end, and lists optional fields for session-end events. But there is no field-level schema. What is the required shape of a claim event? A completion event? Without this, two components writing to `events.jsonl` will produce incompatible records.
- **Approval workflow mechanism:** Is this a skill (Claude-driven), a shell script, or an interactive prompt? The PRD does not say. This is a significant implementation decision that is currently left open.
- **Main checkout resolution algorithm:** The PRD says "scripts locate the main checkout through the shared git common directory." This is enough to implement, but only for developers who already know that `git rev-parse --git-common-dir` works correctly in worktrees. A note or pseudocode would reduce the risk of an implementer using a subtly wrong approach (e.g., `git rev-parse --show-toplevel`, which returns the worktree root, not the main checkout).

**Recommendations:**
1. Add an appendix or "Data Formats" section with: mission packet frontmatter schema, claimed filename format, event log record shapes for each event type, and approval token filename pattern.
2. Specify the approval workflow mechanism (skill vs. shell script vs. interactive CLI).
3. Include a pseudocode or one-liner showing the worktree resolution approach.

---

## 5. Testability

**Rating: Adequate**

- The testing section is well-structured: it lists modules to test and specifies the testing philosophy (treat scripts as command surfaces, verify filesystem and stdout state). This is the right approach.
- The end-to-end scenario at the bottom is concrete and covers the happy path. It is a good acceptance test skeleton.
- Gaps exist in edge case coverage. Concurrent claim behavior is listed as a test module ("exactly one successful claim") but no guidance is given on how to simulate the race condition in a test harness. For filesystem-based concurrency, this is non-trivial and the PRD should at least acknowledge the challenge.
- Failure mode testing is thin. The only failure case mentioned is "invalid or missing claimed path fails clearly." There is no test for: what happens if `events.jsonl` is unwritable, if `.agents/` is missing when claim is called, if the Stop hook fires in a repo with no `.agents/` directory, or if the approval token already exists when approval is run again.
- The Kanban renderer tests ("parses claimed filenames") depend on a claimed filename format that is not yet defined, making the test specification circular.
- No mention of whether tests should be automated (e.g., shell-based, bats, pytest) or manual verification is acceptable for some modules.

**Recommendations:**
1. Specify the test runner or framework (even "bats or plain shell assertions" is enough).
2. Add at least two failure-path test cases per module: one for missing/invalid input, one for partial state (e.g., `.agents/` exists but `inbox/` is missing).
3. Address the concurrent claim test strategy — e.g., "use a subshell race or sleep-based interleaving" so implementers don't skip it.

---

## 6. Future-Proofing

**Rating: Strong**

- The PRD explicitly acknowledges the v2 multi-machine path in user story 35, the Further Notes section, and the Design Invariants list. The design choices map cleanly to a future git-ref-based claiming protocol.
- The append-only event log is the right foundation for future replay or observability without requiring any structural change.
- The approval token as a file-existence contract is deliberately minimal, which preserves the ability to enrich it later (token file could carry richer metadata in v2 without breaking the commit hook contract).
- The `blocked-by` and `scope` frontmatter fields being reserved but not enforced is a clean way to stake out the schema space without building the enforcement logic prematurely.
- One risk: the POSIX `mv` claim protocol is single-machine only, which is fine for v0.5. However, the PRD does not describe how the transition to git-ref claiming would be handled for tasks that are mid-flight at migration time. This does not need to be solved in v0.5, but a brief note acknowledging the migration concern would prevent a future implementer from assuming `mv`-based and git-ref-based claims can coexist during transition.

**Recommendations:**
1. Add a one-sentence note in Further Notes acknowledging that the v0.5-to-v2 migration path requires a quiesce step (drain in-flight tasks before switching claim protocols). This prevents over-engineering in v0.5 while flagging the concern for v2 planning.

---

## Prioritized Issues to Address Before Implementation Starts

The following issues are ordered by the likelihood that leaving them open will cause implementers to make incompatible decisions or waste significant effort.

**Priority 1 — Blocking: Data format contracts are missing**

The mission packet frontmatter schema, claimed filename format, and event log record shapes for each event type must be defined before any component is built. Without these, independently written scripts and skills will produce incompatible output and the Kanban renderer and event log parser will need to be rewritten.

**Priority 2 — Blocking: Claim and complete command interfaces are underspecified**

The stdout contract for `claim` (status prefix format, content output, exit codes) and `complete` (success/failure signals) must be pinned. Every consumer of these commands — including skills, tests, and the Stop hook — depends on a stable surface.

**Priority 3 — High: Approval workflow mechanism is undefined**

Whether the approval gate is a Claude skill, a shell script, or an interactive prompt affects how it is implemented and tested. This decision should be made explicit before implementation begins.

**Priority 4 — High: Claimed filename format must be a defined contract**

The Kanban renderer, the Stop hook, and the approval gate all reference "agent identity" derived from the filename. Without a defined format, these three components will implement incompatible parsers.

**Priority 5 — Medium: Stop hook trigger condition is unstated**

Clarify whether the hook fires unconditionally on every session end or only when `.agents/` is present. This affects whether the hook needs a guard clause and whether it can silently fail on non-Commandr repos.

**Priority 6 — Medium: Test strategy for concurrent claim is unspecified**

The concurrent claim test is listed as required but the test approach is not described. This should be specified before the test suite is written to avoid the test being skipped or implemented incorrectly.

**Priority 7 — Low: Commit hook existence should be acknowledged**

The approval token contract is described, but the commit hook that reads the token is never mentioned. Add a brief note or user story so the full approval-gate story is traceable in the document.

---

*End of review.*
