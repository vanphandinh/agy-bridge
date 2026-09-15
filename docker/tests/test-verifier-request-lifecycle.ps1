[CmdletBinding()]
param(
  [string]$VerifierPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($VerifierPath)) {
  $VerifierPath = Join-Path $PSScriptRoot 'verify-all.ps1'
}

function Fail {
  param([Parameter(Mandatory = $true)][string]$Message)
  throw "FAIL: $Message"
}

$resolvedVerifier = (Resolve-Path -LiteralPath $VerifierPath).Path
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
  $resolvedVerifier,
  [ref]$tokens,
  [ref]$parseErrors
)
if (@($parseErrors).Count -ne 0) {
  Fail "verifier does not parse: $($parseErrors[0].Message)"
}

# Every live chat-completion transport gets a correlation id, including paths
# that are expected to reject before spawning agy. If the expected pre-spawn
# denial regresses or times out, the verifier still needs an id to look for
# lifecycle evidence rather than falling back to an uncorrelated assumption.
$completionHttpCalls = @($ast.FindAll({
  param($candidate)
  $candidate -is [System.Management.Automation.Language.CommandAst] -and
    $candidate.GetCommandName() -eq 'Invoke-Http' -and
    $candidate.Extent.Text -match '/v1/chat/completions'
}, $true))
if ($completionHttpCalls.Count -eq 0) {
  Fail 'verifier has no chat-completion HTTP calls to audit'
}
foreach ($call in $completionHttpCalls) {
  if ($call.Extent.Text -notmatch '(?i)-RequestId\b') {
    Fail "chat-completion HTTP call at line $($call.Extent.StartLineNumber) is missing request correlation"
  }
}

function Import-VerifierFunction {
  param([Parameter(Mandatory = $true)][string]$Name)
  $node = $ast.Find({
    param($candidate)
    $candidate -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
      $candidate.Name -eq $Name
  }, $true)
  if ($null -eq $node) {
    Fail "verifier is missing $Name"
  }
  $definition = $node.Extent.Text -replace (
    '^function\s+' + [regex]::Escape($Name)
  ), "function global:$Name"
  Invoke-Expression $definition
}

Import-VerifierFunction -Name 'Wait-RequestTerminalEvidence'
Import-VerifierFunction -Name 'Invoke-CompletionResponse'
Import-VerifierFunction -Name 'Assert-WorkspaceMutationEvidence'
Import-VerifierFunction -Name 'Stop-WorkspaceVerifierDeployment'
Import-VerifierFunction -Name 'Remove-WorkspaceChildEnvObserverResult'
Import-VerifierFunction -Name 'Remove-RwReservedShadowProbeArtifacts'

$script:CleanupBlocked = $false
$script:CleanupBlockReason = $null
$script:ApiBase = 'http://127.0.0.1:1'
$script:EvidencePoll = 0

# A cancellation can reach the bridge before the child reaches terminal state.
# The verifier must keep waiting rather than treating cancellation request as
# cancellation completion.
function Get-RequestUsageEvidence {
  param(
    [Parameter(Mandatory = $true)][string]$RequestId,
    [Parameter(Mandatory = $true)][ValidateSet('default', 'ro', 'rw')][string]$DeploymentMode
  )
  $script:EvidencePoll++
  if ($script:EvidencePoll -lt 3) {
    return [pscustomobject]@{
      Found = $true
      RequestId = $RequestId
      ChildStarted = $true
      ChildTerminal = $false
      FailureKind = 'aborted'
    }
  }
  return [pscustomobject]@{
    Found = $true
    RequestId = $RequestId
    ChildStarted = $true
    ChildTerminal = $true
    FailureKind = 'aborted'
    ChildExitCode = 143
    ChildSuccess = $false
    ChildSignal = 'SIGTERM'
  }
}

