# win\Backup.ps1 -- Confirm-LargeDeletion and Confirm-Unverifiable.
#
# LOGIC-ONLY COVERAGE. wsl.exe and Read-Host are shadowed PowerShell functions,
# so these tests prove the consent decisions (deny by default, when the prompt
# appears at all, which amounts count as small, which route to the fail-safe)
# and NOT how the real `maint clean --dry-run` behaves as a native process --
# in particular NOT the $ErrorActionPreference='Stop' + 2>&1 NativeCommandError
# hazard the function's own comment describes. That hazard is covered by
# Test-BackupConsentNative.ps1 against a real process. See the header of Run.ps1.
#
# Nothing here can reach a real `maint clean`: wsl.exe is shadowed for every
# scenario, and no test touches the filesystem at all.

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'Assert.ps1')
. (Join-Path (Split-Path -Parent (Split-Path -Parent $here)) 'win\Common.ps1')
. (Join-Path (Split-Path -Parent (Split-Path -Parent $here)) 'win\Backup.ps1')

$script:Answers = @()
$script:AnsIdx = 0
$script:ReadHostCalls = 0
$script:Logs = @()

# Runs Confirm-LargeDeletion against a scripted preview. If no -Answers are
# supplied, Read-Host THROWS: that is how "this path must never prompt" is
# proved structurally rather than by counting.
function Invoke-ConsentScenario {
    param(
        [string[]]$Preview = @(),
        [int]$ExitCode = 0,
        [object[]]$Answers = @(),
        [switch]$Unattended
    )
    $script:Answers = $Answers
    $script:AnsIdx = 0
    $script:ReadHostCalls = 0
    $script:Logs = @()

    function Get-MaintConfig { @{ Distro = 'TestDistro'; BackupRoot = 'T:\nowhere'; Keep = 3 } }
    function Write-MaintLog { param($Level = 'info', $Message) $script:Logs += "[$Level] $Message" }
    function Write-Host { param([Parameter(ValueFromRemainingArguments = $true)]$Rest) }
    function Read-Host {
        param([Parameter(ValueFromRemainingArguments = $true)]$Rest)
        $script:ReadHostCalls++
        if ($script:AnsIdx -ge @($script:Answers).Count) { throw 'READ-HOST-REACHED' }
        $v = $script:Answers[$script:AnsIdx]
        $script:AnsIdx++
        $v
    }
    function wsl.exe {
        [CmdletBinding()] param([Parameter(ValueFromRemainingArguments = $true)]$WslArgs)
        $global:LASTEXITCODE = $ExitCode
        $Preview
    }

    $res = $null
    $err = $null
    try { $res = Confirm-LargeDeletion -Unattended:$Unattended } catch { $err = "$_" }
    [pscustomobject]@{
        Result        = $res
        Error         = $err
        ReadHostCalls = $script:ReadHostCalls
        Log           = ($script:Logs -join "`n")
    }
}

function Invoke-UnverifiableScenario {
    param([string]$Reason, [object[]]$Answers = @(), [switch]$Unattended)
    $script:Answers = $Answers
    $script:AnsIdx = 0
    $script:ReadHostCalls = 0
    $script:Logs = @()

    function Write-MaintLog { param($Level = 'info', $Message) $script:Logs += "[$Level] $Message" }
    function Write-Host { param([Parameter(ValueFromRemainingArguments = $true)]$Rest) }
    function Read-Host {
        param([Parameter(ValueFromRemainingArguments = $true)]$Rest)
        $script:ReadHostCalls++
        if ($script:AnsIdx -ge @($script:Answers).Count) { throw 'READ-HOST-REACHED' }
        $v = $script:Answers[$script:AnsIdx]
        $script:AnsIdx++
        $v
    }

    $res = $null
    $err = $null
    try { $res = Confirm-Unverifiable -Reason $Reason -Unattended:$Unattended } catch { $err = "$_" }
    [pscustomobject]@{
        Result        = $res
        Error         = $err
        ReadHostCalls = $script:ReadHostCalls
        Log           = ($script:Logs -join "`n")
    }
}

# --- Consent is default-deny -------------------------------------------------
# Only y/yes (any case, surrounding whitespace ignored) is consent. Everything
# else -- including $null from a closed stdin, an empty line, and "yeah" -- denies.
function Test-ConsentIsDefaultDeny {
    $deny = @(@($null), @(''), @('   '), @('yeah'), @('y y'), @('n'), @('N'), @('no'), @('nope'),
              @('garbage'), @('1'), @('sure'))
    $first = $true
    foreach ($a in $deny) {
        $r = Invoke-ConsentScenario -Preview @('would free: 50G') -Answers $a
        $shown = if ($null -eq $a[0]) { '<null>' } else { "'$($a[0])'" }
        # The per-row fact is the verdict. "was asked at all" and "did not
        # error" are properties of the harness, identical for every row, so
        # they are checked once instead of twelve times.
        Assert-False $r.Result "answer $shown must NOT count as consent"
        if ($first) {
            Assert-Null $r.Error 'the deny path produces no error'
            Assert-Eq 1 $r.ReadHostCalls 'the operator was actually asked'
            $first = $false
        }
    }
}

