# Windows-side test runner. Mirrors tests/run.sh: run every Test-*.ps1, echo
# everything except its RESULT line, sum the RESULT lines, print one summary,
# exit non-zero if anything failed.
#
# Run with:  powershell.exe -NoProfile -NonInteractive -File tests\win\Run.ps1
# or from WSL via:  bash tests/run.sh   (which shells out to this file)
#
# ---------------------------------------------------------------------------
# WHAT THIS SUITE CAN AND CANNOT PROVE -- read before adding tests.
#
# Almost every test here works by shadowing a dependency (the one exception,
# Test-BackupConsentNative.ps1, is described below): `function wsl.exe { ... }`
# with a matching [CmdletBinding()] signature really does intercept
# `& wsl.exe`, because Get-Command -All ranks a Function above an Application.
# The same trick works for real cmdlets (Read-Host, Remove-Item, Get-MpPreference).
#
# THE LIMIT, and it is not negotiable: a shadowed PowerShell function is not a
# native process, and its output is NOT subject to native-command stderr-to-
# exception wrapping. Under $ErrorActionPreference = 'Stop', a REAL external
# exe whose stderr is merged with 2>&1 turns its first stderr line into a
# terminating NativeCommandError; a shadowed function never does. So:
#
#   * These tests prove LOGIC: branch decisions, ordering, consent handling,
#     what gets deleted and what survives, what is thrown and when.
#   * These tests CANNOT prove real external-process stream behaviour:
#     stdout/stderr interleaving, UTF-16LE decoding, exit-code plumbing
#     through a real pipe, or NativeCommandError wrapping.
#
# A whole review cycle in this project was lost to exactly that gap: a bug
# where 'Stop' + 2>&1 on a real native process threw before the parser ran,
# which 26 passing shadowed assertions could not see. If a test's subject is
# stream behaviour rather than logic, this suite is the wrong place for it --
# it needs a manual run against the real binary -- or, for the narrow
# NativeCommandError case, a REAL stand-in process: FakeExe.ps1 compiles a
# console program that is put first on PATH, and Test-BackupConsentNative.ps1 runs
# Confirm-LargeDeletion against it under 'Stop'. That covers the wrapping
# hazard only, not the real wsl.exe's encoding or interleaving.
#
# Tests whose coverage is logic-only say so in their own name or comment.
# Keep it that way; do not let a test imply more coverage than it has.
# ---------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

$totalPass = 0
$totalFail = 0

Get-ChildItem -Path $here -Filter 'Test-*.ps1' -File | Sort-Object Name | ForEach-Object {
    [Console]::Out.WriteLine("== $($_.Name)")
    # Scoped to 'Continue' for exactly this call. This runner is itself an
    # instance of the hazard documented above: merging a REAL child process's
    # stderr with 2>&1 under 'Stop' turns its first stderr line into a
    # terminating NativeCommandError -- and a test file's FAIL diagnostics go
    # to stderr, so under 'Stop' the first failing assertion anywhere would
    # kill the whole run before it could print a summary.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & powershell.exe -NoProfile -NonInteractive -File $_.FullName 2>&1 | ForEach-Object { [string]$_ }
    } finally {
        $ErrorActionPreference = $prevEap
    }
    $out | Where-Object { $_ -notlike 'RESULT *' } | ForEach-Object { [Console]::Out.WriteLine($_) }
    $line = @($out | Where-Object { $_ -like 'RESULT *' }) | Select-Object -Last 1
    if ($line) {
        $parts = $line -split '\s+'
        $totalPass += [int]$parts[1]
        $totalFail += [int]$parts[2]
    } else {
        # No RESULT line at all means the file died before it could report.
        [Console]::Error.WriteLine("  FAIL $($_.Name): produced no RESULT line")
        $totalFail += 1
    }
}

[Console]::Out.WriteLine("")
[Console]::Out.WriteLine("passed: $totalPass  failed: $totalFail")
if ($totalFail -ne 0) { exit 1 }
exit 0
