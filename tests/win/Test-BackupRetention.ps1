# win\Backup.ps1 -- Invoke-MaintBackup: ordering, integrity gate, retention.
#
# LOGIC-ONLY COVERAGE. wsl.exe, Invoke-Wsl, Confirm-LargeDeletion and
# Get-FreeSpaceGb are shadowed, so these tests prove the SEQUENCE and the
# side effects on disk (which files are created, which are deleted, which
# survive a throw) and NOT that a real wsl --export or a real zstd behaves as
# the mocks say. See the header of Run.ps1.
#
# Two levels. Invoke-BackupScenario drives Invoke-MaintBackup end to end, for
# preflight, consent, dry-run and step ORDER (nothing is deleted unless the
# new archive verified). The three steps it delegates to -- New-BackupArchive,
# Test-BackupArchive, Invoke-BackupRetention -- are also called directly, with
# only the one or two shadows each actually needs.
#
# Safety: the real backup directory is never referenced. Get-MaintConfig is
# shadowed to a per-test temp dir, and Remove-Item is shadowed file-wide to a
# recorder that REFUSES any path outside the system temp root -- so even a
# broken test (or a deliberately broken production copy during a negative
# control) cannot delete a real backup.

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent (Split-Path -Parent $here)
. (Join-Path $here 'Assert.ps1')
. (Join-Path $repo 'win\Common.ps1')
. (Join-Path $repo 'win\Backup.ps1')

$script:TempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$script:Removed = @()
$script:Logs = @()

