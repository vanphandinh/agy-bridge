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

function Get-FunctionText {
  param([Parameter(Mandatory = $true)][string]$Name)
  $node = $ast.Find({
    param($candidate)
    $candidate -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
      $candidate.Name -eq $Name
  }, $true)
  if ($null -eq $node) { return $null }
  return $node.Extent.Text
}

$stepFunction = Get-FunctionText -Name 'Assert-LatestWorkspaceToolStep'
if ([string]::IsNullOrWhiteSpace($stepFunction)) {
  Fail 'verifier is missing Assert-LatestWorkspaceToolStep'
}
Invoke-Expression $stepFunction

$script:FixtureUsage = @'
{"tool_step_updates":1,"autonomous":"rw","agent":"agy-bridge-worker-rw-v1","conversation_id":"11111111-1111-1111-1111-111111111111"}
'@
$script:FixtureTranscript = ''

function New-MockCapture {
  param([Parameter(Mandatory = $true)][string[]]$ArgumentList)
  if ($ArgumentList -contains 'tail') {
    return [pscustomobject]@{ ExitCode = 0; Output = $script:FixtureUsage }
  }
  if ($ArgumentList -contains 'cat') {
    return [pscustomobject]@{ ExitCode = 0; Output = $script:FixtureTranscript }
  }
  Fail "unexpected verifier capture arguments: $($ArgumentList -join ' ')"
}

function Invoke-WorkspaceDockerCapture {
  param(
    [string[]]$ArgumentList = @(),
    [switch]$AllowFailure,
    [switch]$Quiet
  )
  return New-MockCapture -ArgumentList $ArgumentList
}

function Invoke-WorkspaceRwDockerCapture {
  param(
    [string[]]$ArgumentList = @(),
    [switch]$AllowFailure,
    [switch]$Quiet
  )
  return New-MockCapture -ArgumentList $ArgumentList
}

function Invoke-WorkspaceModeDockerCapture {
  param(
    [Parameter(Mandatory = $true)][ValidateSet('ro', 'rw')][string]$DeploymentMode,
    [string[]]$ArgumentList = @(),
    [switch]$AllowFailure,
    [switch]$Quiet
  )
  return New-MockCapture -ArgumentList $ArgumentList
}

# This is the historical false-positive precondition: an unrelated native tool
# step satisfies the old aggregate counter even though the forbidden target was
# never attempted.
$script:FixtureTranscript = @'
{"type":"PLANNER_RESPONSE","tool_calls":[{"name":"view_file","args":{"AbsolutePath":"/workspace/README-fixture.txt"}}]}
'@
Assert-LatestWorkspaceToolStep `
  -DeploymentMode rw `
  -Context 'synthetic unrelated control read'

$exactFunction = Get-FunctionText -Name 'Assert-LatestWorkspaceToolInvocation'
if ([string]::IsNullOrWhiteSpace($exactFunction)) {
  Fail 'verifier accepted aggregate native-tool evidence but is missing exact-target invocation evidence'
}
Invoke-Expression $exactFunction

