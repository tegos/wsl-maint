# Windows-side cleanup: TEMP, app junk in %LOCALAPPDATA% and the recycle bin.
# Dot-sourced by maint.ps1.
#
# Every statement through the "N entries" log line is read-only
# (Get-ChildItem/Test-Path), and so is the app-junk walk (Get-AppJunkMatch).
# The -DryRun gate sits immediately before the first side-effecting call in
# each block (Remove-Item for TEMP, Remove-Item for app junk, then
# Clear-RecycleBin); nothing before those gates deletes anything.
#
# Targets: the user TEMP dir and %LOCALAPPDATA%\Temp (the same directory
# unless TEMP was redirected; both are named in README and the usage text),
# files matching $script:AppJunkPatterns or the owner's winclean_extra
# (validated by Get-MaintConfig) untouched for winclean_age days, plus the
# recycle bin. SoftwareDistribution\Download and DISM component cleanup
# are deliberately not included: admin-only, opt-in, never run.
#
# Files in use are skipped by -ErrorAction SilentlyContinue, matching the
# behaviour of the del /q /f /s the old batch file used.

function Test-ReparsePoint {
    # A junction, a directory symlink or a file symlink: the one way a walk
    # that only steps into listed children can leave the tree it started in.
    param([Parameter(Mandatory)]$Item)
    ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
}

function Remove-TempEntry {
    # Windows PowerShell 5.1's Remove-Item -Recurse walks INTO a junction or
    # directory symlink and deletes the TARGET's contents (fixed in PowerShell
    # 6, never in 5.1), so a junction an installer left in %TEMP% pointing at
    # a project turned "clear temp" into emptying that project, silently. A
    # reparse point is removed as a link only: .Delete() is RemoveDirectory /
    # DeleteFile, which never follow one. -Recurse is never used; directories
    # are walked here one entry at a time, so a link nested deeper is caught
    # too, and a directory that still holds something (a locked file) is left
    # for the re-count below to report.
    param([Parameter(Mandatory)]$Item)
    if (Test-ReparsePoint $Item) {
        try { $Item.Delete() } catch { }
        return
    }
    if ($Item.PSIsContainer) {
        foreach ($child in @(Get-ChildItem -LiteralPath $Item.FullName -Force -ErrorAction SilentlyContinue)) {
            Remove-TempEntry $child
        }
        if (@(Get-ChildItem -LiteralPath $Item.FullName -Force -ErrorAction SilentlyContinue).Count -gt 0) { return }
    }
    Remove-Item -LiteralPath $Item.FullName -Force -ErrorAction SilentlyContinue
}

# App junk: files apps leave under %LOCALAPPDATA% and download again when
# they need them. Relative to %LOCALAPPDATA%, `\`-separated, each segment
# matched against one directory level, with `*` and `?` the only wildcards
# (ConvertTo-AppJunkWildcard). Generic on purpose (the repo is public):
# electron-updater's cached installer and crash dumps, the Windows Error
# Reporting folder and the <vendor>\<app>\CrashDumps layout (TechSmith\Snagit)
# some apps use. The owner's winclean_extra patterns are
# appended to these and go through the same walk and gates.
$script:AppJunkPatterns = @(
    '*-updater\installer.exe',
    'CrashDumps\*.dmp',
    '*\*\CrashDumps\*.dmp'
)

function ConvertTo-AppJunkWildcard {
    # One pattern segment as a -like pattern with only `*` and `?` live:
    # backtick, `[` and `]` are escaped so they match themselves. -like would
    # read `[...]` as a character class (so Foo[1] never matched a folder named
    # Foo[1]) and throw on a lone `[`, at match time, after TEMP was emptied.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Segment)
    $Segment -replace '([`\[\]])', '`$1'
}

