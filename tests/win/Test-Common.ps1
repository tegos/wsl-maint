# win\Common.ps1 -- Get-MaintConfig, Write-MaintLog, Get-FreeSpaceGb,
# Format-Gb, Invoke-Wsl.
#
# LOGIC-ONLY COVERAGE for Invoke-Wsl: wsl.exe is a shadowed function, so the
# exit-code branch is proved but not real native-process plumbing. See the
# header of Run.ps1.
#
# Assert-Admin is deliberately NOT tested: it reads the real process token, so
# any assertion about it would either duplicate its own implementation or give
# a different verdict in an elevated shell. It is covered by manual runs.

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent (Split-Path -Parent $here)
. (Join-Path $here 'Assert.ps1')
. (Join-Path $repo 'win\Common.ps1')

# Redirect Write-MaintLog's log directory away from the repo's real logs\ for
# the whole file. Common.ps1 reads this variable at call time, and dot-sourcing
# put it in this file's script scope.
$script:LogSandbox = New-TestDir 'common-logs'
$script:MaintRepoRoot = $script:LogSandbox

# --- Get-MaintConfig ---------------------------------------------------------
# Runs $Script with WSL_MAINT_CONFIG pointing at a temp maint.conf holding
# $Lines, and hands it the file's path. The variable is restored in finally so
# a throwing assertion cannot leak it into the next test.
function Invoke-WithConfig {
    param([string[]]$Lines, [Parameter(Mandatory)][scriptblock]$Script)
    $dir = New-TestDir 'maint-conf'
    $file = Join-Path $dir 'maint.conf'
    $prev = $env:WSL_MAINT_CONFIG
    try {
        Set-Content -LiteralPath $file -Value $Lines
        $env:WSL_MAINT_CONFIG = $file
        & $Script $file
    } finally {
        $env:WSL_MAINT_CONFIG = $prev
        Remove-TestDir $dir
    }
}

# maint.conf is one file for both halves, so it is read as UTF-8 like the WSL
# side reads it, with or without a BOM. The non-ASCII character is built from
# its code point so this .ps1 stays ASCII (PS 5.1 reads a BOM-less .ps1 as
# ANSI too).
function Test-GetMaintConfigReadsUtf8WithAndWithoutBom {
    $dir = New-TestDir 'maint-conf'
    $file = Join-Path $dir 'maint.conf'
    $prev = $env:WSL_MAINT_CONFIG
    try {
        $root = 'D:\Sicherungen\' + [char]0x00DC + 'bung'
        $utf8 = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllBytes($file, $utf8.GetBytes("backup_root = $root`n"))
        $env:WSL_MAINT_CONFIG = $file
        Assert-Eq $root (Get-MaintConfig).BackupRoot 'a BOM-less UTF-8 backup_root is read as written'
        [IO.File]::WriteAllBytes($file, [byte[]](0xEF, 0xBB, 0xBF) + $utf8.GetBytes("backup_root = $root`n"))
        Assert-Eq $root (Get-MaintConfig).BackupRoot 'a UTF-8 backup_root behind a BOM is read as written'
    } finally {
        $env:WSL_MAINT_CONFIG = $prev
        Remove-TestDir $dir
    }
}

# Throws from Get-MaintConfig, as a string, or $null when it did not throw.
function Get-ConfigError {
    $err = $null
    try { Get-MaintConfig | Out-Null } catch { $err = "$_" }
    $err
}

# No maint.conf at the repo root (the sandbox) and no override: generic
# defaults, and no backup root at all -- there is no sane place to guess.
function Test-GetMaintConfigDefaults {
    $prev = $env:WSL_MAINT_CONFIG
    $env:WSL_MAINT_CONFIG = ''
    try { $cfg = Get-MaintConfig } finally { $env:WSL_MAINT_CONFIG = $prev }
    Assert-Eq 'Ubuntu' $cfg.Distro 'distro name'
    Assert-Null $cfg.BackupRoot 'no backup root without a config'
    Assert-Eq 3 $cfg.Keep 'retention count'
    Assert-Eq 14 $cfg.WinCleanAge 'winclean app junk age'
}

