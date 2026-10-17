# win\Backup.ps1 -- Confirm-LargeDeletion against a REAL native process.
#
# REAL-PROCESS COVERAGE, narrow on purpose. Every other Backup test shadows
# wsl.exe with a PowerShell function, which can never reproduce the
# $ErrorActionPreference='Stop' + 2>&1 NativeCommandError hazard (see the
# header of Run.ps1). Here wsl.exe is a real compiled console program
# (FakeExe.ps1) first on PATH, so Confirm-LargeDeletion runs unchanged, under
# 'Stop', against a child process that writes to stderr. Remove its scoped
# 'Continue' and these tests fail.
#
# What this does NOT prove: anything about the real wsl.exe or the real
# `maint` binary -- UTF-16LE decoding of wsl.exe's own messages, real
# stdout/stderr interleaving, or that `maint clean --dry-run` prints what the
# fake prints. Those are still manual-only.
#
# Safety: the real wsl.exe is never run. Invoke-WithFakeExe refuses to run a
# scenario unless wsl.exe resolves into the fake's temp dir, and each test
# then asserts that the fake's marker file recorded the call. No function named wsl.exe is defined in
# this file: it would outrank the exe and hide it.

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'Assert.ps1')
. (Join-Path $here 'FakeExe.ps1')
. (Join-Path (Split-Path -Parent (Split-Path -Parent $here)) 'win\Common.ps1')
. (Join-Path (Split-Path -Parent (Split-Path -Parent $here)) 'win\Backup.ps1')

try {
    $script:FakeDir = New-FakeNativeExe
} catch {
    [Console]::Out.WriteLine("  SKIP Test-BackupConsentNative.ps1: cannot compile the fake exe ($_)")
    Write-AssertSummary
    exit 0
}

$script:Logs = @()

function Get-MaintConfig { @{ Distro = 'TestDistro'; BackupRoot = 'T:\nowhere'; Keep = 3 } }
function Write-MaintLog { param($Level = 'info', $Message) $script:Logs += "[$Level] $Message" }
function Write-Host { param([Parameter(ValueFromRemainingArguments = $true)]$Rest) }
function Read-Host { param([Parameter(ValueFromRemainingArguments = $true)]$Rest) throw 'READ-HOST-REACHED' }

# Runs Confirm-LargeDeletion -Unattended against the fake replaying $Lines.
# -Unattended so no path can block on a prompt; Read-Host throws anyway.
function Invoke-NativeConsentScenario {
    param([string[]]$Lines)
    $script:Logs = @()
    Invoke-WithFakeExe -Dir $script:FakeDir -Lines $Lines -Script {
        $res = $null
        $err = $null
        try { $res = Confirm-LargeDeletion -Unattended } catch { $err = "$_" }
        [pscustomobject]@{
            Result = $res
            Error  = $err
            Log    = ($script:Logs -join "`n")
        }
    }
}

# --- Negative control: the fake really triggers the hazard -------------------
# If this ever stops throwing, the fake no longer behaves like a real native
# exe, and the tests below would pass without guarding anything.
function Test-FakeExeTriggersNativeCommandErrorUnderStop {
    $err = Invoke-WithFakeExe -Dir $script:FakeDir -Lines @('out:hello', 'err:boom on stderr') -Script {
        $ErrorActionPreference = 'Stop'
        try { $null = & wsl.exe -d X -- probe 2>&1; $null } catch { "$_" }
    }
    Assert-Contains (Get-FakeExeCalls $script:FakeDir) 'probe' 'the fake recorded the call'
    Assert-NotNull $err 'Stop + 2>&1 on the fake exe throws, like a real native exe'
    Assert-Contains "$err" 'boom on stderr' 'the throw is the stderr line itself'
}

# The resolution guard itself: a `function wsl.exe` in scope outranks the
# exe, so the helper must refuse instead of silently testing a shadow.
function Test-ShadowedWslRefusesToRun {
    function wsl.exe { 'shadow' }
    $script:Ran = $false
    $err = $null
    try { Invoke-WithFakeExe -Dir $script:FakeDir -Script { $script:Ran = $true } } catch { $err = "$_" }
    Assert-Contains "$err" 'TEST GUARD' 'a shadowed wsl.exe is refused'
    Assert-False $script:Ran 'the script block never ran'
}

# --- The bug the scoped 'Continue' fixes -------------------------------------
# `maint clean --dry-run` logs to stderr exactly when it has something to
# free. Under 'Stop' that first stderr line used to throw before the
# "would free:" line was ever parsed.
function Test-StderrDuringPreviewDoesNotThrow {
    $r = Invoke-NativeConsentScenario -Lines @(
        'err:[info] rule apt-cache: 2.1G',
        'out:cleaning preview',
        'err:[warn] rule docker: skipped',
        'out:would free: 50G'
    )
    Assert-Null $r.Error 'stderr from a real process does not abort the preview'
    Assert-True $r.Result 'the amount was parsed and unattended proceeded'
    Assert-Contains $r.Log 'unattended: proceeding to free 50G' 'the would-free line after stderr was read'
    Assert-Contains (Get-FakeExeCalls $script:FakeDir) 'clean --dry-run' 'the fake recorded the preview call'
}

# A failing preview that also writes stderr must reach the fail-safe with its
# exit code, not die on the first stderr line.
function Test-FailingPreviewWithStderrReachesFailSafe {
    $r = Invoke-NativeConsentScenario -Lines @(
        'err:maint: rules.conf unreadable',
        'out:would free: 100M',
        'exit:3'
    )
    Assert-NotNull $r.Error 'a failed preview aborts under -Unattended'
    Assert-Contains "$($r.Error)" 'clean --dry-run preview exited 3' 'the abort is the fail-safe, carrying the real exit code'
    Assert-NotContains "$($r.Error)" 'rules.conf unreadable' 'the abort is not the raw stderr line'
    Assert-Contains (Get-FakeExeCalls $script:FakeDir) 'clean --dry-run' 'the fake recorded the preview call'
}

# A WSL_MAINT_CONFIG override reaches the preview as --config <WSL path>, so
# the preview measures what the real clean will do with the same file.
function Test-PreviewCarriesTheConfigOverride {
    function Get-MaintConfig { @{ Distro = 'TestDistro'; BackupRoot = 'T:\nowhere'; Keep = 3; ConfigOverride = 'T:\conf\alt.conf' } }
    $r = Invoke-NativeConsentScenario -Lines @('out:would free: 10M')
    Assert-Null $r.Error 'the preview ran'
    Assert-Match (Get-FakeExeCalls $script:FakeDir) '^-d TestDistro -- /mnt/\S+/wsl/maint clean --config /mnt/t/conf/alt\.conf --dry-run$' 'the override reaches the preview call'
}

try {
    Test-FakeExeTriggersNativeCommandErrorUnderStop
    Test-ShadowedWslRefusesToRun
    Test-StderrDuringPreviewDoesNotThrow
    Test-FailingPreviewWithStderrReachesFailSafe
    Test-PreviewCarriesTheConfigOverride
} finally {
    Remove-TestDir $script:FakeDir
}

Write-AssertSummary
