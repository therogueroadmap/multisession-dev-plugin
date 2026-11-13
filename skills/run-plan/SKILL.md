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
- By default the driver creates a work branch. Add `-UseCurrentBranch` to use the active branch, which needs a clean working tree.
- The driver handles one repository. A plan that spans several repositories cannot run with it.
- Keep the other parameters at their defaults unless the user asks.
