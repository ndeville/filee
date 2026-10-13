---
title: Filee app icon options
date: 2026-10-10
status: done - Nic picked 7 (red body), installed
---

# Filee app icon options

10 app icon concepts for Filee, to replace the placeholder (NicAI logo on red).

## What the folder holds

| Path                             | What it is                                                          |
| -                                | -                                                                   |
| `261010-filee-icon-options.html` | The showcase. Self-contained, works offline. Open it and pick 1.    |
| `src/icon-NN-<slug>.svg`         | The 10 source SVGs, 1024x1024, macOS grid (body 824 at x=100 y=100) |
| `qa/png/`                        | `rsvg-convert` renders at 1024, 256, 128, 32 and 16 px              |
| `qa/sheet-*.png`                 | Contact sheets: 16 and 32 px magnified, on light and dark grounds   |
| `qa/page-*.png`                  | Screenshots of the showcase (light, dark, phone width)              |
| `build/make_icons.py`            | Writes the 10 SVGs                                                  |
| `build/make_page.py`             | Writes the showcase page from the SVGs                              |
| `build/render_qa.sh`             | Renders `qa/`                                                       |

To change a concept, edit `build/make_icons.py`, then run:

```bash
python3 build/make_icons.py && ./build/render_qa.sh && python3 build/make_page.py
```

## How to swap the chosen icon into the app

The SVGs need nothing beyond `rsvg-convert`: no external fonts, no external files.

1. Copy the chosen SVG into the repo, for example to `assets/AppIcon.svg`.
2. In `build.sh`, step 1, replace the `python3 - "$ICONSET" <<'PY' ... PY` block with:

   ```zsh
   cp assets/AppIcon.svg "$ICONSET/icon.svg"
   ```

   The `rsvg-convert` loop, `rm "$ICONSET/icon.svg"` and `iconutil` lines stay as they are.
3. Delete the cached icon so step 1 runs again: `rm FileeMac/Resources/AppIcon.icns`. Step 1 only runs when that file is missing.
4. Run `./build.sh --install`. If the Dock still shows the old icon, run `killall Dock`.

## Log

- v1 - 261010 - 10 concepts, showcase page, QA renders.
- v2 - 261010 - Nic picked 7 and asked for a black body. `build/make_final.py` writes 7b (white folder, red edelweiss, black) and 7c (red folder, white edelweiss, black). 7b is installed as `assets/AppIcon.svg`; `qa/final/compare.png` compares 7, 7b and 7c. Rule from Nic: every app icon carries his logo.
- v3 - 261010 - Nic went back to 7 on red. `src/icon-07-edelweiss-folder.svg` is `assets/AppIcon.svg` again; 7b and 7c stay as options.
