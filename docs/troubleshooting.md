# wsl-maint: troubleshooting, limits, uninstall

Back to the [README](../README.md). Design and failure paths: [how-it-works.md](how-it-works.md).

## Troubleshooting

- **`maint: command not found` through `wsl.exe`.** `wsl.exe -d <distro> --` does not
  source `~/.profile`, so `~/.local/bin` is not on `PATH`. Call `wsl/maint` by its
  absolute path, as the Windows half does.
- **Sharing violation on `docker_data.vhdx` during `compact`.** Docker Desktop restarted
  its distro after the shutdown and holds the disk. Nothing is corrupted: quit Docker
  Desktop and rerun.
- **"Optimize-VHD is unavailable".** The Hyper-V PowerShell module is missing (always
  the case on Windows Home). `full -DryRun` stops here too; use `backup -DryRun`.
- **"journal vacuum skipped" or "fstrim skipped".** No passwordless sudo for that
  command. Grant it with `sudo visudo -f /etc/sudoers.d/wsl-maint`, using the paths
  `command -v journalctl fstrim` prints:

  ```text
  youruser ALL=(root) NOPASSWD: /usr/bin/journalctl, /usr/sbin/fstrim
  ```

  A grant pinned to an exact argument (`journalctl --vacuum-size=100M`) stops matching
  when the size in `rules.conf` changes.
- **"volumes kept: no terminal to confirm".** `maint docker` ran without a terminal and
  without `--yes`. Run it interactively, or add `--yes` after setting
  `docker_guard_extra`.
- **"playwright scan incomplete; skipping orphan prune".** A scan root is missing or
  unreadable. Fix or remove the root named in the warning.
- **An archive ends in `.unverified`.** The distro did not answer the `zstd -t` check.
  Run `zstd -t` on it yourself, then rename it back to `.tar.zst`. A `.bad` archive is
  corrupt.
- **`[FAILED] exit N - see logs\ for details`.** The reason is the last line of the
  newest `logs\maint-*.log`.
- **Running the PowerShell scripts by hand.** Use `-ExecutionPolicy Bypass`, as
  `maint.bat` does: the repo may sit on a path PowerShell treats as remote.

## Known limits

- `compact` needs the Hyper-V PowerShell module, so it does not work on Windows Home.
- `compact` and `defender` find the distro disk through the WSL registry, else the Store
  package folder; if several disks match they refuse and list them.
- `maint space` reports the disk of maint.conf `distro`, else of the distro it runs in,
  found almost like `compact` finds it (a registry path that names no file falls back
  to the Store package glob here, where `compact` says not found). It needs `reg.exe`
  over WSL interop for that; without it only a Store package disk on `C:` is found. "Used" is unknown when the
  configured distro is not the one `space` runs in.
- `backup_root` must be a local drive path (`X:\...`); UNC and relative paths are refused.
- Drive letters must mount at `/mnt/<letter>` inside WSL. A different `[automount] root`
  in `/etc/wsl.conf` is not supported.
- Sparse VHD is not used; [how-it-works.md](how-it-works.md) explains why.

## Uninstall and revert

1. Defender exclusions. `maint.bat defender` adds these, and there is no remove verb:
   your distro's `ext4.vhdx`, `%LOCALAPPDATA%\Docker\wsl\disk\docker_data.vhdx`, and
   the full image paths of `wsl.exe`, `wslservice.exe`, `wslhost.exe` (under
   `%ProgramFiles%\WSL`, plus `%SystemRoot%\System32\wsl.exe`) and
   `com.docker.backend.exe`, `com.docker.service`, `dockerd.exe`, `docker.exe` (under
   `%ProgramFiles%\Docker\Docker`). `maint.bat defender -Verify` prints the exact paths.
   To remove them, from an elevated PowerShell. This removes the exclusion whoever added
   it: if you had any of these before running `defender`, they go too. Check
   `Get-MpPreference` first and skip the ones you want to keep:

   ```powershell
   $pf = $env:ProgramFiles
   Remove-MpPreference -ExclusionProcess "$pf\WSL\wsl.exe","$pf\WSL\wslservice.exe","$pf\WSL\wslhost.exe","$env:SystemRoot\System32\wsl.exe","$env:SystemRoot\System32\wslservice.exe","$env:SystemRoot\System32\wslhost.exe","$pf\Docker\Docker\resources\com.docker.backend.exe","$pf\Docker\Docker\com.docker.service","$pf\Docker\Docker\resources\dockerd.exe","$pf\Docker\Docker\resources\bin\docker.exe"
   Remove-MpPreference -ExclusionPath "$env:LOCALAPPDATA\Docker\wsl\disk\docker_data.vhdx"
   Remove-MpPreference -ExclusionPath '<path to your ext4.vhdx>'
   ```

   Older versions added bare names (`vmmemWSL`, `vmmem`, `wsl.exe`, `docker.exe` and the
   rest), which Defender matches in any folder. `-Verify` lists any still present with
   the `Remove-MpPreference -ExclusionProcess '<name>'` command for each.
2. Remove any cron lines you added, and the symlink: `rm ~/.local/bin/maint`.
3. Delete the repo directory. `maint.conf`, the logs and the state file all live inside
   it. Backup archives in `backup_root` are not touched.
