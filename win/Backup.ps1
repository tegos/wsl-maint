# Backup: clean, trim, export, compress, retain. Dot-sourced by maint.ps1,
# after win\Common.ps1 (Get-MaintConfig, Get-MaintWslArgs, ConvertTo-WslPath).

function Confirm-Unverifiable {
    # Shared fail-safe for every way Confirm-LargeDeletion can fail to learn
    # how much would be freed (preview call failed, produced no "would free:"
    # line, or produced an amount in a shape the parser below does not
    # recognise). An unknown size is never treated as "safe to skip the
    # prompt" -- not knowing is handled at least as cautiously as a confirmed
    # large deletion: -Unattended aborts outright (a scheduled run with no
    # human to ask and no reliable size estimate must not guess and proceed
    # to `maint clean` against unknown data), and an interactive run still
    # gets asked, still default-deny.
    param([Parameter(Mandatory)][string]$Reason, [switch]$Unattended)

    Write-MaintLog -Level warn -Message "$Reason; cannot verify how much would be freed"
    if ($Unattended) {
        throw "$Reason; refusing to guess under -Unattended."
    }
    Write-Host ""
    Write-Host "Could not determine how much would be freed ($Reason)." -ForegroundColor Yellow
    $answer = Read-Host "Continue anyway? [y/N]"
    return (Test-MaintConsent $answer)
}

