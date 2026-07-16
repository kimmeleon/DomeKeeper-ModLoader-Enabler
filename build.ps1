#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$Version,
    [string]$GdreZipPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = [IO.Path]::GetFullPath($PSScriptRoot)
if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = (Get-Content -LiteralPath (Join-Path $root "VERSION") -Raw).Trim()
}

function Remove-TreeInsideRepository {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $rootPrefix = $root.TrimEnd("\") + "\"
    if (-not $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove a directory outside the repository: $fullPath"
    }
    if (Test-Path -LiteralPath $fullPath) {
        Remove-Item -LiteralPath $fullPath -Recurse -Force
    }
}

function Wait-ForFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$TimeoutSeconds = 60
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            return
        }
        Start-Sleep -Milliseconds 250
    }
    throw "Timed out waiting for generated file: $Path"
}

$config = Get-Content -LiteralPath (Join-Path $root "supported-builds.json") -Raw | ConvertFrom-Json
$buildRoot = Join-Path $root ".build"
$artifactsRoot = Join-Path $root "artifacts"
Remove-TreeInsideRepository -Path $buildRoot
Remove-TreeInsideRepository -Path $artifactsRoot
New-Item -ItemType Directory -Force -Path $buildRoot, $artifactsRoot | Out-Null

$gdreArchive = Join-Path $buildRoot "gdre-tools.zip"
if ([string]::IsNullOrWhiteSpace($GdreZipPath)) {
    Write-Host "Downloading GDRE Tools $($config.gdre.version)..."
    Invoke-WebRequest -Uri ([string]$config.gdre.releaseUrl) -OutFile $gdreArchive -UseBasicParsing
}
else {
    Copy-Item -LiteralPath (Resolve-Path -LiteralPath $GdreZipPath).Path -Destination $gdreArchive
}

$archiveHash = (Get-FileHash -LiteralPath $gdreArchive -Algorithm SHA256).Hash.ToUpperInvariant()
if ($archiveHash -ne ([string]$config.gdre.archiveSha256).ToUpperInvariant()) {
    throw "GDRE Tools archive SHA-256 mismatch. Expected $($config.gdre.archiveSha256), got $archiveHash."
}

$gdreRoot = Join-Path $buildRoot "gdre"
Expand-Archive -LiteralPath $gdreArchive -DestinationPath $gdreRoot -Force
$gdreExe = (Get-ChildItem -LiteralPath $gdreRoot -Recurse -File -Filter "gdre_tools.exe" | Select-Object -First 1).FullName
if ([string]::IsNullOrWhiteSpace($gdreExe)) {
    throw "gdre_tools.exe was not found in the verified archive."
}
$gdreBinRoot = Split-Path -Parent $gdreExe

