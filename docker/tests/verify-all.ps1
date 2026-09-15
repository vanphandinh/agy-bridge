[CmdletBinding()]
param(
  [string]$ExpectedHead = '',
  [string]$Model = '',
  [string]$BaseRef = '06567660cb765285cf68f28637169c79ddd1aabc',
  [switch]$SkipLive,
  [switch]$SkipDockerRestart,
  [int]$DockerRestartTimeoutSec = 300,
  [int]$ServiceStartTimeoutSec = 120,
  [int]$RequestTimeoutSec = 180
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Net.Http

$script:Results = @()
$script:HadFailure = $false
$script:Incomplete = $false
$script:FatalMessage = $null
$script:ApiBase = 'http://127.0.0.1:7421'
$script:SelectedModel = $null
$script:BridgeToken = $null
$script:WorkspaceFixtureRoot = $null
$script:WorkspaceOverrideFile = $null
$script:WorkspacePreviousHostPath = $null
$script:WorkspaceAgyVersion = $null
$script:WorkspaceFingerprint = $null
$script:WorkspaceMarkers = $null
$script:WorkspaceCanaries = $null
$script:WorkspaceRwFixtureRoot = $null
$script:WorkspaceRwOverrideFile = $null
$script:WorkspaceRwPreviousHostPath = $null
$script:WorkspaceRwMarkers = $null
$script:WorkspaceRwCanaries = $null
$script:WorkspaceRwEnvProbePassed = $false
$script:CleanupBlocked = $false
$script:CleanupBlockReason = $null

function Add-Result {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][ValidateSet('PASS', 'FAIL', 'SKIP')][string]$Status,
    [string]$Detail = ''
  )
  $script:Results += [pscustomobject]@{
    Gate = $Name
    Status = $Status
    Detail = $Detail
  }
}

function Invoke-Gate {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][scriptblock]$Action
  )
  Write-Host "`n=== $Name ===" -ForegroundColor Cyan
  try {
    & $Action
    Add-Result -Name $Name -Status PASS
    Write-Host "PASS: $Name" -ForegroundColor Green
  }
  catch {
    $script:HadFailure = $true
    $message = $_.Exception.Message
    Add-Result -Name $Name -Status FAIL -Detail $message
    Write-Host "FAIL: $Name - $message" -ForegroundColor Red
    throw
  }
}

function Add-Skip {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Reason
  )
  $script:Incomplete = $true
  Add-Result -Name $Name -Status SKIP -Detail $Reason
  Write-Host "SKIP: $Name - $Reason" -ForegroundColor Yellow
}

function Invoke-NativeCapture {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [string[]]$ArgumentList = @(),
    [switch]$AllowFailure,
    [switch]$Quiet,
    [int]$TimeoutMs = 0,
    [int]$TerminationGraceMs = 100
  )

  if ($TimeoutMs -gt 0) {
    $runner = @'
$ErrorActionPreference = 'Continue'
$payloadJson = [System.Text.Encoding]::UTF8.GetString(
  [Convert]::FromBase64String($env:AGY_VERIFY_NATIVE_PAYLOAD_B64)
)
$payload = $payloadJson | ConvertFrom-Json
$nativeArgs = @($payload.ArgumentList | ForEach-Object { [string]$_ })
$lines = @(& ([string]$payload.FilePath) @nativeArgs 2>&1)
$exitCode = $LASTEXITCODE
foreach ($line in $lines) {
  [Console]::Out.WriteLine([string]$line)
}
if ($null -eq $exitCode) { exit 1 }
exit [int]$exitCode
'@
    $payloadJson = @{
      FilePath = $FilePath
      ArgumentList = @($ArgumentList)
    } | ConvertTo-Json -Compress
    $payloadB64 = [Convert]::ToBase64String(
      [System.Text.Encoding]::UTF8.GetBytes($payloadJson)
    )
    $encodedRunner = [Convert]::ToBase64String(
      [System.Text.Encoding]::Unicode.GetBytes($runner)
    )
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Join-Path $PSHOME 'powershell.exe'
    $startInfo.Arguments =
      "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encodedRunner"
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $startInfo.EnvironmentVariables['AGY_VERIFY_NATIVE_PAYLOAD_B64'] = $payloadB64

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $forcedTermination = $false
    $timedOut = $false
    $stdout = ''
    $stderr = ''
    $budgetWatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
      if (-not $process.Start()) {
        throw "$FilePath failed to start"
      }
      $stdoutTask = $process.StandardOutput.ReadToEndAsync()
      $stderrTask = $process.StandardError.ReadToEndAsync()

      $remainingAfterStartMs = [Math]::Max(
        0,
        $TimeoutMs - [int]$budgetWatch.ElapsedMilliseconds
      )
      $terminationBudgetMs = [Math]::Min(
        [Math]::Max(0, $TerminationGraceMs),
        [Math]::Max(0, $remainingAfterStartMs - 1)
      )
      $executionBudgetMs = [Math]::Max(0, $remainingAfterStartMs - $terminationBudgetMs)
      if ($executionBudgetMs -le 0 -or -not $process.WaitForExit($executionBudgetMs)) {
        $timedOut = $true
        try { [void]$process.CloseMainWindow() } catch { }
        if (-not $process.HasExited) {
          $forcedTermination = $true
          $taskkillInfo = [System.Diagnostics.ProcessStartInfo]::new()
          $taskkillInfo.FileName = 'taskkill.exe'
          $taskkillInfo.Arguments = "/PID $($process.Id) /T /F"
          $taskkillInfo.UseShellExecute = $false
          $taskkillInfo.CreateNoWindow = $true
          $taskkillInfo.RedirectStandardOutput = $true
          $taskkillInfo.RedirectStandardError = $true
          $taskkill = [System.Diagnostics.Process]::new()
          $taskkill.StartInfo = $taskkillInfo
          $taskkillStarted = $false
          try {
            $taskkillStarted = $taskkill.Start()
            $remainingTerminationMs = [Math]::Max(
              0,
              $TimeoutMs - [int]$budgetWatch.ElapsedMilliseconds
            )
            if ($taskkillStarted -and $remainingTerminationMs -gt 0) {
              [void]$taskkill.WaitForExit($remainingTerminationMs)
            }
          }
          catch { }
          finally {
            if ($taskkillStarted -and -not $taskkill.HasExited) {
              try { $taskkill.Kill() } catch { }
            }
            $taskkill.Dispose()
          }
          if (-not $process.HasExited) {
            try { $process.Kill() } catch { }
          }
          $remainingTerminationMs = [Math]::Max(
            0,
            $TimeoutMs - [int]$budgetWatch.ElapsedMilliseconds
          )
          if (-not $process.HasExited -and $remainingTerminationMs -gt 0) {
            [void]$process.WaitForExit($remainingTerminationMs)
          }
        }
      }
      $budgetWatch.Stop()

      if ($process.HasExited) {
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
      }
      $textParts = @(
        @($stdout.TrimEnd(), $stderr.TrimEnd()) |
          Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
          ForEach-Object { [string]$_ }
      )
      $text = $textParts -join [Environment]::NewLine
      if (-not $Quiet -and $text) {
        Write-Host $text
      }

      if ($timedOut) {
        if (-not $process.HasExited) {
          throw "$FilePath timed out after ${TimeoutMs}ms and did not terminate"
        }
        if (-not $AllowFailure) {
          throw "$FilePath timed out after ${TimeoutMs}ms"
        }
        return [pscustomobject]@{
          ExitCode = $null
          Output = $text
          TimedOut = $true
          ForcedTermination = $forcedTermination
        }
      }

      $exitCode = $process.ExitCode
      if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "$FilePath $($ArgumentList -join ' ') failed with exit code $exitCode`n$text"
      }
      return [pscustomobject]@{
        ExitCode = $exitCode
        Output = $text
        TimedOut = $false
        ForcedTermination = $false
      }
    }
    finally {
      $process.Dispose()
    }
  }

  # Windows PowerShell 5.1 can promote redirected native stderr records to
  # terminating errors when ErrorActionPreference is Stop. Docker/BuildKit
  # writes normal progress to stderr, so temporarily relax only the native
  # invocation and decide success/failure from LASTEXITCODE below.
  $savedErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $lines = @(& $FilePath @ArgumentList 2>&1)
    $exitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $savedErrorActionPreference
  }

  $text = ($lines | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
  if (-not $Quiet -and $text) {
    Write-Host $text
  }
  if ($exitCode -ne 0 -and -not $AllowFailure) {
    throw "$FilePath $($ArgumentList -join ' ') failed with exit code $exitCode`n$text"
  }
  return [pscustomobject]@{
    ExitCode = $exitCode
    Output = $text
  }
}

function Invoke-DockerCapture {
  param(
    [string[]]$ArgumentList = @(),
    [switch]$AllowFailure,
    [switch]$Quiet,
    [int]$TimeoutMs = 0,
    [int]$TerminationGraceMs = 100
  )
  return Invoke-NativeCapture `
    -FilePath 'docker' `
    -ArgumentList $ArgumentList `
    -AllowFailure:$AllowFailure `
    -Quiet:$Quiet `
    -TimeoutMs $TimeoutMs `
    -TerminationGraceMs $TerminationGraceMs
}

function Invoke-Http {
  param(
    [Parameter(Mandatory = $true)][ValidateSet('GET', 'POST')][string]$Method,
    [Parameter(Mandatory = $true)][string]$Uri,
    [hashtable]$Headers = @{},
    [string]$Body = '',
    [string]$RequestId = ''
  )

  if (
    -not [string]::IsNullOrWhiteSpace($RequestId) -and
    $RequestId -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$'
  ) {
    throw 'request correlation id contains unsupported characters'
  }

  $client = [System.Net.Http.HttpClient]::new()
  # Own the deadline explicitly so a verifier timeout is distinguishable from
  # an unrelated cancellation. HttpClient.Timeout otherwise surfaces both as
  # TaskCanceledException ("A task was canceled."). A client-side timeout does
  # not prove that the bridge request or its child process has terminated.
  $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
  $deadlineCts = [System.Threading.CancellationTokenSource]::new()
  $deadlineCts.CancelAfter([TimeSpan]::FromSeconds($RequestTimeoutSec))
  $startedAt = [DateTime]::UtcNow
  $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
  $request = [System.Net.Http.HttpRequestMessage]::new(
    [System.Net.Http.HttpMethod]::new($Method),
    $Uri
  )
  try {
    foreach ($name in $Headers.Keys) {
      $value = [string]$Headers[$name]
      if ($name -eq 'Host') {
        $request.Headers.Host = $value
      }
      elseif (-not $request.Headers.TryAddWithoutValidation($name, $value)) {
        throw "unable to set HTTP header: $name"
      }
    }
    if (-not [string]::IsNullOrWhiteSpace($RequestId)) {
      if (-not $request.Headers.TryAddWithoutValidation('X-Agy-Request-Id', $RequestId)) {
        throw 'unable to set request correlation header'
      }
    }
    if ($Method -eq 'POST') {
      $request.Content = [System.Net.Http.StringContent]::new(
        $Body,
        [System.Text.Encoding]::UTF8,
        'application/json'
      )
    }

    try {
      $response = $client.SendAsync($request, $deadlineCts.Token).GetAwaiter().GetResult()
    }
    catch {
      $cause = $_.Exception
      while ($null -ne $cause.InnerException) {
        $cause = $cause.InnerException
      }
      if ($cause -is [System.OperationCanceledException]) {
        $stopwatch.Stop()
        $outcome = if ($deadlineCts.IsCancellationRequested) { 'timeout' } else { 'cancelled' }
        $endedAt = [DateTime]::UtcNow
        Write-Host (
          '[HTTP] request_id={0} outcome={1} started_utc={2} ended_utc={3} elapsed_ms={4} deadline_sec={5} terminal_state=unknown' -f
          $RequestId,
          $outcome,
          $startedAt.ToString('o'),
          $endedAt.ToString('o'),
          [Math]::Round($stopwatch.Elapsed.TotalMilliseconds, 2),
          $RequestTimeoutSec
        ) -ForegroundColor DarkYellow
        return [pscustomobject]@{
          RequestId = $RequestId
          Outcome = $outcome
          StatusCode = $null
          Content = ''
          StartedAtUtc = $startedAt.ToString('o')
          EndedAtUtc = $endedAt.ToString('o')
          ElapsedMs = [Math]::Round($stopwatch.Elapsed.TotalMilliseconds, 2)
          DeadlineSec = $RequestTimeoutSec
          TerminalState = 'unknown'
        }
      }
      throw
    }
    try {
      $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
      $stopwatch.Stop()
      $endedAt = [DateTime]::UtcNow
      Write-Host (
        '[HTTP] request_id={0} outcome=completed started_utc={1} ended_utc={2} elapsed_ms={3} deadline_sec={4} terminal_state=http_response' -f
        $RequestId,
        $startedAt.ToString('o'),
        $endedAt.ToString('o'),
        [Math]::Round($stopwatch.Elapsed.TotalMilliseconds, 2),
        $RequestTimeoutSec
      ) -ForegroundColor DarkGray
      return [pscustomobject]@{
        RequestId = $RequestId
        Outcome = 'completed'
        StatusCode = [int]$response.StatusCode
        Content = $content
        StartedAtUtc = $startedAt.ToString('o')
        EndedAtUtc = $endedAt.ToString('o')
        ElapsedMs = [Math]::Round($stopwatch.Elapsed.TotalMilliseconds, 2)
        DeadlineSec = $RequestTimeoutSec
        TerminalState = 'http_response'
      }
    }
    finally {
      $response.Dispose()
    }
  }
  finally {
    $request.Dispose()
    $deadlineCts.Dispose()
    $client.Dispose()
  }
}

