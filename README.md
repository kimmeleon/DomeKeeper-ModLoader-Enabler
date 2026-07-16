# Dome Keeper Mod Loader Enabler

An independent, auditable Windows tool that enables the Godot Mod Loader
already bundled with the Steam `staging` build of Dome Keeper.

It does **not** depend on the LeonardoLuca patcher and does **not** install,
bundle, copy, or remove any mod.

## Quick start

1. In Steam, open **Dome Keeper > Properties > Betas**.
2. Set **Beta Participation** to `staging` and wait for the update to finish.
3. Close Dome Keeper.
4. Download and extract the latest release ZIP.
5. Double-click **Enable Mod Loader.bat**.
6. Subscribe to compatible Workshop mods and launch the game normally.

To undo the change, close the game and double-click
**Disable Mod Loader.bat**. The exact original Steam PCK is restored.

Use **Check Status.bat** to display the detected installation, Steam beta,
Build ID, PCK SHA-256, and enabled/disabled state.

## What it changes

Dome Keeper staging Build `24088424` includes Godot Mod Loader `7.0.1`, but
the exported game selects a profile that disables mods. This tool selects the
existing `production_workshop` profile and creates the Mod Loader's supported
`steam_data.json` configuration with Dome Keeper's Steam App ID `1637320`.

The readable source for the patched resource is
[`src/patches/options.tres`](src/patches/options.tres). The generated
`steam_data.json` contains only `{"app_id":1637320}`. No decompiled game
script is distributed.

## Safety model

- The Steam beta, Build ID, executable, clean PCK, patch resource, patched
  PCK, and tool dependencies are checked against pinned SHA-256 values.
- Unknown or already modified PCK files are refused.
- Dome Keeper must be closed before any change.
- The original PCK is moved to
  `.domekeeper-modloader-enabler/backup/<build-id>/domekeeper.pck` inside the
  game folder while the loader is enabled.
- A failed patch automatically moves the original PCK back into place.
- Disable restores the exact original PCK, not a reconstructed equivalent.
- Disable removes `steam_data.json` only when its content exactly matches the
  file managed by this tool; any other existing file is left unchanged.
- Save data and installed mods are never read, written, or deleted.

About 1.5 GB of free disk space is required while enabling. Steam's
**Verify integrity of game files** remains the fallback recovery method.

## Supported builds

| Steam beta | Build ID | Base depot manifest |
| --- | ---: | ---: |
| `staging` | `24088424` | `7372251440806421745` |

The tool intentionally fails closed after a Dome Keeper update. A new release
must verify and add the new build hashes before modifying it.

## Manual game path

Steam libraries are detected automatically from Steam's registry and
`libraryfolders.vdf`. If detection fails:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\DomeKeeperModLoader.ps1 `
  -Action Enable -GamePath "D:\SteamLibrary\steamapps\common\Dome Keeper"
```

Actions are `Enable`, `Disable`, and `Status`.

## Verified release build

Requirements: Windows PowerShell 5.1 or newer and internet access.

```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

The build script:

1. Downloads the pinned official GDRE Tools Windows archive.
2. Verifies the archive and each included binary by SHA-256.
3. Compiles the readable Mod Loader resource and verifies its hash.
4. Creates the self-contained release ZIP and checksum in `artifacts/`.

## Dependencies and licenses

- This project's scripts: MIT.
- [GDRE Tools](https://github.com/GDRETools/gdsdecomp) `v2.6.0-beta.4`: MIT.
- [Godot Mod Loader](https://github.com/GodotModding/godot-mod-loader)
  `v7.0.1`: CC0 1.0 Universal.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for details.

This project is an independent community tool and is not affiliated with or
endorsed by Bippinbits or Raw Fury.
