#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateSet("Enable", "Disable", "Status")]
    [string]$Action = "Status",

    [string]$GamePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:AppId = "1637320"
$script:SteamDataContent = '{"app_id":1637320}'
$script:LogPath = $null

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[ OK ] $Message" -ForegroundColor Green
}

function Write-WarningMessage {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Log {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($script:LogPath)) {
        return
    }

    $line = "{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $Message
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-AcfValue {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $pattern = '(?im)^\s*"' + [regex]::Escape($Name) + '"\s*"([^"]*)"'
    $match = [regex]::Match($Text, $pattern)
    if ($match.Success) {
        return $match.Groups[1].Value
    }
    return ""
}

function Add-UniquePath {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    $fullPath = [IO.Path]::GetFullPath($Path.Replace("/", "\"))
    foreach ($existing in $List) {
        if ($existing.Equals($fullPath, [StringComparison]::OrdinalIgnoreCase)) {
            return
        }
    }
    $List.Add($fullPath)
}

function Get-SteamRoots {
    $roots = New-Object 'System.Collections.Generic.List[string]'

    foreach ($registryPath in @(
        "HKCU:\Software\Valve\Steam",
        "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam",
        "HKLM:\SOFTWARE\Valve\Steam"
    )) {
        try {
            $properties = Get-ItemProperty -LiteralPath $registryPath -ErrorAction Stop
            if ($properties.PSObject.Properties.Name -contains "SteamPath") {
                Add-UniquePath -List $roots -Path $properties.SteamPath
            }
            if ($properties.PSObject.Properties.Name -contains "InstallPath") {
                Add-UniquePath -List $roots -Path $properties.InstallPath
            }
        }
        catch {
            # Registry location is optional.
        }
    }

    Add-UniquePath -List $roots -Path "${env:ProgramFiles(x86)}\Steam"

    $allLibraries = New-Object 'System.Collections.Generic.List[string]'
    foreach ($steamRoot in $roots) {
        if (-not (Test-Path -LiteralPath $steamRoot -PathType Container)) {
            continue
        }

        Add-UniquePath -List $allLibraries -Path $steamRoot
        $libraryFile = Join-Path $steamRoot "steamapps\libraryfolders.vdf"
        if (-not (Test-Path -LiteralPath $libraryFile -PathType Leaf)) {
            continue
        }

        $libraryText = Get-Content -LiteralPath $libraryFile -Raw
        foreach ($match in [regex]::Matches($libraryText, '"path"\s*"([^"]+)"')) {
            Add-UniquePath -List $allLibraries -Path $match.Groups[1].Value.Replace("\\", "\")
        }
    }

    return $allLibraries
}

function New-InstallationInfo {
    param(
        [Parameter(Mandatory = $true)][string]$ResolvedGamePath,
        [Parameter(Mandatory = $true)][string]$ManifestPath
    )

    $pckPath = Join-Path $ResolvedGamePath "domekeeper.pck"
    $exePath = Join-Path $ResolvedGamePath "domekeeper.exe"
    if (-not (Test-Path -LiteralPath $pckPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $exePath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        return $null
    }

    $manifestText = Get-Content -LiteralPath $ManifestPath -Raw
    return [PSCustomObject]@{
        GamePath = [IO.Path]::GetFullPath($ResolvedGamePath)
        ManifestPath = [IO.Path]::GetFullPath($ManifestPath)
        ManifestText = $manifestText
        BuildId = Get-AcfValue -Text $manifestText -Name "buildid"
        Beta = (Get-AcfValue -Text $manifestText -Name "BetaKey").ToLowerInvariant()
        PckPath = $pckPath
        ExePath = $exePath
    }
}

function Find-GameInstallation {
    param([string]$RequestedPath)

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        $resolved = (Resolve-Path -LiteralPath $RequestedPath -ErrorAction Stop).Path
        $commonPath = Split-Path -Parent $resolved
        $steamAppsPath = Split-Path -Parent $commonPath
        $manifestPath = Join-Path $steamAppsPath "appmanifest_$($script:AppId).acf"
        $installation = New-InstallationInfo -ResolvedGamePath $resolved -ManifestPath $manifestPath
        if ($null -eq $installation) {
            throw "The requested folder is not a complete Steam installation of Dome Keeper: $resolved"
        }
        return $installation
    }

    $installations = @()
    foreach ($libraryRoot in Get-SteamRoots) {
        $manifestPath = Join-Path $libraryRoot "steamapps\appmanifest_$($script:AppId).acf"
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            continue
        }

        $manifestText = Get-Content -LiteralPath $manifestPath -Raw
        $installDir = Get-AcfValue -Text $manifestText -Name "installdir"
        if ([string]::IsNullOrWhiteSpace($installDir)) {
            continue
        }

        $candidatePath = Join-Path $libraryRoot "steamapps\common\$installDir"
        $installation = New-InstallationInfo -ResolvedGamePath $candidatePath -ManifestPath $manifestPath
        if ($null -ne $installation) {
            $installations += $installation
        }
    }

    if ($installations.Count -eq 0) {
        throw "Dome Keeper was not found. Run this script with -GamePath '<Steam game folder>'."
    }

    $stagingInstall = $installations | Where-Object { $_.Beta -eq "staging" } | Select-Object -First 1
    if ($null -ne $stagingInstall) {
        return $stagingInstall
    }
    return $installations[0]
}

function Find-PackageRoot {
    $candidate = Split-Path -Parent $PSScriptRoot
    for ($i = 0; $i -lt 3; $i++) {
        if (Test-Path -LiteralPath (Join-Path $candidate "supported-builds.json") -PathType Leaf) {
            return $candidate
        }
        $parent = Split-Path -Parent $candidate
        if ($parent -eq $candidate) {
            break
        }
        $candidate = $parent
    }
    throw "supported-builds.json was not found near this script. Re-extract the complete release ZIP."
}

function Get-SupportedBuild {
    param([Parameter(Mandatory = $true)]$Installation)

    return @($script:Config.builds) | Where-Object {
        ([string]$_.buildId -eq $Installation.BuildId) -and
        ([string]$_.beta -eq $Installation.Beta)
    } | Select-Object -First 1
}

function Assert-GameStopped {
    if ($null -ne (Get-Process -Name "domekeeper" -ErrorAction SilentlyContinue)) {
        throw "Dome Keeper is running. Close the game before continuing."
    }
}

function Assert-PathInside {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd("\") + "\"
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not $fullPath.StartsWith($fullRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to modify a path outside the game folder: $fullPath"
    }
}

function Remove-SafeFile {
    param(
        [Parameter(Mandatory = $true)][string]$GameRoot,
        [Parameter(Mandatory = $true)][string]$Path
    )

    Assert-PathInside -Root $GameRoot -Path $Path
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Remove-Item -LiteralPath $Path -Force
    }
}

function Get-SteamDataPath {
    param([Parameter(Mandatory = $true)]$Installation)
    return Join-Path $Installation.GamePath "steam_data.json"
}

function Test-SteamDataValid {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    try {
        $data = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        return ($data.PSObject.Properties.Name -contains "app_id") -and
            ([string]$data.app_id -eq $script:AppId)
    }
    catch {
        return $false
    }
}

function Ensure-SteamData {
    param([Parameter(Mandatory = $true)]$Installation)

    $path = Get-SteamDataPath -Installation $Installation
    Assert-PathInside -Root $Installation.GamePath -Path $path
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        if (-not (Test-SteamDataValid -Path $path)) {
            throw "An incompatible steam_data.json already exists. The tool will not overwrite it: $path"
        }
        Write-Info "Using the existing valid Dome Keeper Steam App ID configuration."
        return $false
    }

    Write-Info "Creating the Steam Workshop App ID configuration..."
    $utf8WithoutBom = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($path, $script:SteamDataContent, $utf8WithoutBom)
    if ((Get-Content -LiteralPath $path -Raw) -ne $script:SteamDataContent) {
        throw "steam_data.json verification failed."
    }
    return $true
}

function Remove-ManagedSteamData {
    param([Parameter(Mandatory = $true)]$Installation)

    $path = Get-SteamDataPath -Installation $Installation
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return
    }

    $content = Get-Content -LiteralPath $path -Raw
    if ($content -eq $script:SteamDataContent) {
        Remove-SafeFile -GameRoot $Installation.GamePath -Path $path
        Write-Info "Removed the managed Steam Workshop App ID configuration."
    }
    else {
        Write-WarningMessage "steam_data.json was not created exactly by this tool and was left unchanged."
    }
}

function Get-StatePaths {
    param(
        [Parameter(Mandatory = $true)]$Installation,
        [Parameter(Mandatory = $true)][string]$BuildId
    )

    $stateRoot = Join-Path $Installation.GamePath ".domekeeper-modloader-enabler"
    return [PSCustomObject]@{
        StateRoot = $stateRoot
        BackupPath = Join-Path $stateRoot "backup\$BuildId\domekeeper.pck"
        WorkPath = Join-Path $stateRoot "work\domekeeper.patched.pck"
        RemovePath = Join-Path $stateRoot "work\domekeeper.remove.pck"
        StateFile = Join-Path $stateRoot "state.json"
        LogFile = Join-Path $stateRoot "enabler.log"
    }
}

function Assert-PackageIntegrity {
    param([Parameter(Mandatory = $true)]$Build)

    $patches = @()
    foreach ($patch in @($Build.patches)) {
        $patchPath = Join-Path $script:PackageRoot ([string]$patch.packagePath)
        if (-not (Test-Path -LiteralPath $patchPath -PathType Leaf)) {
            throw "Patch resource is missing: $patchPath"
        }
        if ((Get-Sha256 -Path $patchPath) -ne ([string]$patch.sha256).ToUpperInvariant()) {
            throw "Patch resource hash mismatch: $($patch.packagePath)"
        }
        $patches += [PSCustomObject]@{
            PatchPath = $patchPath
            PatchTarget = [string]$patch.target
        }
    }
    if ($patches.Count -eq 0) {
        throw "No patch resources are defined for this supported build."
    }

    foreach ($property in $script:Config.gdre.files.PSObject.Properties) {
        $toolPath = Join-Path $script:PackageRoot ("tools\gdre\" + $property.Name)
        if (-not (Test-Path -LiteralPath $toolPath -PathType Leaf)) {
            throw "GDRE Tools component is missing: $toolPath"
        }
        if ((Get-Sha256 -Path $toolPath) -ne ([string]$property.Value).ToUpperInvariant()) {
            throw "GDRE Tools component hash mismatch: $($property.Name)"
        }
    }

    return [PSCustomObject]@{
        Patches = $patches
        GdrePath = Join-Path $script:PackageRoot "tools\gdre\gdre_tools.exe"
    }
}

function Wait-ForCompletedFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][long]$MinimumLength,
        [int]$TimeoutSeconds = 300
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $previousLength = -1L
    $stableChecks = 0

    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $length = (Get-Item -LiteralPath $Path).Length
            if ($length -ge $MinimumLength -and $length -eq $previousLength) {
                $stableChecks++
            }
            else {
                $stableChecks = 0
            }
            $previousLength = $length

            if ($stableChecks -ge 2) {
                try {
                    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
                    $stream.Dispose()
                    return
                }
                catch {
                    $stableChecks = 0
                }
            }
        }
        Start-Sleep -Milliseconds 500
    }

    throw "Timed out waiting for GDRE Tools to create: $Path"
}

