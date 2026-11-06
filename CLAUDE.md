# Fotolark — notes for Claude

- Plan: `docs/plan.md` (mirror of the Claude Doc https://claude.ai/artifact/C4sZy2hHauiyKFhUyMas6H). When the plan changes, update both.
- Build only what the current phase lists; check the phase table before adding features.
- Architecture: all editing logic lives in the `FotolarkKit` Swift package and must stay free of AppKit/Mac-only APIs so it also builds for iPadOS/iOS (Phase 6). UI code lives in the app target.
- Edits are non-destructive: an edit recipe (ordered operations, JSON-encodable) is replayed through Core Image; originals are never overwritten without asking.
- Apple frameworks only; no third-party dependencies without asking (Sparkle is the one planned exception, Phase 5).
- Tests: `cd FotolarkKit && swift test`; iOS check: `xcodebuild -scheme FotolarkKit -destination 'generic/platform=iOS' build` (run from FotolarkKit/).
- Never use "Picasa", "Picasso" or Google phrases in UI text or assets. See `docs/naming-and-legal.md`.
