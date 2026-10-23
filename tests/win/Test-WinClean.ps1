# win\WinClean.ps1 -- Invoke-MaintWinClean.
#
# LOGIC-ONLY COVERAGE for the deletion itself: Remove-Item is shadowed to a
# recorder that REFUSES any path outside the system temp root, and
# Clear-RecycleBin is shadowed to a counter so the operator's real recycle bin
# is never emptied by a test run. $env:TEMP and $env:LOCALAPPDATA are pointed
# at per-test sandboxes, so the only files this file can touch are ones it
# created itself.
#
# The first test is a hard precondition: if either shadow is NOT in effect the
# file bails out immediately rather than running the destructive cases.

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent (Split-Path -Parent $here)
. (Join-Path $here 'Assert.ps1')
# Common.ps1 for Format-Mb; its Write-MaintLog and Get-FreeSpaceGb are
# shadowed below, after it, so the shadows win.
. (Join-Path $repo 'win\Common.ps1')
. (Join-Path $repo 'win\WinClean.ps1')

$script:TempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$script:Removed = @()
$script:RecycleBinCleared = 0
$script:Logs = @()
$script:LockedPattern = $null
$script:RecycleBinError = $null

function Remove-Item {
    [CmdletBinding()]
    param([Parameter(Position = 0, ValueFromPipeline = $true)][Alias('LiteralPath')]$Path, [switch]$Force, [switch]$Recurse)
    $full = [IO.Path]::GetFullPath("$Path")
    if (-not $full.StartsWith($script:TempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "TEST GUARD: refused to delete outside temp: $full"
    }
    # Simulates a file held open: production passes -ErrorAction SilentlyContinue,
    # so a failure here must not abort the loop.
    if ($script:LockedPattern -and $full -like $script:LockedPattern) { return }
    $script:Removed += $full
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $full -Force:$Force -Recurse:$Recurse
}

function Clear-RecycleBin {
    [CmdletBinding()] param([switch]$Force)
    # A scripted failure is a non-terminating error, like the real cmdlet's,
    # so production's -ErrorAction decides whether it throws.
    # One error or several: the real cmdlet can report one per drive.
    if ($script:RecycleBinError) {
        foreach ($e in @($script:RecycleBinError)) { Write-Error -Exception $e }
        return
    }
    $script:RecycleBinCleared++
}

function Write-MaintLog { param([string]$Level = 'info', [string]$Message) $script:Logs += "[$Level] $Message" }
function Get-FreeSpaceGb { param($DriveLetter) 42.5 }

function New-CleanSandbox {
    param([int]$Files = 3, [string]$Prefix = 'f')
    $d = New-TestDir 'winclean'
    for ($i = 0; $i -lt $Files; $i++) {
        Set-Content -LiteralPath (Join-Path $d "$Prefix$i.tmp") -Value 'junk'
    }
    $d
}

# A file of $Bytes under $Root\$Rel, last written $AgeDays days ago.
function New-JunkFile {
    param([string]$Root, [string]$Rel, [long]$Bytes = 1MB, [int]$AgeDays = 30)
    $p = Join-Path $Root $Rel
    [IO.Directory]::CreateDirectory((Split-Path -Parent $p)) | Out-Null
    $fs = [IO.File]::Create($p)
    try { $fs.SetLength($Bytes) } finally { $fs.Dispose() }
    [IO.File]::SetLastWriteTime($p, (Get-Date).AddDays(-$AgeDays))
    $p
}

function Invoke-WinCleanScenario {
    param([string]$TempDir, [string]$LocalAppData, [switch]$DryRun, [string]$Locked, $RecycleError, [int]$Age = 14)
    $script:Removed = @()
    $script:RecycleBinCleared = 0
    $script:Logs = @()
    $script:LockedPattern = $Locked
    $script:RecycleBinError = $RecycleError

    $oldTemp = $env:TEMP
    $oldLad = $env:LOCALAPPDATA
    $env:TEMP = $TempDir
    $env:LOCALAPPDATA = $LocalAppData
    $err = $null
    try { Invoke-MaintWinClean -Config @{ WinCleanAge = $Age } -DryRun:$DryRun } catch { $err = "$_" } finally {
        $env:TEMP = $oldTemp
        $env:LOCALAPPDATA = $oldLad
        $script:LockedPattern = $null
        $script:RecycleBinError = $null
    }
    [pscustomobject]@{
        Error    = $err
        Removed  = @($script:Removed)
        Recycled = $script:RecycleBinCleared
        Log      = ($script:Logs -join "`n")
    }
}

# --- Precondition ------------------------------------------------------------
function Test-DestructiveCmdletsAreShadowed {
    $rb = (Get-Command Clear-RecycleBin).CommandType
    $ri = (Get-Command Remove-Item).CommandType
    Assert-Eq 'Function' $rb 'Clear-RecycleBin is shadowed by this test file'
    Assert-Eq 'Function' $ri 'Remove-Item is shadowed by this test file'
    if ($rb -ne 'Function' -or $ri -ne 'Function') {
        [Console]::Error.WriteLine('  ABORT: shadows not in effect, refusing to run destructive tests')
        Write-AssertSummary
        exit 1
    }
}

# --- -DryRun -----------------------------------------------------------------
function Test-DryRunDeletesNothing {
    $t = New-CleanSandbox -Files 3
    $lad = New-TestDir 'winclean-lad'
    New-Item -ItemType Directory -Path (Join-Path $lad 'Temp') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $lad 'Temp\a.tmp') -Value 'junk'
    try {
        $r = Invoke-WinCleanScenario -TempDir $t -LocalAppData $lad -DryRun

        Assert-Null $r.Error '-DryRun does not throw'
        Assert-Eq 0 $r.Removed.Count '-DryRun deletes nothing'
        Assert-Eq 0 $r.Recycled '-DryRun does not empty the recycle bin'
        Assert-Eq 3 (Get-ChildItem -LiteralPath $t -File).Count 'the TEMP files are all still there'
        Assert-Contains $r.Log 'DRY would clear' '-DryRun says what it would clear'
        Assert-Contains $r.Log 'DRY would empty the recycle bin' '-DryRun says it would empty the bin'
        Assert-Contains $r.Log ' : 3 entries' 'the entry count is still reported'
    } finally { Remove-TestDir $t; Remove-TestDir $lad }
}

