# Atari GameStation Go

This target builds Linux ARMHF Rednukem packages for the Atari GameStation Go.
It uses the validated Dice/Debian Stretch SDK sysroot, SDL2, and ALSA runtime
staging used by the working GameStation Go ports. The normal package is
software-rendered; the dedicated Duke Nukem 64 package uses Rednukem's
OpenGL renderer through the same SDL KMSDRM video path.

## Build

From WSL Ubuntu, build and validate the package with:

```sh
cd /mnt/d/Development/rednukem
SYSROOT=/mnt/d/Development/SDKs/gamestation-go-dice-stretch-armhf \
  bash platform/gamestation-go-build.sh
```

To build the distinct SDL/OpenGL package required by Duke Nukem 64:

```sh
cd /mnt/d/Development/rednukem
GSG_RENDERER=dn64-gl \
SYSROOT=/mnt/d/Development/SDKs/gamestation-go-dice-stretch-armhf \
  bash platform/gamestation-go-build.sh
```

`GSG_RENDERER=software` is the default and outputs
`package/gamestation-go/`. `GSG_RENDERER=dn64-gl` enables OpenGL, disables
Polymer, and outputs `package/gamestation-go-dn64/` with a separate object
directory. This leaves the tested software package unchanged.

The script requires `arm-linux-gnueabihf-gcc` and
`arm-linux-gnueabihf-g++`. It prefers `arm-linux-gnueabihf-readelf` for
validation and falls back to GNU `readelf`, which parses ARM ELF files
independently of the host architecture. Override `CROSS`, `READELF`,
`OUTPUT_DIR`, `BUILD_DIR`, `TARGET_CFLAGS`, or `TARGET_LDFLAGS` when needed.

The build uses `--sysroot`, `-march=armv7-a`, `-mfloat-abi=hard`, `-mfpu=neon`,
and `-fPIE`; it links a PIE against `/lib/ld-linux-armhf.so.3`. The primary
SDK supplies the SDL2/ALSA development files and the staged runtime. Its
runtime-only root does not contain the glibc development linker scripts, so
the script also uses the cached GCC 6.3/Debian Stretch-compatible headers and
linker scripts at `/home/lebla/armhf-stretch-sysroot`. Override
`LEGACY_SYSROOT` if that cache is installed elsewhere. The cached Stretch image
also provides GCC 8 compatibility C++ headers and `libstdc++.so.6` at
`opt/mame-gcc8/usr`; override `LEGACY_CXX_ROOT` if needed. That shared library
is staged with the firmware-matched SDL2/ALSA/FLAC/Ogg/libgcc/libatomic
closure, avoiding newer host runtime symbols. The final link also uses
Stretch's `libc_nonshared.a` for the glibc `atexit` compatibility shim. The
script also uses Stretch's PIE start/end files with GCC's `crtbeginS.o` and
`crtendS.o`. This preserves C++ global-constructor execution under the
firmware-compatible glibc; using GCC 13's newer `Scrt1.o` leaves global
`std::string` state uninitialized and crashes before Rednukem reads arguments.
The executable uses 64 KiB ELF load alignment, matching the verified EDuke32
GameStation Go package. Set `RUNTIME_LIBDIR` to a colon-separated replacement
search path for another firmware-matched staging environment.

After every build, the script recursively walks `DT_NEEDED` entries with
readelf. It bundles every non-baseline dependency in `lib/` and fails if any
non-baseline library is missing, is not ARMHF, or is not included in the
closure. The firmware-provided ARMHF baseline is limited to the dynamic loader
and glibc libraries (`libc`, `libdl`, `libm`, `libpthread`, and `librt`).

## Deploy

The deployable output is `package/gamestation-go/`. Copy that directory to
`/sdcard/bin/rednukem` on the device, keep its `lib/` directory intact, and
run:

```sh
/sdcard/bin/rednukem/run-rednukem.sh -g /path/to/DUKE3D.GRP
```

### Duke Nukem 64

Deploy `package/gamestation-go-dn64/` to
`/sdcard/bin/rednukem-dn64/` to keep it alongside the software-rendered
package. Preserve its `lib/` directory and launcher:

```sh
/sdcard/bin/rednukem-dn64/run-rednukem.sh \
  -g '/sdcard/Games/Duke Nukem 64/Duke Nukem 64.z64'
```

