# maint.ps1 -- dispatcher, failure logging, and the `full` abort chain.
#
# maint.ps1 is a script, not a function, so it is tested the only honest way:
# it is COPIED VERBATIM into a temp sandbox next to stub win\*.ps1 files, and
# run as a real child process. That means the exit code, the try/catch and the
# dot-source order are all exercised for real. What the stubs replace is only
# what the sandbox must not do (touch WSL, the VM, the backup drive, or the
# repo's logs\ dir).
#
# LOGIC-ONLY COVERAGE for anything below the dispatcher: Invoke-MaintBackup,
# Invoke-MaintCompact, Invoke-MaintWinClean and Invoke-MaintDefender are stubs
# here. Their own behaviour is covered by the other Test-*.ps1 files.

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent (Split-Path -Parent $here)
. (Join-Path $here 'Assert.ps1')
. (Join-Path $here 'FakeExe.ps1')

# Appended to a verbatim copy of the REAL win\Common.ps1, so Get-MaintConfig
# and Get-MaintWslBin run for real (reading the sandbox's own maint.conf) and
# only what the sandbox must not do is replaced: the log file, the elevation
# check, the free-space probe, and -- unless a test asks for the native fake
# -- the wsl.exe call itself.
$commonOverrides = @'
function Write-MaintLog {
    param([ValidateSet('info','warn','err')][string]$Level = 'info', [Parameter(Mandatory)][string]$Message)
    Add-Content -Path $env:MAINT_TEST_LOG -Value "[$Level] $Message"
}
function Assert-Admin { Add-Content -Path $env:MAINT_TEST_MARKER -Value 'assert-admin' }
function Get-FreeSpaceGb { param($DriveLetter) 999 }
function Format-Gb { param([long]$Bytes) "$Bytes B" }
'@

$invokeWslOverride = @'
function Invoke-Wsl {
    param([Parameter(Mandatory)][string[]]$Arguments)
    Add-Content -Path $env:MAINT_TEST_MARKER -Value ('wsl ' + ($Arguments -join ' '))
}
'@
# The end-of-run keypress in the UAC-relaunched child. Replaced unless a test
# asks for the real one, so no test can ever block on a key.
$pauseOverride = @'
function Wait-MaintExitKey { Add-Content -Path $env:MAINT_TEST_MARKER -Value 'pause' }
'@

$backupStub = @'
function Invoke-MaintBackup {
    param([switch]$DryRun, [switch]$Unattended, [switch]$NoClean)
    Add-Content -Path $env:MAINT_TEST_MARKER -Value "backup dry=$DryRun unattended=$Unattended noclean=$NoClean"
    if ($env:MAINT_TEST_THROW -eq 'backup') { throw 'BOOM-BACKUP' }
    # An exception whose Message is the empty string. Write-MaintLog's -Message
    # is Mandatory, so this is the input that used to break the catch block.
    if ($env:MAINT_TEST_THROW -eq 'backup-empty') { throw (New-Object System.InvalidOperationException '') }
}
'@

$compactStub = @'
function Invoke-MaintCompact {
    param([switch]$DryRun)
    Add-Content -Path $env:MAINT_TEST_MARKER -Value "compact dry=$DryRun"
    if ($env:MAINT_TEST_THROW -eq 'compact') { throw 'BOOM-COMPACT' }
}
'@

$wincleanStub = @'
function Invoke-MaintWinClean {
    param([switch]$DryRun)
    Add-Content -Path $env:MAINT_TEST_MARKER -Value "winclean dry=$DryRun"
    if ($env:MAINT_TEST_THROW -eq 'winclean') { throw 'BOOM-WINCLEAN' }
}
'@

$defenderStub = @'
function Invoke-MaintDefender {
    param([switch]$Verify)
    Add-Content -Path $env:MAINT_TEST_MARKER -Value "defender verify=$Verify"
    if ($env:MAINT_TEST_THROW -eq 'defender') { throw 'BOOM-DEFENDER' }
}
'@

