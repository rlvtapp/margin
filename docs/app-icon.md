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
