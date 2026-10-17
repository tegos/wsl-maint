# Minimal assertion helpers for the Windows-side suite. No Pester, no external
# deps -- the same shape as tests/assert.sh, so both suites read alike.
#
# Diagnostics go through [Console]::Error / [Console]::Out on purpose, NOT
# through Write-Host or Write-Output: test files routinely shadow Write-Host
# (to silence a function under test) and pipe their own output around, and an
# assertion that reported through a shadowed cmdlet could be swallowed by the
# very mock it is meant to be judging.

$script:AssertPass = 0
$script:AssertFail = 0

function script:Add-AssertPass {
    $script:AssertPass = $script:AssertPass + 1
}

function script:Add-AssertFail {
    param([string]$Text)
    $script:AssertFail = $script:AssertFail + 1
    [Console]::Error.WriteLine("  FAIL $Text")
}

function Assert-Eq {
    param($Expected, $Actual, [string]$Message = '')
    if ([string]$Expected -eq [string]$Actual) {
        Add-AssertPass
    } else {
        Add-AssertFail "${Message}: expected [$Expected] got [$Actual]"
    }
}

function Assert-True {
    param($Value, [string]$Message = '')
    if ($Value) { Add-AssertPass } else { Add-AssertFail "${Message}: expected true, got [$Value]" }
}

function Assert-False {
    param($Value, [string]$Message = '')
    if (-not $Value) { Add-AssertPass } else { Add-AssertFail "${Message}: expected false, got [$Value]" }
}

function Assert-Null {
    param($Value, [string]$Message = '')
    if ($null -eq $Value) { Add-AssertPass } else { Add-AssertFail "${Message}: expected null, got [$Value]" }
}

function Assert-NotNull {
    param($Value, [string]$Message = '')
    if ($null -ne $Value) { Add-AssertPass } else { Add-AssertFail "${Message}: expected non-null" }
}

# Literal substring, not -like: needles here routinely contain [brackets]
# (log level tags), which -like would read as a wildcard character class.
function Assert-Contains {
    param([string]$Haystack, [string]$Needle, [string]$Message = '')
    if ($Haystack.Contains($Needle)) {
        Add-AssertPass
    } else {
        Add-AssertFail "${Message}: [$Haystack] does not contain [$Needle]"
    }
}

function Assert-NotContains {
    param([string]$Haystack, [string]$Needle, [string]$Message = '')
    if ($Haystack.Contains($Needle)) {
        Add-AssertFail "${Message}: [$Haystack] unexpectedly contains [$Needle]"
    } else {
        Add-AssertPass
    }
}

function Assert-Match {
    param([string]$Value, [string]$Pattern, [string]$Message = '')
    if ($Value -match $Pattern) {
        Add-AssertPass
    } else {
        Add-AssertFail "${Message}: [$Value] does not match /$Pattern/"
    }
}

function Assert-FileExists {
    param([string]$Path, [string]$Message = '')
    if (Test-Path -LiteralPath $Path) { Add-AssertPass } else { Add-AssertFail "${Message}: missing file [$Path]" }
}

function Assert-FileMissing {
    param([string]$Path, [string]$Message = '')
    if (Test-Path -LiteralPath $Path) { Add-AssertFail "${Message}: file still exists [$Path]" } else { Add-AssertPass }
}

# Runner contract: one machine-readable line per test file, summed by Run.ps1
# exactly as tests/run.sh sums the bash suite's RESULT lines.
function Write-AssertSummary {
    [Console]::Out.WriteLine("RESULT $script:AssertPass $script:AssertFail")
}

# Per-test temp sandbox. Every test that touches the filesystem must work
# inside one of these and nowhere else.
function New-TestDir {
    param([string]$Name = 'wsl-maint-test')
    $p = Join-Path ([IO.Path]::GetTempPath()) ("$Name-" + [Guid]::NewGuid().ToString('N').Substring(0, 12))
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    $p
}

function Remove-TestDir {
    param([string]$Path)
    # Belt and braces: only ever recurse-delete something under the temp root.
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -and $full.Length -gt $temp.Length) {
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        [Console]::Error.WriteLine("  REFUSED to remove non-temp path [$Path]")
    }
}
