# wsl-maint

[![CI](https://github.com/tegos/wsl-maint/actions/workflows/test.yml/badge.svg)](https://github.com/tegos/wsl-maint/actions/workflows/test.yml)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

**Clean WSL2 caches, back the distro up, and give the freed space back to Windows.**

<img src="assets/demo.webp" alt="wsl-maint demo" width="800">

Deleting files inside WSL does not shrink the virtual disk on `C:`. A distro disk that
grew to 80 GB stays 80 GB until it is compacted. wsl-maint cleans caches inside the
distro, prunes the Docker build cache and dangling volumes, exports the distro to a
`zstd`-compressed backup, and compacts the distro disk (`ext4.vhdx`) and the Docker disk
(`docker_data.vhdx`) with `Optimize-VHD`.

Looking is safe: `maint audit` and every `--dry-run` / `-DryRun` delete nothing. Read up
before running `backup` (its export stops the distro: every shell and process inside it
dies), `full` and `compact` (they shut WSL down) and `maint docker --named-volumes` (it can
remove named volumes, see [Safety](#safety)).

Two halves share one config file. The Windows half (`maint.bat` around `maint.ps1`) does
whatever stops the VM or needs admin: backup, compact, Defender exclusions, `%TEMP%`
cleanup. The WSL half (`wsl/maint`, bash) does cache cleanup, Docker prune, audit and
backup verification. Why the split: [docs/how-it-works.md](docs/how-it-works.md).

## Requirements

- WSL2, any distro. Windows PowerShell 5.1 (the built-in `powershell.exe`).
  `maint space` finds the distro disk through the WSL registry (`reg.exe` over interop),
  so imported distros and disks off `C:` work; without interop it falls back to the
  Store package folder.
- Inside the distro: GNU coreutils and findutils (what Debian, Ubuntu, Fedora and openSUSE
  ship; a busybox-based distro such as Alpine needs `apk add coreutils findutils`), plus
  `jq` and `zstd`.
- Admin for `full`, `backup`, `compact` and `defender`; `maint.bat` asks through UAC.
- The Hyper-V PowerShell module for `compact` and `full` (Windows Home lacks it;
  everything else works there).
- Docker is optional. Without it only `maint docker` is unavailable.
- Optional: passwordless `sudo` for `journalctl` and `fstrim`, else those steps are
  skipped with a warning.

## Quick start

1. Clone onto a Windows drive, not inside the distro: after `wsl --shutdown` a script
   under `\\wsl$\...` is unreachable from Windows.

   ```bat
   git clone https://github.com/tegos/wsl-maint D:\tools\wsl-maint
   ```

2. Inside WSL, install the dependencies and a `maint` command (open a new shell after):

   ```bash
   sudo apt install -y jq zstd
   mkdir -p ~/.local/bin
   ln -s /mnt/d/tools/wsl-maint/wsl/maint ~/.local/bin/maint
   ```

3. Copy `maint.conf.example` to `maint.conf`. Set `backup_root`, and `distro` if yours
   is not `Ubuntu`.

4. Look before deleting anything:

   ```bash
   maint audit
   maint clean --dry-run
   maint docker --dry-run
   ```

   On Windows, from an elevated cmd: `maint.bat backup -DryRun` (needs `backup_root` and
   40 GB free there).

5. Take a first backup before anything is deleted. Close anything running inside the
   distro first: the export stops it. `backup` normally cleans first; `-NoClean` exports
   the distro as it is:

   ```bat
   maint.bat backup -NoClean
   ```

   Docker Desktop volumes live outside the distro and are not in this archive.

6. Review `rules.conf`, quit Docker Desktop, then run `maint.bat full`.

## Configuration

`maint.conf` (repo root, gitignored) is read by both halves: `key = value`, `#`
comments, parsed, never executed. An unknown key stops every command with `file:line`.
`maint.conf.example` lists every key.

| key | default | what it controls |
|---|---|---|
| `distro` | `Ubuntu` | the distro to back up, compact and run commands in |
| `backup_root` | none | Windows directory for archives (`X:\...`); needed by `backup`, `full`, `maint verify` |
| `keep` | `3` | archives retained (1 to 1000) |
| `docker_guard_extra` | empty | extra volume name patterns never pruned, `\|`-separated regex |
| `docker_named_volumes` | `no` | `yes` = `maint docker` prunes named dangling volumes too, like `--named-volumes` |
| `pw_scan_roots_extra` | empty | extra dirs scanned for Playwright pins, `:`-separated |

`docker_guard_extra` matches anywhere in the name, so `myapp` guards `myapp_db` and
`myapp_cache`. It applies to named volumes, so set it before your first
`maint docker --named-volumes --yes`. Put your project dirs in
`pw_scan_roots_extra` so the browsers they pin are not treated as orphans. The
Playwright rule is `auto=no` for that reason: it runs only with `--all`.

## Usage

```text
maint.bat full        clean -> fstrim -> export -> zstd -> verify -> retention -> shutdown -> Optimize-VHD
maint.bat backup      same, without the compact
maint.bat compact     wsl --shutdown, then Optimize-VHD only
maint.bat winclean    empty Windows %TEMP%, %LOCALAPPDATA%\Temp and the recycle bin
maint.bat defender    add Defender exclusions for the WSL/Docker disks and processes
maint.bat audit|clean|docker   run the WSL verb (better: run it inside WSL, no UAC)
```

Flags: `-DryRun` (all but `defender`, which has `-Verify` instead) and `-Unattended`
(skips the final keypress; on `backup` and `full` it answers yes to the large-deletion
prompt, and aborts when the amount to free is unknown; UAC still asks), plus
`-NoClean` on `backup` and `full` (export without cleaning first). From a
non-elevated cmd it reopens in an admin window that waits for a key at the end
(not with `-Unattended`); run from an elevated cmd to keep the output in the window
you started from. Logs go to `logs\maint-*.log`.

```text
maint audit              per-rule size, what each rule would free, change since last audit
maint space              what fills the disks: vhdx size vs data, biggest dirs, Docker usage
maint clean              apply the auto=yes rules from rules.conf
maint clean --all        also apply the auto=no rules
maint docker             prune the build cache; anonymous dangling volumes after a y
maint docker --yes       same, without asking
maint docker --named-volumes   named dangling volumes too, minus the guarded names
maint verify             zstd -t the newest archive in backup_root
```

Flags: `--dry-run`, `--if-stale <days>`, `--rules <file>`, `--config <file>`; `maint
help` lists them all. Exit codes: 0 success, 1 failure, 2 usage or config error.

## What it deletes

Only when you run the verb that does it:

- Cache entries listed in `rules.conf` (`maint clean`).
- The Docker build cache and anonymous dangling volumes (`maint docker`); named dangling
  volumes outside the guard only with `--named-volumes` or `docker_named_volumes = yes`.
- Windows `%TEMP%` and `%LOCALAPPDATA%\Temp` (normally the same directory) and the recycle
  bin (`maint.bat winclean`).
- This tool's own archives beyond the newest `keep`.

Never: Docker images, named volumes without the opt-in, volumes matching the guard
(`db-data`, `mysql`, `_data`, `postgres`, `pgdata`, `mongo`, `redis` and similar, plus
`docker_guard_extra`) even with it, or the protected paths (`~/.ssh`, `~/.gnupg`,
`~/.config`, `/etc`, every Windows drive `/mnt/<letter>` and the author's own defaults in
`PROTECTED_PATTERNS`, `wsl/lib/common.sh`; edit them to fit your layout).

The shipped `rules.conf` reflects the author's machine, so review it first. One line per
rule:

```text
~/.cache/whatever      age    30d    yes
```

| policy | deletes |
|---|---|
| `purge` | every direct child of the directory |
| `age <Nd>` | top-level entries untouched for N days |
| `keep-newest <N>` | all but the N newest entries |
| `pw-orphan` | Playwright browser revisions nothing references |
| `vacuum <size>` | `journalctl --vacuum-size` through `sudo -n` |

The last column is `yes` (runs on plain `maint clean`, for caches that come back on
their own) or `no` (only with `--all`, for logins, models, tokens). Test a new rule
with `maint clean --dry-run`. A bad arg (`age 1w`, `keep-newest 0`, `vacuum 100m`) fails the run before anything is deleted.

## Safety

- **The path guard checks each path, not the rule's root.** A rule `~ purge` would still
  delete `~/.bashrc`. The protected list protects what it names, nothing more.
- **`--named-volumes` prunes named dangling volumes.** Under Docker Engine in WSL,
  `db-data` is dangling the moment its container stops, and Compose names a `mysql_data:`
  volume `<project>_mysql_data`. Without the opt-in only anonymous (64-hex) volumes go and
  the named ones are logged as kept. With it, set `docker_guard_extra` first.
- **Docker images are out of scope.** "RECLAIMABLE" in `docker system df` does not mean
  safe to delete. `full` never prunes Docker.
- **The new backup is verified before retention deletes the oldest.**
- **Large deletions ask first.** `full` and `backup` prompt when the clean would free
  1 GB or more.
- **`defender` excludes processes by full path** (`%ProgramFiles%\WSL\wsl.exe`, not
  `wsl.exe`), so a same-named file elsewhere is still scanned. `-Verify` flags bare-name
  entries left by older versions.

Every guard and failure path: [docs/how-it-works.md](docs/how-it-works.md). Errors,
limits and uninstall: [docs/troubleshooting.md](docs/troubleshooting.md).

## Scheduling

Nothing is scheduled by the tool. Cron in WSL only fires while WSL runs, so pair a
daytime slot with `@reboot ... --if-stale`:

```cron
0 13 * * 0   $HOME/.local/bin/maint clean
@reboot      $HOME/.local/bin/maint clean --if-stale 7
0 13 * * 0   $HOME/.local/bin/maint docker
```

Without a terminal and `--yes`, `maint docker` keeps the volumes. Keep `backup` and `full`
manual: they stop the distro, and `full` shuts WSL down.

## Tests

```bash
bash tests/run.sh
```

Runs the bash suite and, when `powershell.exe` is available, the PowerShell suite.
Hermetic: no test touches the real VM, backups or Defender. Enable the pre-commit hook
with `git config core.hooksPath .githooks`.

## License

MIT, see [LICENSE](LICENSE).