function Invoke-GdrePatch {
    param(
        [Parameter(Mandatory = $true)][string]$GdrePath,
        [Parameter(Mandatory = $true)][object[]]$Patches,
        [Parameter(Mandatory = $true)][string]$SourcePck,
        [Parameter(Mandatory = $true)][string]$DestinationPck
    )

    $arguments = @(
        "--headless",
        "--pck-patch=$SourcePck",
        "--output=$DestinationPck"
    )
    foreach ($patch in $Patches) {
        $arguments += "--patch-file=$($patch.PatchPath)=$($patch.PatchTarget)"
    }

    $quotedArguments = foreach ($argument in $arguments) {
        '"' + $argument.Replace('"', '\"') + '"'
    }
    $logRoot = Split-Path -Parent $DestinationPck
    $stdoutPath = Join-Path $logRoot "gdre.stdout.log"
    $stderrPath = Join-Path $logRoot "gdre.stderr.log"
    if (Test-Path -LiteralPath $stdoutPath) {
        Remove-Item -LiteralPath $stdoutPath -Force
    }
    if (Test-Path -LiteralPath $stderrPath) {
        Remove-Item -LiteralPath $stderrPath -Force
    }

    Write-Log "Starting GDRE Tools PCK patch."
    $process = Start-Process -FilePath $GdrePath -ArgumentList $quotedArguments -WorkingDirectory (Split-Path -Parent $GdrePath) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    foreach ($outputPath in @($stdoutPath, $stderrPath)) {
        if (Test-Path -LiteralPath $outputPath) {
            foreach ($line in Get-Content -LiteralPath $outputPath) {
                Write-Log "GDRE: $line"
            }
            Remove-Item -LiteralPath $outputPath -Force
        }
    }
    if ($process.ExitCode -ne 0) {
        throw "GDRE Tools failed with exit code $($process.ExitCode)."
    }

    Wait-ForCompletedFile -Path $DestinationPck -MinimumLength 1000000000
}

