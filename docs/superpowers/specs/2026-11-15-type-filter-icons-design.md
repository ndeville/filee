# Type-filter icons: safe, recognizable fallback — Design

**Size:** small change (one file, new bundled assets).

## Why

`TypeFilterBar`'s buttons show "the icon of the family's default app" by asking
macOS which app opens a sample extension (`NSWorkspace.urlForApplication(toOpen:)`).
On a Mac with no real app installed for a family (no PowerPoint, no dedicated
Markdown app), macOS hands back whatever incidental app registered itself for
that file type — e.g. ChatGPT.app for `.pptx`, Xcode-beta for `.md`. The button
then shows a logo with no visual connection to "PowerPoint" or "Markdown,"
which is actively misleading rather than just imprecise.

## Goals

- Every filter button always shows something immediately recognizable as
  "this is the \<family\> filter," regardless of what's installed.
- Keep showing the user's actual preferred app's icon when one genuinely
  exists (Microsoft Office, VLC, IINA, Affinity Photo, Adobe Reader, etc.) —
  don't throw away accuracy that already works today.

## Non-goals

- Redesigning the badge/symbol visual language used elsewhere.
- Changing which extensions belong to which family (`FileTypeFilter.extensions`
  is untouched).

## Anti-goals

- Never ship a third-party brand logo (Microsoft, Adobe, VLC, etc.) as a
  bundled asset — CLAUDE.md's "no brand logos" rule stays in force for
  anything not Apple's own.
- Never silently replace a real, correctly-installed app's icon with a
  bundled fallback.

## Constraint surfaced and resolved

CLAUDE.md: *"No brand logos ship with the app."* Real Word/Excel/PowerPoint/VLC
icons are out. PowerPoint specifically has no safe source at all (not
installed, no Apple-made PowerPoint-equivalent exists without fetching a
third-party logo from the web). Apple's own app icons are the one safe,
recognizable source available — some already on every Mac's disk (Preview,
QuickTime Player, TextEdit, Photos), some fetched once from Apple's own
App Store listing (Pages, Numbers, Keynote) since they aren't installed here.
**Decision, made by Nic (fork owner) in this conversation: ship Apple's own
icons as the bundled fallback for this fork.** CLAUDE.md's "no brand logos"
line gets a one-line carve-out noting this exception, so a future agent
doesn't flag it as a violation.

## Approaches considered

- **A — colored letter/symbol badges** (already built, used today only when
  no app at all is registered). Zero sourcing, zero risk, but plain.
- **B — SF Symbol badges** instead of letters. Same safety, more iconographic.
- **C — hybrid, real Apple icons + badges only where no Apple icon exists.**
- **C+ (chosen) — hybrid, real Apple icons for every family**, using Pages/
  Numbers/Keynote to cover Word/Excel/PowerPoint (closing the gap C had).

## The decided how

**Per-family icon source**, in priority order — ask macOS for the real
default app first; use it only if it's a recognized, legitimate handler for
that family; otherwise use the bundled Apple icon:

| Family | Bundled fallback icon | Source |
|---|---|---|
| PDF | Preview | on-disk, `/System/Applications/Preview.app` |
| Images | Photos | on-disk, `/System/Applications/Photos.app` |
| Video | QuickTime Player | on-disk, `/System/Applications/QuickTime Player.app` |
| Markdown | TextEdit | on-disk, `/System/Applications/TextEdit.app` |
| Word | Pages | fetched once from Apple's App Store listing (`com.apple.Pages`) |
| Excel | Numbers | fetched once from Apple's App Store listing (`com.apple.Numbers`) |
| PowerPoint | Keynote | fetched once from Apple's App Store listing (`com.apple.Keynote`) |

**"Recognized, legitimate handler" check (my call, since it directly follows
from what Nic asked for):** each family gets a short allow-list of bundle IDs
that are real, known apps for that family (Microsoft Office apps, LibreOffice/
OpenOffice, Adobe Reader/Acrobat, VLC/IINA/QuickTime for video, Affinity/
Photos/Preview for images, etc. — the existing `fallbacks` dict in
`TypeFilterBar.swift` is the seed for this). If `urlForApplication(toOpen:)`
returns something on the family's allow-list, draw that app's real icon
(today's behavior, unchanged — this is why VLC and Microsoft Word/Excel
already look correct and keep looking correct). If it returns something not
on the list (ChatGPT, Xcode-beta, or nothing), draw the bundled Apple icon
for that family instead.

**Asset handling:** bundled icons ship as small pre-sized PNGs (matching the
existing `Logo.png` / `Icons.small` convention and the AppKit lesson against
decoding raw 1024px icons) in `FileeMac/Resources/TypeIcons/`, loaded the same
way the current code already downsamples `NSWorkspace` icons to a 64px bitmap.

## What's left to the builder

- Exact allow-list bundle IDs per family (seed from `TypeFilterBar.swift`'s
  existing `fallbacks` dict, extend reasonably — a generous but not
  exhaustive list is fine, per Nic's priority on "always recognizable" over
  "perfectly accurate").
- Exact PNG sizing/compression for the 7 bundled assets (follow the existing
  64px-bitmap convention already in the file).
- The one-line CLAUDE.md amendment carving out Apple's own icons from the
  "no brand logos" rule.
