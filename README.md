# Cosmopolitan

<p align="center">
  <a href="https://github.com/cyber-prinzesse/Cosmopolitan/releases/latest"><img src="docs/promo/cosmopolitan-techno-1-door-4x5.png" width="32%" alt="Windows games get in. Your Mac is on the list — a one-click game launcher for macOS. In beta."></a>
  <a href="https://github.com/cyber-prinzesse/Cosmopolitan/releases/latest"><img src="docs/promo/cosmopolitan-techno-2-rules-4x5.png" width="32%" alt="No Windows. No terminal. No config. Just play. House rules for Windows games on your Mac."></a>
  <a href="https://github.com/cyber-prinzesse/Cosmopolitan/releases/latest"><img src="docs/promo/cosmopolitan-ad-5-gameplay-4x5.png" width="32%" alt="A Windows game, running on macOS — real gameplay, recorded on my Mac."></a>
</p>

<p align="center"><b><a href="https://github.com/cyber-prinzesse/Cosmopolitan/releases/latest">⬇ Download Cosmopolitan for Mac</a></b> · free · Apple Silicon</p>

Runs Windows games and programs on Apple Silicon Macs through Wine, with the graphics
layers (DXMT, DXVK, D3DMetal), controllers, runtimes and community fixes handled
automatically. Free, unnotarized.

## Install and updates

Download `Cosmopolitan-<version>.dmg` from the [latest release](https://github.com/cyber-prinzesse/Cosmopolitan/releases/latest),
open it and drag the app to Applications. The app is not notarized (no paid Apple Developer
account), so macOS blocks the first open with "Apple could not verify…". Click **Done**, then open
**System Settings → Privacy & Security**, scroll to "Cosmopolitan was blocked", click **Open Anyway**
and confirm. Once is enough. (Right-click → Open no longer bypasses this on macOS 15 and later.)

Updates arrive inside the app (Sparkle). Every GitHub release carries the signed update

Updates arrive inside the app (Sparkle) from these releases.

## Engine: Cosmos

<img src="docs/design/cosmos-icon-128.png" width="64" align="right" alt="The Cosmos icon: a martini glass holding a galaxy">

Cosmopolitan is moving to its own Wine engine, **Cosmos**: based on Wine (LGPL) with its own patches (each program's own
Dock name, one Dock icon for Steam, dark title bars, a black theme for the windows Wine draws itself, D3D12 games no longer
freezing on a fault in Apple's Metal threads). As the LGPL requires, every engine release publishes its complete source:
the Wine base and the patch series it was built with ([cosmos-engine releases](https://github.com/cyber-prinzesse/cosmos-engine/releases)).

## Stores

**Stores…** next to the programs grid. *Install Battle.net* downloads the official installer into the bottle and
runs it (Arial and software rendering are set up first, the known fixes under Wine); its games then appear in the
grid. *Epic Games* goes through [Legendary](https://github.com/derrod/legendary) (installed with pipx on first use):
sign in with the code from Epic's login page, pick a game under *Install Epic game*, and it downloads into
`C:\Games\Epic` and launches with Epic's auth parameters through this bottle's engine and drivers. *GOG* goes through
[lgogdownloader](https://github.com/Sude-/lgogdownloader) (Homebrew): sign in with the address GOG's login page lands
on, pick a game under *Install GOG game*, and the DRM-free Windows build is installed straight into `C:\GOG Games`.
*Install Epic Games Launcher…* puts Epic's own Windows client into the bottle too (silent MSI); Cosmopolitan starts it with
`-SkipBuildPatchPrereq` on the DXMT driver set and finishes its pending self-update before each launch, which is what
otherwise leaves it in a restart loop under Wine. GOG Galaxy's Windows client is not offered: its Qt 6 web view stays
blank under every Direct3D layer available on macOS (other Mac Wine launchers report the same), so the menu opens or
installs GOG's native Mac client instead, and Windows-only GOG builds come through lgogdownloader.

## D3DMetal (Direct3D 12) is optional and comes from Apple

Direct3D 10/11 games run through DXMT out of the box. Direct3D 12 needs Apple's
D3DMetal, which is proprietary and **not included**. Download the Game Porting Toolkit
from https://developer.apple.com/games/game-porting-toolkit/, then in Cosmopolitan:
Drivers › **D3DMetal…** › *Install from Apple's download…*, read Apple's license, and
accept it. You can remove it again from the same place. See `THIRD_PARTY_NOTICES.md`.

## Anti-cheat

Nothing here bypasses or disables anti-cheat, ever. Games are badged honestly:
"Online won't work (Easy Anti-Cheat)" or "Kernel anti-cheat — will not run". For the
latter, the app points to cloud gaming.

## Not built (and why)

- **SteamGridDB art**: needs a personal API key; Steam's own CDN art is used instead.
- **Discord Rich Presence bridge**: not built yet.
- **DualSense adaptive triggers**: not possible under Wine for XInput games; rumble works through SDL, and games with native DualSense support can get the real pad per game (Options `DUALSENSE=native`).
- **GOG Galaxy's Windows client**: its Qt 6 interface stays blank under every Direct3D layer available on macOS. Stores… opens or installs GOG's native Mac client instead, and Windows-only GOG games install into the bottle through lgogdownloader.

Built on the Mac side instead of inside Wine: game keyboard layout (switches to a Latin layout you already have, per game), cloud saves (iCloud Drive mirror for non-Steam programs), benchmarking and fps history (Metal HUD read with on-device text recognition), replay clips (rolling system recorder + hotkeys), shared multi-user bottles (/Users/Shared), mods (overlay with backups).

## Credits

Wine and its contributors, Highball's engine recipe and patches (gauthierpiarrette), the Sikarugir Wine
builds, DXMT (3Shain), DXVK/D9VK (doitsujin, Gcenx),
MoltenVK (Khronos), GStreamer, cnc-ddraw, SDL, winetricks, DOSBox Staging, the Highball
database (CC0), ProtonDB and umu-protonfixes. Full list with licenses in
`THIRD_PARTY_NOTICES.md`.

## License

Cosmopolitan is proprietary software: free to download and use under [TERMS.txt](TERMS.txt) and [LICENSE](LICENSE);
its source code is not public. Third-party components keep their own licenses ([THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)).
