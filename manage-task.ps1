#Requires -Version 5.1
<#
.SYNOPSIS
Installs, inspects or removes a per-user Windows cache cleanup schedule.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('Install', 'Status', 'Remove')][string]$Action = 'Status',
    [ValidateRange(0.001, 100000)][double]$ThresholdGB = 20,
    [ValidateRange(1, 3650)][int]$MinAgeDays = 7,
    [switch]$IncludeInstallers
)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Windows is required.' }
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$taskName = 'WindowsCacheCleanup-' + $sid
$installDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'WindowsCacheCleanup'

if ($Action -eq 'Status') {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if (-not $task) { Write-Host 'No cache cleanup schedule is installed.'; return }
    $task | Select-Object TaskName, State
    $task | Get-ScheduledTaskInfo | Select-Object LastRunTime, LastTaskResult, NextRunTime
    return
}
if ($Action -eq 'Remove') {
    if ($PSCmdlet.ShouldProcess($taskName, 'Remove cache cleanup schedule')) {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($task) { $task | Unregister-ScheduledTask -Confirm:$false }
        Write-Host 'Schedule removed. Local scripts and reports are retained.'
    }
    return
}

$source = Join-Path $PSScriptRoot 'windows-cache-cleanup.ps1'
if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw 'The cleanup script must be next to this installer.' }
. $source -ThresholdGB $ThresholdGB -MinAgeDays $MinAgeDays -IncludeInstallers:$IncludeInstallers
$installDir = Assert-CachePlainPath $installDir
$target = Join-Path $installDir 'windows-cache-cleanup.ps1'
$runner = Join-Path $installDir 'run-scheduled.ps1'
foreach ($path in @($source, $target, $runner)) { Assert-CachePlainPath $path | Out-Null }
$invariant = [Globalization.CultureInfo]::InvariantCulture
$thresholdText = $ThresholdGB.ToString('R', $invariant)
$installerSwitch = if ($IncludeInstallers) { ' -IncludeInstallers' } else { '' }
$runnerText = @'
# Generated locally by manage-task.ps1. No network access or self-updates.
$ErrorActionPreference = 'Stop'
$cleanup = Join-Path $PSScriptRoot 'windows-cache-cleanup.ps1'
$report = Join-Path $PSScriptRoot ('reports\cleanup-' + [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff') + '.json')
& $cleanup -Auto -ThresholdGB THRESHOLD_VALUE -MinAgeDays AGE_VALUEINSTALLER_SWITCH -ReportPath $report
'@
$runnerText = $runnerText.Replace('THRESHOLD_VALUE', $thresholdText).Replace('AGE_VALUE', [string]$MinAgeDays).Replace('INSTALLER_SWITCH', $installerSwitch)
if (-not $PSCmdlet.ShouldProcess($taskName, "Install daily and logon cleanup; threshold $thresholdText GiB; minimum age $MinAgeDays days")) { return }

New-Item -ItemType Directory -Path $installDir -Force | Out-Null
Assert-CachePlainPath $installDir | Out-Null
# Copies only two scripts; profile data and repository history are never copied.
if ([IO.Path]::GetFullPath($source) -ne [IO.Path]::GetFullPath($target)) {
    Copy-Item -LiteralPath $source -Destination $target -Force
}
[IO.File]::WriteAllText($runner, $runnerText, [Text.UTF8Encoding]::new($false))
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $runner + '"'
$taskAction = New-ScheduledTaskAction -Execute $powershell -Argument $arguments -WorkingDirectory $installDir
$logon = New-ScheduledTaskTrigger -AtLogOn -User $sid
$logon.Delay = 'PT10M'
$daily = New-ScheduledTaskTrigger -Daily -At '10:00'
$principal = New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 1)
$task = New-ScheduledTask -Action $taskAction -Trigger @($logon, $daily) -Principal $principal -Settings $settings -Description 'Deletes old files from a fixed cache allowlist only when the size threshold is reached.'
Register-ScheduledTask -TaskName $taskName -InputObject $task -Force | Out-Null
Write-Host 'Installed: daily at 10:00 and 10 minutes after login, while this user is signed in.'
Write-Host 'No cleanup was started by the installer. Run -Action Status to inspect the schedule.'
Write-Host "Local scripts and reports: $installDir"
