# fazbear-security

A pair of single-file Roblox Studio plugins that scaffold horror-game systems
straight into your place.

| Plugin | What it builds |
| ------ | -------------- |
| [`plugin/FazbearSecurityPlugin.server.lua`](./plugin/FazbearSecurityPlugin.server.lua) | A Freddy Fazbear's Security map (rooms / doors / vents) + a multiplayer-friendly camera tablet + lockable doors. |
| [`plugin/HorrorMenuPlugin.server.lua`](./plugin/HorrorMenuPlugin.server.lua) | A polished neon-purple, VHS-themed horror main menu with **Play / Party / Settings / Credits**, a working party + matchmaking system, and a full settings panel. |

Both plugins are zero-dependency: they install everything they need into your
place when you click their toolbar buttons, and only use rbxasset:// IDs that
ship with Roblox so no asset uploads are required.

## Install

For either plugin:

### Option A — drop the file into your local Plugins folder

1. Copy the `.server.lua` you want into your Roblox Plugins folder:
    - Windows: `%LOCALAPPDATA%\Roblox\Plugins\`
    - macOS:  `~/Documents/Roblox/Plugins/`
2. Restart Studio.

### Option B — install from a script in Studio

1. Open your place in Studio.
2. Paste the file's contents into a `Script` inside `Workspace`.
3. Right-click the script → **Save as Local Plugin…**.
4. Restart Studio.

## Horror Menu plugin

After installing, click the **Horror Menu** toolbar → **Install / Rebuild**.
The plugin installs:

| Path | What it does |
| ---- | ------------ |
| `StarterGui.HorrorMenuGui` | ScreenGui with backdrop, VHS overlay, scanlines, dust, title, main menu, side panels, loading screen, invite popup, notifications. |
| `ReplicatedStorage.HorrorMenu.MenuConfig` | ModuleScript with mission list, difficulty list, default settings, and `GamePlaceId`. Edit this to drive matchmaking at your gameplay place. |
| `ReplicatedStorage.HorrorMenu.Remotes` | Folder of RemoteEvents + RemoteFunctions used by the menu (`CreateParty`, `JoinParty`, `PartyState`, `Toast`, `SaveSettings`, …). |
| `ServerScriptService.HorrorMenuServer` | Authoritative party / matchmaking server. Validates inputs, owns party state, reserves servers via `TeleportService:ReserveServer`, and persists settings via `DataStoreService`. |
| `StarterPlayer.StarterPlayerScripts.HorrorMenuClient` | Menu client: screen manager, hover / click sounds, settings sliders + toggles + keybind capture, party UI sync, invite popup, notifications, dust particles, VHS flicker, camera sway. |
| `Workspace.HorrorMenuScene` | A dimly lit neon backdrop the menu camera looks at. |
| `Lighting.HMFx_*` | Bloom, Blur, ColorCorrection, and Atmosphere effects tuned for the menu. |

### Plug it into your game

Open `ReplicatedStorage.HorrorMenu.MenuConfig` and set:

```lua
MenuConfig.GamePlaceId = <your gameplay placeId>
```

Leaving `GamePlaceId = 0` is fine while testing — matchmaking will toast a
message instead of teleporting.

### Reskin it

The first ~100 lines of `plugin/HorrorMenuPlugin.server.lua` are pure config:

- `PALETTE` – colours
- `FONTS` – fonts
- `AUDIO_IDS` – click / hover / music / static SoundIds
- `IMAGE_IDS` – overlay textures
- `UI` – sizes, spacing, transition times

Change anything you want, then click **Install / Rebuild** to re-scaffold.

### Toolbar buttons

| Button | What it does |
| ------ | ------------ |
| `Install / Rebuild` | Wipes and re-installs all menu instances + scripts. |
| `Rebuild UI Only` | Re-generates StarterGui + Lighting only. |
| `Rebuild Scene Only` | Re-generates the workspace backdrop + Lighting only. |

## Fazbear Security plugin

See the install/use instructions in
[`plugin/FazbearSecurityPlugin.server.lua`](./plugin/FazbearSecurityPlugin.server.lua)
or check out the original PR for the full feature list.

## Dev — lint / format

```bash
stylua --check plugin/
selene plugin/
```

Configs: [`.stylua.toml`](./.stylua.toml), [`selene.toml`](./selene.toml). CI
runs both on every PR.

## License

MIT — see [`LICENSE`](./LICENSE).