function Write-State {
    param(
        [Parameter(Mandatory = $true)]$Paths,
        [Parameter(Mandatory = $true)]$Installation,
        [Parameter(Mandatory = $true)]$Build,
        [Parameter(Mandatory = $true)][string]$Status
    )

    $state = [ordered]@{
        toolVersion = $script:PackageVersion
        status = $Status
        changedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        appId = $script:AppId
        gamePath = $Installation.GamePath
        beta = $Installation.Beta
        buildId = $Installation.BuildId
        cleanPckSha256 = ([string]$Build.cleanPckSha256).ToUpperInvariant()
        patchedPckSha256 = ([string]$Build.patchedPckSha256).ToUpperInvariant()
        backupPath = $Paths.BackupPath
        patchTargets = @($Build.patches | ForEach-Object { [string]$_.target })
        steamDataPath = Get-SteamDataPath -Installation $Installation
        gdreVersion = [string]$script:Config.gdre.version
    }
    $state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Paths.StateFile -Encoding UTF8
}

function Show-Status {
    param([Parameter(Mandatory = $true)]$Installation)

    Write-Host ""
    Write-Host "Dome Keeper Mod Loader Enabler $script:PackageVersion"
    Write-Host "Game folder : $($Installation.GamePath)"
    Write-Host "Steam beta  : $($Installation.Beta)"
    Write-Host "Build ID    : $($Installation.BuildId)"
    Write-Info "Hashing domekeeper.pck..."
    $pckHash = Get-Sha256 -Path $Installation.PckPath
    Write-Host "PCK SHA-256 : $pckHash"

    $build = Get-SupportedBuild -Installation $Installation
    if ($null -eq $build) {
        Write-WarningMessage "This beta/build is not supported by this tool release."
        return
    }

    $paths = Get-StatePaths -Installation $Installation -BuildId $Installation.BuildId
    $steamDataPath = Get-SteamDataPath -Installation $Installation
    $steamDataReady = Test-SteamDataValid -Path $steamDataPath
    if ($pckHash -eq ([string]$build.cleanPckSha256).ToUpperInvariant()) {
        Write-Ok "Status: disabled (exact clean Steam staging PCK)."
        if (Test-Path -LiteralPath $steamDataPath -PathType Leaf) {
            Write-WarningMessage "A steam_data.json file remains, but the PCK is clean and mods are disabled."
        }
    }
    elseif ($pckHash -eq ([string]$build.patchedPckSha256).ToUpperInvariant()) {
        if ($steamDataReady) {
            Write-Ok "Status: enabled. Local and Steam Workshop mod loading are active."
        }
        else {
            Write-WarningMessage "Status: partially enabled. Run Enable Mod Loader.bat to repair Steam Workshop loading."
        }
    }
    else {
        Write-WarningMessage "Status: unknown PCK. The tool will not modify it."
    }

    if (Test-Path -LiteralPath $paths.BackupPath -PathType Leaf) {
        Write-Host "Backup      : $($paths.BackupPath)"
    }
    else {
        Write-Host "Backup      : none"
    }
}