# Copies maint.ps1 verbatim into a sandbox, runs it as a child process, and
# returns its exit code plus everything the stubs recorded.
#   -ConfLines  written to the sandbox's own maint.conf (its repo root), which
#               the real Get-MaintConfig reads; no file when omitted.
#   -ConfigEnv  value of WSL_MAINT_CONFIG for the child; cleared otherwise, so
#               the operator's own setting can never leak into a test.
#   -FakeDir    keep the REAL Invoke-Wsl and run the child with FakeExe.ps1's
#               native wsl.exe first on PATH; .FakeCalls is what it recorded.
function Invoke-MaintSandbox {
    param(
        [string[]]$Arguments,
        [string]$ThrowFrom = '',
        [string[]]$ConfLines,
        [string]$ConfigEnv = '',
        [string]$FakeDir = '',
        [switch]$RealPause
    )
    $root = New-TestDir 'maint-sandbox'
    $prevConfig = $env:WSL_MAINT_CONFIG
    try {
        New-Item -ItemType Directory -Path (Join-Path $root 'win') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $repo 'maint.ps1') -Destination (Join-Path $root 'maint.ps1')
        $common = @(Get-Content -LiteralPath (Join-Path $repo 'win\Common.ps1')) + $commonOverrides
        if (-not $FakeDir) { $common += $invokeWslOverride }
        if (-not $RealPause) { $common += $pauseOverride }
        Set-Content -LiteralPath (Join-Path $root 'win\Common.ps1')   -Value $common
        Set-Content -LiteralPath (Join-Path $root 'win\Backup.ps1')   -Value $backupStub
        Set-Content -LiteralPath (Join-Path $root 'win\Compact.ps1')  -Value $compactStub
        Set-Content -LiteralPath (Join-Path $root 'win\WinClean.ps1') -Value $wincleanStub
        Set-Content -LiteralPath (Join-Path $root 'win\Defender.ps1') -Value $defenderStub
        if ($PSBoundParameters.ContainsKey('ConfLines')) {
            Set-Content -LiteralPath (Join-Path $root 'maint.conf') -Value $ConfLines
        }

        $env:MAINT_TEST_LOG = Join-Path $root 'log.txt'
        $env:MAINT_TEST_MARKER = Join-Path $root 'marker.txt'
        $env:MAINT_TEST_THROW = $ThrowFrom
        $env:WSL_MAINT_CONFIG = $ConfigEnv
        Set-Content -LiteralPath $env:MAINT_TEST_LOG -Value ''
        Set-Content -LiteralPath $env:MAINT_TEST_MARKER -Value ''

        $psArgs = @('-NoProfile', '-NonInteractive', '-File', (Join-Path $root 'maint.ps1')) + $Arguments
        # Scoped to 'Continue' for exactly this call, for the same reason
        # Confirm-LargeDeletion does it: merging a REAL native process's stderr
        # with 2>&1 under 'Stop' turns its first stderr line into a terminating
        # NativeCommandError before anything here can read it. maint.ps1
        # can still write to stderr (a binding error, e.g. an ambiguous switch).
        $run = {
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $out = & powershell.exe @psArgs 2>&1 | ForEach-Object { [string]$_ }
                @{ Out = $out; Code = $LASTEXITCODE }
            } finally {
                $ErrorActionPreference = $prevEap
            }
        }
        $fakeCalls = ''
        if ($FakeDir) {
            $res = Invoke-WithFakeExe -Dir $FakeDir -Script $run
            $fakeCalls = Get-FakeExeCalls -Dir $FakeDir
        } else {
            $res = & $run
        }

        [pscustomobject]@{
            ExitCode  = $res.Code
            Stdout    = ($res.Out -join "`n")
            Log       = ((Get-Content -LiteralPath $env:MAINT_TEST_LOG) -join "`n")
            Marker    = ((Get-Content -LiteralPath $env:MAINT_TEST_MARKER) -join "`n")
            FakeCalls = $fakeCalls
        }
    } finally {
        $env:MAINT_TEST_THROW = ''
        $env:WSL_MAINT_CONFIG = $prevConfig
        Remove-TestDir $root
    }
}