The file must be a legal 8 MiB Duke Nukem 64 cartridge ROM dump. Rednukem
accepts supported byte orders and normalizes them internally; optional MIDI
tracks extracted from a lawful `DUKE3D.GRP` may be placed beside the ROM.
The `dn64-gl` binary still uses SDL/KMSDRM and all GameStation input support.
SDL dynamically loads the firmware's `libGL.so.1`/EGL/GLES backend, so this
package intentionally does not bundle the desktop Stretch Mesa libraries,
which are not compatible with the GameStation graphics stack.
The GameStation build requests an attribute-free desktop OpenGL context:
the firmware EGL driver rejects the desktop robust-access/debug context
attributes, while Rednukem's renderer requires desktop fixed-function OpenGL
rather than GLES.
Its optional desktop ImGui renderer is disabled: the firmware exposes GL
through SDL's context resolver, not the separate desktop `libGL` loader ImGui
uses. This does not affect the game renderer or controls.

The launcher resolves its own directory, prepends
`/sdcard/bin/rednukem/lib` (or its actual installed location) to
`LD_LIBRARY_PATH` without discarding an existing value, starts Rednukem from
the package directory, and rejects an empty invocation with usage and status
64 in its first executable block, before it performs a path lookup,
environment change, or binary launch. Use Rednukem's standard `-g`, `-grp`,
or `-game_dir` game-data options as appropriate.

Normal single-player launches retain Rednukem's main menu. To start a
specific episode, level, or skill directly, pass Rednukem's standard
one-based `-v`, `-l`, and `-s` options explicitly.

When the explicit main archive is named `WW2GI.GRP`, the launcher also adds
the GameStation-only `-ww2gi` selection switch. This is required for valid
World War II GI archive revisions that differ from the scanner's fixed
CRC/size record: it selects the World War II GI game type and related
resources. Rednukem then uses the archive's normal CON fallback (`WW2GI.CON`
when present, otherwise `GAME.CON`); a user-supplied `-x` CON file remains
authoritative.

The launcher also translates a supplied `/sdcard/...` game-data directory to
`/mnt/sdcard/...` when that mounted path exists. Rednukem itself runs from
`/mnt/sdcard` on the firmware, so this makes GameStation launcher paths
readable without changing a caller's command line.

For an explicit `-game_dir` plus `-gamegrp`, the launcher verifies that the
selected archive is a readable regular file before starting Rednukem. On
failure it exits with status 66 and prints the resolved path plus the
game-data directory listing, avoiding an empty-archive startup stall.

An empty invocation that still prints `Segmentation fault` is not running
this staged launcher; redeploy `run-rednukem.sh` and invoke it explicitly
through `/bin/sh`.

Rednukem's SDL layer already loads a local `gamecontrollerdb.txt` before
controller discovery. The package supplies the verified GameStation Go
`agpio-keys` mapping and the launcher exports the same mapping through
`SDL_GAMECONTROLLERCONFIG` only when the user has not provided an override.
If SDL cannot expose the device as a game controller, Rednukem instead
selects the verified `agpio-keys` GUID as its raw joystick.

### Volume buttons

The volume buttons are ignored: they produce no game, menu or exit action.
On-device (`evtest`) they come from the separate evdev device `zadc-keys`
(`/dev/input/event0`), which reports `KEY_VOLUMEDOWN` (114) and
`KEY_VOLUMEUP` (115). The SDL layer (`sdlayer.cpp`, same approach as the
EDuke32 and NBlood AGSG builds) handles them as follows:

- The passive evdev watch notes real 114/115 events from `zadc-keys`, and
  never turns 114/115 from any watched node into game input.
- `SDL_SCANCODE_VOLUMEUP/DOWN` and `SDLK_VOLUMEUP/DOWN` keyboard events are
  dropped before any key handling.
- The driver can remap a volume press into other game inputs (key, button or
  axis). While a real volume key is held (up to 1000 ms) and for 250 ms after
  it, new key/button/axis presses are dropped; releases and returns to centre
  always pass so nothing sticks. Home (`misc1` / raw `b25`) is never
  suppressed. Number keys (keypad digits, SDL scancodes 1-0 and KP 1-0) are
  never dropped: the keypad reader does not apply the window and the SDL
  key-down check exempts them.
- The wireless gamepad's keypad (HID keyboard interface of the "LiteStar
  PC-GamePad" evdev nodes, e.g. `KEY_KP1`=79) is read passively by the same
  keypad reader and injected as number keys 1-0; its `*` (`KEY_9`) and `#`
  (`KEY_0`) become the left/right stick clicks like the built-in keypad. No
  other events are used from those nodes. The reader also keeps its
  `zadc-keys`/pad flags in step with its fd list when a node is removed.

Home, D-pad, trackball, and the other `agpio-keys` buttons are unchanged.

On GameStation Go, the D-pad is bound to forward, backward, turn-left, and
turn-right during gameplay. Menu navigation continues to use SDL's D-pad
repeat state.