# --- Real run ----------------------------------------------------------------
function Test-BothTempTargetsAreClearedAndBinEmptied {
    $t = New-CleanSandbox -Files 3 -Prefix 'a'
    $lad = New-TestDir 'winclean-lad'
    $ladTemp = Join-Path $lad 'Temp'
    New-Item -ItemType Directory -Path $ladTemp -Force | Out-Null
    1..2 | ForEach-Object { Set-Content -LiteralPath (Join-Path $ladTemp "b$_.tmp") -Value 'junk' }
    try {
        $r = Invoke-WinCleanScenario -TempDir $t -LocalAppData $lad

        Assert-Null $r.Error 'a real run does not throw'
        Assert-Eq 5 $r.Removed.Count 'every entry in both targets was removed'
        Assert-Eq 0 (Get-ChildItem -LiteralPath $t -Force).Count 'the TEMP target is empty'
        Assert-Eq 0 (Get-ChildItem -LiteralPath $ladTemp -Force).Count 'the LOCALAPPDATA\Temp target is empty'
        Assert-Eq 1 $r.Recycled 'the recycle bin was emptied exactly once'
        Assert-Contains $r.Log 'recycle bin emptied' 'the bin is logged'
        Assert-NotContains $r.Log 'locked or in use' 'nothing was reported stuck'
        Assert-Contains $r.Log 'C: free before: 42.5 GB' 'free space is reported before'
        Assert-Contains $r.Log 'C: free after: 42.5 GB' 'free space is reported after'
    } finally { Remove-TestDir $t; Remove-TestDir $lad }
}