foreach ($property in $config.gdre.files.PSObject.Properties) {
    $componentPath = Join-Path $gdreBinRoot $property.Name
    if (-not (Test-Path -LiteralPath $componentPath -PathType Leaf)) {
        throw "Missing GDRE Tools component: $($property.Name)"
    }
    $componentHash = (Get-FileHash -LiteralPath $componentPath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($componentHash -ne ([string]$property.Value).ToUpperInvariant()) {
        throw "GDRE Tools component SHA-256 mismatch: $($property.Name)"
    }
}

$buildDefinition = @($config.builds) | Select-Object -First 1
$patchBuildRoot = Join-Path $buildRoot "resource-project"
New-Item -ItemType Directory -Force -Path $patchBuildRoot | Out-Null
Copy-Item -LiteralPath (Join-Path $root "src\patches\project.godot") -Destination (Join-Path $patchBuildRoot "project.godot")

$compiledPatches = @()
foreach ($patchDefinition in @($buildDefinition.patches)) {
    $resourcePath = [string]$patchDefinition.resourcePath
    if (-not $resourcePath.StartsWith("res://", [StringComparison]::Ordinal)) {
        throw "Patch resourcePath must start with res://: $resourcePath"
    }

    $relativeResourcePath = $resourcePath.Substring(6).Replace("/", "\")
    $patchSource = Join-Path $root ([string]$patchDefinition.sourcePath)
    $resourceProjectSource = Join-Path $patchBuildRoot $relativeResourcePath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resourceProjectSource) | Out-Null
    Copy-Item -LiteralPath $patchSource -Destination $resourceProjectSource

    $binaryName = [IO.Path]::GetFileNameWithoutExtension($relativeResourcePath) + ".res"
    $patchBinary = Join-Path $patchBuildRoot $binaryName
    Write-Host "Compiling $resourcePath..."
    $compileArguments = @(
        '"--path"',
        ('"{0}"' -f $patchBuildRoot.Replace('"', '\"')),
        '"--headless"',
        ('"--txt-to-bin={0}"' -f $resourcePath.Replace('"', '\"'))
    )
    $compileProcess = Start-Process -FilePath $gdreExe -ArgumentList $compileArguments -WorkingDirectory $patchBuildRoot -Wait -PassThru -NoNewWindow
    if ($compileProcess.ExitCode -ne 0) {
        throw "GDRE Tools resource compilation failed with exit code $($compileProcess.ExitCode): $resourcePath"
    }
    Wait-ForFile -Path $patchBinary

    $patchHash = (Get-FileHash -LiteralPath $patchBinary -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($patchHash -ne ([string]$patchDefinition.sha256).ToUpperInvariant()) {
        throw "Generated patch SHA-256 mismatch for $resourcePath. Expected $($patchDefinition.sha256), got $patchHash."
    }
    $compiledPatches += [PSCustomObject]@{
        BinaryPath = $patchBinary
        PackagePath = [string]$patchDefinition.packagePath
    }
}

$packageName = "DomeKeeper-ModLoader-Enabler-v$Version"
$packageRoot = Join-Path $buildRoot $packageName
New-Item -ItemType Directory -Force -Path $packageRoot | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $packageRoot "scripts"), (Join-Path $packageRoot "patches"), (Join-Path $packageRoot "tools\gdre"), (Join-Path $packageRoot "third_party") | Out-Null

Copy-Item -Path (Join-Path $root "src\launchers\*.bat") -Destination $packageRoot
Copy-Item -LiteralPath (Join-Path $root "src\scripts\DomeKeeperModLoader.ps1") -Destination (Join-Path $packageRoot "scripts")
foreach ($compiledPatch in $compiledPatches) {
    $packagePatchPath = Join-Path $packageRoot $compiledPatch.PackagePath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $packagePatchPath) | Out-Null
    Copy-Item -LiteralPath $compiledPatch.BinaryPath -Destination $packagePatchPath
}
Copy-Item -LiteralPath (Join-Path $root "src\release\README.txt") -Destination (Join-Path $packageRoot "README.txt")
Copy-Item -LiteralPath (Join-Path $root "supported-builds.json"), (Join-Path $root "VERSION"), (Join-Path $root "LICENSE"), (Join-Path $root "THIRD_PARTY_NOTICES.md") -Destination $packageRoot
Copy-Item -Path (Join-Path $root "third_party\*") -Destination (Join-Path $packageRoot "third_party")

foreach ($property in $config.gdre.files.PSObject.Properties) {
    Copy-Item -LiteralPath (Join-Path $gdreBinRoot $property.Name) -Destination (Join-Path $packageRoot "tools\gdre")
}

$zipPath = Join-Path $artifactsRoot "$packageName.zip"
Compress-Archive -LiteralPath $packageRoot -DestinationPath $zipPath -CompressionLevel Optimal
$zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$checksumPath = Join-Path $artifactsRoot "$packageName.sha256"
Set-Content -LiteralPath $checksumPath -Value "$zipHash *$packageName.zip" -Encoding ASCII

Write-Host ""
Write-Host "Built: $zipPath" -ForegroundColor Green
Write-Host "SHA-256: $zipHash"