The Home button (`b25`, exposed by SDL as `misc1` when the runtime emits a
controller event) exits Rednukem cleanly only while the top-level main menu
(`MENU_MAIN`, or the in-game main menu) is active; in submenus such as Options
it does nothing.
Both the verified controller's raw `b25` and mapped `misc1` events are
consumed during gameplay, so Home cannot trigger an unintended exit mid-level.
Redneck Rampage and Redneck Rampage Rides Again also exit from their title
attract demo, which presents the frontend with its menu closed.

The integrated trackball is read directly from the Linux input device that
provides `REL_Z` and `REL_RX` axes, which are translated into horizontal and
vertical mouse movement while the game has mouse capture. The known
`/dev/input/event5` is preferred; otherwise Rednukem selects a single
capability-matched event device and refuses an ambiguous match.

### Redneck HUD and menu fixes

- The Redneck status bar (`hud_fullwidth`, default 1) is stretched across the
  full screen width on displays wider than 4:3. Only status-bar and inventory
  sprites are affected: `G_DisplayRest` sets `g_rotatespriteHudStretch` around
  those draws and `dorotspr_handle_bit2` maps the 320x200 space onto the whole
  screen with separate x/y scales. Add `hud_fullwidth 0` to `autoexec.cfg` for
  the original centred 4:3 bar.
- The HUD Setup "Status bar" slider is initialised in every renderer, not only
  OpenGL builds (`Menu_SetupScreenSize`), and the range movement code ignores
  degenerate ranges, which fixes a divide-by-zero crash in software builds.
- Deer Huntin' status bar (Deer Huntin' only): `G_DrawStatusBar` used to draw
  the Redneck Alcohol/Gut meters over the Deer Huntin' bar art, so they floated
  at the wrong spots, and the original Deer Huntin' HUD (`ghstatbr_render` in
  `rrdh.cpp`) was never called. For Deer Huntin' it now calls that renderer
  every frame: animal icon with LBS/KILLS, ammo image with its name, wind
  arrow, compass needle and scent/decoy lights. The original's random wind
  arrow jitter is dropped. `G_PatchStatusBar` also uses the full-width clip when
  the HUD stretch is active.
- Deer Huntin' "hold weapon up" (F1): the hardcoded F1 check in `rrdh.cpp` now
  also fires on the unused `Alt_Fire` game function, which the default AGSG
  controller bindings already put on the right shoulder. In Deer Huntin' that
  function is shown as "Hold Weapon" in the Controls menus so it can be moved to
  another button; it is still stored as `Alt_Fire` in the config file.
- Deer Huntin' number keys (Deer Huntin' only): the AGSG keypad has no F keys, so
  number keys 1-8 (the keypad digits) trigger the F1-F8 actions (1 = hold weapon,
  2 = load, 3 = F3 action, 4 = deploy/drop, 5-8 = sounds) via `DH_FKeyPressed` in
  `rrdh.cpp`. Real F keys still work. Because of this, keys 1-8 no longer select
  weapons in Deer Huntin' (9 and 0, Next/Previous Weapon still do).
  Keypad/number key 9 is also Crouch / pick up decoys (same as the Z key / Crouch
  binding; it toggles crouch like the default Crouch key does), handled in
  `sub_299D8` in `player.cpp`.
- Deer Huntin' walking speed (Deer Huntin' only): walking is slow by default and holding
  Run (the keypad `*`, left stick click) walks fast; `cl_autorun` / the run-mode setting
  are ignored in `P_DHGetInput`.
- Deer Huntin' strafe button (Deer Huntin' only): the keypad `#` (right stick click) is
  bound to Strafe at every level load (`CONFIG_SetGameStationGoDHStrafeButton`, replacing
  its default Crouch binding; Crouch is keypad 9), so holding it makes D-pad left/right
  strafe instead of turn.
- Deer Huntin' sky (Deer Huntin' only): `G_InitRRRASkies` now also runs for Deer
  Huntin', so 512/1024+ pixel wide sky tiles are set up as one panorama instead of
  the Redneck default of the same tile repeated 8 times around the horizon. The
  wide tiles the map uses are also listed at the end of `dhdiag.txt`. Narrower
  (parallaxed) Deer Huntin' sky tiles are stretched horizontally by `dh_skystretch`
  (percent, default 200 = each cloud 2x as wide as the old 2-repeat look, close to
      the DOS game; any value 25-1600 works, 100 = unstretched). The stretch is applied
  in the software renderer's sky code (`parascan`, `skystretchcol` in `engine.cpp`),
  on top of the base repeat count `dh_skyrepeat` (default 1 = 2 repeats). The number of
  tile widths round the full circle is snapped to a whole number (minimum 1), and the
  column wraps on the tile's real width (so non power-of-two sky tiles also work), so
  the clouds always join up with no seam. The effective stretch is therefore stepped:
  with `dh_skyrepeat 1`, 200 and anything above gives one tile round the circle, 100 gives two.
  The sky is also slid to match the DOS game: `dh_skyxoffs`
  (default 3 angle units, 2048 = 360 degrees, so 1 unit is about 0.18 degrees of view;
  lower/negative moves the clouds right, higher moves them left) and
  `dh_skyyoffs` (default -5 tile pixels; negative moves the clouds down). The defaults
  are the final hard-coded values (`dh_skyrepeat 1`, `dh_skystretch 200`, `dh_skyxoffs 3`,
  `dh_skyyoffs -5`), so no `autoexec.cfg` entry is needed. All of these remain
  console variables (`autoexec.cfg` can still override them) and apply at the next level load. The horizontal
  offset is `parallaxxoffs_override` in the software renderer's sky code. The sky
  settings apply to every parallaxed sky tile whatever its width.
