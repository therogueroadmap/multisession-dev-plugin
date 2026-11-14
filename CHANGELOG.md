# Changelog

## [0.1.0] - 2026-11-14

### Added
- `.claude-plugin/plugin.json`, with `rogue-workflow` as a dependency.
- `run-plan` skill, which prints the driver command.

### Changed
- The driver runs each level with `rogue-workflow:subagent-driven-development`.
- The close session finishes the plan: final review, fix wave, scoped re-review, rulings and full suite. It gets the base branch, or a candidate to confirm, from the driver, ends with `COMPLETE` and never merges, pushes or opens a pull request; opening the pull request stays with you.
- The close session keeps its record in `.final-review-<plan>.draft.md` and renames it to the `.final-review-<plan>.md` marker when the suite is green; the marker still means the plan is closed.
- The level prompts leave the re-review cap to `rogue-workflow`'s fix loop.
- The dashboard strips the plugin prefix from agent types and shows the combined review, the model of each dispatch, a "Cierre" group and the ready-to-integrate state that still needs a pull request.
- The clean-tree check ignores the close marker and its draft.
- The end-to-end driver tests carry the `Slow` tag, and a test hook sets the decision wait in seconds.
- README: install, the `rogue-workflow` requirement, the `run-plan` skill and the driver's limits.