function Test-ConsentAcceptsOnlyYOrYes {
    foreach ($a in @('y', 'Y', 'yes', 'YES', 'Yes', '  y', "`ty", 'yes ')) {
        $r = Invoke-ConsentScenario -Preview @('would free: 50G') -Answers @($a)
        Assert-True $r.Result "answer '$a' is consent"
    }
}

# --- Unattended never reaches Read-Host --------------------------------------
# Structural: Read-Host throws in these scenarios (no -Answers given), so a
# prompt would surface as an error, not just a count.
function Test-UnattendedAboveThresholdProceedsWithoutPrompting {
    $r = Invoke-ConsentScenario -Preview @('would free: 50G') -Unattended
    Assert-True $r.Result 'unattended proceeds above the threshold'
    Assert-Null $r.Error 'unattended never reached Read-Host'
    Assert-Eq 0 $r.ReadHostCalls 'no prompt was issued'
    Assert-Contains $r.Log 'unattended: proceeding to free 50G' 'unattended logs what it is about to free'
}

function Test-UnattendedUnverifiableAbortsRatherThanGuessing {
    $r = Invoke-ConsentScenario -Preview @('nothing useful here') -Unattended
    Assert-NotNull $r.Error 'unattended with no usable estimate aborts'
    Assert-Contains $r.Error "refusing to guess under -Unattended" 'the abort names the reason'
    Assert-Eq 0 $r.ReadHostCalls 'it did not try to prompt'
    Assert-NotContains "$($r.Result)" 'True' 'it did not return consent'
}

# --- Threshold ---------------------------------------------------------------
function Test-BelowThresholdAutoProceedsWithoutPrompt {
    # No -Answers, so any prompt would throw READ-HOST-REACHED -- which is why
    # ReadHostCalls is not asserted per row: a prompt shows up as Error, and
    # Result could not be true if the scenario had thrown.
    foreach ($amount in @('512M', '900K', '1023', '0', '1023M', '0,5G', '0.9G')) {
        $r = Invoke-ConsentScenario -Preview @("would free: $amount")
        Assert-True $r.Result "'$amount' is below 1 GB and proceeds silently"
        Assert-Null $r.Error "'$amount' issued no prompt"
    }
}

function Test-AtOrAboveThresholdPrompts {
    # 1.0G is NOT below a 1.0 GB threshold: the boundary must prompt.
    foreach ($amount in @('1.0G', '1G', '1,5G', '50G', '999G', '1T', '2T')) {
        $r = Invoke-ConsentScenario -Preview @("would free: $amount") -Answers @('y')
        # ReadHostCalls IS the assertion here -- proceeding without asking is
        # the failure this test exists to catch, so Result alone is not enough.
        Assert-Eq 1 $r.ReadHostCalls "'$amount' asked before proceeding"
        Assert-True $r.Result "'$amount' proceeded after consent"
    }
}

# --- The "B" fail-open bug ---------------------------------------------------
# B is not a numfmt unit. It is wsl/lib/common.sh's fallback when numfmt is
# ABSENT, i.e. a raw unscaled byte count with no upper bound: "53687091200B"
# is 50 GB. Reading a B suffix as "smaller than K, therefore tiny" would skip
# the whole gate silently in exactly the case where it matters most.
function Test-ByteSuffixIsNeverTreatedAsBelowThreshold {
    foreach ($amount in @('53687091200B', '100B', '1B')) {
        $r = Invoke-ConsentScenario -Preview @("would free: $amount") -Unattended
        Assert-NotNull $r.Error "'$amount' must not silently auto-proceed under -Unattended"
        Assert-Contains $r.Error "could not parse 'would free' amount '$amount'" "'$amount' is reported as unparseable"
        Assert-NotContains "$($r.Result)" 'True' "'$amount' returned no consent"
    }
}

function Test-ByteSuffixPromptsWhenInteractive {
    $r = Invoke-ConsentScenario -Preview @('would free: 53687091200B') -Answers @('n')
    Assert-False $r.Result 'a B-suffixed amount is denied by default'
    Assert-Eq 1 $r.ReadHostCalls 'the operator was asked rather than bypassed'
    Assert-Contains $r.Log 'cannot verify how much would be freed' 'the fail-safe path was taken'
}