function Invoke-DockerInfoProbe {
  param([int]$TimeoutMs = 3000)

  # docker info can block on the Windows Docker named pipe while Desktop is
  # restarting. Run the probe as its own process with a hard per-call timeout
  # so one wedged CLI invocation cannot freeze the entire verifier.
  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = 'docker'
  $startInfo.Arguments = 'info --format "{{.ServerVersion}}"'
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.CreateNoWindow = $true

  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  try {
    if (-not $process.Start()) {
      return [pscustomobject]@{
        Available = $false
        TimedOut = $false
        ExitCode = $null
        Detail = 'docker info probe did not start'
      }
    }

    if (-not $process.WaitForExit($TimeoutMs)) {
      try { $process.Kill() } catch { }
      try { [void]$process.WaitForExit(1000) } catch { }
      return [pscustomobject]@{
        Available = $false
        TimedOut = $true
        ExitCode = $null
        Detail = "docker info probe timed out after ${TimeoutMs}ms"
      }
    }

    $stdout = $process.StandardOutput.ReadToEnd().Trim()
    $stderr = $process.StandardError.ReadToEnd().Trim()
    $exitCode = $process.ExitCode
    $detail = if ($exitCode -eq 0) {
      $stdout
    }
    elseif ($stderr) {
      $stderr
    }
    else {
      "docker info exited with code $exitCode"
    }

    return [pscustomobject]@{
      Available = ($exitCode -eq 0)
      TimedOut = $false
      ExitCode = $exitCode
      Detail = $detail
    }
  }
  catch {
    return [pscustomobject]@{
      Available = $false
      TimedOut = $false
      ExitCode = $null
      Detail = $_.Exception.Message
    }
  }
  finally {
    $process.Dispose()
  }
}

function Wait-Docker {
  Write-Host '[Docker restart] waiting for daemon recovery...' -ForegroundColor DarkYellow
  $deadline = [DateTime]::UtcNow.AddSeconds($DockerRestartTimeoutSec)
  do {
    # docker info, bounded by Invoke-DockerInfoProbe
    $probe = Invoke-DockerInfoProbe -TimeoutMs 3000
    if ($probe.Available) {
      Write-Host '[Docker restart] daemon is UP.' -ForegroundColor DarkYellow
      return
    }
    if ($probe.TimedOut) {
      Write-Host '[Docker restart] probe timed out; daemon still unavailable...' -ForegroundColor DarkYellow
    }
    else {
      Write-Host '[Docker restart] daemon still unavailable...' -ForegroundColor DarkYellow
    }
    Start-Sleep -Seconds 2
  } while ([DateTime]::UtcNow -lt $deadline)
  throw 'Docker daemon did not become available after the restart checkpoint'
}

function Wait-DockerUnavailable {
  Write-Host '[Docker restart] waiting for daemon outage...' -ForegroundColor DarkYellow
  $deadline = [DateTime]::UtcNow.AddSeconds($DockerRestartTimeoutSec)
  $downStreak = 0
  do {
    $probe = Invoke-DockerInfoProbe -TimeoutMs 3000
    if (-not $probe.Available) {
      $downStreak++
      $reason = if ($probe.TimedOut) { 'probe timed out' } else { 'docker info failed' }
      Write-Host "[Docker restart] $reason -> DOWN candidate ($downStreak/2)" -ForegroundColor DarkYellow
      if ($downStreak -ge 2) {
        Write-Host '[Docker restart] daemon outage confirmed.' -ForegroundColor DarkYellow
        return
      }
    }
    else {
      if ($downStreak -gt 0) {
        Write-Host '[Docker restart] daemon responded again; resetting outage confirmation.' -ForegroundColor DarkYellow
      }
      $downStreak = 0
      Write-Host '[Docker restart] daemon still UP; restart not observed yet...' -ForegroundColor DarkYellow
    }
    Start-Sleep -Seconds 1
  } while ([DateTime]::UtcNow -lt $deadline)
  throw 'Docker daemon did not become unavailable during the restart checkpoint'
}

function Wait-BridgeHealth {
  $deadline = [DateTime]::UtcNow.AddSeconds($ServiceStartTimeoutSec)
  $lastError = 'no response yet'
  do {
    try {
      $res = Invoke-Http -Method GET -Uri "$($script:ApiBase)/healthz"
      if ($res.StatusCode -eq 200) {
        return
      }
      $lastError = "HTTP $($res.StatusCode)"
    }
    catch {
      $lastError = $_.Exception.Message
    }
    Start-Sleep -Seconds 2
  } while ([DateTime]::UtcNow -lt $deadline)
  throw "bridge did not become healthy: $lastError"
}

function Get-BridgeToken {
  $result = Invoke-DockerCapture -ArgumentList @('compose', '--profile', 'tools', 'run', '--rm', 'print-token') -Quiet
  $match = [regex]::Match($result.Output, 'AGY_TOKEN=([0-9a-f]{48})')
  if (-not $match.Success) {
    throw 'could not obtain the local bridge Bearer token from print-token'
  }
  return $match.Groups[1].Value
}

function Assert-OAuthPreflight {
  $command = '/app/docker/keyring-session.sh "$AGY_BIN" models >/tmp/verify-models.tsv && test -s /tmp/verify-models.tsv'
  $result = Invoke-DockerCapture -ArgumentList @(
    'compose', 'run', '--rm', '--no-deps', '--entrypoint', 'bash',
    'agy-bridge', '-lc', $command
  ) -AllowFailure -Quiet
  if ($result.ExitCode -ne 0) {
    throw "Antigravity OAuth is not reusable from the persisted volumes. Run 'docker compose run --rm agy-auth' once, then rerun this verifier."
  }
}

function Get-AuthenticatedModels {
  param([Parameter(Mandatory = $true)][string]$Token)
  $res = Invoke-Http -Method GET -Uri "$($script:ApiBase)/v1/models" -Headers @{
    Authorization = "Bearer $Token"
  }
  if ($res.StatusCode -ne 200) {
    throw "authenticated /v1/models returned HTTP $($res.StatusCode)"
  }
  $json = $res.Content | ConvertFrom-Json
  $ids = @($json.data | ForEach-Object { [string]$_.id } | Where-Object { $_ })
  if ($ids.Count -eq 0) {
    throw 'authenticated /v1/models returned an empty model list'
  }
  return $ids
}

function Invoke-CompletionSmoke {
  param(
    [Parameter(Mandatory = $true)][string]$WireModel,
    [Parameter(Mandatory = $true)][string]$Token,
    [Parameter(Mandatory = $true)][string]$Prompt
  )
  $res = Invoke-CompletionResponse `
    -WireModel $WireModel `
    -Token $Token `
    -Prompt $Prompt `
    -DeploymentMode default
  [void](Get-CompletionText -Response $res)
}

function Invoke-StreamingSmoke {
  param(
    [Parameter(Mandatory = $true)][string]$WireModel,
    [Parameter(Mandatory = $true)][string]$Token
  )
  $body = @{
    model = $WireModel
    stream = $true
    messages = @(@{ role = 'user'; content = 'Reply briefly with STREAM_VERIFY_OK.' })
  } | ConvertTo-Json -Depth 8 -Compress
  $requestId = 'verify-' + [Guid]::NewGuid().ToString('N')
  $res = Invoke-Http -Method POST -Uri "$($script:ApiBase)/v1/chat/completions" -Headers @{
    Authorization = "Bearer $Token"
  } -Body $body -RequestId $requestId
  $terminal = Wait-RequestTerminalEvidence -RequestId $requestId -DeploymentMode default
  $terminalState = if ($terminal.ChildStarted) { 'child_terminal' } else { 'no_child_spawned' }
  $res | Add-Member -NotePropertyName TerminalState -NotePropertyValue $terminalState -Force
  $res | Add-Member -NotePropertyName TerminalEvidence -NotePropertyValue $terminal -Force
  if ($res.Outcome -ne 'completed') {
    throw (
      'streaming completion transport {0} after {1}s; request_id={2}; terminal_state={3}' -f
      $res.Outcome,
      $res.DeadlineSec,
      $res.RequestId,
      $res.TerminalState
    )
  }
  if ($res.StatusCode -ne 200) {
    throw "streaming completion returned HTTP $($res.StatusCode): $($res.Content)"
  }
  if (-not $res.Content.Contains('data: [DONE]')) {
    throw 'streaming completion did not terminate with data: [DONE]'
  }
  if ($res.Content -match '"error"\s*:') {
    throw 'streaming completion contained an error event'
  }
}

function Set-StateMarker {
  param([Parameter(Mandatory = $true)][string]$Marker)
  $command = "printf '%s' '$Marker' > /home/agy/.local/state/agy-bridge/verify-persistence-marker"
  Invoke-DockerCapture -ArgumentList @('compose', 'exec', '-T', 'agy-bridge', 'bash', '-lc', $command) -Quiet | Out-Null
}

function Assert-StateMarker {
  param([Parameter(Mandatory = $true)][string]$Marker)
  $result = Invoke-DockerCapture -ArgumentList @(
    'compose', 'exec', '-T', 'agy-bridge', 'cat',
    '/home/agy/.local/state/agy-bridge/verify-persistence-marker'
  ) -Quiet
  if ($result.Output.Trim() -ne $Marker) {
    throw 'bridge-state persistence marker is missing or changed'
  }
}

function Assert-ApiAfterPersistenceTransition {
  param(
    [Parameter(Mandatory = $true)][string]$ExpectedToken,
    [Parameter(Mandatory = $true)][string]$Marker
  )
  Wait-BridgeHealth
  $currentToken = Get-BridgeToken
  if ($currentToken -ne $ExpectedToken) {
    throw 'local Bearer token changed across a persistence transition'
  }
  $models = Get-AuthenticatedModels -Token $ExpectedToken
  if ($models.Count -eq 0) {
    throw 'OAuth reuse verification returned no models'
  }
  Assert-StateMarker -Marker $Marker
}

function Test-DestructiveReset {
  $suffix = [Guid]::NewGuid().ToString('N').Substring(0, 12)
  $project = "agy-bridge-reset-$suffix"
  $marker = "reset-$suffix"
  $token1 = $null
  try {
    Invoke-DockerCapture -ArgumentList @('compose', '-p', $project, '--profile', 'tools', 'run', '--rm', 'init-secrets') -Quiet | Out-Null
    $first = Invoke-DockerCapture -ArgumentList @('compose', '-p', $project, '--profile', 'tools', 'run', '--rm', 'print-token') -Quiet
    $m1 = [regex]::Match($first.Output, 'AGY_TOKEN=([0-9a-f]{48})')
    if (-not $m1.Success) { throw 'disposable reset project did not generate a bridge token' }
    $token1 = $m1.Groups[1].Value

    $writeMarkers = "printf '%s' '$marker' > /home/agy/.gemini/.verify-marker; printf '%s' '$marker' > /home/agy/.local/share/keyrings/.verify-marker"
    Invoke-DockerCapture -ArgumentList @(
      'compose', '-p', $project, '--profile', 'tools', 'run', '--rm',
      '--entrypoint', 'bash', 'agy-auth', '-lc', $writeMarkers
    ) -Quiet | Out-Null

    # docker compose down -v (disposable project only)
    Invoke-DockerCapture -ArgumentList @('compose', '-p', $project, '--profile', 'tools', 'down', '-v', '--remove-orphans') -Quiet | Out-Null

    Invoke-DockerCapture -ArgumentList @('compose', '-p', $project, '--profile', 'tools', 'run', '--rm', 'init-secrets') -Quiet | Out-Null
    $second = Invoke-DockerCapture -ArgumentList @('compose', '-p', $project, '--profile', 'tools', 'run', '--rm', 'print-token') -Quiet
    $m2 = [regex]::Match($second.Output, 'AGY_TOKEN=([0-9a-f]{48})')
    if (-not $m2.Success) { throw 'disposable reset project did not regenerate a bridge token' }
    if ($m2.Groups[1].Value -eq $token1) {
      throw 'down -v did not reset the disposable agy-secrets volume'
    }

    $assertMarkersGone = 'test ! -e /home/agy/.gemini/.verify-marker && test ! -e /home/agy/.local/share/keyrings/.verify-marker'
    Invoke-DockerCapture -ArgumentList @(
      'compose', '-p', $project, '--profile', 'tools', 'run', '--rm',
      '--entrypoint', 'bash', 'agy-auth', '-lc', $assertMarkersGone
    ) -Quiet | Out-Null
  }
  finally {
    Invoke-DockerCapture -ArgumentList @('compose', '-p', $project, '--profile', 'tools', 'down', '-v', '--remove-orphans') -AllowFailure -Quiet | Out-Null
  }
}

function Get-WorkspaceComposeArgs {
  if (-not $script:WorkspaceOverrideFile) {
    throw 'workspace verifier override is not initialized'
  }
  return @(
    'compose',
    '-f', 'compose.yaml',
    '-f', 'compose.workspace.yaml',
    '-f', $script:WorkspaceOverrideFile
  )
}

function Invoke-WorkspaceDockerCapture {
  param(
    [string[]]$ArgumentList = @(),
    [switch]$AllowFailure,
    [switch]$Quiet,
    [int]$TimeoutMs = 0
  )
  $prefix = @(Get-WorkspaceComposeArgs)
  return Invoke-DockerCapture `
    -ArgumentList @($prefix + $ArgumentList) `
    -AllowFailure:$AllowFailure `
    -Quiet:$Quiet `
    -TimeoutMs $TimeoutMs
}

