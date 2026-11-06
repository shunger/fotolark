# Fotolark

A simple, fast photo editor for Mac, in the spirit of Picasa: point it at your folders, fix a photo in seconds, and never lose an original. iPad and iPhone versions come later (Phase 6).

Built in Swift + SwiftUI on Apple frameworks only (Core Image, ImageIO, Vision, ImageCaptureCore). Minimum macOS 14 Sonoma.

## Status

- Phase 1 (core editor): built; waiting on the "edit 20 of your own photos" gate.
- Phase 2 (import and bulk tools): built; waiting on the "a 10,000-photo folder
  scrolls smoothly" gate. Batches:
  1. Browsing — watched folders, thumbnail grid, filmstrip, Info panel, live updates,
     file operations, Settings: **built**
  2. White balance picker, sharpness/clarity/structure, vignette, histogram,
     copy/paste edits: **built**
  3. Strip metadata, export presets, multi-photo export, Share sheet, drag out
     edited photos, bulk job queue: **built**
  4. Bulk convert/rename/resize/rotate/move (with date folders), each with a
     preview: **built**
  5. Import from iPhone, camera, SD card, drives and folders (new only, date range,
     date folders, rename, HEIC → JPEG, skip duplicates, verified delete): **built**
  6. Keyboard shortcuts list (⌘/), keyboard cropping, accessibility pass: **built**

- Phase 3 (retouch and creative): built; waiting on the "retouching looks natural
  on real photos" gate. Batches:
  1. RAW, noise reduction, curves, levels, HSL color ranges: **built**
  2. Auto-straighten, auto-crop, red-eye removal: **built**
  3. Spot heal, clone stamp, soften skin: **built**
  4. Looks with strength, focal B&W, custom presets, text, watermark: **built**
  5. Compare view: **built**
  6. Live Photos and video import, bulk metadata, bulk auto-fix/preset: **built**

- Phase 4 (organize and print): in progress. Batches:
  1. Star ratings, pick/reject flags, tags (optionally saved into the files), albums: **built**
  2. Library index, search (including text in photos), filters, timeline: **built**
  3. Slideshow: **built**
  4. Brush and gradient adjustments, tilt-shift, lens correction: **built**
  5. Object removal, background blur, remove background
  6. Borders and frames, shapes and arrows, versions
  7. Print, contact sheet, collage, PDF

## Build and test

- Open `Fotolark.xcodeproj` in Xcode and run the **Fotolark** scheme, or
  `xcodebuild -project Fotolark.xcodeproj -scheme Fotolark build`.
- Engine tests: `cd FotolarkKit && swift test`.
- Check the engine still builds for iPad/iPhone:
  `cd FotolarkKit && xcodebuild -scheme FotolarkKit -destination 'generic/platform=iOS' build`.

The app is sandboxed and signed to run locally (no Apple Developer account needed yet).

## Docs

- [docs/plan.md](docs/plan.md) — full version plan: 109 features, 6 phases plus optional Phase 7, risks, next steps
- [docs/roadmap.png](docs/roadmap.png) — release roadmap diagram
- [docs/naming-and-legal.md](docs/naming-and-legal.md) — name screening and rules for staying clear of Picasa/Google trademarks
- Live, editable plan (Claude Doc): https://claude.ai/artifact/C4sZy2hHauiyKFhUyMas6H

## Layout

```
Fotolark/
├── docs/              plans and research
├── FotolarkKit/       shared Swift package: edit recipes, Core Image filters, file I/O (+ its tests)
└── Fotolark/          macOS app (SwiftUI)
```
