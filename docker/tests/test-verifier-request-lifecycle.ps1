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

Import-VerifierFunction -Name 'Test-TerminalEvidenceWithinBudget'
Import-VerifierFunction -Name 'Wait-RequestTerminalEvidence'
Import-VerifierFunction -Name 'Invoke-CompletionResponse'
Import-VerifierFunction -Name 'Assert-WorkspaceMutationEvidence'
Import-VerifierFunction -Name 'Stop-WorkspaceVerifierDeployment'
Import-VerifierFunction -Name 'Remove-WorkspaceChildEnvObserverResult'
Import-VerifierFunction -Name 'Remove-RwReservedShadowProbeArtifacts'

# Tool evidence must stay attached to the exact correlated request. Reading the
# latest usage row can silently bind a probe to another concurrent request.
foreach ($functionName in @('Assert-LatestWorkspaceToolStep', 'Assert-LatestWorkspaceToolInvocation')) {
  $functionNode = $ast.Find({
    param($candidate)
    $candidate -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
      $candidate.Name -eq $functionName
  }, $true)
  if ($null -eq $functionNode) {
    Fail "verifier is missing $functionName"
  }
  if ($functionNode.Extent.Text -match "tail'\s*,\s*'-n'\s*,\s*'1'") {
    Fail "$functionName still binds tool evidence to the latest uncorrelated usage row"
  }
  if ($functionNode.Extent.Text -notmatch '(?i)\$UsageEvidence\b') {
    Fail "$functionName does not consume exact correlated usage evidence"
  }
}

$script:CleanupBlocked = $false
$script:CleanupBlockReason = $null
$script:ApiBase = 'http://127.0.0.1:1'
$script:EvidencePoll = 0

# Stabilization uses an inclusive deadline: evidence before or exactly at the
# budget is eligible; evidence first observed after the budget is late.
if (-not (Test-TerminalEvidenceWithinBudget -ElapsedMs 9999 -TimeoutMs 10000)) {
  Fail 'terminal evidence before the stabilization budget was rejected'
}
if (-not (Test-TerminalEvidenceWithinBudget -ElapsedMs 10000 -TimeoutMs 10000)) {
  Fail 'terminal evidence exactly at the stabilization boundary was rejected'
}
if (Test-TerminalEvidenceWithinBudget -ElapsedMs 10001 -TimeoutMs 10000) {
  Fail 'terminal evidence after the stabilization budget was accepted'
}

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

# Evidence first observed after the stabilization budget has expired must not
# be accepted merely because polling woke up late. The timeout is an evidence
# deadline, not a suggestion for how long to sleep between samples.
$script:CleanupBlocked = $false
$script:CleanupBlockReason = $null
$script:EvidencePoll = 0
function Get-RequestUsageEvidence {
  param(
    [Parameter(Mandatory = $true)][string]$RequestId,
    [Parameter(Mandatory = $true)][ValidateSet('default', 'ro', 'rw')][string]$DeploymentMode
  )
  $script:EvidencePoll++
  if ($script:EvidencePoll -eq 1) {
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

$lateTerminalRejected = $false
try {
  Wait-RequestTerminalEvidence `
    -RequestId 'verify-terminal-after-budget' `
    -DeploymentMode ro `
    -TimeoutMs 20 `
    -PollIntervalMs 60 | Out-Null
}
catch {
  if ($_.Exception.Message -like '*terminal state remains unknown*') {
    $lateTerminalRejected = $true
  }
  else { throw }
}
if (-not $lateTerminalRejected) {
  Fail 'terminal evidence first observed after the stabilization budget was accepted'
}
if (-not $script:CleanupBlocked) {
  Fail 'late terminal evidence did not block cleanup after the budget expired'
}

$script:CleanupBlocked = $false
$script:CleanupBlockReason = $null

# A single evidence fetch can itself cross the stabilization deadline (for
# example while Docker is slow). Terminal evidence returned only after that
# fetch completes is also late and must fail closed.
function Get-RequestUsageEvidence {
  param(
    [Parameter(Mandatory = $true)][string]$RequestId,
    [Parameter(Mandatory = $true)][ValidateSet('default', 'ro', 'rw')][string]$DeploymentMode
  )
  Start-Sleep -Milliseconds 60
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

$slowFetchRejected = $false
try {
  Wait-RequestTerminalEvidence `
    -RequestId 'verify-terminal-slow-fetch' `
    -DeploymentMode ro `
    -TimeoutMs 20 `
    -PollIntervalMs 1 | Out-Null
}
catch {
  if ($_.Exception.Message -like '*terminal state remains unknown*') {
    $slowFetchRejected = $true
  }
  else { throw }
}
if (-not $slowFetchRejected) {
  Fail 'terminal evidence returned by a fetch that crossed the budget was accepted'
}
if (-not $script:CleanupBlocked) {
  Fail 'slow evidence fetch did not block cleanup after crossing the budget'
}

$script:CleanupBlocked = $false
$script:CleanupBlockReason = $null

# A correlated request rejected before child spawn is already terminal once
# its usage evidence exists; it must not wait for an impossible child status.
function Get-RequestUsageEvidence {
  param(
    [Parameter(Mandatory = $true)][string]$RequestId,
    [Parameter(Mandatory = $true)][ValidateSet('default', 'ro', 'rw')][string]$DeploymentMode
  )
  return [pscustomobject]@{
    Found = $true
    RequestId = $RequestId
    ChildStarted = $false
    ChildTerminal = $false
    FailureKind = 'rejected'
    ChildExitCode = $null
    ChildSuccess = $null
    ChildSignal = $null
  }
}

$preSpawn = Wait-RequestTerminalEvidence `
  -RequestId 'verify-pre-spawn-reject' `
  -DeploymentMode ro `
  -TimeoutMs 100 `
  -PollIntervalMs 1
if ($preSpawn.ChildStarted -or $preSpawn.FailureKind -ne 'rejected') {
  Fail 'pre-spawn rejection did not resolve as a no-child terminal request'
}
if ($script:CleanupBlocked) {
  Fail 'pre-spawn rejection incorrectly blocked cleanup waiting for child terminal state'
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
