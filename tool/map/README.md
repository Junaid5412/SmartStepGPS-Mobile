# Offline map (Qatar, English)

The app's map is drawn from two bundled files - nothing comes from a third-party tile server:

| File | What it is |
|---|---|
| `assets/map/qatar.pmtiles` | Vector tiles for Qatar, zoom 0–15, cut from the Protomaps daily OpenStreetMap build |
| `assets/map/protomaps_light_en.json` | The official Protomaps "light" style, reduced to English labels |

**Licence:** the map data is OpenStreetMap, under the ODbL. The map must show
"© OpenStreetMap contributors" (the map screen does). The Protomaps style is CC0 and its
generator code is BSD-3.

## Refreshing the map data

1. Get the `pmtiles` CLI: https://github.com/protomaps/go-pmtiles/releases
2. Pick the latest build from https://build-metadata.protomaps.dev/builds.json and extract Qatar:

   ```
   pmtiles extract https://build.protomaps.com/YYYYMMDD.pmtiles qatar.pmtiles --bbox="50.70,24.45,51.70,26.20" --maxzoom=15
   pmtiles verify qatar.pmtiles
   ```

3. Replace `assets/map/qatar.pmtiles`.
4. In `lib/services/offline_map.dart`, set `_tilesVersion` to the new build date, so installed apps
   copy the new file instead of keeping the old one.

## Regenerating the style

Only needed if Protomaps changes its tile schema (check the `version` in `pmtiles show`).

```
npm install @protomaps/basemaps
node gen_style.cjs        # official light/English style  -> protomaps_light_en.json
node simplify_style.cjs   # English-only labels, no icons -> protomaps_light_en_flutter.json
```

Copy `protomaps_light_en_flutter.json` to `assets/map/protomaps_light_en.json`.

The simplification exists because the official style prints English *and* the local script on
two lines using `format` / `is-supported-script`, which the Flutter renderer does not draw, and
its icons need a sprite sheet the app does not ship.