function Confirm-LargeDeletion {
    # Gate that sits directly in front of the real `maint clean` call in the
    # [1/6] block below. It always previews first with `maint clean --dry-run`
    # (a read-only call) so the threshold check and the printed preview are
    # accurate on every run, dry or not -- this is why the prompt itself can
    # still appear when the caller's own -DryRun is set, on purpose: a dry
    # run shows the same prompt a real run would. -DryRun still guarantees
    # nothing destructive happens either
    # way: the real clean call downstream also gets --dry-run appended
    # whenever the outer -DryRun is set, regardless of the answer given here.
    param([double]$ThresholdGb = 1.0, [switch]$Unattended)

    $cfg = Get-MaintConfig
    # Resolved before the 'Continue' window below, so a repo (or a
    # WSL_MAINT_CONFIG file) the WSL side cannot reach throws here instead of
    # turning into a failed preview.
    $previewArgs = @(Get-MaintWslArgs $cfg 'clean') + '--dry-run'

    # maint.ps1 sets $ErrorActionPreference = 'Stop' at script scope, and that
    # is inherited here. In Windows PowerShell 5.1, merging a NATIVE exe's
    # stderr into a captured variable with 2>&1 wraps each stderr line as a
    # terminating NativeCommandError under 'Stop' -- confirmed against the
    # real binary: `wsl.exe -d Ubuntu -- sh -c "echo out; echo err 1>&2" 2>&1`
    # threw immediately, before this function's own parsing ever ran. That is
    # fatal for this exact call: `maint clean --dry-run` legitimately writes
    # to stderr (wsl/lib/common.sh's log_info/log_warn/log_err all do) for
    # every non-zero-sized rule, i.e. precisely when this gate has something
    # to say. Scoping $ErrorActionPreference to 'Continue' for just this one
    # call keeps stderr lines flowing into $preview as (ErrorRecord) entries
    # instead of throwing; -match/string interpolation on them behaves the
    # same as on plain strings (verified against the real binary below), and
    # $ErrorActionPreference is restored to the caller's value immediately
    # after, win or lose, via try/finally.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # Absolute path, not bare "maint": see Get-MaintWslBin in Common.ps1.
        $preview = & wsl.exe @previewArgs 2>&1
        $previewExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }
    $preview | ForEach-Object { Write-Host "  $_" }

    if ($previewExit -ne 0) {
        return Confirm-Unverifiable -Reason "clean --dry-run preview exited $previewExit" -Unattended:$Unattended
    }

    $line = $preview | Where-Object { $_ -match 'would free:\s*(.+)$' } | Select-Object -Last 1
    if (-not $line) {
        return Confirm-Unverifiable -Reason "preview produced no 'would free:' line" -Unattended:$Unattended
    }

    $amount = [regex]::Match($line, 'would free:\s*(.+)$').Groups[1].Value.Trim()
    # numfmt --to=iec --format='%.1f' (wsl/lib/common.sh) can be locale-
    # sensitive about the decimal separator (comma vs. dot); accept either
    # and normalise to dot before casting. The captured group intentionally
    # allows only one decimal separator followed by digits, not thousands
    # grouping -- the value here is always a single IEC unit's fractional
    # part (< 1024), never a grouped integer.
    $gb = $null
    if ($amount -match '^\d+(?:[.,]\d+)?G$') {
        $gb = [double](($amount.TrimEnd('G')) -replace ',', '.')
    } elseif ($amount -match '^\d+(?:[.,]\d+)?T$') {
        $gb = [double](($amount.TrimEnd('T')) -replace ',', '.') * 1024
    } elseif ($amount -match '^\d+(?:[.,]\d+)?[KM]?$') {
        # A bare number, K, or M is confidently below $ThresholdGb (1 GB) by
        # construction of numfmt's auto-scaling: numfmt only ever picks a unit
        # for values in [1, 1024) of that unit, so anything it renders as K or
        # M (or leaves unsuffixed) is < 1 GB.
        #
        # "B" is deliberately NOT in this class, even though it looks like the
        # smallest unit of all. B is not a numfmt unit; it is wsl/lib/
        # common.sh:14's fallback for when numfmt is ABSENT (`|| echo
        # "${b}B"`), i.e. a RAW, UNSCALED byte count with no upper bound. On a
        # box without coreutils' numfmt, "would free: 53687091200B" is 50 GB,
        # not 50 bytes -- treating it as < 1 GB would skip this whole gate
        # silently, with no prompt and no log line, in exactly the case where
        # it matters most. Letting B fall through leaves $gb $null, so it hits
        # Confirm-Unverifiable below and gets the fail-safe treatment.
        $gb = 0.0
    }
    # Anything else -- a unit this parser does not recognise (e.g. a P/E/Z/Y
    # scale numfmt would use for values that huge) or a shape that doesn't
    # match any of the above -- is NOT "confidently small". Per this task's
    # fix round: a value that cannot be parsed must never silently read as
    # "below threshold". It gets the same fail-safe treatment as a missing
    # preview line, not a free pass.
    if ($null -eq $gb) {
        return Confirm-Unverifiable -Reason "could not parse 'would free' amount '$amount'" -Unattended:$Unattended
    }

    if ($gb -lt $ThresholdGb) { return $true }
    if ($Unattended) {
        Write-MaintLog -Message "unattended: proceeding to free $amount"
        return $true
    }

    Write-Host ""
    Write-Host "About to free $amount inside $($cfg.Distro)." -ForegroundColor Yellow
    $answer = Read-Host "Continue? [y/N]"
    # Default-deny: only y/yes counts as consent (Test-MaintConsent). $null,
    # empty, whitespace-only, "n", "no", or garbage input all fall through to
    # $false. Ambiguous input must never read as consent (the Get-MpPreference
    # sentinel in Defender.ps1 follows the same rule).
    return (Test-MaintConsent $answer)
}

