# Shared helpers for the Windows side. Dot-sourced by maint.ps1.

$script:MaintRepoRoot = Split-Path -Parent $PSScriptRoot

function Get-MaintConfig {
    # Reads maint.conf (repo root, or $env:WSL_MAINT_CONFIG) as DATA: one
    # `key = value` per line, `#` comment lines and blank lines skipped, the
    # value taken literally after trimming. Nothing in it is ever evaluated.
    # The WSL side (wsl/lib) parses the same file with the same rules.
    $cfg = @{
        Distro         = 'Ubuntu'
        BackupRoot     = $null
        Keep           = 3
        # Days a file of app junk must be untouched before winclean deletes it.
        WinCleanAge    = 14
        # Owner app-junk patterns (winclean_extra), added to WinClean.ps1's own.
        WinCleanExtra  = @()
        RepoRoot       = $script:MaintRepoRoot
        # Full path of the WSL_MAINT_CONFIG file, $null for the repo-root one.
        # Get-MaintWslArgs hands it to wsl/maint, which would otherwise read
        # the repo-root file and miss e.g. docker_guard_extra.
        ConfigOverride = $null
    }

    # An explicit override that points nowhere is reported, not quietly
    # replaced by defaults; only the implicit repo-root file is optional.
    $file = $env:WSL_MAINT_CONFIG
    if ($file) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            throw "WSL_MAINT_CONFIG points at a file that does not exist: $file"
        }
        $file = (Resolve-Path -LiteralPath $file).ProviderPath
        $cfg.ConfigOverride = $file
    } else {
        $file = Join-Path $script:MaintRepoRoot 'maint.conf'
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $cfg }
    }

    # -Encoding UTF8: without it Windows PowerShell 5.1 decodes a BOM-less
    # file with the ANSI code page, while the WSL side reads UTF-8 bytes.
    # Notepad (since Windows 10 1903) and VS Code write UTF-8 without a BOM,
    # so a non-ASCII backup_root became a different, mojibake path on this
    # half: the archives went there and `maint verify` never found them.
    # PS 5.1's UTF8 reader honours (and strips) a BOM when there is one.
    $n = 0
    foreach ($raw in @(Get-Content -LiteralPath $file -Encoding UTF8)) {
        $n++
        $at = "${file}:$n"
        # A BOM is what Notepad and PS 5.1's UTF8 encoding put in front of line 1.
        $line = $raw.TrimStart([char]0xFEFF).Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        $eq = $line.IndexOf('=')
        if ($eq -lt 0) { throw "${at}: expected 'key = value', got: $line" }
        $key = $line.Substring(0, $eq).Trim()
        $value = $line.Substring($eq + 1).Trim()
        if ($key -eq '') { throw "${at}: missing key before '='" }
        switch -CaseSensitive ($key) {
            'distro' {
                # Ends up in archive file names and a Get-ChildItem -Filter, so
                # held to the characters WSL itself allows in a distro name.
                if ($value -ne '' -and $value -notmatch '^[A-Za-z0-9._-]+$') {
                    throw "${at}: distro may only contain letters, digits, '.', '_' and '-', got: $value"
                }
                if ($value -ne '') { $cfg.Distro = $value }
            }
            'backup_root' { if ($value -ne '') { $cfg.BackupRoot = $value } }
            'keep' {
                # Feeds Select-Object -Skip in retention: 0 would delete every
                # archive, the one just made included.
                if ($value -ne '') {
                    # Length checked before the cast, leading zeros aside, so a
                    # value too big for Int64 gets this message, not a cast error.
                    # wsl/lib/config.sh applies the same rule.
                    $digits = $value.TrimStart('0')
                    if ($value -notmatch '^[0-9]+$' -or $digits.Length -gt 4 -or [int64]$value -lt 1 -or [int64]$value -gt 1000) {
                        throw "${at}: keep must be a whole number from 1 to 1000, got: $value"
                    }
                    $cfg.Keep = [int]$value
                }
            }
            'winclean_age' {
                # The age gate on what winclean deletes from %LOCALAPPDATA%: 0
                # would take a crash report still being written. Checked like
                # keep, length before the cast; wsl/lib/config.sh applies the
                # same rule and message.
                if ($value -ne '') {
                    $digits = $value.TrimStart('0')
                    if ($value -notmatch '^[0-9]+$' -or $digits.Length -gt 4 -or [int64]$value -lt 1 -or [int64]$value -gt 3650) {
                        throw "${at}: winclean_age must be a whole number from 1 to 3650, got: $value"
                    }
                    $cfg.WinCleanAge = [int]$value
                }
            }
            'winclean_extra' {
                # Owner app-junk patterns, `|`-separated, each relative to
                # %LOCALAPPDATA% like the built-in ones; what they match is
                # deleted. So a drive, a leading `\` (rooted or UNC), a `..`
                # segment or an empty one fails the load before winclean runs:
                # only a path the walk can reach from %LOCALAPPDATA% is a
                # pattern. `/` is read as `\`, and spaces around `|` dropped.
                # wsl/lib/config.sh only knows the key.
                if ($value -ne '') {
                    $patterns = @($value -split '\|' | ForEach-Object { $_.Trim().Replace('/', '\') })
                    foreach ($pat in $patterns) {
                        if ($pat.Contains(':') -or @($pat -split '\\' | Where-Object { $_ -eq '' -or $_ -eq '..' }).Count -gt 0) {
                            throw "${at}: winclean_extra patterns must be relative to %LOCALAPPDATA%, without a drive, a leading '\', a '..' or an empty segment, got: $value"
                        }
                    }
                    $cfg.WinCleanExtra = $patterns
                }
            }
            # Read by the WSL side only; accepted here so one file serves both.
            'docker_guard_extra'  { }
            'docker_named_volumes' {
                # Used by the WSL side only, but validated here too, with the
                # same rule and message as wsl/lib/config.sh: an opt-in to
                # pruning data, so a typo must not read as either answer.
                if ($value -ne '' -and $value -cnotmatch '^(yes|no)$') {
                    throw "${at}: docker_named_volumes must be yes or no, got: $value"
                }
            }
            'pw_scan_roots_extra' { }
            default { throw "${at}: unknown key '$key'" }
        }
    }
    $cfg
}

function Assert-LocalDrivePath {
    param([Parameter(Mandatory)][string]$WindowsPath, [string]$What = 'path')
    if ($WindowsPath -notmatch '^[A-Za-z]:[\\/]') {
        throw "$What must be a local drive path (X:\...), got: $WindowsPath"
    }
}

function ConvertTo-WslPath {
    # "D:\backups\wsl-ubuntu\ubuntu_x.tar" -> "/mnt/d/backups/wsl-ubuntu/ubuntu_x.tar".
    # Same "X:\ is always /mnt/x" assumption the rest of this repo makes (the
    # WSL side converts backup_root by the same rule), so anything else (UNC,
    # relative) is refused rather than silently mangled.
    param([Parameter(Mandatory)][string]$WindowsPath, [string]$What = 'path')
    Assert-LocalDrivePath $WindowsPath -What $What
    # ToLowerInvariant: .ToLower() follows the user's culture, and tr-TR maps
    # I to dotless i, so I:\ became /mnt/<dotless i> and every WSL call failed.
    "/mnt/" + $WindowsPath.Substring(0, 1).ToLowerInvariant() + $WindowsPath.Substring(2).Replace('\', '/')
}

function Get-LxssDistroEntries {
    # Every distro WSL has registered for this user: one subkey per distro
    # under HKCU:\...\Lxss, carrying DistributionName, BasePath (the disk's
    # folder) and, on some installs, VhdFileName. The only registry read in
    # this repo, kept separate so tests can shadow it.
    $root = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    if (-not (Test-Path -LiteralPath $root)) { return }
    Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | ForEach-Object {
        $p = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
        if ($p -and $p.DistributionName) {
            [pscustomobject]@{
                DistributionName = [string]$p.DistributionName
                BasePath         = [string]$p.BasePath
                VhdFileName      = [string]$p.VhdFileName
            }
        }
    }
}

function Get-DistroVhdxPath {
    # The distro's disk. The registry (Get-LxssDistroEntries) is asked first:
    # the entry whose DistributionName equals the configured distro
    # (case-insensitive) gives BasePath, minus any \\?\ long-path prefix,
    # plus VhdFileName or the default ext4.vhdx. That covers `wsl --import`
    # disks anywhere on the box and names that differ from the Store package.
    # A registered distro whose disk is missing is $null, not a glob guess.
    # Only when no entry matches does the old lookup run: a Store package
    # folder containing the distro name (CanonicalGroupLimited.Ubuntu_...)
    # with LocalState\ext4.vhdx. $null when nothing is found, and the caller
    # says so. Two matches throw: acting on whichever enumerated first is a
    # guess. Shared by compact and defender so they always agree.
    param([Parameter(Mandatory)][string]$Distro, [string]$Purpose = 'use')
    $entries = @(Get-LxssDistroEntries | Where-Object { $_.DistributionName -eq $Distro })
    if ($entries.Count -gt 0) {
        $disks = @($entries | Where-Object { $_.BasePath } | ForEach-Object {
            $base = [string]$_.BasePath
            if ($base.StartsWith('\\?\UNC\')) { $base = '\\' + $base.Substring(8) }
            elseif ($base.StartsWith('\\?\')) { $base = $base.Substring(4) }
            $file = if ($_.VhdFileName) { [string]$_.VhdFileName } else { 'ext4.vhdx' }
            # Not Join-Path: it throws on a drive that is not there (an
            # unplugged disk an import went to), which under Stop would abort
            # the caller instead of reporting the disk as not found.
            [System.IO.Path]::Combine($base, $file)
        } | Where-Object { Test-Path -LiteralPath $_ })
    } else {
        $disks = @(Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'Packages') -Directory -Filter "*$Distro*" -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'LocalState\ext4.vhdx' } |
            Where-Object { Test-Path -LiteralPath $_ })
    }
    if ($disks.Count -gt 1) {
        throw ("More than one $Distro disk found; refusing to guess which to ${Purpose}:`n  " + ($disks -join "`n  "))
    }
    if ($disks.Count -eq 1) { $disks[0] } else { $null }
}

function Get-MaintWslBin {
    # The WSL-side entry point, this repo's own wsl\maint as WSL sees it. Still
    # an absolute path, never a bare "maint": WSL's non-interactive interop
    # shell never sources ~/.profile or ~/.bashrc, so ~/.local/bin is not on
    # PATH there and a bare "maint" fails with "command not found". The script
    # is mode 100755 and resolves its own location, so calling it by absolute
    # path works from any clone. That is also why the repo has to live on a
    # drive letter: WSL reaches it through /mnt/<drive>.
    ConvertTo-WslPath -WindowsPath (Join-Path $script:MaintRepoRoot 'wsl\maint') -What 'the repo (so WSL can reach wsl\maint)'
}

function Get-MaintWslArgs {
    # wsl.exe arguments that run wsl/maint <Verb> in the configured distro.
    # When the config came from WSL_MAINT_CONFIG, the same file goes along as
    # --config <WSL path>, so both halves read one file. A path WSL cannot
    # reach (UNC, relative) throws here rather than silently splitting them.
    # --exec, not --: wsl.exe hands everything after -- to `$SHELL -c` as one
    # string, so the repo path and the config path would reach a Linux shell
    # unescaped. --exec runs the program directly with each argument as argv.
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Verb)
    $wslArgs = @('-d', $Config.Distro, '--exec', (Get-MaintWslBin), $Verb)
    if ($Config.ConfigOverride) {
        $wslArgs += @('--config', (ConvertTo-WslPath -WindowsPath $Config.ConfigOverride -What 'WSL_MAINT_CONFIG'))
    }
    $wslArgs
}

function Write-MaintLog {
    param(
        [ValidateSet('info', 'warn', 'err')][string]$Level = 'info',
        [Parameter(Mandatory)][string]$Message
    )
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$stamp][$Level] $Message"
    switch ($Level) {
        'err'  { Write-Host $line -ForegroundColor Red }
        'warn' { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line }
    }
    $logDir = Join-Path $script:MaintRepoRoot 'logs'
    # -LiteralPath: a repo under a bracketed dir must still log. New-Item has
    # no -LiteralPath, and needs none: its -Path is not wildcard-expanded.
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $logFile = Join-Path $logDir ("maint-" + (Get-Date -Format 'yyyy-MM-dd') + ".log")
    Add-Content -LiteralPath $logFile -Value $line
}

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This command needs an elevated shell. Run maint.bat instead."
    }
}

function Invoke-WslNoThrow {
    # Runs wsl.exe and leaves its exit code in $LASTEXITCODE; never throws on
    # its own. For the callers that read the exit code themselves (zstd, the
    # liveness probe, fstrim); Invoke-Wsl below is the throwing variant.
    #
    # 'Continue' for just the native call (pitfall 3 in docs/how-it-works.md).
    # Under 'Stop', PS 5.1 turns a wsl.exe stderr line into a terminating
    # NativeCommandError whenever it redirects the child's stderr: with 2>&1,
    # and also when powershell.exe's own stderr is a file or pipe (an elevated
    # prompt or task running `maint.bat full -Unattended > log 2>&1`).
    # wsl/maint logs every [info] line to stderr, so the proxy verbs and
    # backup's clean step threw on the first line of a successful run there.
    # The exit code decides; output still flows through.
    param([Parameter(Mandatory)][string[]]$Arguments)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & wsl.exe @Arguments
    } finally {
        $ErrorActionPreference = $prevEap
    }
}