function Enable-ModLoader {
    param([Parameter(Mandatory = $true)]$Installation)

    Assert-GameStopped
    $build = Get-SupportedBuild -Installation $Installation
    if ($null -eq $build) {
        throw "Unsupported Steam beta/build. Required beta: staging. Installed build: $($Installation.BuildId)."
    }

    Write-Info "Hashing the current Steam files..."
    $pckHash = Get-Sha256 -Path $Installation.PckPath
    $cleanHash = ([string]$build.cleanPckSha256).ToUpperInvariant()
    $patchedHash = ([string]$build.patchedPckSha256).ToUpperInvariant()
    $alreadyPatched = $pckHash -eq $patchedHash
    if ($pckHash -ne $cleanHash -and -not $alreadyPatched) {
        throw "domekeeper.pck is not the supported clean Steam file. Use Steam 'Verify integrity of game files', then try again."
    }

    $exeHash = Get-Sha256 -Path $Installation.ExePath
    if ($exeHash -ne ([string]$build.exeSha256).ToUpperInvariant()) {
        throw "domekeeper.exe does not match the supported staging build."
    }

    $package = Assert-PackageIntegrity -Build $build
    $paths = Get-StatePaths -Installation $Installation -BuildId $Installation.BuildId
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $paths.BackupPath), (Split-Path -Parent $paths.WorkPath) | Out-Null
    $script:LogPath = $paths.LogFile
    Write-Log "Enable requested for build $($Installation.BuildId)."

    if (-not $alreadyPatched) {
        $driveName = [IO.Path]::GetPathRoot($Installation.GamePath).Substring(0, 1)
        $freeBytes = (Get-PSDrive -Name $driveName).Free
        $requiredBytes = (Get-Item -LiteralPath $Installation.PckPath).Length + 268435456
        if ($freeBytes -lt $requiredBytes) {
            throw "Not enough free space. At least $([Math]::Ceiling($requiredBytes / 1GB)) GB is required."
        }

        if (Test-Path -LiteralPath $paths.BackupPath -PathType Leaf) {
            if ((Get-Sha256 -Path $paths.BackupPath) -ne $cleanHash) {
                throw "An unexpected backup already exists: $($paths.BackupPath)"
            }
            Remove-SafeFile -GameRoot $Installation.GamePath -Path $paths.BackupPath
        }
        Remove-SafeFile -GameRoot $Installation.GamePath -Path $paths.WorkPath
    }

    $steamDataCreated = Ensure-SteamData -Installation $Installation
    if ($alreadyPatched) {
        Write-State -Paths $paths -Installation $Installation -Build $build -Status "enabled"
        Write-Log "Existing PCK installation repaired for Steam Workshop loading."
        Write-Ok "Mod Loader is enabled and Steam Workshop loading is configured."
        return
    }

    $patchedPckInstalled = $false
    try {
        Write-Info "Moving the original PCK into the recovery backup..."
        Move-Item -LiteralPath $Installation.PckPath -Destination $paths.BackupPath

        Write-Info "Applying the auditable Mod Loader configuration patch..."
        Invoke-GdrePatch -GdrePath $package.GdrePath -Patches $package.Patches -SourcePck $paths.BackupPath -DestinationPck $paths.WorkPath

        Write-Info "Verifying the patched PCK..."
        $actualPatchedHash = Get-Sha256 -Path $paths.WorkPath
        if ($actualPatchedHash -ne $patchedHash) {
            throw "Patched PCK verification failed. Expected $patchedHash, got $actualPatchedHash."
        }

        Move-Item -LiteralPath $paths.WorkPath -Destination $Installation.PckPath
        $patchedPckInstalled = $true
        Write-State -Paths $paths -Installation $Installation -Build $build -Status "enabled"
        Write-Log "Enable completed successfully."
    }
    catch {
        Write-Log "Enable failed: $($_.Exception.Message)"
        Remove-SafeFile -GameRoot $Installation.GamePath -Path $paths.WorkPath
        if ($patchedPckInstalled -and (Test-Path -LiteralPath $Installation.PckPath) -and (Test-Path -LiteralPath $paths.BackupPath)) {
            Move-Item -LiteralPath $Installation.PckPath -Destination $paths.WorkPath
            Move-Item -LiteralPath $paths.BackupPath -Destination $Installation.PckPath
            Remove-SafeFile -GameRoot $Installation.GamePath -Path $paths.WorkPath
        }
        elseif (-not (Test-Path -LiteralPath $Installation.PckPath) -and (Test-Path -LiteralPath $paths.BackupPath)) {
            Move-Item -LiteralPath $paths.BackupPath -Destination $Installation.PckPath
        }
        if ($steamDataCreated) {
            Remove-ManagedSteamData -Installation $Installation
        }
        throw
    }

    Write-Ok "Mod Loader enabled. No mods were installed or changed."
    Write-Host "Original backup: $($paths.BackupPath)"
}

