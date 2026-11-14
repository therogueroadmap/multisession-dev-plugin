---
name: run-plan
description: Use when an implementation plan with a dependency map should run unattended across chained headless sessions, or when writing-plans offers multi-session execution. Prints the driver command. It does not run anything.
---

# Run a plan across sessions

Print the command for the user to run in their own terminal, then stop. Do not run it yourself.

The driver lives two levels above this skill's base directory, in `scripts/plan-session-driver.ps1`. Resolve that absolute path from the base directory shown when this skill loaded.

```powershell
pwsh "<resolved path to plan-session-driver.ps1>" `
  -ProjectPath "<root of the repository where the plan runs>" `
  -PlanFile "<plan-file-name>.md"
```

- `-PlanFile` is the bare file name. The driver looks for it in `docs\superpowers\plans`.
- The driver needs a clean working tree, whether it creates a work branch (the default) or runs on the active one with `-UseCurrentBranch`. Do not commit the plan or its spec: list `docs/superpowers/specs/` and `docs/superpowers/plans/` in `.gitignore`, which also covers the checkpoint and the driver's own files.
- The driver handles one repository. A plan that spans several repositories cannot run with it.
- Keep the other parameters at their defaults unless the user asks.
