#Requires -Version 5.1
[CmdletBinding()]
param()

function Remove-ExpiredCleanupReports {
    param([string]$Directory, [string]$Cleaner, [int]$Keep = 30, [int]$AgeDays = 30)
    . $Cleaner
    Assert-CachePlainPath $Directory | Out-Null
    $files = @(Get-ChildItem -LiteralPath $Directory -File -Force -ErrorAction Stop |
        Where-Object { $_.Name -match '^cleanup-[0-9]{8}-[0-9]{6}-[a-f0-9]{32}(?:-error)?\.json$' -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
        Sort-Object LastWriteTimeUtc -Descending)
    $cutoff = [datetime]::UtcNow.AddDays(-$AgeDays).ToFileTimeUtc()
    Initialize-CacheFileDeletion
    $removed = 0
    foreach ($file in @($files | Select-Object -Skip $Keep)) {
        if ($file.CreationTimeUtc.ToFileTimeUtc() -gt $cutoff -or $file.LastWriteTimeUtc.ToFileTimeUtc() -gt $cutoff) { continue }
        $result = [WindowsCacheCleanup.NativeFile]::Delete($file.FullName, $Directory, $file.Length, $file.LastWriteTimeUtc.ToFileTimeUtc(), $file.CreationTimeUtc.ToFileTimeUtc(), $cutoff)
        if ($result -eq 0) { $removed++ }
    }
    return $removed
}
function Invoke-ScheduledCleanup {
    param([string]$Release = $PSScriptRoot)
    $cleaner = Join-Path $Release 'windows-cache-cleanup.ps1'
    $settings = Join-Path $Release 'settings.json'
    # Load validators in a child scope so the cleaner's parameters cannot reset ours.
    $validate = { param($Path, $Source) . $Source; Assert-CachePlainPath $Path }
    & $validate $Release $cleaner | Out-Null
    & $validate $settings $cleaner | Out-Null
    $config = Get-Content -LiteralPath $settings -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
    $number = $config.ThresholdGB -is [double] -or $config.ThresholdGB -is [decimal] -or $config.ThresholdGB -is [int] -or $config.ThresholdGB -is [long]
    $integer = $config.MinAgeDays -is [int] -or $config.MinAgeDays -is [long]
    if ($config.SchemaVersion -ne 1 -or -not $number -or [double]::IsNaN([double]$config.ThresholdGB) -or $config.ThresholdGB -lt 0.001 -or $config.ThresholdGB -gt 100000 -or
        -not $integer -or $config.MinAgeDays -lt 1 -or $config.MinAgeDays -gt 3650 -or
        $config.ReportOnly -isnot [bool] -or $config.IncludeInstallers -isnot [bool]) { throw 'Invalid scheduler settings; nothing was cleaned.' }
    $root = Split-Path -Parent (Split-Path -Parent $Release)
    $reports = Join-Path $root 'reports'
    & $validate $reports $cleaner | Out-Null
    New-Item -ItemType Directory -Path $reports -Force -ErrorAction Stop | Out-Null
    $id = 'cleanup-' + [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N')
    $path = Join-Path $reports ($id + '.json')
    try {
        & $cleaner -Auto:(!$config.ReportOnly) -ThresholdGB $config.ThresholdGB -MinAgeDays $config.MinAgeDays -IncludeInstallers:$config.IncludeInstallers -ReportPath $path
        if (-not $config.ReportOnly) {
            $removed = Remove-ExpiredCleanupReports -Directory $reports -Cleaner $cleaner
            Write-Host "Expired local reports removed: $removed"
        }
    } catch {
        $errorPath = Join-Path $reports ($id + '-error.json')
        $failure = @{ SchemaVersion = 1; Mode = 'Failed'; CapturedUtc = [datetime]::UtcNow.ToString('o'); Error = $_.Exception.Message }
        [IO.File]::WriteAllText($errorPath, ($failure | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        throw
    }
}
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    Invoke-ScheduledCleanup
}
