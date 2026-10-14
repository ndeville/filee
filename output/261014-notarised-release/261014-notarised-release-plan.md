---
title: Notarised download of Filee on GitHub Releases
date: 2026-10-14
status: parked
trigger: Nic says "go"
estimate: about 1 hour, plus a few minutes per Apple notarisation run
---

# Notarised download of Filee on GitHub Releases

Today Filee installs only from source (Xcode 26, `./build.sh --install`). This plan adds a download that opens on any Mac with macOS 26 and Apple silicon, with the standard "downloaded from the internet" prompt only.

The Developer ID name and team ID show in every signed app (`codesign -dv`). That's normal, and Nic dropped the rule that hid them on 14th October 2026.

## Why notarise

Gatekeeper checks every app that comes from the internet:

| App                                  | What the user sees                                                                    |
| -                                    | -                                                                                     |
| Developer ID signed and notarised    | 1 standard prompt, then it opens                                                      |
| Unsigned or ad hoc                   | Blocked. Since macOS 15: **System Settings > Privacy & Security > Open Anyway**, or `xattr -dr com.apple.quarantine` |

## Nic's step first

Notarisation needs an app-specific password for Nic's Apple ID. It's a secret: Nic types it, Claude never sees or stores it.

1. Create the password at [account.apple.com](https://account.apple.com): **Sign-In and Security > App-Specific Passwords**, name it "notarytool".
2. Store it in the keychain as the profile `filee` (Claude gives the exact command, with the team ID filled in):

   ```bash
   xcrun notarytool store-credentials filee --apple-id <Apple ID e-mail> --team-id <TEAMID>
   ```

## The steps (defaults; Nic answers only where he disagrees)

1. **`./build.sh --release`:** build, sign with the Developer ID and the hardened runtime, submit to `notarytool` and wait, staple the ticket so it opens offline, then check with `spctl -a -vv` and `stapler validate`. Default: stop with an error if any step fails.
2. **DMG:** a window with Filee next to an Applications shortcut, so the user drags it across. The DMG is notarised and stapled too. Default: DMG, not zip.
3. **Version:** 1.0.0, build number 1 (today 0.1.0), and the git tag `v1.0.0`.
4. **Test as a stranger would:** download the DMG from GitHub on this Mac so macOS marks it as downloaded, and check that Gatekeeper opens it with the standard prompt only.
5. **GitHub Release `v1.0.0`** with the DMG and short release notes. This publishes the signed app. Default: Claude shows Nic the release notes before publishing.
6. **README:** a **Download** section near the top with a download badge, in place of "Filee has no download". Building from source moves below it.
7. **Docs:** `SPEC.md` open item 1 (notarisation) marked done, the release steps in `CLAUDE.md`, the release in Claude's project memory.
8. **Nic's note** ([Filee: my own file manager for macOS](https://notes.nicolasdeville.com/nicai/filee/)): Filee can be downloaded, with the link. Then `./publish.sh`.
9. **Tests, commit, push:** `swift test` and `python3 qa.py` must pass first.

## Defaults kept

- Apple silicon and macOS 26 only. An Intel or older-macOS build needs testing that can't happen on Nic's Mac.
- No automatic updates (Sparkle), no Homebrew cask, no Mac App Store. Each is separate work, for later if people use Filee.

## Not in this plan

- **Mac App Store:** not ready. It needs the App Sandbox (a disk access grant through an open panel, security-scoped bookmarks), custom actions moved to `~/Library/Application Scripts/` and `NSUserUnixTask`, Empty Trash without AppleScript, a privacy manifest, privacy and support URLs, and the EU trader status. About 3 to 5 days, and 2 versions to maintain.
- **Faster folder opening:** Filee opens a 10,000-file folder in 465 ms. About 250 ms of that is layout and drawing after the listing (see `CLAUDE.md`, Facts).
- **Size Browser** (phase 1.5).
