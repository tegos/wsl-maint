# win\Compact.ps1 -- Wait-WslStopped, Get-WslVhdxPaths, Invoke-MaintCompact.
#
# LOGIC-ONLY COVERAGE. wsl.exe is a shadowed PowerShell function here, so these
# tests prove Wait-WslStopped's decisions (what counts as "stopped", what
# counts as inconclusive, when it throws) and NOT how the real wsl.exe binary
# behaves on the wire -- see the header of Run.ps1.
#
# Nothing here can touch the real VM or a real VHDX: wsl.exe, Invoke-Wsl,
# Optimize-VHD and Get-WslVhdxPaths are all shadowed, and the only files
# involved are dummies created under the temp dir by this file.

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'Assert.ps1')
. (Join-Path (Split-Path -Parent (Split-Path -Parent $here)) 'win\Common.ps1')
. (Join-Path (Split-Path -Parent (Split-Path -Parent $here)) 'win\Compact.ps1')

# File-wide: Invoke-MaintCompact reads the distro from config, and the
# operator's real maint.conf must never decide what a test compacts.
function Get-MaintConfig { @{ Distro = 'Ubuntu'; BackupRoot = $null; Keep = 3 } }
# Common.ps1 is loaded for Get-DistroVhdxPath only. Its real Invoke-Wsl and
# Write-MaintLog must never run from here (a shutdown, a write to the repo's
# logs\): a test that forgets to shadow them fails loudly instead.
function Invoke-Wsl { param($Arguments) throw 'TEST GUARD: the real Invoke-Wsl must never be reached' }
function Write-MaintLog { param($Level = 'info', $Message) throw 'TEST GUARD: the real Write-MaintLog must never be reached' }
# No registered distros: the real HKCU Lxss key is never read, and the disk
# lookup falls back to the Packages glob under the temp LOCALAPPDATA below.
# The registry path itself is covered in Test-Common.ps1.
function Get-LxssDistroEntries { @() }

$script:Polls = 0

# --- The Critical regression -------------------------------------------------
# A wsl.exe that fails with a non-zero exit and empty stdout must NOT read as
# "nothing running". Before the fix this returned in ~1ms with no throw, and
# Invoke-MaintCompact went on to Optimize-VHD a possibly-live disk.
function Test-NonZeroExitWithEmptyStdoutIsNotStopped {
    function wsl.exe {
        [CmdletBinding()] param([Parameter(ValueFromRemainingArguments = $true)]$WslArgs)
        $script:Polls++
        $global:LASTEXITCODE = 1
        @()
    }
    $script:Polls = 0
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $err = $null
    try { Wait-WslStopped -TimeoutSeconds 2 -PollSeconds 1 } catch { $err = $_ }
    $sw.Stop()

    Assert-NotNull $err 'exit 1 + empty stdout must not be read as stopped'
    Assert-Contains "$err" 'exited 1' 'throw names the failing poll exit code'
    Assert-Contains "$err" 'could not be trusted' 'throw says the reading was inconclusive'
    # Assert-True, not Assert-NotContains: a bare NotContains here also passes
    # when $err is $null or empty, i.e. exactly when the throw above went
    # missing. Requiring a non-empty message first makes this fail on that too.
    Assert-True ((("$err").Length -gt 0) -and (-not ("$err").Contains('still running:'))) 'inconclusive is reported as inconclusive, not as a running-distro list'
    Assert-True ($script:Polls -ge 2) "it kept polling instead of giving up (polls=$($script:Polls))"
    Assert-True ($sw.ElapsedMilliseconds -ge 1000) "it did not return instantly (elapsed=$($sw.ElapsedMilliseconds)ms)"
}