# --- A throw from any command must be logged AND must exit non-zero ----------
# Before this catch existed, every throw wrote only to a console that the UAC
# relaunch closes on exit, while the log file just stopped mid-sequence.
#
# There is ONE try/catch, and it sits outside the switch (see
# Test-FullAbortsBeforeCompactWhenBackupThrows for why it has to). So this is
# covered per-catch, not per-verb: `backup` exercises the block and the
# empty-message case below exercises its only branch. There used to be
# identical copies of this test for winclean, defender and compact; they
# re-entered the same three lines through a different switch arm, at the cost
# of three more powershell.exe child processes per suite run.
function Test-BackupThrowIsLoggedAndExitsNonZero {
    $r = Invoke-MaintSandbox -Arguments @('backup') -ThrowFrom 'backup'
    Assert-Eq 1 $r.ExitCode 'the failure is visible to maint.bat as a non-zero exit code'
    Assert-Contains $r.Log '[err] BOOM-BACKUP' 'the reason reaches the log file, not just the console'
}

# An empty exception message must not silently defeat the catch. Write-MaintLog
# takes a [Parameter(Mandatory)][string], so passing $_.Exception.Message raw
# threw a binding error INSIDE the catch: the exit code stayed non-zero (so
# maint.bat's MAINT_RC still worked) but the log gained no reason at all, which
# is the exact failure this try/catch was added to prevent.
function Test-EmptyExceptionMessageStillLogsAReason {
    $r = Invoke-MaintSandbox -Arguments @('backup') -ThrowFrom 'backup-empty'
    Assert-Eq 1 $r.ExitCode 'an empty-message failure still exits non-zero'
    Assert-Contains $r.Log '[err]' 'the catch still reached the log file'
    Assert-Contains $r.Log 'InvalidOperationException' 'it falls back to the exception type when there is no message'
}

# --- `full` must abort, not continue on error --------------------------------
# The catch is OUTSIDE the switch precisely so a backup failure unwinds past
# Invoke-MaintCompact instead of being handled between the two calls. A `full`
# that compacted anyway would shut the VM down and run Optimize-VHD after a
# backup that did not complete.
function Test-FullAbortsBeforeCompactWhenBackupThrows {
    $r = Invoke-MaintSandbox -Arguments @('full') -ThrowFrom 'backup'
    Assert-Eq 1 $r.ExitCode 'full exits non-zero'
    Assert-Contains $r.Marker 'backup dry=False' 'backup was attempted'
    Assert-NotContains $r.Marker 'compact' 'compact was NEVER reached after the backup threw'
    Assert-Contains $r.Log '[err] BOOM-BACKUP' 'the backup failure is what got logged'
}

function Test-FullRunsBackupThenCompactWhenHealthy {
    $r = Invoke-MaintSandbox -Arguments @('full')
    Assert-Eq 0 $r.ExitCode 'a healthy full run exits 0'
    Assert-Contains $r.Marker 'assert-admin' 'full checks for elevation first'
    Assert-Contains $r.Marker 'backup dry=False' 'backup ran'
    Assert-Contains $r.Marker 'compact dry=False' 'compact ran'
    Assert-True ($r.Marker.IndexOf('backup dry') -lt $r.Marker.IndexOf('compact dry')) 'backup ran before compact'
    Assert-NotContains $r.Log '[err]' 'a healthy run logs no error'
}

function Test-FullForwardsSwitches {
    $r = Invoke-MaintSandbox -Arguments @('full', '-DryRun', '-Unattended')
    Assert-Eq 0 $r.ExitCode 'a dry full run exits 0'
    Assert-Contains $r.Marker 'backup dry=True unattended=True' 'both switches reach the backup'
    Assert-Contains $r.Marker 'compact dry=True' '-DryRun reaches the compact'
}

# --- Proxy commands ----------------------------------------------------------
# The WSL entry point is the sandbox's OWN wsl\maint, seen from WSL: the
# sandbox lives under %TEMP% on a drive letter, so it must come out as
# /mnt/<drive>/.../maint-sandbox-<id>/wsl/maint. Still absolute, never a bare
# "maint": WSL's interop shell does not source ~/.profile, so ~/.local/bin is
# not on its PATH.
function Test-ProxyCommandsUseTheWslBinUnderTheRepo {
    $r = Invoke-MaintSandbox -Arguments @('audit')
    Assert-Eq 0 $r.ExitCode 'audit exits 0'
    Assert-Match $r.Marker '(?m)^wsl -d Ubuntu -- /mnt/[a-z]/\S*/maint-sandbox-[0-9a-f]{12}/wsl/maint audit$' 'audit proxies to the repo''s own wsl/maint by absolute WSL path'
    Assert-NotContains $r.Marker '/home/' 'no home-directory symlink is assumed'
    Assert-NotContains $r.Marker 'assert-admin' 'a proxy command needs no elevation'
}