# -ErrorAction SilentlyContinue means a held-open file neither throws nor
# aborts the loop -- but it must not disappear from the log either.
function Test-LockedEntryIsReportedNotSwallowed {
    $t = New-CleanSandbox -Files 2 -Prefix 'ok'
    Set-Content -LiteralPath (Join-Path $t 'locked.tmp') -Value 'held open'
    $lad = New-TestDir 'winclean-lad'
    try {
        $r = Invoke-WinCleanScenario -TempDir $t -LocalAppData $lad -Locked '*locked.tmp'

        Assert-Null $r.Error 'a locked file does not abort the run'
        Assert-Eq 2 $r.Removed.Count 'the other entries were still removed'
        Assert-FileExists (Join-Path $t 'locked.tmp') 'the locked file survives'
        Assert-Contains $r.Log '[warn] ' 'a warning was raised'
        Assert-Contains $r.Log '1 entries left (locked or in use)' 'the stuck entry is counted and reported'
        Assert-Eq 1 $r.Recycled 'the run still finished and emptied the bin'
    } finally { Remove-TestDir $t; Remove-TestDir $lad }
}

# $env:TEMP normally IS %LOCALAPPDATA%\Temp. Select-Object -Unique must stop
# the same directory being walked twice.
function Test-IdenticalTargetsAreDeduplicated {
    $lad = New-TestDir 'winclean-lad'
    $ladTemp = Join-Path $lad 'Temp'
    New-Item -ItemType Directory -Path $ladTemp -Force | Out-Null
    1..4 | ForEach-Object { Set-Content -LiteralPath (Join-Path $ladTemp "c$_.tmp") -Value 'junk' }
    try {
        $r = Invoke-WinCleanScenario -TempDir $ladTemp -LocalAppData $lad

        Assert-Null $r.Error 'no throw'
        Assert-Eq 1 (@($r.Log -split "`n") | Where-Object { $_ -like '* entries' }).Count 'the shared directory is walked once, not twice'
        Assert-Eq 4 $r.Removed.Count 'each file was removed exactly once'
    } finally { Remove-TestDir $lad }
}

function Test-MissingTargetsAreSkipped {
    $lad = New-TestDir 'winclean-lad'
    try {
        # Neither $env:TEMP nor %LOCALAPPDATA%\Temp exists.
        $r = Invoke-WinCleanScenario -TempDir (Join-Path $lad 'no-such-dir') -LocalAppData $lad

        Assert-Null $r.Error 'a missing temp directory is not an error'
        Assert-Eq 0 $r.Removed.Count 'nothing was deleted'
        Assert-Eq 1 $r.Recycled 'the recycle bin step still runs'
        Assert-NotContains $r.Log ' entries' 'no target was reported'
    } finally { Remove-TestDir $lad }
}

# Clear-RecycleBin runs with -ErrorAction SilentlyContinue so a failure does
# not abort the run, but the log must not then claim the bin was emptied.
function Test-FailedRecycleBinIsAWarningNotEmptied {
    $lad = New-TestDir 'winclean-lad'
    try {
        $r = Invoke-WinCleanScenario -TempDir (Join-Path $lad 'no-such-dir') -LocalAppData $lad `
            -RecycleError ([UnauthorizedAccessException]::new('Access is denied'))

        Assert-Null $r.Error 'a failed recycle bin does not abort the run'
        Assert-NotContains $r.Log 'recycle bin emptied' 'a failure is not logged as emptied'
        Assert-Contains $r.Log '[warn] recycle bin not emptied: Access is denied' 'the failure is a warning with the reason'
        Assert-Contains $r.Log 'C: free after:' 'the run still reports free space after'
    } finally { Remove-TestDir $lad }
}

# PS 5.1 Clear-RecycleBin errors with "path not found" (Win32 error 3) when
# the bin is already empty. That is not a failure.
function Test-AlreadyEmptyRecycleBinIsNotAWarning {
    $lad = New-TestDir 'winclean-lad'
    try {
        $r = Invoke-WinCleanScenario -TempDir (Join-Path $lad 'no-such-dir') -LocalAppData $lad `
            -RecycleError ([ComponentModel.Win32Exception]::new(3))

        Assert-Null $r.Error 'an already empty bin does not abort the run'
        Assert-NotContains $r.Log '[warn]' 'an already empty bin is not a warning'
        Assert-Contains $r.Log 'recycle bin already empty' 'an already empty bin is logged as such'
    } finally { Remove-TestDir $lad }
}