function Test-GenuinelyStoppedReturnsPromptly {
    function wsl.exe {
        [CmdletBinding()] param([Parameter(ValueFromRemainingArguments = $true)]$WslArgs)
        $script:Polls++
        $global:LASTEXITCODE = 0
        @()
    }
    $script:Polls = 0
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $err = $null
    try { Wait-WslStopped -TimeoutSeconds 60 -PollSeconds 2 } catch { $err = $_ }
    $sw.Stop()

    Assert-Null $err 'exit 0 + empty listing returns without throwing'
    # Poll count, not wall-clock: a single poll IS the promptness claim, and it
    # cannot go flaky on a loaded box the way an elapsed-time bound can. The
    # opposite direction (did NOT return instantly) is still asserted on time
    # in Test-NonZeroExitWithEmptyStdoutIsNotStopped, where a fast return is
    # exactly the bug and no counter can stand in for it.
    Assert-Eq 1 $script:Polls 'it stopped after the first conclusive poll'
}

function Test-StillRunningKeepsPollingThenThrows {
    function wsl.exe {
        [CmdletBinding()] param([Parameter(ValueFromRemainingArguments = $true)]$WslArgs)
        $script:Polls++
        $global:LASTEXITCODE = 0
        @('Ubuntu')
    }
    $script:Polls = 0
    $err = $null
    try { Wait-WslStopped -TimeoutSeconds 2 -PollSeconds 1 } catch { $err = $_ }

    Assert-NotNull $err 'a still-running distro must end in a throw, not a proceed'
    Assert-Contains "$err" 'still running: Ubuntu' 'throw names what is still running'
    Assert-True ($script:Polls -ge 2) "it polled more than once (polls=$($script:Polls))"
}

# wsl.exe stdout is UTF-16LE and PowerShell does not decode it, so a real
# listing arrives as characters interleaved with literal nulls. Emptiness is
# decided structurally after stripping them -- never by matching message text.
function Test-NullInterleavedNameStillCountsAsRunning {
    function wsl.exe {
        [CmdletBinding()] param([Parameter(ValueFromRemainingArguments = $true)]$WslArgs)
        $script:Polls++
        $global:LASTEXITCODE = 0
        @(("U`0b`0u`0n`0t`0u`0"))
    }
    $script:Polls = 0
    $err = $null
    try { Wait-WslStopped -TimeoutSeconds 2 -PollSeconds 1 } catch { $err = $_ }

    Assert-NotNull $err 'a null-interleaved distro name is still a running distro'
    Assert-Contains "$err" 'still running: Ubuntu' 'nulls are stripped before reporting'
}

function Test-BlankAndNullOnlyOutputCountsAsStopped {
    function wsl.exe {
        [CmdletBinding()] param([Parameter(ValueFromRemainingArguments = $true)]$WslArgs)
        $script:Polls++
        $global:LASTEXITCODE = 0
        @('', "`0`0", '   ')
    }
    $script:Polls = 0
    $err = $null
    try { Wait-WslStopped -TimeoutSeconds 60 -PollSeconds 2 } catch { $err = $_ }

    Assert-Null $err 'blank/null-only lines are structurally empty, i.e. stopped'
    Assert-Eq 1 $script:Polls 'one poll was enough'
}

function Test-NonZeroExitWithContentIsAlsoInconclusive {
    function wsl.exe {
        [CmdletBinding()] param([Parameter(ValueFromRemainingArguments = $true)]$WslArgs)
        $script:Polls++
        $global:LASTEXITCODE = 4
        @('Ubuntu')
    }
    $script:Polls = 0
    $err = $null
    try { Wait-WslStopped -TimeoutSeconds 2 -PollSeconds 1 } catch { $err = $_ }

    Assert-NotNull $err 'non-zero exit with content still ends in a throw'
    Assert-Contains "$err" 'exited 4' 'the inconclusive-exit message wins over the running list'
}

# A transient failure must not be fatal on its own: the loop retries, and a
# later conclusive poll resolves it.
function Test-TransientFailureThenStoppedResolves {
    function wsl.exe {
        [CmdletBinding()] param([Parameter(ValueFromRemainingArguments = $true)]$WslArgs)
        $script:Polls++
        if ($script:Polls -eq 1) { $global:LASTEXITCODE = 1; return @('garbage') }
        $global:LASTEXITCODE = 0
        @()
    }
    $script:Polls = 0
    $err = $null
    try { Wait-WslStopped -TimeoutSeconds 30 -PollSeconds 1 } catch { $err = $_ }

    Assert-Null $err 'a transient poll failure followed by a clean poll must not throw'
    Assert-Eq 2 $script:Polls 'it retried exactly once before succeeding'
}

