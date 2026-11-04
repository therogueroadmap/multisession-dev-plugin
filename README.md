# multisession-dev-plugin

A PowerShell driver that runs an implementation plan in chained headless Claude Code sessions,
one dependency level per session, with a local dashboard to follow the run.

It expects plans with a Dependency Map (a `Task | Depends On | Level` table), like the ones I
write with my planning skills.

## Status

Under construction. It is not a Claude Code plugin yet (no `plugin.json`), so it is not in the
[catalog](https://github.com/therogueroadmap/marketplace). I publish it to work on it in the open.

## Requirements

- Windows with PowerShell 7 (`pwsh`).
- Claude Code CLI on `PATH`.
- Python 3 for the dashboard server.
- Pester 3.4.0 (the tests use the `Should Be` syntax, which fails on Pester 5) and pytest to run the tests.

## Usage

```powershell
pwsh scripts/plan-session-driver.ps1 -ProjectPath <project root> -PlanFile <plan>.md
```

A bare `-PlanFile` name is resolved inside `docs/superpowers/plans` of the project; absolute paths and relative paths with a folder also work. Without it, the driver picks the plan when that folder has exactly one `.md` file.
The dashboard listens on port 8787 by default (`-Port`).

## Tests

```powershell
Import-Module Pester -RequiredVersion 3.4.0 -Force; Invoke-Pester -Path tests
python -m pytest tests/python
```

## License

MIT