# Several errors (one per drive): each is classified, not only the first.
# An "already empty" drive must not hide a real failure behind it.
function Test-EveryRecycleBinErrorIsClassified {
    $lad = New-TestDir 'winclean-lad'
    try {
        $r = Invoke-WinCleanScenario -TempDir (Join-Path $lad 'no-such-dir') -LocalAppData $lad `
            -RecycleError @([ComponentModel.Win32Exception]::new(3),
                            [UnauthorizedAccessException]::new('Access is denied'),
                            [IO.IOException]::new('Disk is busy'))

        Assert-Null $r.Error 'mixed recycle bin errors do not abort the run'
        Assert-Contains $r.Log '[warn] recycle bin not emptied: Access is denied' 'the second error is warned'
        Assert-Contains $r.Log '[warn] recycle bin not emptied: Disk is busy' 'the third error is warned'
        Assert-NotContains $r.Log 'already empty' 'not "already empty" when a real error is present'
        Assert-NotContains $r.Log 'recycle bin emptied' 'not logged as emptied'
    } finally { Remove-TestDir $lad }
}

# Every drive reporting error 3 is still just an empty bin.
function Test-AllAlreadyEmptyErrorsAreNotAWarning {
    $lad = New-TestDir 'winclean-lad'
    try {
        $r = Invoke-WinCleanScenario -TempDir (Join-Path $lad 'no-such-dir') -LocalAppData $lad `
            -RecycleError @([ComponentModel.Win32Exception]::new(3), [ComponentModel.Win32Exception]::new(3))

        Assert-NotContains $r.Log '[warn]' 'two error-3 drives are not a warning'
        Assert-Contains $r.Log 'recycle bin already empty' 'logged as already empty'
    } finally { Remove-TestDir $lad }
}

# A profile dir with brackets (C:\Users\John [x]) puts them in TEMP. Read as a
# wildcard, `Tmp [ab]` names no such dir and matches the sibling `Tmp a`
# instead, so the old -Path calls cleared the wrong directory.
function Test-BracketedTempIsClearedLiterallyNotItsWildcardSibling {
    $root = New-TestDir 'winclean-brackets'
    $target = [IO.Directory]::CreateDirectory((Join-Path $root 'Tmp [ab]')).FullName
    $sibling = [IO.Directory]::CreateDirectory((Join-Path $root 'Tmp a')).FullName
    1..2 | ForEach-Object { Set-Content -LiteralPath (Join-Path $target "t$_.tmp") -Value 'junk' }
    1..3 | ForEach-Object { Set-Content -LiteralPath (Join-Path $sibling "keep$_.tmp") -Value 'keep' }
    try {
        $r = Invoke-WinCleanScenario -TempDir $target -LocalAppData $root

        Assert-Null $r.Error 'a bracketed TEMP does not throw'
        Assert-Eq 0 (Get-ChildItem -LiteralPath $target -Force).Count 'the bracketed TEMP is emptied'
        # The old wildcard did not stop at the sibling's children: it removed
        # the sibling dir itself, so check it exists before counting in it.
        Assert-True (Test-Path -LiteralPath $sibling -PathType Container) 'the sibling the wildcard matches still exists'
        $kept = @(if (Test-Path -LiteralPath $sibling) { Get-ChildItem -LiteralPath $sibling -Force })
        Assert-Eq 3 $kept.Count 'the sibling the wildcard matches is untouched'
        Assert-Eq 2 $r.Removed.Count 'exactly the two TEMP entries were removed'
        Assert-Contains $r.Log 'Tmp [ab] : 2 entries' 'the bracketed dir is counted by its literal name'
    } finally { Remove-TestDir $root }
}