$target = '/outside/forbidden.txt'
$rejectedMissingTarget = $false
try {
  Assert-LatestWorkspaceToolInvocation `
    -DeploymentMode rw `
    -ExpectedPath $target `
    -ExpectedToolNames @('view_file') `
    -ExpectedPathFields @('AbsolutePath') `
    -Context 'synthetic missing target'
}
catch {
  if ($_.Exception.Message -like '*did not record a native tool invocation for the exact denied path*') {
    $rejectedMissingTarget = $true
  }
  else {
    throw
  }
}
if (-not $rejectedMissingTarget) {
  Fail 'unrelated benign tool activity satisfied the exact-target evidence gate'
}

$script:FixtureTranscript = @"
{"type":"PLANNER_RESPONSE","tool_calls":[{"name":"view_file","args":{"AbsolutePath":"$target"}}]}
"@
Assert-LatestWorkspaceToolInvocation `
  -DeploymentMode rw `
  -ExpectedPath $target `
  -ExpectedToolNames @('view_file') `
  -ExpectedPathFields @('AbsolutePath') `
  -Context 'synthetic exact target'

$script:FixtureTranscript = @"
{"type":"PLANNER_RESPONSE","tool_calls":[{"name":"list_dir","args":{"AbsolutePath":"$target"}}]}
"@
$rejectedWrongTool = $false
try {
  Assert-LatestWorkspaceToolInvocation `
    -DeploymentMode rw `
    -ExpectedPath $target `
    -ExpectedToolNames @('view_file') `
    -ExpectedPathFields @('AbsolutePath') `
    -Context 'synthetic wrong tool'
}
catch {
  if ($_.Exception.Message -like '*did not record a native tool invocation for the exact denied path*') {
    $rejectedWrongTool = $true
  }
  else {
    throw
  }
}
if (-not $rejectedWrongTool) {
  Fail 'wrong native tool type satisfied the exact-target evidence gate'
}

$writeTarget = '/outside/forbidden-write.txt'
$script:FixtureTranscript = @"
{"type":"PLANNER_RESPONSE","tool_calls":[{"name":"replace_file_content","args":{"TargetFile":"$writeTarget"}}]}
"@
Assert-LatestWorkspaceToolInvocation `
  -DeploymentMode rw `
  -ExpectedPath $writeTarget `
  -ExpectedToolNames @('write_to_file', 'replace_file_content') `
  -ExpectedPathFields @('TargetFile') `
  -Context 'synthetic exact write target'

$script:FixtureTranscript = @"
{"type":"PLANNER_RESPONSE","tool_calls":[{"name":"replace_file_content","args":{"AbsolutePath":"$writeTarget"}}]}
"@
$rejectedWrongWriteField = $false
try {
  Assert-LatestWorkspaceToolInvocation `
    -DeploymentMode rw `
    -ExpectedPath $writeTarget `
    -ExpectedToolNames @('write_to_file', 'replace_file_content') `
    -ExpectedPathFields @('TargetFile') `
    -Context 'synthetic wrong write path field'
}
catch {
  if ($_.Exception.Message -like '*did not record a native tool invocation for the exact denied path*') {
    $rejectedWrongWriteField = $true
  }
  else {
    throw
  }
}
if (-not $rejectedWrongWriteField) {
  Fail 'wrong write path field satisfied the exact-target evidence gate'
}

$observerFunction = Get-FunctionText -Name 'Wait-WorkspaceChildEnvObserver'
if ([string]::IsNullOrWhiteSpace($observerFunction)) {
  Fail 'verifier is missing Wait-WorkspaceChildEnvObserver'
}
Invoke-Expression $observerFunction
foreach ($mode in @('ro', 'rw')) {
  foreach ($verdict in @('CANARY_ABSENT', 'CANARY_PRESENT')) {
    $script:FixtureTranscript = "READY`n$verdict`n"
    $actual = Wait-WorkspaceChildEnvObserver -DeploymentMode $mode -ResultPath '/synthetic/observer' -Context 'synthetic observer'
    if ($actual -ne $verdict) { Fail "observer changed $verdict to $actual" }
  }
  $script:FixtureTranscript = "READY`nINCONCLUSIVE`n"
  $rejectedInconclusive = $false
  try {
    Wait-WorkspaceChildEnvObserver -DeploymentMode $mode -ResultPath '/synthetic/observer' -Context 'synthetic observer'
  }
  catch {
    if ($_.Exception.Message -like '*could not read a stable child environment*') {
      $rejectedInconclusive = $true
    }
    else { throw }
  }
  if (-not $rejectedInconclusive) { Fail "$mode accepted an inconclusive environment observation" }
}

Write-Host 'PASS: verifier binds workspace native-tool evidence to the exact target and rejects inconclusive child environments'