function Invoke-Wsl {
    param([Parameter(Mandatory)][string[]]$Arguments)
    Write-MaintLog -Message ("wsl " + ($Arguments -join ' '))
    Invoke-WslNoThrow $Arguments
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        throw ("wsl exited " + $code + ": wsl " + ($Arguments -join ' '))
    }
}

function Get-FreeSpaceGb {
    param([Parameter(Mandatory)][string]$DriveLetter)
    # Get-PSDrive wants a bare letter ('D'), not a qualifier ('D:'); accept either
    # so callers that pass Split-Path -Qualifier output verbatim do not crash.
    [math]::Round((Get-PSDrive $DriveLetter.TrimEnd(':')).Free / 1GB, 2)
}

function Format-Gb {
    param([Parameter(Mandatory)][long]$Bytes)
    # InvariantCulture and no grouping: the same "2048.00 GB" on any console,
    # so a size can be parsed back out of logs\maint-*.log.
    ($Bytes / 1GB).ToString('F2', [Globalization.CultureInfo]::InvariantCulture) + ' GB'
}

function Format-Mb {
    # Format-Gb's rule at MB scale, for winclean's app junk: a crash dump of a
    # few MB would read as 0.00 GB.
    param([Parameter(Mandatory)][long]$Bytes)
    ($Bytes / 1MB).ToString('F1', [Globalization.CultureInfo]::InvariantCulture) + ' MB'
}

function Test-MaintConsent {
    # The one consent rule, shared with wsl/lib/common.sh is_consent: "y" or
    # "yes" in any case, surrounding whitespace ignored. Anything else ($null
    # from a closed stdin, empty, "yeah", "n") is a refusal.
    param([AllowNull()][string]$Answer)
    return ("$Answer".Trim() -match '^(y|yes)$')
}