# --- Get-WslVhdxPaths --------------------------------------------------------
function Test-GetWslVhdxPathsFindsBothDisks {
    $root = New-TestDir 'compact-paths'
    try {
        $ub = Join-Path $root 'Packages\CanonicalGroupLimited.Ubuntu_x\LocalState'
        $dk = Join-Path $root 'Docker\wsl\disk'
        New-Item -ItemType Directory -Path $ub -Force | Out-Null
        New-Item -ItemType Directory -Path $dk -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $ub 'ext4.vhdx') -Value 'x'
        Set-Content -LiteralPath (Join-Path $dk 'docker_data.vhdx') -Value 'x'

        $old = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $root
        try { $found = @(Get-WslVhdxPaths -Distro Ubuntu) } finally { $env:LOCALAPPDATA = $old }

        Assert-Eq 2 $found.Count 'both VHDX files are discovered'
        Assert-Eq 'Ubuntu' $found[0].Name 'Ubuntu is listed first'
        Assert-Eq 'Docker' $found[1].Name 'Docker is listed second'
        Assert-Contains $found[0].Path 'LocalState\ext4.vhdx' 'Ubuntu path points at ext4.vhdx'
    } finally { Remove-TestDir $root }
}

function Test-GetWslVhdxPathsSkipsMissingDocker {
    $root = New-TestDir 'compact-paths'
    try {
        $ub = Join-Path $root 'Packages\CanonicalGroupLimited.Ubuntu_x\LocalState'
        New-Item -ItemType Directory -Path $ub -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $ub 'ext4.vhdx') -Value 'x'

        $old = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $root
        try { $found = @(Get-WslVhdxPaths -Distro Ubuntu) } finally { $env:LOCALAPPDATA = $old }

        Assert-Eq 1 $found.Count 'a missing docker_data.vhdx is skipped, not invented'
        Assert-Eq 'Ubuntu' $found[0].Name 'only Ubuntu remains'
    } finally { Remove-TestDir $root }
}

function Test-GetWslVhdxPathsEmptyWhenNothingInstalled {
    $root = New-TestDir 'compact-paths'
    try {
        $old = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $root
        try { $found = @(Get-WslVhdxPaths -Distro Ubuntu) } finally { $env:LOCALAPPDATA = $old }
        Assert-Eq 0 $found.Count 'no disks found on a bare profile'
    } finally { Remove-TestDir $root }
}

# Two Ubuntu packages with a disk each: which one is "Ubuntu" is not decidable
# from the wildcard, so it throws and lists both rather than compacting
# whichever the enumeration returned first.
function Test-GetWslVhdxPathsThrowsOnTwoUbuntuDisks {
    $root = New-TestDir 'compact-paths'
    try {
        foreach ($pkg in @('CanonicalGroupLimited.Ubuntu_x', 'CanonicalGroupLimited.Ubuntu22.04LTS_x')) {
            $d = Join-Path $root "Packages\$pkg\LocalState"
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $d 'ext4.vhdx') -Value 'x'
        }

        $old = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $root
        $err = $null
        try { Get-WslVhdxPaths -Distro Ubuntu | Out-Null } catch { $err = "$_" } finally { $env:LOCALAPPDATA = $old }

        Assert-NotNull $err 'two Ubuntu disks refuse to guess'
        Assert-Contains "$err" 'Ubuntu_x' 'the first package is listed'
        Assert-Contains "$err" 'Ubuntu22.04LTS_x' 'the second package is listed'
    } finally { Remove-TestDir $root }
}

