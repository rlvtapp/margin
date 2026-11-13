# App icon

Margin's icon is one sheet of paper with its top folded down over the front, in blue glass.

## Where it lives

- `Apps/Shared/AppIcon.icon` is the icon, made with Icon Composer (it ships inside Xcode). The Mac, iPhone and Watch apps all use this one file. On macOS 26, iOS 26 and watchOS 26, the system draws it as Liquid Glass, including the dark, clear and tinted looks.
- `Apps/<platform>/Assets.xcassets/AppIcon.appiconset` holds flat PNGs of the same icon for older systems (macOS 15, iOS 18, watchOS 11). Xcode uses the `.icon` where it can and these PNGs elsewhere, because both are named `AppIcon`.

The icon is two layers, `front.svg` (the sheet) and `flap.svg` (the fold), on a 1024 × 1024 canvas. Every corner has the same radius. The glass, shadows and light come from Icon Composer, not from the artwork.

## Changing it

1. Open `Apps/Shared/AppIcon.icon` in Icon Composer (Xcode › Open Developer Tool › Icon Composer), or edit the two SVGs and `icon.json` directly.
2. Render the PNG fallbacks again so older systems match:

```bash
T="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
I=Apps/Shared/AppIcon.icon
"$T" "$I" --export-image --output-file /tmp/ios.png --platform iOS --rendition Default --width 1024 --height 1024 --scale 1
"$T" "$I" --export-image --output-file /tmp/ios-dark.png --platform iOS --rendition Dark --width 1024 --height 1024 --scale 1
"$T" "$I" --export-image --output-file /tmp/mac.png --platform macOS --rendition Default --width 1024 --height 1024 --scale 1
"$T" "$I" --export-image --output-file /tmp/watch.png --platform watchOS --rendition Default --width 1024 --height 1024 --scale 1
```

3. Copy them into the asset catalogues:
   - **Mac:** use `mac.png` as it is, resized to each size in `macOS/.../AppIcon.appiconset` (`sips -z`).
   - **iPhone and Watch:** these icons can't have transparency. Put each render on a solid square of the tile colour, scaled up about 13% so the rendered edge falls outside the system's mask.

## Icon colours and the Dock

Settings → Appearance offers the icon in other colours. Each is its own Icon Composer file,
`Apps/Shared/AppIcon-<Name>[-Dark].icon`, listed as an alternate icon for the Mac and iOS targets
(`AppIconChoice` in `Sources/MailUI/Model/AppIconChoice.swift`). iPhone and iPad switch the Home
Screen icon. macOS can't change an installed app's icon, so on the Mac the choice shows in the
Dock only, in two parts:

- **While Margin is open**, `MailModel.applyAppIcon()` sets the app's Dock picture.
- **While Margin is closed**, a Dock tile plug-in draws it: `Apps/DockTile/DockTilePlugIn.swift`,
  the `MarginDockTile` target, built into `Margin.app/Contents/PlugIns/MarginDockTile.docktileplugin`
  and named by `NSDockTilePlugIn` in `Apps/Margin-Info.plist`. The Dock loads it into a helper
  process of its own when Margin's tile appears in the Dock, and at login for a tile kept there.

How the plug-in learns the choice:

- Margin is sandboxed and the Dock's helper isn't, so they share no settings or files. Instead,
  `applyAppIcon()` posts a distributed notification, `<bundle id>.dock-icon`, with the alternate
  icon's name (`AppIcon-Green-Dark`, or nothing for blue on light) as its object. That is all a
  sandboxed app can send, and all the plug-in needs.
- The plug-in remembers the name in the helper's own settings
  (`~/Library/Preferences/<bundle id>.docktile.plist`) and reads it back the next time it loads,
  for instance at login with Margin closed.
- When the plug-in loads it also asks (`<bundle id>.dock-icon.ask`) and a running Margin answers,
  so whichever of the two starts first, the choice arrives.
- The artwork isn't copied: the plug-in reads the alternate icons from Margin's own asset
  catalogue. It accepts icon names only, never paths, because any process can post the
  notification.
- With blue on light chosen, or nothing chosen yet, the plug-in leaves the tile alone and the Dock
  draws the main icon in the system's icon style.

No app group or extra entitlement is involved, so every build carries it, the ad hoc one from
`scripts/build-share.sh` included.

What stays the main icon: Finder, Launchpad, Spotlight and the app switcher while Margin is
closed. The Dock only loads the plug-in for a tile that's in the Dock; a copy that was already
kept there before it first had the plug-in picks it up at the next login (or after taking the
icon out of the Dock and putting it back).

To check a build: `Margin.app/Contents/PlugIns/MarginDockTile.docktileplugin` exists,
`plutil -p Margin.app/Contents/Info.plist | grep NSDockTilePlugIn` names it, and with a colour
chosen `defaults read <bundle id>.docktile icon` prints its name after Margin has run once.
