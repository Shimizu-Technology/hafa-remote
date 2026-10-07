# HR-047 — Refine the original app icon

The app icon now matches the Warm teal interface: an ivory remote silhouette on deep teal, a teal directional pad with a mint select button, and two quiet graphite controls. Simple shapes replace the previous glossy cyan treatment. The recognizable silhouette and strong contrast remain visible at small sizes.

## Artwork and source

`scripts/generate-app-icon.swift` is the canonical vector source. It draws original CoreGraphics paths using four colors: deep teal `#12685D`, warm ivory `#F7F5EF`, mint `#78D5BF`, and graphite `#192927`. It uses no fonts, raster input, stock art, manufacturer logos, lettering, or emoji. The generic remote motif does not reproduce a specific physical remote model.

Run from the repository:

```sh
swift scripts/generate-app-icon.swift
```

The generator replaces `HafaRemote/Resources/Assets.xcassets/AppIcon.appiconset/HafaRemoteAppIcon.png` with an opaque, 1024 × 1024, sRGB PNG. Existing Xcode asset-catalog metadata stays unchanged. Apple applies the platform's icon mask; the source fills the entire square canvas.

Optional standalone previews and output paths:

```sh
swift scripts/generate-app-icon.swift --preview-dir /tmp/hafa-icon-previews
swift scripts/generate-app-icon.swift --output /tmp/hafa-icon.png
```

Previews render directly from the vector source at 20, 40, 60, 120, and 180 pixels. On the current macOS/CoreGraphics runtime, repeated 1024-pixel rendering produces byte-identical PNG output. Rasterization may differ between operating-system versions.

## Acceptance and evidence

- [x] Author original, flat vector geometry matching the approved palette.
- [x] Keep the current iPhone asset/bundle scope and avoid additional unverified appearance variants.
- [x] Validate the export as 1024 × 1024 with no alpha channel.
- [x] Inspect the full-size image and 20- and 60-pixel previews for silhouette and directional-pad legibility.
- [x] Verify repeated rendering produces identical SHA-256 output on this machine.
- [x] Inspect the built icon in native SpringBoard and Settings on an owned iPhone 16 Pro iOS 18.5 simulator.
- [ ] Run the full repository gate and current-head code review before merge.

The validated PNG SHA-256 is `22feaff50af5677b7a6b96a1743f2c14aa86a4bf87429a6b9029dd6d59b6c2ec`.

The original artwork and generator remain unchanged during the release-QA phase.
Signed build-for-testing, bundle-seal verification, release preflight, and static
checks passed. Computer use verified the installed icon's silhouette and contrast
on SpringBoard and in Settings → Apps. Native screenshots are preserved at
`/tmp/hafa-hr047-validation/springboard-icon.png` and
`/tmp/hafa-hr047-validation/settings-apps-icon.png`.

No protocol or hardware-support behavior changes. Updated internal-candidate
notes and privacy/tooling evidence are in [release QA](HR-047-RELEASE-QA.md).
The integrated full gate and current-head review remain with the release owner.
