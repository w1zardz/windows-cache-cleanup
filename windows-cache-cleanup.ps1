#Requires -Version 5.1
<#
.SYNOPSIS
Reports known Windows caches; -Auto clears old cache files above a size threshold.
.EXAMPLE
.\windows-cache-cleanup.ps1
.EXAMPLE
.\windows-cache-cleanup.ps1 -Auto -ThresholdGB 20 -MinAgeDays 7 -WhatIf
.EXAMPLE
.\windows-cache-cleanup.ps1 -Auto -ThresholdGB 20 -MinAgeDays 7
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [switch]$Auto,
    [ValidateRange(0.001, 100000)][double]$ThresholdGB = 20,
    [ValidateRange(1, 3650)][int]$MinAgeDays = 7,
    [switch]$IncludeInstallers,
    [string]$ReportPath
)

function Test-CachePathInside([string]$Path, [string]$Root) {
    $full = [IO.Path]::GetFullPath($Path)
    $boundary = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    return $full.StartsWith($boundary, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-CachePlainPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -notmatch '^[A-Za-z]:\\' -or $full.StartsWith('\\')) {
        throw "Only local drive paths are supported: $Path"
    }
    for ($part = $full; $part; $part = Split-Path -Parent $part) {
        if (Test-Path -LiteralPath $part) {
            $item = Get-Item -LiteralPath $part -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Junction, symlink or other reparse point: $part"
            }
        }
        if ($part -eq [IO.Path]::GetPathRoot($part)) { break }
    }
    return $full
}

