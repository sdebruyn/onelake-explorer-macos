# OFEM brand assets

Canonical source of truth for the OFEM (OneLake File Explorer for macOS) marks.
All other bitmap renditions in this repo are generated from the SVGs in this folder.

## Files

| File | Purpose |
| --- | --- |
| `ofem-icon.svg` | Square macOS app icon (1024×1024 squircle treatment). Source for the `AppIcon.appiconset` bitmaps and the `.icns` bundle. |
| `ofem-lockup.svg` | Wordmark + icon side by side. Use for headers, READMEs, slides. |
| `ofem-mark.svg` | Square mark in full colour (gradient-filled, 200×200 viewBox). The primary brand mark. |
| `ofem-mark-mono-dark.svg` | Monochrome variant in ink — use on light surfaces. |
| `ofem-mark-mono-light.svg` | Monochrome variant in paper — use reversed-out on dark surfaces. |
| `OFEM-Logo.html` | Design-system reference page. Open in a browser for the colour palette, scale tests, lockup pairings, and usage rules. |

Open `OFEM-Logo.html` in any browser — it loads the sibling SVGs via relative
paths and renders the full spec offline.

## Derived bitmaps

The following generated artefacts live elsewhere in the repo and are reproduced
from the SVGs above. Re-run the commands below whenever a source SVG changes.

- `docs/assets/favicon.ico` — docs site favicon, derived from `ofem-mark.svg`.
- `apple/OneLake/Assets.xcassets/AppIcon.appiconset/icon_*.png` — macOS app
  icon set, derived from `ofem-icon.svg`.

Both pipelines need `rsvg-convert` (from `librsvg`) and `magick` (from
ImageMagick 7). Install with Homebrew:

```bash
brew install librsvg imagemagick
```

### Regenerate the docs site favicon

```bash
# from repo root
rsvg-convert -w 256 -h 256 assets/branding/ofem-mark.svg -o /tmp/favicon-256.png
rsvg-convert -w 128 -h 128 assets/branding/ofem-mark.svg -o /tmp/favicon-128.png
rsvg-convert -w 64  -h 64  assets/branding/ofem-mark.svg -o /tmp/favicon-64.png
rsvg-convert -w 48  -h 48  assets/branding/ofem-mark.svg -o /tmp/favicon-48.png
rsvg-convert -w 32  -h 32  assets/branding/ofem-mark.svg -o /tmp/favicon-32.png
rsvg-convert -w 16  -h 16  assets/branding/ofem-mark.svg -o /tmp/favicon-16.png

magick /tmp/favicon-16.png /tmp/favicon-32.png /tmp/favicon-48.png \
       /tmp/favicon-64.png /tmp/favicon-128.png /tmp/favicon-256.png \
       docs/assets/favicon.ico
```

### Regenerate the macOS AppIcon set

```bash
# from repo root
for size in 16 32 64 128 256 512 1024; do
  rsvg-convert -w "$size" -h "$size" assets/branding/ofem-icon.svg \
    -o "apple/OneLake/Assets.xcassets/AppIcon.appiconset/icon_${size}.png"
done
```

`Contents.json` in that folder maps each bitmap to its slot in the asset
catalogue and should not need to change unless icon sizes are added or removed.

## Editing rules

See `OFEM-Logo.html` for the full spec. Hard rules:

- Do not recolour the gradient stops.
- Do not flip the gradient direction.
- Do not separate the three drops.
- Minimum clear space around the mark = the height of the small accent drop.
- For favicons below 16 px or any single-colour context, use the mono variants.
