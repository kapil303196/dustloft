# DOCFILES — full context for any agent picking this up

> Read this file first. It contains everything needed to continue work on
> Reclaim without access to the original conversation.

---

## 1. Why this project exists

On 2026-09-07 a 512 GB MacBook Pro was at **96% full** — 404 GB used, 20 GB free,
with macOS reporting most of it as opaque "System Data". A manual investigation
over one session brought it down to **210 GB used / 215 GB free**. This app
automates that exact investigation so it never has to be done by hand again.

### What the manual session actually found (the spec, in effect)

| Finding | Size | Lesson encoded in the app |
|---|---|---|
| WhatsApp media in `~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media` | 92 GB | Biggest single win, but **irreversible** — WhatsApp does not re-serve old media. Became the `permanent` tier. |
| 217 `node_modules` folders under `~/Desktop/projects` | 46 GB | Project-scoped sweeps, never a global filesystem walk. |
| `.next` build caches (42 folders) | 20 GB | Build output is the most under-appreciated hog. |
| Docker `Docker.raw` | 23 GB → 8.8 GB | Prune reclaims, and the raw file compacts afterwards. **Never `--volumes`.** |
| Ollama models | 16 GB | Trivially re-pullable. |
| `~/.cache` (huggingface, uv, puppeteer) | 10 GB | — |
| Orphaned Xcode simulator runtimes | 13 GB | Root-owned, needs admin; orphaned because Xcode was uninstalled. |
| Trash | 9.3 GB | Partly root-owned → needs admin. |
| `cameron/search-by-name/.csv_tmp` | 9.3 GB | Stale scratch data. |

### The two mistakes that shaped the safety model

**1. The glob that hid 55 GB.** The first pass used `du -shx /Users/apple/*`,
which silently skips dotfolders. `~/.ollama` (16 GB), `~/.cache` (10 GB) and
`~/.Trash` (9.3 GB) were invisible. **The app therefore enumerates with
`FileManager.contentsOfDirectory`, which includes hidden entries.** Never
reintroduce a `*` glob for enumeration.

**2. The repo that was nearly destroyed.** The user asked to "remove car-viewer
data". Its `.git` was 2.2 GB and it had a GitHub remote configured, so deleting
it looked safe. Running `git ls-remote origin` showed the remote
**authenticated successfully but returned zero refs** — nothing had ever been
pushed. That local `.git` was the only copy of the project's history.

> **This is the app's headline feature.** Reclaim never offers to delete a
> `.git` directory. It offers `git gc --prune=now` only, and it shows a red
> "Only copy — nothing pushed" badge when `ls-remote` returns zero refs.
> See `Scanners.gitRepos` and `GitSafety` in the source.

---

## 2. Safety model — do not weaken these

| Rule | Where enforced |
|---|---|
| Three tiers: `regenerable` / `admin` / `permanent` | `Models.swift` → `SafetyTier` |
| Permanent items are **never bulk-selected** by "Select all" | `ScanEngine.selectAll` |
| Permanent deletion requires a separate acknowledgement checkbox | `ReviewSheet` |
| `.git` folders are never deletable — gc only | `Scanners.gitRepos` |
| Docker volumes are never pruned (no `--volumes`) | `Cleaner.perform` → `.dockerPrune` |
| Cloud-synced folders are hard-excluded and not user-overridable | `Settings.hardExclusions` |
| Brave is excluded by default (explicit user instruction) | `Settings.defaultExclusions` |
| MySQL data dir is never touched — binlogs are advisory only | `Scanners.advisories` |
| Project sweeps only run inside configured roots, never `/` or `$HOME` | `Scanners.projectDirs` |
| Nothing is deleted without the review sheet | `RootView` → `ReviewSheet` |
| Purgeable space is deliberately **not** listed as reclaimable | `SafetyNote` |

`hardExclusions` covers `~/Dropbox`, `~/Library/Mobile Documents` (iCloud),
`~/Library/CloudStorage`, Brave, and `MobileSync`. Deleting inside a sync root
propagates the deletion to every other device — that is why it is not
overridable from the UI.

---

## 3. Architecture

```
Sources/Reclaim/
  ReclaimApp.swift        @main entry point, WindowGroup
  DesignSystem.swift      DS.* semantic tokens; light+dark defined together
  Models.swift            SafetyTier, CleanAction, ScanItem, Category, GitSafety
  Settings.swift          persisted roots + exclusions (JSON in App Support)
  Shell.swift             Process wrapper, PATH resolution, admin via osascript
  Scanner.swift           ScanEngine (@MainActor) + Scanners (background)
  Cleaner.swift           executes CleanActions, batches admin into one prompt
  Views/
    Components.swift      Card, TierBadge, StorageMeter, CompositionBar, buttons
    ContentView.swift     RootView, sidebar, overview, action bar
    CategoryDetailView.swift  per-category item list
    ReviewSheet.swift     review → running → results
```

