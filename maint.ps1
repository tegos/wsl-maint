# A simple script on purpose: no [CmdletBinding()] and no [Parameter()], since
# either makes it advanced and adds the common parameters. With them, -E, -O,
# -W and -I were each ambiguous between two common parameters and died in
# param() binding, before the try below and its log, and -Debug/-Verbose were
# accepted and ignored. Without them, an unknown switch or a third positional
# lands in $args and is refused in the try (a second binds to -MaintConfig and
# is refused there unless it carries maint.bat's cfg: prefix). Malformed input can still die in
# binding (-DryRun:abc, -C with no value, a switch given twice, a bare - or --);
# maint.bat's failure pause keeps that reason on screen. Keep the switches on
# distinct first letters (Test-Maint.ps1 checks), so every one-letter
# abbreviation stays unambiguous.
param(
    # Checked inside the try below, not by ValidateSet: a binding error stops
    # the script before any of it runs, so a typo (maint.bat compcat) never
    # reached the log and the elevated window closed without its keypress.
    [string]$Command = 'help',

    [switch]$DryRun,
    [switch]$Unattended,
    [switch]$Verify,
    [switch]$NoClean,

    # Internal: maint.bat passes it only on the UAC relaunch (and never with
    # -Unattended), whose new window would otherwise close with the output.
    [switch]$PauseAtEnd,

    # Internal: maint.bat passes the caller's WSL_MAINT_CONFIG on the UAC
    # relaunch, because the elevated child gets a fresh environment and would
    # otherwise silently read the repo-root maint.conf instead. A [string] in
    # a non-advanced script is also positional, so maint.bat sends the value
    # as cfg:<full path> and the try below refuses anything without that
    # prefix as a stray argument, a drive path (`backup D:\x`) included.
    [string]$MaintConfig
)

$ErrorActionPreference = 'Stop'