function Rename-FailedArchive {
    # Moves an archive that failed [4/6] or [5/6] out of the <distro>_*.tar.zst
    # shape Invoke-BackupRetention counts. Left under its own name, the next
    # good run would count it as one of the newest $Keep and rotate a good
    # backup out in its place, so every failed run would silently cost one.
    # Renamed, not deleted: an .unverified archive may well be fine, and even
    # a .bad one is evidence.
    #
    # A taken first-choice name (two failed runs in one _HHmm minute, or a
    # leftover) moves on to <suffix>.1, .2, ...; every candidate ends in the
    # suffix or a digit, so none matches <distro>_*.tar.zst. Returns the new path
    # in .Path and a sentence for the caller's throw in .Note. If no rename
    # works, .Note says loudly that the archive still has its retention-visible
    # name: falling back silently is exactly the bug this exists to prevent.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Suffix)
    $leaf = Split-Path -Leaf $Path
    $dir = Split-Path -Parent $Path
    $lastErr = $null
    for ($n = 0; $n -le 99; $n++) {
        $name = if ($n -eq 0) { "$leaf$Suffix" } else { "$leaf$Suffix.$n" }
        $target = Join-Path $dir $name
        if (Test-Path -LiteralPath $target) { continue }
        try {
            Rename-Item -LiteralPath $Path -NewName $name -ErrorAction Stop
        } catch {
            $lastErr = $_
            Write-MaintLog -Level err -Message "could not rename $Path to $target ($_)"
            continue
        }
        Write-MaintLog -Level warn -Message "renamed to $target so retention never counts it"
        return [pscustomobject]@{ Path = $target; Note = "Archive moved to $target." }
    }
    Write-MaintLog -Level err -Message "archive NOT renamed, still named $Path; retention will count it"
    [pscustomobject]@{
        Path = $Path
        Note = "ARCHIVE NOT RENAMED: still named $Path, which the next backup's retention counts as a good backup; move it out by hand before the next backup (last error: $lastErr)."
    }
}

function New-BackupArchive {
    # Steps [3/6] and [4/6]: exports the distro to $TarPath and compresses it
    # in place with zstd, leaving "$TarPath.zst". A failed export removes the
    # partial tar; a failed compression keeps the tar (it is the only copy of
    # the export) and throws. Either throw leaves existing backups untouched.
    # Deliberately returns nothing: wsl.exe's own stdout flows down this
    # function's pipeline, so a returned path would arrive mixed with it.
    param([Parameter(Mandatory)][string]$Distro, [Parameter(Mandatory)][string]$TarPath)

    $zst = "$TarPath.zst"
    Write-MaintLog -Message "[3/6] exporting to $TarPath (this stops the distro)"
    try {
        Invoke-Wsl @('--export', $Distro, $TarPath)
    } catch {
        if (Test-Path -LiteralPath $TarPath) { Remove-Item -LiteralPath $TarPath -Force }
        throw "Export failed; partial tar removed. $_"
    }
    $tarBytes = (Get-Item -LiteralPath $TarPath).Length
    Write-MaintLog -Message ("exported " + (Format-Gb $tarBytes))

    Write-MaintLog -Message '[4/6] compressing with zstd -T0 -3'
    $wslTar = ConvertTo-WslPath $TarPath
    & wsl.exe -d $Distro -- zstd -T0 -3 --rm -q $wslTar
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $zst)) {
        Write-MaintLog -Level err -Message 'compression failed; keeping the uncompressed tar'
        # A partial .zst zstd left behind has the shape retention counts.
        if (Test-Path -LiteralPath $zst) {
            $partial = Rename-FailedArchive -Path $zst -Suffix '.bad'
            throw "zstd failed on $TarPath; partial archive left behind. $($partial.Note)"
        }
        throw "zstd failed on $TarPath"
    }
    $zstBytes = (Get-Item -LiteralPath $zst).Length
    $ratio = [math]::Round($tarBytes / $zstBytes, 2)
    Write-MaintLog -Message ("compressed to " + (Format-Gb $zstBytes) + " (${ratio}x)")
}