# PS 5.1's Remove-Item -Recurse follows a junction into its target. A junction
# in %TEMP% (top level, and nested inside a directory) must go as a link, with
# every file behind it untouched. Junctions need no privilege, unlike symlinks.
# The target lives in its own sandbox: a .Delete() on the link bypasses the
# Remove-Item shadow, so this test asserts on the filesystem.
function Test-JunctionInTempIsRemovedAsALinkNotFollowed {
    $t = New-CleanSandbox -Files 1 -Prefix 'j'
    $lad = New-TestDir 'winclean-lad'
    $target = New-TestDir 'winclean-junction-target'
    1..3 | ForEach-Object { Set-Content -LiteralPath (Join-Path $target "keep$_.txt") -Value 'keep' }
    $nested = Join-Path $t 'build'
    New-Item -ItemType Directory -Path $nested -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $nested 'obj.tmp') -Value 'junk'
    try {
        New-Item -ItemType Junction -Path (Join-Path $t 'link') -Target $target | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $nested 'link2') -Target $target | Out-Null

        $r = Invoke-WinCleanScenario -TempDir $t -LocalAppData $lad

        Assert-Null $r.Error 'a junction in TEMP does not throw'
        Assert-Eq 3 @(Get-ChildItem -LiteralPath $target -Force).Count 'every file behind the junctions survives'
        Assert-False (Test-Path -LiteralPath (Join-Path $t 'link')) 'the top-level junction itself is gone'
        Assert-False (Test-Path -LiteralPath $nested) 'the directory holding a nested junction is gone'
        Assert-Eq 0 @(Get-ChildItem -LiteralPath $t -Force).Count 'TEMP is empty afterwards'
        Assert-NotContains $r.Log 'entries left' 'nothing is reported stuck'
    } finally { Remove-TestDir $t; Remove-TestDir $lad; Remove-TestDir $target }
}

# --- App junk in %LOCALAPPDATA% ----------------------------------------------
# One match per built-in pattern, all older than the default 14 days.
function New-AppJunkSandbox {
    $lad = New-TestDir 'winclean-lad'
    [pscustomobject]@{
        Root      = $lad
        Installer = New-JunkFile $lad 'obsidian-updater\installer.exe' -Bytes 1MB
        Dump      = New-JunkFile $lad 'CrashDumps\app.exe.123.dmp' -Bytes 2MB
        AppDump   = New-JunkFile $lad 'TechSmith\Snagit\CrashDumps\snagit.dmp' -Bytes 1MB
    }
}

function Test-AppJunkDryRunListsEachMatchWithSizeAndDeletesNothing {
    $j = New-AppJunkSandbox
    try {
        $r = Invoke-WinCleanScenario -TempDir (Join-Path $j.Root 'no-such-dir') -LocalAppData $j.Root -DryRun

        Assert-Null $r.Error '-DryRun does not throw'
        Assert-Eq 0 $r.Removed.Count '-DryRun deletes no app junk'
        foreach ($f in $j.Installer, $j.Dump, $j.AppDump) { Assert-FileExists $f "still there: $f" }
        Assert-Contains $r.Log "DRY would delete $($j.Installer) (1.0 MB)" 'the updater installer is listed with its size'
        Assert-Contains $r.Log "DRY would delete $($j.Dump) (2.0 MB)" 'a top-level crash dump is listed with its size'
        Assert-Contains $r.Log "DRY would delete $($j.AppDump) (1.0 MB)" 'an app crash dump is listed with its size'
        Assert-Contains $r.Log 'DRY app junk: 3 files, 4.0 MB' 'the total is logged'
    } finally { Remove-TestDir $j.Root }
}

function Test-AppJunkRealRunDeletesEveryMatch {
    $j = New-AppJunkSandbox
    try {
        $r = Invoke-WinCleanScenario -TempDir (Join-Path $j.Root 'no-such-dir') -LocalAppData $j.Root

        Assert-Null $r.Error 'a real run does not throw'
        Assert-Eq 3 $r.Removed.Count 'each match went through Remove-Item'
        foreach ($f in $j.Installer, $j.Dump, $j.AppDump) { Assert-FileMissing $f "deleted: $f" }
        Assert-True (Test-Path -LiteralPath (Join-Path $j.Root 'TechSmith\Snagit\CrashDumps') -PathType Container) 'the folder holding a dump is left in place'
        Assert-Contains $r.Log "deleted $($j.Dump) (2.0 MB)" 'each deletion is logged with its size'
        Assert-Contains $r.Log 'app junk: freed 4.0 MB (3 of 3 files)' 'the freed total is logged'
        Assert-NotContains $r.Log '[warn]' 'nothing was reported stuck'
    } finally { Remove-TestDir $j.Root }
}

