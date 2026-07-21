# BarBlackout — Release & Launch Runbook

Everything here is a handoff checklist. Steps that need your machine, your Apple
ID, or your GitHub account are marked **[you]**. Copy/paste blocks are ready to go.

---

## ⚠️ Read this first — deployment target caps your user base

`project.pbxproj` currently sets the **Release** `MACOSX_DEPLOYMENT_TARGET = 26.0`.
That means the shipped app **won't even launch for anyone below macOS 26 (Tahoe)** —
which in mid-2026 is almost everyone. For a high-user-base / high-stars launch this
is the single biggest own-goal in the repo.

The real floor is the **CoreAudio process API** (`kAudioHardwarePropertyProcessObjectList`,
`kAudioProcessPropertyIsRunningOutput`), which is **macOS 14.2+**. IOKit assertions and
the SkyLight/CGS calls are far older. So you can safely target **macOS 14.2** and reach
essentially the entire current Mac install base instead of a sliver.

**[you] Recommended:** in Xcode → target → Build Settings → set the Release
"macOS Deployment Target" to **14.2** (or 14.0 if you add an `@available` guard around
the audio check). Rebuild, sanity-check on a 14.x machine if you can. Then the cask's
`depends_on macos: ">= :sonoma"` is honest.

---

## 1. [you] Record the demo GIF  → `docs/demo.gif`

The README already references `docs/demo.gif`. This is the #1 star lever.
- Record a <5s clip: menu bar blacking out → hover-to-reveal → the ring icon filling.
- QuickTime (screen recording) or [Kap](https://getkap.co) → export GIF, keep < ~5 MB.
- `mkdir -p docs && mv ~/Desktop/demo.gif docs/demo.gif`

## 2. [you] Build a Release .app and package the DMG

```bash
# From the repo root
xcodebuild -project BarBlackout.xcodeproj -scheme BarBlackout \
  -configuration Release -derivedDataPath build

APP="build/Build/Products/Release/BarBlackout.app"

# Simple DMG (no notarization). If you have create-dmg installed it's prettier;
# hdiutil needs nothing extra:
hdiutil create -volname "BarBlackout" -srcfolder "$APP" \
  -ov -format UDZO BarBlackout.dmg

shasum -a 256 BarBlackout.dmg   # copy this into release/barblackout.rb
```

> Optional notarization (needs the $99 Apple Developer account). Skip for the first
> launch; the README already tells users to right-click → Open. If you later notarize:
> `xcrun notarytool submit BarBlackout.dmg --keychain-profile <profile> --wait`
> then `xcrun stapler staple BarBlackout.dmg`.

## 3. [you] Install the gh CLI and cut the GitHub release

```bash
brew install gh
gh auth login

# Set repo metadata (do this once):
gh repo edit aadia1234/BarBlackout \
  --description "Hide your macOS menu bar on a timer — and automatically while you watch video." \
  --homepage "https://github.com/aadia1234/BarBlackout" \
  --add-topic macos --add-topic menubar --add-topic swift \
  --add-topic swiftui --add-topic appkit --add-topic reverse-engineering

# Commit the README/LICENSE/etc first, then tag + release:
git add README.md LICENSE release docs
git commit -m "Docs, license, and release assets for launch"
git push

gh release create v1.0.0 BarBlackout.dmg \
  --title "BarBlackout 1.0.0" \
  --notes "First public release. Hide the macOS menu bar on a timer, or automatically while video is playing. Install: \`brew install --cask aadia1234/tap/barblackout\` or download the DMG below (right-click → Open on first launch)."
```

## 4. [you] Publish the Homebrew tap

```bash
# One-time: create the tap repo on GitHub named exactly  homebrew-tap
gh repo create aadia1234/homebrew-tap --public \
  --description "Homebrew tap for BarBlackout"

git clone https://github.com/aadia1234/homebrew-tap.git
mkdir -p homebrew-tap/Casks
cp release/barblackout.rb homebrew-tap/Casks/barblackout.rb
# → edit Casks/barblackout.rb: paste the real sha256 from step 2
cd homebrew-tap
git add Casks/barblackout.rb
git commit -m "Add BarBlackout cask"
git push

# Verify end-to-end on a clean-ish account:
brew install --cask aadia1234/tap/barblackout
```

## 5. [you] Launch — one anchor, cross-post same day

Best window: **Tue–Thu, ~8–10am US Eastern.** Be free for the next 2–4 hours; the
first two hours decide HN ranking, and your first comment is where stars are won.

### Show HN (primary)
Lead with the *technical hook*, not the product name.

**Title:**
> Show HN: Detecting macOS video playback after Apple killed MediaRemote in 15.4

**URL:** the GitHub repo.

**First comment (post it yourself, immediately):**
> I wanted my menu bar to auto-hide while watching video, but macOS has no public API
> for "is a video playing right now" — and Apple locked down the private one
> (MediaRemote) in 15.4. So BarBlackout infers it from two public signals ANDed
> together: the frontmost app holds a display-sleep assertion (video players take one
> specifically for *visual* playback) AND it's actively outputting audio (CoreAudio's
> per-process API). The audio gate is what rejects presentations and screen-sharing,
> which take the same assertion silently.
>
> The fiddly part was browsers: Chrome plays media in renderer helper processes, and
> Safari's WebContent processes are reparented and only link back via "responsible
> pid," so matching the frontmost PID alone never sees the audio. Walking both the
> process tree and the responsible-pid chain fixes it. Code's here: [link to VideoDetector.swift]
>
> Known trade-off: a *muted* video doesn't register. Curious if anyone knows a cleaner
> public signal I missed.

### Same-day cross-posts
- **r/macapps** — product angle ("I made a menu-bar app that hides the bar on a timer / while you watch video"), link the demo GIF.
- **r/swift** or **r/macosprogramming** — the reverse-engineering angle, same story as the HN comment.
- **X/Twitter** — a short thread: problem → the two-signal trick → the browser-process gotcha → repo link + GIF.

Keep all of them pointing at the same repo. Respond to every substantive comment for
the first few hours.

## 6. [you] After launch (days 7–10)
- Triage issues; fix quick paper-cuts and any player-detection edge cases people report.
- Iterate the README based on what confused people.
- If it's gaining traction and you want the "signed & notarized" credibility line,
  buy the $99 account and re-release a notarized DMG.
- Update your resume: "BarBlackout — macOS menu-bar utility, N★ on GitHub;
  reverse-engineered video-playback detection around a removed Apple private API."