function Test-BackupArchive {
    # Step [5/6]. Returns normally only when `zstd -t` passed; every other
    # outcome throws, so the caller never reaches retention with an archive
    # that is bad or unverified.
    param([Parameter(Mandatory)][string]$Distro, [Parameter(Mandatory)][string]$ArchivePath)

    Write-MaintLog -Message '[5/6] verifying the new archive with zstd -t'

    # Verifies the archive just made BEFORE retention is allowed to delete the
    # oldest known-good one. $LASTEXITCODE -eq 0 from zstd plus Test-Path at
    # [4/6] only proves a file exists; a truncated-but-exit-0 .zst passes both
    # and would rotate a good backup out in exchange for a bad one. This is the
    # only backup of a live VM, so the check must ABORT, not warn after the
    # fact -- the caller runs it before Invoke-BackupRetention, and throwing
    # here leaves every existing backup in place. Same `zstd -t` the WSL
    # side's `maint verify` runs; costs a few minutes on top of an already
    # ~20-minute operation, which is accepted.
    $wslZst = ConvertTo-WslPath $ArchivePath
    & wsl.exe -d $Distro -- zstd -t $wslZst
    $verifyExit = $LASTEXITCODE
    if ($verifyExit -ne 0) {
        # A non-zero exit here is ambiguous, and the two readings mean opposite
        # things to the operator. `zstd -t` says the archive is bad; wsl.exe
        # failing to start the distro (which [3/6] deliberately stopped) says
        # nothing about the archive at all. Reporting the second as corruption
        # sends the operator to re-run a ~20-minute backup over a file that was
        # probably fine. Distinguish them by probing the distro with a command
        # that cannot fail on a healthy one.
        #
        # Fail-closed either way: both paths throw before retention, so an
        # UNVERIFIED archive is no more allowed to rotate a known-good one
        # out than a known-bad one is.
        #
        # Either way the archive is renamed out of retention's filter (see
        # Rename-FailedArchive), or the NEXT good run would rotate a good
        # backup out to keep this one.
        & wsl.exe -d $Distro -- true
        if ($LASTEXITCODE -ne 0) {
            $moved = Rename-FailedArchive -Path $ArchivePath -Suffix '.unverified'
            throw "Integrity check could not be run on $ArchivePath -- $Distro did not respond (zstd -t exited $verifyExit, and so did a plain probe); the archive is UNVERIFIED, not known-bad, so keeping all existing backups. $($moved.Note) Re-check it later with: wsl -d $Distro -- zstd -t $(ConvertTo-WslPath $moved.Path) (maint verify only sees *.tar.zst), and rename it back to .tar.zst if it passes"
        }
        $moved = Rename-FailedArchive -Path $ArchivePath -Suffix '.bad'
        throw "Integrity check failed on $ArchivePath; zstd -t exited $verifyExit and reports the archive as corrupt, so keeping all existing backups. $($moved.Note)"
    }
    Write-MaintLog -Message 'archive verified'
}

function Get-BackupPrefix {
    # Archive name prefix: the lowercased distro plus "_". The default Ubuntu
    # gives ubuntu_, the name every archive had before the distro was
    # configurable, so existing archives keep rotating.
    param([Parameter(Mandatory)][string]$Distro)
    $Distro.ToLowerInvariant() + '_'
}

function Invoke-BackupRetention {
    # Step [6/6]: deletes all but the newest $Keep archives, by LastWriteTime.
    # Only this distro's archives count: <prefix><yyyy-MM-dd_HHmm>.tar.zst,
    # exactly the name Invoke-MaintBackup writes, so uncompressed legacy .tar
    # files, another distro's archives (including one whose name merely starts
    # the same way, Ubuntu_22 vs Ubuntu) and anything else in the directory
    # are never touched. Fewer than Keep entries, or an empty directory, both
    # leave -Skip with nothing to enumerate: no error, no deletion. Only ever
    # called after the new archive passed Test-BackupArchive. The regex
    # re-check is belt and braces: -Filter alone was never seen to match a
    # .bad or .unverified name (checked on C: and D:), but Win32 filter
    # matching can also consider 8.3 short names, and the archives
    # Rename-FailedArchive leaves must never count.
    param(
        [Parameter(Mandatory)][string]$BackupRoot,
        [Parameter(Mandatory)][int]$Keep,
        [Parameter(Mandatory)][string]$Distro
    )
    $prefix = Get-BackupPrefix $Distro
    $shape = '^' + [regex]::Escape($prefix) + '\d{4}-\d{2}-\d{2}_\d{4}\.tar\.zst$'
    Write-MaintLog -Message "[6/6] retention: keeping newest $Keep ${prefix}*.tar.zst"
    Get-ChildItem -LiteralPath $BackupRoot -Filter "${prefix}*.tar.zst" -File |
        Where-Object { $_.Name -match $shape } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $Keep |
        ForEach-Object {
            Write-MaintLog -Message ("removing old backup: " + $_.Name)
            Remove-Item -LiteralPath $_.FullName -Force
        }
}