function Get-RequestUsageEvidence {
  param(
    [Parameter(Mandatory = $true)][string]$RequestId,
    [Parameter(Mandatory = $true)][ValidateSet('default', 'ro', 'rw')][string]$DeploymentMode,
    [int]$TimeoutMs = 0
  )

  $tailArgs = @(
    'exec', '-T', 'agy-bridge',
    'tail', '-n', '200',
    '/home/agy/.local/state/agy-bridge/usage.jsonl'
  )
  if ($DeploymentMode -eq 'ro') {
    $capture = Invoke-WorkspaceDockerCapture `
      -ArgumentList $tailArgs `
      -AllowFailure `
      -Quiet `
      -TimeoutMs $TimeoutMs
  }
  elseif ($DeploymentMode -eq 'rw') {
    $capture = Invoke-WorkspaceRwDockerCapture `
      -ArgumentList $tailArgs `
      -AllowFailure `
      -Quiet `
      -TimeoutMs $TimeoutMs
  }
  else {
    $captureArgs = @('compose') + $tailArgs
    $capture = Invoke-DockerCapture `
      -ArgumentList $captureArgs `
      -AllowFailure `
      -Quiet `
      -TimeoutMs $TimeoutMs
  }
  if ($capture.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($capture.Output)) {
    return [pscustomobject]@{
      Found = $false
      RequestId = $RequestId
      ChildTerminal = $false
    }
  }

  $lines = @($capture.Output -split '[\r\n]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  for ($i = $lines.Count - 1; $i -ge 0; $i--) {
    try {
      $entry = $lines[$i] | ConvertFrom-Json
    }
    catch {
      continue
    }
    if (
      -not ($entry.PSObject.Properties.Name -contains 'request_id') -or
      [string]$entry.request_id -ne $RequestId
    ) {
      continue
    }
    $childTerminal =
      $entry.PSObject.Properties.Name -contains 'child_terminal' -and
      [bool]$entry.child_terminal
    $childStarted =
      $entry.PSObject.Properties.Name -contains 'child_started' -and
      [bool]$entry.child_started
    return [pscustomobject]@{
      Found = $true
      RequestId = $RequestId
      Timestamp = if ($entry.PSObject.Properties.Name -contains 'ts') { [string]$entry.ts } else { $null }
      Ok = if ($entry.PSObject.Properties.Name -contains 'ok') { [bool]$entry.ok } else { $null }
      FailureKind = if ($entry.PSObject.Properties.Name -contains 'failure_kind') { [string]$entry.failure_kind } else { $null }
      ChildStarted = $childStarted
      ChildTerminal = $childTerminal
      ChildSuccess = if ($entry.PSObject.Properties.Name -contains 'child_success') { [bool]$entry.child_success } else { $null }
      ChildExitCode = if ($entry.PSObject.Properties.Name -contains 'child_exit_code') { [int]$entry.child_exit_code } else { $null }
      ChildSignal = if ($entry.PSObject.Properties.Name -contains 'child_signal') { [string]$entry.child_signal } else { $null }
      ConversationId = if ($entry.PSObject.Properties.Name -contains 'conversation_id') { [string]$entry.conversation_id } else { $null }
      ToolStepUpdates = if ($entry.PSObject.Properties.Name -contains 'tool_step_updates') { [int]$entry.tool_step_updates } else { $null }
      Autonomous = if ($entry.PSObject.Properties.Name -contains 'autonomous') { [string]$entry.autonomous } else { $null }
      Agent = if ($entry.PSObject.Properties.Name -contains 'agent') { [string]$entry.agent } else { $null }
    }
  }

  return [pscustomobject]@{
    Found = $false
    RequestId = $RequestId
    ChildStarted = $false
    ChildTerminal = $false
  }
}

function Test-TerminalEvidenceWithinBudget {
  param(
    [Parameter(Mandatory = $true)][long]$ElapsedMs,
    [Parameter(Mandatory = $true)][int]$TimeoutMs
  )
  return $ElapsedMs -le $TimeoutMs
}

function Wait-RequestTerminalEvidence {
  param(
    [Parameter(Mandatory = $true)][string]$RequestId,
    [Parameter(Mandatory = $true)][ValidateSet('default', 'ro', 'rw')][string]$DeploymentMode,
    [int]$TimeoutMs = 10000,
    [int]$PollIntervalMs = 200
  )

  $watch = [System.Diagnostics.Stopwatch]::StartNew()
  do {
    # The stabilization timeout is an evidence deadline. A poll that wakes up
    # after the budget must not accept evidence first observed late. Keep the
    # boundary inclusive: evidence observed at exactly TimeoutMs is eligible.
    if (-not (Test-TerminalEvidenceWithinBudget -ElapsedMs $watch.ElapsedMilliseconds -TimeoutMs $TimeoutMs)) { break }
    $remainingMs = $TimeoutMs - [int]$watch.ElapsedMilliseconds
    if ($remainingMs -le 0) { break }
    try {
      $evidence = Get-RequestUsageEvidence `
        -RequestId $RequestId `
        -DeploymentMode $DeploymentMode `
        -TimeoutMs $remainingMs
    }
    catch {
      $script:CleanupBlocked = $true
      $script:CleanupBlockReason =
        "request $RequestId terminal evidence fetch failed; refusing cleanup or further gates"
      throw "$($script:CleanupBlockReason): $($_.Exception.Message)"
    }
    if (-not (Test-TerminalEvidenceWithinBudget -ElapsedMs $watch.ElapsedMilliseconds -TimeoutMs $TimeoutMs)) { break }
    if ($evidence.Found -and ((-not $evidence.ChildStarted) -or $evidence.ChildTerminal)) {
      $watch.Stop()
      Write-Host (
        '[HTTP terminal] request_id={0} mode={1} elapsed_ms={2} child_started={3} child_terminal={4} failure_kind={5} child_exit_code={6} child_signal={7}' -f
        $RequestId,
        $DeploymentMode,
        [Math]::Round($watch.Elapsed.TotalMilliseconds, 2),
        $evidence.ChildStarted,
        $evidence.ChildTerminal,
        $evidence.FailureKind,
        $evidence.ChildExitCode,
        $evidence.ChildSignal
      ) -ForegroundColor DarkYellow
      return $evidence
    }
    if ($watch.ElapsedMilliseconds -ge $TimeoutMs) { break }
    $remainingMs = [Math]::Max(1, $TimeoutMs - [int]$watch.ElapsedMilliseconds)
    $sleepMs = [Math]::Min([Math]::Max(1, $PollIntervalMs), $remainingMs)
    Start-Sleep -Milliseconds $sleepMs
  } while ($true)

  $watch.Stop()
  $script:CleanupBlocked = $true
  $script:CleanupBlockReason =
    "request $RequestId terminal state remains unknown after ${TimeoutMs}ms; refusing cleanup or further gates"
  throw $script:CleanupBlockReason
}

function Get-Sha256Hex {
  param([Parameter(Mandatory = $true)][string]$Path)
  $stream = [System.IO.File]::OpenRead($Path)
  try {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
      return ([System.BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '')
    }
    finally {
      $sha.Dispose()
    }
  }
  finally {
    $stream.Dispose()
  }
}

function Get-WorkspaceFingerprint {
  param([Parameter(Mandatory = $true)][string]$Path)
  $root = [System.IO.Path]::GetFullPath($Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
  $entries = @()
  foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -File | Sort-Object FullName)) {
    $relative = $file.FullName.Substring($root.Length).TrimStart([char[]]@('\', '/'))
    $hash = Get-Sha256Hex -Path $file.FullName
    $entries += "FILE|$relative|$($file.Length)|$($file.LastWriteTimeUtc.Ticks)|$hash"
  }
  foreach ($dir in @(Get-ChildItem -LiteralPath $root -Recurse -Directory | Sort-Object FullName)) {
    $relative = $dir.FullName.Substring($root.Length).TrimStart([char[]]@('\', '/'))
    $entries += "DIR|$relative|$($dir.LastWriteTimeUtc.Ticks)"
  }
  return $entries -join "`n"
}

function Assert-WorkspaceMutationEvidence {
  param(
    [Parameter(Mandatory = $true)]$Response,
    [Parameter(Mandatory = $true)][string]$BeforeFingerprint,
    [Parameter(Mandatory = $true)][string]$AfterFingerprint
  )

  if ($AfterFingerprint -ne $BeforeFingerprint) {
    throw 'host workspace fingerprint changed after mutation request'
  }
  if ($Response.Outcome -ne 'completed') {
    throw (
      'workspace mutation probe {0} after {1}s; request_id={2}; terminal_state={3}; fingerprint unchanged but immutability evidence remains inconclusive' -f
      $Response.Outcome,
      $Response.DeadlineSec,
      $Response.RequestId,
      $Response.TerminalState
    )
  }
  if ($Response.StatusCode -ne 200) {
    throw "workspace mutation probe requires HTTP 200 evidence; got HTTP $($Response.StatusCode)"
  }
}

function Invoke-CompletionResponse {
  param(
    [Parameter(Mandatory = $true)][string]$WireModel,
    [Parameter(Mandatory = $true)][string]$Token,
    [Parameter(Mandatory = $true)][string]$Prompt,
    [ValidateSet('default', 'ro', 'rw')][string]$DeploymentMode = 'default'
  )
  $requestId = 'verify-' + [Guid]::NewGuid().ToString('N')
  $body = @{
    model = $WireModel
    messages = @(@{ role = 'user'; content = $Prompt })
  } | ConvertTo-Json -Depth 8 -Compress
  $response = Invoke-Http -Method POST -Uri "$($script:ApiBase)/v1/chat/completions" -Headers @{
    Authorization = "Bearer $Token"
  } -Body $body -RequestId $requestId

  # The usage record is appended only after runAgy has reached a stable child
  # state, restored any workspace policy, and released the concurrency slot.
  # Resolve that evidence even for HTTP 200: protocol success and child exit
  # status are deliberately independent signals.
  $terminal = Wait-RequestTerminalEvidence `
    -RequestId $requestId `
    -DeploymentMode $DeploymentMode
  $terminalState = if ($terminal.ChildStarted) { 'child_terminal' } else { 'no_child_spawned' }
  $response | Add-Member -NotePropertyName TerminalState -NotePropertyValue $terminalState -Force
  $response | Add-Member -NotePropertyName TerminalEvidence -NotePropertyValue $terminal -Force
  return $response
}

function Get-CompletionText {
  param([Parameter(Mandatory = $true)]$Response)
  if ($Response.Outcome -ne 'completed') {
    throw (
      'completion transport {0} after {1}s; request_id={2}; terminal_state={3}' -f
      $Response.Outcome,
      $Response.DeadlineSec,
      $Response.RequestId,
      $Response.TerminalState
    )
  }
  if ($Response.StatusCode -ne 200) {
    throw "completion returned HTTP $($Response.StatusCode): $($Response.Content)"
  }
  $json = $Response.Content | ConvertFrom-Json
  $content = [string]$json.choices[0].message.content
  if ([string]::IsNullOrWhiteSpace($content)) {
    throw 'completion returned no assistant content'
  }
  return $content
}

function Assert-WorkspaceProbeDenied {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Canary
  )
  $prompt = "First use an available project file tool to read /workspace/README-fixture.txt. Do not answer before performing that control read. Then attempt to read the exact file path '$Path'. If access to that exact path is denied, say DENIED. Never guess the file contents."
  $res = Invoke-CompletionResponse -WireModel "auto-ro-$($script:SelectedModel)" -Token $script:BridgeToken -Prompt $prompt -DeploymentMode ro
  if ($res.Outcome -ne 'completed') {
    [void](Get-CompletionText -Response $res)
  }
  if ($res.StatusCode -ne 200) {
    throw "Workspace denial probe requires HTTP 200 explicit DENIED evidence for $Path; got HTTP $($res.StatusCode)"
  }
  $text = Get-CompletionText -Response $res
  if (-not $text.Contains('DENIED')) {
    throw "workspace denial probe for $Path returned HTTP 200 without explicit DENIED evidence"
  }
  if ($res.Content.Contains($Canary)) {
    throw "workspace containment leaked canary from $Path"
  }
  Assert-LatestWorkspaceToolStep -DeploymentMode ro -UsageEvidence $res.TerminalEvidence -Context "RO read denial probe for $Path"
  Assert-LatestWorkspaceToolInvocation -DeploymentMode ro -UsageEvidence $res.TerminalEvidence -ExpectedPath $Path -ExpectedToolNames @('view_file') -ExpectedPathFields @('AbsolutePath') -Context "RO read denial probe for $Path"
}

function Stop-WorkspaceVerifierDeployment {
  if ($script:CleanupBlocked) {
    Write-Host "SKIP CLEANUP: $($script:CleanupBlockReason)" -ForegroundColor Red
    return
  }
  if ($script:WorkspaceOverrideFile -and (Test-Path -LiteralPath $script:WorkspaceOverrideFile)) {
    try {
      Invoke-WorkspaceDockerCapture -ArgumentList @('down', '--remove-orphans') -AllowFailure -Quiet | Out-Null
    }
    catch { }
  }
  if ($null -eq $script:WorkspacePreviousHostPath) {
    Remove-Item Env:AGY_WORKSPACE_HOST_PATH -ErrorAction SilentlyContinue
  }
  else {
    $env:AGY_WORKSPACE_HOST_PATH = $script:WorkspacePreviousHostPath
  }
  if ($script:WorkspaceFixtureRoot -and (Test-Path -LiteralPath $script:WorkspaceFixtureRoot)) {
    Remove-Item -LiteralPath $script:WorkspaceFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
  $script:WorkspaceFixtureRoot = $null
  $script:WorkspaceOverrideFile = $null
}

function Get-WorkspaceRwComposeArgs {
  if (-not $script:WorkspaceRwOverrideFile) {
    throw 'RW workspace verifier override is not initialized'
  }
  return @(
    'compose',
    '-f', 'compose.yaml',
    '-f', 'compose.workspace-rw.yaml',
    '-f', $script:WorkspaceRwOverrideFile
  )
}

function Invoke-WorkspaceRwDockerCapture {
  param(
    [string[]]$ArgumentList = @(),
    [switch]$AllowFailure,
    [switch]$Quiet,
    [int]$TimeoutMs = 0
  )
  $prefix = @(Get-WorkspaceRwComposeArgs)
  return Invoke-DockerCapture `
    -ArgumentList @($prefix + $ArgumentList) `
    -AllowFailure:$AllowFailure `
    -Quiet:$Quiet `
    -TimeoutMs $TimeoutMs
}

function ConvertTo-ShellSingleQuoted {
  param([Parameter(Mandatory = $true)][string]$Value)
  if ($Value.Contains("'")) {
    throw 'child environment observer argument contains an unsupported single quote'
  }
  return "'$Value'"
}

function Invoke-WorkspaceModeDockerCapture {
  param(
    [Parameter(Mandatory = $true)][ValidateSet('ro', 'rw')][string]$DeploymentMode,
    [string[]]$ArgumentList = @(),
    [switch]$AllowFailure,
    [switch]$Quiet
  )
  if ($DeploymentMode -eq 'ro') {
    return Invoke-WorkspaceDockerCapture -ArgumentList $ArgumentList -AllowFailure:$AllowFailure -Quiet:$Quiet
  }
  return Invoke-WorkspaceRwDockerCapture -ArgumentList $ArgumentList -AllowFailure:$AllowFailure -Quiet:$Quiet
}

function Start-WorkspaceChildEnvObserver {
  param(
    [Parameter(Mandatory = $true)][ValidateSet('ro', 'rw')][string]$DeploymentMode,
    [Parameter(Mandatory = $true)][string]$FirstCommandFragment,
    [Parameter(Mandatory = $true)][string]$SecondCommandFragment,
    [Parameter(Mandatory = $true)][string]$EnvName,
    [Parameter(Mandatory = $true)][string]$EnvValue
  )

  $helperPath = Join-Path (Get-Location) 'docker/tests/observe-child-env.sh'
  if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) {
    throw "missing child environment observer helper: $helperPath"
  }
  $helper = (Get-Content -LiteralPath $helperPath -Raw).Replace("`r", '')
  $resultPath = "/home/agy/.local/state/agy-bridge/.verify-child-env-$([Guid]::NewGuid().ToString('N')).txt"
  $observerArgs = @(
    $resultPath,
    $FirstCommandFragment,
    $SecondCommandFragment,
    $EnvName,
    $EnvValue,
    '30'
  )
  $setArgs = 'set -- ' + (($observerArgs | ForEach-Object { ConvertTo-ShellSingleQuoted -Value $_ }) -join ' ')
  $runner = $setArgs + "`n" + $helper
  $encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($runner))
  $launchScript = "printf '%s' '$encoded' | base64 -d | bash"

  Invoke-WorkspaceModeDockerCapture -DeploymentMode $DeploymentMode -ArgumentList @(
    'exec', '-T', '-d', 'agy-bridge', 'bash', '-lc', $launchScript
  ) -Quiet | Out-Null

  $deadline = [DateTime]::UtcNow.AddSeconds(5)
  while ([DateTime]::UtcNow -lt $deadline) {
    $ready = Invoke-WorkspaceModeDockerCapture -DeploymentMode $DeploymentMode -ArgumentList @(
      'exec', '-T', 'agy-bridge', 'cat', $resultPath
    ) -AllowFailure -Quiet
    if ($ready.ExitCode -eq 0 -and $ready.Output -match '(?m)^READY$') {
      return $resultPath
    }
    Start-Sleep -Milliseconds 50
  }
  throw "$DeploymentMode child environment observer did not become ready"
}

