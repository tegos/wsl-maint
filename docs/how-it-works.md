# wsl-maint: how it works

For contributors who want to understand the tool or build something similar. Usage,
flags, `maint.conf` and test commands are in the README; this file covers the design,
the guards and the pitfalls.

Read the README first, then this file. Code: `wsl/maint` -> `wsl/lib/*.sh` (WSL side,
bash), `maint.bat` -> `maint.ps1` -> `win/*.ps1` (Windows side, PowerShell 5.1). Examples
use the distro `Ubuntu` (the default).

## Architecture: Windows orchestrates, WSL executes

`wsl --export` and `wsl --shutdown` kill the VM. A bash script inside WSL that runs them
dies halfway. Only the Windows side can survive the whole sequence (clean, export,
shutdown, compact).

So the tool has two halves:

- `wsl/maint` (bash) does everything that works from inside Linux: cleaning caches,
  Docker, audit, backup verification. No admin needed.
- `maint.bat` -> `maint.ps1` does what needs a stopped VM or admin rights: export,
  compact, Defender exclusions, Windows TEMP. It calls into WSL with
  `wsl.exe -d <distro> -- <absolute path>/wsl/maint ...`, where the path is derived from
  the repo location (`D:\tools\wsl-maint` -> `/mnt/d/tools/wsl-maint/wsl/maint`).

The repo lives on a Windows drive, not inside WSL. After `wsl --shutdown`,
`\\wsl$\Ubuntu\...` is gone, and the PowerShell script could no longer load its own
modules from there. From WSL the repo is visible as `/mnt/d/...`, so both halves read the
same `maint.conf`.

Rejected alternatives:

- **A detached `Start-Process` launched from WSL.** It survives shutdown, but the caller
  loses the exit code and output and cannot drive the next steps.
- **Recompressing with Windows `tar.exe`.** It rewrites every tar entry, which risks
  silently losing metadata in a disaster-recovery archive. `zstd` over the finished tar
  bytes cannot break the archive structure.
- **Piping `wsl --export Ubuntu -` into a compressor.** PowerShell 5.1 corrupts binary
  data in pipelines, and zstd only exists inside the distro being exported.

```
maint.bat (UAC self-elevation, pause at the end)
  -> maint.ps1 (verb dispatcher)
       -> win/Backup.ps1   clean -> fstrim -> export -> zstd -> verify -> retention
       -> win/Compact.ps1  shutdown -> wait until WSL is really stopped -> Optimize-VHD
       -> win/WinClean.ps1, win/Defender.ps1
       -> wsl.exe -- /mnt/<drive>/.../wsl/maint clean|audit|docker
                              |
wsl/maint (bash CLI) ---------+
  lib/config.sh   reads maint.conf (as data, never sourced)
  lib/rules.sh    parses rules.conf, policies, rule_run (plan once, apply, count freed)
  lib/common.sh   safe_rm + the protected path list
  lib/clean.sh    runs the auto rules, sums what was freed
  lib/audit.sh    size / would free / delta table
  lib/space.sh    what fills the vhdx (read-only)
  lib/docker.sh   build cache + anonymous dangling volume prune (named: opt-in + guard)
  lib/browsers.sh which Playwright revisions are still needed
  lib/state.sh    key=value state (last sizes, last run times)
```

## WSL side

### rules.conf

One line per cache: `path policy arg auto`. Policies:

| policy | deletes |
|---|---|
| `purge` | every direct child of the folder |
| `age 30d` | children inactive for more than N days (see below) |
| `keep-newest N` | all but the N newest by mtime |
| `pw-orphan` | Chromium revisions in the Playwright cache that no `browsers.json` references |
| `vacuum 100M` | `journalctl --vacuum-size` via `sudo -n` |

How `age` decides a child is inactive:

- activity is the newest file atime/mtime and folder mtime anywhere in its subtree;
- folder atime is ignored, because `du` updates it;
- a child that contains a mount point is always kept.

Edge cases, each decided on purpose:

- Listing a directory does not count as use, so `audit` and `space` never keep a cache
  alive. Opening any file inside an entry does.
- Symlinks count by their own times and are not followed.
- An entry with an unreadable directory or a name holding a newline is kept with a
  warning.
- Times more than a day in the future are ignored, so one bad clock does not pin an
  entry forever.
- On a `noatime` mount only writes count.

Design points worth copying:

- The parser takes the **last three** columns as policy/arg/auto, so paths may contain
  spaces.
