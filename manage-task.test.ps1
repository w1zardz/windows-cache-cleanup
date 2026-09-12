#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'manage-task.ps1')
. (Join-Path $PSScriptRoot 'scheduled-cleanup.ps1')
$suiteRoot = Join-Path ([IO.Path]::GetTempPath()) ('windows-cache-schedule-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $suiteRoot | Out-Null
$script:passed = 0
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Expect-Failure([scriptblock]$Body, [string]$Pattern) {
    $caught = $false
    try { & $Body | Out-Null } catch { if ($_.Exception.Message -notlike $Pattern) { throw }; $caught = $true }
    Check $caught 'Expected failure did not occur'
}
function Case([string]$Name, [scriptblock]$Body) { & $Body; $script:passed++; Write-Host "PASS: $Name" }
function New-Config {
    [ordered]@{ SchemaVersion = 1; ThresholdGB = 33.5; MinAgeDays = 9; IncludeInstallers = $true; ReportOnly = $true; DailyAt = '13:45'; LogonDelayMinutes = 12 }
}
function New-FakeBackend {
    $holder = @{ Task = $null; FailNextWrite = $false; Restores = 0; Removed = 0; Definition = $null }
    $backend = @{
        Read = { param($Name) if ($null -ne $holder.Task) { $holder.Task } }.GetNewClosure()
        Export = { param($Name) $holder.Task }.GetNewClosure()
        Write = {
            param($Name, $Definition, $Xml)
            if ($null -ne $Xml) { $holder.Task = $Xml; $holder.Restores++; return }
            $holder.Definition = $Definition
            $holder.Task = [pscustomobject]@{ Description = $Definition.Description; Actions = $Definition.Actions; State = $(if ($Definition.Settings.Enabled) { 'Ready' } else { 'Disabled' }) }
            if ($holder.FailNextWrite) { $holder.FailNextWrite = $false; throw 'Simulated failure after registration' }
        }.GetNewClosure()
        Remove = { param($Name) $holder.Task = $null; $holder.Removed++ }.GetNewClosure()
    }
    [pscustomobject]@{ State = $holder; Backend = $backend }
}
function New-TestContext([string]$Name) {
    New-CleanupTaskContext -InstallRoot (Join-Path $suiteRoot $Name) -SourceRoot $PSScriptRoot -TaskName ('Fixture-' + $Name)
}
function Put-OldReport([string]$Directory, [int]$Age = 50, [string]$Name) {
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    if (-not $Name) { $Name = 'cleanup-20200101-000000-' + [guid]::NewGuid().ToString('N') + '.json' }
    $path = Join-Path $Directory $Name
    [IO.File]::WriteAllText($path, '{}')
    [IO.File]::SetLastWriteTimeUtc($path, [datetime]::UtcNow.AddDays(-$Age))
    [IO.File]::SetCreationTimeUtc($path, [datetime]::UtcNow.AddDays(-$Age))
    return $path
}
function New-RunnerFixture([string]$Name) {
    $release = Join-Path (Join-Path $suiteRoot $Name) 'releases\fixture'
    New-Item -ItemType Directory -Path $release -Force | Out-Null
    $stub = @'
[CmdletBinding()]
param([switch]$Auto, [double]$ThresholdGB, [int]$MinAgeDays, [switch]$IncludeInstallers, [string]$ReportPath)
function Assert-CachePlainPath([string]$Path) { [IO.Path]::GetFullPath($Path) }
if ($MyInvocation.InvocationName -ne '.') {
    if ($Auto) { throw 'Unexpected deletion mode in a report-only fixture' }
    if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'fail')) { throw 'Fixture execution failure' }
    [IO.File]::WriteAllText($ReportPath, (@{ Mode = 'Report'; Threshold = $ThresholdGB; Age = $MinAgeDays; Installers = [bool]$IncludeInstallers } | ConvertTo-Json))
}
'@
    [IO.File]::WriteAllText((Join-Path $release 'windows-cache-cleanup.ps1'), $stub)
    [IO.File]::WriteAllText((Join-Path $release 'settings.json'), ((New-Config) | ConvertTo-Json))
    return $release
}
try {
    Case 'Installer preserves explicit parameters and creates a limited, disabled task' {
        $ctx = New-TestContext 'install'; $fake = New-FakeBackend
        $result = Install-CleanupTask $ctx (New-Config) $fake.Backend -StartDisabled
        $config = Get-Content -LiteralPath (Join-Path $result.Release 'settings.json') -Raw | ConvertFrom-Json
        Check ($config.ThresholdGB -eq 33.5 -and $config.MinAgeDays -eq 9 -and $config.ReportOnly -and $config.IncludeInstallers) 'Installer lost parameters'
        Check ($fake.State.Task.State -eq 'Disabled') 'Disabled install started enabled'
        Check ([int]$fake.State.Definition.Principal.RunLevel -eq 0) 'Task requests elevated privileges'
        Check ($fake.State.Definition.Triggers[0].Delay -eq 'PT12M') 'Logon delay was lost'
    }
    Case 'Upgrade uses new immutable files and preserves a paused task' {
        $ctx = New-TestContext 'upgrade'; $fake = New-FakeBackend; $config = New-Config
        $first = Install-CleanupTask $ctx $config $fake.Backend -StartDisabled
        $oldHash = (Get-FileHash -LiteralPath (Join-Path $first.Release 'settings.json')).Hash
        $same = Install-CleanupTask $ctx $config $fake.Backend
        Check ($same.Release -eq $first.Release) 'Identical installation was not reused'
        $config.ThresholdGB = 40
        $second = Install-CleanupTask $ctx $config $fake.Backend
        Check ($second.Release -ne $first.Release -and $second.Disabled) 'Upgrade lost disabled state or reused changed files'
        Check ((Get-FileHash -LiteralPath (Join-Path $first.Release 'settings.json')).Hash -eq $oldHash) 'Old release changed'
    }
    Case 'Failed upgrade restores the previous task after a partial registration' {
        $ctx = New-TestContext 'rollback'; $fake = New-FakeBackend; $config = New-Config
        Install-CleanupTask $ctx $config $fake.Backend | Out-Null
        $previous = $fake.State.Task.Actions[0].Arguments
        $config.ThresholdGB = 60; $fake.State.FailNextWrite = $true
        Expect-Failure { Install-CleanupTask $ctx $config $fake.Backend } '*previous task restored*'
        Check ($fake.State.Restores -eq 1 -and $fake.State.Task.Actions[0].Arguments -eq $previous) 'Rollback lost the old task'
    }
    Case 'Failed first installation removes only its own partial task' {
        $ctx = New-TestContext 'first-failure'; $fake = New-FakeBackend; $fake.State.FailNextWrite = $true
        Expect-Failure { Install-CleanupTask $ctx (New-Config) $fake.Backend } '*previous task restored*'
        Check ($null -eq $fake.State.Task -and $fake.State.Removed -eq 1) 'Partial task was left registered'
    }
    Case 'An unrelated task is never overwritten' {
        $ctx = New-TestContext 'unrelated'; $fake = New-FakeBackend
        $fake.State.Task = [pscustomobject]@{ Description = 'Personal task'; Actions = @(); State = 'Ready' }
        Expect-Failure { Install-CleanupTask $ctx (New-Config) $fake.Backend } '*unrelated task*'
        Check (-not (Test-Path -LiteralPath $ctx.Root)) 'Files were prepared before checking task ownership'
    }
    Case 'Modified releases and redirected install directories are preserved' {
        $ctx = New-TestContext 'modified'; $fake = New-FakeBackend; $config = New-Config
        $result = Install-CleanupTask $ctx $config $fake.Backend
        $file = Join-Path $result.Release 'windows-cache-cleanup.ps1'
        [IO.File]::AppendAllText($file, '# modified')
        Expect-Failure { Install-CleanupTask $ctx $config $fake.Backend } '*modified*'
        $outside = Join-Path $suiteRoot 'outside'; New-Item -ItemType Directory -Path $outside | Out-Null
        $linkContext = New-TestContext 'redirect'
        New-Item -ItemType Junction -Path $linkContext.Root -Target $outside | Out-Null
        try { Expect-Failure { New-CleanupTaskRelease $linkContext $config } '*reparse point*' }
        finally { [IO.Directory]::Delete($linkContext.Root) }
        Check (@(Get-ChildItem -LiteralPath $outside -Force).Count -eq 0) 'Install followed a junction'
    }
    Case 'Report retention preserves recent, locked and non-report files' {
        $directory = Join-Path $suiteRoot 'retention'
        $old = Put-OldReport $directory
        $locked = Put-OldReport $directory
        $recent = Put-OldReport $directory -Age 1
        $recent2 = Put-OldReport $directory -Age 2
        $personal = Put-OldReport $directory -Name 'manual.json'
        $handle = [IO.File]::Open($locked, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        try { $removed = Remove-ExpiredCleanupReports -Directory $directory -Cleaner (Join-Path $PSScriptRoot 'windows-cache-cleanup.ps1') -Keep 2 }
        finally { $handle.Dispose() }
        Check ($removed -eq 1 -and -not (Test-Path -LiteralPath $old)) 'Expired report was not removed'
        foreach ($path in @($locked, $recent, $recent2, $personal)) { Check (Test-Path -LiteralPath $path) 'Protected report was deleted' }
    }
    Case 'Scheduled report-only mode never enables cleanup or trims existing reports' {
        $release = New-RunnerFixture 'report-only'
        $reports = Join-Path (Split-Path -Parent (Split-Path -Parent $release)) 'reports'
        $old = Put-OldReport $reports
        Invoke-ScheduledCleanup -Release $release
        Check (Test-Path -LiteralPath $old) 'Report-only run removed an old report'
        $new = @(Get-ChildItem -LiteralPath $reports -Filter '*.json' | Where-Object FullName -ne $old)
        $data = Get-Content -LiteralPath $new[0].FullName -Raw | ConvertFrom-Json
        Check ($new.Count -eq 1 -and $data.Mode -eq 'Report' -and $data.Threshold -eq 33.5 -and $data.Age -eq 9) 'Runner changed mode or parameters'
    }
    Case 'Runner records execution failure and rejects unsafe settings' {
        $release = New-RunnerFixture 'runner-errors'
        [IO.File]::WriteAllText((Join-Path $release 'fail'), '')
        Expect-Failure { Invoke-ScheduledCleanup -Release $release } '*Fixture execution failure*'
        $reports = Join-Path (Split-Path -Parent (Split-Path -Parent $release)) 'reports'
        $failures = @(Get-ChildItem -LiteralPath $reports -Filter '*-error.json')
        Check ($failures.Count -eq 1) 'Failure report missing'
        $config = New-Config; $config.ReportOnly = 'false'
        [IO.File]::WriteAllText((Join-Path $release 'settings.json'), ($config | ConvertTo-Json))
        Expect-Failure { Invoke-ScheduledCleanup -Release $release } '*Invalid scheduler settings*'
        $config = New-Config; $config.ThresholdGB = $true
        [IO.File]::WriteAllText((Join-Path $release 'settings.json'), ($config | ConvertTo-Json))
        Expect-Failure { Invoke-ScheduledCleanup -Release $release } '*Invalid scheduler settings*'
    }
    Write-Host "All $script:passed scheduler tests passed."
} finally {
    $full = [IO.Path]::GetFullPath($suiteRoot)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if (-not (Test-CachePathInside $full $temp) -or (Split-Path -Leaf $full) -notmatch '^windows-cache-schedule-test-[a-f0-9]{32}$') { throw 'Unexpected fixture cleanup path.' }
    Assert-CachePlainPath $full | Out-Null
    $links = @(Get-ChildItem -LiteralPath $full -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
    if ($links.Count) { throw 'Fixture still has a junction; refusing recursive cleanup.' }
    Remove-Item -LiteralPath $full -Recurse -Force
}
