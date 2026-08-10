# YATO GAMI — Mobile Horror Update

Godot 3.5 / GLES2

## Implemented
- Dark horror environment with substantially reduced ambient/directional lighting.
- Warm, focused flashlight with stronger contrast and mobile-friendly range.
- Reduced procedural noise textures from 256px to 128px for GLES2/mobile memory use.
- Mobile virtual joystick on the left.
- Right-side touch/drag camera look.
- Mobile FIRE, USE, LIGHT and RELOAD buttons.
- Existing keyboard/mouse and gamepad controls remain available on desktop.
- Touch sensitivity setting (0.2x–3.0x) saved to `user://settings.cfg` and applied immediately.
- Removed player Health/HP HUD elements from the weapon HUD.
- Added `MobileInput` autoload as a small input bridge, avoiding synthetic mouse events.
- Mobile controls automatically hide on non-touch desktop environments.

## Sanity checks performed
- Verified all newly referenced scripts/scenes exist.
- Verified the new PauseMenu signal and node paths match.
- Verified MobileControls is instantiated by GameHUD.
- Verified modified gameplay scripts guard access to `/root/MobileInput`.
- Verified the old player Health/HP HUD nodes are removed.
- No Godot executable is installed in this workspace, so a real Godot 3.5 runtime execution test could not be performed here.

## Important
Open the project with Godot 3.5 and run it once on desktop first, then export to Android/iOS. The project is explicitly configured for GLES2.