- Any rule error (missing file, malformed line, unknown policy, bad arg such as `age 1w`
  or `keep-newest 0`) fails the whole run
  **before** anything is deleted. A silently skipped line is worse than a crash.
- Targets are listed one level deep (`find -mindepth 1 -maxdepth 1`), so whole cache
  subfolders are deleted, not single files.
- `clean` applies only `auto=yes` rules; `auto=no` rules run only with `--all`.
- `#` starts a comment anywhere on a line, and `|` is refused, so neither can appear in
  a path.
- A rule path that is itself a symlink is resolved to its target once, before the walk
  (`find` would otherwise not descend it and the rule would silently free nothing), so the
  guard judges the real directory. A protected name that is a symlink (`~/.config` pointing
  at another disk) is refused by its name instead.

### Deletion guard

Only `safe_rm` deletes anything, and it calls `is_protected` first. The protected list is
hardcoded in `lib/common.sh` and `rules.conf` cannot override it: `~/.ssh`, `~/.gnupg`,
`~/.config`, `~/.claude/projects/*/memory`, `~/scripts`, `~/work`, `~/tools`, every
single-letter Windows drive mount `/mnt/[a-z]` (not `/mnt/wsl` or `/mnt/wslg`), `/etc`.
`~/scripts`, `~/work` and `~/tools` are the author's own layout, kept as extra protection
that costs nothing if you have no such directory. Your layout does not need to match; to
protect a directory of your own, add it to `PROTECTED_PATTERNS` in `wsl/lib/common.sh`.

The guard rejects a path that:

- **equals** a protected path;
- **is under** a protected path;
- **contains** a protected path. Without this check a rule `/home purge` yields the target
  `/home/<user>`, which matches no pattern, and deletes `~/.ssh` with it. For patterns
  with `*` the check looks at the real filesystem: a project with `memory/` inside is
  protected, one without it is not.

The guard checks every target, not the rule root. `~ purge` would delete everything not
on the list: the list protects only what it names. `/` is refused by a separate
empty-target guard, and relative targets are refused too.

