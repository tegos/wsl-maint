# Defender exclusions for WSL and Docker paths. Dot-sourced by maint.ps1.
#
# Ported from an earlier standalone defender-wsl-exclusions.ps1 script.
# That script excludes the distro and Docker vhdx FILES (not their containing
# directories) and nine host processes by bare name. Excluding the containing
# directories (...\LocalState, %LOCALAPPDATA%\Docker) or a bare '\\wsl$' UNC
# path would be broader: \\wsl$ alone tells Defender to stop scanning the live
# filesystem of every WSL distro on the box. So: the two vhdx files, no \\wsl$.
#
# Process exclusions are FULL IMAGE PATHS, not the old script's bare names.
# Microsoft's "Exclusions in Microsoft Defender Antivirus" (process
# exclusions): an image-name exclusion like 'docker.exe' "excludes files
# opened by any process with that name, no matter where it runs from,
# including removable media"; a full path excludes "that specific process
# only. Whenever possible, use the full path." With bare names any downloaded
# docker.exe ran with its file I/O unscanned.

function Get-MaintExclusionPaths {
    # The distro disk comes from Get-DistroVhdxPath (Common.ps1), the same
    # lookup compact uses, so two matching disks are refused, not guessed.
    param([Parameter(Mandatory)][string]$Distro)
    $paths = @()

    $distroVhdx = Get-DistroVhdxPath -Distro $Distro -Purpose 'exclude'
    if ($distroVhdx) { $paths += $distroVhdx }

    $dockerVhdx = Get-MaintDockerVhdxPath
    if (Test-Path -LiteralPath $dockerVhdx) { $paths += $dockerVhdx }

    $paths | Where-Object { $_ }
}

function Get-MaintDockerVhdxPath {
    Join-Path $env:LOCALAPPDATA 'Docker\wsl\disk\docker_data.vhdx'
}

function Get-MaintExclusionProcessCandidates {
    # Where each excluded process lives. Only admin-writable install dirs
    # (%ProgramFiles%, %SystemRoot%\System32) are searched, never PATH
    # (Get-Command) or the image of a running process (Get-Process): a user
    # can put a docker.exe first on PATH or run one from Downloads, and
    # resolving through either would hand that file the exclusion, the hole
    # full paths exist to close.
    #
    # WSL: the Store/MSI package puts wsl.exe, wslservice.exe and wslhost.exe
    # in %ProgramFiles%\WSL. System32 keeps the inbox wsl.exe (a launcher that
    # hands off to the package when it is installed) and, on old inbox-only
    # WSL, wslhost.exe. Every candidate that exists is excluded, so a box with
    # both gets both wsl.exe entries.
    # Docker Desktop: the default install dir only. A custom
    # --installation-dir is not looked up; those processes are skipped with a
    # warning.
    #
    # vmmem / vmmemWSL are dropped, not kept as bare names. They are
    # pseudo-processes (the VM's memory as Task Manager shows it) with no
    # image on disk, so there is no full path to give. The VM disk I/O they
    # might cover is already excluded by the two vhdx path exclusions, while a
    # bare name still matches any image called 'vmmem' in any folder. Little
    # gain, a real hole: dropped. -Verify flags an old bare entry as stale.
    param(
        [string]$ProgramFiles = $env:ProgramFiles,
        [string]$SystemRoot = $env:SystemRoot
    )
    $wsl = Join-Path $ProgramFiles 'WSL'
    $sys = Join-Path $SystemRoot 'System32'
    $dk = Join-Path $ProgramFiles 'Docker\Docker'
    @(
        [pscustomobject]@{ Name = 'wsl.exe';                Paths = @((Join-Path $wsl 'wsl.exe'), (Join-Path $sys 'wsl.exe')) }
        [pscustomobject]@{ Name = 'wslservice.exe';         Paths = @((Join-Path $wsl 'wslservice.exe'), (Join-Path $sys 'wslservice.exe')) }
        [pscustomobject]@{ Name = 'wslhost.exe';            Paths = @((Join-Path $wsl 'wslhost.exe'), (Join-Path $sys 'wslhost.exe')) }
        [pscustomobject]@{ Name = 'com.docker.backend.exe'; Paths = @((Join-Path $dk 'resources\com.docker.backend.exe')) }
        [pscustomobject]@{ Name = 'com.docker.service';     Paths = @((Join-Path $dk 'com.docker.service')) }
        [pscustomobject]@{ Name = 'dockerd.exe';            Paths = @((Join-Path $dk 'resources\dockerd.exe')) }
        [pscustomobject]@{ Name = 'docker.exe';             Paths = @((Join-Path $dk 'resources\bin\docker.exe')) }
    )
}