# The same, through the REAL Invoke-Wsl and a real native wsl.exe stand-in,
# with the distro taken from the sandbox's maint.conf: every proxy verb hands
# the configured distro to wsl.exe.
function Test-ConfiguredDistroReachesWslExeForEveryProxyVerb {
    if (-not $script:FakeDir) { [Console]::Out.WriteLine('  SKIP distro-to-wsl.exe: no fake exe'); return }
    foreach ($verb in @('audit', 'clean', 'docker')) {
        $r = Invoke-MaintSandbox -Arguments @($verb, '-DryRun') -ConfLines @('distro = Debian') -FakeDir $script:FakeDir
        Assert-Eq 0 $r.ExitCode "$verb exits 0 against the fake"
        Assert-Match $r.FakeCalls "^-d Debian -- /mnt/[a-z]/\S*/wsl/maint $verb" "$verb reaches wsl.exe with the configured distro"
        Assert-NotContains $r.FakeCalls 'Ubuntu' "$verb never falls back to the default distro"
    }
}

# WSL_MAINT_CONFIG wins over the repo-root file.
function Test-ConfigOverrideVariableWinsOverRepoFile {
    $dir = New-TestDir 'maint-conf'
    try {
        $alt = Join-Path $dir 'alt.conf'
        Set-Content -LiteralPath $alt -Value 'distro = Alpine'
        $r = Invoke-MaintSandbox -Arguments @('audit') -ConfLines @('distro = Debian') -ConfigEnv $alt
        Assert-Contains $r.Marker 'wsl -d Alpine -- ' 'the override file is the one read'
        Assert-NotContains $r.Marker 'Debian' 'the repo-root file is ignored when overridden'
    } finally { Remove-TestDir $dir }
}

# The override must reach the WSL side too: wsl/maint would otherwise read the
# repo-root maint.conf, and docker_guard_extra in the override (what keeps a
# database volume alive) would never reach the docker prune. Every proxy verb
# hands it over as --config <WSL path>; without the variable, no --config.
function Test-ConfigOverrideReachesTheWslSideForEveryProxyVerb {
    $dir = New-TestDir 'maint-conf'
    try {
        $alt = Join-Path $dir 'alt.conf'
        Set-Content -LiteralPath $alt -Value 'distro = Alpine'
        foreach ($verb in @('audit', 'clean', 'docker')) {
            $r = Invoke-MaintSandbox -Arguments @($verb, '-DryRun') -ConfLines @('distro = Debian') -ConfigEnv $alt
            Assert-Eq 0 $r.ExitCode "$verb exits 0 with an override"
            Assert-Match $r.Marker "(?m)^wsl -d Alpine -- /mnt/[a-z]/\S*/wsl/maint $verb --config /mnt/[a-z]/\S*/maint-conf-[0-9a-f]{12}/alt\.conf( --dry-run)?$" "$verb hands the override to wsl/maint as a WSL path"
        }
        $plain = Invoke-MaintSandbox -Arguments @('docker') -ConfLines @('distro = Debian')
        Assert-NotContains $plain.Marker '--config' 'no override: wsl/maint finds the repo-root file itself'
    } finally { Remove-TestDir $dir }
}

# A broken maint.conf stops the command before it does anything, and the
# reason (with file:line) reaches the log, not only the console.
function Test-BrokenConfigStopsBeforeAnyAction {
    foreach ($verb in @('audit', 'backup', 'winclean')) {
        $r = Invoke-MaintSandbox -Arguments @($verb) -ConfLines @('distro = Debian', 'kep = 2')
        Assert-Eq 1 $r.ExitCode "$verb exits 1 on a broken config"
        Assert-Match $r.Log '\[err\] .*maint\.conf:2: unknown key' "$verb logs the file and line"
        Assert-Eq '' $r.Marker.Trim() "$verb performed no action"
    }
}

