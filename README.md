# fazbear-security

A single-file Roblox Studio plugin that builds **Freddy Fazbear's Security
Map** — rooms, doors (regular + lockable), vents and ceiling cameras — into
your place, and installs a multiplayer-friendly camera tablet + door system.

![map reference](https://app.devin.ai/attachments/7b0e4b60-d3a1-4d34-b459-69e83830445c/75FEEB43-C619-4903-9D50-CFF0BD2EC468.png)

## What the plugin builds

**Map** (under `Workspace.FazbearMap`) — a 3×3 grid of rooms matching the
reference floorplan:

```
+-----------+-----------+-----------+
| BACK ROOM | SHOW STAGE|  ARCADE   |
|  CAM 04   |  CAM 02   |  CAM 05   |
+-----------+-----------+-----------+
|  KITCHEN  | DINING    | PARTY ROOM|
|  CAM 03   | AREA      |  CAM 06   |
| (audio)   | CAM 01    |           |
+-----------+-----------+-----------+
| WEST HALL | SECURITY  | EAST HALL |
|  CAM 07   |  OFFICE   |  CAM 08   |
+-----------+-----------+-----------+
```

Connections (matching the legend):

| Connection                          | Type            |
| ----------------------------------- | --------------- |
| Show Stage ↔ Dining Area            | Door            |
| Show Stage ↔ Back Room              | Door            |
| Show Stage ↔ Arcade                 | Door            |
| Dining Area ↔ Kitchen               | Door            |
| Dining Area ↔ Party Room            | Door            |
| Dining Area ↔ Security Office       | Door            |
| West Hall ↔ Security Office         | **Lockable**    |
| East Hall ↔ Security Office         | **Lockable**    |
| Kitchen ↔ West Hall                 | Vent (grate)    |
| Party Room ↔ East Hall              | Vent (grate)    |

**Scripts** (auto-installed alongside the map):

| Path                                                       | What it does |
| ---------------------------------------------------------- | ------------ |
| `ReplicatedStorage.FazbearSecurity` (Folder)               | `ToggleDoor`, `DoorState`, `RequestState` RemoteEvents |
| `ServerScriptService.FazbearSecurityServer` (Script)       | Owns lockable-door state; broadcasts changes to all clients. Plain (blue) doors are click-toggled via `ClickDetector`. |
| `StarterPlayer.StarterPlayerScripts.FazbearTabletClient` (LocalScript) | Per-client tablet UI: **press `M`** to open/close. Cycles `CAM 01`..`CAM 08`. `CAM 03` (Kitchen) shows an *AUDIO ONLY* overlay. Door panel toggles the West / East security-office locks via the server. |

## Multiplayer behaviour

- Cameras live on each client's own `ScreenGui`; **multiple players can each
  view a different camera at the same time**.
- Closing the tablet returns the player's camera to their character
  immediately ("getting up off the cameras"). The character is never frozen
  — players can walk around freely between camera checks.
- Door state (locked / unlocked) is **server-authoritative** and broadcast to
  every client so a door locked by one player stays locked for everyone.

## Install

The plugin is **one file**, `plugin/FazbearSecurityPlugin.server.lua`.

### Option A — drop into your local Plugins folder

1. Copy `plugin/FazbearSecurityPlugin.server.lua` into your Roblox Plugins
   folder:
    - Windows: `%LOCALAPPDATA%\Roblox\Plugins\`
    - macOS:  `~/Documents/Roblox/Plugins/`
2. Restart Studio.

### Option B — install from a script in Studio

1. Open your place in Studio.
2. Paste the file's contents into a `Script` inside `Workspace`.
3. Right-click the script → **Save as Local Plugin…**.
4. Restart Studio.

## Use

1. Open your place in Studio.
2. Click the **Fazbear Security** toolbar → **Install / Rebuild**.
3. Press **Play**. In-game, press **`M`** to open the camera tablet.
4. To iterate on the layout, click **Rebuild Map Only** — it preserves the
   installed scripts and remotes but rebuilds the geometry.

Anything you put outside of `Workspace.FazbearMap`,
`ReplicatedStorage.FazbearSecurity`,
`ServerScriptService.FazbearSecurityServer`, and
`StarterPlayer.StarterPlayerScripts.FazbearTabletClient` is left untouched on
rebuild, so this plugin is safe to use alongside your own scripts.

## Controls

| Key | Action |
| --- | ------ |
| `M` | Toggle the camera tablet |
| `CAM 01..08` buttons | Switch the active camera feed |
| `WEST / EAST DOOR` buttons (on the tablet) | Toggle the lockable security-office doors |
| Click a blue door | Slide it open / closed |

## Tuning

Open `plugin/FazbearSecurityPlugin.server.lua` and edit the config blocks
near the top:

- `ROOM_SIZE`, `ROOM_HEIGHT`, `DOOR_WIDTH`, `DOOR_HEIGHT` — geometry knobs.
- `ROOMS` — per-room colour, theme, camera id.
- `PASSAGES` — which rooms are connected and how.

Re-run **Install / Rebuild** to apply your changes.

## Dev — lint / format

```bash
stylua --check plugin/
selene plugin/
```

(Configs: [`.stylua.toml`](./.stylua.toml), [`selene.toml`](./selene.toml).
CI runs both on every PR.)

## License

MIT — see [`LICENSE`](./LICENSE).