function Wait-WorkspaceChildEnvObserver {
  param(
    [Parameter(Mandatory = $true)][ValidateSet('ro', 'rw')][string]$DeploymentMode,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [Parameter(Mandatory = $true)][string]$Context
  )

  $deadline = [DateTime]::UtcNow.AddSeconds(35)
  while ([DateTime]::UtcNow -lt $deadline) {
    $result = Invoke-WorkspaceModeDockerCapture -DeploymentMode $DeploymentMode -ArgumentList @(
      'exec', '-T', 'agy-bridge', 'cat', $ResultPath
    ) -AllowFailure -Quiet
    if ($result.ExitCode -eq 0) {
      if ($result.Output -match '(?m)^CANARY_PRESENT$') { return 'CANARY_PRESENT' }
      if ($result.Output -match '(?m)^CANARY_ABSENT$') { return 'CANARY_ABSENT' }
      if ($result.Output -match '(?m)^INCONCLUSIVE$') {
        throw "$Context could not read a stable child environment; containment evidence is incomplete"
      }
      if ($result.Output -match '(?m)^TIMEOUT$') {
        throw "$Context did not observe the expected agy child before timeout"
      }
    }
    Start-Sleep -Milliseconds 50
  }
  throw "$Context child environment observer did not produce a verdict"
}

function Remove-WorkspaceChildEnvObserverResult {
  param(
    [Parameter(Mandatory = $true)][ValidateSet('ro', 'rw')][string]$DeploymentMode,
    [Parameter(Mandatory = $true)][string]$ResultPath
  )
  if ($script:CleanupBlocked) {
    Write-Host "SKIP CLEANUP: $($script:CleanupBlockReason)" -ForegroundColor Red
    return
  }
  Invoke-WorkspaceModeDockerCapture -DeploymentMode $DeploymentMode -ArgumentList @(
    'exec', '-T', 'agy-bridge', 'rm', '-f', $ResultPath
  ) -AllowFailure -Quiet | Out-Null
}

function Remove-RwReservedShadowProbeArtifacts {
  param(
    [Parameter(Mandatory = $true)][string]$ReservedContainerPath,
    [Parameter(Mandatory = $true)][string]$SentinelHostPath
  )
  if ($script:CleanupBlocked) {
    Write-Host "SKIP CLEANUP: $($script:CleanupBlockReason)" -ForegroundColor Red
    return
  }
  Invoke-WorkspaceRwDockerCapture -ArgumentList @(
    'exec', '-T', 'agy-bridge', 'rm', '-f', $ReservedContainerPath
  ) -AllowFailure -Quiet | Out-Null
  Remove-Item -LiteralPath $SentinelHostPath -Force -ErrorAction SilentlyContinue
}

function Assert-LatestWorkspaceToolStep {
  param(
    [Parameter(Mandatory = $true)][ValidateSet('ro', 'rw')][string]$DeploymentMode,
    [Parameter(Mandatory = $true)]$UsageEvidence,
    [Parameter(Mandatory = $true)][string]$Context
  )
  if (-not $UsageEvidence.Found) {
    throw "$Context has no correlated bridge usage entry to prove native tool activity"
  }
  if ($null -eq $UsageEvidence.ToolStepUpdates -or [int]$UsageEvidence.ToolStepUpdates -lt 1) {
    throw "$Context did not reach a native tool step"
  }
  $expectedAgent = if ($DeploymentMode -eq 'ro') {
    'agy-bridge-worker-ro-v1'
  }
  else {
    'agy-bridge-worker-rw-v1'
  }
  if ([string]$UsageEvidence.Autonomous -ne $DeploymentMode -or [string]$UsageEvidence.Agent -ne $expectedAgent) {
    throw "$Context tool evidence came from the wrong autonomous profile or agent"
  }
}

function Assert-LatestWorkspaceToolInvocation {
  param(
    [Parameter(Mandatory = $true)][ValidateSet('ro', 'rw')][string]$DeploymentMode,
    [Parameter(Mandatory = $true)]$UsageEvidence,
    [Parameter(Mandatory = $true)][string]$ExpectedPath,
    [Parameter(Mandatory = $true)][string[]]$ExpectedToolNames,
    [Parameter(Mandatory = $true)][string[]]$ExpectedPathFields,
    [switch]$BareRoute,
    [Parameter(Mandatory = $true)][string]$Context
  )

  if (-not $UsageEvidence.Found) {
    throw "$Context has no correlated bridge usage entry to locate native tool evidence"
  }
  if ($BareRoute) {
    if ($UsageEvidence.Autonomous -or $UsageEvidence.Agent) {
      throw "$Context tool invocation evidence came from an autonomous workspace route instead of the bare route"
    }
  }
  else {
    $expectedAgent = if ($DeploymentMode -eq 'ro') {
      'agy-bridge-worker-ro-v1'
    }
    else {
      'agy-bridge-worker-rw-v1'
    }
    if ([string]$UsageEvidence.Autonomous -ne $DeploymentMode -or [string]$UsageEvidence.Agent -ne $expectedAgent) {
      throw "$Context tool invocation evidence came from the wrong autonomous profile or agent"
    }
  }

  $conversationId = [string]$UsageEvidence.ConversationId
  $parsedConversationId = [Guid]::Empty
  if (-not [Guid]::TryParse($conversationId, [ref]$parsedConversationId)) {
    throw "$Context usage entry has no valid conversation_id for transcript evidence"
  }

  $transcriptPath = "/home/agy/.gemini/antigravity-cli/brain/$conversationId/.system_generated/logs/transcript_full.jsonl"
  $transcript = Invoke-WorkspaceModeDockerCapture `
    -DeploymentMode $DeploymentMode `
    -ArgumentList @('exec', '-T', 'agy-bridge', 'cat', $transcriptPath) `
    -AllowFailure `
    -Quiet
  if ($transcript.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($transcript.Output)) {
    throw "$Context could not read transcript_full.jsonl for native tool evidence"
  }

  $matched = $false
  foreach ($line in @($transcript.Output -split '[\r\n]+')) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try {
      $event = $line | ConvertFrom-Json
    }
    catch {
      throw "$Context transcript_full.jsonl contains malformed JSON"
    }
    if ([string]$event.type -ne 'PLANNER_RESPONSE') { continue }
    if (-not ($event.PSObject.Properties.Name -contains 'tool_calls') -or $null -eq $event.tool_calls) {
      continue
    }
    foreach ($toolCall in @($event.tool_calls)) {
      if (
        $null -eq $toolCall -or
        -not ($toolCall.PSObject.Properties.Name -contains 'name') -or
        $ExpectedToolNames -notcontains [string]$toolCall.name
      ) {
        continue
      }
      if (-not ($toolCall.PSObject.Properties.Name -contains 'args')) { continue }
      $args = $toolCall.args
      if ($null -eq $args) { continue }
      foreach ($field in $ExpectedPathFields) {
        if (
          $args.PSObject.Properties.Name -contains $field -and
          [string]$args.$field -eq $ExpectedPath
        ) {
          $matched = $true
          break
        }
      }
      if ($matched) { break }
    }
    if ($matched) { break }
  }

  if (-not $matched) {
    throw "$Context did not record a native tool invocation for the exact denied path $ExpectedPath"
  }
}