# Remove-Item runs with -ErrorAction SilentlyContinue, so a file an app holds
# open is neither an error nor freed space: only what Test-Path no longer sees
# counts, never the pre-run sum.
function Test-AppJunkLockedFileIsAWarnAndNotCountedAsFreed {
    $j = New-AppJunkSandbox
    try {
        $r = Invoke-WinCleanScenario -TempDir (Join-Path $j.Root 'no-such-dir') -LocalAppData $j.Root -Locked '*\CrashDumps\app.exe.123.dmp'

        Assert-Null $r.Error 'a locked file does not abort the run'
        Assert-FileExists $j.Dump 'the locked dump survives'
        Assert-FileMissing $j.Installer 'the other matches are still deleted'
        Assert-Contains $r.Log "[warn] $($j.Dump) : not deleted (locked or in use)" 'the locked file is a warn line'
        Assert-NotContains $r.Log "deleted $($j.Dump)" 'the locked file is not logged as deleted'
        Assert-Contains $r.Log 'app junk: freed 2.0 MB (2 of 3 files)' 'the 2 MB still on disk is not counted as freed'
        Assert-Eq 1 $r.Recycled 'the run still goes on to the recycle bin'
    } finally { Remove-TestDir $j.Root }
}

# An in-progress crash report or a pending update is recent: only files
# untouched for winclean_age days are junk, and a fresh one is not even listed.
function Test-AppJunkNewerThanAgeIsKeptAndNotListed {
    $lad = New-TestDir 'winclean-lad'
    $old = New-JunkFile $lad 'CrashDumps\old.dmp' -AgeDays 20
    $fresh = New-JunkFile $lad 'CrashDumps\fresh.dmp' -AgeDays 5
    $pending = New-JunkFile $lad 'ueli-updater\installer.exe' -AgeDays 0
    try {
        $r = Invoke-WinCleanScenario -TempDir (Join-Path $lad 'no-such-dir') -LocalAppData $lad -DryRun
        Assert-Contains $r.Log "DRY would delete $old" 'a dump older than 14 days is listed'
        Assert-NotContains $r.Log 'fresh.dmp' 'a dump younger than 14 days is not listed'
        Assert-NotContains $r.Log 'ueli-updater' 'an installer written today is not listed'

        $r = Invoke-WinCleanScenario -TempDir (Join-Path $lad 'no-such-dir') -LocalAppData $lad
        Assert-FileMissing $old 'the old dump is deleted'
        Assert-FileExists $fresh 'the fresh dump is kept'
        Assert-FileExists $pending 'the fresh installer is kept'
        Assert-Contains $r.Log 'app junk: freed 1.0 MB (1 of 1 files)' 'kept files are not part of the count'

        # The gate is winclean_age, not a constant.
        $r = Invoke-WinCleanScenario -TempDir (Join-Path $lad 'no-such-dir') -LocalAppData $lad -DryRun -Age 3
        Assert-Contains $r.Log "DRY would delete $fresh" 'winclean_age = 3 lists a 5-day-old dump'
        Assert-NotContains $r.Log 'ueli-updater' 'winclean_age = 3 still keeps a file written today'
    } finally { Remove-TestDir $lad }
}

# A vendor folder moved to another drive and linked back is the realistic
# case: the dump behind the junction lies outside %LOCALAPPDATA%, so it is
# reported, never deleted. Junctions need no privilege, unlike symlinks.
function Test-AppJunkBehindAJunctionIsSkippedWithAWarn {
    $lad = New-TestDir 'winclean-lad'
    $outside = New-TestDir 'winclean-outside'
    $dump = New-JunkFile $outside 'CrashDumps\moved.dmp'
    try {
        New-Item -ItemType Directory -Path (Join-Path $lad 'Vendor') -Force | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $lad 'Vendor\App') -Target $outside | Out-Null
        $seen = Join-Path $lad 'Vendor\App\CrashDumps\moved.dmp'

        $r = Invoke-WinCleanScenario -TempDir (Join-Path $lad 'no-such-dir') -LocalAppData $lad

        Assert-Null $r.Error 'a junction on the way does not throw'
        Assert-FileExists $dump 'the dump behind the junction survives'
        Assert-Eq 0 $r.Removed.Count 'nothing went through Remove-Item'
        Assert-Contains $r.Log "[warn] skipped ${seen}: reached through a junction or symlink" 'the skip is a warn line naming the path'
    } finally { Remove-TestDir $lad; Remove-TestDir $outside }
}

