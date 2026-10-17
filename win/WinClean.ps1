# Windows-side cleanup: TEMP and recycle bin. Dot-sourced by maint.ps1.
#
# Every statement through the "N entries" log line is read-only
# (Get-ChildItem/Test-Path). The -DryRun gate sits immediately before the
# first side-effecting call in each block (Remove-Item, then Clear-RecycleBin);
# nothing before those two gates deletes anything.
#
# Targets match cleanup-windows.bat items 1-2 exactly: the user TEMP dir and
# %LOCALAPPDATA%\Temp, plus the recycle bin. Item 3 (recycle bin) is kept;
# items 4-5 of the old batch file (SoftwareDistribution\Download, DISM
# component cleanup) were commented out there too - admin-only, opt-in, never
# run - and are intentionally not ported here.
#
# Files in use are skipped by -ErrorAction SilentlyContinue, matching the
# behaviour of the del /q /f /s the old batch file used.

function Invoke-MaintWinClean {
    param([switch]$DryRun)

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
        $items | ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
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
