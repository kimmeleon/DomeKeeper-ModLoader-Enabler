DOME KEEPER MOD LOADER ENABLER
==============================

This is an independent, auditable Windows tool. It enables the Godot Mod
Loader already included in Dome Keeper staging builds. It does not install,
bundle, copy, or delete any mod.

QUICK START
-----------

1. In Steam, open Dome Keeper > Properties > Betas.
2. Set Beta Participation to "staging" and wait for Steam to finish updating.
3. Close Dome Keeper.
4. Extract this complete ZIP to any normal folder.
5. Double-click "Enable Mod Loader.bat".
6. Subscribe to compatible Workshop mods, then launch the game normally.

To remove the change, close the game and double-click
"Disable Mod Loader.bat". The tool restores the exact original Steam PCK.

"Check Status.bat" reports the detected game folder, Steam beta, Build ID,
PCK SHA-256, and current enabled/disabled state.

SAFETY
------

- Only exact supported staging builds are accepted.
- The original PCK is retained under the game's
  .domekeeper-modloader-enabler folder while enabled.
- About 1.5 GB of free disk space is required during installation.
- Save data and installed mods are never changed.
- Unknown or modified PCK files are refused.
- A minimal steam_data.json pins Dome Keeper's Steam App ID so Workshop
  subscriptions are scanned from the correct app directory. Disable removes
  it only when its content exactly matches the file managed by this tool.
- Steam file verification remains the fallback recovery method.

If automatic Steam detection fails, run this in PowerShell:

  powershell -ExecutionPolicy Bypass -File .\scripts\DomeKeeperModLoader.ps1 `
    -Action Enable -GamePath "D:\SteamLibrary\steamapps\common\Dome Keeper"

Project and source:
https://github.com/ltx001/DomeKeeper-ModLoader-Enabler