# File-wide safety net. Also the recorder the retention assertions read.
function Remove-Item {
    [CmdletBinding()]
    param([Parameter(Position = 0, ValueFromPipeline = $true)][Alias('LiteralPath')]$Path, [switch]$Force, [switch]$Recurse)
    $full = [IO.Path]::GetFullPath("$Path")
    if (-not $full.StartsWith($script:TempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "TEST GUARD: refused to delete outside temp: $full"
    }
    $script:Removed += $full
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $full -Force:$Force -Recurse:$Recurse
}

# Same guard for the rename a failed verify does: never outside temp.
function Rename-Item {
    [CmdletBinding()]
    param([string]$LiteralPath, [string]$NewName)
    $full = [IO.Path]::GetFullPath("$LiteralPath")
    if (-not $full.StartsWith($script:TempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "TEST GUARD: refused to rename outside temp: $full"
    }
    Microsoft.PowerShell.Management\Rename-Item -LiteralPath $full -NewName $NewName
}

# File-wide net so no test can ever append to the repo's real logs\ dir.
function Write-MaintLog {
    param([string]$Level = 'info', [string]$Message)
    $script:Logs += "[$Level] $Message"
}

function ConvertFrom-WslPathTest {
    param([string]$WslPath)
    ($WslPath.Substring(5, 1).ToUpper()) + ':' + $WslPath.Substring(6).Replace('/', '\')
}

function New-BackupSandbox {
    # -Leaf puts the root one level down, under that exact name, so a test can
    # give it characters New-TestDir's names never have (brackets). Remove the
    # parent of such a root, not the root.
    param([string[]]$Names, [int]$OldestDaysAgo = 10, [string]$Leaf)
    $root = New-TestDir 'backup-root'
    if ($Leaf) { $root = [IO.Directory]::CreateDirectory((Join-Path $root $Leaf)).FullName }
    $i = 0
    foreach ($n in $Names) {
        $p = Join-Path $root $n
        Set-Content -LiteralPath $p -Value ("payload-" + $n)
        # Deterministic ordering: first name is oldest, last is newest.
        (Get-Item -LiteralPath $p).LastWriteTime = (Get-Date).AddDays(-$OldestDaysAgo + $i)
        $i++
    }
    $root
}

# Drives Invoke-MaintBackup end to end with every external call shadowed.
function Invoke-BackupScenario {
    param(
        [string]$BackupRoot,
        [int]$Keep = 3,
        [int]$ZstdPresentExit = 0,
        [int]$CompressExit = 0,
        [switch]$CompressProducesNothing,
        [int]$VerifyExit = 0,
        # Exit code for the `-- true` liveness probe the verify step runs when
        # zstd -t comes back non-zero. 0 = the distro is up, so the archive is
        # genuinely bad; non-zero = the distro never started and the check
        # never ran.
        [int]$ProbeExit = 0,
        [double]$FreeGb = 100,
        [switch]$ConsentDenied,
        [switch]$ExportFails,
        [switch]$DryRun,
        [switch]$NoClean,
        # Fixes the archive timestamp, so two runs in one test make two
        # archives instead of the second overwriting the first.
        [string]$Stamp,
        [string]$Distro = 'Ubuntu',
        # When given, Get-MaintConfig is NOT shadowed: the real reader parses
        # these lines from a temp maint.conf (via WSL_MAINT_CONFIG), and
        # -BackupRoot/-Keep/-Distro are ignored.
        [string[]]$ConfigLines
    )
    $script:Removed = @()
    $script:Logs = @()
    $script:WslCalls = @()

    if ($Stamp) {
        function Get-Date {
            param([string]$Format)
            if ($Format) { return $Stamp }
            Microsoft.PowerShell.Utility\Get-Date
        }
    }

    if (-not $PSBoundParameters.ContainsKey('ConfigLines')) {
        function Get-MaintConfig { @{ Distro = $Distro; BackupRoot = $BackupRoot; Keep = $Keep; RepoRoot = $BackupRoot } }
    }
    function Get-FreeSpaceGb { param($DriveLetter) $FreeGb }
    function Confirm-LargeDeletion {
        param([double]$ThresholdGb = 1.0, [switch]$Unattended)
        $script:WslCalls += 'confirm'
        -not $ConsentDenied
    }
    function Invoke-Wsl {
        param([Parameter(Mandatory)][string[]]$Arguments)
        $script:WslCalls += ($Arguments -join ' ')
        if ($Arguments -contains '--export') {
            if ($ExportFails) {
                Set-Content -LiteralPath $Arguments[2] -Value 'partial'
                throw 'wsl exited 1: wsl --export'
            }
            Set-Content -LiteralPath $Arguments[2] -Value ('tar' * 100)
        }
    }
    function wsl.exe {
        [CmdletBinding()] param([Parameter(ValueFromRemainingArguments = $true)]$WslArgs)
        $joined = @($WslArgs) -join ' '
        $script:WslCalls += "raw: $joined"
        if ($joined -like '*command -v zstd*') { $global:LASTEXITCODE = $ZstdPresentExit; return }
        if ($joined -like '*fstrim*') { $global:LASTEXITCODE = 0; return }
        if ($joined -like '*-T0*') {
            $win = ConvertFrom-WslPathTest (@($WslArgs)[-1])
            if (-not $CompressProducesNothing -and $CompressExit -eq 0) {
                Set-Content -LiteralPath ($win + '.zst') -Value 'compressed'
                Microsoft.PowerShell.Management\Remove-Item -LiteralPath $win -Force
            }
            $global:LASTEXITCODE = $CompressExit
            return
        }
        if ($joined -like '*zstd*') { $global:LASTEXITCODE = $VerifyExit; return }
        # PowerShell's parameter binder eats the `--` before a shadowed *function*
        # sees it, and binds `-d` as a prefix of the common `-Debug` switch (its
        # value survives as a positional arg), so this matches on the probe command
        # itself rather than on the full command line. It sits after the zstd
        # branches because those are the only other calls that could contain it,
        # and a hex temp path never can.
        if ($joined -like '*true*') { $global:LASTEXITCODE = $ProbeExit; return }
        $global:LASTEXITCODE = 0
    }

    $err = $null
    $confDir = $null
    $prevConfig = $env:WSL_MAINT_CONFIG
    try {
        if ($PSBoundParameters.ContainsKey('ConfigLines')) {
            $confDir = New-TestDir 'backup-conf'
            $env:WSL_MAINT_CONFIG = Join-Path $confDir 'maint.conf'
            Set-Content -LiteralPath $env:WSL_MAINT_CONFIG -Value $ConfigLines
        }
        Invoke-MaintBackup -DryRun:$DryRun -NoClean:$NoClean
    } catch {
        $err = "$_"
    } finally {
        $env:WSL_MAINT_CONFIG = $prevConfig
        if ($confDir) { Remove-TestDir $confDir }
    }
    [pscustomobject]@{
        Error    = $err
        Removed  = @($script:Removed)
        Log      = ($script:Logs -join "`n")
        WslCalls = @($script:WslCalls)
    }
}

function Get-ZstNames {
    param([string]$Root)
    (Get-ChildItem -LiteralPath $Root -File | Sort-Object Name | ForEach-Object { $_.Name }) -join ','
}

# --- The integrity gate must precede the deletion loop -----------------------
# zstd exit 0 + Test-Path only proves a file exists; a truncated-but-exit-0
# .zst would rotate a known-good backup out in exchange for a bad one. The
# `zstd -t` check therefore sits ABOVE the retention loop and throws, leaving
# every existing backup untouched. This is the only backup of a live VM.
# Both verify failures must stop the run before retention: a corrupt archive
# (distro up) and an unverified one (distro down, the check never ran).
function Test-IntegrityFailureAbortsBeforeAnyDeletion {
    $names = @('ubuntu_2026-08-01_0100.tar.zst', 'ubuntu_2026-08-02_0100.tar.zst',
               'ubuntu_2026-08-03_0100.tar.zst', 'ubuntu_2026-08-04_0100.tar.zst',
               'ubuntu_2026-08-05_0100.tar.zst')
    foreach ($case in @(@{ Probe = 0; Verdict = 'reports the archive as corrupt'; Shown = 'corrupt'; Suffix = '.bad' },
                        @{ Probe = 1; Verdict = 'UNVERIFIED, not known-bad'; Shown = 'distro down'; Suffix = '.unverified' })) {
        $root = New-BackupSandbox -Names $names
        try {
            $r = Invoke-BackupScenario -BackupRoot $root -VerifyExit 1 -ProbeExit $case.Probe
            $shown = $case.Shown

            Assert-NotNull $r.Error "$shown aborts the run"
            Assert-Contains $r.Error 'keeping all existing backups' "$shown states nothing was deleted"
            # The verdict wording per case is a Test-BackupArchive unit test;
            # this only pins that the orchestrator surfaces it unchanged.
            Assert-Contains $r.Error $case.Verdict "$shown surfaces the verify verdict"
            # Removed is the recorder every deletion in this file must pass
            # through, and the file count below proves the disk agrees with it.
            Assert-Eq 0 $r.Removed.Count "$shown deleted nothing (removed: $($r.Removed -join ','))"
            Assert-Contains $r.Log '[5/6] verifying the new archive' "$shown got as far as the verify step"
            Assert-NotContains $r.Log '[6/6] retention' "$shown never entered the retention step"
            # Five pre-existing + the new archive it just made and could not verify.
            Assert-Eq 6 (Get-ChildItem -LiteralPath $root -File).Count "$shown keeps the unverified archive too"
            Assert-Eq 1 @(Get-ChildItem -LiteralPath $root -Filter "*$($case.Suffix)" -File).Count "$shown renamed the new archive to $($case.Suffix)"
        } finally { Remove-TestDir $root }
    }
}

# --- A failed verify must not cost a good backup on the NEXT run -------------
# Regression: the archive a failed verify left behind used to keep its
# ubuntu_*.tar.zst name, so the next good run counted it as one of the Keep
# and rotated a good backup out in its place. It is now renamed out of the
# retention filter (.bad when corrupt, .unverified when the distro was down).
function Test-FailedVerifyDoesNotCostAGoodBackupNextRun {
    $good = @('ubuntu_2026-08-01_0100.tar.zst', 'ubuntu_2026-08-02_0100.tar.zst',
              'ubuntu_2026-08-03_0100.tar.zst')
    foreach ($case in @(@{ Probe = 0; Suffix = '.bad' }, @{ Probe = 1; Suffix = '.unverified' })) {
        $root = New-BackupSandbox -Names $good
        $suffix = $case.Suffix
        try {
            $bad = Invoke-BackupScenario -BackupRoot $root -Keep 3 -VerifyExit 1 -ProbeExit $case.Probe -Stamp '2026-09-01_0100'
            $badPath = Join-Path $root "ubuntu_2026-09-01_0100.tar.zst$suffix"
            Assert-NotNull $bad.Error "$suffix run N fails verify"
            Assert-FileExists $badPath "$suffix run N renamed the failed archive out of the filter"
            Assert-FileMissing (Join-Path $root 'ubuntu_2026-09-01_0100.tar.zst') "$suffix run N left no ubuntu_*.tar.zst behind"
            Assert-Contains $bad.Error $badPath "$suffix the throw names the renamed path"
            Assert-Contains $bad.Log "renamed to $badPath" "$suffix the rename is logged"

            $ok = Invoke-BackupScenario -BackupRoot $root -Keep 3 -Stamp '2026-09-02_0100'
            Assert-Null $ok.Error "$suffix run N+1 succeeds"
            # 3 good + 1 new good, Keep 3: only the oldest good one goes. The
            # old code counted the failed archive as a keeper and also lost 08-02.
            Assert-Eq 1 $ok.Removed.Count "$suffix run N+1 removed exactly one (removed: $($ok.Removed -join ','))"
            Assert-FileMissing (Join-Path $root $good[0]) "$suffix oldest good rotated out"
            Assert-FileExists (Join-Path $root $good[1]) "$suffix second good kept"
            Assert-FileExists (Join-Path $root $good[2]) "$suffix newest prior good kept"
            Assert-FileExists (Join-Path $root 'ubuntu_2026-09-02_0100.tar.zst') "$suffix new good archive kept"
            Assert-FileExists $badPath "$suffix the failed archive is left for the operator"
        } finally { Remove-TestDir $root }
    }
}

# Same, when the first-choice name is taken (two failed runs in one _HHmm
# minute, or a leftover): the rename must pick a free name, never fall back to
# leaving the archive under its retention-visible one.
function Test-FailedVerifyWithBadNameTakenStillLeavesTheFilter {
    $good = @('ubuntu_2026-08-01_0100.tar.zst', 'ubuntu_2026-08-02_0100.tar.zst',
              'ubuntu_2026-08-03_0100.tar.zst')
    $root = New-BackupSandbox -Names ($good + 'ubuntu_2026-09-01_0100.tar.zst.bad')
    try {
        $bad = Invoke-BackupScenario -BackupRoot $root -Keep 3 -VerifyExit 1 -ProbeExit 0 -Stamp '2026-09-01_0100'
        $next = Join-Path $root 'ubuntu_2026-09-01_0100.tar.zst.bad.1'
        Assert-FileExists $next 'taken .bad: the archive went to .bad.1'
        Assert-FileMissing (Join-Path $root 'ubuntu_2026-09-01_0100.tar.zst') 'taken .bad: no ubuntu_*.tar.zst left behind'
        Assert-Contains $bad.Error "moved to $next" 'taken .bad: the throw names .bad.1'

        $ok = Invoke-BackupScenario -BackupRoot $root -Keep 3 -Stamp '2026-09-02_0100'
        Assert-Null $ok.Error 'taken .bad: the next good run succeeds'
        Assert-Eq 1 $ok.Removed.Count "taken .bad: only the oldest good went (removed: $($ok.Removed -join ','))"
        Assert-FileExists (Join-Path $root $good[1]) 'taken .bad: second good kept'
        Assert-FileExists (Join-Path $root $good[2]) 'taken .bad: newest prior good kept'
        Assert-FileExists (Join-Path $root 'ubuntu_2026-09-02_0100.tar.zst') 'taken .bad: new good kept'
        Assert-FileExists $next 'taken .bad: .bad.1 left for the operator'
        Assert-FileExists (Join-Path $root 'ubuntu_2026-09-01_0100.tar.zst.bad') 'taken .bad: the older .bad untouched'
    } finally { Remove-TestDir $root }
}

# --- Archive creation as a unit: export + compress ---------------------------
# New-BackupArchive takes the distro and the tar path and leaves the .zst
# next to it. Shadowed: Invoke-Wsl (the export) and wsl.exe (zstd). The sandbox is a
# real temp dir, so which files exist afterwards is read off the disk.
function Invoke-ArchiveScenario {
    param([switch]$ExportFails, [int]$CompressExit = 0, [switch]$CompressProducesNothing, [string]$Leaf)
    $root = New-TestDir 'backup-archive'
    $dir = $root
    if ($Leaf) { $dir = [IO.Directory]::CreateDirectory((Join-Path $root $Leaf)).FullName }
    $tar = Join-Path $dir 'ubuntu_2026-09-01_0100.tar'
    $script:Removed = @()
    $script:Logs = @()
    $script:WslCalls = @()
    function Invoke-Wsl {
        param([Parameter(Mandatory)][string[]]$Arguments)
        if ($ExportFails) {
            Set-Content -LiteralPath $Arguments[2] -Value 'partial'
            throw 'wsl exited 1: wsl --export'
        }
        Set-Content -LiteralPath $Arguments[2] -Value ('tar' * 100)
    }
    function wsl.exe {
        [CmdletBinding()] param([Parameter(ValueFromRemainingArguments = $true)]$WslArgs)
        $script:WslCalls += (@($WslArgs) -join ' ')
        $win = ConvertFrom-WslPathTest (@($WslArgs)[-1])
        # Unlike Invoke-BackupScenario, a .zst is written whenever it is not
        # suppressed, even on a non-zero exit: zstd can fail after creating its
        # output, and that case must still read as a failure. The tar is kept
        # in that case, as --rm only removes it on success.
        if (-not $CompressProducesNothing) {
            Set-Content -LiteralPath ($win + '.zst') -Value 'compressed'
            if ($CompressExit -eq 0) { Microsoft.PowerShell.Management\Remove-Item -LiteralPath $win -Force }
        }
        $global:LASTEXITCODE = $CompressExit
    }
    $err = $null
    try { New-BackupArchive -Distro 'TestDistro' -TarPath $tar } catch { $err = "$_" }
    [pscustomobject]@{
        Root    = $root
        Error   = $err
        Removed = @($script:Removed)
        Files   = ((Get-ChildItem -LiteralPath $dir -File | Sort-Object Name | ForEach-Object { $_.Name }) -join ',')
        Log     = ($script:Logs -join "`n")
        WslCalls = @($script:WslCalls)
        Tar     = $tar
    }
}

function Test-ArchiveUnitLeavesTheZstAndDropsTheTar {
    $r = Invoke-ArchiveScenario
    try {
        Assert-Null $r.Error 'a good export and compression do not throw'
        Assert-Eq 'ubuntu_2026-09-01_0100.tar.zst' $r.Files 'only the archive is left'
        Assert-Contains $r.Log '[3/6] exporting to' 'the export step is logged'
        Assert-Contains $r.Log '[4/6] compressing with zstd -T0 -3' 'the compression step is logged'
        Assert-Contains $r.Log 'compressed to ' 'the compressed size is logged'
        # --exec, not --: the backup_root-derived path must not pass through a
        # Linux shell (audit #4, item 23).
        Assert-Eq ('-d TestDistro --exec zstd -T0 -3 --rm -q ' + (ConvertTo-WslPath $r.Tar)) ($r.WslCalls -join ' | ') 'zstd is run with --exec, the path as its own argument'
    } finally { Remove-TestDir $r.Root }
}

function Test-ArchiveUnitExportFailureRemovesPartialTar {
    $r = Invoke-ArchiveScenario -ExportFails
    try {
        Assert-NotNull $r.Error 'a failed export throws'
        Assert-Contains "$($r.Error)" 'Export failed; partial tar removed.' 'the throw says the partial tar was cleaned up'
        Assert-Eq 1 $r.Removed.Count 'exactly the partial tar was removed'
        Assert-Eq '' $r.Files 'nothing is left behind'
        Assert-NotContains $r.Log '[4/6]' 'compression never started'
    } finally { Remove-TestDir $r.Root }
}

function Test-ArchiveUnitCompressionFailureKeepsTar {
    foreach ($case in @(@{ Exit = 1; Nothing = $true }, @{ Exit = 0; Nothing = $true }, @{ Exit = 1; Nothing = $false })) {
        $r = Invoke-ArchiveScenario -CompressExit $case.Exit -CompressProducesNothing:$case.Nothing
        $shown = "exit $($case.Exit), .zst written: $(-not $case.Nothing)"
        try {
            Assert-NotNull $r.Error "$shown throws"
            Assert-Contains "$($r.Error)" 'zstd failed on' "$shown names zstd"
            Assert-Contains $r.Log 'keeping the uncompressed tar' "$shown says the tar is being kept"
            Assert-True (@($r.Files -split ',') -contains 'ubuntu_2026-09-01_0100.tar') "$shown kept the uncompressed tar"
            # A partial .zst has the shape retention counts; it must not keep it.
            Assert-False (@($r.Files -split ',') -contains 'ubuntu_2026-09-01_0100.tar.zst') "$shown left no ubuntu_*.tar.zst behind"
            if (-not $case.Nothing) {
                Assert-True (@($r.Files -split ',') -contains 'ubuntu_2026-09-01_0100.tar.zst.bad') "$shown renamed the partial archive to .bad"
                Assert-Contains "$($r.Error)" 'moved to ' "$shown names the partial archive's new path"
            }
        } finally { Remove-TestDir $r.Root }
    }
}

# --- Archive verification as a unit: only wsl.exe shadowed ------------------
# Test-BackupArchive takes the distro and the archive path; it reads no config
# and touches no files, so the one shadow is the wsl.exe it calls.
function Invoke-VerifyScenario {
    param([int]$VerifyExit = 0, [int]$ProbeExit = 0, [switch]$RenameFails)
    if ($RenameFails) {
        function Rename-Item { [CmdletBinding()] param([string]$LiteralPath, [string]$NewName) throw 'access denied' }
    }
    $script:Logs = @()
    $script:WslCalls = @()
    $root = New-TestDir 'backup-verify'
    $archive = Join-Path $root 'ubuntu_x.tar.zst'
    Set-Content -LiteralPath $archive -Value 'compressed'
    function wsl.exe {
        [CmdletBinding()] param([Parameter(ValueFromRemainingArguments = $true)]$WslArgs)
        $joined = @($WslArgs) -join ' '
        $script:WslCalls += $joined
        if ($joined -like '*zstd -t*') { $global:LASTEXITCODE = $VerifyExit; return }
        if ($joined -like '*true*') { $global:LASTEXITCODE = $ProbeExit; return }
        $global:LASTEXITCODE = 0
    }
    $err = $null
    try { Test-BackupArchive -Distro 'TestDistro' -ArchivePath $archive } catch { $err = "$_" }
    $files = (Get-ChildItem -LiteralPath $root -File | ForEach-Object { $_.Name }) -join ','
    Remove-TestDir $root
    [pscustomobject]@{ Error = $err; Log = ($script:Logs -join "`n"); WslCalls = @($script:WslCalls); Archive = $archive; Files = $files }
}

function Test-VerifyUnitPassesAGoodArchive {
    $r = Invoke-VerifyScenario
    Assert-Null $r.Error 'zstd -t exit 0 does not throw'
    Assert-Contains $r.Log '[5/6] verifying the new archive with zstd -t' 'the step banner is logged'
    Assert-Contains $r.Log 'archive verified' 'success is logged'
    Assert-Contains ($r.WslCalls -join ' | ') ('-d TestDistro --exec zstd -t ' + (ConvertTo-WslPath $r.Archive)) 'the WSL path of the archive is tested, through --exec'
    Assert-Eq 1 $r.WslCalls.Count 'no liveness probe when the check passed'
    Assert-Eq 'ubuntu_x.tar.zst' $r.Files 'a verified archive keeps its name'
}

function Test-VerifyUnitReportsCorruptionWhenDistroIsUp {
    $r = Invoke-VerifyScenario -VerifyExit 1 -ProbeExit 0
    Assert-NotNull $r.Error 'a failed zstd -t throws'
    Assert-Contains "$($r.Error)" "Integrity check failed on $($r.Archive)" 'the throw names the archive'
    Assert-Eq 'ubuntu_x.tar.zst.bad' $r.Files 'a corrupt archive is renamed to .bad'
    Assert-Contains "$($r.Error)" "moved to $($r.Archive).bad" 'the throw names the renamed path'
    Assert-Contains $r.Log "renamed to $($r.Archive).bad" 'the rename is logged'
    Assert-Contains "$($r.Error)" 'reports the archive as corrupt' 'a live distro means the verdict really is corruption'
    Assert-Contains "$($r.Error)" 'keeping all existing backups' 'the throw states nothing will be deleted'
    Assert-NotContains $r.Log 'archive verified' 'no success line'
}

function Test-VerifyUnitReportsUnverifiedWhenDistroIsDown {
    $r = Invoke-VerifyScenario -VerifyExit 1 -ProbeExit 1
    Assert-NotNull $r.Error 'an unrunnable check throws'
    Assert-Contains "$($r.Error)" 'could not be run' 'the throw says the check never ran'
    Assert-Contains "$($r.Error)" 'UNVERIFIED, not known-bad' 'the archive is not blamed for the distro failing'
    Assert-Contains "$($r.Error)" 'keeping all existing backups' 'it is still fail-closed'
    Assert-Contains "$($r.Error)" 'zstd -t exited 1' 'the original exit code is carried'
    Assert-NotContains "$($r.Error)" 'reports the archive as corrupt' 'no corruption verdict is invented'
    # maint verify globs *.tar.zst, so it cannot see the renamed file; the
    # hint must be a zstd -t on the new path.
    Assert-Contains "$($r.Error)" ('zstd -t ' + (ConvertTo-WslPath "$($r.Archive).unverified")) 'the operator is told how to re-check the renamed file'
    Assert-Eq 'ubuntu_x.tar.zst.unverified' $r.Files 'an unverified archive is renamed to .unverified, not .bad'
    Assert-Contains "$($r.Error)" "moved to $($r.Archive).unverified" 'the throw names the renamed path'
    Assert-Contains $r.Log "renamed to $($r.Archive).unverified" 'the rename is logged'
}

# If no rename works at all, the throw must say loudly that the archive still
# has a name retention counts, so the operator moves it before the next run.
function Test-VerifyUnitSaysLoudlyWhenTheRenameFails {
    foreach ($probe in 0, 1) {
        $r = Invoke-VerifyScenario -VerifyExit 1 -ProbeExit $probe -RenameFails
        Assert-NotNull $r.Error "probe $probe, rename fails: still throws"
        Assert-Contains "$($r.Error)" "NOT RENAMED: still named $($r.Archive)" "probe $probe, rename fails: the throw says the name is unchanged"
        Assert-Contains "$($r.Error)" 'move it out by hand' "probe $probe, rename fails: the throw says what to do"
        Assert-NotContains "$($r.Error)" 'moved to' "probe $probe, rename fails: no false claim it was moved"
        Assert-Eq 'ubuntu_x.tar.zst' $r.Files "probe $probe, rename fails: the file is where it was"
    }
}

# --- A successful run rotates, after a real clean -----------------------------
# Retention's own rules (LastWriteTime order, the filename filter, Keep edge
# cases) are tested on Invoke-BackupRetention directly below. This one proves
# the orchestrator reaches it with the right root and Keep after a good run.
function Test-SuccessfulRunRotatesAfterARealClean {
    $names = @('ubuntu_2026-08-01_0100.tar.zst', 'ubuntu_2026-08-02_0100.tar.zst',
               'ubuntu_2026-08-03_0100.tar.zst', 'ubuntu_2026-08-04_0100.tar.zst',
               'ubuntu_2026-08-05_0100.tar.zst')
    $root = New-BackupSandbox -Names $names
    try {
        $r = Invoke-BackupScenario -BackupRoot $root -Keep 3

        Assert-Null $r.Error 'a clean run does not throw'
        # 5 old + 1 new = 6, keep 3 -> the 3 oldest go.
        Assert-Eq 3 $r.Removed.Count "exactly three files were deleted (removed: $($r.Removed -join ','))"
        Assert-FileExists (Join-Path $root $names[4]) 'newest pre-existing kept'
        Assert-Eq 3 (Get-ChildItem -LiteralPath $root -Filter 'ubuntu_*.tar.zst' -File).Count 'exactly Keep archives remain'
        Assert-Contains $r.Log 'backup complete' 'the run reports completion'
        # The counterpart to Test-DryRunProducesNoArchiveAndNoDeletion's
        # '-DryRun forwards --dry-run': a run WITHOUT -DryRun must not invent
        # it, or `backup`/`full` would preview a clean and never perform one.
        Assert-Contains ($r.WslCalls -join ' | ') 'clean' 'the clean was invoked at all'
        Assert-NotContains ($r.WslCalls -join ' | ') '--dry-run' 'a real backup runs a real clean, not a dry one'
    } finally { Remove-TestDir $root }
}

# -NoClean exists for the first backup: one taken before anything is deleted.
# It must skip both the consent preview and the clean, and still export.
function Test-NoCleanSkipsTheCleanAndStillBacksUp {
    $root = New-BackupSandbox -Names @()
    try {
        $r = Invoke-BackupScenario -BackupRoot $root -NoClean
        $calls = $r.WslCalls -join ' | '

        Assert-Null $r.Error 'a -NoClean run does not throw'
        Assert-NotContains $calls 'confirm' 'no large-deletion preview'
        Assert-NotContains $calls 'clean' 'no clean call reached WSL'
        Assert-Contains $calls '--export' 'the export still ran'
        Assert-Contains $r.Log 'clean skipped (-NoClean)' 'the skip is logged'
        Assert-Eq 1 (Get-ChildItem -LiteralPath $root -Filter 'ubuntu_*.tar.zst' -File).Count 'one archive was produced'
    } finally { Remove-TestDir $root }
}

# --- Retention as a unit: no WSL, no config, just a directory ---------------
# Called directly: the only shadow in play is the file-wide Remove-Item guard.
function Test-RetentionUnitKeepsNewestByLastWriteTime {
    # Names sort the OPPOSITE way to their LastWriteTime, so a sort by name
    # would delete the wrong three.
    $names = @('ubuntu_2026-08-06_0100.tar.zst', 'ubuntu_2026-08-05_0100.tar.zst',
               'ubuntu_2026-08-04_0100.tar.zst', 'ubuntu_2026-08-03_0100.tar.zst',
               'ubuntu_2026-08-02_0100.tar.zst', 'ubuntu_2026-08-01_0100.tar.zst')
    $root = New-BackupSandbox -Names $names
    try {
        $script:Removed = @()
        $script:Logs = @()
        Invoke-BackupRetention -BackupRoot $root -Keep 3 -Distro Ubuntu

        Assert-Eq 3 $script:Removed.Count "exactly three files were deleted (removed: $($script:Removed -join ','))"
        Assert-FileMissing (Join-Path $root $names[0]) 'oldest by LastWriteTime deleted'
        Assert-FileMissing (Join-Path $root $names[1]) 'second oldest deleted'
        Assert-FileMissing (Join-Path $root $names[2]) 'third oldest deleted'
        Assert-FileExists (Join-Path $root $names[3]) 'third newest kept'
        Assert-FileExists (Join-Path $root $names[4]) 'second newest kept'
        Assert-FileExists (Join-Path $root $names[5]) 'newest kept'
        Assert-Contains ($script:Logs -join "`n") '[6/6] retention: keeping newest 3' 'the step banner is logged'
        Assert-Contains ($script:Logs -join "`n") 'removing old backup: ubuntu_2026-08-06_0100.tar.zst' 'each removal is logged by name'
    } finally { Remove-TestDir $root }
}

# The filter is the literal ubuntu_*.tar.zst shape. A legacy uncompressed .tar,
# an unrelated archive, a .bak, or any other file in the directory must never
# be touched.
function Test-RetentionUnitNeverTouchesNonMatchingFilenames {
    $keepers = @('notes.txt', 'ubuntu_2026-01-01_0100.tar', 'other_2026-01-01.tar.zst',
                 'ubuntu_2026-01-01_0100.tar.zst.bak', 'ubuntu-2026-01-01.tar.zst',
                 'ubuntu_2026-01-01_0100.tar.zst.bad', 'ubuntu_2026-01-01_0100.tar.zst.unverified',
                 'ubuntu_2026-01-01_0100.tar.zstd')
    $names = @('ubuntu_2026-08-01_0100.tar.zst', 'ubuntu_2026-08-02_0100.tar.zst',
               'ubuntu_2026-08-03_0100.tar.zst', 'ubuntu_2026-08-04_0100.tar.zst',
               'ubuntu_2026-08-05_0100.tar.zst')
    $root = New-BackupSandbox -Names ($keepers + $names)
    try {
        $script:Removed = @()
        Invoke-BackupRetention -BackupRoot $root -Keep 3 -Distro Ubuntu

        Assert-Eq 2 $script:Removed.Count "only the two oldest archives went (removed: $($script:Removed -join ','))"
        # Each keeper is a different near-miss of the ubuntu_*.tar.zst glob, so
        # these need to be per-name.
        foreach ($k in $keepers) {
            Assert-FileExists (Join-Path $root $k) "non-matching file $k was left alone"
        }
    } finally { Remove-TestDir $root }
}

function Test-RetentionUnitDoesNothingAtOrBelowKeep {
    $root = New-BackupSandbox -Names @('ubuntu_2026-08-01_0100.tar.zst', 'ubuntu_2026-08-02_0100.tar.zst',
                                       'ubuntu_2026-08-03_0100.tar.zst')
    $one = New-BackupSandbox -Names @('ubuntu_2026-08-01_0100.tar.zst')
    $empty = New-TestDir 'backup-empty'
    try {
        $script:Removed = @()
        Invoke-BackupRetention -BackupRoot $root -Keep 3 -Distro Ubuntu
        Assert-Eq 0 $script:Removed.Count 'exactly Keep archives means no deletion'
        Assert-Eq 3 (Get-ChildItem -LiteralPath $root -File).Count 'all three survive'

        Invoke-BackupRetention -BackupRoot $one -Keep 3 -Distro Ubuntu
        Assert-Eq 0 $script:Removed.Count 'fewer than Keep archives means no deletion'
        Assert-Eq 1 (Get-ChildItem -LiteralPath $one -File).Count 'the only archive survives'

        $err = $null
        try { Invoke-BackupRetention -BackupRoot $empty -Keep 3 -Distro Ubuntu } catch { $err = "$_" }
        Assert-Null $err 'an empty directory does not throw'
        Assert-Eq 0 $script:Removed.Count 'an empty directory deletes nothing'
    } finally { Remove-TestDir $root; Remove-TestDir $one; Remove-TestDir $empty }
}

# --- Failure paths upstream of retention -------------------------------------
function Test-DeniedConsentAbortsBeforeTheCleanCall {
    $root = New-BackupSandbox -Names @('ubuntu_2026-08-01_0100.tar.zst')
    try {
        $r = Invoke-BackupScenario -BackupRoot $root -ConsentDenied

        Assert-NotNull $r.Error 'a denied prompt aborts the backup'
        Assert-Contains $r.Error 'Aborted by user before cleaning.' 'the abort reason is explicit'
        Assert-NotContains ($r.WslCalls -join ' | ') '/wsl/maint clean' 'no maint clean was ever run'
        Assert-Eq 0 $r.Removed.Count 'nothing was deleted'
        Assert-Eq 1 (Get-ChildItem -LiteralPath $root -File).Count 'no archive was produced'
    } finally { Remove-TestDir $root }
}

function Test-ExportFailureRemovesPartialTarAndThrows {
    $root = New-BackupSandbox -Names @('ubuntu_2026-08-01_0100.tar.zst')
    try {
        $r = Invoke-BackupScenario -BackupRoot $root -ExportFails

        # Partial-tar cleanup itself is a New-BackupArchive unit test; this
        # pins only that the run stops and existing archives survive.
        Assert-Contains $r.Error 'Export failed' 'a failed export aborts the run'
        Assert-NotContains ($r.Removed -join ',') '.tar.zst' 'no existing archive was removed'
        Assert-NotContains $r.Log '[6/6]' 'retention never ran'
    } finally { Remove-TestDir $root }
}

function Test-CompressionFailureKeepsTarAndThrows {
    $root = New-BackupSandbox -Names @('ubuntu_2026-08-01_0100.tar.zst',
                                       'ubuntu_2026-08-02_0100.tar.zst',
                                       'ubuntu_2026-08-03_0100.tar.zst',
                                       'ubuntu_2026-08-04_0100.tar.zst')
    try {
        $r = Invoke-BackupScenario -BackupRoot $root -CompressExit 1 -CompressProducesNothing

        # Keeping the tar is a New-BackupArchive unit test; this pins only
        # that the run stops before retention with every archive intact.
        Assert-Contains $r.Error 'zstd failed on' 'a failed compression aborts the run'
        Assert-Eq 0 $r.Removed.Count 'no retention ran'
        Assert-Eq 4 (Get-ChildItem -LiteralPath $root -Filter 'ubuntu_*.tar.zst' -File).Count 'all four existing archives survived'
    } finally { Remove-TestDir $root }
}

function Test-MissingZstdInDistroThrowsBeforeExport {
    $root = New-BackupSandbox -Names @('ubuntu_2026-08-01_0100.tar.zst')
    try {
        $r = Invoke-BackupScenario -BackupRoot $root -ZstdPresentExit 1

        Assert-NotNull $r.Error 'a distro without zstd refuses to start'
        Assert-Contains $r.Error 'zstd is not installed' 'the reason is named'
        Assert-Eq 1 (Get-ChildItem -LiteralPath $root -File).Count 'no 20 GB tar was produced first'
        Assert-Eq 0 $r.Removed.Count 'nothing was deleted'
    } finally { Remove-TestDir $root }
}

function Test-LowFreeSpaceRefusesToStart {
    $root = New-BackupSandbox -Names @('ubuntu_2026-08-01_0100.tar.zst')
    try {
        $r = Invoke-BackupScenario -BackupRoot $root -FreeGb 39.9

        Assert-NotNull $r.Error 'under 40 GB free refuses to start an export'
        Assert-Contains $r.Error 'refusing to start an export' 'the reason is named'
        Assert-Eq 1 (Get-ChildItem -LiteralPath $root -File).Count 'nothing was written'
        Assert-Eq 0 $r.Removed.Count 'nothing was deleted'
    } finally { Remove-TestDir $root }
}

function Test-DryRunProducesNoArchiveAndNoDeletion {
    $names = @('ubuntu_2026-08-01_0100.tar.zst', 'ubuntu_2026-08-02_0100.tar.zst',
               'ubuntu_2026-08-03_0100.tar.zst', 'ubuntu_2026-08-04_0100.tar.zst',
               'ubuntu_2026-08-05_0100.tar.zst')
    $root = New-BackupSandbox -Names $names
    try {
        $r = Invoke-BackupScenario -BackupRoot $root -DryRun

        Assert-Null $r.Error '-DryRun completes without throwing'
        Assert-Eq 0 $r.Removed.Count '-DryRun deletes nothing even with more than Keep archives'
        Assert-Eq 5 (Get-ChildItem -LiteralPath $root -File).Count 'no new file was created'
        Assert-Contains $r.Log 'DRY would export to' '-DryRun says what it would have exported'
        Assert-Contains $r.Log 'DRY would run: sudo -n fstrim --all' '-DryRun does not really fstrim'
        Assert-Contains ($r.WslCalls -join ' | ') 'clean --dry-run' '-DryRun forwards --dry-run to the real clean call'
    } finally { Remove-TestDir $root }
}

# A dry run must touch nothing: no BackupRoot created on disk, and no
# wsl.exe probe that could start a stopped distro.
function Test-DryRunCreatesNoDirectoryAndStartsNoDistro {
    $parent = New-TestDir 'backup-dry'
    $root = Join-Path $parent 'not-yet'
    try {
        $r = Invoke-BackupScenario -BackupRoot $root -DryRun

        Assert-Null $r.Error '-DryRun on a missing root completes without throwing'
        Assert-False (Test-Path -LiteralPath $root) '-DryRun did not create the backup root'
        Assert-NotContains ($r.WslCalls -join ' | ') 'command -v zstd' '-DryRun did not run the zstd probe in the distro'
        Assert-Contains $r.Log 'DRY would create' '-DryRun says it would create the root'
        Assert-Contains $r.Log 'DRY would check zstd in Ubuntu' '-DryRun says what it would have probed'
    } finally { Remove-TestDir $parent }
}

# The counterpart: a real run still creates the root and probes zstd.
function Test-RealRunCreatesRootAndProbesZstd {
    $parent = New-TestDir 'backup-real'
    $root = Join-Path $parent 'not-yet'
    try {
        $r = Invoke-BackupScenario -BackupRoot $root

        Assert-Null $r.Error 'a real run on a missing root completes'
        Assert-True (Test-Path -LiteralPath $root) 'a real run creates the backup root'
        Assert-Contains ($r.WslCalls -join ' | ') 'command -v zstd' 'a real run probes zstd before exporting'
    } finally { Remove-TestDir $parent }
}

# --- ConvertTo-WslPath -------------------------------------------------------
function Test-ConvertToWslPathMapsDriveLetter {
    Assert-Eq '/mnt/d/backups/wsl-ubuntu/u.tar' (ConvertTo-WslPath 'D:\backups\wsl-ubuntu\u.tar') 'X:\ maps to /mnt/x'
    Assert-Eq '/mnt/d/backups/u.tar' (ConvertTo-WslPath 'D:/backups/u.tar') 'X:/ is a drive path too'
}

# The drive letter is lowercased culture-invariantly: under tr-TR a culture
# ToLower() turns I into dotless i (U+0131), a path WSL does not have.
function Test-ConvertToWslPathLowercasesTheDriveInvariantly {
    $prev = [Threading.Thread]::CurrentThread.CurrentCulture
    try {
        [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('tr-TR')
        Assert-Eq '/mnt/i/wsl/u.tar' (ConvertTo-WslPath 'I:\wsl\u.tar') 'I: maps to /mnt/i under tr-TR'
    } finally {
        [Threading.Thread]::CurrentThread.CurrentCulture = $prev
    }
}

function Test-ConvertToWslPathRefusesNonDrivePaths {
    foreach ($bad in @('\\server\share\backups', 'backups\wsl', 'D:relative')) {
        $err = $null
        try { ConvertTo-WslPath $bad | Out-Null } catch { $err = "$_" }
        Assert-NotNull $err "refused: $bad"
        Assert-Contains "$err" 'must be a local drive path' "the reason is named for: $bad"
    }
}

# --- The distro decides the archive prefix ----------------------------------
# Lowercased distro + "_": the owner's Ubuntu keeps its ubuntu_ archives, and
# a Debian box only ever rotates debian_ ones. Another distro's archives in
# the same directory are not this run's to delete.
function Test-RetentionUnitOnlyTouchesTheDistrosPrefix {
    $names = @('ubuntu_2026-08-01_0100.tar.zst', 'debian_2026-08-02_0100.tar.zst',
               'ubuntu_2026-08-03_0100.tar.zst', 'debian_2026-08-04_0100.tar.zst',
               'debian_2026-08-05_0100.tar.zst')
    $root = New-BackupSandbox -Names $names
    try {
        $script:Removed = @()
        Invoke-BackupRetention -BackupRoot $root -Keep 1 -Distro 'Debian'
        Assert-Eq 2 $script:Removed.Count "only the two older debian_ archives went (removed: $($script:Removed -join ','))"
        Assert-FileMissing (Join-Path $root 'debian_2026-08-02_0100.tar.zst') 'oldest debian_ deleted'
        Assert-FileMissing (Join-Path $root 'debian_2026-08-04_0100.tar.zst') 'second debian_ deleted'
        Assert-FileExists (Join-Path $root 'debian_2026-08-05_0100.tar.zst') 'newest debian_ kept'
        Assert-FileExists (Join-Path $root 'ubuntu_2026-08-01_0100.tar.zst') 'another distro''s archive is untouched'
        Assert-FileExists (Join-Path $root 'ubuntu_2026-08-03_0100.tar.zst') 'another distro''s archive is untouched'
    } finally { Remove-TestDir $root }
}

# Distro "Ubuntu" must not rotate archives of a distro whose name merely
# starts the same way ("Ubuntu_22" -> ubuntu_22_...).
function Test-RetentionUnitIgnoresALongerDistroWithTheSamePrefix {
    $names = @('ubuntu_22_2026-08-01_0100.tar.zst', 'ubuntu_22_2026-08-02_0100.tar.zst',
               'ubuntu_2026-08-03_0100.tar.zst')
    $root = New-BackupSandbox -Names $names
    try {
        $script:Removed = @()
        Invoke-BackupRetention -BackupRoot $root -Keep 1 -Distro 'Ubuntu'
        Assert-Eq 0 $script:Removed.Count "nothing of Ubuntu_22's was deleted (removed: $($script:Removed -join ','))"
    } finally { Remove-TestDir $root }
}

# End to end with distro Debian: the new archive is debian_<stamp>, retention
# counts only debian_ archives, and every wsl call names Debian.
function Test-BackupRunFollowsTheConfiguredDistro {
    $names = @('debian_2026-08-01_0100.tar.zst', 'debian_2026-08-02_0100.tar.zst',
               'debian_2026-08-03_0100.tar.zst', 'ubuntu_2026-08-04_0100.tar.zst',
               'ubuntu_2026-08-05_0100.tar.zst')
    $root = New-BackupSandbox -Names $names
    try {
        $r = Invoke-BackupScenario -BackupRoot $root -Distro 'Debian' -Keep 3 -Stamp '2026-09-01_0100'
        Assert-Null $r.Error 'a Debian backup completes'
        Assert-FileExists (Join-Path $root 'debian_2026-09-01_0100.tar.zst') 'the archive is named after the distro'
        Assert-FileMissing (Join-Path $root 'debian_2026-08-01_0100.tar.zst') 'the oldest debian_ archive rotated out'
        Assert-FileExists (Join-Path $root 'ubuntu_2026-08-04_0100.tar.zst') 'ubuntu_ archives are not counted or deleted'
        Assert-FileExists (Join-Path $root 'ubuntu_2026-08-05_0100.tar.zst') 'ubuntu_ archives are not counted or deleted'
        $calls = @($r.WslCalls | Where-Object { $_ -ne 'confirm' })
        Assert-True ($calls.Count -ge 6) "the run made its wsl calls (saw $($calls.Count))"
        foreach ($c in $calls) { Assert-Contains $c 'Debian' "the distro reaches: $c" }
    } finally { Remove-TestDir $root }
}

# No backup_root in maint.conf: there is no sane place to guess, so backup
# refuses, names the key to set, and never reaches the distro (dry or not).
function Test-MissingBackupRootRefusesAndNamesTheKey {
    foreach ($dry in @($false, $true)) {
        $r = Invoke-BackupScenario -ConfigLines @('distro = Debian', 'keep = 2') -DryRun:$dry
        Assert-NotNull $r.Error "dry=${dry}: backup without backup_root refuses"
        Assert-Contains "$($r.Error)" 'backup_root' "dry=${dry}: the message names the key"
        Assert-Contains "$($r.Error)" 'maint.conf' "dry=${dry}: and the file to set it in"
        Assert-Eq 0 $r.WslCalls.Count "dry=${dry}: no wsl call was made"
        Assert-Eq 0 $r.Removed.Count "dry=${dry}: nothing was deleted"
        Assert-NotContains $r.Log 'DRY would create' "dry=${dry}: no directory is even proposed"
    }
}

# A UNC root is refused up front, before any distro call or export, not
# reported as a corrupt archive at [5/6].
function Test-UncBackupRootRefusedBeforeAnything {
    $r = Invoke-BackupScenario -BackupRoot '\\server\share\backups'

    Assert-NotNull $r.Error 'a UNC backup root is refused'
    Assert-Contains $r.Error 'must be a local drive path' 'the reason is named'
    Assert-Eq 0 $r.WslCalls.Count 'no wsl call was made'
}

# Through the real Get-MaintConfig and WSL_MAINT_CONFIG: the clean step hands
# the override file to wsl/maint, so it does not read the repo-root one.
function Test-BackupCleanCarriesTheConfigOverride {
    $root = New-BackupSandbox -Names @()
    try {
        $r = Invoke-BackupScenario -ConfigLines @("backup_root = $root") -DryRun
        Assert-Null $r.Error 'a dry backup with an override completes'
        $clean = @($r.WslCalls | Where-Object { $_ -like '*/wsl/maint clean*' })
        Assert-Eq 1 $clean.Count "one clean call (calls: $($r.WslCalls -join ' | '))"
        Assert-Match "$clean" '/wsl/maint clean --config /mnt/[a-z]/\S*/backup-conf-[0-9a-f]{12}/maint\.conf --dry-run$' 'the override reaches the clean call'
    } finally { Remove-TestDir $root }
}

# --- Brackets in backup_root are literal, not wildcards ----------------------
# `[` `]` are wildcard syntax to -Path. A root like "D:\Backups [wsl]" made
# Get-Item find no tar, Test-Path miss the good .tar.zst (so the failure branch
# renamed it to .bad and claimed a tar it had already lost), and retention
# never match. Every path call takes -LiteralPath; only -Filter is a pattern.
$script:BracketLeaf = 'Backups [x]'

function Test-ArchiveUnitBracketedRootTakesTheSuccessPath {
    $r = Invoke-ArchiveScenario -Leaf $script:BracketLeaf
    try {
        Assert-Null $r.Error 'a good export and compression under a bracketed root do not throw'
        Assert-Eq 'ubuntu_2026-09-01_0100.tar.zst' $r.Files 'the archive kept its retention name, not .bad'
        Assert-NotContains $r.Log 'compression failed' 'the failure branch was not taken'
        Assert-Contains $r.Log 'compressed to ' 'the compressed size is logged'
    } finally { Remove-TestDir $r.Root }
}

function Test-RetentionUnitBracketedRootPrunes {
    $names = @('ubuntu_2026-08-01_0100.tar.zst', 'ubuntu_2026-08-02_0100.tar.zst',
               'ubuntu_2026-08-03_0100.tar.zst', 'ubuntu_2026-08-04_0100.tar.zst',
               'ubuntu_2026-08-05_0100.tar.zst')
    $root = New-BackupSandbox -Names $names -Leaf $script:BracketLeaf
    try {
        $script:Removed = @()
        Invoke-BackupRetention -BackupRoot $root -Keep 3 -Distro Ubuntu

        Assert-Eq 2 $script:Removed.Count "the two oldest went (removed: $($script:Removed -join ','))"
        Assert-FileMissing (Join-Path $root $names[0]) 'oldest deleted'
        Assert-FileMissing (Join-Path $root $names[1]) 'second oldest deleted'
        Assert-Eq 'ubuntu_2026-08-03_0100.tar.zst,ubuntu_2026-08-04_0100.tar.zst,ubuntu_2026-08-05_0100.tar.zst' (Get-ZstNames $root) 'the newest three remain'
    } finally { Remove-TestDir (Split-Path -Parent $root) }
}

function Test-BackupRunWithBracketedRootRotates {
    $names = @('ubuntu_2026-08-01_0100.tar.zst', 'ubuntu_2026-08-02_0100.tar.zst',
               'ubuntu_2026-08-03_0100.tar.zst')
    $root = New-BackupSandbox -Names $names -Leaf $script:BracketLeaf
    try {
        $r = Invoke-BackupScenario -BackupRoot $root -Keep 3 -Stamp '2026-09-01_0100'

        Assert-Null $r.Error 'a run under a bracketed root completes'
        Assert-Contains $r.Log 'backup complete' 'the run reports completion'
        Assert-Eq 1 $r.Removed.Count "3 old + 1 new, keep 3: the oldest went (removed: $($r.Removed -join ','))"
        Assert-Eq 'ubuntu_2026-08-02_0100.tar.zst,ubuntu_2026-08-03_0100.tar.zst,ubuntu_2026-09-01_0100.tar.zst' (Get-ZstNames $root) 'the new archive and the two newest old ones remain'
    } finally { Remove-TestDir (Split-Path -Parent $root) }
}

function Test-RealRunCreatesABracketedRoot {
    $parent = New-TestDir 'backup-real'
    $root = Join-Path $parent 'not [yet]'
    try {
        $r = Invoke-BackupScenario -BackupRoot $root

        Assert-Null $r.Error 'a real run on a missing bracketed root completes'
        Assert-True (Test-Path -LiteralPath $root) 'the bracketed root was created under its literal name'
    } finally { Remove-TestDir $parent }
}

Test-IntegrityFailureAbortsBeforeAnyDeletion
Test-BackupCleanCarriesTheConfigOverride
Test-SuccessfulRunRotatesAfterARealClean
Test-NoCleanSkipsTheCleanAndStillBacksUp
Test-FailedVerifyDoesNotCostAGoodBackupNextRun
Test-FailedVerifyWithBadNameTakenStillLeavesTheFilter
Test-VerifyUnitSaysLoudlyWhenTheRenameFails
Test-ArchiveUnitLeavesTheZstAndDropsTheTar
Test-ArchiveUnitExportFailureRemovesPartialTar
Test-ArchiveUnitCompressionFailureKeepsTar
Test-VerifyUnitPassesAGoodArchive
Test-VerifyUnitReportsCorruptionWhenDistroIsUp
Test-VerifyUnitReportsUnverifiedWhenDistroIsDown
Test-RetentionUnitKeepsNewestByLastWriteTime
Test-RetentionUnitNeverTouchesNonMatchingFilenames
Test-RetentionUnitDoesNothingAtOrBelowKeep
Test-DeniedConsentAbortsBeforeTheCleanCall
Test-ExportFailureRemovesPartialTarAndThrows
Test-CompressionFailureKeepsTarAndThrows
Test-MissingZstdInDistroThrowsBeforeExport
Test-LowFreeSpaceRefusesToStart
Test-DryRunProducesNoArchiveAndNoDeletion
Test-DryRunCreatesNoDirectoryAndStartsNoDistro
Test-RealRunCreatesRootAndProbesZstd
Test-ConvertToWslPathMapsDriveLetter
Test-ConvertToWslPathLowercasesTheDriveInvariantly
Test-ConvertToWslPathRefusesNonDrivePaths
Test-UncBackupRootRefusedBeforeAnything
Test-MissingBackupRootRefusesAndNamesTheKey
Test-RetentionUnitOnlyTouchesTheDistrosPrefix
Test-RetentionUnitIgnoresALongerDistroWithTheSamePrefix
Test-BackupRunFollowsTheConfiguredDistro
Test-ArchiveUnitBracketedRootTakesTheSuccessPath
Test-RetentionUnitBracketedRootPrunes
Test-BackupRunWithBracketedRootRotates
Test-RealRunCreatesABracketedRoot

Write-AssertSummary