function Test-CleanProxyForwardsDryRunOnlyWhenAsked {
    $dry = Invoke-MaintSandbox -Arguments @('clean', '-DryRun')
    Assert-Contains $dry.Marker 'maint clean --dry-run' '-DryRun is forwarded to the WSL side'

    $wet = Invoke-MaintSandbox -Arguments @('clean')
    Assert-Contains $wet.Marker 'maint clean' 'clean proxies through'
    Assert-NotContains $wet.Marker '--dry-run' 'no --dry-run is invented when it was not asked for'
}

function Test-DockerProxyForwardsDryRun {
    $dry = Invoke-MaintSandbox -Arguments @('docker', '-DryRun')
    Assert-Contains $dry.Marker 'maint docker --dry-run' '-DryRun is forwarded to the docker prune'
    Assert-NotContains $dry.Marker 'assert-admin' 'the docker proxy needs no elevation'
}

# `full` deliberately does not prune Docker: it must not decide to delete
# image data behind an operator who asked for a backup.
function Test-FullDoesNotPruneDocker {
    $r = Invoke-MaintSandbox -Arguments @('full')
    Assert-NotContains $r.Marker 'maint docker' 'full never runs the docker prune'
    # `full` reaches the clean only THROUGH Invoke-MaintBackup, which is a stub
    # in this file -- so an assertion here about the clean's arguments could
    # never fail whatever maint.ps1 did. What this file can honestly check is
    # the switch that decides it: a wet `full` must hand the backup dry=False.
    # The clean call itself is covered where the real Invoke-MaintBackup runs,
    # in Test-BackupRetention.ps1.
    Assert-Contains $r.Marker 'backup dry=False' 'full hands the backup a real (not dry) run, which is what makes the clean real'
}

# Same guard one verb over: a bare `backup` must also be wet unless asked
# otherwise. `full` had this covered and `backup` did not, which left the
# identical bug reachable through the more commonly used entry point.
function Test-BackupVerbIsWetByDefault {
    $r = Invoke-MaintSandbox -Arguments @('backup')
    Assert-Contains $r.Marker 'backup dry=False' 'a bare backup runs for real, not as a dry run'
    $dry = Invoke-MaintSandbox -Arguments @('backup', '-DryRun')
    Assert-Contains $dry.Marker 'backup dry=True' '-DryRun still reaches the backup'
}

# --- Dispatcher --------------------------------------------------------------
function Test-DefaultCommandIsHelpAndIsHarmless {
    $r = Invoke-MaintSandbox -Arguments @()
    Assert-Eq 0 $r.ExitCode 'no arguments exits 0'
    Assert-Contains $r.Stdout 'wsl-maint - Windows side' 'usage is printed'
    Assert-Eq '' $r.Marker.Trim() 'no argument performs no action at all'
}

function Test-UnknownCommandIsRejectedWithoutSideEffects {
    $r = Invoke-MaintSandbox -Arguments @('nuke')
    Assert-True ($r.ExitCode -ne 0) "an unknown command exits non-zero (got $($r.ExitCode))"
    Assert-Eq '' $r.Marker.Trim() 'an unknown command performs no action'
    Assert-Contains $r.Log "[err] unknown command 'nuke'" 'the reason reaches the log, which maint.bat points at'
}

# A typo used to fail in param() binding, before the try: nothing reached the
# log and the elevated window closed without its -PauseAtEnd keypress.
function Test-UnknownCommandOrSwitchPausesWithItsReason {
    $r = Invoke-MaintSandbox -Arguments @('compcat', '-PauseAtEnd')
    Assert-Eq 1 $r.ExitCode 'a typo in the command exits 1'
    Assert-Contains $r.Stdout "[FAILED] unknown command 'compcat'" 'the elevated window shows the reason'
    Assert-Contains $r.Marker 'pause' 'and waits for a key'
    $f = Invoke-MaintSandbox -Arguments @('audit', '-Foo', '-PauseAtEnd')
    Assert-Eq 1 $f.ExitCode 'an unknown switch exits 1'
    Assert-Contains $f.Log '[err] unknown argument: -Foo' 'the stray argument is named in the log'
    Assert-Contains $f.Marker 'pause' 'and waits for a key'
    Assert-NotContains $f.Marker 'wsl' 'audit does not run with a stray argument'
}