- **Animal count (Deer Huntin'):** at level load the game keeps at most 4 of each animal
  type (pig, vixen, dogrun, cheer) and randomly deletes the extras the map places. The
  console variable `dh_animals` (`autoexec.cfg`, 1-1000, default 4) sets that limit. The
  real ceiling is however many animals the map itself contains: a value at or above that
  keeps all of them. Applies at the next level load.
- **Kill display test (Deer Huntin'):** the console command `dh_testkill [type] [count]`
  (type 1 = vixen, 2 = pig, 3 = dogrun, 4 = cheer; no arguments = one of each) registers
  fake kills through the normal kill code in a running single-player game, so the status
  bar kill icon, pounds and count can be checked without hunting. Put the same command
  in `autoexec.cfg` (before a game starts) and it registers the kill(s) at every level
  load instead. Alternatively
  `dh_testkills N` in `autoexec.cfg` (same types, 0 = off, not saved to `settings.cfg`)
  registers three fake kills of that animal when a level loads (no keyboard needed).
  Levels 1-4 only (the kill counter is not used on later levels). Remove it for normal play.
- Deer Huntin' Status bar setting (Deer Huntin' only): the Status bar is always the
  farthest-right (full) setting; smaller settings shrink the view and cut off the
  weapon. `rrdh_limitstatusbar()` in `rrdh.cpp` forces it every time the screen area
  is updated, and in HUD setup the "Status bar" slider is replaced by the
  "Brightness" slider (0-15 in 16 steps; `Menu_SetupScreenSize` in `menus.cpp` swaps the
  entry). The slider drives the palette brightness table (`g_videoPaletteBrightnessOnly`
  in `palette.cpp`), because the display gamma ramp used by the normal Brightness
  slider has no effect on the AGSG. The level is saved in the game's main config file
  (`Screen Setup` > `DHBrightness`, written on exit and read at startup) and also as
  the `dh_brightness` cvar (default 0).
- Deer Huntin' "FOG #1" marker (Deer Huntin' only): the editor marker tile 7059
  is hidden by forcing its tile size to zero, which the renderer skips. This is
  now re-applied every game tic (`sub_579A0`) instead of only at level load,
  and any sprite using tile 7059 or 7936 is also made invisible at level load. The
  "FOG #1" marker was found to be tile 7936 (sprite) using the `dhdiag.txt` report; the
  RRRA-only spawn case that zeroes its size never ran for Deer Huntin'.
  A tile 7936 sprite now also turns on the Redneck Rides Again style fog
  (`G_SetFog(2)`, constant visibility) for that level; it is reset on every level load.
  Because the marker tile number was inferred, level load also scans the tiles the map
  uses (`dh_hidemarkertiles` in `rrdh.cpp`), hides any flat yellow/blue editor-style tile,
  and writes a per-tile report to `dhdiag.txt` in the working directory.

## Device diagnostic

To capture the dynamic-loader trace, launcher environment, checksums, exact
forwarded arguments, and Rednukem output without changing normal launches,
use the launcher-only diagnostic prefix:

```sh
/sdcard/bin/rednukem/run-rednukem.sh --launcher --debug-log /tmp/rednukem-gsg.log -- \
  -game_dir '/sdcard/Games/Duke Nukem/gamedata/rednukem-WWII' -gamegrp WW2GI.GRP
```

The command writes the log with mode 0600, records every forwarded argument as
an exact hexadecimal byte sequence, returns Rednukem's exit status, and does
not alter the normal launch environment. `--debug` uses
`/tmp/runtime-<uid>/rednukem-gsg.log` when no explicit log path is supplied.

Game data is not distributed. Place compatible Duke Nukem 3D, Redneck
Rampage, NAM, or World War II GI data where Rednukem can find it, or pass the
appropriate Rednukem command-line arguments. On hardware, verify SDL video,
audio, controller mapping, trackball behavior, and a clean game exit against
the installed firmware; those device-specific checks cannot be performed by
the cross-build.
