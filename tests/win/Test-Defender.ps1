# win\Defender.ps1 -- exclusion list, the unelevated sentinel, and the
# partial-failure-then-throw path.
#
# LOGIC-ONLY COVERAGE. Get-MpPreference and Add-MpPreference are shadowed
# functions; the real Defender configuration is never read and never written.
# See the header of Run.ps1.

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent (Split-Path -Parent $here)
. (Join-Path $here 'Assert.ps1')
. (Join-Path $repo 'win\Common.ps1')
. (Join-Path $repo 'win\Defender.ps1')

$script:Sentinel = 'N/A: Must be an administrator to view exclusions'

# A fixed resolved process list for the scenario tests, so the result never
# depends on what is installed under the real %ProgramFiles%. Resolution itself
# is tested against a temp tree below.
$script:Procs = @('C:\PF\WSL\wsl.exe', 'C:\PF\WSL\wslservice.exe', 'C:\PF\WSL\wslhost.exe',
                  'C:\PF\Docker\Docker\resources\com.docker.backend.exe',
                  'C:\PF\Docker\Docker\com.docker.service',
                  'C:\PF\Docker\Docker\resources\dockerd.exe',
                  'C:\PF\Docker\Docker\resources\bin\docker.exe')

# File-wide safety net: nothing in this file may reach the real cmdlet.
function Add-MpPreference {
    [CmdletBinding()] param($ExclusionPath, $ExclusionProcess)
    throw 'TEST GUARD: the real Add-MpPreference must never be reached'
}
function Write-MaintLog { param([string]$Level = 'info', [string]$Message) $script:Logs += "[$Level] $Message" }
# The operator's real maint.conf must never decide what a test excludes.
function Get-MaintConfig { @{ Distro = 'Ubuntu'; BackupRoot = $null; Keep = 3 } }
# No registered distros: the real HKCU Lxss key is never read, and the disk
# lookup falls back to the Packages glob under a temp LOCALAPPDATA. The
# registry path itself is covered in Test-Common.ps1.
function Get-LxssDistroEntries { @() }

function Invoke-DefenderScenario {
    param(
        [string[]]$HavePaths = @(),
        [string[]]$HaveProcs = @(),
        [string[]]$WantPaths = @(),
        [string[]]$WantProcs = $script:Procs,
        [string[]]$FailToAdd = @(),
        [switch]$Verify,
        [switch]$PrefsThrow,
        [switch]$RealProcs
    )
    $script:Logs = @()
    $script:Added = @()
    $script:AdminChecked = $false

    function Get-MpPreference {
        [CmdletBinding()] param()
        if ($PrefsThrow) { throw 'Access denied' }
        [pscustomobject]@{ ExclusionPath = $HavePaths; ExclusionProcess = $HaveProcs }
    }
    function Add-MpPreference {
        [CmdletBinding()] param($ExclusionPath, $ExclusionProcess)
        $v = if ($ExclusionPath) { "path:$ExclusionPath" } else { "proc:$ExclusionProcess" }
        if ($FailToAdd -contains $ExclusionPath -or $FailToAdd -contains $ExclusionProcess) {
            throw "0x800106ba on $v"
        }
        $script:Added += $v
    }
    function Assert-Admin { $script:AdminChecked = $true }
    function Get-MaintExclusionPaths { $WantPaths }
    if (-not $RealProcs) { function Get-MaintExclusionProcesses { $WantProcs } }

    $err = $null
    try { Invoke-MaintDefender -Verify:$Verify } catch { $err = "$_" }
    [pscustomobject]@{
        Error        = $err
        Added        = @($script:Added)
        Log          = ($script:Logs -join "`n")
        AdminChecked = $script:AdminChecked
    }
}

