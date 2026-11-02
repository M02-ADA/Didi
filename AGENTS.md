# AGENTS.md — Sedactive (Codex: Edo, Jevon)

> **Status: DRAFT — not yet approved by the team.**

Read `Docs/TEAM_ALIGNMENT.md` before your first change in a session. It is the team's single source of truth and takes precedence over this file. Follow its source-precedence order.

- **Owner:** work as the owner named in the task, Edo or Jevon, within the areas listed for them in TEAM_ALIGNMENT §A. If the owner is unclear, ask. Edits to another owner's files follow the proposal step in §E.
- **Before implementing:** read the relevant existing code and `Docs/Architecture/Game-Oriented-Architecture.md` for current paths, plus applicable Architecture Reference sections. Source folders are logical modules within the existing app target.
- **Contracts:** use the shared contract types (§B) exactly as their producer defines them. Extend them through the contract workflow.
- **Workflow:** follow the risk-based workflow in §E.
  - Small changes in your own area go straight through.
  - Contract changes, cross-owner changes, and coordinate or timing changes are proposed first and wait for agreement.
- **Skills (§D):** check your installed Codex skills for ones that match the task. Read the skill's `SKILL.md` before applying it. Typical areas:
  - Swift/iOS
  - AVFoundation and Vision
  - Swift concurrency
  - game logic and state machines
  - unit and integration testing
  - performance profiling

  These are areas to look for, not a list of installed skills.
- **Testing:** run the tests relevant to your change (§F).
- **Finish with the §F report:** changed files, tests and results, skills used, limitations, and integration work for other owners.
