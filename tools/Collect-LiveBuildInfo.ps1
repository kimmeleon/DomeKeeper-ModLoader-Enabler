#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$GamePath,
    [string]$OutputPath,
    [switch]$KeepPatchedPck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$config = Get-Content -LiteralPath (Join-Path $root "supported-builds.json") -Raw | ConvertFrom-Json

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-AcfValue {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $pattern = '(?m)^\s*"' + [regex]::Escape($Name) + '"\s*"([^"]*)"\s*$'
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) {
        return ""
    }
    return $match.Groups[1].Value
}

function Resolve-GamePath {
    param([string]$RequestedPath)

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        return (Resolve-Path -LiteralPath $RequestedPath -ErrorAction Stop).Path
    }

    $roots = @()
    $steamRegistry = @(
        'HKCU:\Software\Valve\Steam',
        'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
        'HKLM:\SOFTWARE\Valve\Steam'
    )
    foreach ($key in $steamRegistry) {
        try {
            $steamPath = (Get-ItemProperty -Path $key -Name SteamPath -ErrorAction Stop).SteamPath
            if (-not [string]::IsNullOrWhiteSpace($steamPath)) { $roots += $steamPath }
        } catch { }
    }
    if ($roots.Count -eq 0) {
        $roots += @(
            (Join-Path ${env:ProgramFiles(x86)} 'Steam'),
            (Join-Path ${env:ProgramFiles} 'Steam')
        )
    }

    $libraryRoots = @()
    foreach ($steamRoot in ($roots | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $steamRoot -PathType Container)) { continue }
        $libraryRoots += $steamRoot
        $vdf = Join-Path $steamRoot 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf -PathType Leaf) {
            $text = Get-Content -LiteralPath $vdf -Raw
            foreach ($match in [regex]::Matches($text, '"path"\s*"([^"]+)"')) {
                $libraryRoots += $match.Groups[1].Value.Replace('\\', '\')
            }
        }
    }

    foreach ($libraryRoot in ($libraryRoots | Select-Object -Unique)) {
        $manifest = Join-Path $libraryRoot "steamapps\appmanifest_$($config.appId).acf"
        if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { continue }
        $manifestText = Get-Content -LiteralPath $manifest -Raw
        $installDir = Get-AcfValue -Text $manifestText -Name 'installdir'
        if ([string]::IsNullOrWhiteSpace($installDir)) { continue }
        $candidate = Join-Path $libraryRoot "steamapps\common\$installDir"
        if ((Test-Path -LiteralPath (Join-Path $candidate 'domekeeper.exe') -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $candidate 'domekeeper.pck') -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw "Dome Keeper was not found automatically. Re-run with -GamePath '<Steam game folder>'."
}

$game = Resolve-GamePath -RequestedPath $GamePath
$steamApps = Split-Path -Parent (Split-Path -Parent $game)
$manifestPath = Join-Path $steamApps "appmanifest_$($config.appId).acf"
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Steam app manifest not found next to the supplied game folder: $manifestPath"
}
$manifestText = Get-Content -LiteralPath $manifestPath -Raw
$buildId = Get-AcfValue -Text $manifestText -Name 'buildid'
$beta = (Get-AcfValue -Text $manifestText -Name 'BetaKey').ToLowerInvariant()

# Steam may record the default public branch as BetaKey="public".
# Treat both an empty value and "public" as the live/public branch; staging remains explicit.
if ($beta -ne '' -and $beta -ne 'public') {
    throw "The selected installation is not the public/live branch. BetaKey='$beta'. Supply the public Dome Keeper installation with -GamePath."
}
if ($buildId -ne '25038893') {
    throw "The selected public installation is build $buildId, not the current live build 25038893. Update Dome Keeper first."
}

$pckPath = Join-Path $game 'domekeeper.pck'
$exePath = Join-Path $game 'domekeeper.exe'
$cleanPckSha256 = Get-Sha256 -Path $pckPath
$exeSha256 = Get-Sha256 -Path $exePath

Write-Host "Public build: $buildId"
Write-Host "Public branch marker: $(if ($beta -eq '') { '<empty>' } else { $beta })"
Write-Host "Game path: $game"
Write-Host "domekeeper.exe SHA-256: $exeSha256"
Write-Host "domekeeper.pck SHA-256: $cleanPckSha256"
Write-Host ""
Write-Host "Preparing the verified GDRE patch with build.ps1..."
& (Join-Path $root 'build.ps1')
if ($LASTEXITCODE -ne 0) {
    throw "build.ps1 failed with exit code $LASTEXITCODE."
}

$buildDefinition = @($config.builds) | Select-Object -First 1
if ($null -eq $buildDefinition) { throw 'supported-builds.json contains no build definition.' }
$patchDefinition = @($buildDefinition.patches) | Select-Object -First 1
if ($null -eq $patchDefinition) { throw 'The existing build definition contains no patch definition.' }

$gdreExe = Join-Path $root '.build\gdre\gdre_tools.exe'
$patchPath = Join-Path $root '.build\resource-project\options.res'
if (-not (Test-Path -LiteralPath $gdreExe -PathType Leaf)) { throw "GDRE Tools executable was not produced: $gdreExe" }
if (-not (Test-Path -LiteralPath $patchPath -PathType Leaf)) { throw "Compiled patch was not produced: $patchPath" }

$patchHash = Get-Sha256 -Path $patchPath
if ($patchHash -ne ([string]$patchDefinition.sha256).ToUpperInvariant()) {
    throw "Compiled patch hash mismatch. Expected $($patchDefinition.sha256), got $patchHash."
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path ([IO.Path]::GetTempPath()) ("DomeKeeper-25038893-patched-{0}.pck" -f ([guid]::NewGuid().ToString('N')))
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
$outputDir = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Force }

$args = @(
    '--headless',
    "--pck-patch=$pckPath",
    "--output=$OutputPath",
    "--patch-file=$patchPath=$($patchDefinition.target)"
)
$quotedArgs = foreach ($arg in $args) { '"' + $arg.Replace('"', '\"') + '"' }
Write-Host "Patching a temporary copy of domekeeper.pck. The installed game file will not be modified..."
$process = Start-Process -FilePath $gdreExe -ArgumentList $quotedArgs -WorkingDirectory (Split-Path -Parent $gdreExe) -Wait -PassThru -NoNewWindow
if ($process.ExitCode -ne 0) {
    if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue }
    throw "GDRE Tools PCK patch failed with exit code $($process.ExitCode)."
}
if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
    throw "GDRE Tools completed but did not create the expected patched PCK: $OutputPath"
}

$patchedPckSha256 = Get-Sha256 -Path $OutputPath
Write-Host "Patched PCK SHA-256: $patchedPckSha256"
Write-Host ""
Write-Host "Copy these values into supported-builds.json for the public beta:'' entry:" -ForegroundColor Green
$result = [ordered]@{
    buildId = $buildId
    beta = 'public'
    cleanPckSha256 = $cleanPckSha256
    patchedPckSha256 = $patchedPckSha256
    exeSha256 = $exeSha256
    patchSha256 = $patchHash
    patchTarget = [string]$patchDefinition.target
}
$result | ConvertTo-Json

if (-not $KeepPatchedPck) {
    Remove-Item -LiteralPath $OutputPath -Force
    Write-Host "Temporary patched PCK removed."
} else {
    Write-Host "Temporary patched PCK retained at: $OutputPath"
}