# --- The process list: full image paths --------------------------------------
# A bare image name ('docker.exe') makes Defender skip files opened by ANY
# process of that name, wherever it runs from. Every entry must be a full path
# to an image that exists in an admin-writable install dir.
function New-FakeInstallTree {
    param([string]$Root, [string[]]$Files)
    foreach ($f in $Files) {
        $full = Join-Path $Root $f
        New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force | Out-Null
        Set-Content -LiteralPath $full -Value 'x'
    }
}

function Test-ProcessExclusionsAreResolvedFullPaths {
    $root = New-TestDir 'defender-procs'
    try {
        $pf = Join-Path $root 'PF'; $sr = Join-Path $root 'WIN'
        New-FakeInstallTree -Root $pf -Files @('WSL\wsl.exe', 'WSL\wslservice.exe', 'WSL\wslhost.exe',
            'Docker\Docker\resources\com.docker.backend.exe', 'Docker\Docker\com.docker.service',
            'Docker\Docker\resources\dockerd.exe', 'Docker\Docker\resources\bin\docker.exe')
        New-FakeInstallTree -Root $sr -Files @('System32\wsl.exe')
        $script:Logs = @()
        $procs = @(Get-MaintExclusionProcesses -ProgramFiles $pf -SystemRoot $sr)

        Assert-Eq 8 $procs.Count 'seven package images plus the inbox System32 wsl.exe'
        foreach ($p in $procs) {
            Assert-True ([IO.Path]::IsPathRooted($p)) "$p is a full path"
            Assert-True (Test-Path -LiteralPath $p -PathType Leaf) "$p exists"
        }
        Assert-True ($procs -contains (Join-Path $pf 'WSL\wsl.exe')) 'the package wsl.exe is excluded'
        Assert-True ($procs -contains (Join-Path $sr 'System32\wsl.exe')) 'the inbox wsl.exe is excluded too'
        Assert-True ($procs -contains (Join-Path $pf 'Docker\Docker\resources\bin\docker.exe')) 'docker.exe by its install path'
        foreach ($bare in @('vmmemWSL', 'vmmem', 'wsl.exe', 'docker.exe', 'dockerd.exe', 'com.docker.service')) {
            Assert-False ($procs -contains $bare) "no bare-name entry $bare"
        }
        Assert-NotContains (($procs -join ';')) 'vmmem' 'vmmem has no image on disk and is not excluded'
        Assert-NotContains ($script:Logs -join "`n") '[warn]' 'nothing is reported missing'
    } finally { Remove-TestDir $root }
}

# Docker Desktop not installed (or in a custom dir): its processes are skipped
# with a warning each, and the WSL ones are still returned.
function Test-MissingProcessImageIsSkippedWithWarn {
    $root = New-TestDir 'defender-procs'
    try {
        $pf = Join-Path $root 'PF'; $sr = Join-Path $root 'WIN'
        New-FakeInstallTree -Root $pf -Files @('WSL\wsl.exe', 'WSL\wslservice.exe', 'WSL\wslhost.exe')
        New-Item -ItemType Directory -Path $sr -Force | Out-Null
        $script:Logs = @()
        $err = $null
        try { $procs = @(Get-MaintExclusionProcesses -ProgramFiles $pf -SystemRoot $sr) } catch { $err = "$_" }

        Assert-Null $err 'a missing image is not an error'
        Assert-Eq 3 $procs.Count 'only the three WSL images that exist'
        $log = $script:Logs -join "`n"
        foreach ($n in @('com.docker.backend.exe', 'com.docker.service', 'dockerd.exe', 'docker.exe')) {
            Assert-Contains $log "[warn] process $n not found" "missing $n is warned about"
        }
        Assert-NotContains $log 'process wsl.exe not found' 'a found process is not warned about'
    } finally { Remove-TestDir $root }
}