# An Ubuntu package with no disk (installed, never launched) is not a candidate.
function Test-GetWslVhdxPathsIgnoresUbuntuPackageWithoutDisk {
    $root = New-TestDir 'compact-paths'
    try {
        $ub = Join-Path $root 'Packages\CanonicalGroupLimited.Ubuntu_x\LocalState'
        New-Item -ItemType Directory -Path $ub -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $ub 'ext4.vhdx') -Value 'x'
        New-Item -ItemType Directory -Path (Join-Path $root 'Packages\CanonicalGroupLimited.Ubuntu22.04LTS_x\LocalState') -Force | Out-Null

        $old = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $root
        try { $found = @(Get-WslVhdxPaths -Distro Ubuntu) } finally { $env:LOCALAPPDATA = $old }

        Assert-Eq 1 $found.Count 'only the package with a disk counts'
        Assert-Contains $found[0].Path 'Ubuntu_x' 'and it is the one with the disk'
    } finally { Remove-TestDir $root }
}

# The configured distro picks the package: on a box with both Debian and
# Ubuntu installed, distro Debian compacts Debian's disk and names it so.
function Test-GetWslVhdxPathsFollowsTheConfiguredDistro {
    $root = New-TestDir 'compact-paths'
    try {
        foreach ($pkg in @('TheDebianProject.DebianGNULinux_x', 'CanonicalGroupLimited.Ubuntu_x')) {
            $d = Join-Path $root "Packages\$pkg\LocalState"
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $d 'ext4.vhdx') -Value 'x'
        }
        $old = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $root
        try { $found = @(Get-WslVhdxPaths -Distro 'Debian') } finally { $env:LOCALAPPDATA = $old }

        Assert-Eq 1 $found.Count 'only the configured distro''s disk'
        Assert-Eq 'Debian' $found[0].Name 'it is named after the configured distro'
        Assert-Contains $found[0].Path 'DebianGNULinux_x' 'and it is the Debian package''s disk'
    } finally { Remove-TestDir $root }
}

# A distro whose package cannot be found by name is said out loud, not
# skipped silently while only Docker gets compacted.
function Test-CompactWarnsWhenTheDistroDiskIsNotFound {
    $root = New-TestDir 'compact-nodisk'
    try {
        $vhd = Join-Path $root 'docker_data.vhdx'
        Set-Content -LiteralPath $vhd -Value 'x'
        $script:Log = @()
        function Get-MaintConfig { @{ Distro = 'Arch'; BackupRoot = $null; Keep = 3 } }
        function Write-MaintLog { param($Level = 'info', $Message) $script:Log += "[$Level] $Message" }
        function Get-WslVhdxPaths { param($Distro) @([pscustomobject]@{ Name = 'Docker'; Path = $vhd }) }
        function Format-Gb { param([long]$Bytes) "$Bytes B" }
        function Optimize-VHD { [CmdletBinding()] param($Path, $Mode) }
        Invoke-MaintCompact -DryRun
        Assert-Contains ($script:Log -join "`n") '[warn] no disk found for distro Arch' 'the missing distro disk is reported'
    } finally { Remove-TestDir $root }
}

# --- Invoke-MaintCompact -----------------------------------------------------
# Every destructive dependency is shadowed twice over: Invoke-Wsl is replaced,
# AND wsl.exe underneath it is replaced, so even a failed shadow cannot reach a
# real `wsl --shutdown`.
function Test-DryRunNeverShutsDownOrOptimizes {
    $root = New-TestDir 'compact-dry'
    try {
        $vhd = Join-Path $root 'ext4.vhdx'
        Set-Content -LiteralPath $vhd -Value 'x'
        $script:Log = @()
        $script:Side = @()

        function wsl.exe { [CmdletBinding()] param([Parameter(ValueFromRemainingArguments = $true)]$WslArgs) $script:Side += 'wsl.exe'; $global:LASTEXITCODE = 0 }
        function Invoke-Wsl { param($Arguments) $script:Side += 'Invoke-Wsl' }
        function Wait-WslStopped { param($TimeoutSeconds, $PollSeconds) $script:Side += 'Wait-WslStopped' }
        function Optimize-VHD { [CmdletBinding()] param($Path, $Mode) $script:Side += 'Optimize-VHD' }
        function Write-MaintLog { param($Level = 'info', $Message) $script:Log += "[$Level] $Message" }
        function Get-WslVhdxPaths { @([pscustomobject]@{ Name = 'Ubuntu'; Path = $vhd }) }
        function Format-Gb { param([long]$Bytes) "$Bytes B" }
        function Get-FreeSpaceGb { param($DriveLetter) 100 }

        Invoke-MaintCompact -DryRun

        Assert-Eq 0 @($script:Side).Count "-DryRun performed no side effects (saw: $($script:Side -join ','))"
        Assert-Contains ($script:Log -join "`n") 'DRY would run wsl --shutdown' '-DryRun says what it would have done'
        Assert-Contains ($script:Log -join "`n") 'found Ubuntu' 'targets are still enumerated and logged'
    } finally { Remove-TestDir $root }
}

