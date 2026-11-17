# Lighthouse App Icon — install

`AppIcon.appiconset/` is a ready Xcode asset. To use:

1. Drag the whole `AppIcon.appiconset` folder into your target's **Assets.xcassets** in Xcode
   (or replace the existing `AppIcon` set's contents with these files + `Contents.json`).
2. Target ▸ **General ▸ App Icons and Launch Screen ▸ App Icon** → set to `AppIcon`.
3. Build. macOS applies the rounded-rect mask/shadow itself, but these tiles already bake the
   Big Sur squircle (824px tile inside 1024, 100px transparent margin, r185) so they also look
   correct anywhere the raw PNG is shown.

## Contents
- `icon-source-night.svg` — editable vector master (concept **1a Night beacon**).
- `icon_16 / 32 / 64 / 128 / 256 / 512 / 1024.png` — rasterized sizes.
- `Contents.json` — maps the 10 mac idiom slots (1x/2x for 16, 32, 128, 256, 512) to those files.

## Regenerate / switch concept
Edit `icon-source-night.svg` (or swap to option 1b/1c/1d from `Lighthouse-Icon.dc.html`) and
re-export the seven PNG sizes at the same pixel dimensions — filenames and `Contents.json` stay the same.

Brand colors: navy `#0e1526`, cream `#eef1f6`, band red `#c73b34`, beacon amber `#f0b45e`.