# --- Failure routes: prompt-or-abort, never silent consent -------------------
function Test-NonZeroPreviewExitIgnoresTheAmountAndRoutesToFailSafe {
    # The preview says "100M" (well under threshold) but exited non-zero, so
    # the amount must not be trusted: unattended aborts.
    $r = Invoke-ConsentScenario -Preview @('would free: 100M') -ExitCode 3 -Unattended
    Assert-NotNull $r.Error 'a failed preview aborts under -Unattended'
    Assert-Contains $r.Error 'clean --dry-run preview exited 3' 'the exit code is reported'

    $r2 = Invoke-ConsentScenario -Preview @('would free: 100M') -ExitCode 3 -Answers @('n')
    Assert-False $r2.Result 'interactively it is denied by default'
    Assert-Eq 1 $r2.ReadHostCalls 'interactively it asks'
    Assert-Contains $r2.Log 'cannot verify how much would be freed' 'the fail-safe path was taken'
}

function Test-MissingWouldFreeLineRoutesToFailSafe {
    $r = Invoke-ConsentScenario -Preview @('cleaning rule foo', 'done') -Unattended
    Assert-NotNull $r.Error 'no estimate means no unattended guess'
    Assert-Contains $r.Error "preview produced no 'would free:' line" 'the reason is named'

    $r2 = Invoke-ConsentScenario -Preview @('cleaning rule foo') -Answers @('y')
    Assert-True $r2.Result 'interactively an explicit yes still proceeds'
    Assert-Eq 1 $r2.ReadHostCalls 'interactively it asks first'
}

function Test-UnparseableAmountsRouteToFailSafe {
    foreach ($amount in @('5P', 'abc', '1.2.3G', '12 G', '-4G', 'G', '1e3G', '1,024,000')) {
        $r = Invoke-ConsentScenario -Preview @("would free: $amount") -Unattended
        Assert-NotNull $r.Error "'$amount' must not read as below threshold"
        Assert-Contains $r.Error 'could not parse' "'$amount' is reported as unparseable"
    }
}

function Test-LastWouldFreeLineWins {
    # The WSL side prints a per-rule preview and a final total; the total is
    # last. Picking an earlier line would under-read the deletion size.
    $r = Invoke-ConsentScenario -Preview @('would free: 100M', 'would free: 50G') -Answers @('y')
    Assert-Eq 1 $r.ReadHostCalls 'the 50G total, not the 100M partial, decided the prompt'
    Assert-True $r.Result 'consent was honoured'
}

# --- Confirm-Unverifiable on its own -----------------------------------------
function Test-ConfirmUnverifiableUnattendedThrows {
    $r = Invoke-UnverifiableScenario -Reason 'preview exploded' -Unattended
    Assert-NotNull $r.Error 'unattended aborts'
    Assert-Contains $r.Error 'preview exploded; refusing to guess under -Unattended.' 'reason is carried into the throw'
    Assert-Eq 0 $r.ReadHostCalls 'it never prompts'
    Assert-Contains $r.Log '[warn] preview exploded; cannot verify how much would be freed' 'it warns to the log first'
}

function Test-ConfirmUnverifiableInteractiveIsDefaultDeny {
    $asked = $false
    foreach ($a in @(@($null), @(''), @('yeah'), @('n'), @('whatever'))) {
        $r = Invoke-UnverifiableScenario -Reason 'no estimate' -Answers $a
        Assert-False $r.Result 'ambiguous input is not consent'
        if (-not $asked) { Assert-Eq 1 $r.ReadHostCalls 'it asked'; $asked = $true }
    }
    $r2 = Invoke-UnverifiableScenario -Reason 'no estimate' -Answers @('y')
    Assert-True $r2.Result 'an explicit y proceeds'
}

Test-ConsentIsDefaultDeny
Test-ConsentAcceptsOnlyYOrYes
Test-UnattendedAboveThresholdProceedsWithoutPrompting
Test-UnattendedUnverifiableAbortsRatherThanGuessing
Test-BelowThresholdAutoProceedsWithoutPrompt
Test-AtOrAboveThresholdPrompts
Test-ByteSuffixIsNeverTreatedAsBelowThreshold
Test-ByteSuffixPromptsWhenInteractive
Test-NonZeroPreviewExitIgnoresTheAmountAndRoutesToFailSafe
Test-MissingWouldFreeLineRoutesToFailSafe
Test-UnparseableAmountsRouteToFailSafe
Test-LastWouldFreeLineWins
Test-ConfirmUnverifiableUnattendedThrows
Test-ConfirmUnverifiableInteractiveIsDefaultDeny

Write-AssertSummary