function Disable-ModLoader {
    param([Parameter(Mandatory = $true)]$Installation)

    Assert-GameStopped
    $build = Get-SupportedBuild -Installation $Installation
    if ($null -eq $build) {
        throw "Unsupported Steam beta/build. This release cannot safely restore it."
    }

    Write-Info "Hashing the current PCK..."
    $pckHash = Get-Sha256 -Path $Installation.PckPath
    $cleanHash = ([string]$build.cleanPckSha256).ToUpperInvariant()
    $patchedHash = ([string]$build.patchedPckSha256).ToUpperInvariant()
    if ($pckHash -eq $cleanHash) {
        Remove-ManagedSteamData -Installation $Installation
        Write-Ok "Mod Loader is already disabled; the Steam PCK is clean."
        return
    }
    if ($pckHash -ne $patchedHash) {
        throw "The current PCK is unknown. The tool will not overwrite it. Use Steam file verification to restore the game."
    }

    $paths = Get-StatePaths -Installation $Installation -BuildId $Installation.BuildId
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $paths.RemovePath) | Out-Null
    $script:LogPath = $paths.LogFile
    Write-Log "Disable requested for build $($Installation.BuildId)."

    if (-not (Test-Path -LiteralPath $paths.BackupPath -PathType Leaf)) {
        throw "The exact original backup is missing. Use Steam 'Verify integrity of game files' to restore the clean PCK."
    }
    if ((Get-Sha256 -Path $paths.BackupPath) -ne $cleanHash) {
        throw "The original backup failed SHA-256 verification. It will not be restored."
    }

    Remove-SafeFile -GameRoot $Installation.GamePath -Path $paths.RemovePath
    Write-Info "Restoring the exact original Steam PCK..."
    Move-Item -LiteralPath $Installation.PckPath -Destination $paths.RemovePath

    try {
        Move-Item -LiteralPath $paths.BackupPath -Destination $Installation.PckPath
        if ((Get-Sha256 -Path $Installation.PckPath) -ne $cleanHash) {
            throw "Restored PCK verification failed."
        }
        Remove-SafeFile -GameRoot $Installation.GamePath -Path $paths.RemovePath
        Remove-ManagedSteamData -Installation $Installation
        Write-State -Paths $paths -Installation $Installation -Build $build -Status "disabled"
        Write-Log "Disable completed successfully."
    }
    catch {
        Write-Log "Disable failed: $($_.Exception.Message)"
        if (-not (Test-Path -LiteralPath $Installation.PckPath) -and (Test-Path -LiteralPath $paths.RemovePath)) {
            Move-Item -LiteralPath $paths.RemovePath -Destination $Installation.PckPath
        }
        throw
    }

    Write-Ok "Original Steam PCK restored exactly. Mods and save data were not changed."
}

try {
    $script:PackageRoot = Find-PackageRoot
    $configPath = Join-Path $script:PackageRoot "supported-builds.json"
    $script:Config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $versionPath = Join-Path $script:PackageRoot "VERSION"
    $script:PackageVersion = if (Test-Path -LiteralPath $versionPath) {
        (Get-Content -LiteralPath $versionPath -Raw).Trim()
    }
    else {
        "development"
    }

    $installation = Find-GameInstallation -RequestedPath $GamePath
    switch ($Action) {
        "Enable" { Enable-ModLoader -Installation $installation }
        "Disable" { Disable-ModLoader -Installation $installation }
        "Status" { Show-Status -Installation $installation }
    }
    exit 0
}
catch {
    Write-Host ""
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    if (-not [string]::IsNullOrWhiteSpace($script:LogPath)) {
        Write-Host "Log: $script:LogPath"
    }
    Write-Host "No save data or mods were changed by this error."
    exit 1
}
