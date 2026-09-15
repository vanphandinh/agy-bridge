[CmdletBinding()]
param(
  [string]$VerifierPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

if ([string]::IsNullOrWhiteSpace($VerifierPath)) {
  $VerifierPath = Join-Path $PSScriptRoot 'verify-all.ps1'
}

function Fail {
  param([Parameter(Mandatory = $true)][string]$Message)
  throw "FAIL: $Message"
}

function Get-FreeTcpPort {
  $listener = [System.Net.Sockets.TcpListener]::new(
    [System.Net.IPAddress]::Loopback,
    0
  )
  $listener.Start()
  try {
    return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
  }
  finally {
    $listener.Stop()
  }
}

function Start-TestHttpServer {
  param(
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][int]$DelayMs
  )
  $id = [Guid]::NewGuid().ToString('N')
  $serverPath = Join-Path $env:TEMP "agy-verifier-http-server-$id.ps1"
  $readyPath = Join-Path $env:TEMP "agy-verifier-http-ready-$id"
  $outputPath = Join-Path $env:TEMP "agy-verifier-http-output-$id.txt"
  $serverScript = @'
param(
  [int]$Port,
  [int]$DelayMs,
  [string]$ReadyPath,
  [string]$OutputPath
)
$ErrorActionPreference = 'Stop'
$listener = [System.Net.Sockets.TcpListener]::new(
  [System.Net.IPAddress]::Loopback,
  $Port
)
$listener.Start()
[System.IO.File]::WriteAllText($ReadyPath, 'READY')
try {
  $client = $listener.AcceptTcpClient()
  try {
    $stream = $client.GetStream()
    $reader = [System.IO.StreamReader]::new(
      $stream,
      [System.Text.Encoding]::ASCII,
      $false,
      1024,
      $true
    )
    $requestId = ''
    while ($true) {
      $line = $reader.ReadLine()
      if ($null -eq $line -or $line.Length -eq 0) { break }
      $match = [regex]::Match($line, '^X-Agy-Request-Id:\s*(.+)$', 'IgnoreCase')
      if ($match.Success) { $requestId = $match.Groups[1].Value.Trim() }
    }
    Start-Sleep -Milliseconds $DelayMs
    $stream.ReadTimeout = 150
    try {
      $peerProbe = $stream.ReadByte()
      if ($peerProbe -eq -1) {
        $peerState = 'PEER_READ=EOF'
      }
      else {
        $peerState = 'PEER_READ=UNEXPECTED_DATA'
      }
    }
    catch [System.IO.IOException] {
      $peerState = 'PEER_READ=NO_EOF'
    }
    $payload = [System.Text.Encoding]::ASCII.GetBytes(
      "HTTP/1.1 200 OK`r`nContent-Length: 2`r`nConnection: close`r`n`r`nOK"
    )
    try {
      $stream.Write($payload, 0, $payload.Length)
      $stream.Flush()
      $writeState = 'SERVER_WRITE=OK'
    }
    catch {
      $writeState = 'SERVER_WRITE=DISCONNECTED'
    }
    [System.IO.File]::WriteAllText(
      $OutputPath,
      "REQUEST_ID=$requestId`r`n$peerState`r`n$writeState`r`nSERVER_FINISHED=YES`r`n"
    )
  }
  finally {
    $client.Dispose()
  }
}
finally {
  $listener.Stop()
}
'@
  [System.IO.File]::WriteAllText(
    $serverPath,
    $serverScript,
    [System.Text.UTF8Encoding]::new($false)
  )
  $args = @(
    '-NoProfile',
    '-File', "`"$serverPath`"",
    '-Port', $Port,
    '-DelayMs', $DelayMs,
    '-ReadyPath', "`"$readyPath`"",
    '-OutputPath', "`"$outputPath`""
  )
  $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $args -PassThru -WindowStyle Hidden
  return [pscustomobject]@{
    Process = $process
    ServerPath = $serverPath
    ReadyPath = $readyPath
    OutputPath = $outputPath
  }
}

function Stop-TestHttpServer {
  param([Parameter(Mandatory = $true)]$Server)
  try {
    if (-not $Server.Process.HasExited) {
      if (-not $Server.Process.WaitForExit(5000)) {
        $Server.Process.Kill()
        $Server.Process.WaitForExit()
      }
    }
  }
  finally {
    Remove-Item -LiteralPath $Server.ServerPath, $Server.ReadyPath, $Server.OutputPath -Force -ErrorAction SilentlyContinue
    $Server.Process.Dispose()
  }
}

function Wait-TestServerReady {
  param([Parameter(Mandatory = $true)]$Server)
  $deadline = [DateTime]::UtcNow.AddSeconds(5)
  while ([DateTime]::UtcNow -lt $deadline) {
    if (Test-Path -LiteralPath $Server.ReadyPath) { return }
    if ($Server.Process.HasExited) { Fail 'local HTTP server exited before READY' }
    Start-Sleep -Milliseconds 50
  }
  Fail 'local HTTP server did not start'
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

$invokeHttpAst = $ast.Find({
  param($candidate)
  $candidate -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $candidate.Name -eq 'Invoke-Http'
}, $true)
if ($null -eq $invokeHttpAst) {
  Fail 'verifier is missing Invoke-Http'
}
Invoke-Expression $invokeHttpAst.Extent.Text

$script:RequestTimeoutSec = 1

# Control: a response completed before the deadline remains an ordinary HTTP
# completion and does not get confused with timeout handling.
$fastPort = Get-FreeTcpPort
$fastServer = Start-TestHttpServer -Port $fastPort -DelayMs 50
try {
  Wait-TestServerReady -Server $fastServer
  $fast = Invoke-Http -Method GET -Uri "http://127.0.0.1:$fastPort/"
  if ($fast.StatusCode -ne 200 -or $fast.Content -ne 'OK') {
    Fail 'response completed before deadline was not returned normally'
  }
}
finally {
  Stop-TestHttpServer -Server $fastServer
}

# Regression: the historical verifier let HttpClient surface a raw
# TaskCanceledException ("A task was canceled.") at the deadline. A timeout is
# a transport/lifecycle outcome, not a workspace-mutation assertion failure.
$slowPort = Get-FreeTcpPort
$slowServer = Start-TestHttpServer -Port $slowPort -DelayMs 1600
$slowRequestId = 'verify-http-timeout-wire-001'
try {
  Wait-TestServerReady -Server $slowServer
  $started = [DateTime]::UtcNow
  try {
    $slow = Invoke-Http -Method GET -Uri "http://127.0.0.1:$slowPort/" -RequestId $slowRequestId
  }
  catch {
    Fail "HTTP timeout escaped as an unclassified exception: $($_.Exception.Message)"
  }
  $elapsedMs = ([DateTime]::UtcNow - $started).TotalMilliseconds

  if ($slow.Outcome -ne 'timeout') {
    Fail "expected timeout outcome, got '$($slow.Outcome)'"
  }
  if ($elapsedMs -lt 700 -or $elapsedMs -gt 1450) {
    Fail "timeout returned outside the expected deadline window: ${elapsedMs}ms"
  }
  if ($slowServer.Process.HasExited) {
    Fail 'client timeout incorrectly implied that server-side work was terminal'
  }

  if (-not $slowServer.Process.WaitForExit(5000)) {
    Fail 'delayed server did not finish after the client timeout'
  }
  $serverOutput = Get-Content -LiteralPath $slowServer.OutputPath -Raw
  if ($serverOutput -notmatch 'SERVER_FINISHED=YES') {
    Fail 'delayed server did not finish after the client timeout'
  }
  if ($serverOutput -notmatch ("REQUEST_ID=" + [regex]::Escape($slowRequestId))) {
    Fail 'request correlation id was not delivered on the HTTP request'
  }
  $writeObservation = if ($serverOutput -match 'SERVER_WRITE=DISCONNECTED') {
    'disconnected-before-delayed-write'
  }
  else {
    'delayed-write-still-accepted'
  }
  $peerObservation = if ($serverOutput -match 'PEER_READ=EOF') {
    'peer-eof-observed'
  }
  elseif ($serverOutput -match 'PEER_READ=NO_EOF') {
    'no-peer-eof-observed'
  }
  else {
    'unexpected-peer-read-state'
  }
  Write-Host "OBSERVED: client timeout; connection=$peerObservation; server_write=$writeObservation; terminal inference remains forbidden"
}
finally {
  Stop-TestHttpServer -Server $slowServer
}

Write-Host 'PASS: verifier classifies HTTP timeout without assuming server-side termination'