function Test-MissingOptimizeVhdThrowsBeforeAnything {
    $script:Side = @()
    function wsl.exe { [CmdletBinding()] param([Parameter(ValueFromRemainingArguments = $true)]$WslArgs) $script:Side += 'wsl.exe'; $global:LASTEXITCODE = 0 }
    function Invoke-Wsl { param($Arguments) $script:Side += 'Invoke-Wsl' }
    function Get-Command { param($Name, $ErrorAction) $null }
    function Get-WslVhdxPaths { $script:Side += 'Get-WslVhdxPaths'; @() }

    $err = $null
    try { Invoke-MaintCompact } catch { $err = $_ }
    Assert-NotNull $err 'a box without the Hyper-V module refuses to compact'
    Assert-Contains "$err" 'Optimize-VHD is unavailable' 'the reason is named'
    Assert-Eq 0 @($script:Side).Count 'it bailed before enumerating or shutting anything down'
}

# One VHDX failing must not silently disappear into a clean summary, and must
# not stop the other VHDX from being compacted.
function Test-PartialOptimizeFailureCompactsRestThenThrows {
    $root = New-TestDir 'compact-partial'
    try {
        $a = Join-Path $root 'ext4.vhdx'
        $b = Join-Path $root 'docker_data.vhdx'
        Set-Content -LiteralPath $a -Value 'aaaa'
        Set-Content -LiteralPath $b -Value 'bbbb'
        $script:Log = @()
        $script:Optimized = @()
        $script:WslCalls = @()

        function wsl.exe { [CmdletBinding()] param([Parameter(ValueFromRemainingArguments = $true)]$WslArgs) $script:WslCalls += 'RAW-WSL-REACHED'; $global:LASTEXITCODE = 0 }
        function Invoke-Wsl { param($Arguments) $script:WslCalls += ($Arguments -join ' ') }
        function Wait-WslStopped { param($TimeoutSeconds, $PollSeconds) $script:WslCalls += 'wait' }
        function Optimize-VHD {
            [CmdletBinding()] param($Path, $Mode)
            $script:Optimized += $Path
            if ($Path -like '*docker_data.vhdx') { throw 'The process cannot access the file' }
        }
        function Write-MaintLog { param($Level = 'info', $Message) $script:Log += "[$Level] $Message" }
        function Format-Gb { param([long]$Bytes) "$Bytes B" }
        function Get-WslVhdxPaths {
            @([pscustomobject]@{ Name = 'Ubuntu'; Path = $a }, [pscustomobject]@{ Name = 'Docker'; Path = $b })
        }
        function Get-FreeSpaceGb { param($DriveLetter) 123.45 }

        $err = $null
        try { Invoke-MaintCompact } catch { $err = $_ }
        $log = $script:Log -join "`n"

        Assert-NotNull $err 'a failed Optimize-VHD surfaces as a throw'
        Assert-Contains "$err" 'failed for: Docker' 'the throw names the VHDX that failed'
        Assert-Eq 2 @($script:Optimized).Count 'the healthy VHDX was still compacted after the failure'
        Assert-Contains $log '[warn] Docker: Optimize-VHD failed' 'the failure is logged as a warning'
        Assert-Contains $log 'total reclaimed' 'the summary still runs'
        Assert-NotContains ($script:WslCalls -join ' ') 'RAW-WSL-REACHED' 'the real wsl.exe was never invoked'
        Assert-Contains ($script:WslCalls -join ' ') '--shutdown' 'the shutdown went through the shadowed Invoke-Wsl'
    } finally { Remove-TestDir $root }
}