function New-CacheCleanupContext {
    param([string]$ProfileRoot = [Environment]::GetFolderPath('UserProfile'))
    $profilePath = [IO.Path]::GetFullPath($ProfileRoot).TrimEnd('\')
    if ($profilePath -eq [IO.Path]::GetPathRoot($profilePath).TrimEnd('\')) {
        throw 'A drive root is not a user profile.'
    }
    # No arbitrary cleanup roots or recursive search through a user's Temp/projects.
    $local = Join-Path $profilePath 'AppData\Local'
    $roaming = Join-Path $profilePath 'AppData\Roaming'
    $documents = Join-Path $profilePath 'Documents'
    $programData = Join-Path $profilePath 'ProgramData'
    if ($profilePath -eq [Environment]::GetFolderPath('UserProfile').TrimEnd('\')) {
        $documents = [Environment]::GetFolderPath('MyDocuments')
        $programData = [Environment]::GetFolderPath('CommonApplicationData')
    }
    [pscustomobject]@{
        Profile = $profilePath; Local = $local; Roaming = $roaming
        Documents = $documents; Temp = Join-Path $local 'Temp'; ProgramData = $programData
    }
}

function Get-CapCutCurrentVersion([string]$AppsRoot) {
    $info = Join-Path $AppsRoot 'ProductInfo.xml'
    if (-not (Test-Path -LiteralPath $info)) { return $null }
    try {
        Assert-CachePlainPath $info | Out-Null
        $text = [IO.File]::ReadAllText($info)
        if ($text -match '<full_appver\s+value="(\d+\.\d+\.\d+\.\d+)"') {
            $version = $Matches[1]
            if (Test-Path -LiteralPath (Join-Path $AppsRoot $version) -PathType Container) {
                return $version
            }
        }
    } catch { return $null }
    return $null
}

function Get-WindowsCacheRules {
    param($Context, [switch]$IncludeInstallers)
    $rules = [Collections.Generic.List[object]]::new()
    function Add-Rule {
        param([string]$Category, [string]$Root, [string[]]$Patterns = @('*'),
            [string[]]$Busy = @(), [int]$Age = 0, [bool]$WholeRoot = $false,
            [bool]$Enabled = $true, [string]$Version = '', [string]$VersionRoot = '')
        if (-not $Root -or -not (Test-Path -LiteralPath $Root -PathType Container)) { return }
        # A rule must name a cache/download leaf, never a Unity/source tree.
        if ($Root -match '(?i)[\\/](Library|Assets|ProjectSettings|\.git|minecraftWorlds)([\\/]|$)') {
            throw "Protected source/project path: $Root"
        }
        $rules.Add([pscustomobject]@{
            Category = $Category; Root = [IO.Path]::GetFullPath($Root)
            Patterns = $Patterns; Busy = $Busy; Age = $Age; WholeRoot = $WholeRoot
            Enabled = $Enabled; Version = $Version; VersionRoot = $VersionRoot
        })
    }
    $adobeBusy = @('Adobe Premiere Pro', 'AfterFX', 'Adobe Media Encoder', 'Adobe Audition')
    Add-Rule 'Minecraft content logs' (Join-Path $Context.Roaming 'Minecraft Bedrock\logs') @('ContentLog*.txt') @('Minecraft*', 'Bedrock*')
    Add-Rule 'Skydimo logs' (Join-Path $Context.Local 'Skydimo\logs') @('*.log', '*.log.1') @('Skydimo*')
    Add-Rule 'Premiere audio cache' (Join-Path $Context.Documents 'Adobe Premiere Pro Audio Previews') @('*.cfa', '*.pek') $adobeBusy
    Add-Rule 'Adobe media cache' (Join-Path $Context.Roaming 'Adobe\Common\Media Cache Files') @('*.cfa', '*.pek', '*.ims') $adobeBusy
    Add-Rule 'Adobe peak cache' (Join-Path $Context.Roaming 'Adobe\Common\Peak Files') @('*.pek') $adobeBusy

    $aeRoot = Join-Path $Context.Temp 'Adobe\After Effects'
    if (Test-Path -LiteralPath $aeRoot) {
        try {
            Assert-CachePlainPath $aeRoot | Out-Null
            foreach ($version in Get-ChildItem -LiteralPath $aeRoot -Directory -Force) {
                if ($version.Name -notmatch '^\d+\.\d+$') { continue }
                Assert-CachePlainPath $version.FullName | Out-Null
                foreach ($cache in Get-ChildItem -LiteralPath $version.FullName -Directory -Force) {
                    if ($cache.Name -like 'Disk Cache -*.noindex') {
                        Add-Rule 'After Effects disk cache' $cache.FullName @('*') $adobeBusy
                    }
                }
            }
        } catch { Write-Verbose $_.Exception.Message }
    }

    Add-Rule 'pip downloads' (Join-Path $Context.Local 'pip\cache') @('*') @('python*', 'pip*')
    Add-Rule 'npm downloads' (Join-Path $Context.Local 'npm-cache') @('*') @('node', 'npm', 'npx')
    Add-Rule 'Gradle cache' (Join-Path $Context.Profile '.gradle\caches') @('*') @('java', 'javaw', 'gradle*', 'Unity')
    Add-Rule 'NVIDIA shader cache' (Join-Path $Context.Local 'NVIDIA\DXCache') @('*.nvph')
    Add-Rule 'NVIDIA OpenGL cache' (Join-Path $Context.Local 'NVIDIA\GLCache')
    Add-Rule 'DirectX shader cache' (Join-Path $Context.Local 'D3DSCache')
    Add-Rule 'CapCut cache' (Join-Path $Context.Local 'CapCut\User Data\Cache') @('*') @('CapCut*')

    foreach ($browser in @(
        @{ Folder = 'Google\Chrome\User Data'; Name = 'Chrome'; Busy = 'chrome' },
        @{ Folder = 'Microsoft\Edge\User Data'; Name = 'Edge'; Busy = 'msedge' }
    )) {
        $browserRoot = Join-Path $Context.Local $browser.Folder
        if (-not (Test-Path -LiteralPath $browserRoot)) { continue }
        try {
            Assert-CachePlainPath $browserRoot | Out-Null
            foreach ($profileDir in Get-ChildItem -LiteralPath $browserRoot -Directory -Force) {
                if ($profileDir.Name -notmatch '^(Default|Profile \d+|Guest Profile)$') { continue }
                foreach ($leaf in @('Cache', 'Code Cache', 'GPUCache')) {
                    Add-Rule ($browser.Name + ' cache') (Join-Path $profileDir.FullName $leaf) @('*') @($browser.Busy)
                }
            }
        } catch { Write-Verbose $_.Exception.Message }
    }
    foreach ($editor in @('Code', 'Cursor')) {
        foreach ($leaf in @('Cache', 'Code Cache', 'GPUCache', 'CachedData', 'CachedExtensionVSIXs')) {
            Add-Rule ($editor + ' cache') (Join-Path (Join-Path $Context.Roaming $editor) $leaf) @('*') @($editor)
        }
    }
    $telegramRoot = Join-Path $Context.Roaming 'Telegram Desktop\tdata'
    if (Test-Path -LiteralPath $telegramRoot) {
        try {
            Assert-CachePlainPath $telegramRoot | Out-Null
            foreach ($userDir in Get-ChildItem -LiteralPath $telegramRoot -Directory -Force) {
                if ($userDir.Name -match '^user_data(?:#\d+)?$') {
                    Add-Rule 'Telegram media cache' (Join-Path $userDir.FullName 'cache') @('*') @('Telegram')
                }
            }
        } catch { Write-Verbose $_.Exception.Message }
    }
    foreach ($leaf in @('cache', 'server-cache', 'server-cache-priv')) {
        Add-Rule 'FiveM server cache' (Join-Path $Context.Local ('FiveM\FiveM.app\data\' + $leaf)) @('*') @('FiveM*', 'GTA5*')
    }

    $appsRoot = Join-Path $Context.Local 'CapCut\Apps'
    $current = Get-CapCutCurrentVersion $appsRoot
    if ($current) {
        try {
            Assert-CachePlainPath $appsRoot | Out-Null
            $previous = @(Get-ChildItem -LiteralPath $appsRoot -Directory -Force |
                Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' -and [version]$_.Name -lt [version]$current } |
                Sort-Object { [version]$_.Name } -Descending)
            # Keep the installed version, its immediately preceding version, and newer/pending versions.
            foreach ($oldVersion in @($previous | Select-Object -Skip 1)) {
                Add-Rule 'Old CapCut versions' $oldVersion.FullName @('*') @('CapCut*') 30 $true $true $current $appsRoot
            }
        } catch { Write-Verbose $_.Exception.Message }
    }
    Add-Rule 'Minecraft installers (optional)' (Join-Path $Context.Roaming 'levilauncher.exe\installers') @('*.msixvc', '*.msix', '*.appx') @('levilauncher*', 'Minecraft*') 30 $false ([bool]$IncludeInstallers)
    foreach ($channel in @('crd', 'grd')) {
        $channelRoot = Join-Path $Context.ProgramData ('NVIDIA Corporation\NVIDIA app\UpdateFramework\ota-artifacts\' + $channel)
        foreach ($parent in @($channelRoot, (Join-Path $channelRoot 'post-processing'))) {
            if (-not (Test-Path -LiteralPath $parent)) { continue }
            try {
                Assert-CachePlainPath $parent | Out-Null
                foreach ($archive in Get-ChildItem -LiteralPath $parent -Directory -Force) {
                    if ($archive.Name -match '^[a-fA-F0-9]{32}$') {
                        Add-Rule 'NVIDIA installers (optional)' $archive.FullName @('*') @('NVIDIA App', 'NVIDIAInstaller*', 'setup') 30 $true ([bool]$IncludeInstallers)
                    }
                }
            } catch { Write-Verbose $_.Exception.Message }
        }
    }
    return $rules.ToArray()
}

function Get-CacheFiles {
    param([string]$Root, [string[]]$Patterns = @('*'))
    Assert-CachePlainPath $Root | Out-Null
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($Root)
    while ($pending.Count) {
        $directory = $pending.Pop()
        Assert-CachePlainPath $directory | Out-Null
        foreach ($entry in ([IO.DirectoryInfo]::new($directory)).EnumerateFileSystemInfos()) {
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($entry.Attributes -band [IO.FileAttributes]::Directory) {
                if ($entry.Name -notmatch '^(?i:Library|Assets|ProjectSettings|\.git|minecraftWorlds)$') { $pending.Push($entry.FullName) }
                continue
            }
            if (-not (Test-CachePathInside $entry.FullName $Root)) { throw 'File outside cache root.' }
            $matchesPattern = $false
            foreach ($pattern in $Patterns) { if ($entry.Name -like $pattern) { $matchesPattern = $true; break } }
            if (-not $matchesPattern) { continue }
            [pscustomobject]@{
                Path = $entry.FullName; Bytes = $entry.Length
                WriteTime = $entry.LastWriteTimeUtc.ToFileTimeUtc()
                CreationTime = $entry.CreationTimeUtc.ToFileTimeUtc()
            }
        }
    }
}

function Test-CacheAppBusy($Rule, [string[]]$ProcessNames) {
    foreach ($pattern in $Rule.Busy) {
        foreach ($name in $ProcessNames) { if ($name -like $pattern) { return $true } }
    }
    return $false
}

function Initialize-CacheFileDeletion {
    if ('WindowsCacheCleanup.NativeFile' -as [type]) { return }
    # Delete only after acquiring an exclusive handle and verifying its final physical
    # path, timestamps and length. No close/reopen gap, recursive delete or ACL changes.
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace WindowsCacheCleanup {
  public static class NativeFile {
    [StructLayout(LayoutKind.Sequential)]
    struct Info {
      public uint Attributes;
      public System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write;
      public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct Disposition { [MarshalAs(UnmanagedType.Bool)] public bool Delete; }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security,
      uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetFileInformationByHandle(SafeFileHandle handle, out Info info);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern uint GetFinalPathNameByHandle(SafeFileHandle handle, StringBuilder path, uint size, uint flags);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool SetFileInformationByHandle(SafeFileHandle handle, int kind, ref Disposition info, uint size);
    static long Time(System.Runtime.InteropServices.ComTypes.FILETIME t) {
      return ((long)(uint)t.dwHighDateTime << 32) | (uint)t.dwLowDateTime;
    }
    // 0 deleted; positive Win32 error (including access denied/sharing violation);
    // -1 changed/recent, -2 unsafe physical path/type, -3 shared hard link/read-only.
    public static int Delete(string path, string root, long bytes, long write, long creation, long cutoff) {
      string expected = Path.GetFullPath(path);
      string boundary = Path.GetFullPath(root).TrimEnd('\\') + "\\";
      if (!expected.StartsWith(boundary, StringComparison.OrdinalIgnoreCase)) return -2;
      using (SafeFileHandle handle = CreateFile(expected, 0x00010080, 0, IntPtr.Zero, 3, 0x00200000, IntPtr.Zero)) {
        if (handle.IsInvalid) return Marshal.GetLastWin32Error();
        Info info;
        if (!GetFileInformationByHandle(handle, out info)) return Marshal.GetLastWin32Error();
        if ((info.Attributes & (0x10u | 0x400u | 0x4u)) != 0) return -2;
        if (info.Links != 1 || (info.Attributes & 1u) != 0) return -3;
        var finalPath = new StringBuilder(32768);
        uint length = GetFinalPathNameByHandle(handle, finalPath, (uint)finalPath.Capacity, 0);
        if (length == 0 || length >= finalPath.Capacity) return -2;
        string actual = finalPath.ToString();
        if (actual.StartsWith(@"\\?\")) actual = actual.Substring(4);
        if (!actual.Equals(expected, StringComparison.OrdinalIgnoreCase)) return -2;
        long size = ((long)info.SizeHigh << 32) | info.SizeLow;
        if (size != bytes || Time(info.Write) != write || Time(info.Creation) != creation ||
            Time(info.Write) > cutoff || Time(info.Creation) > cutoff) return -1;
        var disposition = new Disposition { Delete = true };
        if (!SetFileInformationByHandle(handle, 4, ref disposition, 4)) return Marshal.GetLastWin32Error();
      }
      return 0;
    }
  }
}
'@
}

function Invoke-WindowsCacheCleanup {
    param(
        $Context = (New-CacheCleanupContext), [switch]$Auto,
        [double]$ThresholdGB = 20, [int]$MinAgeDays = 7, [switch]$IncludeInstallers,
        [scriptblock]$ProcessProvider = { @(Get-Process -ErrorAction Stop | ForEach-Object ProcessName) },
        [scriptblock]$ShouldDelete = { param($Path) $false },
        [datetime]$NowUtc = [datetime]::UtcNow
    )
    if ($ThresholdGB -le 0 -or $MinAgeDays -lt 1) { throw 'Positive threshold and minimum age of one day are required.' }
    $rows = [Collections.Generic.List[object]]::new()
    $processes = @(& $ProcessProvider)
    foreach ($rule in @(Get-WindowsCacheRules -Context $Context -IncludeInstallers:$IncludeInstallers)) {
        $row = [pscustomobject]@{
            Category = $rule.Category; Root = $rule.Root; TotalBytes = 0L; EligibleBytes = 0L
            DeletedBytes = 0L; DeletedFiles = 0; SkippedFiles = 0; Status = 'Ready'
            Errors = [Collections.Generic.List[string]]::new(); Rule = $rule; Files = @()
            Cutoff = $NowUtc.AddDays(-[math]::Max($MinAgeDays, $rule.Age)).ToFileTimeUtc()
        }
        try {
            $all = @(Get-CacheFiles $rule.Root $rule.Patterns)
            foreach ($file in $all) { $row.TotalBytes += $file.Bytes }
            $old = @($all | Where-Object { $_.WriteTime -le $row.Cutoff -and $_.CreationTime -le $row.Cutoff })
            if ($rule.WholeRoot -and ($old.Count -ne $all.Count -or
                (Get-Item -LiteralPath $rule.Root).CreationTimeUtc.ToFileTimeUtc() -gt $row.Cutoff)) { $old = @() }
            if (-not $rule.Enabled) { $row.Status = 'Requires -IncludeInstallers' }
            elseif (Test-CacheAppBusy $rule $processes) { $row.Status = 'Application running' }
            else {
                $row.Files = $old
                foreach ($file in $old) { $row.EligibleBytes += $file.Bytes }
            }
        } catch { $row.Status = 'Scan skipped'; $row.Errors.Add($_.Exception.Message) }
        $rows.Add($row)
    }
    $eligible = 0L
    foreach ($row in $rows) { $eligible += $row.EligibleBytes }
    $result = [pscustomobject]@{
        Version = 1; StartedUtc = $NowUtc.ToString('o'); Mode = 'Report'
        ThresholdGB = $ThresholdGB; MinAgeDays = $MinAgeDays
        EligibleBytes = $eligible; DeletedBytes = 0L; DeletedFiles = 0; Rows = $rows.ToArray()
    }
    if (-not $Auto) { return $result }
    if ($eligible -lt $ThresholdGB * 1GB) { $result.Mode = 'Below threshold'; return $result }
    $result.Mode = 'Auto'
    Initialize-CacheFileDeletion
    foreach ($row in $rows) {
        if ($row.Status -ne 'Ready' -or -not $row.Files.Count) { continue }
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $first = $true
        foreach ($file in $row.Files) {
            try {
                if ($first -or $timer.ElapsedMilliseconds -ge 250) {
                    $first = $false; $timer.Restart()
                    if (Test-CacheAppBusy $row.Rule @(& $ProcessProvider)) {
                        $row.Status = 'Application started; stopped'; break
                    }
                    if ($row.Rule.Version -and (Get-CapCutCurrentVersion $row.Rule.VersionRoot) -ne $row.Rule.Version) {
                        $row.Status = 'CapCut version changed; stopped'; break
                    }
                }
                Assert-CachePlainPath $file.Path | Out-Null
                if (-not (Test-CachePathInside $file.Path $row.Root)) { throw 'File outside approved cache root.' }
                if (-not (& $ShouldDelete $file.Path)) { $row.SkippedFiles++; continue }
                $code = [WindowsCacheCleanup.NativeFile]::Delete($file.Path, $row.Root, $file.Bytes, $file.WriteTime, $file.CreationTime, $row.Cutoff)
                if ($code -ne 0) {
                    $row.SkippedFiles++
                    if ($row.Errors.Count -lt 20) { $row.Errors.Add("Skipped ($code): $($file.Path)") }
                    continue
                }
                $row.DeletedBytes += $file.Bytes; $row.DeletedFiles++
                $result.DeletedBytes += $file.Bytes; $result.DeletedFiles++
            } catch {
                $row.SkippedFiles++
                if ($row.Errors.Count -lt 20) { $row.Errors.Add($_.Exception.Message) }
            }
        }
        if ($row.Status -eq 'Ready') {
            $row.Status = if ($row.SkippedFiles) { 'Completed with skips' } else { 'Cleaned' }
        }
    }
    return $result
}

function ConvertTo-CacheCleanupReport($Result) {
    [pscustomobject]@{
        Version = $Result.Version; StartedUtc = $Result.StartedUtc; Mode = $Result.Mode
        ThresholdGB = $Result.ThresholdGB; MinAgeDays = $Result.MinAgeDays
        EligibleBytes = $Result.EligibleBytes; DeletedBytes = $Result.DeletedBytes; DeletedFiles = $Result.DeletedFiles
        Rows = @($Result.Rows | Select-Object Category, Root, TotalBytes, EligibleBytes, DeletedBytes, DeletedFiles, SkippedFiles, Status,
            @{ Name = 'Errors'; Expression = { $_.Errors.ToArray() } })
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    if ($env:OS -ne 'Windows_NT') { throw 'This tool supports Windows only.' }
    $context = New-CacheCleanupContext
    $mutex = $null; $acquired = $false; $reportStream = $null
    try {
        # Reserve the report before any deletion: a bad output path must fail early.
        if ($ReportPath -and -not $WhatIfPreference) {
            $fullReport = Assert-CachePlainPath ([IO.Path]::GetFullPath($ReportPath))
            $parent = Split-Path -Parent $fullReport
            if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            Assert-CachePlainPath $parent | Out-Null
            $reportStream = [IO.File]::Open($fullReport, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        }
        if ($Auto -and -not $WhatIfPreference) {
            $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            $mutex = [Threading.Mutex]::new($false, ('Local\WindowsCacheCleanup-' + $sid))
            try { $acquired = $mutex.WaitOne(0) }
            catch [Threading.AbandonedMutexException] { $acquired = $true }
            if (-not $acquired) { throw 'Another cache cleanup is already running.' }
        }
        $outerCmdlet = $PSCmdlet
        $decision = { param($Path) $outerCmdlet.ShouldProcess($Path, 'Delete old cache file') }.GetNewClosure()
        $result = Invoke-WindowsCacheCleanup -Context $context -Auto:$Auto -ThresholdGB $ThresholdGB -MinAgeDays $MinAgeDays -IncludeInstallers:$IncludeInstallers -ShouldDelete $decision
        if ($Auto -and $WhatIfPreference) { $result.Mode = 'WhatIf' }
        $report = ConvertTo-CacheCleanupReport $result
        $report.Rows | Where-Object { $_.TotalBytes -gt 0 -or $_.Errors.Count } |
            Select-Object Category, @{n='TotalGiB';e={[math]::Round($_.TotalBytes/1GB,2)}},
                @{n='EligibleGiB';e={[math]::Round($_.EligibleBytes/1GB,2)}},
                @{n='DeletedGiB';e={[math]::Round($_.DeletedBytes/1GB,2)}}, Status | Format-Table -AutoSize
        Write-Host ('{0}: eligible {1:N2} GiB; deleted {2:N2} GiB ({3} files).' -f $report.Mode,($report.EligibleBytes/1GB),($report.DeletedBytes/1GB),$report.DeletedFiles)
        if ($reportStream) {
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($report | ConvertTo-Json -Depth 6))
            $reportStream.Write($bytes, 0, $bytes.Length)
            Write-Host "Report: $fullReport"
        }
    } finally {
        if ($reportStream) { $reportStream.Dispose() }
        if ($acquired) { $mutex.ReleaseMutex() }
        if ($mutex) { $mutex.Dispose() }
    }
}