$terminal = Wait-RequestTerminalEvidence `
  -RequestId 'verify-delayed-terminal' `
  -DeploymentMode ro `
  -TimeoutMs 500 `
  -PollIntervalMs 1
if (-not $terminal.ChildTerminal) {
  Fail 'delayed cancellation was accepted before child terminal state'
}
if ($script:EvidencePoll -lt 3) {
  Fail 'terminal wait did not poll past the non-terminal child state'
}
if ($script:CleanupBlocked) {
  Fail 'terminal evidence unexpectedly blocked cleanup'
}

# Every completion that can spawn agy must carry a correlation id and resolve
# actual terminal evidence independently from the HTTP/protocol result.
$script:CapturedRequestId = $null
function Invoke-Http {
  param(
    [string]$Method,
    [string]$Uri,
    [hashtable]$Headers,
    [string]$Body,
    [string]$RequestId
  )
  $script:CapturedRequestId = $RequestId
  return [pscustomobject]@{
    Outcome = 'completed'
    StatusCode = 200
    Content = '{"choices":[{"message":{"content":"OK"}}]}'
    RequestId = $RequestId
    TerminalState = 'unknown'
  }
}
function Get-RequestUsageEvidence {
  param(
    [Parameter(Mandatory = $true)][string]$RequestId,
    [Parameter(Mandatory = $true)][ValidateSet('default', 'ro', 'rw')][string]$DeploymentMode
  )
  return [pscustomobject]@{
    Found = $true
    RequestId = $RequestId
    ChildStarted = $true
    ChildTerminal = $true
    FailureKind = $null
    ChildExitCode = 7
    ChildSuccess = $false
    ChildSignal = $null
  }
}

$tracked = Invoke-CompletionResponse `
  -WireModel 'auto-ro-gemini-test' `
  -Token 'synthetic-token-never-logged' `
  -Prompt 'synthetic harmless prompt' `
  -DeploymentMode ro
if ([string]::IsNullOrWhiteSpace($script:CapturedRequestId)) {
  Fail 'completion did not generate a request correlation id'
}
if ($script:CapturedRequestId -notmatch '^verify-[a-f0-9]{32}$') {
  Fail "completion generated an unexpected request id format: $($script:CapturedRequestId)"
}
if ($tracked.TerminalState -ne 'child_terminal') {
  Fail 'completed HTTP response was accepted without correlated child terminal evidence'
}
if ($tracked.TerminalEvidence.ChildExitCode -ne 7 -or $tracked.TerminalEvidence.ChildSuccess) {
  Fail 'completion inferred child success from protocol/HTTP success instead of terminal evidence'
}

