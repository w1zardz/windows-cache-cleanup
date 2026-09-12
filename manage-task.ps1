#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('Install', 'Status', 'Pause', 'Resume', 'Remove')][string]$Action = 'Status',
    [ValidateRange(0.001, 100000)][double]$ThresholdGB = 20,
    [ValidateRange(1, 3650)][int]$MinAgeDays = 7,
    [switch]$IncludeInstallers,
    [switch]$ReportOnly,
    [ValidatePattern('^(?:[01][0-9]|2[0-3]):[0-5][0-9]$')][string]$DailyAt = '10:00',
    [ValidateRange(1, 180)][int]$LogonDelayMinutes = 10,
    [switch]$Disabled
)
. (Join-Path $PSScriptRoot 'windows-cache-cleanup.ps1') -ThresholdGB $ThresholdGB -MinAgeDays $MinAgeDays -IncludeInstallers:$IncludeInstallers

function New-CleanupTaskContext {
    param([string]$InstallRoot, [string]$SourceRoot = $PSScriptRoot, [string]$TaskName)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    # This location is also visible from outside packaged terminals that virtualize AppData.
    if (-not $InstallRoot) { $InstallRoot = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.windows-cache-cleanup' }
    if (-not $TaskName) { $TaskName = 'WindowsCacheCleanup-' + $sid }
    [pscustomobject]@{
        Root = [IO.Path]::GetFullPath($InstallRoot); Source = $SourceRoot; Name = $TaskName; Sid = $sid
        PowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        LegacyRunner = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'WindowsCacheCleanup\run-scheduled.ps1'
    }
}
function New-CleanupTaskBackend {
    @{
        Read = { param($Name) @(Get-ScheduledTask -TaskPath '\' -ErrorAction Stop | Where-Object TaskName -eq $Name) }
        Export = { param($Name) Export-ScheduledTask -TaskName $Name -TaskPath '\' -ErrorAction Stop }
        Write = {
            param($Name, $Definition, $Xml)
            if ($null -ne $Xml) { Register-ScheduledTask -TaskName $Name -TaskPath '\' -Xml $Xml -Force -ErrorAction Stop | Out-Null }
            else { Register-ScheduledTask -TaskName $Name -TaskPath '\' -InputObject $Definition -Force -ErrorAction Stop | Out-Null }
        }
        Remove = { param($Name) Unregister-ScheduledTask -TaskName $Name -TaskPath '\' -Confirm:$false -ErrorAction Stop }
    }
}
function Get-CleanupManagedTask($Context, $Backend) {
    $found = @(& ($Backend.Read) $Context.Name)
    if ($found.Count -gt 1) { throw 'Multiple tasks matched; refusing to change them.' }
    if (-not $found.Count) { return $null }
    $task = $found[0]; $actions = @($task.Actions); $ours = $false
    if ($actions.Count -eq 1 -and $actions[0].Execute -eq $Context.PowerShell) {
        $prefix = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "'
        $pattern = '^' + [regex]::Escape($prefix + $Context.Root + '\releases\') + '[a-f0-9]{64}\\scheduled-cleanup\.ps1"$'
        $ours = $task.Description -eq 'WindowsCacheCleanup v2' -and $actions[0].Arguments -match $pattern
        if (-not $ours) {
            $ours = $task.Description -eq 'Deletes old files from a fixed cache allowlist only when the size threshold is reached.' -and $actions[0].Arguments -eq ($prefix + $Context.LegacyRunner + '"')
        }
    }
    if (-not $ours) { throw "An unrelated task uses the name $($Context.Name); it was not changed." }
    return $task
}
function New-CleanupTaskRelease($Context, $Configuration) {
    Assert-CachePlainPath $Context.Root | Out-Null
    $payload = [ordered]@{}
    foreach ($name in @('windows-cache-cleanup.ps1', 'scheduled-cleanup.ps1')) {
        $payload[$name] = [IO.File]::ReadAllBytes((Assert-CachePlainPath (Join-Path $Context.Source $name)))
    }
    $payload['settings.json'] = [Text.UTF8Encoding]::new($false).GetBytes(($Configuration | ConvertTo-Json -Compress))
    $hashInput = [IO.MemoryStream]::new(); $sha = [Security.Cryptography.SHA256]::Create()
    try {
        foreach ($bytes in $payload.Values) {
            $hashInput.Write([BitConverter]::GetBytes([long]$bytes.Length), 0, 8)
            $hashInput.Write($bytes, 0, $bytes.Length)
        }
        $id = ([BitConverter]::ToString($sha.ComputeHash($hashInput.ToArray()))).Replace('-', '').ToLowerInvariant()
    } finally { $hashInput.Dispose(); $sha.Dispose() }
    $releases = Join-Path $Context.Root 'releases'; $release = Join-Path $releases $id
    Assert-CachePlainPath $release | Out-Null
    if (Test-Path -LiteralPath $release) {
        foreach ($name in $payload.Keys) {
            $file = Assert-CachePlainPath (Join-Path $release $name)
            if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($file)) -cne [Convert]::ToBase64String($payload[$name])) { throw 'An existing release was modified; refusing to overwrite it.' }
        }
        return $release
    }
    New-Item -ItemType Directory -Path $releases -Force -ErrorAction Stop | Out-Null
    Assert-CachePlainPath $releases | Out-Null
    $pending = Join-Path $releases ('.pending-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $pending -ErrorAction Stop | Out-Null
    foreach ($name in $payload.Keys) { [IO.File]::WriteAllBytes((Join-Path $pending $name), $payload[$name]) }
    # The old task still uses its old files during preparation. No directory is overwritten.
    $pending = Assert-CachePlainPath $pending
    $release = Assert-CachePlainPath $release
    if (-not (Test-CachePathInside $pending $Context.Root) -or -not (Test-CachePathInside $release $Context.Root)) { throw 'Release paths must stay inside the installation directory.' }
    [IO.Directory]::Move($pending, $release)
    return $release
}
function Install-CleanupTask {
    param($Context, $Configuration, $Backend = (New-CleanupTaskBackend), [switch]$StartDisabled)
    $previous = Get-CleanupManagedTask $Context $Backend; $previousXml = $null
    if ($null -ne $previous) { $previousXml = & ($Backend.Export) $Context.Name }
    $release = New-CleanupTaskRelease $Context $Configuration
    $arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + (Join-Path $release 'scheduled-cleanup.ps1') + '"'
    $taskAction = New-ScheduledTaskAction -Execute $Context.PowerShell -Argument $arguments -WorkingDirectory $release
    $logon = New-ScheduledTaskTrigger -AtLogOn -User $Context.Sid
    $logon.Delay = 'PT' + $Configuration.LogonDelayMinutes + 'M'
    $daily = New-ScheduledTaskTrigger -Daily -At $Configuration.DailyAt
    $principal = New-ScheduledTaskPrincipal -UserId $Context.Sid -LogonType Interactive -RunLevel Limited
    $wasDisabled = $null -ne $previous -and $previous.State -eq 'Disabled'
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 1) -Disable:($StartDisabled -or $wasDisabled)
    $definition = New-ScheduledTask -Action $taskAction -Trigger @($logon, $daily) -Principal $principal -Settings $settings -Description 'WindowsCacheCleanup v2'
    try {
        & ($Backend.Write) $Context.Name $definition $null
        $saved = Get-CleanupManagedTask $Context $Backend
        if ($null -eq $saved -or $saved.Actions[0].Arguments -ne $arguments) { throw 'Task Scheduler did not retain the new action.' }
    } catch {
        $failure = $_
        try {
            if ($null -ne $previousXml) { & ($Backend.Write) $Context.Name $null $previousXml }
            else {
                $created = Get-CleanupManagedTask $Context $Backend
                if ($null -ne $created -and $created.Actions[0].Arguments -eq $arguments) { & ($Backend.Remove) $Context.Name }
            }
        } catch { throw "Installation failed: $($failure.Exception.Message). Rollback also failed: $($_.Exception.Message)" }
        throw "Installation failed; previous task restored: $($failure.Exception.Message)"
    }
    [pscustomobject]@{ Release = $release; ReportOnly = $Configuration.ReportOnly; Disabled = [bool]($StartDisabled -or $wasDisabled) }
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    if ($env:OS -ne 'Windows_NT') { throw 'Windows is required.' }
    $context = New-CleanupTaskContext; $backend = New-CleanupTaskBackend
    $mutex = [Threading.Mutex]::new($false, ('Local\WindowsCacheCleanupSetup-' + $context.Sid)); $locked = $false
    try {
        try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Another setup operation is running.' }
        if ($Action -eq 'Install') {
            $config = [ordered]@{ SchemaVersion = 1; ThresholdGB = $ThresholdGB; MinAgeDays = $MinAgeDays; IncludeInstallers = [bool]$IncludeInstallers; ReportOnly = [bool]$ReportOnly; DailyAt = $DailyAt; LogonDelayMinutes = $LogonDelayMinutes }
            $mode = if ($ReportOnly) { 'reports only' } else { 'automatic cleanup' }
            if ($PSCmdlet.ShouldProcess($context.Name, "Install $mode; threshold $ThresholdGB GiB; age $MinAgeDays days; daily $DailyAt")) {
                Install-CleanupTask -Context $context -Configuration $config -Backend $backend -StartDisabled:$Disabled | Format-List
                Write-Host 'Installation completed. No cleanup was started by the installer.'
            }
            return
        }
        $task = Get-CleanupManagedTask $context $backend
        if ($null -eq $task) { Write-Host 'No cache cleanup schedule is installed.'; return }
        if ($Action -eq 'Status') {
            $task | Select-Object TaskName, State, @{n='Action';e={$_.Actions[0].Arguments}} | Format-List
            $task | Get-ScheduledTaskInfo | Select-Object LastRunTime, LastTaskResult, NextRunTime | Format-List
            if ($task.Description -eq 'WindowsCacheCleanup v2') {
                $runner = ($task.Actions[0].Arguments -split ' -File "', 2)[1].TrimEnd('"')
                $configurationPath = Assert-CachePlainPath (Join-Path (Split-Path -Parent $runner) 'settings.json')
                Get-Content -LiteralPath $configurationPath -Raw -Encoding UTF8 | Write-Host
                Get-ChildItem -LiteralPath (Join-Path $context.Root 'reports') -Filter 'cleanup-*.json' -File -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1 FullName,LastWriteTimeUtc | Format-List
            }
            return
        }
        if (-not $PSCmdlet.ShouldProcess($context.Name, $Action)) { return }
        switch ($Action) {
            'Pause' { Disable-ScheduledTask -TaskName $context.Name -TaskPath '\' | Out-Null; Write-Host 'Future runs paused. An existing run is allowed to finish.' }
            'Resume' { Enable-ScheduledTask -TaskName $context.Name -TaskPath '\' | Out-Null; Write-Host 'Schedule enabled.' }
            'Remove' { & ($backend.Remove) $context.Name; Write-Host 'Schedule removed. Local releases and reports retained.' }
        }
    } finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}