# Apply, through the real resolver (only %ProgramFiles% is redirected), hands
# Add-MpPreference full paths, never a bare name.
function Test-ApplyAddsFullPathProcessExclusions {
    $root = New-TestDir 'defender-procs'
    $old = $env:ProgramFiles
    try {
        New-FakeInstallTree -Root $root -Files @('WSL\wsl.exe', 'Docker\Docker\resources\bin\docker.exe')
        $env:ProgramFiles = $root
        $r = Invoke-DefenderScenario -WantPaths @('C:\x\ext4.vhdx') -RealProcs
    } finally { $env:ProgramFiles = $old; Remove-TestDir $root }
    Assert-Null $r.Error 'a clean apply does not throw'
    Assert-Contains ($r.Added -join ';') ('proc:' + (Join-Path $root 'Docker\Docker\resources\bin\docker.exe')) 'docker.exe is added by full path'
    Assert-Contains ($r.Added -join ';') ('proc:' + (Join-Path $root 'WSL\wsl.exe')) 'wsl.exe is added by full path'
    foreach ($a in $r.Added) {
        if ($a -like 'proc:*') { Assert-True ([IO.Path]::IsPathRooted($a.Substring(5))) "$a is a full path" }
    }
    Assert-Contains $r.Log '[warn] process dockerd.exe not found' 'an image that is not there is warned about'
}

# A box that ran an older version still has the bare-name exclusions. -Verify
# names each one with the command to remove it, and removes nothing itself.
function Test-VerifyFlagsStaleBareNameExclusions {
    $r = Invoke-DefenderScenario -Verify -HavePaths @('C:\x\ext4.vhdx') -HaveProcs (@($script:Procs) + @('vmmem', 'docker.exe', 'C:\Tools\mine.exe')) -WantPaths @('C:\x\ext4.vhdx')
    Assert-Null $r.Error '-Verify reports rather than throws'
    Assert-Contains $r.Log "[warn] stale bare-name exclusion docker.exe" 'the bare docker.exe is flagged'
    Assert-Contains $r.Log "Remove-MpPreference -ExclusionProcess 'docker.exe'" 'with the command that removes it'
    Assert-Contains $r.Log "[warn] stale bare-name exclusion vmmem" 'the bare vmmem is flagged'
    Assert-NotContains $r.Log 'mine.exe' 'an unrelated user exclusion is left alone'
    Assert-NotContains $r.Log 'MISS' 'the full-path set itself is complete'
    Assert-Eq 0 $r.Added.Count '-Verify adds nothing'
}

# Apply warns about the stale entries too, and does not remove them.
function Test-ApplyWarnsAboutStaleBareNamesButKeepsThem {
    $script:Removed = @()
    function Remove-MpPreference { [CmdletBinding()] param($ExclusionPath, $ExclusionProcess) $script:Removed += "$ExclusionProcess$ExclusionPath" }
    $r = Invoke-DefenderScenario -WantPaths @('C:\x\ext4.vhdx') -HaveProcs @('wsl.exe')
    Assert-Null $r.Error 'stale entries do not fail the apply'
    Assert-Contains $r.Log "[warn] stale bare-name exclusion wsl.exe" 'the stale entry is flagged on apply'
    Assert-Eq 0 $script:Removed.Count 'nothing is removed'
}

function Test-PathExclusionsAreTheTwoVhdxFilesOnly {
    $root = New-TestDir 'defender-paths'
    try {
        $ub = Join-Path $root 'Packages\CanonicalGroupLimited.Ubuntu_x\LocalState'
        $dk = Join-Path $root 'Docker\wsl\disk'
        New-Item -ItemType Directory -Path $ub -Force | Out-Null
        New-Item -ItemType Directory -Path $dk -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $ub 'ext4.vhdx') -Value 'x'
        Set-Content -LiteralPath (Join-Path $dk 'docker_data.vhdx') -Value 'x'

        $old = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $root
        try { $paths = @(Get-MaintExclusionPaths -Distro Ubuntu) } finally { $env:LOCALAPPDATA = $old }

        Assert-Eq 2 $paths.Count 'exactly the two vhdx files'
        Assert-Contains ($paths -join ';') 'ext4.vhdx' 'the Ubuntu disk is excluded'
        Assert-Contains ($paths -join ';') 'docker_data.vhdx' 'the Docker disk is excluded'
        # A bare \\wsl$ would tell Defender to stop scanning the live filesystem
        # of every distro on the box. It was deliberately not ported.
        Assert-NotContains ($paths -join ';') 'wsl$' 'no blanket \\wsl$ exclusion is added'
        Assert-NotContains ($paths -join ';') 'LocalState;' 'containing directories are not excluded, only the files'
    } finally { Remove-TestDir $root }
}