function Get-AppJunkMatch {
    # Read-only. Every entry under $Base matching $Pattern, as
    # @{ Item; ViaLink }, ViaLink set when a directory on the way is a junction
    # or symlink. Such directories are still walked, so what lies behind one is
    # reported rather than silently missed; the caller refuses to delete it.
    # Windows' own compatibility junctions in %LOCALAPPDATA% (Application Data,
    # History, ...) deny listing, so they yield nothing and no noise.
    # -LiteralPath for the walk and -like on each name: the base (a profile
    # dir with brackets) is never read as a wildcard, only the pattern's `*`
    # and `?` are.
    param([Parameter(Mandatory)][string]$Base, [Parameter(Mandatory)][string]$Pattern)
    $segments = @($Pattern -split '\\' | ForEach-Object { ConvertTo-AppJunkWildcard $_ })
    $level = @([pscustomobject]@{ Dir = $Base; ViaLink = $false })
    for ($i = 0; $i -lt $segments.Count; $i++) {
        $next = @()
        foreach ($node in $level) {
            foreach ($child in @(Get-ChildItem -LiteralPath $node.Dir -Force -ErrorAction SilentlyContinue)) {
                if ($child.Name -notlike $segments[$i]) { continue }
                if ($i -eq $segments.Count - 1) {
                    [pscustomobject]@{ Item = $child; ViaLink = $node.ViaLink }
                } elseif ($child.PSIsContainer) {
                    $next += [pscustomobject]@{ Dir = $child.FullName; ViaLink = ($node.ViaLink -or (Test-ReparsePoint $child)) }
                }
            }
        }
        $level = $next
    }
}

function Invoke-AppJunkClean {
    # Files under $Base (%LOCALAPPDATA%) matching $Patterns, untouched for
    # $AgeDays. Only plain files are deleted, so no pattern can empty a tree
    # or reach outside $Base: a plain directory match is skipped silently (an
    # owner pattern ending in `*` matches folders on every run, a warn each
    # time would be noise), a link or a file reached through one is skipped
    # with a warning. The walk only ever steps from a directory to one of its
    # listed children (Get-ChildItem returns no `..`), so a reparse point is
    # the one way out, and those are refused here.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Base, [Parameter(Mandatory)][string[]]$Patterns, [Parameter(Mandatory)][int]$AgeDays, [switch]$DryRun)
    if (-not $Base -or -not (Test-Path -LiteralPath $Base -PathType Container)) { return }
    $Base = [IO.Path]::GetFullPath($Base).TrimEnd('\')
    $cutoff = (Get-Date).AddDays(-$AgeDays)

    $seen = @{}
    $files = @()
    foreach ($pattern in $Patterns) {
        foreach ($m in @(Get-AppJunkMatch -Base $Base -Pattern $pattern)) {
            $item = $m.Item
            if ($seen.ContainsKey($item.FullName)) { continue }
            $seen[$item.FullName] = $true
            # A directory or junction is refused whatever its age: its
            # LastWriteTime is the link's or the folder's own, not a sign of
            # the content's, and it is never a delete candidate anyway.
            $isLink = Test-ReparsePoint $item
            if ($item.PSIsContainer -and -not $isLink) { continue }
            if (-not $item.PSIsContainer -and $item.LastWriteTime -ge $cutoff) { continue }
            if ($isLink) {
                Write-MaintLog -Level warn -Message "skipped $($item.FullName): a junction or symlink"
                continue
            }
            if ($m.ViaLink) {
                Write-MaintLog -Level warn -Message "skipped $($item.FullName): reached through a junction or symlink, may be outside %LOCALAPPDATA%"
                continue
            }
            $files += $item
        }
    }

    if ($DryRun) {
        $total = 0L
        foreach ($f in $files) {
            $total += $f.Length
            Write-MaintLog -Message "DRY would delete $($f.FullName) ($(Format-Mb $f.Length))"
        }
        Write-MaintLog -Message "DRY app junk would free: $(Format-Mb $total) ($($files.Count) files)"
        return
    }

    # SilentlyContinue: a file the app holds open must not abort the run. So
    # the outcome is read back from the disk: a file Test-Path still sees was
    # not deleted and its bytes are not freed (the clean_run lesson: never
    # report the pre-run sum as reclaimed).
    $freed = 0L
    $gone = 0
    foreach ($f in $files) {
        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $f.FullName) {
            Write-MaintLog -Level warn -Message "$($f.FullName) : not deleted (locked or in use)"
            continue
        }
        $freed += $f.Length
        $gone++
        Write-MaintLog -Message "deleted $($f.FullName) ($(Format-Mb $f.Length))"
    }
    Write-MaintLog -Message "app junk: freed $(Format-Mb $freed) ($gone of $($files.Count) files)"
}

