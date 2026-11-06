# Fotolark

A simple, fast photo editor for Mac, in the spirit of Picasa: point it at your folders, fix a photo in seconds, and never lose an original. iPad and iPhone versions come later (Phase 6).

Built in Swift + SwiftUI on Apple frameworks only (Core Image, ImageIO, Vision, ImageCaptureCore). Minimum macOS 14 Sonoma.

## Status

Planning complete; development not started. Next: Phase 1 (core editor).

## Docs

- [docs/plan.md](docs/plan.md) — full version plan: 109 features, 6 phases plus optional Phase 7, risks, next steps
- [docs/roadmap.png](docs/roadmap.png) — release roadmap diagram
- [docs/naming-and-legal.md](docs/naming-and-legal.md) — name screening and rules for staying clear of Picasa/Google trademarks
- Live, editable plan (Claude Doc): https://claude.ai/artifact/C4sZy2hHauiyKFhUyMas6H

## Planned layout

```
Fotolark/
├── docs/              plans and research
├── FotolarkKit/       shared Swift package: edit recipes, Core Image filters, file I/O, bulk jobs
├── Fotolark/          macOS app (SwiftUI)
└── FotolarkTests/
```
