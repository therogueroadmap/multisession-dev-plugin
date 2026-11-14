# multisession-dev-plugin

A PowerShell driver that runs an implementation plan in chained headless Claude Code sessions,
one dependency level per session, with a local dashboard to follow the run.

It expects plans with a Dependency Map (a `Task | Depends On | Level` table), like the ones
`rogue-workflow:writing-plans` writes.

## Status

Version 0.1.0. Under construction: it is not in the
[catalog](https://github.com/therogueroadmap/marketplace) yet.
I publish it to work on it in the open.

## Install

Once it is listed in the [The Rogue Roadmap catalog](https://github.com/therogueroadmap/marketplace):

```text
/plugin marketplace add therogueroadmap/marketplace
/plugin install multisession-dev-plugin@therogueroadmap
```

## Requirements

- Windows with PowerShell 7 (`pwsh`).
- Claude Code CLI on `PATH`.
- The `rogue-workflow` plugin, its declared dependency: every session runs `rogue-workflow:subagent-driven-development`.
- Python 3 for the dashboard server.
- Pester 3.4.0 (the tests use the `Should Be` syntax, which fails on Pester 5) and pytest to run the tests.

## Usage

The `run-plan` skill prints the driver command for a plan; `rogue-workflow:writing-plans` offers it when a plan suits unattended execution. You can also run the driver yourself:

```powershell
pwsh scripts/plan-session-driver.ps1 -ProjectPath <project root> -PlanFile <plan>.md
```

A bare `-PlanFile` name is resolved inside `docs/superpowers/plans` of the project; absolute paths and relative paths with a folder also work. Without it, the driver picks the plan when that folder has exactly one `.md` file.
The dashboard listens on port 8787 by default (`-Port`).

### Limits

- One repository per run. A plan that spans several repositories cannot run with the driver: run it interactively, or split it into one plan per repository.
- A clean working tree. List `docs/superpowers/specs/` and `docs/superpowers/plans/` in `.gitignore`: that covers the plan, its spec, the checkpoint and the driver's own files.
- By default the driver creates a work branch named after the plan, from `develop`, `main` or `master`. With `-UseCurrentBranch` it runs on the active branch instead.
- When it finishes, the plan is closed in full: final review, its fix wave, the scoped re-review, the rulings and the full suite, with the result in `docs/superpowers/plans/.final-review-<plan>.md`. The close session ends with `COMPLETE`; it never merges, pushes or opens a pull request. If the close is cut short, the record stays as `.final-review-<plan>.draft.md` and the next close session resumes from it. The dashboard then shows "Lista para integrar, falta PR": merging and opening the pull request are up to you.

## Tests

```powershell
Import-Module Pester -RequiredVersion 3.4.0 -Force; Invoke-Pester -Path tests
python -m pytest tests/python
```

## License

MIT