`safe_rm` also never deletes through a mount: a target that is itself a mount point is
refused (dry run included), and a mount nested deeper inside a target is skipped
(`rm --one-file-system`), which fails that rule and reports the leftover. Without this,
a Windows drive mounted under a cache directory had no `/mnt/` in its name for the
lexical guard to see, and `du -x` had counted none of it in the estimate. A bind mount on
the same device is not detected (the same limit as `age`'s `-xdev` walk).

A target the guard refuses fails only that rule: the others still run, `clean` prints its
`freed:` summary, then exits 1.

### pw-orphan

Each Playwright version pins its own Chromium revision, so upgrades leave orphans.
"Delete all but the newest" is wrong: another project may still pin an older one.

1. Find every `browsers.json` under the scan roots (`~/tools`, `~/.local`, `~/.nvm`,
   `~/.npm/_npx`, `~/.cache/ms-playwright-mcp`, plus `pw_scan_roots_extra`). `~/tools`
   is the author's default for where projects live; put your own project directories in
   `pw_scan_roots_extra` in `maint.conf`. A project outside every root looks
   unpinned, so the shipped rule is `auto=no` and runs only with `--all`.
2. Parse each as JSON and collect revisions of browsers whose name starts with
   `chromium`.
3. Delete only revisions nobody references.

Safety rules:

- The scan fails closed. Nothing is pruned that run if a `find` or `jq` step errors, a
  built-in root sits on an unmounted or empty `/mnt/<drive>`, a `pw_scan_roots_extra`
  directory is missing, or no `browsers.json` is found at all ("unknown", not "nothing
  needed"). Only a missing built-in root under `$HOME` is skipped.
- A missing folder from `pw_scan_roots_extra` blocks deletion because the user named it,
  and skipping it could delete what it holds.
- Do not grep every `"revision"`: that also picks up firefox/webkit revisions and only
  works while the number ranges happen not to overlap.
- `~/.npm/_npx` must be a scan root, or revisions used by `npx playwright` look orphaned.

### clean: counting what was freed

1. List each rule's targets once and size each one (the estimate).
2. Delete them.
3. **Measure each target again**: freed is what is no longer on disk.

The estimate is not the result: a target can be refused (guard), half deleted, or a vacuum
skipped (no sudo). Dry runs print `would free:`, real runs print `freed:`.

### docker

1. Use `docker` in WSL; if it does not answer, fall back to `docker.exe`. If neither
   answers, exit 1 and do not record a run, so an empty run never looks like success.
2. `docker builder prune -af`.
3. List dangling volumes. Without the opt-in (`--named-volumes` or
   `docker_named_volumes = yes`) keep and log every named one, leaving only anonymous
   (64-hex) names. With it, skip every name that matches the guard regex (plus
   `docker_guard_extra`). Print the rest and delete them only after `y` or with `--yes`.
   With no terminal and no `--yes` they are kept.

Why anonymous-only by default: under Docker Engine in WSL, `dangling=true` also lists
**named** volumes such as `db-data` as soon as their container is stopped, and Compose
names volumes `<project>_<name>`, which no fixed name list can predict. A name guard is a
blocklist, so it is the second line, not the first. It is per name, so one protected
volume does not cancel the prune of the others.

Images are never touched: usually all of them back live `docker-compose.yml` files, and
`image prune -a` would cost hours of rebuilds. `RECLAIMABLE` in `docker system df` means
"not attached to a running container", not "garbage".

### space

Read-only. The distro disk line is for maint.conf `distro` if set (the disk `compact`
acts on), else the distro it runs in. The disk is found almost the way `compact` finds it: the
WSL registry (`HKCU\...\Lxss`, read with `reg.exe` over interop), else (no entry, or
its path names no file) the Store package folder `*<distro>*` on `C:`
(`compact` does not glob when the registry entry exists, so on a stale Store copy the two
can disagree). Two matches are listed, not guessed between. "Used" comes
from `df /`, so for a distro other than the running one it shows as unknown.
"Slack" is file size minus used, an upper bound on what `compact` returns: Optimize-VHD
frees only vhdx blocks that are entirely unused, and ext4 leaves free space scattered
across partly used ones. On a 61 GB disk with 13 GB slack, one compact returned 4 GB.

### State

`logs/.state` holds `key=value` pairs: sizes for the `audit` delta and `lastrun.clean` /
`lastrun.docker` for `--if-stale`. A failed run does not write `lastrun`, so
`--if-stale` does not count it.

## Windows side

### maint.bat

- Self-elevates through UAC for every verb, even ones that need no admin, and returns
  the child's exit code.
- Runs with `-ExecutionPolicy Bypass`, because the repo path may count as remote and an
  unsigned `.ps1` there is blocked.
- Waits for a key at the end so a double-clicked window stays open, except with
  `-Unattended`.

Verbs that need admin: `backup`, `compact`, `full`, and `defender` without `-Verify`.

`-Unattended` is accepted by every verb and only skips the final `pause`, except on
`full` and `backup`, where it also answers the large-deletion gate. It does not avoid the
UAC prompt. `defender` refuses `-DryRun`: it has no dry run, and ignoring the switch
would add the exclusions for real. The reverse holds too: every other verb refuses
`-Verify` (`full -Verify` would otherwise back up and compact), and every verb but
`backup` and `full` refuses `-NoClean`.

### Config on both halves

`WSL_MAINT_CONFIG` set on Windows must name a file on a drive letter: the Windows side
hands it to every `wsl/maint` call as `--config /mnt/<drive>/...`, so both halves read
the same file and `docker_guard_extra` reaches the Docker prune. `maint.bat` forwards it
across the UAC relaunch (as the internal `-MaintConfig <path>`), since the elevated child
does not inherit the caller's environment. This, the `wsl/maint`
path and `backup_root` all assume drives mount at `/mnt/<letter>`; a different
`[automount] root` in `/etc/wsl.conf` breaks the mapping.

### backup

1. Preflight: `backup_root` set in `maint.conf`, the drive exists, zstd installed in the
   distro, at least 40 GB free.
2. `clean` inside the distro, behind the large-deletion gate (below). `-NoClean` skips
   this step, so a first backup holds the distro exactly as it was.
3. `sudo -n fstrim --all`.
4. `wsl --export Ubuntu <backup_root>\ubuntu_<date>.tar` (stops the distro).
5. `zstd -T0 -3 --rm` from inside WSL, through `/mnt/<drive>/...`.
6. `zstd -t` on the new archive.
7. Retention: keep the `keep` (default 3) newest `ubuntu_*.tar.zst`; the prefix is the
   distro name in lower case plus `_`.

The export covers the distro only. Docker Desktop keeps images and volumes in
`docker_data.vhdx`, which is compacted but never backed up; Docker Engine inside the
distro keeps them in `/var/lib/docker`, which is exported.

`full` runs `backup`, then `compact`. It never prunes Docker: it compacts
`docker_data.vhdx` but leaves its contents alone.

`backup -DryRun` does not create a missing backup directory and skips the in-distro
`zstd` check, but still requires `backup_root` and 40 GB free. It runs the clean preview
inside the distro, so it starts a stopped distro (not with `-NoClean`). `full -DryRun` also needs Hyper-V:
compact checks for `Optimize-VHD` before its own dry-run branch.

Why this order and these failure paths:

- **Verify before retention.** If the new archive is bad and retention already deleted
  the oldest good one, you have one good backup fewer. A failed check aborts the run and
  keeps every old archive.
- A failed archive is renamed to `.bad`, an unverified one to `.unverified`, so the next
  run's retention does not count them.
- If export fails, the partial `.tar` is deleted and retention never runs.
- If zstd fails, the uncompressed `.tar` stays: nothing is lost silently.
- If `zstd -t` cannot even start (the distro does not answer), the archive is
  "unverified", not "bad". The error message tells them apart.

### Large-deletion gate

Before the clean step, `backup` runs `maint clean --dry-run` and parses `would free:`.
`-NoClean` skips the clean, and with it the gate.

- Under 1 GB: continue.
- 1 GB or more: ask `Continue? [y/N]` (default no; only `y` or `yes`, any case, counts, the same rule as the `maint docker` volume prompt). With `-Unattended`: log
  "unattended: proceeding to free `<amount>`" and continue.
- Dry run failed or the amount did not parse: "unknown". It asks, and with `-Unattended`
  it **stops**. Unknown is never treated as safe.
- The prompt also appears under `backup -DryRun`, because the preview runs whenever the clean does. The
  real clean then also gets `--dry-run`, so nothing is deleted whatever you answer.

### compact

1. Find the distro vhdx and Docker's
   (`%LOCALAPPDATA%\Docker\wsl\disk\docker_data.vhdx`). The distro disk comes from the WSL
   registry (`HKCU\...\Lxss`, the entry whose `DistributionName` is `distro`, its
   `BasePath`), so `wsl --import` distros are found too. Only without a registry entry
   does it glob `%LOCALAPPDATA%\Packages\*<distro>*\LocalState\ext4.vhdx`. Two distro
   disks: error with the list, never a random pick. None found: warn and compact what was
   found. `defender` uses the same lookup; with no distro disk it warns, excludes the
   rest, and its summary says the disk is not excluded (exit 0, like compact).
2. `wsl --shutdown`, then **poll `wsl -l --running -q`** until empty (60 s timeout). The
   VM holds the vhdx for a few seconds after `--shutdown`.
3. `Optimize-VHD -Mode Full` on each disk, print "before -> after".

Needs the Hyper-V PowerShell module (not on Windows Home).

Sparse VHD (`wsl --manage <distro> --set-sparse true`) is not used. It is still
experimental, with open corruption reports
([microsoft/WSL#10609](https://github.com/microsoft/WSL/issues/10609),
[#41837](https://github.com/microsoft/WSL/issues/41837), a sparse disk corrupted when
the host drive filled up), and Docker's vhdx
is not a WSL distro and gets no sparse support. The distro root mounts with `discard`, so
freed blocks are trimmed online and `Optimize-VHD` reclaims them. Close Docker Desktop first, or
it restarts its distro and holds a handle on `docker_data.vhdx`: the run fails with a
sharing violation. No data is damaged; close Docker Desktop and retry.

### Other verbs

- `winclean`: `%TEMP%`, `%LOCALAPPDATA%\Temp` (deduplicated when they coincide) and the
  Recycle Bin, with free space on C: before and after.
- `defender`: adds Defender exclusions for the vhdx files and WSL/Docker processes
  (`wslservice.exe`, `com.docker.backend.exe` and others), which speeds up I/O
  noticeably. Processes are excluded by full image path, resolved at run time from
  `%ProgramFiles%\WSL`, `%SystemRoot%\System32` and `%ProgramFiles%\Docker\Docker`
  only (never PATH or a running process, which a user can plant). A bare name would
  match a process of that name in any folder. A process not found there is skipped
  with a warning. `vmmem`/`vmmemWSL` are not excluded: they have no image on disk, and
  the vhdx path exclusions already cover the VM disk. `-Verify` only checks, and flags
  bare-name exclusions an older version added, with the `Remove-MpPreference` command
  for each; it never removes them.
- Every run logs to `logs/maint-<date>.log`.

## Pitfalls

Each of these was a real bug once.

1. **`wsl.exe -d X -- cmd` does not read `~/.profile` or `~/.bashrc`.** `~/.local/bin`
   is not on PATH, so a bare `maint` gives "command not found". From Windows always call
   the absolute path.
2. **The exit code is the contract between the halves.** `Invoke-Wsl` treats only 0 as
   success, so the bash side must return non-zero on every real problem. Bash can
   swallow a failure in four ways:
   - `while ...; done < <(cmd)` loses the status of `cmd`. Use `x=$(cmd) || return 1`,
     then `<<< "$x"`;
   - `cmd | other || true`;
   - a loop's status is its last iteration's. Add `|| rc=1` to each one;
   - an `echo` after `|| log_warn`.

   Test the exit code with broken input, not by reading the output.
3. **PowerShell 5.1 + `$ErrorActionPreference = 'Stop'` + native stderr** gives a
   terminating error even when the program exits 0. Around `wsl.exe` calls that write to
   stderr, switch to `Continue` and check `$LASTEXITCODE`.
4. **Probe the operation, not a proxy.** The journal vacuum used to probe `sudo -n true`.
   A correct sudoers grant allows only `journalctl --vacuum-size=100M`, not `true`, so the
   probe said "no sudo" exactly where sudo was set up right. Now the real command runs and
   a sudo refusal goes to the log.
5. **Locale.** With a comma decimal separator, `journalctl --disk-usage` prints `514,2M`
   and the parser read only `2M`. Set `LC_ALL=C` and accept a comma. PowerShell
   `"{0:N2}"` also gives `0,00 GB`, so `Format-Gb` formats with InvariantCulture.
6. **`wsl -l` outputs UTF-16LE** with NUL bytes. Strip them with `-replace "`0", ''`, or
   string comparisons fail silently.
7. **Cron in WSL does not catch up.** At night WSL is usually not running and the slot
   just never fires. If you automate, use a daytime slot plus `@reboot ... --if-stale 7`.
8. **`npx playwright install` deletes other projects' browser revisions by default.**
   Use `PLAYWRIGHT_SKIP_BROWSER_GC=1`. General rule: delete a cache only once you have
   proven nobody needs it.

## Tests

`bash tests/run.sh` runs `tests/test_*.sh` and, when `powershell.exe` is available,
`tests/win/Run.ps1`. Under CI (`CI` set) a Windows half that did not run is a failure
unless `WSL_MAINT_SKIP_WIN=1` is set. One limit: PowerShell tests
replace `wsl.exe`, `Optimize-VHD`, `Read-Host` and similar with functions, which proves
the logic (branches, order, what was deleted and what survived) but not native stream
behaviour (stdout/stderr order, UTF-16LE). That is still checked by hand with `-DryRun`
against the real binaries. The exception is pitfall 3, covered by
`Test-BackupConsentNative.ps1`: it compiles a real console program
(`tests/win/FakeExe.ps1`) and puts it first on `PATH` as `wsl.exe`.

## Building your own

Minimum viable version, in order of importance:

1. **`safe_rm` plus a protected list** checked three ways (equals / under / contains).
   Write nothing else before this.
2. **A rules file** with 3-4 policies (`purge`, `age`, `keep-newest`) and `--dry-run`.
   Fail on a malformed file.
3. **`audit`**, to see what grows before you automate deletion.
4. **A Windows wrapper for export + compact**, with verify before retention and a wait
   for WSL to really stop.
5. Then as needed: Docker with a guard, pw-orphan, the large-deletion gate, Defender.

To adapt it, copy `maint.conf.example` to `maint.conf` (no code changes needed), adjust
`PROTECTED_PATTERNS` in `wsl/lib/common.sh` if your protected list differs, and put your
own caches in `rules.conf` (start from `maint audit` or `du -xh -d2 ~ | sort -h`).

Dependencies: inside WSL bash, GNU coreutils (`du -b`, `numfmt`, `tail -z`) and findutils
(`find -printf`), `jq`, `zstd`. On Windows PowerShell
5.1 and the Hyper-V module for `Optimize-VHD` (Pro/Enterprise only). On Home,
`diskpart compact vdisk` might work, but that path is untested.