function Invoke-MaintWinClean {
    param([Parameter(Mandatory)][hashtable]$Config, [switch]$DryRun)

    $before = Get-FreeSpaceGb -DriveLetter 'C'
    Write-MaintLog -Message "C: free before: $before GB"

    $targets = @($env:TEMP, (Join-Path $env:LOCALAPPDATA 'Temp')) |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
        Select-Object -Unique

    foreach ($t in $targets) {
        # -LiteralPath on every path call here: a profile dir with brackets
        # (C:\Users\John [x]) read as a wildcard matches a sibling dir instead,
        # and the old -Path calls deleted that sibling.
        $items = @(Get-ChildItem -LiteralPath $t -Force -ErrorAction SilentlyContinue)
        Write-MaintLog -Message ("$t : " + $items.Count + " entries")
        if ($DryRun) {
            Write-MaintLog -Message "DRY would clear $t"
            continue
        }
        $items | ForEach-Object { Remove-TempEntry $_ }
        # -ErrorAction SilentlyContinue above means a locked file does not
        # throw and does not abort the loop (matching del /q /f /s), but that
        # also means a failure is otherwise invisible. Re-count afterwards so
        # a locked/in-use item is reported instead of silently disappearing
        # from the log.
        $remaining = @(Get-ChildItem -LiteralPath $t -Force -ErrorAction SilentlyContinue)
        if ($remaining.Count -gt 0) {
            Write-MaintLog -Level warn -Message ("$t : " + $remaining.Count + " entries left (locked or in use)")
        }
    }

    # A file both lists match is listed and deleted once (Invoke-AppJunkClean's $seen).
    $patterns = @($script:AppJunkPatterns)
    if ($Config.WinCleanExtra) { $patterns += @($Config.WinCleanExtra) }
    Invoke-AppJunkClean -Base $env:LOCALAPPDATA -Patterns $patterns -AgeDays $Config.WinCleanAge -DryRun:$DryRun

    if ($DryRun) {
        Write-MaintLog -Message 'DRY would empty the recycle bin'
    } else {
        # SilentlyContinue keeps a failure from aborting the run; -ErrorVariable
        # keeps it from being logged as success. PS 5.1 reports an already empty
        # bin as Win32 error 3 (path not found), which is not a failure.
        $rbErr = $null
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue -ErrorVariable rbErr
        if (-not $rbErr) {
            Write-MaintLog -Message 'recycle bin emptied'
        } else {
            # One error per drive is possible: classify each, so an empty
            # drive's error 3 cannot hide a real failure behind it.
            $realFailure = $false
            foreach ($e in $rbErr) {
                $ex = $e.Exception
                if ($ex -is [ComponentModel.Win32Exception] -and $ex.NativeErrorCode -eq 3) { continue }
                $realFailure = $true
                Write-MaintLog -Level warn -Message "recycle bin not emptied: $($ex.Message)"
            }
            if (-not $realFailure) {
                Write-MaintLog -Message 'recycle bin already empty'
            }
        }
    }

    $after = Get-FreeSpaceGb -DriveLetter 'C'
    Write-MaintLog -Message "C: free after: $after GB (gained $([math]::Round($after - $before, 2)) GB)"
}