$timeoutResponse = [pscustomobject]@{
  Outcome = 'timeout'
  DeadlineSec = 180
  RequestId = 'verify-timeout-fingerprint'
  TerminalState = 'child_terminal'
  StatusCode = $null
}
$timeoutRejected = $false
try {
  Assert-WorkspaceMutationEvidence `
    -Response $timeoutResponse `
    -BeforeFingerprint 'UNCHANGED' `
    -AfterFingerprint 'UNCHANGED'
}
catch {
  if ($_.Exception.Message -like '*fingerprint unchanged but immutability evidence remains inconclusive*') {
    $timeoutRejected = $true
  }
  else { throw }
}
if (-not $timeoutRejected) {
  Fail 'unchanged fingerprint converted a timed-out mutation probe into PASS'
}

$completedResponse = [pscustomobject]@{
  Outcome = 'completed'
  DeadlineSec = 180
  RequestId = 'verify-completed-fingerprint'
  TerminalState = 'child_terminal'
  StatusCode = 200
}
Assert-WorkspaceMutationEvidence `
  -Response $completedResponse `
  -BeforeFingerprint 'UNCHANGED' `
  -AfterFingerprint 'UNCHANGED'

$mutationRejected = $false
try {
  Assert-WorkspaceMutationEvidence `
    -Response $completedResponse `
    -BeforeFingerprint 'BEFORE' `
    -AfterFingerprint 'AFTER'
}
catch {
  if ($_.Exception.Message -like '*host workspace fingerprint changed*') {
    $mutationRejected = $true
  }
  else { throw }
}
if (-not $mutationRejected) {
  Fail 'changed fingerprint was not rejected as a workspace mutation'
}

# If terminal state remains unknowable, the verifier must fail closed and mark
# cleanup unsafe. This prevents finally from tearing down a deployment or
# deleting a fixture that an in-flight child could still be using.
function Get-RequestUsageEvidence {
  param(
    [Parameter(Mandatory = $true)][string]$RequestId,
    [Parameter(Mandatory = $true)][ValidateSet('default', 'ro', 'rw')][string]$DeploymentMode
  )
  return [pscustomobject]@{
    Found = $false
    RequestId = $RequestId
    ChildTerminal = $false
  }
}

$unknownRejected = $false
try {
  Wait-RequestTerminalEvidence `
    -RequestId 'verify-terminal-unknown' `
    -DeploymentMode ro `
    -TimeoutMs 30 `
    -PollIntervalMs 1 | Out-Null
}
catch {
  if ($_.Exception.Message -like '*terminal state remains unknown*') {
    $unknownRejected = $true
  }
  else {
    throw
  }
}
if (-not $unknownRejected) {
  Fail 'unknown terminal state did not stop the verifier'
}
if (-not $script:CleanupBlocked) {
  Fail 'unknown terminal state did not block cleanup'
}

$script:WorkspaceOverrideFile = 'synthetic-override.json'
$script:WorkspaceFixtureRoot = 'synthetic-fixture'
$script:WorkspacePreviousHostPath = $null
$script:CleanupAttempted = $false
function Test-Path { param([string]$LiteralPath) return $true }
function Invoke-WorkspaceDockerCapture {
  $script:CleanupAttempted = $true
  throw 'cleanup must not run while terminal state is unknown'
}
function Remove-Item {
  $script:CleanupAttempted = $true
  throw 'fixture cleanup must not run while terminal state is unknown'
}

Stop-WorkspaceVerifierDeployment
if ($script:CleanupAttempted) {
  Fail 'cleanup ran despite unknown request/child terminal state'
}
if ($script:WorkspaceOverrideFile -ne 'synthetic-override.json') {
  Fail 'blocked cleanup discarded workspace deployment identity'
}
if ($script:WorkspaceFixtureRoot -ne 'synthetic-fixture') {
  Fail 'blocked cleanup discarded workspace fixture identity'
}

# CleanupBlocking is an evidence-lifecycle invariant, not only a deployment
# teardown invariant. Local finally blocks must also preserve observer files
# and workspace artifacts while a request/child may still be running.
$script:CleanupAttempted = $false
function Invoke-WorkspaceModeDockerCapture {
  $script:CleanupAttempted = $true
  throw 'observer cleanup must not run while terminal state is unknown'
}
Remove-WorkspaceChildEnvObserverResult `
  -DeploymentMode ro `
  -ResultPath '/tmp/synthetic-observer-result'
if ($script:CleanupAttempted) {
  Fail 'observer evidence was removed despite unknown request/child terminal state'
}

$script:CleanupAttempted = $false
function Invoke-WorkspaceRwDockerCapture {
  $script:CleanupAttempted = $true
  throw 'reserved-shadow cleanup must not run while terminal state is unknown'
}
Remove-RwReservedShadowProbeArtifacts `
  -ReservedContainerPath '/workspace/.agents/agents/agy-bridge-worker-rw-v1/agent.md' `
  -SentinelHostPath 'C:\synthetic\request-after-shadow-must-not-run.txt'
if ($script:CleanupAttempted) {
  Fail 'reserved-shadow evidence was removed despite unknown request/child terminal state'
}

Write-Host 'PASS: verifier waits for terminal evidence and blocks cleanup when terminal state is unknown'
