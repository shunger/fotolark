# Releasing Fotolark on the Mac App Store

Fotolark is released and updated through the Mac App Store (decided Nov 6, 2026). The
app is ready for it: sandboxed, with a privacy manifest, the required Info.plist keys,
a universal (Apple silicon + Intel) Release archive that builds, and no third-party code.
What's left needs an Apple Developer Program membership and a few decisions.

## Already done in the project

- App Sandbox with only the access Fotolark uses (see "Entitlements" below).
- `Fotolark/PrivacyInfo.xcprivacy`: no tracking, no data collected; reasons given for
  UserDefaults (CA92.1) and file dates (3B52.1, C617.1).
- `ITSAppUsesNonExemptEncryption = NO` (Fotolark only hashes files to find duplicates).
- Category: Photography. Photos library usage description. App icon at every size.
- Shortcuts actions, Finder Services, help and a first-run tour.
- `xcodebuild -scheme Fotolark -configuration Release archive` succeeds.

## Steps

1. [ ] Join the Apple Developer Program ($99/year) with the Apple ID that will own the app.
2. [ ] Decide the price: free or a one-time price (still open in `plan.md`).
3. [ ] Run the trademark search and register the domains (`plan.md` › Next steps).
4. [ ] In Xcode › Fotolark target › Signing & Capabilities: tick "Automatically manage
       signing" and choose your team. (The project currently signs with "-" for local
       runs.) Xcode registers the bundle ID `com.purehungerlabs.fotolark`.
5. [ ] Set the version: `MARKETING_VERSION` 1.0 (now 0.1), `CURRENT_PROJECT_VERSION` 1.
6. [ ] In App Store Connect › Apps › +: new macOS app, name "Fotolark", bundle ID above,
       SKU e.g. `fotolark-mac`.
7. [ ] Fill in the listing from `app-store-listing.md`; publish the privacy policy
       (`privacy-policy.md`) at a URL (e.g. fotolark.app/privacy) and add the support URL.
8. [ ] App Privacy: answer "Data Not Collected".
9. [ ] Screenshots: at least one at 2880 × 1800 (or 2560 × 1600, 1440 × 900, 1280 × 800).
       Suggested: the grid with stars, the editor with Magic fix, People, a collage, import.
10. [ ] Product › Archive in Xcode, then Distribute App › App Store Connect › Upload.
11. [ ] TestFlight: add yourself and family as testers and use the build for a while.
12. [ ] Submit for review with the review notes below.

Each update after that: raise `MARKETING_VERSION` (e.g. 1.1) and `CURRENT_PROJECT_VERSION`,
archive, upload, submit. People get it through App Store updates.

## Entitlements (for the review notes)

| Entitlement | Why |
| --- | --- |
| App Sandbox | Required for the Mac App Store |
| User-selected files, read-write | Opening, editing alongside, exporting and organizing the photos and folders the person chooses |
| App-scope bookmarks | Remembering the folders the person added, so they don't have to grant access every launch |
| USB | Importing photos from cameras and phones connected by USB (ImageCaptureCore) |
| Photos library | Importing from Apple Photos, and saving edits back as Photos edits |
| Printing | File › Print |

## Review notes (paste into App Store Connect)

> Fotolark is a photo organizer and editor for the folders on your Mac. To try it: choose
> File › Add Folder… and pick any folder of photos, double-click a photo, and press Magic
> fix. Edits are non-destructive and saved in small ".fotolark" sidecar files next to each
> photo. Face grouping, duplicate finding and text recognition run on-device with Vision;
> nothing is sent anywhere and there is no account. USB access is for importing from
> cameras and phones; Photos access is requested only when the person opens Apple Photos
> under Import.

## Still to check on real hardware before submitting

- Importing from an iPhone, a camera and an SD card (ImageCaptureCore).
- Apple Photos: import, Edit in Fotolark, Save to Photos, and Revert to Original in Photos.
- Printing to a real printer.
- Finder Services and the Shortcuts actions.
- The app on the Intel Mac (subject detection may fall back to people only there).