function Test-DefenderVerifyIsForwarded {
    $r = Invoke-MaintSandbox -Arguments @('defender', '-Verify')
    Assert-Eq 0 $r.ExitCode 'defender -Verify exits 0'
    Assert-Contains $r.Marker 'defender verify=True' '-Verify reaches Invoke-MaintDefender'
    Assert-NotContains $r.Marker 'assert-admin' 'maint.ps1 does not pre-assert admin for defender'
}

# defender has no dry run. Before this check `defender -DryRun` dropped the
# switch on the floor and added the exclusions for real, so an operator who
# asked to look first changed Defender config instead.
function Test-DefenderRefusesDryRun {
    $r = Invoke-MaintSandbox -Arguments @('defender', '-DryRun')
    Assert-Eq 1 $r.ExitCode 'defender -DryRun exits non-zero'
    Assert-NotContains $r.Marker 'defender verify=' 'Invoke-MaintDefender was never reached'
    Assert-Contains $r.Log '-Verify' 'the logged reason points at -Verify'
}

function Test-NoCleanIsForwardedByBackupAndFull {
    foreach ($verb in @('backup', 'full')) {
        $r = Invoke-MaintSandbox -Arguments @($verb, '-NoClean')
        Assert-Eq 0 $r.ExitCode "$verb -NoClean exits 0"
        Assert-Contains $r.Marker 'noclean=True' "$verb forwards -NoClean to the backup"
    }
    $r = Invoke-MaintSandbox -Arguments @('backup')
    Assert-Contains $r.Marker 'noclean=False' 'backup without the switch cleans'
}

# Any other verb would silently ignore it, and `clean -NoClean` would clean.
function Test-NoCleanIsRefusedOutsideBackupAndFull {
    $r = Invoke-MaintSandbox -Arguments @('clean', '-NoClean')
    Assert-Eq 1 $r.ExitCode 'clean -NoClean exits non-zero'
    Assert-NotContains $r.Marker 'wsl ' 'nothing reached WSL'
    Assert-Contains $r.Log '-NoClean' 'the logged reason names the switch'
}

# Same rule as -NoClean: `full -Verify` reads as "only check" and would run
# the whole backup + compact if the switch were ignored.
function Test-VerifyIsRefusedOutsideDefender {
    foreach ($verb in @('clean', 'full')) {
        $r = Invoke-MaintSandbox -Arguments @($verb, '-Verify')
        Assert-Eq 1 $r.ExitCode "$verb -Verify exits non-zero"
        Assert-NotContains $r.Marker 'wsl ' "$verb -Verify: nothing reached WSL"
        Assert-NotContains $r.Marker 'backup ' "$verb -Verify: the backup never started"
        Assert-Contains $r.Log '-Verify' "$verb -Verify: the logged reason names the switch"
    }
}

# --- End-of-run pause in the UAC-relaunched child ----------------------------
# maint.bat passes the internal -PauseAtEnd only on the UAC relaunch, and only
# without -Unattended: that child runs in a new window that would otherwise
# close with the output. An already elevated cmd keeps maint.bat's own pause.
function Test-PauseAtEndPausesAfterASuccessfulRun {
    $r = Invoke-MaintSandbox -Arguments @('audit', '-PauseAtEnd')
    Assert-Eq 0 $r.ExitCode 'a paused successful run still exits 0'
    Assert-Contains $r.Marker 'pause' 'the child waits for a key before its window closes'
    Assert-True ($r.Marker.IndexOf('wsl ') -lt $r.Marker.IndexOf('pause')) 'the pause comes after the work'
}

