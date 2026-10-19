@echo off
setlocal EnableExtensions

set "MAINT_PS1=%~dp0maint.ps1"
set "MAINT_ARGS=%*"

rem Detect -Unattended (also its unambiguous PowerShell abbreviations: -U, -Una...)
rem so scheduled runs never stop on "pause". SHIFT does not affect %*, and the
rem full argument tail was captured into MAINT_ARGS above anyway.
set "MAINT_UNATTENDED="
set "MAINT_CHILD_PAUSES="
:maint_scan
if "%~1"=="" goto maint_scanned
set "MAINT_ARG=%~1"
if /i "%MAINT_ARG:~0,2%"=="-U" set "MAINT_UNATTENDED=1"
shift
goto maint_scan
:maint_scanned

net session >nul 2>&1
if %errorlevel% equ 0 goto maint_run

rem Not elevated: relaunch maint.ps1 under UAC. The argument tail is handed to
rem PowerShell through the MAINT_ARGS environment variable and appended as ONE
rem array element; Start-Process joins -ArgumentList with plain spaces and adds
rem no quoting, so the child's command line is a byte-for-byte reconstruction of
rem what the user typed (quoted arguments keep their quotes). Splicing %* into a
rem comma-joined literal instead binds stray switches onto Start-Process itself
rem and leaves a dangling comma when there are no arguments.
rem -Wait -PassThru (never -NoExit, which would block forever) propagates the
rem elevated child's exit code back out of this script.
rem The child runs in a NEW window that closes when it exits, so unless
rem -Unattended it gets the internal -PauseAtEnd (before the user's arguments)
rem and waits for a key itself, [FAILED] line included; this window then skips
rem its own pause on success, so a clean run asks for one key. If the child never
rem starts (UAC declined), the reason prints here and the failure pause below
rem keeps it on screen.
rem MAINT_UNATTENDED reaches
rem this non-elevated powershell by normal inheritance; the elevated child
rem would not see it (a UAC launch does not inherit the caller's environment),
rem hence a switch on its command line instead. The same goes for a
rem session-scoped WSL_MAINT_CONFIG: forwarded as -MaintConfig cfg:<full path>
rem (resolved here, since the elevated child starts in System32; quoted like the
rem script path, before the user's arguments) or the elevated run would
rem silently read the repo-root maint.conf instead of the one chosen.
if not defined MAINT_UNATTENDED set "MAINT_CHILD_PAUSES=1"
echo Requesting administrative privileges...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference = 'Stop'; $q = [char]34; $a = @('-NoProfile','-ExecutionPolicy','Bypass','-File',($q + $env:MAINT_PS1 + $q)); if ($env:MAINT_CHILD_PAUSES) { $a += '-PauseAtEnd' }; if ($env:WSL_MAINT_CONFIG) { $a += @('-MaintConfig', ($q + 'cfg:' + [IO.Path]::GetFullPath($env:WSL_MAINT_CONFIG) + $q)) }; if ($env:MAINT_ARGS) { $a += $env:MAINT_ARGS }; try { $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $a -Wait -PassThru } catch { Write-Host $_.Exception.Message; exit 1 }; if ($null -eq $p -or $null -eq $p.ExitCode) { exit 1 }; exit $p.ExitCode"
set "MAINT_RC=%errorlevel%"
goto maint_done

:maint_run
powershell -NoProfile -ExecutionPolicy Bypass -File "%MAINT_PS1%" %MAINT_ARGS%
set "MAINT_RC=%errorlevel%"

:maint_done
rem MAINT_RC is captured immediately after each powershell call because the
rem lines below (echo, pause, endlocal) each set their own errorlevel, so
rem %errorlevel% no longer holds powershell's code by the time we exit. The
rem actual bug this fixed was not the echo: it was the missing "exit /b" --
rem a batch script that just runs off its last line returns the errorlevel of
rem whatever ran last (pause, which is always 0), discarding the failure.
rem The comparison below is string-based, not "if errorlevel 1", which
rem would treat any negative exit code as success.
if not "%MAINT_RC%"=="0" echo.
if not "%MAINT_RC%"=="0" echo [FAILED] exit %MAINT_RC% - see logs\ for details
rem A failed run pauses here even after a child pause: a child that dies in
rem param() binding (a switch given a non-boolean value, -DryRun:abc) or before
rem its try exits without pausing, and its window takes the error with it.
if not defined MAINT_UNATTENDED if not defined MAINT_CHILD_PAUSES pause
if not defined MAINT_UNATTENDED if defined MAINT_CHILD_PAUSES if not "%MAINT_RC%"=="0" pause
endlocal & exit /b %MAINT_RC%
