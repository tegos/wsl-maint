# A REAL native stand-in for wsl.exe. Dot-sourced by
# test files; not a Test-*.ps1, so Run.ps1 does not pick it up on its own.
#
# Why this exists: a shadowed `function wsl.exe` is not a native process, so
# its output never goes through PowerShell 5.1's native stderr wrapping (see
# the header of Run.ps1). The exe built here IS a native process, so a test
# that runs code against it under $ErrorActionPreference = 'Stop' sees the
# real NativeCommandError hazard. It is compiled at test time with the
# in-box Add-Type, so there is no binary in the repo and no new dependency.
#
# The exe is scripted through two environment variables, read on every run:
#   FAKE_EXE_SCRIPT  path to a file of lines, replayed in order:
#                      out:<text>   -> one stdout line
#                      err:<text>   -> one stderr line
#                      exit:<n>     -> the process exit code (default 0)
#   FAKE_EXE_MARKER  path of a file the exe appends its argv to, one line per
#                    run. A test asserts on it to prove the fake ran, not the
#                    real binary further down PATH.
#
# IMPORTANT for callers: do not define a `function wsl.exe` in the scope that
# runs against the fake. A Function outranks an Application in command
# resolution and would hide the exe, silently turning a real-process test
# back into a shadowed one. Invoke-WithFakeExe refuses to run the script
# block unless wsl.exe resolves into the fake's dir, so that mistake (or a
# PATH that still picks the real wsl.exe) throws instead of passing.

$script:FakeExeSource = @'
using System;
using System.IO;
public static class FakeExe {
    public static int Main(string[] args) {
        string marker = Environment.GetEnvironmentVariable("FAKE_EXE_MARKER");
        if (!String.IsNullOrEmpty(marker)) {
            File.AppendAllText(marker, String.Join(" ", args) + Environment.NewLine);
        }
        int code = 0;
        string script = Environment.GetEnvironmentVariable("FAKE_EXE_SCRIPT");
        if (String.IsNullOrEmpty(script) || !File.Exists(script)) { return code; }
        foreach (string line in File.ReadAllLines(script)) {
            if (line.StartsWith("out:")) { Console.Out.WriteLine(line.Substring(4)); Console.Out.Flush(); }
            else if (line.StartsWith("err:")) { Console.Error.WriteLine(line.Substring(4)); Console.Error.Flush(); }
            else if (line.StartsWith("exit:")) { code = Int32.Parse(line.Substring(5)); }
        }
        return code;
    }
}
'@

# Compiles the fake into a fresh temp dir as wsl.exe and returns the dir.
# Throws if the in-box compiler is unavailable, after removing the dir; callers
# turn that into a skip, not a failure.
function New-FakeNativeExe {
    $dir = New-TestDir 'fake-exe'
    try {
        Add-Type -TypeDefinition $script:FakeExeSource -OutputAssembly (Join-Path $dir 'wsl.exe') -OutputType ConsoleApplication
    } catch {
        Remove-TestDir $dir
        throw
    }
    $dir
}

function Get-FakeExeMarkerPath {
    param([Parameter(Mandatory)][string]$Dir)
    Join-Path $Dir 'marker.txt'
}

# Runs $Script with $Dir first on PATH and the fake scripted by $Lines.
# Throws a TEST GUARD before running $Script if wsl.exe does not resolve into
# $Dir. PATH and both env vars are restored in finally, so a throwing
# assertion cannot leak the fake into the next test. Returns whatever $Script
# returns.
function Invoke-WithFakeExe {
    param(
        [Parameter(Mandatory)][string]$Dir,
        [string[]]$Lines = @(),
        [Parameter(Mandatory)][scriptblock]$Script
    )
    $prevPath = $env:PATH
    $prevScript = $env:FAKE_EXE_SCRIPT
    $prevMarker = $env:FAKE_EXE_MARKER
    $scriptFile = Join-Path $Dir 'script.txt'
    $markerFile = Get-FakeExeMarkerPath $Dir
    try {
        Set-Content -LiteralPath $scriptFile -Value $Lines
        if (Test-Path -LiteralPath $markerFile) { Microsoft.PowerShell.Management\Remove-Item -LiteralPath $markerFile -Force }
        $env:FAKE_EXE_SCRIPT = $scriptFile
        $env:FAKE_EXE_MARKER = $markerFile
        $env:PATH = "$Dir;$prevPath"
        $source = (Get-Command wsl.exe).Source
        if (-not "$source".StartsWith($Dir, [StringComparison]::OrdinalIgnoreCase)) {
            throw "TEST GUARD: wsl.exe resolved to '$source', not the fake in $Dir; refusing to run"
        }
        & $Script
    } finally {
        $env:PATH = $prevPath
        $env:FAKE_EXE_SCRIPT = $prevScript
        $env:FAKE_EXE_MARKER = $prevMarker
    }
}

# The argv lines the fake recorded during the last Invoke-WithFakeExe, or an
# empty string if it never ran.
function Get-FakeExeCalls {
    param([Parameter(Mandatory)][string]$Dir)
    $markerFile = Get-FakeExeMarkerPath $Dir
    if (Test-Path -LiteralPath $markerFile) { (Get-Content -LiteralPath $markerFile) -join "`n" } else { '' }
}