# The end-of-run keypress for -PauseAtEnd. Defined BEFORE Common.ps1 is
# dot-sourced so tests\win\Test-Maint.ps1 can replace it from its sandbox
# copy of Common.ps1. Never blocks a host that cannot answer: -NonInteractive,
# redirected stdin, or a non-interactive session (CI, a scheduled task).
function Wait-MaintExitKey {
    $nonInteractive = @([Environment]::GetCommandLineArgs() | Where-Object { $_ -like '-noni*' }).Count -gt 0
    if ($nonInteractive -or -not [Environment]::UserInteractive -or [Console]::IsInputRedirected) { return }
    Write-Host ''
    Write-Host 'Press any key to close this window...'
    try { [void]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { }
}

. (Join-Path $PSScriptRoot 'win\Common.ps1')

function Show-Usage {
    @"
wsl-maint - Windows side

usage: maint.bat <command> [-DryRun] [-Unattended] [-Verify] [-NoClean]

commands:
  full        clean -> fstrim -> export -> zstd -> verify -> retention -> shutdown -> Optimize-VHD
  backup      clean -> fstrim -> export -> zstd -> verify -> retention
              (-NoClean on backup/full: skip the clean, e.g. for a first backup)
  compact     shutdown + Optimize-VHD only
  winclean    Windows TEMP, %LOCALAPPDATA%\Temp and recycle bin
  defender    Defender exclusions for WSL/Docker paths (-Verify to check only)
  audit       proxy to the WSL-side audit
  clean       proxy to the WSL-side clean
  docker      proxy to the WSL-side docker prune

The three proxy commands (audit, clean, docker) do nothing Windows-specific and
do not need admin rights, but maint.bat still asks for UAC elevation for every
command. Run them natively inside WSL to skip the prompt: maint audit
"@
}

# Every throw below (Backup.ps1, Compact.ps1, Defender.ps1, Common.ps1's
# Assert-Admin/Invoke-Wsl) writes only to the console, and the UAC relaunch
# has no -NoExit, so the elevated window closes when the run ends (after the
# -PauseAtEnd keypress, if any) and takes the console copy of the reason with
# it -- while maint.bat still prints "see logs\ for details" at a log file
# that would just stop mid-sequence. This catch puts the reason IN that log
# file before exiting.
#
# Two properties this must not break, both verified:
#   1. It does not swallow the failure: the `exit 1` below keeps the process exit code
#      non-zero, so maint.bat's `set "MAINT_RC=%errorlevel%"` still sees it.
#   2. It does not turn `full` into a continue-on-error sequence: the catch is
#      OUTSIDE the switch, so a throw from Invoke-MaintBackup unwinds past
#      Invoke-MaintCompact rather than being handled between the two calls.
$failed = $false
try {
    $commands = 'full', 'backup', 'compact', 'winclean', 'defender', 'audit', 'clean', 'docker', 'help'
    if ($Command -notin $commands) { throw ("unknown command '$Command'; one of: " + ($commands -join ', ')) }
    # .Count, not truthiness: @('') is falsy, so `backup ""` would slip through.
    if ($args.Count) { throw ('unknown argument: ' + ($args -join ' ') + '; see maint.bat help') }
    # A second positional (`backup extra`, `backup D:\x`) binds to
    # -MaintConfig before it could reach $args, so only maint.bat's cfg:
    # prefix is accepted here and anything else is a stray argument.
    if ($PSBoundParameters.ContainsKey('MaintConfig')) {
        if (-not $MaintConfig.StartsWith('cfg:')) { throw ('unknown argument: ' + $MaintConfig + '; see maint.bat help') }
        $forwarded = $MaintConfig.Substring(4)
        if (-not $forwarded) { throw 'WSL_MAINT_CONFIG was forwarded empty across the UAC relaunch' }
        $env:WSL_MAINT_CONFIG = $forwarded
    }
    # help acts on nothing: it reads no config and no switch guard applies,
    # so `help -NoClean` prints usage instead of exiting 1.
    if ($Command -ne 'help') {
        # Inside the try: a broken maint.conf stops every command before it
        # does anything, and its file:line reason reaches the log.
        $cfg = Get-MaintConfig
        # Refused rather than ignored: `clean -NoClean` would otherwise clean.
        if ($NoClean -and $Command -notin 'backup', 'full') { throw '-NoClean applies to backup and full only' }
        # Same for -Verify: `full -Verify` would otherwise back up and compact.
        if ($Verify -and $Command -ne 'defender') { throw '-Verify applies to defender only' }
    }
    switch ($Command) {
        'help'     { Show-Usage }
        'audit'    { Invoke-Wsl (Get-MaintWslArgs $cfg 'audit') }
        'clean'    {
            $wslArgs = Get-MaintWslArgs $cfg 'clean'
            if ($DryRun) { $wslArgs += '--dry-run' }
            Invoke-Wsl $wslArgs
        }
        # Nothing in the `full` sequence prunes Docker, and that is deliberate:
        # `full` compacts docker_data.vhdx but must not also decide to delete
        # image/build data behind an operator who asked for a backup. Nothing
        # is scheduled either (README's Schedule section only keeps the cron
        # lines on hand), so Docker is pruned only when someone runs
        # `maint docker`, through this proxy or directly in WSL.
        'docker'   {
            $dockerArgs = Get-MaintWslArgs $cfg 'docker'
            if ($DryRun) { $dockerArgs += '--dry-run' }
            Invoke-Wsl $dockerArgs
        }
        'winclean' { . (Join-Path $PSScriptRoot 'win\WinClean.ps1'); Invoke-MaintWinClean -DryRun:$DryRun }
        'defender' {
            # defender has no dry run; ignoring the switch would add the
            # exclusions for real behind an operator who asked to look first.
            if ($DryRun) { throw 'defender has no -DryRun; use -Verify to check without changing anything' }
            . (Join-Path $PSScriptRoot 'win\Defender.ps1'); Invoke-MaintDefender -Verify:$Verify
        }
        'backup'   {
            Assert-Admin
            . (Join-Path $PSScriptRoot 'win\Backup.ps1')
            Invoke-MaintBackup -DryRun:$DryRun -Unattended:$Unattended -NoClean:$NoClean
        }
        'compact'  {
            Assert-Admin
            . (Join-Path $PSScriptRoot 'win\Compact.ps1')
            Invoke-MaintCompact -DryRun:$DryRun
        }
        'full'     {
            Assert-Admin
            . (Join-Path $PSScriptRoot 'win\Backup.ps1')
            . (Join-Path $PSScriptRoot 'win\Compact.ps1')
            Invoke-MaintBackup -DryRun:$DryRun -Unattended:$Unattended -NoClean:$NoClean
            Invoke-MaintCompact -DryRun:$DryRun
        }
    }
} catch {
    # Write-MaintLog's -Message is [Parameter(Mandatory)][string]. An exception
    # whose Message is empty (some .NET types construct that way, and `throw ''`
    # produces it) would fail that binding INSIDE this catch and lose the one
    # thing the catch exists to record -- the process would still exit non-zero,
    # so maint.bat's MAINT_RC survives, but the log would say nothing about why.
    # Fall back until something non-empty is found; the exception type name
    # always is.
    $reason = $_.Exception.Message
    if ([string]::IsNullOrWhiteSpace($reason)) { $reason = "$_" }
    if ([string]::IsNullOrWhiteSpace($reason)) { $reason = $_.Exception.GetType().FullName }
    Write-MaintLog -Level err -Message $reason
    $failed = $true
}

# After the catch, so a failed run pauses too, with its [FAILED] line on
# screen first: maint.bat prints its own [FAILED] line in the ORIGINAL window,
# which the user of the elevated one cannot see.
if ($PauseAtEnd -and -not $Unattended) {
    if ($failed) {
        Write-Host ''
        Write-Host "[FAILED] $reason - see logs\ for details" -ForegroundColor Red
    }
    Wait-MaintExitKey
}
if ($failed) { exit 1 }