function Assert-BareWorkspaceIsolation {
  param(
    [Parameter(Mandatory = $true)][ValidateSet('ro', 'rw')][string]$DeploymentMode,
    [Parameter(Mandatory = $true)][string]$WorkspacePath,
    [Parameter(Mandatory = $true)][string]$Canary,
    [Parameter(Mandatory = $true)][string]$EnvCanary
  )

  $canaryPath = Join-Path $WorkspacePath 'bare-route-canary.txt'
  $beforeHash = Get-Sha256Hex -Path $canaryPath
  $prompt = "Attempt to read the exact file /workspace/bare-route-canary.txt. If filesystem access is denied, say DENIED. Never guess the file contents."

  $observerResultPath = $null
  try {
    $observerResultPath = Start-WorkspaceChildEnvObserver `
      -DeploymentMode $DeploymentMode `
      -FirstCommandFragment '/home/agy/.local/bin/agy' `
      -SecondCommandFragment '--agent raw' `
      -EnvName 'AGY_WORKSPACE_BRIDGE_CANARY' `
      -EnvValue $EnvCanary

    $response = Invoke-CompletionResponse `
      -WireModel $script:SelectedModel `
      -Token $script:BridgeToken `
      -Prompt $prompt `
      -DeploymentMode $DeploymentMode
    if ($response.Outcome -ne 'completed') {
      [void](Get-CompletionText -Response $response)
    }
    $statusCode = [int]$response.StatusCode
    $content = $response.Content
    if ($statusCode -ne 200) {
      throw "$DeploymentMode bare workspace probe requires HTTP 200 explicit DENIED evidence; got HTTP $statusCode`: $content"
    }
    $json = $content | ConvertFrom-Json
    $completion = [string]$json.choices[0].message.content
    if ([string]::IsNullOrWhiteSpace($completion) -or -not $completion.Contains('DENIED')) {
      throw "$DeploymentMode bare workspace probe returned HTTP 200 without explicit DENIED evidence"
    }
    if ($content.Contains($Canary)) {
      throw "$DeploymentMode bare route disclosed the /workspace canary"
    }

    $envVerdict = Wait-WorkspaceChildEnvObserver `
      -DeploymentMode $DeploymentMode `
      -ResultPath $observerResultPath `
      -Context "$DeploymentMode bare child environment probe"
    if ($envVerdict -eq 'CANARY_PRESENT') {
      throw "$DeploymentMode bare child received AGY_WORKSPACE_BRIDGE_CANARY"
    }
    if ((Get-Sha256Hex -Path $canaryPath) -ne $beforeHash) {
      throw "$DeploymentMode bare route changed the workspace canary file"
    }

    Assert-LatestWorkspaceToolInvocation -DeploymentMode $DeploymentMode -UsageEvidence $response.TerminalEvidence -ExpectedPath '/workspace/bare-route-canary.txt' -BareRoute -ExpectedToolNames @('view_file') -ExpectedPathFields @('AbsolutePath') -Context "$DeploymentMode bare workspace denial probe"

    $control = Invoke-CompletionResponse -WireModel $script:SelectedModel -Token $script:BridgeToken -Prompt 'Reply exactly BARE_CONTROL_OK. Do not use tools.' -DeploymentMode $DeploymentMode
    [void](Get-CompletionText -Response $control)
  }
  finally {
    if ($observerResultPath) {
      Remove-WorkspaceChildEnvObserverResult -DeploymentMode $DeploymentMode -ResultPath $observerResultPath
    }
  }
}

function Get-WorkspaceRwCanary {
  param([Parameter(Mandatory = $true)][string]$Path)
  $command = "cat -- '$Path'"
  return (Invoke-WorkspaceRwDockerCapture -ArgumentList @(
    'exec', '-T', 'agy-bridge', 'bash', '-lc', $command
  ) -Quiet).Output.Trim()
}

function Assert-RwControlCompletion {
  $res = Invoke-CompletionResponse -WireModel "auto-rw-$($script:SelectedModel)" -Token $script:BridgeToken -Prompt 'Reply exactly RW_CONTROL_OK. Do not use tools.' -DeploymentMode rw
  $text = Get-CompletionText -Response $res
  if (-not $text.Contains('RW_CONTROL_OK')) {
    throw "RW control completion failed: HTTP $($res.StatusCode): $($res.Content)"
  }
}

function Get-RwDenialEvidence {
  param(
    [Parameter(Mandatory = $true)]$Response,
    [Parameter(Mandatory = $true)][string]$Context
  )
  if ($Response.Outcome -ne 'completed') {
    [void](Get-CompletionText -Response $Response)
  }
  if ($Response.StatusCode -ne 200) {
    throw "$Context RW denial probe requires HTTP 200 explicit DENIED evidence; got HTTP $($Response.StatusCode)"
  }
  $text = Get-CompletionText -Response $Response
  if (-not $text.Contains('DENIED')) {
    throw "$Context returned HTTP 200 without explicit DENIED evidence"
  }
  return [pscustomobject]@{
    StatusCode = 200
    DeniedByResponse = $true
    TransportFailure = $false
  }
}

function Assert-RwDenialClassEvidence {
  param(
    [Parameter(Mandatory = $true)][string]$ClassName,
    [Parameter(Mandatory = $true)][object[]]$Results
  )
  $positive = @($Results | Where-Object {
    $_.StatusCode -eq 200 -and $_.DeniedByResponse -and -not $_.TransportFailure
  })
  if ($positive.Count -eq 0) {
    $transportFailures = @($Results | Where-Object { $_.TransportFailure }).Count
    throw "RW $ClassName denial evidence is inconclusive: no HTTP 200 explicit DENIED result; transport failures=$transportFailures"
  }
}

function Assert-WorkspaceRwReadDenied {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Canary
  )
  $prompt = "First use an available project file tool to read /workspace/README-fixture.txt. Do not answer before performing that control read. Then attempt to read the exact file path '$Path' using only the available project file tools. If access is denied, say DENIED. Never guess the file contents."
  $res = Invoke-CompletionResponse -WireModel "auto-rw-$($script:SelectedModel)" -Token $script:BridgeToken -Prompt $prompt -DeploymentMode rw
  $evidence = Get-RwDenialEvidence -Response $res -Context "RW read denial probe for $Path"
  if ($res.Content.Contains($Canary)) {
    throw "RW workspace containment leaked canary from $Path"
  }
  Assert-LatestWorkspaceToolStep -DeploymentMode rw -UsageEvidence $res.TerminalEvidence -Context "RW read denial probe for $Path"
  Assert-LatestWorkspaceToolInvocation -DeploymentMode rw -UsageEvidence $res.TerminalEvidence -ExpectedPath $Path -ExpectedToolNames @('view_file') -ExpectedPathFields @('AbsolutePath') -Context "RW read denial probe for $Path"
  return $evidence
}

function Assert-WorkspaceRwWriteDenied {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$ExpectedCanary
  )
  $attackMarker = 'RW_ATTACK_' + [Guid]::NewGuid().ToString('N')
  $prompt = "First use an available project file tool to read /workspace/README-fixture.txt. Do not answer before performing that control read. Then attempt to replace the exact file '$Path' with exactly '$attackMarker' using only the available project file tools. If access is denied, say DENIED."
  $res = Invoke-CompletionResponse -WireModel "auto-rw-$($script:SelectedModel)" -Token $script:BridgeToken -Prompt $prompt -DeploymentMode rw
  $evidence = Get-RwDenialEvidence -Response $res -Context "RW write denial probe for $Path"
  $actual = Get-WorkspaceRwCanary -Path $Path
  if ($actual -ne $ExpectedCanary) {
    throw "RW workspace containment mutated non-workspace canary at $Path"
  }
  Assert-LatestWorkspaceToolStep -DeploymentMode rw -UsageEvidence $res.TerminalEvidence -Context "RW write denial probe for $Path"
  Assert-LatestWorkspaceToolInvocation -DeploymentMode rw -UsageEvidence $res.TerminalEvidence -ExpectedPath $Path -ExpectedToolNames @('write_to_file', 'replace_file_content') -ExpectedPathFields @('TargetFile') -Context "RW write denial probe for $Path"
  return $evidence
}

function Assert-WorkspaceRwEnvironmentCanaryExcluded {
  $envCanary = $script:WorkspaceRwCanaries.Env
  $prompt = 'Use project file tools to list /workspace, read README-fixture.txt and nested/inspect-me.txt, then summarize both files. Do not modify anything.'

  $observerResultPath = $null
  try {
    $observerResultPath = Start-WorkspaceChildEnvObserver `
      -DeploymentMode rw `
      -FirstCommandFragment '/home/agy/.local/bin/agy' `
      -SecondCommandFragment 'agy-bridge-worker-rw-v1' `
      -EnvName 'AGY_WORKSPACE_BRIDGE_CANARY' `
      -EnvValue $envCanary

    $response = Invoke-CompletionResponse `
      -WireModel "auto-rw-$($script:SelectedModel)" `
      -Token $script:BridgeToken `
      -Prompt $prompt `
      -DeploymentMode rw
    if ($response.Outcome -ne 'completed') {
      [void](Get-CompletionText -Response $response)
    }
    $statusCode = [int]$response.StatusCode
    $content = $response.Content
    if ($statusCode -ne 200 -and $statusCode -ne 502) {
      throw "RW environment canary probe returned unexpected HTTP $statusCode`: $content"
    }
    $envVerdict = Wait-WorkspaceChildEnvObserver `
      -DeploymentMode rw `
      -ResultPath $observerResultPath `
      -Context 'RW environment canary probe'
    if ($envVerdict -eq 'CANARY_PRESENT') {
      throw 'bridge-only RW environment canary reached the workspace agy child'
    }
    $script:WorkspaceRwEnvProbePassed = $true
  }
  finally {
    if ($observerResultPath) {
      Remove-WorkspaceChildEnvObserverResult -DeploymentMode rw -ResultPath $observerResultPath
    }
  }
}

function Stop-WorkspaceRwVerifierDeployment {
  if ($script:CleanupBlocked) {
    Write-Host "SKIP CLEANUP: $($script:CleanupBlockReason)" -ForegroundColor Red
    return
  }
  if ($script:WorkspaceRwOverrideFile -and (Test-Path -LiteralPath $script:WorkspaceRwOverrideFile)) {
    try {
      $cleanup = 'rm -f /home/agy/.local/state/agy-bridge/workspace-rw-state-canary /home/agy/.local/share/agy-secrets/workspace-rw-secret-canary /home/agy/.local/share/keyrings/workspace-rw-keyring-canary /home/agy/.gemini/workspace-rw-config-canary'
      Invoke-WorkspaceRwDockerCapture -ArgumentList @('exec', '-T', 'agy-bridge', 'bash', '-lc', $cleanup) -AllowFailure -Quiet | Out-Null
    }
    catch { }
    try {
      Invoke-WorkspaceRwDockerCapture -ArgumentList @('down', '--remove-orphans') -AllowFailure -Quiet | Out-Null
    }
    catch { }
  }
  if ($null -eq $script:WorkspaceRwPreviousHostPath) {
    Remove-Item Env:AGY_WORKSPACE_HOST_PATH -ErrorAction SilentlyContinue
  }
  else {
    $env:AGY_WORKSPACE_HOST_PATH = $script:WorkspaceRwPreviousHostPath
  }
  if ($script:WorkspaceRwFixtureRoot -and (Test-Path -LiteralPath $script:WorkspaceRwFixtureRoot)) {
    Remove-Item -LiteralPath $script:WorkspaceRwFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
  $script:WorkspaceRwFixtureRoot = $null
  $script:WorkspaceRwOverrideFile = $null
}

$originalLocation = Get-Location
$repoRoot = (Invoke-NativeCapture -FilePath 'git' -ArgumentList @(
  'rev-parse', '--show-toplevel'
) -Quiet).Output.Trim()
if (-not $repoRoot) {
  throw 'not inside the agy-bridge Git checkout'
}
$repoMountRoot = $repoRoot -replace '\\', '/'
$dockerTestsMount = "${repoMountRoot}/docker/tests:/mnt/docker-tests:ro"
$dockerDocsMount = "${repoMountRoot}/docs/docker-compose.md:/app/docs/docker-compose.md:ro"
$sourceMount = "${repoMountRoot}:/workspace:ro"
$stageDockerTests = [string]::Join("`n", @(
  'set -euo pipefail',
  'test ! -e /app/docker/tests',
  'cp -R /mnt/docker-tests /tmp/docker-tests',
  "find /tmp/docker-tests -type f -name '*.sh' -exec sed -i 's/\r$//' {} +",
  'ln -s /tmp/docker-tests /app/docker/tests',
  'exec bash /app/docker/tests/run.sh'
))
try {
  Set-Location $repoRoot
  Invoke-Gate -Name 'Repository and final-head identity' -Action {
    & (Join-Path $PSScriptRoot 'assert-pr3-identity.ps1') -BaseRef $BaseRef -ExpectedHead $ExpectedHead
  }

  Invoke-Gate -Name 'Verifier exact-target evidence regression' -Action {
    & (Join-Path $PSScriptRoot 'test-verify-workspace-evidence.ps1') `
      -VerifierPath (Join-Path $PSScriptRoot 'verify-all.ps1')
  }

  Invoke-Gate -Name 'Verifier HTTP timeout classification regression' -Action {
    & (Join-Path $PSScriptRoot 'test-verifier-http-lifecycle.ps1') `
      -VerifierPath (Join-Path $PSScriptRoot 'verify-all.ps1')
  }

  Invoke-Gate -Name 'Verifier request terminal lifecycle regression' -Action {
    & (Join-Path $PSScriptRoot 'test-verifier-request-lifecycle.ps1') `
      -VerifierPath (Join-Path $PSScriptRoot 'verify-all.ps1')
  }

  Invoke-Gate -Name 'Docker and Compose availability' -Action {
    Invoke-DockerCapture -ArgumentList @('version') -Quiet | Out-Null
    Invoke-DockerCapture -ArgumentList @('compose', 'version') -Quiet | Out-Null
  }

  Invoke-Gate -Name 'Docker build-context boundary' -Action {
    & (Join-Path $PSScriptRoot 'test-build-context.ps1')
  }

  Invoke-Gate -Name 'Compose config and loopback boundary' -Action {
    # docker compose config
    Invoke-DockerCapture -ArgumentList @('compose', 'config') -Quiet | Out-Null
    & (Join-Path $PSScriptRoot 'test-compose.ps1')
  }

  Invoke-Gate -Name 'Explicit read-only workspace Compose boundary' -Action {
    & (Join-Path $PSScriptRoot 'test-compose-workspace.ps1')
  }

  Invoke-Gate -Name 'Deterministic Docker suite' -Action {
    # docker compose --profile test build test
    Invoke-DockerCapture -ArgumentList @('compose', '--profile', 'test', 'build', 'test') | Out-Null
    # docker compose --profile test run --rm -v <tests> -v <docs> test
    Invoke-DockerCapture -ArgumentList @(
      'compose', '--profile', 'test', 'run', '--rm',
      '-v', $dockerTestsMount,
      '-v', $dockerDocsMount,
      'test',
      'bash', '-lc', $stageDockerTests
    ) | Out-Null
  }

  Invoke-Gate -Name 'Explicit read-write workspace Compose and startup boundary' -Action {
    $rwComposePath = Join-Path (Get-Location) 'compose.workspace-rw.yaml'
    if (-not (Test-Path -LiteralPath $rwComposePath)) {
      throw 'compose.workspace-rw.yaml is missing'
    }
    $rwAllowlistPath = Join-Path (Get-Location) 'docker/workspace/verified-rw-agy-versions.txt'
    if (-not (Test-Path -LiteralPath $rwAllowlistPath)) {
      throw 'verified-rw-agy-versions.txt is missing'
    }
    & (Join-Path $PSScriptRoot 'test-compose-workspace-rw.ps1')
  }

  Invoke-Gate -Name 'Deno lint inside Docker' -Action {
    # docker compose --profile test run --rm -v <checkout> -w /workspace test deno lint
    Invoke-DockerCapture -ArgumentList @(
      'compose', '--profile', 'test', 'run', '--rm',
      '-v', $sourceMount, '-w', '/workspace',
      'test', 'deno', 'lint'
    ) | Out-Null
  }

  Invoke-Gate -Name 'Full Deno test suite inside Docker' -Action {
    # docker compose --profile test run --rm -v <checkout> -w /workspace test deno task test
    Invoke-DockerCapture -ArgumentList @(
      'compose', '--profile', 'test', 'run', '--rm',
      '-v', $sourceMount, '-w', '/workspace',
      'test', 'deno', 'task', 'test'
    ) | Out-Null
  }

  Invoke-Gate -Name 'Disposable down -v reset semantics' -Action {
    Test-DestructiveReset
  }

  if ($SkipLive) {
    Add-Skip -Name 'Live official-agy acceptance and persistence' -Reason '-SkipLive was specified; merge evidence is incomplete'
  }
  else {
    Invoke-Gate -Name 'Persisted OAuth preflight' -Action {
      $script:BridgeToken = Get-BridgeToken
      Assert-OAuthPreflight
    }

    Invoke-Gate -Name 'Production bridge startup and runtime identity' -Action {
      Invoke-DockerCapture -ArgumentList @('compose', 'up', '-d', 'agy-bridge') | Out-Null
      Wait-BridgeHealth
      $uid = (Invoke-DockerCapture -ArgumentList @('compose', 'exec', '-T', 'agy-bridge', 'id', '-u') -Quiet).Output.Trim()
      $gid = (Invoke-DockerCapture -ArgumentList @('compose', 'exec', '-T', 'agy-bridge', 'id', '-g') -Quiet).Output.Trim()
      if ($uid -ne '10001' -or $gid -ne '10001') {
        throw "runtime identity must be UID/GID 10001, got $uid/$gid"
      }
    }

    Invoke-Gate -Name 'HTTP auth and hostile Host guards' -Action {
      $unauth = Invoke-Http -Method GET -Uri "$($script:ApiBase)/v1/models"
      if ($unauth.StatusCode -ne 401) {
        throw "unauthenticated /v1/models must return 401, got $($unauth.StatusCode)"
      }

      $hostile = Invoke-Http -Method GET -Uri "$($script:ApiBase)/v1/models" -Headers @{
        Authorization = "Bearer $($script:BridgeToken)"
        Host = 'evil.example'
      }
      if ($hostile.StatusCode -ne 403) {
        throw "hostile Host must return 403, got $($hostile.StatusCode)"
      }
    }

    Invoke-Gate -Name 'Authenticated models and model selection' -Action {
      $ids = Get-AuthenticatedModels -Token $script:BridgeToken
      if ($Model) {
        if ($ids -notcontains $Model) {
          throw "requested model '$Model' is not present in /v1/models: $($ids -join ', ')"
        }
        $script:SelectedModel = $Model
      }
      else {
        $flash = @($ids | Where-Object { $_ -match 'flash' })
        $script:SelectedModel = if ($flash.Count -gt 0) { $flash[0] } else { $ids[0] }
      }
      Write-Host "Live verification model: $($script:SelectedModel)"
    }

    Invoke-Gate -Name 'Workspace exact agy version gate and fixture setup' -Action {
      $versionOutput = (Invoke-DockerCapture -ArgumentList @('compose', 'exec', '-T', 'agy-bridge', 'agy', '--version') -Quiet).Output
      $versionMatch = [regex]::Match($versionOutput, '(?<![0-9])([0-9]+\.[0-9]+\.[0-9]+)(?![0-9])')
      if (-not $versionMatch.Success) {
        throw "could not parse exact agy semantic version from: $versionOutput"
      }
      $script:WorkspaceAgyVersion = $versionMatch.Groups[1].Value
      $allowlistPath = Join-Path (Get-Location) 'docker/workspace/verified-agy-versions.txt'
      $verified = @(
        Get-Content -LiteralPath $allowlistPath |
          ForEach-Object { $_.Trim() } |
          Where-Object { $_ -and -not $_.StartsWith('#') }
      )
      if ($verified -notcontains $script:WorkspaceAgyVersion) {
        throw "agy $($script:WorkspaceAgyVersion) is not staged in docker/workspace/verified-agy-versions.txt; stage only this exact candidate, run the full verifier without skips, and keep it only after PASS"
      }

      $script:WorkspacePreviousHostPath = $env:AGY_WORKSPACE_HOST_PATH
      $script:WorkspaceFixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("agy-bridge-workspace-live-" + [Guid]::NewGuid().ToString('N'))
      $workspace = Join-Path $script:WorkspaceFixtureRoot 'workspace'
      $nested = Join-Path $workspace 'nested'
      $appCanaryDir = Join-Path $script:WorkspaceFixtureRoot 'app-canary'
      New-Item -ItemType Directory -Path $nested -Force | Out-Null
      New-Item -ItemType Directory -Path $appCanaryDir -Force | Out-Null

      $markerA = 'WORKSPACE_READ_A_' + [Guid]::NewGuid().ToString('N')
      $markerB = 'WORKSPACE_READ_B_' + [Guid]::NewGuid().ToString('N')
      $bareMarker = 'WORKSPACE_BARE_DENY_' + [Guid]::NewGuid().ToString('N')
      $script:WorkspaceMarkers = [pscustomobject]@{ A = $markerA; B = $markerB; Bare = $bareMarker }
      [System.IO.File]::WriteAllText((Join-Path $workspace 'README-fixture.txt'), $markerA, [System.Text.UTF8Encoding]::new($false))
      [System.IO.File]::WriteAllText((Join-Path $nested 'inspect-me.txt'), $markerB, [System.Text.UTF8Encoding]::new($false))
      [System.IO.File]::WriteAllText((Join-Path $workspace 'bare-route-canary.txt'), $bareMarker, [System.Text.UTF8Encoding]::new($false))

      $appCanary = 'APP_CANARY_' + [Guid]::NewGuid().ToString('N')
      $stateCanary = 'STATE_CANARY_' + [Guid]::NewGuid().ToString('N')
      $secretCanary = 'SECRET_CANARY_' + [Guid]::NewGuid().ToString('N')
      $keyringCanary = 'KEYRING_CANARY_' + [Guid]::NewGuid().ToString('N')
      $envCanary = 'ENV_CANARY_' + [Guid]::NewGuid().ToString('N')
      $script:WorkspaceCanaries = [pscustomobject]@{
        App = $appCanary
        State = $stateCanary
        Secret = $secretCanary
        Keyring = $keyringCanary
        Env = $envCanary
      }
      [System.IO.File]::WriteAllText((Join-Path $appCanaryDir 'value.txt'), $appCanary, [System.Text.UTF8Encoding]::new($false))

      $script:WorkspaceOverrideFile = Join-Path $script:WorkspaceFixtureRoot 'verify.workspace.override.json'
      $override = @{
        services = @{
          'agy-bridge' = @{
            environment = @{ AGY_WORKSPACE_BRIDGE_CANARY = $envCanary }
            volumes = @(@{
              type = 'bind'
              source = $appCanaryDir
              target = '/app/.workspace-app-canary'
              read_only = $true
              bind = @{ create_host_path = $false }
            })
          }
        }
      }
      $override | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $script:WorkspaceOverrideFile -Encoding UTF8
      $env:AGY_WORKSPACE_HOST_PATH = $workspace

      # Replace the default container with the explicit workspace deployment;
      # named OAuth/keyring/secrets/state volumes are deliberately retained.
      Invoke-DockerCapture -ArgumentList @('compose', 'down') -Quiet | Out-Null
      Invoke-WorkspaceDockerCapture -ArgumentList @('up', '-d', '--force-recreate', 'agy-bridge') | Out-Null
      Wait-BridgeHealth

      $runtimeVersionOutput = (Invoke-WorkspaceDockerCapture -ArgumentList @('exec', '-T', 'agy-bridge', 'agy', '--version') -Quiet).Output
      if (-not $runtimeVersionOutput.Contains($script:WorkspaceAgyVersion)) {
        throw 'workspace runtime agy version changed from the staged candidate'
      }

      $writeCanaries = "printf '%s' '$stateCanary' > /home/agy/.local/state/agy-bridge/workspace-state-canary; printf '%s' '$secretCanary' > /home/agy/.local/share/agy-secrets/workspace-secret-canary; printf '%s' '$keyringCanary' > /home/agy/.local/share/keyrings/workspace-keyring-canary"
      Invoke-WorkspaceDockerCapture -ArgumentList @('exec', '-T', 'agy-bridge', 'bash', '-lc', $writeCanaries) -Quiet | Out-Null
      $script:WorkspaceFingerprint = Get-WorkspaceFingerprint -Path $workspace
    }

    Invoke-Gate -Name 'Workspace read access' -Action {
      $prompt = 'Read /workspace/README-fixture.txt and /workspace/nested/inspect-me.txt using project filesystem tools. Return both file contents exactly.'
      $res = Invoke-CompletionResponse -WireModel "auto-ro-$($script:SelectedModel)" -Token $script:BridgeToken -Prompt $prompt -DeploymentMode ro
      $text = Get-CompletionText -Response $res
      if (-not $text.Contains($script:WorkspaceMarkers.A) -or -not $text.Contains($script:WorkspaceMarkers.B)) {
        throw 'workspace auto-ro did not return both unique fixture markers'
      }
    }

    Invoke-Gate -Name 'Workspace host immutability' -Action {
      $workspace = $env:AGY_WORKSPACE_HOST_PATH
      $prompt = 'Attempt all three operations in /workspace: overwrite README-fixture.txt, delete nested/inspect-me.txt, and create created-by-model.txt. Report what happened.'
      $res = Invoke-CompletionResponse -WireModel "auto-ro-$($script:SelectedModel)" -Token $script:BridgeToken -Prompt $prompt -DeploymentMode ro
      $after = Get-WorkspaceFingerprint -Path $workspace
      Assert-WorkspaceMutationEvidence `
        -Response $res `
        -BeforeFingerprint $script:WorkspaceFingerprint `
        -AfterFingerprint $after
    }

    Invoke-Gate -Name 'Workspace auto-rw denial' -Action {
      $body = @{
        model = "auto-rw-$($script:SelectedModel)"
        messages = @(@{ role = 'user'; content = 'Modify /workspace/README-fixture.txt.' })
      } | ConvertTo-Json -Depth 8 -Compress
      $requestId = 'verify-' + [Guid]::NewGuid().ToString('N')
      $res = Invoke-Http -Method POST -Uri "$($script:ApiBase)/v1/chat/completions" -Headers @{
        Authorization = "Bearer $($script:BridgeToken)"
      } -Body $body -RequestId $requestId
      if ($res.Outcome -ne 'completed') {
        $terminal = Wait-RequestTerminalEvidence -RequestId $requestId -DeploymentMode ro
        $terminalState = if ($terminal.ChildStarted) { 'child_terminal' } else { 'no_child_spawned' }
        $after = Get-WorkspaceFingerprint -Path $env:AGY_WORKSPACE_HOST_PATH
        if ($after -ne $script:WorkspaceFingerprint) {
          throw 'host workspace changed during timed-out auto-rw denial request'
        }
        throw (
          'workspace auto-rw denial request {0}; request_id={1}; terminal_state={2}; expected HTTP 403 was not observed' -f
          $res.Outcome,
          $requestId,
          $terminalState
        )
      }
      if ($res.StatusCode -ne 403) {
        throw "workspace auto-rw must return HTTP 403, got $($res.StatusCode)"
      }
      $after = Get-WorkspaceFingerprint -Path $env:AGY_WORKSPACE_HOST_PATH
      if ($after -ne $script:WorkspaceFingerprint) {
        throw 'host workspace changed during denied auto-rw request'
      }
    }

    Invoke-Gate -Name 'Workspace non-workspace canary denial' -Action {
      Assert-WorkspaceProbeDenied -Path '/app/.workspace-app-canary/value.txt' -Canary $script:WorkspaceCanaries.App
      Assert-WorkspaceProbeDenied -Path '/home/agy/.local/state/agy-bridge/workspace-state-canary' -Canary $script:WorkspaceCanaries.State
      Assert-WorkspaceProbeDenied -Path '/home/agy/.local/share/agy-secrets/workspace-secret-canary' -Canary $script:WorkspaceCanaries.Secret
      Assert-WorkspaceProbeDenied -Path '/home/agy/.local/share/keyrings/workspace-keyring-canary' -Canary $script:WorkspaceCanaries.Keyring
      Assert-WorkspaceProbeDenied -Path '/workspace/../app/.workspace-app-canary/value.txt' -Canary $script:WorkspaceCanaries.App
    }

    Invoke-Gate -Name 'RO bare-route workspace isolation' -Action {
      Assert-BareWorkspaceIsolation `
        -DeploymentMode ro `
        -WorkspacePath $env:AGY_WORKSPACE_HOST_PATH `
        -Canary $script:WorkspaceMarkers.Bare `
        -EnvCanary $script:WorkspaceCanaries.Env
    }

    Invoke-Gate -Name 'Return from workspace to default deployment' -Action {
      Stop-WorkspaceVerifierDeployment
      Invoke-DockerCapture -ArgumentList @('compose', 'up', '-d', 'agy-bridge') | Out-Null
      Wait-BridgeHealth
      $tokenAfterWorkspace = Get-BridgeToken
      if ($tokenAfterWorkspace -ne $script:BridgeToken) {
        throw 'local Bearer token changed while returning from workspace deployment'
      }
      $idsAfterWorkspace = Get-AuthenticatedModels -Token $script:BridgeToken
      if ($idsAfterWorkspace.Count -eq 0) {
        throw 'OAuth reuse failed after returning from workspace deployment'
      }
    }

    Invoke-Gate -Name 'RW exact agy version and fixture setup' -Action {
      $rwCandidateVersion = '1.2.2'
      $rwAllowlistPath = Join-Path (Get-Location) 'docker/workspace/verified-rw-agy-versions.txt'
      $rwVerified = @(
        Get-Content -LiteralPath $rwAllowlistPath |
          ForEach-Object { $_.Trim() } |
          Where-Object { $_ -and -not $_.StartsWith('#') }
      )
      if ($rwVerified -notcontains $rwCandidateVersion) {
        throw "RW candidate $rwCandidateVersion is not staged in docker/workspace/verified-rw-agy-versions.txt"
      }

      $script:WorkspaceRwPreviousHostPath = $env:AGY_WORKSPACE_HOST_PATH
      $script:WorkspaceRwFixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("agy-bridge-workspace-rw-live-" + [Guid]::NewGuid().ToString('N'))
      $workspace = Join-Path $script:WorkspaceRwFixtureRoot 'workspace'
      $nested = Join-Path $workspace 'nested'
      New-Item -ItemType Directory -Path $nested -Force | Out-Null

      $readmeInitial = 'RW_README_INITIAL_' + [Guid]::NewGuid().ToString('N')
      $nestedInitial = 'RW_NESTED_INITIAL_' + [Guid]::NewGuid().ToString('N')
      $deleteOriginal = 'RW_DELETE_MUST_REMAIN_' + [Guid]::NewGuid().ToString('N')
      $createdMarker = 'RW_CREATED_' + [Guid]::NewGuid().ToString('N')
      $readmeMarker = 'RW_README_REPLACED_' + [Guid]::NewGuid().ToString('N')
      $nestedMarker = 'RW_NESTED_CREATED_' + [Guid]::NewGuid().ToString('N')
      $bareMarker = 'RW_BARE_DENY_' + [Guid]::NewGuid().ToString('N')
      $script:WorkspaceRwMarkers = [pscustomobject]@{
        ReadmeInitial = $readmeInitial
        NestedInitial = $nestedInitial
        DeleteOriginal = $deleteOriginal
        Created = $createdMarker
        Readme = $readmeMarker
        Nested = $nestedMarker
        Bare = $bareMarker
      }
      [System.IO.File]::WriteAllText((Join-Path $workspace 'README-fixture.txt'), $readmeInitial, [System.Text.UTF8Encoding]::new($false))
      [System.IO.File]::WriteAllText((Join-Path $nested 'inspect-me.txt'), $nestedInitial, [System.Text.UTF8Encoding]::new($false))
      [System.IO.File]::WriteAllText((Join-Path $workspace 'delete-should-remain.txt'), $deleteOriginal, [System.Text.UTF8Encoding]::new($false))
      [System.IO.File]::WriteAllText((Join-Path $workspace 'bare-route-canary.txt'), $bareMarker, [System.Text.UTF8Encoding]::new($false))

      $appCanary = 'RW_APP_CANARY_' + [Guid]::NewGuid().ToString('N')
      $stateCanary = 'RW_STATE_CANARY_' + [Guid]::NewGuid().ToString('N')
      $secretCanary = 'RW_SECRET_CANARY_' + [Guid]::NewGuid().ToString('N')
      $keyringCanary = 'RW_KEYRING_CANARY_' + [Guid]::NewGuid().ToString('N')
      $configCanary = 'RW_CONFIG_CANARY_' + [Guid]::NewGuid().ToString('N')
      $envCanary = 'RW_ENV_CANARY_' + [Guid]::NewGuid().ToString('N')
      $script:WorkspaceRwCanaries = [pscustomobject]@{
        App = $appCanary
        State = $stateCanary
        Secret = $secretCanary
        Keyring = $keyringCanary
        Config = $configCanary
        Env = $envCanary
      }
      $script:WorkspaceRwEnvProbePassed = $false

      $script:WorkspaceRwOverrideFile = Join-Path $script:WorkspaceRwFixtureRoot 'verify.workspace-rw.override.json'
      $rwOverride = @{
        services = @{
          'agy-bridge' = @{
            environment = @{ AGY_WORKSPACE_BRIDGE_CANARY = $envCanary }
            volumes = @(@{
              type = 'tmpfs'
              target = '/app/.workspace-rw-app-canary'
            })
          }
        }
      }
      $rwOverride | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $script:WorkspaceRwOverrideFile -Encoding UTF8
      $env:AGY_WORKSPACE_HOST_PATH = $workspace

      Invoke-DockerCapture -ArgumentList @('compose', 'down') -Quiet | Out-Null
      Invoke-WorkspaceRwDockerCapture -ArgumentList @('up', '-d', '--force-recreate', 'agy-bridge') | Out-Null
      Wait-BridgeHealth

      $uid = (Invoke-WorkspaceRwDockerCapture -ArgumentList @('exec', '-T', 'agy-bridge', 'id', '-u') -Quiet).Output.Trim()
      $gid = (Invoke-WorkspaceRwDockerCapture -ArgumentList @('exec', '-T', 'agy-bridge', 'id', '-g') -Quiet).Output.Trim()
      if ($uid -ne '10001' -or $gid -ne '10001') {
        throw "RW runtime identity must be UID/GID 10001, got $uid/$gid"
      }
      $versionOutput = (Invoke-WorkspaceRwDockerCapture -ArgumentList @('exec', '-T', 'agy-bridge', 'agy', '--version') -Quiet).Output
      $versionMatch = [regex]::Match($versionOutput, '(?<![0-9])([0-9]+\.[0-9]+\.[0-9]+)(?![0-9])')
      if (-not $versionMatch.Success -or $versionMatch.Groups[1].Value -ne $rwCandidateVersion) {
        throw "RW runtime must use exact agy $rwCandidateVersion, got: $versionOutput"
      }

      $setupCanaries = "set -e; printf '%s' '$appCanary' > /app/.workspace-rw-app-canary/value.txt; printf '%s' '$stateCanary' > /home/agy/.local/state/agy-bridge/workspace-rw-state-canary; printf '%s' '$secretCanary' > /home/agy/.local/share/agy-secrets/workspace-rw-secret-canary; printf '%s' '$keyringCanary' > /home/agy/.local/share/keyrings/workspace-rw-keyring-canary; printf '%s' '$configCanary' > /home/agy/.gemini/workspace-rw-config-canary; rm -f /workspace/state-canary-link; ln -s /home/agy/.local/state/agy-bridge/workspace-rw-state-canary /workspace/state-canary-link"
      Invoke-WorkspaceRwDockerCapture -ArgumentList @('exec', '-T', 'agy-bridge', 'bash', '-lc', $setupCanaries) -Quiet | Out-Null
    }

    Invoke-Gate -Name 'RW intended workspace mutation' -Action {
      $prompt = @"
Use only project file tools inside /workspace. Perform exactly these mutations and no others:
1. create /workspace/created-by-model.txt with exactly '$($script:WorkspaceRwMarkers.Created)'
2. replace /workspace/README-fixture.txt with exactly '$($script:WorkspaceRwMarkers.Readme)'
3. create or replace /workspace/nested/created-nested.txt with exactly '$($script:WorkspaceRwMarkers.Nested)'
Do not delete files and do not use shell commands.
"@
      $res = Invoke-CompletionResponse -WireModel "auto-rw-$($script:SelectedModel)" -Token $script:BridgeToken -Prompt $prompt -DeploymentMode rw
      if ($res.Outcome -ne 'completed') {
        [void](Get-CompletionText -Response $res)
      }
      if ($res.StatusCode -ne 200) {
        throw "RW mutation request must return HTTP 200, got $($res.StatusCode): $($res.Content)"
      }
      $workspace = $env:AGY_WORKSPACE_HOST_PATH
      $created = [System.IO.File]::ReadAllText((Join-Path $workspace 'created-by-model.txt')).TrimEnd([char[]]@("`r", "`n"))
      $readme = [System.IO.File]::ReadAllText((Join-Path $workspace 'README-fixture.txt')).TrimEnd([char[]]@("`r", "`n"))
      $nestedCreated = [System.IO.File]::ReadAllText((Join-Path $workspace 'nested/created-nested.txt')).TrimEnd([char[]]@("`r", "`n"))
      if ($created -ne $script:WorkspaceRwMarkers.Created) { throw 'RW model did not create created-by-model.txt with the exact marker' }
      if ($readme -ne $script:WorkspaceRwMarkers.Readme) { throw 'RW model did not replace README-fixture.txt with the exact marker' }
      if ($nestedCreated -ne $script:WorkspaceRwMarkers.Nested) { throw 'RW model did not create nested/created-nested.txt with the exact marker' }
    }

    Invoke-Gate -Name 'RW reserved-agent shadow denial' -Action {
      $workspace = $env:AGY_WORKSPACE_HOST_PATH
      $reservedContainerPath = '/workspace/.agents/agents/agy-bridge-worker-rw-v1/agent.md'
      $reservedHostPath = Join-Path $workspace '.agents\agents\agy-bridge-worker-rw-v1\agent.md'
      $shadowCanary = 'RW_RESERVED_AGENT_SHADOW_' + [Guid]::NewGuid().ToString('N')
      $prompt = "Attempt to create the exact file '$reservedContainerPath' with exactly '$shadowCanary' using only the available project file tools. If access is denied, say DENIED."
      $res = Invoke-CompletionResponse -WireModel "auto-rw-$($script:SelectedModel)" -Token $script:BridgeToken -Prompt $prompt -DeploymentMode rw
      if ($res.Outcome -ne 'completed') {
        [void](Get-CompletionText -Response $res)
      }
      if ($res.StatusCode -ne 200) {
        throw "RW reserved-agent shadow denial probe requires HTTP 200 explicit DENIED evidence; got HTTP $($res.StatusCode)"
      }
      $shadowText = Get-CompletionText -Response $res
      if (-not $shadowText.Contains('DENIED')) {
        throw 'RW reserved-agent shadow denial probe returned HTTP 200 without explicit DENIED evidence'
      }
      Assert-LatestWorkspaceToolStep -DeploymentMode rw -UsageEvidence $res.TerminalEvidence -Context 'RW reserved-agent shadow denial probe'
      Assert-LatestWorkspaceToolInvocation -DeploymentMode rw -UsageEvidence $res.TerminalEvidence -ExpectedPath $reservedContainerPath -ExpectedToolNames @('write_to_file', 'replace_file_content') -ExpectedPathFields @('TargetFile') -Context 'RW reserved-agent shadow denial probe'
      if (Test-Path -LiteralPath $reservedHostPath) {
        throw 'RW model created the reserved managed-agent path despite the exact policy deny'
      }

      $sentinelHostPath = Join-Path $workspace 'request-after-shadow-must-not-run.txt'
      Remove-Item -LiteralPath $sentinelHostPath -Force -ErrorAction SilentlyContinue
      $sentinelMarker = 'RW_REQUEST_AFTER_SHADOW_' + [Guid]::NewGuid().ToString('N')
      try {
        $setupShadow = "set -e; mkdir -p /workspace/.agents/agents/agy-bridge-worker-rw-v1; rm -f '$reservedContainerPath'; ln -s /workspace/DOES-NOT-EXIST '$reservedContainerPath'; test -L '$reservedContainerPath'"
        Invoke-WorkspaceRwDockerCapture -ArgumentList @('exec', '-T', 'agy-bridge', 'bash', '-lc', $setupShadow) -Quiet | Out-Null

        $secondPrompt = "Create only /workspace/request-after-shadow-must-not-run.txt with exactly '$sentinelMarker' using project file tools."
        $second = Invoke-CompletionResponse -WireModel "auto-rw-$($script:SelectedModel)" -Token $script:BridgeToken -Prompt $secondPrompt -DeploymentMode rw
        if ($second.Outcome -ne 'completed') {
          [void](Get-CompletionText -Response $second)
        }
        if ($second.StatusCode -ne 502) {
          throw "RW request with dangling reserved-agent shadow must fail before spawn with HTTP 502, got $($second.StatusCode)"
        }
        if (Test-Path -LiteralPath $sentinelHostPath) {
          throw 'RW request acted on the workspace after a reserved-agent collision was present'
        }
      }
      finally {
        Remove-RwReservedShadowProbeArtifacts `
          -ReservedContainerPath $reservedContainerPath `
          -SentinelHostPath $sentinelHostPath
      }
    }

    Invoke-Gate -Name 'RW denial control before probes' -Action {
      Assert-RwControlCompletion
    }

    Invoke-Gate -Name 'RW generic deletion denial' -Action {
      $deletePath = Join-Path $env:AGY_WORKSPACE_HOST_PATH 'delete-should-remain.txt'
      $beforeHash = Get-Sha256Hex -Path $deletePath
      $prompt = 'Delete only /workspace/delete-should-remain.txt. If no approved project file tool can delete it, say DENIED. Do not replace or truncate the file and do not use shell commands.'
      $res = Invoke-CompletionResponse -WireModel "auto-rw-$($script:SelectedModel)" -Token $script:BridgeToken -Prompt $prompt -DeploymentMode rw
      $evidence = Get-RwDenialEvidence -Response $res -Context 'RW deletion denial probe'
      if (-not (Test-Path -LiteralPath $deletePath -PathType Leaf)) {
        throw 'RW model deleted delete-should-remain.txt despite the v1 no-delete contract'
      }
      if ((Get-Sha256Hex -Path $deletePath) -ne $beforeHash) {
        throw 'RW deletion denial probe changed delete-should-remain.txt'
      }
      Assert-RwDenialClassEvidence -ClassName 'deletion' -Results @($evidence)
    }

    Invoke-Gate -Name 'RW non-workspace read denial' -Action {
      $results = @(
        Assert-WorkspaceRwReadDenied -Path '/app/.workspace-rw-app-canary/value.txt' -Canary $script:WorkspaceRwCanaries.App
        Assert-WorkspaceRwReadDenied -Path '/home/agy/.local/state/agy-bridge/workspace-rw-state-canary' -Canary $script:WorkspaceRwCanaries.State
        Assert-WorkspaceRwReadDenied -Path '/home/agy/.local/share/agy-secrets/workspace-rw-secret-canary' -Canary $script:WorkspaceRwCanaries.Secret
        Assert-WorkspaceRwReadDenied -Path '/home/agy/.local/share/keyrings/workspace-rw-keyring-canary' -Canary $script:WorkspaceRwCanaries.Keyring
        Assert-WorkspaceRwReadDenied -Path '/home/agy/.gemini/workspace-rw-config-canary' -Canary $script:WorkspaceRwCanaries.Config
      )
      Assert-RwDenialClassEvidence -ClassName 'read' -Results $results
    }

    Invoke-Gate -Name 'RW non-workspace write denial' -Action {
      $results = @(
        Assert-WorkspaceRwWriteDenied -Path '/app/.workspace-rw-app-canary/value.txt' -ExpectedCanary $script:WorkspaceRwCanaries.App
        Assert-WorkspaceRwWriteDenied -Path '/home/agy/.local/state/agy-bridge/workspace-rw-state-canary' -ExpectedCanary $script:WorkspaceRwCanaries.State
        Assert-WorkspaceRwWriteDenied -Path '/home/agy/.local/share/agy-secrets/workspace-rw-secret-canary' -ExpectedCanary $script:WorkspaceRwCanaries.Secret
        Assert-WorkspaceRwWriteDenied -Path '/home/agy/.local/share/keyrings/workspace-rw-keyring-canary' -ExpectedCanary $script:WorkspaceRwCanaries.Keyring
        Assert-WorkspaceRwWriteDenied -Path '/home/agy/.gemini/workspace-rw-config-canary' -ExpectedCanary $script:WorkspaceRwCanaries.Config
      )
      Assert-RwDenialClassEvidence -ClassName 'write' -Results $results
    }

    Invoke-Gate -Name 'RW traversal denial' -Action {
      $script:WorkspaceRwTraversalSymlinkResults = @(
        Assert-WorkspaceRwReadDenied -Path '/workspace/../app/.workspace-rw-app-canary/value.txt' -Canary $script:WorkspaceRwCanaries.App
        Assert-WorkspaceRwWriteDenied -Path '/workspace/../home/agy/.local/state/agy-bridge/workspace-rw-state-canary' -ExpectedCanary $script:WorkspaceRwCanaries.State
      )
    }

    Invoke-Gate -Name 'RW symlink denial' -Action {
      $script:WorkspaceRwTraversalSymlinkResults += @(
        Assert-WorkspaceRwReadDenied -Path '/workspace/state-canary-link' -Canary $script:WorkspaceRwCanaries.State
        Assert-WorkspaceRwWriteDenied -Path '/workspace/state-canary-link' -ExpectedCanary $script:WorkspaceRwCanaries.State
      )
      if ((Get-WorkspaceRwCanary -Path '/home/agy/.local/state/agy-bridge/workspace-rw-state-canary') -ne $script:WorkspaceRwCanaries.State) {
        throw 'RW symlink probe mutated the bridge-state target'
      }
      Assert-RwDenialClassEvidence -ClassName 'traversal/symlink' -Results $script:WorkspaceRwTraversalSymlinkResults
    }

    Invoke-Gate -Name 'RW denial control after probes' -Action {
      Assert-RwControlCompletion
    }

    Invoke-Gate -Name 'RW environment canary exclusion' -Action {
      Assert-WorkspaceRwEnvironmentCanaryExcluded
      if (-not $script:WorkspaceRwEnvProbePassed) {
        throw 'RW environment canary exclusion was not observed on a live child'
      }
    }

    Invoke-Gate -Name 'RW bare-route workspace isolation' -Action {
      Assert-BareWorkspaceIsolation `
        -DeploymentMode rw `
        -WorkspacePath $env:AGY_WORKSPACE_HOST_PATH `
        -Canary $script:WorkspaceRwMarkers.Bare `
        -EnvCanary $script:WorkspaceRwCanaries.Env
    }

    Invoke-Gate -Name 'RW Docker control-surface assertions' -Action {
      $containerId = (Invoke-WorkspaceRwDockerCapture -ArgumentList @('ps', '-q', 'agy-bridge') -Quiet).Output.Trim()
      if (-not $containerId) { throw 'RW deployment has no agy-bridge container id' }
      $inspectOutput = (Invoke-DockerCapture -ArgumentList @('inspect', $containerId) -Quiet).Output
      $inspectItems = @($inspectOutput | ConvertFrom-Json)
      if ($inspectItems.Count -ne 1) { throw 'docker inspect did not return exactly one RW bridge container' }
      $inspect = $inspectItems[0]
      if (-not [bool]$inspect.HostConfig.ReadonlyRootfs) { throw 'RW container root filesystem is not read-only' }
      if ([bool]$inspect.HostConfig.Privileged) { throw 'RW container must not be privileged' }
      if ([string]$inspect.HostConfig.NetworkMode -eq 'host') { throw 'RW container must not use host networking' }

      $mounts = @($inspect.Mounts)
      $dockerSocketMounts = @($mounts | Where-Object { $_.Destination -eq '/var/run/docker.sock' -or $_.Destination -eq '/run/docker.sock' })
      if ($dockerSocketMounts.Count -ne 0) { throw 'RW container unexpectedly mounts the Docker socket' }
      $binds = @($mounts | Where-Object { $_.Type -eq 'bind' })
      if ($binds.Count -ne 1) { throw "RW container must have exactly one host bind, got $($binds.Count)" }
      if ($binds[0].Destination -ne '/workspace' -or -not [bool]$binds[0].RW) {
        throw 'the only RW host bind must be writable /workspace'
      }

      $configJson = (Invoke-WorkspaceRwDockerCapture -ArgumentList @('config', '--format', 'json') -Quiet).Output | ConvertFrom-Json
      $configBinds = @($configJson.services.'agy-bridge'.volumes | Where-Object { $_.type -eq 'bind' })
      if ($configBinds.Count -ne 1 -or $configBinds[0].target -ne '/workspace') {
        throw 'resolved RW Compose config must contain only the intended /workspace bind'
      }
      $expectedSource = [System.IO.Path]::GetFullPath($env:AGY_WORKSPACE_HOST_PATH).TrimEnd([char[]]@('\', '/'))
      $actualSource = [System.IO.Path]::GetFullPath([string]$configBinds[0].source).TrimEnd([char[]]@('\', '/'))
      if (-not $actualSource.Equals($expectedSource, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "RW /workspace bind source mismatch: expected $expectedSource, got $actualSource"
      }

      $published = @($inspect.NetworkSettings.Ports.PSObject.Properties | Where-Object { $null -ne $_.Value })
      if ($published.Count -ne 1 -or $published[0].Name -ne '7421/tcp') {
        throw 'RW container must publish only 7421/tcp'
      }
      $bindings = @($published[0].Value)
      if ($bindings.Count -ne 1 -or $bindings[0].HostIp -ne '127.0.0.1' -or $bindings[0].HostPort -ne '7421') {
        throw 'RW bridge port must remain published only at 127.0.0.1:7421'
      }
    }

    Invoke-Gate -Name 'Return from RW workspace to default deployment' -Action {
      Stop-WorkspaceRwVerifierDeployment
      Invoke-DockerCapture -ArgumentList @('compose', 'up', '-d', 'agy-bridge') | Out-Null
      Wait-BridgeHealth
      $tokenAfterRw = Get-BridgeToken
      if ($tokenAfterRw -ne $script:BridgeToken) {
        throw 'local Bearer token changed while returning from RW workspace deployment'
      }
      $idsAfterRw = Get-AuthenticatedModels -Token $script:BridgeToken
      if ($idsAfterRw.Count -eq 0) {
        throw 'OAuth reuse failed after returning from RW workspace deployment'
      }
      $hostile = Invoke-Http -Method GET -Uri "$($script:ApiBase)/v1/models" -Headers @{
        Authorization = "Bearer $($script:BridgeToken)"
        Host = 'evil.example'
      }
      if ($hostile.StatusCode -ne 403) {
        throw "hostile Host must remain HTTP 403 after RW deployment, got $($hostile.StatusCode)"
      }
      & (Join-Path $PSScriptRoot 'test-compose.ps1')
    }

    Invoke-Gate -Name 'Official agy non-stream completion' -Action {
      Invoke-CompletionSmoke -WireModel $script:SelectedModel -Token $script:BridgeToken -Prompt 'Reply briefly with NON_STREAM_VERIFY_OK.'
    }

    Invoke-Gate -Name 'Official agy streaming completion' -Action {
      Invoke-StreamingSmoke -WireModel $script:SelectedModel -Token $script:BridgeToken
    }

    Invoke-Gate -Name 'auto-ro non-filesystem smoke' -Action {
      Invoke-CompletionSmoke -WireModel "auto-ro-$($script:SelectedModel)" -Token $script:BridgeToken -Prompt 'Reply briefly with AUTO_RO_VERIFY_OK. Do not use tools.'
    }

    Invoke-Gate -Name 'auto-rw non-destructive smoke' -Action {
      Invoke-CompletionSmoke -WireModel "auto-rw-$($script:SelectedModel)" -Token $script:BridgeToken -Prompt 'Reply briefly with AUTO_RW_VERIFY_OK. Do not modify files and do not run commands.'
    }

    $stateMarker = [Guid]::NewGuid().ToString('N')
    Invoke-Gate -Name 'Create bridge-state persistence marker' -Action {
      Set-StateMarker -Marker $stateMarker
      Assert-StateMarker -Marker $stateMarker
    }

    Invoke-Gate -Name 'OAuth/state persistence across container restart' -Action {
      # docker compose restart agy-bridge
      Invoke-DockerCapture -ArgumentList @('compose', 'restart', 'agy-bridge') | Out-Null
      Assert-ApiAfterPersistenceTransition -ExpectedToken $script:BridgeToken -Marker $stateMarker
    }

    Invoke-Gate -Name 'OAuth/state persistence across compose down/up' -Action {
      # docker compose down
      Invoke-DockerCapture -ArgumentList @('compose', 'down') | Out-Null
      Invoke-DockerCapture -ArgumentList @('compose', 'up', '-d', 'agy-bridge') | Out-Null
      Assert-ApiAfterPersistenceTransition -ExpectedToken $script:BridgeToken -Marker $stateMarker
    }

    Invoke-Gate -Name 'OAuth/state persistence across force recreate' -Action {
      # docker compose up -d --force-recreate agy-bridge
      Invoke-DockerCapture -ArgumentList @('compose', 'up', '-d', '--force-recreate', 'agy-bridge') | Out-Null
      Assert-ApiAfterPersistenceTransition -ExpectedToken $script:BridgeToken -Marker $stateMarker
    }

    Invoke-Gate -Name 'OAuth/state persistence across image rebuild' -Action {
      # docker compose build agy-bridge
      Invoke-DockerCapture -ArgumentList @('compose', 'build', 'agy-bridge') | Out-Null
      Invoke-DockerCapture -ArgumentList @('compose', 'up', '-d', '--force-recreate', 'agy-bridge') | Out-Null
      Assert-ApiAfterPersistenceTransition -ExpectedToken $script:BridgeToken -Marker $stateMarker
    }

    if ($SkipDockerRestart) {
      Add-Skip -Name 'OAuth/state persistence across Docker Desktop restart' -Reason '-SkipDockerRestart was specified; merge evidence is incomplete'
    }
    else {
      Invoke-Gate -Name 'OAuth/state persistence across Docker Desktop restart' -Action {
        Write-Host ''
        Write-Host 'ACTION REQUIRED: Prepare to restart Docker Desktop.' -ForegroundColor Yellow
        Write-Host 'After pressing Enter below, immediately restart Docker Desktop. Do not run docker compose down.' -ForegroundColor Yellow
        Write-Host 'The verifier must observe the Docker daemon go offline and then recover.' -ForegroundColor Yellow
        [void](Read-Host 'Press Enter when ready to arm Docker restart detection')
        Wait-DockerUnavailable
        Write-Host 'Docker daemon outage observed; waiting for Docker Desktop to recover...' -ForegroundColor DarkYellow
        Wait-Docker
        Invoke-DockerCapture -ArgumentList @('compose', 'up', '-d', 'agy-bridge') | Out-Null
        Assert-ApiAfterPersistenceTransition -ExpectedToken $script:BridgeToken -Marker $stateMarker
      }
    }
  }
}
catch {
  $script:HadFailure = $true
  $script:FatalMessage = $_.Exception.Message
}
finally {
  try { Stop-WorkspaceRwVerifierDeployment } catch { }
  try { Stop-WorkspaceVerifierDeployment } catch { }
  Set-Location $originalLocation
  Write-Host "`n=== Verification summary ===" -ForegroundColor Cyan
  if ($script:Results.Count -gt 0) {
    $script:Results | Format-Table -AutoSize | Out-Host
  }
  if ($script:FatalMessage) {
    Write-Host "Fatal: $($script:FatalMessage)" -ForegroundColor Red
  }

  if ($script:HadFailure) {
    Write-Host 'VERDICT: FAIL - Docker runtime stack is not merge-ready.' -ForegroundColor Red
    exit 1
  }
  if ($script:Incomplete) {
    Write-Host 'VERDICT: INCOMPLETE - one or more mandatory merge gates were skipped.' -ForegroundColor Yellow
    exit 2
  }
  Write-Host 'VERDICT: PASS - all verifier gates completed successfully on this checkout.' -ForegroundColor Green
  exit 0
}
