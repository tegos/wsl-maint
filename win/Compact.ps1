# Compact: shut WSL down and reclaim VHDX slack. Dot-sourced by maint.ps1.
#
# Every step through the "found <name>: <path> (<size>)" logging is read-only
# (Get-ChildItem/Test-Path/Get-Item.Length). The -DryRun gate sits immediately
# before the first side-effecting call (wsl --shutdown); nothing before that
# gate touches the VM or the VHDX.

function Get-WslVhdxPaths {
    # The distro disk comes from Get-DistroVhdxPath (Common.ps1), which throws
    # on two matches; none found is reported by Invoke-MaintCompact.
    param([Parameter(Mandatory)][string]$Distro)
    $paths = @()

    $disk = Get-DistroVhdxPath -Distro $Distro -Purpose 'compact'
    if ($disk) { $paths += [pscustomobject]@{ Name = $Distro; Path = $disk } }

    $docker = Join-Path $env:LOCALAPPDATA 'Docker\wsl\disk\docker_data.vhdx'
    if (Test-Path -LiteralPath $docker) { $paths += [pscustomobject]@{ Name = 'Docker'; Path = $docker } }

    $paths
}

function Wait-WslStopped {
    # No fixed `Start-Sleep -Seconds 5` after `wsl --shutdown`: exit 0 from --shutdown
    # means the shutdown was initiated, not that the VM's handle on the VHDX
    # was released; on a large disk or a loaded machine 5s is not a bound on
    # anything. Poll `wsl -l --running -q` instead until it reports nothing.
    #
    # -q ("only show distribution names") skips both the header and the
    # localised "no running distributions" message, so there is no message
    # text to match in any language. wsl.exe's stdout is UTF-16LE and
    # PowerShell's external-process capture does not decode it, so each raw
    # line arrives as characters interleaved with literal null bytes (e.g.
    # "Ubuntu" -> "U`0b`0u`0n`0t`0u`0"). Emptiness is decided structurally:
    # strip the null bytes, trim, drop blank lines, and check the count of
    # what is left - never by matching any particular string.
    param(
        # 2s poll: frequent enough to not add noticeable latency, not so tight
        # it spams wsl.exe. 60s timeout: a normal `wsl --shutdown` completes in
        # a few seconds even with a large VHDX, since it is the VM stopping,
        # not the disk being copied; 60s is a generous multiple of that, so a
        # trip here means WSL is genuinely stuck, not just "still working".
        [int]$TimeoutSeconds = 60,
        [double]$PollSeconds = 2
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $running = @('(not yet polled)')
    $pollExit = $null
    while ((Get-Date) -lt $deadline) {
        # Invoke-WslNoThrow, not a bare call: under 'Stop', PS 5.1 turns a
        # redirected stderr line into a terminating error even with 2>$null.
        $raw = Invoke-WslNoThrow @('-l', '--running', '-q') 2>$null
        $pollExit = $LASTEXITCODE
        $running = @($raw | ForEach-Object { $_ -replace "`0", '' } | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        # A non-zero exit means this reading is inconclusive, not "nothing
        # running": wsl.exe can fail (a transient LxssManager hiccup, an RPC
        # error) with empty stdout, which would look identical to a genuinely
        # empty listing if the exit code were ignored. Only exit 0 with a
        # structurally empty listing counts as confirmed-stopped; anything
        # else - including exit 0 with content, and any non-zero exit
        # regardless of content - falls through to another poll, and
        # eventually to the timeout below if it never resolves.
        if ($pollExit -eq 0 -and $running.Count -eq 0) { return }
        Start-Sleep -Seconds $PollSeconds
    }
    if ($pollExit -ne 0) {
        throw ("Timed out after ${TimeoutSeconds}s waiting for WSL to fully shut down: the last poll (wsl -l --running -q) exited $pollExit, so its result could not be trusted. Not compacting.")
    }
    throw ("Timed out after ${TimeoutSeconds}s waiting for WSL to fully shut down (still running: " + ($running -join ', ') + "). Not compacting.")
}

function Invoke-MaintCompact {
    param([switch]$DryRun)

    if (-not (Get-Command Optimize-VHD -ErrorAction SilentlyContinue)) {
        throw "Optimize-VHD is unavailable. Enable the Hyper-V PowerShell module."
    }

    $distro = (Get-MaintConfig).Distro
    $targets = Get-WslVhdxPaths -Distro $distro
    if (-not $targets) { throw "No WSL VHDX files found." }
    if (-not @($targets | Where-Object { $_.Name -eq $distro })) {
        Write-MaintLog -Level warn -Message "no disk found for distro $distro (WSL registry or %LOCALAPPDATA%\Packages); only the disks listed below are compacted"
    }

    foreach ($t in $targets) {
        Write-MaintLog -Message ("found " + $t.Name + ": " + $t.Path + " (" + (Format-Gb (Get-Item -LiteralPath $t.Path).Length) + ")")
    }

    if ($DryRun) {
        Write-MaintLog -Message 'DRY would run wsl --shutdown then Optimize-VHD on the above'
        return
    }

    Write-MaintLog -Message 'shutting WSL down'
    Invoke-Wsl @('--shutdown')
    Write-MaintLog -Message 'waiting for WSL to release its VHDX handles'
    Wait-WslStopped
    Write-MaintLog -Message 'WSL fully stopped'

    $totalFreed = 0
    $failed = @()
    foreach ($t in $targets) {
        $before = (Get-Item -LiteralPath $t.Path).Length
        try {
            Optimize-VHD -Path $t.Path -Mode Full -ErrorAction Stop
        } catch {
            # Do not let this failure hide inside a clean-looking summary: record
            # it and keep going so the other VHDX still gets compacted, but the
            # function throws at the end so the caller's exit code reflects it.
            Write-MaintLog -Level warn -Message ($t.Name + ": Optimize-VHD failed: " + $_)
            $failed += $t.Name
            continue
        }
        $after = (Get-Item -LiteralPath $t.Path).Length
        $freed = $before - $after
        $totalFreed += $freed
        Write-MaintLog -Message ($t.Name + ": " + (Format-Gb $before) + " -> " + (Format-Gb $after) + " (freed " + (Format-Gb $freed) + ")")
    }

    Write-MaintLog -Message ("total reclaimed on C: " + (Format-Gb $totalFreed))
    Write-MaintLog -Message ("C: free now " + (Get-FreeSpaceGb -DriveLetter 'C') + " GB")

    if ($failed.Count -gt 0) {
        throw ("Optimize-VHD failed for: " + ($failed -join ', ') + ". WSL was already shut down; the listed VHDX(es) were not compacted.")
    }
}