# The match itself a junction (named like a dump), or a real directory: only
# files are deleted, so neither the link nor anything in or behind it goes.
function Test-AppJunkDirectoryOrJunctionMatchIsNeverDeleted {
    $lad = New-TestDir 'winclean-lad'
    $outside = New-TestDir 'winclean-outside'
    $behind = New-JunkFile $outside 'keep.txt'
    $inside = New-JunkFile $lad 'CrashDumps\folder.dmp\keep.txt'
    [IO.Directory]::SetLastWriteTime((Join-Path $lad 'CrashDumps\folder.dmp'), (Get-Date).AddDays(-30))
    $link = Join-Path $lad 'CrashDumps\link.dmp'
    try {
        New-Item -ItemType Junction -Path $link -Target $outside | Out-Null

        $r = Invoke-WinCleanScenario -TempDir (Join-Path $lad 'no-such-dir') -LocalAppData $lad

        Assert-Null $r.Error 'a directory match does not throw'
        Assert-Eq 0 $r.Removed.Count 'nothing went through Remove-Item'
        Assert-FileExists $inside 'the directory match and its content survive'
        Assert-True (Test-Path -LiteralPath $link) 'the junction match survives'
        Assert-FileExists $behind 'the file behind the junction survives'
        Assert-Contains $r.Log "[warn] skipped $(Join-Path $lad 'CrashDumps\folder.dmp'): a directory, only files are deleted" 'the directory is a warn line'
        Assert-Contains $r.Log "[warn] skipped ${link}: a junction or symlink" 'the junction is a warn line'
        Assert-Contains $r.Log 'app junk: freed 0.0 MB (0 of 0 files)' 'nothing is counted'
    } finally { Remove-TestDir $lad; Remove-TestDir $outside }
}

# The same bracket hazard as TEMP: a profile dir `Local [ab]` read as a
# wildcard would walk the sibling `Local a` instead.
function Test-AppJunkUnderABracketedLocalAppDataIsMatchedLiterally {
    $root = New-TestDir 'winclean-brackets'
    $lad = [IO.Directory]::CreateDirectory((Join-Path $root 'Local [ab]')).FullName
    $sibling = [IO.Directory]::CreateDirectory((Join-Path $root 'Local a')).FullName
    $mine = New-JunkFile $lad 'CrashDumps\mine.dmp'
    $theirs = New-JunkFile $sibling 'CrashDumps\theirs.dmp'
    try {
        $r = Invoke-WinCleanScenario -TempDir (Join-Path $root 'no-such-dir') -LocalAppData $lad

        Assert-FileMissing $mine 'the dump under the bracketed dir is deleted'
        Assert-FileExists $theirs 'the sibling the wildcard matches is untouched'
        Assert-Contains $r.Log 'app junk: freed 1.0 MB (1 of 1 files)' 'exactly one file counted'
    } finally { Remove-TestDir $root }
}

Test-DestructiveCmdletsAreShadowed
Test-DryRunDeletesNothing
Test-JunctionInTempIsRemovedAsALinkNotFollowed
Test-BothTempTargetsAreClearedAndBinEmptied
Test-LockedEntryIsReportedNotSwallowed
Test-IdenticalTargetsAreDeduplicated
Test-MissingTargetsAreSkipped
Test-FailedRecycleBinIsAWarningNotEmptied
Test-AlreadyEmptyRecycleBinIsNotAWarning
Test-EveryRecycleBinErrorIsClassified
Test-AllAlreadyEmptyErrorsAreNotAWarning
Test-BracketedTempIsClearedLiterallyNotItsWildcardSibling
Test-AppJunkDryRunListsEachMatchWithSizeAndDeletesNothing
Test-AppJunkRealRunDeletesEveryMatch
Test-AppJunkLockedFileIsAWarnAndNotCountedAsFreed
Test-AppJunkNewerThanAgeIsKeptAndNotListed
Test-AppJunkBehindAJunctionIsSkippedWithAWarn
Test-AppJunkDirectoryOrJunctionMatchIsNeverDeleted
Test-AppJunkUnderABracketedLocalAppDataIsMatchedLiterally

Write-AssertSummary