function Test-PauseAtEndShowsFailedLineThenPausesOnFailure {
    $r = Invoke-MaintSandbox -Arguments @('backup', '-PauseAtEnd') -ThrowFrom 'backup'
    Assert-Eq 1 $r.ExitCode 'the pause does not swallow the failure exit code'
    Assert-Contains $r.Marker 'pause' 'a failed run pauses too'
    Assert-Contains $r.Stdout '[FAILED] BOOM-BACKUP' 'the child window shows why before it waits'
    Assert-Contains $r.Log '[err] BOOM-BACKUP' 'the reason still reaches the log'
}

function Test-UnattendedNeverPauses {
    $r = Invoke-MaintSandbox -Arguments @('audit', '-PauseAtEnd', '-Unattended')
    Assert-Eq 0 $r.ExitCode 'unattended exits 0'
    Assert-NotContains $r.Marker 'pause' '-Unattended wins over -PauseAtEnd'
}

function Test-NoPauseWithoutTheFlag {
    $r = Invoke-MaintSandbox -Arguments @('audit')
    Assert-NotContains $r.Marker 'pause' 'a run from an elevated cmd leaves the pause to maint.bat'
    $f = Invoke-MaintSandbox -Arguments @('backup') -ThrowFrom 'backup'
    Assert-NotContains $f.Marker 'pause' 'nor on failure'
    Assert-NotContains $f.Stdout '[FAILED]' 'maint.bat prints the [FAILED] line in that case, not maint.ps1'
}

# The REAL Wait-MaintExitKey under a -NonInteractive host (as every sandbox
# child runs): it must return at once instead of waiting for a key nobody can
# press. A broken guard would hang or throw on ReadKey here.
function Test-RealPauseNeverBlocksANonInteractiveHost {
    $r = Invoke-MaintSandbox -Arguments @('audit', '-PauseAtEnd') -RealPause
    Assert-Eq 0 $r.ExitCode 'the run completes and exits 0'
    Assert-NotContains $r.Stdout 'Press any key' 'no prompt is shown to a host that cannot answer'
}

# -PauseAtEnd is internal: it must stay out of the usage text.
function Test-PauseAtEndIsNotInUsage {
    $r = Invoke-MaintSandbox -Arguments @('help')
    Assert-NotContains $r.Stdout 'PauseAtEnd' 'the internal switch is not advertised'
}

Test-PauseAtEndPausesAfterASuccessfulRun
Test-PauseAtEndShowsFailedLineThenPausesOnFailure
Test-UnattendedNeverPauses
Test-NoPauseWithoutTheFlag
Test-RealPauseNeverBlocksANonInteractiveHost
Test-PauseAtEndIsNotInUsage
Test-BackupThrowIsLoggedAndExitsNonZero
Test-EmptyExceptionMessageStillLogsAReason
Test-FullAbortsBeforeCompactWhenBackupThrows
Test-FullRunsBackupThenCompactWhenHealthy
Test-FullForwardsSwitches
Test-ProxyCommandsUseTheWslBinUnderTheRepo
Test-CleanProxyForwardsDryRunOnlyWhenAsked
Test-DockerProxyForwardsDryRun
Test-FullDoesNotPruneDocker
Test-BackupVerbIsWetByDefault
Test-DefaultCommandIsHelpAndIsHarmless
Test-UnknownCommandIsRejectedWithoutSideEffects
Test-UnknownCommandOrSwitchPausesWithItsReason
Test-DefenderVerifyIsForwarded
Test-DefenderRefusesDryRun
Test-NoCleanIsForwardedByBackupAndFull
Test-NoCleanIsRefusedOutsideBackupAndFull
Test-VerifyIsRefusedOutsideDefender
Test-ConfigOverrideVariableWinsOverRepoFile
Test-ConfigOverrideReachesTheWslSideForEveryProxyVerb
Test-BrokenConfigStopsBeforeAnyAction

# The native stand-in is compiled once for the file; a box without the in-box
# compiler skips the one test that needs it rather than failing.
$script:FakeDir = $null
try { $script:FakeDir = New-FakeNativeExe } catch { [Console]::Out.WriteLine("  SKIP cannot compile the fake exe ($_)") }
try {
    Test-ConfiguredDistroReachesWslExeForEveryProxyVerb
} finally {
    if ($script:FakeDir) { Remove-TestDir $script:FakeDir }
}

Write-AssertSummary