function Test-GetMaintConfigReadsEachKey {
    Invoke-WithConfig -Lines @('distro = Debian', 'backup_root = E:\wsl backups\deb', 'keep = 5', 'winclean_age = 30') -Script {
        $cfg = Get-MaintConfig
        Assert-Eq 'Debian' $cfg.Distro 'distro comes from the file'
        Assert-Eq 'E:\wsl backups\deb' $cfg.BackupRoot 'backup_root keeps its backslashes and spaces'
        Assert-Eq 5 $cfg.Keep 'keep comes from the file'
        Assert-True ($cfg.Keep -is [int]) 'keep is a number, not the string "5"'
        Assert-Eq 30 $cfg.WinCleanAge 'winclean_age comes from the file'
        Assert-True ($cfg.WinCleanAge -is [int]) 'winclean_age is a number'
    }
}

# Empty means "use the default". The bash-only keys are accepted, so one
# file serves both halves. Values are data: a $(...) is never run, and a #
# after the value is part of it (only whole-line comments exist).
function Test-GetMaintConfigValueSemantics {
    $canary = Join-Path ([IO.Path]::GetTempPath()) ('maint-canary-' + [Guid]::NewGuid().ToString('N'))
    $lines = @(
        '   # indented comment',
        'distro =',
        'keep = ',
        'winclean_age =',
        'docker_guard_extra = myapp|otherapp',
        'docker_named_volumes = yes',
        'pw_scan_roots_extra = /mnt/d/src:/home/me/x',
        ('backup_root = D:\b$(New-Item -ItemType File -Path ''' + $canary + ''')#not-a-comment')
    )
    Invoke-WithConfig -Lines $lines -Script {
        $err = Get-ConfigError
        Assert-Null $err 'empty values and bash-only keys are accepted'
        $cfg = Get-MaintConfig
        Assert-Eq 'Ubuntu' $cfg.Distro 'an empty distro means the default'
        Assert-Eq 3 $cfg.Keep 'an empty keep means the default'
        Assert-Eq 14 $cfg.WinCleanAge 'an empty winclean_age means the default'
        Assert-Eq ('D:\b$(New-Item -ItemType File -Path ''' + $canary + ''')#not-a-comment') $cfg.BackupRoot 'the value is kept verbatim'
        Assert-FileMissing $canary 'the $(...) in a value was never executed'
    }
}

# A typo must stop the run, not be silently ignored, and the message must say
# where: the file and the 1-based line number.
function Test-GetMaintConfigRejectsBrokenLinesWithFileAndLine {
    Invoke-WithConfig -Lines @('# my box', 'distro = Debian', 'backup_rot = D:\b') -Script {
        param($file)
        $err = Get-ConfigError
        Assert-NotNull $err 'an unknown key is an error'
        Assert-Contains "$err" "${file}:3" 'it names the file and the line'
        Assert-Contains "$err" 'backup_rot' 'it names the key it did not know'
    }
    Invoke-WithConfig -Lines @('', 'distro Debian') -Script {
        param($file)
        $err = Get-ConfigError
        Assert-NotNull $err 'a line without = is an error'
        Assert-Contains "$err" "${file}:2" 'it names the file and the line'
    }
    Invoke-WithConfig -Lines @(' = Debian') -Script {
        param($file)
        Assert-Contains "$(Get-ConfigError)" "${file}:1" 'an empty key is an error too'
    }
}

# keep feeds Select-Object -Skip in retention: 0 or garbage there would delete
# every archive, the new one included. distro ends up in archive file names
# and a -Filter pattern, so it is held to WSL's own name characters.
function Test-GetMaintConfigRejectsBadValues {
    foreach ($bad in @('keep = 0', 'keep = -1', 'keep = three', 'keep = 2.5',
                       'keep = 1001', 'keep = 99999999999999999999999',
                       'distro = Ub*', 'distro = my distro', 'distro = ..\x')) {
        Invoke-WithConfig -Lines @($bad) -Script {
            param($file)
            $err = Get-ConfigError
            Assert-NotNull $err "rejected: $bad"
            Assert-Contains "$err" "${file}:1" "the line is named for: $bad"
        }
    }
    # A keep longer than Int64 used to throw the raw cast error, without file:line.
    Invoke-WithConfig -Lines @('keep = 99999999999999999999999') -Script {
        param($file)
        Assert-Contains "$(Get-ConfigError)" "${file}:1: keep must be a whole number from 1 to 1000" 'an Int64 overflow gets the keep message'
    }
    # docker_named_volumes is an opt-in to pruning data: only an exact yes or
    # no, the same rule and message as wsl/lib/config.sh.
    foreach ($bad in @('docker_named_volumes = maybe', 'docker_named_volumes = Yes', 'docker_named_volumes = 1')) {
        Invoke-WithConfig -Lines @($bad) -Script {
            param($file)
            Assert-Contains "$(Get-ConfigError)" "${file}:1: docker_named_volumes must be yes or no, got: " "rejected: $bad"
        }
    }
    Invoke-WithConfig -Lines @('docker_named_volumes = no') -Script {
        Assert-Null (Get-ConfigError) 'docker_named_volumes = no is accepted'
    }
    Invoke-WithConfig -Lines @('keep = 01000') -Script {
        Assert-Eq 1000 (Get-MaintConfig).Keep 'leading zeros are fine, as on the bash side'
    }
    # winclean_age gates what winclean deletes: 0 would take a crash report
    # still being written. Same rule and message as wsl/lib/config.sh.
    foreach ($bad in @('0', 'abc', '3651', '-1', '2.5', '99999999999999999999999')) {
        Invoke-WithConfig -Lines @("winclean_age = $bad") -Script {
            param($file)
            Assert-Contains "$(Get-ConfigError)" "${file}:1: winclean_age must be a whole number from 1 to 3650, got: $bad" "rejected: winclean_age = $bad"
        }
    }
    Invoke-WithConfig -Lines @('winclean_age = 03650') -Script {
        Assert-Eq 3650 (Get-MaintConfig).WinCleanAge 'winclean_age = 3650 (leading zero) is accepted'
    }
    Invoke-WithConfig -Lines @('winclean_age = 1') -Script {
        Assert-Eq 1 (Get-MaintConfig).WinCleanAge 'winclean_age = 1 is accepted'
    }
}

# An explicit override that points nowhere is a mistake to report, not a
# reason to fall back to defaults the operator did not choose.
function Test-GetMaintConfigOverrideToMissingFileIsAnError {
    $dir = New-TestDir 'maint-conf'
    $prev = $env:WSL_MAINT_CONFIG
    try {
        $env:WSL_MAINT_CONFIG = Join-Path $dir 'nope.conf'
        $err = Get-ConfigError
        Assert-NotNull $err 'a missing override file is an error'
        Assert-Contains "$err" 'WSL_MAINT_CONFIG' 'the message names the variable'
        Assert-Contains "$err" 'nope.conf' 'and the path it pointed at'
    } finally {
        $env:WSL_MAINT_CONFIG = $prev
        Remove-TestDir $dir
    }
}

# --- Get-MaintWslArgs --------------------------------------------------------
# An override WSL cannot reach (UNC) must stop the call, not fall back to the
# repo-root file on the WSL side behind the operator's back.
function Test-GetMaintWslArgsRefusesAnUnreachableOverride {
    $err = $null
    try { Get-MaintWslArgs @{ Distro = 'Ubuntu'; ConfigOverride = '\\srv\share\maint.conf' } 'audit' | Out-Null } catch { $err = "$_" }
    Assert-Contains "$err" 'WSL_MAINT_CONFIG must be a local drive path' 'a UNC override is refused, naming the variable'
    $plain = @(Get-MaintWslArgs @{ Distro = 'Ubuntu'; ConfigOverride = $null } 'audit')
    Assert-Eq 'audit' $plain[-1] 'no override: the verb is the last argument'
}

# --- Get-FreeSpaceGb ---------------------------------------------------------
function Test-GetFreeSpaceGbAcceptsLetterOrQualifier {
    # The real Get-PSDrive rejects a qualifier ("a drive with the name 'D:'
    # does not exist"), which is the whole reason Get-FreeSpaceGb trims it.
    # The shadow reproduces that rejection, otherwise this test would pass
    # against a Get-FreeSpaceGb that had lost its .TrimEnd(':').
    function Get-PSDrive {
        param($Name)
        if ("$Name".Contains(':')) { throw "Cannot find drive. A drive with the name '$Name' does not exist." }
        [pscustomobject]@{ Free = 3221225472L }
    }
    Assert-Eq 3 (Get-FreeSpaceGb -DriveLetter 'D') 'bare letter'

    # Invoke-MaintBackup passes Split-Path -Qualifier output straight in, so
    # the qualifier form must not throw.
    $err = $null
    $withColon = $null
    try { $withColon = Get-FreeSpaceGb -DriveLetter 'D:' } catch { $err = "$_" }
    Assert-Null $err 'a trailing colon does not reach Get-PSDrive'
    Assert-Eq 3 $withColon 'trailing colon is tolerated'
}

function Test-GetFreeSpaceGbRoundsToTwoDecimals {
    function Get-PSDrive { param($Name) [pscustomobject]@{ Free = 1610612736L } }
    Assert-Eq 1.5 (Get-FreeSpaceGb -DriveLetter 'C') 'exactly 1.5 GB'

    function Get-PSDrive { param($Name) [pscustomobject]@{ Free = 1234567890L } }
    Assert-Eq 1.15 (Get-FreeSpaceGb -DriveLetter 'C') 'rounded to two decimals'

    function Get-PSDrive { param($Name) [pscustomobject]@{ Free = 0L } }
    Assert-Eq 0 (Get-FreeSpaceGb -DriveLetter 'C') 'a full disk reads as 0, not as an error'

    # The `-lt 40` guard in Invoke-MaintBackup compares this as a number, so a
    # sub-gigabyte free amount must not come back as a string like "0,52".
    function Get-PSDrive { param($Name) [pscustomobject]@{ Free = 557056000L } }
    $v = Get-FreeSpaceGb -DriveLetter 'C'
    Assert-True ($v -is [double]) 'the result is numeric'
    Assert-True ($v -lt 40) 'a small free amount compares as less than the 40 GB guard'
}

# --- Format-Gb ---------------------------------------------------------------
# Pinned to InvariantCulture at the source, so the output is the same on any
# console. The test runs under uk-UA (this box's culture, where N2 would use a
# decimal comma) to prove the pin, not the test, decides the format.
function Test-FormatGbIsCultureInvariant {
    $prev = [Threading.Thread]::CurrentThread.CurrentCulture
    [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('uk-UA')
    try {
        Assert-Eq '0.00 GB' (Format-Gb 0) 'zero'
        Assert-Eq '1.00 GB' (Format-Gb 1073741824) 'exactly 1 GiB'
        Assert-Eq '1.50 GB' (Format-Gb 1610612736) 'one and a half'
        Assert-Eq '20.00 GB' (Format-Gb 21474836480) 'a realistic export size'
        Assert-Eq '0.00 GB' (Format-Gb 1024) 'a kilobyte rounds to 0.00, it does not error'
        Assert-Eq '-1.00 GB' (Format-Gb -1073741824) 'a negative delta (a VHDX that grew) still formats'
        # 2 TB: no grouping separator, which a log parser could misread as a
        # decimal comma; and no scientific notation or overflow.
        Assert-Eq '2048.00 GB' (Format-Gb 2199023255552) 'multi-terabyte values stay parseable'
    } finally {
        [Threading.Thread]::CurrentThread.CurrentCulture = $prev
    }
}

function Test-FormatGbRejectsNonNumeric {
    $err = $null
    try { Format-Gb 'not-a-number' | Out-Null } catch { $err = "$_" }
    Assert-NotNull $err 'a non-numeric byte count is rejected rather than silently formatted'
}

# Format-Mb: the same pin, at the scale of a crash dump.
function Test-FormatMbIsCultureInvariant {
    $prev = [Threading.Thread]::CurrentThread.CurrentCulture
    [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('uk-UA')
    try {
        Assert-Eq '0.0 MB' (Format-Mb 0) 'zero'
        Assert-Eq '1.5 MB' (Format-Mb 1572864) 'one and a half, with a decimal point'
        Assert-Eq '784.0 MB' (Format-Mb 822083584) 'a realistic dump size'
        Assert-Eq '20480.0 MB' (Format-Mb 21474836480) 'no grouping separator'
    } finally {
        [Threading.Thread]::CurrentThread.CurrentCulture = $prev
    }
}

# --- Invoke-Wsl --------------------------------------------------------------
function Test-InvokeWslPassesArgumentsAndSucceedsOnExitZero {
    $script:Seen = $null
    $script:Logged = @()
    function wsl.exe {
        [CmdletBinding()] param([Parameter(ValueFromRemainingArguments = $true)]$WslArgs)
        $script:Seen = @($WslArgs) -join ' '
        $global:LASTEXITCODE = 0
        'listing output'
    }
    function Write-MaintLog { param($Level = 'info', $Message) $script:Logged += "[$Level] $Message" }

    $err = $null
    $out = $null
    try { $out = Invoke-Wsl @('-d', 'Ubuntu', '--', 'echo', 'hi') } catch { $err = "$_" }

    Assert-Null $err 'exit 0 does not throw'
    Assert-Eq '-d Ubuntu -- echo hi' $script:Seen 'arguments reach wsl.exe verbatim and in order'
    Assert-Eq 'listing output' $out 'wsl output is passed through to the caller'
    Assert-Contains ($script:Logged -join "`n") '[info] wsl -d Ubuntu -- echo hi' 'the command is logged before it runs'
}

# The guard is `-ne 0`, so a negative 0xC0000005-style code takes the identical
# branch as exit 3; it used to have its own test, which re-entered the same two
# lines. The value below is negative to keep that input represented here.
function Test-InvokeWslThrowsOnNonZeroExit {
    function wsl.exe {
        [CmdletBinding()] param([Parameter(ValueFromRemainingArguments = $true)]$WslArgs)
        $global:LASTEXITCODE = -1073741819
    }
    function Write-MaintLog { param($Level = 'info', $Message) }

    $err = $null
    try { Invoke-Wsl @('--export', 'Ubuntu', 'x.tar') } catch { $err = "$_" }

    Assert-NotNull $err 'a non-zero wsl exit is fatal'
    Assert-Contains $err 'wsl exited -1073741819' 'the raw exit code is in the message'
    Assert-Contains $err 'wsl --export Ubuntu x.tar' 'the failing command is in the message'
}

# --- Write-MaintLog ----------------------------------------------------------
function Test-WriteMaintLogFormatAndFile {
    function Write-Host { param([Parameter(ValueFromRemainingArguments = $true)]$Rest) }

    Write-MaintLog -Message 'plain message'
    Write-MaintLog -Level warn -Message 'careful'
    Write-MaintLog -Level err -Message 'broken'

    $logFile = Join-Path (Join-Path $script:LogSandbox 'logs') ("maint-" + (Get-Date -Format 'yyyy-MM-dd') + ".log")
    Assert-FileExists $logFile 'the log file is created under logs\ with a dated name'
    $text = (Get-Content -LiteralPath $logFile) -join "`n"
    Assert-Contains $text '[info] plain message' 'default level is info'
    Assert-Contains $text '[warn] careful' 'warn level is tagged'
    Assert-Contains $text '[err] broken' 'err level is tagged'
    Assert-Match ((Get-Content -LiteralPath $logFile)[0]) '^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]\[info\] ' 'each line is timestamped'
}

function Test-WriteMaintLogRejectsUnknownLevel {
    function Write-Host { param([Parameter(ValueFromRemainingArguments = $true)]$Rest) }
    $err = $null
    try { Write-MaintLog -Level 'catastrophe' -Message 'x' } catch { $err = "$_" }
    Assert-NotNull $err 'an unknown log level is rejected by the ValidateSet'
}

# --- Get-DistroVhdxPath -----------------------------------------------------
# LOGIC-ONLY COVERAGE for the registry half: Get-LxssDistroEntries (the only
# thing that reads HKCU:\...\Lxss) is shadowed with fake entries, so the real
# registry is never read. The disks are dummies under a temp dir, and
# LOCALAPPDATA points there so the Packages fallback sees only those.
function Invoke-WithFakeLocalAppData {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][scriptblock]$Script)
    $old = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = $Root
    try { & $Script } finally { $env:LOCALAPPDATA = $old }
}

function New-FakeDisk {
    param([Parameter(Mandatory)][string]$Dir, [string]$Name = 'ext4.vhdx')
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    $f = Join-Path $Dir $Name
    Set-Content -LiteralPath $f -Value 'x'
    $f
}

# `wsl --import` puts the disk wherever the operator said, nowhere near
# Packages. Before the registry lookup this distro had no disk as far as
# compact and defender could tell.
function Test-GetDistroVhdxPathFindsImportedDistroViaRegistry {
    $root = New-TestDir 'vhdx-lookup'
    try {
        $disk = New-FakeDisk (Join-Path $root 'wsl\MyDistro')
        function Get-LxssDistroEntries {
            @([pscustomobject]@{ DistributionName = 'Other'; BasePath = (Join-Path $root 'nowhere') },
              [pscustomobject]@{ DistributionName = 'MyDistro'; BasePath = (Join-Path $root 'wsl\MyDistro') })
        }
        $found = Invoke-WithFakeLocalAppData $root { Get-DistroVhdxPath -Distro 'mydistro' }
        Assert-Eq $disk $found 'an imported distro is found by its registry BasePath, name matched case-insensitively'
    } finally { Remove-TestDir $root }
}

# docker-desktop's BasePath carries the \\?\ long-path prefix, and a
# VhdFileName value, when present, names the disk file.
function Test-GetDistroVhdxPathStripsLongPathPrefixAndHonoursVhdFileName {
    $root = New-TestDir 'vhdx-lookup'
    try {
        $base = Join-Path $root 'Docker\wsl\main'
        $disk = New-FakeDisk $base 'custom.vhdx'
        function Get-LxssDistroEntries {
            @([pscustomobject]@{ DistributionName = 'docker-desktop'; BasePath = ('\\?\' + $base); VhdFileName = 'custom.vhdx' })
        }
        $found = Invoke-WithFakeLocalAppData $root { Get-DistroVhdxPath -Distro 'docker-desktop' }
        Assert-Eq $disk $found 'the \\?\ prefix is stripped and VhdFileName is used'
    } finally { Remove-TestDir $root }
}

# The registry is authoritative: a Packages folder that merely contains the
# distro name does not override it, and does not make the match ambiguous.
function Test-GetDistroVhdxPathPrefersRegistryOverPackagesGlob {
    $root = New-TestDir 'vhdx-lookup'
    try {
        $real = New-FakeDisk (Join-Path $root 'Packages\CanonicalGroupLimited.Ubuntu_x\LocalState')
        New-FakeDisk (Join-Path $root 'Packages\CanonicalGroupLimited.Ubuntu22.04LTS_x\LocalState') | Out-Null
        function Get-LxssDistroEntries {
            @([pscustomobject]@{ DistributionName = 'Ubuntu'; BasePath = (Split-Path -Parent $real) })
        }
        $found = Invoke-WithFakeLocalAppData $root { Get-DistroVhdxPath -Distro 'Ubuntu' }
        Assert-Eq $real $found 'the registered disk wins, the second Packages match is not a conflict'
    } finally { Remove-TestDir $root }
}

# A registered distro whose disk is not there is reported as not found; the
# glob is not consulted, since it could only find some other distro's disk.
function Test-GetDistroVhdxPathRegisteredButMissingIsNull {
    $root = New-TestDir 'vhdx-lookup'
    try {
        New-FakeDisk (Join-Path $root 'Packages\CanonicalGroupLimited.Ubuntu_x\LocalState') | Out-Null
        function Get-LxssDistroEntries {
            @([pscustomobject]@{ DistributionName = 'Ubuntu'; BasePath = (Join-Path $root 'gone') })
        }
        $found = Invoke-WithFakeLocalAppData $root { Get-DistroVhdxPath -Distro 'Ubuntu' }
        Assert-Null $found 'a registered distro without its disk is not found'
    } finally { Remove-TestDir $root }
}

# A registered distro on a drive that is not there (an unplugged USB disk a
# `wsl --import` went to) is not found either. Join-Path throws on a missing
# drive in Windows PowerShell 5.1, and under Stop that would abort compact
# instead of letting it warn and compact the disks it did find.
function Test-GetDistroVhdxPathMissingDriveIsNull {
    $letter = [char[]](90..68) | Where-Object { -not (Test-Path -LiteralPath "${_}:\") } | Select-Object -First 1
    if (-not $letter) { Write-Host '  skip: no free drive letter'; return }
    function Get-LxssDistroEntries {
        @([pscustomobject]@{ DistributionName = 'Ubuntu'; BasePath = "${letter}:\nope" })
    }
    $ErrorActionPreference = 'Stop'
    $found = Get-DistroVhdxPath -Distro 'Ubuntu'
    Assert-Null $found 'a registered distro on a missing drive is not found, and does not throw'
}

# No registry entry for the name: the Packages glob still finds it, and still
# refuses to guess between two matches.
function Test-GetDistroVhdxPathFallsBackToPackagesGlob {
    $root = New-TestDir 'vhdx-lookup'
    try {
        $disk = New-FakeDisk (Join-Path $root 'Packages\TheDebianProject.DebianGNULinux_x\LocalState')
        function Get-LxssDistroEntries {
            @([pscustomobject]@{ DistributionName = 'Ubuntu'; BasePath = (Join-Path $root 'elsewhere') })
        }
        $found = Invoke-WithFakeLocalAppData $root { Get-DistroVhdxPath -Distro 'Debian' }
        Assert-Eq $disk $found 'with no registry match the Packages glob is used'

        function Get-LxssDistroEntries { @() }
        $none = Invoke-WithFakeLocalAppData $root { Get-DistroVhdxPath -Distro 'Arch' }
        Assert-Null $none 'nothing anywhere is $null'

        New-FakeDisk (Join-Path $root 'Packages\TheDebianProject.Debian2_x\LocalState') | Out-Null
        $err = $null
        try { Invoke-WithFakeLocalAppData $root { Get-DistroVhdxPath -Distro 'Debian' } | Out-Null } catch { $err = "$_" }
        Assert-Contains "$err" 'More than one Debian disk found' 'two glob matches still throw'
    } finally { Remove-TestDir $root }
}

# A repo cloned under a bracketed path (D:\work [x]\wsl-maint) must still log:
# read as wildcards the logs dir and file match nothing, and every verb broke.
function Test-WriteMaintLogUnderBracketedRepoPath {
    function Write-Host { param([Parameter(ValueFromRemainingArguments = $true)]$Rest) }
    $root = New-TestDir 'common-brackets'
    $saved = $script:MaintRepoRoot
    try {
        $script:MaintRepoRoot = [IO.Directory]::CreateDirectory((Join-Path $root 'repo [x]')).FullName
        $err = $null
        try {
            Write-MaintLog -Message 'first line'
            Write-MaintLog -Message 'second line'
        } catch { $err = "$_" }
        Assert-Null $err 'logging under a bracketed repo path does not throw'
        $logFile = Join-Path (Join-Path $script:MaintRepoRoot 'logs') ("maint-" + (Get-Date -Format 'yyyy-MM-dd') + ".log")
        Assert-True (Test-Path -LiteralPath $logFile -PathType Leaf) 'the log file is created under the literal bracketed path'
        $lines = @(if (Test-Path -LiteralPath $logFile) { Get-Content -LiteralPath $logFile })
        Assert-Eq 2 $lines.Count 'both lines were appended to the one file'
    } finally { $script:MaintRepoRoot = $saved; Remove-TestDir $root }
}

# LOCALAPPDATA under a bracketed profile dir: the Packages fallback must look
# in the literal dir, not treat [x] as a character class that matches nothing.
function Test-GetDistroVhdxPathPackagesGlobUnderBracketedLocalAppData {
    $root = New-TestDir 'vhdx-brackets'
    try {
        $lad = [IO.Directory]::CreateDirectory((Join-Path $root 'lad [x]')).FullName
        $dir = [IO.Directory]::CreateDirectory((Join-Path $lad 'Packages\TheDebianProject.DebianGNULinux_x\LocalState')).FullName
        $disk = Join-Path $dir 'ext4.vhdx'
        Set-Content -LiteralPath $disk -Value 'x'
        function Get-LxssDistroEntries { @() }
        $found = Invoke-WithFakeLocalAppData $lad { Get-DistroVhdxPath -Distro 'Debian' }
        Assert-Eq $disk $found 'the Packages disk under a bracketed LOCALAPPDATA is found'
    } finally { Remove-TestDir $root }
}

try {
    Test-GetMaintConfigDefaults
    Test-GetMaintConfigReadsEachKey
    Test-GetMaintConfigValueSemantics
    Test-GetMaintConfigReadsUtf8WithAndWithoutBom
    Test-GetMaintConfigRejectsBrokenLinesWithFileAndLine
    Test-GetMaintConfigRejectsBadValues
    Test-GetMaintConfigOverrideToMissingFileIsAnError
    Test-GetMaintWslArgsRefusesAnUnreachableOverride
    Test-GetFreeSpaceGbAcceptsLetterOrQualifier
    Test-GetFreeSpaceGbRoundsToTwoDecimals
    Test-FormatGbIsCultureInvariant
    Test-FormatGbRejectsNonNumeric
Test-FormatMbIsCultureInvariant
    Test-InvokeWslPassesArgumentsAndSucceedsOnExitZero
    Test-InvokeWslThrowsOnNonZeroExit
    Test-WriteMaintLogFormatAndFile
    Test-WriteMaintLogRejectsUnknownLevel
    Test-GetDistroVhdxPathFindsImportedDistroViaRegistry
    Test-GetDistroVhdxPathStripsLongPathPrefixAndHonoursVhdFileName
    Test-GetDistroVhdxPathPrefersRegistryOverPackagesGlob
    Test-GetDistroVhdxPathRegisteredButMissingIsNull
    Test-GetDistroVhdxPathMissingDriveIsNull
    Test-GetDistroVhdxPathFallsBackToPackagesGlob
    Test-WriteMaintLogUnderBracketedRepoPath
    Test-GetDistroVhdxPathPackagesGlobUnderBracketedLocalAppData
} finally {
    Remove-TestDir $script:LogSandbox
}

Write-AssertSummary
