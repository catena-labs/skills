# panel-plan

Harden a written plan by iterating it through a panel of independent local CLI coding agents (codex, claude, opencode) running in parallel. The planning-time sibling of `panel-review`: instead of reviewing a code diff, it reviews a design / implementation plan (a markdown file) *before* any code is written — then loops, round after round, until the plan stops attracting significant concerns.

## Install

```
npx skills add catena-labs/skills --skill panel-plan
```

## How to use it

Write a plan first (e.g. via brainstorming or `writing-plans`), then ask Claude Code in plain English:

- "panel plan docs/specs/foo.md"
- "have the panel review my plan"
- "panel-review this plan, focus on the migration strategy"
- "iterate on this plan with the panel"
- "panel plan with just codex and claude"

## What it does

- Spawns each panelist as a fresh, non-interactive subprocess with no shared conversation state — independent second opinions are the whole point.
- Embeds the plan (with line numbers) in the prompt and runs every panelist **read-only** against your working tree, so each one can check the plan's assumptions against the real codebase — does the file/function/table it references exist? is the step feasible? — without being able to modify anything.
- Each panelist reports structured findings (severity + `plan:line` + suggested plan edit), a goal/approach read, and an **open questions** block — the decisions only a human can make.
- The coordinator synthesizes the round, **applies the clear, uncontested fixes to the plan directly**, **raises every genuine judgment call to you** (open questions, trade-offs, scope changes, panelist disagreements), updates the plan, and re-runs the panel.
- Loops automatically until a round surfaces no new must/should-fix concerns, then asks whether to stop — with a safety cap of 4 rounds. Each round's concerns, your decisions, and the edits applied are logged to a sibling `<plan>.review.md` so the plan file itself stays clean.

## Gotchas

- **Background Bash + `BashOutput` polling is required.** Codex dominates wall clock, so foreground calls block silently for minutes. Don't launch `panel-plan.sh` via the `Agent` tool / subagents — there's no streaming-output API for in-flight subagents and the heartbeats become invisible.
- **Read-only, but not sandboxed against everything.** Panelists run read-only (no edits, no exec that changes state), but they do read your working tree and pick up the project's `AGENTS.md` / `CLAUDE.md` — intentional, but worth knowing if those would bias the review.
- **Write the plan to a file first.** The panel reviews a `.md` on disk; if your plan only lives in the conversation, save it before invoking.