function Get-MaintExclusionProcesses {
    # Full image paths of the candidates that exist. A process with no image
    # found (Docker not installed, a custom install dir) is skipped with a
    # warning, not an error: there is nothing on disk to exclude.
    param(
        [string]$ProgramFiles = $env:ProgramFiles,
        [string]$SystemRoot = $env:SystemRoot
    )
    foreach ($c in (Get-MaintExclusionProcessCandidates -ProgramFiles $ProgramFiles -SystemRoot $SystemRoot)) {
        $found = @($c.Paths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
        if ($found.Count -eq 0) {
            Write-MaintLog -Level warn -Message ("process $($c.Name) not found (looked in " + ($c.Paths -join ', ') + '); not excluded')
            continue
        }
        $found
    }
}

function Write-MaintStaleBareExclusions {
    # Bare-name process exclusions that older versions of this tool (and the
    # script it was ported from) added. Reported with the command that removes
    # each one, never removed here: the user may have added the same name for
    # a reason of their own.
    param([string[]]$Have)
    $legacy = @('vmmemWSL', 'vmmem', 'wsl.exe', 'wslservice.exe', 'wslhost.exe',
                'com.docker.backend.exe', 'com.docker.service', 'dockerd.exe', 'docker.exe')
    foreach ($n in @($Have | Where-Object { $_ -and ($legacy -contains $_) })) {
        Write-MaintLog -Level warn -Message "stale bare-name exclusion $n (matches a process of that name in any folder); remove with: Remove-MpPreference -ExclusionProcess '$n'"
    }
}

function Invoke-MaintDefender {
    param([switch]$Verify)

    try {
        $prefs = Get-MpPreference
    } catch {
        throw "Get-MpPreference failed: $_. Defender may be disabled or managed by policy."
    }

    $distro = (Get-MaintConfig).Distro
    $wantPaths = @(Get-MaintExclusionPaths -Distro $distro)
    $wantProcs = @(Get-MaintExclusionProcesses)

    # Get-DistroVhdxPath returns $null when no disk matches (a distro typo in
    # maint.conf, or a UAC prompt answered by a separate admin account whose
    # HKCU and LOCALAPPDATA are not the WSL user's). The list then holds at
    # most the Docker disk. Say so, as compact does, instead of a quiet
    # success with the distro disk silently left out.
    $dockerVhdx = Get-MaintDockerVhdxPath
    $distroMissing = -not @($wantPaths | Where-Object { $_ -ne $dockerVhdx })
    if ($distroMissing) {
        Write-MaintLog -Level warn -Message "no disk found for distro $distro (WSL registry or %LOCALAPPDATA%\Packages); its disk is not excluded. Check distro in maint.conf, and that UAC elevated the same user"
    }

    # Confirmed by a read-only unelevated run on this box (Windows PowerShell
    # 5.1, 2026-08-12): Get-MpPreference does NOT throw when unelevated. It
    # returns normally but silently substitutes a one-element array
    # containing the literal string "N/A: Must be an administrator to view
    # exclusions" for both ExclusionPath and ExclusionProcess. Left
    # unhandled, -Verify would compare every real path/process against that
    # sentinel, find no match, and print "MISS" for all of them - reading as
    # "no exclusions configured" when the true state is simply unknown from
    # this shell. Detect the sentinel and say so instead of lying.
    $sentinel = 'N/A: Must be an administrator to view exclusions'
    $unreadable = (@($prefs.ExclusionPath) -contains $sentinel) -or (@($prefs.ExclusionProcess) -contains $sentinel)

    if ($Verify) {
        if ($unreadable) {
            Write-MaintLog -Level warn -Message 'cannot read Defender exclusions unelevated; re-run elevated (maint.bat defender -Verify) to check'
            return
        }
        $ok = $true
        if ($distroMissing) { Write-MaintLog -Level warn -Message "MISS path $distro disk (not found)" }
        foreach ($p in $wantPaths) {
            if ($prefs.ExclusionPath -contains $p) {
                Write-MaintLog -Message "OK   path $p"
            } else {
                Write-MaintLog -Level warn -Message "MISS path $p"; $ok = $false
            }
        }
        foreach ($p in $wantProcs) {
            if ($prefs.ExclusionProcess -contains $p) {
                Write-MaintLog -Message "OK   proc $p"
            } else {
                Write-MaintLog -Level warn -Message "MISS proc $p"; $ok = $false
            }
        }
        Write-MaintStaleBareExclusions -Have $prefs.ExclusionProcess
        if (-not $ok) { Write-MaintLog -Level warn -Message 'run: maint.bat defender' }
        return
    }

    Assert-Admin
    if ($unreadable) {
        # Should be unreachable: Assert-Admin above already guarantees an
        # elevated shell, and elevated Get-MpPreference returns real data on
        # this box. Fail loudly rather than risk re-adding exclusions blind.
        throw 'Get-MpPreference returned no usable exclusion data even though this shell is elevated; refusing to guess.'
    }

    $failed = @()
    foreach ($p in $wantPaths) {
        if ($prefs.ExclusionPath -notcontains $p) {
            try {
                Add-MpPreference -ExclusionPath $p -ErrorAction Stop
                Write-MaintLog -Message "added path exclusion: $p"
            } catch {
                Write-MaintLog -Level warn -Message "failed to add path exclusion ${p}: $_"
                $failed += "path:$p"
            }
        }
    }
    foreach ($p in $wantProcs) {
        if ($prefs.ExclusionProcess -notcontains $p) {
            try {
                Add-MpPreference -ExclusionProcess $p -ErrorAction Stop
                Write-MaintLog -Message "added process exclusion: $p"
            } catch {
                Write-MaintLog -Level warn -Message "failed to add process exclusion ${p}: $_"
                $failed += "proc:$p"
            }
        }
    }

    Write-MaintStaleBareExclusions -Have $prefs.ExclusionProcess

    if ($failed.Count -gt 0) {
        throw ("Defender exclusions partially applied; failed: " + ($failed -join ', '))
    }
    if ($distroMissing) {
        Write-MaintLog -Level warn -Message "defender exclusions applied, but the $distro disk was not found; it is not excluded"
        return
    }
    Write-MaintLog -Message 'defender exclusions applied'
}