**Threading:** `ScanEngine` and `Cleaner` are `@MainActor`. Every `Scanners.*`
and `Cleaner.perform` call runs on a background queue via
`withCheckedContinuation`. Never call `Shell.*` on the main thread — `du` on a
large tree blocks for minutes.

**PATH:** GUI apps inherit a minimal PATH, so `docker`, `ollama`, `git` and
`node` are resolved by hand in `Shell.which` against a fixed list of
directories (`/opt/homebrew/bin` first). Do not switch to bare `Process`
launches by name.

**Categories** are declared in `Category.all`. To add one: append a `Category`,
add a matching entry to the `jobs` array in `ScanEngine.scan()`, and write a
`Scanners.foo()` returning `[ScanItem]`.

---

## 4. Build and install (macOS only)

```bash
./build.sh     # swift build -c release, assemble dist/Reclaim.app, ad-hoc sign
./install.sh   # copy to /Applications
open -a Reclaim
```

Requires only **Xcode Command Line Tools** — no full Xcode. Verified on
macOS 26.5.1 with Swift 6.2.4; SwiftUI ships in the CLT SDK. The package pins
`swift-tools-version: 5.9` deliberately: tools-version 6.0 turns on strict
concurrency and `Process`/`FileManager`/`ObservableObject` usage here will not
compile under it.

### Permissions
- **Full Disk Access** is needed for accurate sizes of `~/.Trash`, Group
  Containers and `com.docker.docker`. Without it those return EPERM, the scan
  continues, and `PermissionBanner` appears. Ad-hoc signing means FDA may need
  re-granting after each rebuild.
- **Admin items** use `osascript … with administrator privileges`, batched into
  a single prompt in `Cleaner.run`. Requires `NSAppleEventsUsageDescription`
  in `Info.plist`.

---

## 5. Hard limitation — this cannot be built in the cloud

A Linux cloud environment **cannot compile, run, verify or install this app**.
SwiftUI and AppKit require the Apple SDK, code signing requires macOS, and the
scanners read a real Mac filesystem. A remote agent can usefully edit source,
write docs, and open PRs — but every change must be compiled and verified on a
Mac before it can be trusted. Treat "it compiles" as unverified until someone
runs `./build.sh` locally.

---

## 6. Status

**Working and installed.** First live run found 16.78 GB reclaimable across
package caches (6.71 GB), Python venvs (3.21 GB), app caches (2.46 GB),
developer caches (2.21 GB), node_modules (2.02 GB) and build output (169.5 MB).

### Distribution

`tools/make_dmg.sh` produces a drag-to-install DMG. It is **not notarised** — that
needs a paid Apple Developer ID. Until then, users must right-click → Open once.
If a Developer ID becomes available, the path is: sign with
`Developer ID Application`, `xcrun notarytool submit --wait`, then
`xcrun stapler staple`. A GitHub Actions macOS runner can do all of this on tag.

### The Full Disk Access trap (important)

macOS keys TCC permissions to the code signature. Ad-hoc signatures change every
build, so Full Disk Access was being revoked on each rebuild and macOS fell back
to per-folder Desktop/Downloads prompts — which looked like the app ignoring a
granted permission. `tools/setup_signing.sh` fixes this with a stable self-signed
identity; `build.sh` uses it automatically when present. Also note macOS applies
a new grant only to a freshly launched process, hence the relaunch button.

### Known gaps / next steps
1. **No app icon** — ships with the generic macOS placeholder. Needs an `.icns`
   at `Resources/Reclaim.icns` (build.sh already copies it if present).
2. **Not notarized** — ad-hoc signed only. Fine for personal use; Gatekeeper
   will complain if distributed. Would need an Apple Developer ID.
3. **No scheduling** — scheduled periodic auto-scan is not implemented.
4. **No menu-bar mode.**
5. **Simulator runtimes** are removed with `rm -rf`. When Xcode *is* installed,
   `xcrun simctl runtime delete` is the correct path.
6. **Docker size parsing** reads the `docker system df` table; a format change
   upstream would break `parseDockerSize`. A `--format json` path would be more
   robust.
7. **No tests.** `parseDockerSize` and the ollama `list` parser are the two
   pure functions most worth covering.

### Prior art
`a third-party cleaner` (MIT, ~6.3k stars) is a mature general-purpose macOS
cleaner — app uninstaller, orphan finder, scheduling, notarized. Reclaim
deliberately does **not** compete with it. Reclaim's distinct value is
project-scoped sweeps of `node_modules`/build output, the git-remote safety
check, and the permanent-tier treatment of WhatsApp media. If a general cleaner
is what is wanted, a third-party cleaner is the better tool.