# A profile dir with brackets puts them in LOCALAPPDATA and so in every vhdx
# path. Read as wildcards they match nothing, and both disks went missing.
function Test-BracketedLocalAppDataFindsAndSizesBothDisks {
    $root = New-TestDir 'compact-brackets'
    try {
        $lad = [IO.Directory]::CreateDirectory((Join-Path $root 'lad [x]')).FullName
        $ub = [IO.Directory]::CreateDirectory((Join-Path $lad 'Packages\CanonicalGroupLimited.Ubuntu_x\LocalState')).FullName
        $dk = [IO.Directory]::CreateDirectory((Join-Path $lad 'Docker\wsl\disk')).FullName
        Set-Content -LiteralPath (Join-Path $ub 'ext4.vhdx') -Value 'x'
        Set-Content -LiteralPath (Join-Path $dk 'docker_data.vhdx') -Value 'x'
        # `lad x` is what `lad [x]` matches as a wildcard. Its disk has another
        # size, so reading it instead of the real one shows in the log. (With
        # no such sibling, -Path falls back to the literal path and hides it.)
        $decoy = [IO.Directory]::CreateDirectory((Join-Path $root 'lad x\Docker\wsl\disk')).FullName
        Set-Content -LiteralPath (Join-Path $decoy 'docker_data.vhdx') -Value ('d' * 50)
        $size = (Get-Item -LiteralPath (Join-Path $dk 'docker_data.vhdx')).Length

        $old = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $lad
        try { $found = @(Get-WslVhdxPaths -Distro Ubuntu) } finally { $env:LOCALAPPDATA = $old }
        Assert-Eq 2 $found.Count 'both disks under a bracketed LOCALAPPDATA are found'

        $script:Log = @()
        function Write-MaintLog { param($Level = 'info', $Message) $script:Log += "[$Level] $Message" }
        function Optimize-VHD { [CmdletBinding()] param($Path, $Mode) }
        function Format-Gb { param([long]$Bytes) "$Bytes B" }
        # Fed directly, so the sizing check does not depend on discovery above.
        $script:BracketDisks = @([pscustomobject]@{ Name = 'Ubuntu'; Path = (Join-Path $ub 'ext4.vhdx') },
                                 [pscustomobject]@{ Name = 'Docker'; Path = (Join-Path $dk 'docker_data.vhdx') })
        function Get-WslVhdxPaths { $script:BracketDisks }
        $err = $null
        try { Invoke-MaintCompact -DryRun } catch { $err = "$_" }
        Assert-Null $err 'sizing a bracketed vhdx path does not throw'
        Assert-Contains ($script:Log -join "`n") ("docker_data.vhdx ($size B)") 'the bracketed Docker disk is sized, not the wildcard sibling'
    } finally { Remove-TestDir $root }
}

Test-NonZeroExitWithEmptyStdoutIsNotStopped
Test-GenuinelyStoppedReturnsPromptly
Test-StillRunningKeepsPollingThenThrows
Test-NullInterleavedNameStillCountsAsRunning
Test-BlankAndNullOnlyOutputCountsAsStopped
Test-NonZeroExitWithContentIsAlsoInconclusive
Test-TransientFailureThenStoppedResolves
Test-GetWslVhdxPathsFindsBothDisks
Test-GetWslVhdxPathsSkipsMissingDocker
Test-GetWslVhdxPathsEmptyWhenNothingInstalled
Test-GetWslVhdxPathsThrowsOnTwoUbuntuDisks
Test-GetWslVhdxPathsIgnoresUbuntuPackageWithoutDisk
Test-GetWslVhdxPathsFollowsTheConfiguredDistro
Test-CompactWarnsWhenTheDistroDiskIsNotFound
Test-DryRunNeverShutsDownOrOptimizes
Test-MissingOptimizeVhdThrowsBeforeAnything
Test-PartialOptimizeFailureCompactsRestThenThrows
Test-BracketedLocalAppDataFindsAndSizesBothDisks

Write-AssertSummary
