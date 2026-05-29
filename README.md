# skills

A collection of useful Agent Skills we use at [Catena](https://catenalabs.com).

## Install

Install every skill in the repo:

```
npx skills add catena-labs/skills
```

Or install a specific skill:

```
npx skills add catena-labs/skills --skill optimize-agents-md
```

## Skills

| Skill                                                   | Description                                                                                                            |
| ------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| [optimize-agents-md](./skills/optimize-agents-md)       | Optimize your AGENTS.md (and CLAUDE.md) files according to best practices. Works with monorepos, too                   |
| [panel-plan](./skills/panel-plan)                       | Harden a written plan by iterating it through a panel of independent local CLI agents — auto-fix the clear stuff, raise judgment calls to you, loop to convergence |
| [panel-review](./skills/panel-review)                   | Fan a code review out to multiple local CLI agents (codex, claude, opencode) in parallel and synthesize their findings |
| [triage-pr-comments](./skills/triage-pr-comments)       | Triage every review comment on a PR — verdict per comment, then fix, push, and reply on GitHub                         |

## License

MIT
