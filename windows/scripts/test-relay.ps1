#requires -Version 7.0
param([string]$Relay = (Join-Path $PSScriptRoot '..\target\release\coucou-hook.exe'))
$ErrorActionPreference = 'Stop'
if (Get-Process coucou -ErrorAction SilentlyContinue) {
    throw 'Close Coucou before running the relay smoke test; it uses the same local pipe.'
}
$Relay = (Resolve-Path -LiteralPath $Relay).Path
$pipeName = 'coucou-' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Start-Relay([string]$Event, [string]$Agent = 'codex') {
    $info = [Diagnostics.ProcessStartInfo]::new($Relay)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    if ($Agent -ne 'claude') { $info.ArgumentList.Add('--agent'); $info.ArgumentList.Add($Agent) }
    $info.ArgumentList.Add($Event)
    return [Diagnostics.Process]::Start($info)
}

function Invoke-Exchange([string]$Event, [hashtable]$Fields, [string]$Reply = '', [string]$Agent = 'codex') {
    $server = [IO.Pipes.NamedPipeServerStream]::new($pipeName, [IO.Pipes.PipeDirection]::InOut,
        1, [IO.Pipes.PipeTransmissionMode]::Byte, [IO.Pipes.PipeOptions]::Asynchronous)
    $process = $null
    try {
        $connected = $server.WaitForConnectionAsync()
        $process = Start-Relay $Event $Agent
        $Fields.hook_event_name = $Event
        $process.StandardInput.WriteLine(($Fields | ConvertTo-Json -Compress -Depth 12))
        $process.StandardInput.Close()
        Assert-True ($connected.Wait(3000)) "Relay did not connect for $Event"
        $reader = [IO.StreamReader]::new($server, [Text.UTF8Encoding]::new($false), $false, 4096, $true)
        $lineTask = $reader.ReadLineAsync()
        Assert-True ($lineTask.Wait(3000)) "Relay did not send $Event"
        $payload = $lineTask.Result | ConvertFrom-Json
        if ($Reply) {
            $writer = [IO.StreamWriter]::new($server, [Text.UTF8Encoding]::new($false), 4096, $true)
            $writer.WriteLine($Reply)
            $writer.Flush()
        }
        $server.Dispose()
        Assert-True ($process.WaitForExit(3000)) "Relay did not exit for $Event"
        Assert-True ($process.ExitCode -eq 0) 'Relay returned a failure exit code'
        return @{ Payload = $payload; Output = $process.StandardOutput.ReadToEnd() }
    } finally {
        $server.Dispose()
        if ($process -and -not $process.HasExited) { $process.Kill() }
        if ($process) { $process.Dispose() }
    }
}

$private = 'PRIVATE_CONTENT_MUST_NOT_BE_FORWARDED'
$event = Invoke-Exchange 'PreToolUse' @{
    session_id='smoke-session'; turn_id='smoke-turn'; cwd='C:\example\project';
    tool_name='Bash'; prompt=$private; transcript_path=$private;
    tool_input=@{command=$private}; tool_response=$private
}
Assert-True ($event.Payload.coucou_agent -eq 'codex') 'Missing Codex provider'
Assert-True ($event.Payload.session_id -eq 'smoke-session') 'Session identity was lost'
Assert-True (-not (($event.Payload | ConvertTo-Json -Depth 12).Contains($private))) 'Private activity data leaked'
Assert-True ([string]::IsNullOrWhiteSpace($event.Output)) 'Activity hook changed model context'

$command = 'echo first' + "`n" + ('x' * 2200) + "`n" + 'echo last'
foreach ($decision in @('allow', 'deny')) {
    $approval = Invoke-Exchange 'PermissionRequest' @{
        session_id='smoke-session'; turn_id='smoke-turn'; tool_name='Bash';
        tool_input=@{command=$command; description='Synthetic test; no command is executed'}
    } $decision
    Assert-True ($approval.Payload.tool_input.command -ceq $command) 'Approval command was truncated'
    $answer = $approval.Output | ConvertFrom-Json
    Assert-True ($answer.hookSpecificOutput.decision.behavior -eq $decision) 'Wrong approval response'
}
$fallback = Invoke-Exchange 'PermissionRequest' @{session_id='smoke-session';tool_name='Bash';tool_input=@{command='echo test'}} 'unknown'
Assert-True ([string]::IsNullOrWhiteSpace($fallback.Output)) 'Unknown decision must defer to Codex'

$legacy = Invoke-Exchange 'PreToolUse' @{tool_name='Read';tool_input=@{file_path='example.txt'}} '' 'claude'
Assert-True ($legacy.Payload.tool_input.file_path -eq 'example.txt') 'Legacy Claude events changed'

$external = Invoke-Exchange 'PreToolUse' @{session_id='external-session';tool_name='Read';tool_input=@{file_path='example.txt'}} '' 'my-tool'
Assert-True ($external.Payload.coucou_agent -eq 'my-tool') 'Upstream third-party routing was lost'
Assert-True ([string]::IsNullOrWhiteSpace($external.Output)) 'External activity changed model context'

foreach ($name in @('Stop', 'SubagentStop')) {
    $stopped = Invoke-Exchange $name @{session_id='smoke-session';last_assistant_message=$private}
    Assert-True ($stopped.Output.Trim() -eq '{}') "$name must return neutral valid JSON"
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $process = Start-Relay $name
    try {
        # Intentionally leave stdin open: an absent app must never hold Codex up.
        Assert-True ($process.WaitForExit(2000)) 'Closed Coucou blocked the relay'
        Assert-True ($process.StandardOutput.ReadToEnd().Trim() -eq '{}') 'Missing neutral fallback'
    } finally {
        if (-not $process.HasExited) { $process.Kill() }
        $process.Dispose()
    }
    Write-Output "$name without Coucou: $($clock.ElapsedMilliseconds) ms"
}
Write-Output 'PASS: relay privacy, identity, exact approval arguments, allow/deny/fallback, Claude compatibility, closed-app behavior.'