# The configured distro picks which distro disk is excluded.
function Test-PathExclusionsFollowTheConfiguredDistro {
    $root = New-TestDir 'defender-paths'
    try {
        foreach ($pkg in @('TheDebianProject.DebianGNULinux_x', 'CanonicalGroupLimited.Ubuntu_x')) {
            $d = Join-Path $root "Packages\$pkg\LocalState"
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $d 'ext4.vhdx') -Value 'x'
        }
        $old = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $root
        try { $paths = @(Get-MaintExclusionPaths -Distro 'Debian') } finally { $env:LOCALAPPDATA = $old }
        Assert-Eq 1 $paths.Count 'one distro disk, no Docker disk here'
        Assert-Contains ($paths -join ';') 'DebianGNULinux_x' 'the configured distro''s disk is excluded'
        Assert-NotContains ($paths -join ';') 'Ubuntu_x' 'another distro''s disk is not'
    } finally { Remove-TestDir $root }
}

# Two disks match the distro: like compact, defender refuses to guess which one
# is meant instead of excluding whichever enumerated first. Same lookup as
# Compact.ps1 (Get-DistroVhdxPath in Common.ps1).
function Test-PathExclusionsRefuseTwoMatchingDisks {
    $root = New-TestDir 'defender-paths'
    try {
        foreach ($pkg in @('CanonicalGroupLimited.Ubuntu_x', 'CanonicalGroupLimited.Ubuntu22.04LTS_x')) {
            $d = Join-Path $root "Packages\$pkg\LocalState"
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $d 'ext4.vhdx') -Value 'x'
        }
        $old = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $root
        $err = $null
        try { Get-MaintExclusionPaths -Distro Ubuntu | Out-Null } catch { $err = "$_" } finally { $env:LOCALAPPDATA = $old }
        Assert-Contains "$err" 'More than one Ubuntu disk found' 'two matching disks are refused'
        Assert-Contains "$err" 'Ubuntu_x' 'the first package is listed'
        Assert-Contains "$err" 'Ubuntu22.04LTS_x' 'the second package is listed'
    } finally { Remove-TestDir $root }
}

# Invoke-MaintDefender hands the configured distro to the path lookup.
function Test-DefenderUsesTheConfiguredDistro {
    $script:AskedFor = $null
    function Get-MaintConfig { @{ Distro = 'Debian'; BackupRoot = $null; Keep = 3 } }
    function Get-MpPreference { [CmdletBinding()] param() [pscustomobject]@{ ExclusionPath = @(); ExclusionProcess = @() } }
    function Get-MaintExclusionPaths { param($Distro) $script:AskedFor = $Distro; @() }
    $script:Logs = @()
    Invoke-MaintDefender -Verify
    Assert-Eq 'Debian' $script:AskedFor 'the lookup is for the configured distro'
}

# --- The unelevated sentinel -------------------------------------------------
# Unelevated, Get-MpPreference returns a one-element array containing a literal
# "N/A: ..." string instead of the real lists. Compared naively, every real
# path would read as MISS -- i.e. "no exclusions configured" when the truth is
# simply unknown from this shell.
function Test-VerifySaysUnknownRatherThanMissWhenUnreadable {
    $r = Invoke-DefenderScenario -Verify -HavePaths @($script:Sentinel) -HaveProcs @($script:Sentinel) -WantPaths @('C:\x\ext4.vhdx')
    Assert-Null $r.Error '-Verify does not throw when it cannot read'
    Assert-Contains $r.Log 'cannot read Defender exclusions unelevated' 'it says the state is unknown'
    Assert-NotContains $r.Log 'MISS' 'it does NOT report the exclusions as missing'
    Assert-Eq 0 $r.Added.Count '-Verify adds nothing'
}

