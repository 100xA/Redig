# DigUp fork icon

A D shaped lens and a mint search handle, on a deep forest background. The reduced shape stays recognizable in a
small search window or tray. This replacement icon was created for the independent [100xA fork](https://github.com/100xA/DigUp).
The original DigUp app and its previous icon were created by [Abdur Rahim](https://github.com/ARahim3/DigUp).

- `AppIcon.icon` is the editable Apple Icon Composer document, with separate Discovery and Search layers. It was
  opened, adjusted and saved in Icon Composer. `build.sh` compiles its materials with `actool` for macOS 26 and later.
- `appicon.svg` and `appicon-small.svg` provide the flat fallback used by older macOS versions, Windows and Linux.
- `tray.svg`, `tray-dim.svg` and `tray-paused.svg` provide the tray states. `menubar.svg` is a monochrome variant.
- Background: `#10231F`; lens: `#F4F7EE`; handle: `#A8E6CA`.

To regenerate the checked in fallback assets on a Mac, run from the repository root:

```sh
swift scripts/render-icons.swift
iconutil -c icns build.noindex/AppIcon.iconset -o Resources/AppIcon.icns
cp Resources/AppIcon.icns shell/src-tauri/icons/icon.icns
```

The script renders the SVGs to all app, tray and README PNGs and writes a multiresolution Windows ICO. The layered
Composer source is compiled separately by the normal app build. Keep the SVG geometry and the two Composer layer
assets in agreement when editing the mark.
