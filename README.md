# Fotolark

A simple, fast photo editor for Mac, in the spirit of Picasa: point it at your folders, fix a photo in seconds, and never lose an original. iPad and iPhone versions come later (Phase 6).

Built in Swift + SwiftUI on Apple frameworks only (Core Image, ImageIO, Vision, ImageCaptureCore). Minimum macOS 14 Sonoma.

## Status

- Phase 1 (core editor): built; waiting on the "edit 20 of your own photos" gate.
- Phase 2 (import and bulk tools), in batches:
  1. Browsing — watched folders, thumbnail grid, filmstrip, Info panel, live updates,
     file operations, Settings: **built**
  2. White balance picker, sharpen/clarity, vignette, histogram, copy/paste edits
  3. Strip metadata, export presets, Share sheet, drag out edited photos
  4. Bulk convert/rename/resize/rotate/move with a job queue
  5. Import from iPhone, camera, SD card and drives
  6. Shortcut cheat sheet and accessibility pass

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