function Test-ApplyRefusesToGuessWhenUnreadable {
    $r = Invoke-DefenderScenario -HavePaths @($script:Sentinel) -HaveProcs @($script:Sentinel) -WantPaths @('C:\x\ext4.vhdx')
    Assert-NotNull $r.Error 'an unreadable elevated read is fatal'
    Assert-Contains $r.Error 'refusing to guess' 'it refuses rather than re-adding blind'
    Assert-Eq 0 $r.Added.Count 'nothing was added'
    Assert-True $r.AdminChecked 'elevation was asserted first'
}

function Test-GetMpPreferenceFailureIsWrapped {
    $r = Invoke-DefenderScenario -PrefsThrow
    Assert-NotNull $r.Error 'a failing Get-MpPreference is fatal'
    Assert-Contains $r.Error 'Get-MpPreference failed' 'the wrapper names the call'
    Assert-Contains $r.Error 'Defender may be disabled or managed by policy' 'the hint is kept'
}

# --- -Verify is read-only ----------------------------------------------------
function Test-VerifyNeverWritesEvenWhenEverythingIsMissing {
    $r = Invoke-DefenderScenario -Verify -HavePaths @() -HaveProcs @() -WantPaths @('C:\x\ext4.vhdx')
    Assert-Null $r.Error '-Verify reports rather than throws'
    Assert-Eq 0 $r.Added.Count '-Verify never adds an exclusion'
    Assert-False $r.AdminChecked '-Verify does not demand elevation'
    Assert-Contains $r.Log '[warn] MISS path C:\x\ext4.vhdx' 'a missing path is reported'
    Assert-Contains $r.Log '[warn] MISS proc C:\PF\WSL\wsl.exe' 'a missing process is reported'
    Assert-Contains $r.Log 'run: maint.bat defender' 'it tells the operator how to fix it'
}

function Test-VerifyReportsOkWhenFullyConfigured {
    $r = Invoke-DefenderScenario -Verify -HavePaths @('C:\x\ext4.vhdx') -HaveProcs $script:Procs -WantPaths @('C:\x\ext4.vhdx')
    Assert-Null $r.Error 'no error'
    Assert-Contains $r.Log 'OK   path C:\x\ext4.vhdx' 'the configured path is reported OK'
    Assert-NotContains $r.Log 'MISS' 'nothing is reported missing'
    Assert-NotContains $r.Log 'run: maint.bat defender' 'no remediation hint when all is well'
}

# --- Apply -------------------------------------------------------------------
function Test-ApplyAddsOnlyWhatIsMissing {
    $have = @('C:\PF\WSL\wsl.exe', 'C:\PF\WSL\wslhost.exe')
    $r = Invoke-DefenderScenario -HavePaths @('C:\x\ext4.vhdx') -HaveProcs $have -WantPaths @('C:\x\ext4.vhdx', 'C:\x\docker_data.vhdx')

    Assert-Null $r.Error 'a clean apply does not throw'
    Assert-NotContains ($r.Added -join ';') 'path:C:\x\ext4.vhdx' 'an already-excluded path is not re-added'
    Assert-Contains ($r.Added -join ';') 'path:C:\x\docker_data.vhdx' 'the missing path is added'
    Assert-NotContains ($r.Added -join ';') 'proc:C:\PF\WSL\wsl.exe' 'an already-excluded process is not re-added'
    Assert-Contains ($r.Added -join ';') 'proc:C:\PF\Docker\Docker\resources\dockerd.exe' 'a missing process is added'
    Assert-Eq 6 $r.Added.Count 'one path plus the five missing processes'
    Assert-Contains $r.Log 'defender exclusions applied' 'success is logged'
}

