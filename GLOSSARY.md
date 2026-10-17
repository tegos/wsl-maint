# wsl-maint

Terms for how the cleaner decides what to delete and how it reports what it freed.

## Language

- **Rule**: one line of `rules.conf`: a path, a policy, its argument, and whether `clean` runs it unasked (`auto`).
- **Policy**: how a rule picks its targets under the path: `purge`, `age`, `keep-newest`, `pw-orphan`, `vacuum`.
- **Estimate**: bytes a rule would free, measured before anything is deleted. What `audit` and `clean --dry-run` report.
- **Freed**: bytes a rule actually reclaimed, measured after it ran. Never an estimate; a refused or half-deleted target counts only what left the disk.
- **Rule run**: one rule planned (targets enumerated and sized once) and then applied, yielding both its estimate and what it freed.