function Invoke-MaintBackup {
    # -Unattended is forwarded to Confirm-LargeDeletion below: a scheduled or
    # unattended run must never block on Read-Host, so -Unattended skips the
    # prompt there, logs what it is proceeding to free, and continues.
    # -NoClean skips step 1 so the archive holds the distro exactly as it was:
    # the first backup, taken before this tool has deleted anything.
    param([switch]$DryRun, [switch]$Unattended, [switch]$NoClean)

    $cfg = Get-MaintConfig
    $backupRoot = $cfg.BackupRoot
    $distro = $cfg.Distro

    # No default: a guessed directory is a write somewhere the operator never
    # chose. Refuse before any distro call, dry run included.
    if ([string]::IsNullOrWhiteSpace($backupRoot)) {
        throw "No backup directory configured: set backup_root in maint.conf (e.g. backup_root = D:\backups\wsl), see maint.conf.example."
    }

    # Up front, not at [4/6]: a root the WSL side cannot reach must fail
    # before the export, not surface later as a corrupt-archive alarm.
    Assert-LocalDrivePath $backupRoot -What 'backup_root'
    if (-not (Test-Path -LiteralPath (Split-Path -Qualifier $backupRoot))) {
        throw "Backup drive not available: $backupRoot"
    }

    # Both gated on -DryRun: a dry run touches nothing, and the zstd probe is
    # a real wsl.exe call that can start a stopped distro. The probe exists to
    # fail before a 20 GB export; a dry run produces no export to protect.
    if (-not (Test-Path -LiteralPath $backupRoot)) {
        if ($DryRun) {
            Write-MaintLog -Message "DRY would create $backupRoot"
        } else {
            New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
        }
    }

    if ($DryRun) {
        Write-MaintLog -Message "DRY would check zstd in $distro"
    } else {
        # zstd must exist inside the distro before we produce a 20 GB tar we cannot compress.
        & wsl.exe -d $distro -- sh -c "command -v zstd >/dev/null 2>&1"
        if ($LASTEXITCODE -ne 0) {
            throw "zstd is not installed in $distro. Run: wsl -d $distro -- sudo apt install -y zstd"
        }
    }

    $freeGb = Get-FreeSpaceGb -DriveLetter (Split-Path -Qualifier $backupRoot).TrimEnd(':')
    Write-MaintLog -Message "free on backup drive: $freeGb GB"
    if ($freeGb -lt 40) {
        throw "Less than 40 GB free on the backup drive; refusing to start an export."
    }

    if ($NoClean) {
        Write-MaintLog -Message '[1/6] clean skipped (-NoClean)'
    } else {
        Write-MaintLog -Message '[1/6] cleaning inside the distro'
        if (-not (Confirm-LargeDeletion -Unattended:$Unattended)) {
            throw "Aborted by user before cleaning."
        }
        $cleanArgs = Get-MaintWslArgs $cfg 'clean'
        if ($DryRun) { $cleanArgs += '--dry-run' }
        Invoke-Wsl $cleanArgs
    }

    Write-MaintLog -Message '[2/6] fstrim'
    if ($DryRun) {
        Write-MaintLog -Message 'DRY would run: sudo -n fstrim --all'
    } else {
        & wsl.exe -d $distro -- sudo -n fstrim --all
        if ($LASTEXITCODE -ne 0) {
            Write-MaintLog -Level warn -Message 'fstrim skipped (needs passwordless sudo)'
        }
    }

    $ts = Get-Date -Format 'yyyy-MM-dd_HHmm'
    $tar = Join-Path $backupRoot ((Get-BackupPrefix $distro) + "$ts.tar")
    $zst = "$tar.zst"

    if ($DryRun) {
        Write-MaintLog -Message "DRY would export to $tar then compress to $zst"
        return
    }

    New-BackupArchive -Distro $distro -TarPath $tar

    Test-BackupArchive -Distro $distro -ArchivePath $zst
    Invoke-BackupRetention -BackupRoot $backupRoot -Keep $cfg.Keep -Distro $distro

    Write-MaintLog -Message "backup complete: $zst"
}
