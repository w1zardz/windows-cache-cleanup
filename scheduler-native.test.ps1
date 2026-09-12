#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'manage-task.ps1')
$suffix = [guid]::NewGuid().ToString('N')
$fixture = Join-Path ([Environment]::GetFolderPath('UserProfile')) ('.windows-cache-scheduler-test-' + $suffix)
$name = 'WindowsCacheCleanup-Test-' + $suffix
$ctx = New-CleanupTaskContext -InstallRoot $fixture -SourceRoot $PSScriptRoot -TaskName $name
$backend = New-CleanupTaskBackend
$config = [ordered]@{ SchemaVersion = 1; ThresholdGB = 20; MinAgeDays = 7; IncludeInstallers = $false; ReportOnly = $true; DailyAt = '10:00'; LogonDelayMinutes = 10 }
try {
    # Disabled throughout the test; the cleaner is never launched by this test.
    $first = Install-CleanupTask $ctx $config $backend -StartDisabled
    $task = Get-CleanupManagedTask $ctx $backend
    if ($task.State -ne 'Disabled') { throw 'Fixture task unexpectedly enabled' }
    $config.ThresholdGB = 25
    $second = Install-CleanupTask $ctx $config $backend
    $task = Get-CleanupManagedTask $ctx $backend
    if ($task.State -ne 'Disabled' -or $first.Release -eq $second.Release) { throw 'Native upgrade lost state' }
    if (-not (Test-Path -LiteralPath (Join-Path $first.Release 'settings.json'))) { throw 'Old release was modified' }
    Write-Host 'PASS: native Windows registration, upgrade and disabled-state preservation'
} finally {
    $task = Get-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction SilentlyContinue
    if ($task) { Unregister-ScheduledTask -TaskName $name -TaskPath '\' -Confirm:$false -ErrorAction Stop }
    $profile = [Environment]::GetFolderPath('UserProfile')
    $full = [IO.Path]::GetFullPath($fixture)
    if (-not (Test-CachePathInside $full $profile) -or (Split-Path -Leaf $full) -notmatch '^\.windows-cache-scheduler-test-[a-f0-9]{32}$') { throw 'Unexpected fixture path' }
    if (Test-Path -LiteralPath $full) {
        Assert-CachePlainPath $full | Out-Null
        $links = @(Get-ChildItem -LiteralPath $full -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
        if ($links.Count) { throw 'Refusing to remove a fixture containing links' }
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}