# A failure to add must not vanish into a clean-looking summary, and must not
# stop the remaining exclusions from being applied.
function Test-PartialAddFailureAppliesRestThenThrows {
    $r = Invoke-DefenderScenario -WantPaths @('C:\x\ext4.vhdx') -FailToAdd @('C:\x\ext4.vhdx', 'C:\PF\Docker\Docker\resources\dockerd.exe')

    Assert-NotNull $r.Error 'a partial failure surfaces as a throw'
    Assert-Contains $r.Error 'Defender exclusions partially applied' 'the throw names the situation'
    Assert-Contains $r.Error 'path:C:\x\ext4.vhdx' 'the failed path is listed'
    Assert-Contains $r.Error 'proc:C:\PF\Docker\Docker\resources\dockerd.exe' 'the failed process is listed'
    Assert-Eq 6 $r.Added.Count 'the other six exclusions were still applied'
    Assert-Contains $r.Log '[warn] failed to add path exclusion' 'the path failure is logged'
    Assert-Contains $r.Log '[warn] failed to add process exclusion' 'the process failure is logged'
    Assert-NotContains $r.Log 'defender exclusions applied' 'it does not claim success'
}

# The distro disk is not found (a distro typo in maint.conf, or UAC elevating a
# separate admin account whose HKCU/LOCALAPPDATA hold no WSL disk). Only the
# Docker disk is on the list. Like compact, it warns and goes on (exit 0), but
# the summary must not read as a full success.
function Test-ApplyWarnsWhenTheDistroDiskIsNotFound {
    $r = Invoke-DefenderScenario -WantPaths @(Join-Path $env:LOCALAPPDATA 'Docker\wsl\disk\docker_data.vhdx')
    Assert-Null $r.Error 'a missing distro disk warns, it does not throw (as compact)'
    Assert-Contains $r.Log '[warn] no disk found for distro Ubuntu' 'the missing disk is named'
    Assert-Contains ($r.Added -join ';') 'proc:C:\PF\WSL\wsl.exe' 'the processes are still excluded'
    Assert-NotContains $r.Log '[info] defender exclusions applied' 'no unqualified success line'
    Assert-Contains $r.Log '[warn] defender exclusions applied, but the Ubuntu disk was not found' 'the summary says the disk is not excluded'
}

function Test-VerifyReportsTheMissingDistroDisk {
    $r = Invoke-DefenderScenario -Verify -HavePaths @() -HaveProcs $script:Procs -WantPaths @()
    Assert-Null $r.Error '-Verify reports rather than throws'
    Assert-Contains $r.Log '[warn] no disk found for distro Ubuntu' 'the lookup failure is named'
    Assert-Contains $r.Log '[warn] MISS path Ubuntu disk (not found)' 'the distro disk is reported missing'
}

Test-ProcessExclusionsAreResolvedFullPaths
Test-MissingProcessImageIsSkippedWithWarn
Test-ApplyAddsFullPathProcessExclusions
Test-VerifyFlagsStaleBareNameExclusions
Test-ApplyWarnsAboutStaleBareNamesButKeepsThem
Test-PathExclusionsAreTheTwoVhdxFilesOnly
Test-PathExclusionsFollowTheConfiguredDistro
Test-PathExclusionsRefuseTwoMatchingDisks
Test-DefenderUsesTheConfiguredDistro
Test-VerifySaysUnknownRatherThanMissWhenUnreadable
Test-ApplyRefusesToGuessWhenUnreadable
Test-GetMpPreferenceFailureIsWrapped
Test-VerifyNeverWritesEvenWhenEverythingIsMissing
Test-VerifyReportsOkWhenFullyConfigured
Test-ApplyAddsOnlyWhatIsMissing
Test-PartialAddFailureAppliesRestThenThrows
Test-ApplyWarnsWhenTheDistroDiskIsNotFound
Test-VerifyReportsTheMissingDistroDisk

Write-AssertSummary
