#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows-cache-cleanup.ps1')

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('windows-cache-cleanup-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
$passed = 0
$script:noProcesses = { @() }
$script:allowDeletion = { param($Path) $true }

function Assert-Check([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function New-TestProfile([string]$Name) {
    $root = Join-Path $fixtureRoot $Name
    New-Item -ItemType Directory -Path $root | Out-Null
    return New-CacheCleanupContext -ProfileRoot $root
}
function Put-TestFile {
    param([string]$Path, [int]$Size = 2048, [int]$AgeDays = 40)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    [IO.File]::WriteAllBytes($Path, [byte[]]::new($Size))
    $stamp = [datetime]::UtcNow.AddDays(-$AgeDays)
    [IO.File]::SetLastWriteTimeUtc($Path, $stamp)
    [IO.File]::SetCreationTimeUtc($Path, $stamp)
    return $Path
}
function Invoke-TestCase([string]$Name, [scriptblock]$Body) {
    & $Body
    $script:passed++
    Write-Host "PASS: $Name"
}
function Run-TestCleanup($Context, [switch]$Auto, [double]$Threshold = 0.0000001,
    [scriptblock]$Processes = $script:noProcesses, [scriptblock]$Decision = $script:allowDeletion) {
    Invoke-WindowsCacheCleanup -Context $Context -Auto:$Auto -ThresholdGB $Threshold -MinAgeDays 7 -ProcessProvider $Processes -ShouldDelete $Decision
}

try {
    Invoke-TestCase 'Report and below-threshold runs delete nothing' {
        $ctx = New-TestProfile 'report'
        $file = Put-TestFile (Join-Path $ctx.Roaming 'Minecraft Bedrock\logs\ContentLog-old.txt')
        $report = Run-TestCleanup $ctx
        Assert-Check ($report.Mode -eq 'Report' -and $report.DeletedFiles -eq 0 -and (Test-Path -LiteralPath $file)) 'Report deleted data'
        $below = Run-TestCleanup $ctx -Auto -Threshold 1
        Assert-Check ($below.Mode -eq 'Below threshold' -and (Test-Path -LiteralPath $file)) 'Below-threshold cleanup deleted data'
    }
    Invoke-TestCase 'Old logs are removed; fresh logs and non-log files survive' {
        $ctx = New-TestProfile 'age'
        $old = Put-TestFile (Join-Path $ctx.Roaming 'Minecraft Bedrock\logs\ContentLog-old.txt')
        $fresh = Put-TestFile (Join-Path $ctx.Roaming 'Minecraft Bedrock\logs\ContentLog-new.txt') -AgeDays 0
        $personal = Put-TestFile (Join-Path $ctx.Roaming 'Minecraft Bedrock\logs\notes.txt')
        $result = Run-TestCleanup $ctx -Auto
        Assert-Check ($result.DeletedFiles -eq 1 -and -not (Test-Path -LiteralPath $old)) 'Old log was not deleted'
        Assert-Check ((Test-Path -LiteralPath $fresh) -and (Test-Path -LiteralPath $personal)) 'Fresh/personal file was deleted'
    }
    Invoke-TestCase 'Recently created files with old archived timestamps survive' {
        $ctx = New-TestProfile 'creation-age'
        $old = Put-TestFile (Join-Path $ctx.Local 'NVIDIA\DXCache\old.nvph')
        $newCopy = Put-TestFile (Join-Path $ctx.Local 'NVIDIA\DXCache\copied.nvph')
        [IO.File]::SetCreationTimeUtc($newCopy, [datetime]::UtcNow)
        Run-TestCleanup $ctx -Auto | Out-Null
        Assert-Check (-not (Test-Path -LiteralPath $old)) 'Old shader was not deleted'
        Assert-Check (Test-Path -LiteralPath $newCopy) 'Newly copied file was deleted'
    }
    Invoke-TestCase 'Running application and application started after scan are respected' {
        $ctx = New-TestProfile 'busy'
        $file = Put-TestFile (Join-Path $ctx.Local 'Google\Chrome\User Data\Default\Cache\data')
        $busy = Run-TestCleanup $ctx -Auto -Processes { @('chrome') }
        Assert-Check ($busy.DeletedFiles -eq 0 -and (Test-Path -LiteralPath $file)) 'Running Chrome cache was deleted'
        $script:processReads = 0
        $startsLater = { $script:processReads++; if ($script:processReads -gt 1) { @('chrome') } else { @() } }
        Run-TestCleanup $ctx -Auto -Processes $startsLater | Out-Null
        Assert-Check (Test-Path -LiteralPath $file) 'Application startup was ignored'
    }
    Invoke-TestCase 'Locked files are skipped and do not block other cache files' {
        $ctx = New-TestProfile 'locked'
        $locked = Put-TestFile (Join-Path $ctx.Local 'Skydimo\logs\old.log')
        $other = Put-TestFile (Join-Path $ctx.Local 'Skydimo\logs\other.log.1')
        $handle = [IO.File]::Open($locked, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        try { $result = Run-TestCleanup $ctx -Auto }
        finally { $handle.Dispose() }
        Assert-Check ((Test-Path -LiteralPath $locked) -and -not (Test-Path -LiteralPath $other)) 'Locked-file handling failed'
        Assert-Check ($result.DeletedFiles -eq 1) 'Deletion result included a locked file'
    }
    Invoke-TestCase 'Files changed between scan and deletion survive' {
        $ctx = New-TestProfile 'changed'
        $file = Put-TestFile (Join-Path $ctx.Local 'NVIDIA\DXCache\changing.nvph')
        $changeBeforeDelete = { param($Path) [IO.File]::AppendAllText($Path, 'new data'); $true }
        $result = Run-TestCleanup $ctx -Auto -Decision $changeBeforeDelete
        Assert-Check ((Test-Path -LiteralPath $file) -and $result.DeletedFiles -eq 0) 'Changed file was deleted'
    }
    Invoke-TestCase 'Unity, Temp projects, saves, browser credentials and Telegram state survive' {
        $ctx = New-TestProfile 'protected'
        $protected = @(
            (Join-Path $ctx.Temp 'sample-qa\unity\SampleGame\Library\ArtifactDB'),
            (Join-Path $ctx.Profile 'Games\SampleGame\NativeValidation\unity\SampleGame\Library\ArtifactDB'),
            (Join-Path $ctx.Profile 'Projects\game\.git\objects\pack\data.pack'),
            (Join-Path $ctx.Roaming 'Minecraft Bedrock\Users\Shared\games\com.mojang\minecraftWorlds\world\db\000001.log'),
            (Join-Path $ctx.Local 'Google\Chrome\User Data\Default\Login Data'),
            (Join-Path $ctx.Roaming 'Telegram Desktop\tdata\key_datas'),
            (Join-Path $ctx.Local 'CapCut\User Data\Projects\project\draft_content.json'),
            (Join-Path $ctx.Local 'FiveM\FiveM.app\data\game-storage\game.dat'),
            (Join-Path $ctx.Temp 'private-document.txt')
        )
        foreach ($path in $protected) { Put-TestFile $path | Out-Null }
        $cache = Put-TestFile (Join-Path $ctx.Roaming 'Telegram Desktop\tdata\user_data#2\cache\image')
        Run-TestCleanup $ctx -Auto | Out-Null
        Assert-Check (-not (Test-Path -LiteralPath $cache)) 'Telegram cache was not recognized'
        foreach ($path in $protected) { Assert-Check (Test-Path -LiteralPath $path) "Protected file removed: $path" }
    }
    Invoke-TestCase 'Junctions inside a cache and at its root cannot redirect deletion' {
        $ctx = New-TestProfile 'junction'
        $outside = Join-Path $fixtureRoot 'outside-junction-target'
        $precious = Put-TestFile (Join-Path $outside 'precious.txt')
        $cache = Join-Path $ctx.Local 'CapCut\User Data\Cache'
        $ordinary = Put-TestFile (Join-Path $cache 'old-cache.bin')
        $link = Join-Path $cache 'redirect'
        New-Item -ItemType Junction -Path $link -Target $outside | Out-Null
        try {
            Run-TestCleanup $ctx -Auto | Out-Null
            Assert-Check ((Test-Path -LiteralPath $precious) -and -not (Test-Path -LiteralPath $ordinary)) 'Nested junction was followed'
        } finally { [IO.Directory]::Delete($link) }
        $rootLink = Join-Path $ctx.Local 'NVIDIA\DXCache'
        New-Item -ItemType Directory -Path (Split-Path -Parent $rootLink) -Force | Out-Null
        New-Item -ItemType Junction -Path $rootLink -Target $outside | Out-Null
        try {
            Run-TestCleanup $ctx -Auto | Out-Null
            Assert-Check (Test-Path -LiteralPath $precious) 'Cache-root junction was followed'
        } finally { [IO.Directory]::Delete($rootLink) }
    }
    Invoke-TestCase 'Installed, previous and pending CapCut versions survive' {
        $ctx = New-TestProfile 'versions'
        $apps = Join-Path $ctx.Local 'CapCut\Apps'
        $old = Put-TestFile (Join-Path $apps '7.0.0.1\program.dll')
        $previous = Put-TestFile (Join-Path $apps '8.0.0.1\program.dll')
        $current = Put-TestFile (Join-Path $apps '9.0.0.1\program.dll')
        $pending = Put-TestFile (Join-Path $apps '10.0.0.1\program.dll')
        [IO.File]::WriteAllText((Join-Path $apps 'ProductInfo.xml'), '<full_appver value="9.0.0.1" />')
        [IO.Directory]::SetCreationTimeUtc((Split-Path -Parent $old), [datetime]::UtcNow.AddDays(-40))
        Run-TestCleanup $ctx -Auto | Out-Null
        Assert-Check (-not (Test-Path -LiteralPath $old)) 'Old CapCut version was not cleaned'
        foreach ($file in @($previous,$current,$pending)) { Assert-Check (Test-Path -LiteralPath $file) 'Protected CapCut version was deleted' }
    }
    Invoke-TestCase 'Installers are opt-in and keep recent packages' {
        $ctx = New-TestProfile 'installers'
        $old = Put-TestFile (Join-Path $ctx.Roaming 'levilauncher.exe\installers\old.msixvc')
        $fresh = Put-TestFile (Join-Path $ctx.Roaming 'levilauncher.exe\installers\new.msixvc') -AgeDays 10
        Run-TestCleanup $ctx -Auto | Out-Null
        Assert-Check (Test-Path -LiteralPath $old) 'Installer deleted without opt-in'
        Invoke-WindowsCacheCleanup -Context $ctx -Auto -ThresholdGB 0.0000001 -MinAgeDays 7 -IncludeInstallers -ProcessProvider $script:noProcesses -ShouldDelete $script:allowDeletion | Out-Null
        Assert-Check (-not (Test-Path -LiteralPath $old) -and (Test-Path -LiteralPath $fresh)) 'Installer retention failed'
    }
    Invoke-TestCase 'Declining deletion and outside-root paths are respected' {
        $ctx = New-TestProfile 'declined'
        $file = Put-TestFile (Join-Path $ctx.Local 'Skydimo\logs\old.log')
        Run-TestCleanup $ctx -Auto -Decision { param($Path) $false } | Out-Null
        Assert-Check (Test-Path -LiteralPath $file) 'Declined file was deleted'
        $info = Get-Item -LiteralPath $file
        $wrongRoot = Join-Path $ctx.Local 'different'
        $code = [WindowsCacheCleanup.NativeFile]::Delete($file,$wrongRoot,$info.Length,$info.LastWriteTimeUtc.ToFileTimeUtc(),$info.CreationTimeUtc.ToFileTimeUtc(),[datetime]::UtcNow.ToFileTimeUtc())
        Assert-Check ($code -eq -2 -and (Test-Path -LiteralPath $file)) 'Outside-root file was deleted'
    }
    Invoke-TestCase 'Hard links and read-only files survive' {
        $ctx = New-TestProfile 'hardlink'
        $cache = Join-Path $ctx.Local 'Skydimo\logs'
        $source = Put-TestFile (Join-Path $fixtureRoot 'hardlink-target.txt')
        New-Item -ItemType Directory -Path $cache -Force | Out-Null
        $link = Join-Path $cache 'shared.log'
        New-Item -ItemType HardLink -Path $link -Target $source | Out-Null
        $readOnly = Put-TestFile (Join-Path $cache 'readonly.log')
        [IO.File]::SetAttributes($readOnly, [IO.FileAttributes]::ReadOnly)
        try {
            $result = Run-TestCleanup $ctx -Auto
            Assert-Check ($result.DeletedFiles -eq 0 -and (Test-Path -LiteralPath $link) -and (Test-Path -LiteralPath $source) -and (Test-Path -LiteralPath $readOnly)) 'Shared/read-only file was deleted'
        } finally { [IO.File]::SetAttributes($readOnly, [IO.FileAttributes]::Normal) }
    }
    Invoke-TestCase 'A directory replaced by a junction just before deletion is rejected' {
        $ctx = New-TestProfile 'late-junction'
        $cache = Join-Path $ctx.Local 'NVIDIA\DXCache'
        $original = Put-TestFile (Join-Path $cache 'shader.nvph')
        $outside = Join-Path $fixtureRoot 'late-junction-target'
        $precious = Put-TestFile (Join-Path $outside 'shader.nvph')
        $info = Get-Item -LiteralPath $original
        [IO.File]::SetCreationTimeUtc($precious, $info.CreationTimeUtc)
        [IO.File]::SetLastWriteTimeUtc($precious, $info.LastWriteTimeUtc)
        $savedCache = $cache + '-saved'
        $replace = {
            param($Path)
            [IO.Directory]::Move($cache, $savedCache)
            New-Item -ItemType Junction -Path $cache -Target $outside | Out-Null
            $true
        }.GetNewClosure()
        try {
            $result = Run-TestCleanup $ctx -Auto -Decision $replace
            Assert-Check ($result.DeletedFiles -eq 0 -and (Test-Path -LiteralPath $precious)) 'Late junction redirected deletion'
        } finally {
            if ((Get-Item -LiteralPath $cache -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { [IO.Directory]::Delete($cache) }
        }
    }
    Write-Host "All $passed cache-cleanup tests passed."
} finally {
    # Only this invocation's explicitly created fixture tree is removed.
    $full = [IO.Path]::GetFullPath($fixtureRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if (-not (Test-CachePathInside $full $tempRoot) -or (Split-Path -Leaf $full) -notmatch '^windows-cache-cleanup-test-[a-f0-9]{32}$') {
        throw 'Unexpected test cleanup path.'
    }
    Assert-CachePlainPath $full | Out-Null
    $links = @(Get-ChildItem -LiteralPath $full -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
    if ($links.Count) { throw 'Test fixture still contains a junction; refusing recursive cleanup.' }
    Remove-Item -LiteralPath $full -Recurse -Force
}
