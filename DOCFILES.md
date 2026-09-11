# DOCFILES — full context for any agent picking this up

> Read this file first. It contains everything needed to continue work on
> Dustloft without access to the original conversation.

---

## 1. Why this project exists

A 512 GB MacBook Pro was at **96% full** — 404 GB used, 20 GB free,
with macOS reporting most of it as opaque "System Data". A manual investigation
over one session brought it down to **210 GB used / 215 GB free**. This app
automates that exact investigation so it never has to be done by hand again.

### What the manual session actually found (the spec, in effect)

| Finding | Size | Lesson encoded in the app |
|---|---|---|
| WhatsApp media in `~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media` | 92 GB | Biggest single win, but **irreversible** — WhatsApp does not re-serve old media. Became the `permanent` tier. |
| 217 `node_modules` folders under one project root | 46 GB | Project-scoped sweeps, never a global filesystem walk. |
| `.next` build caches (42 folders) | 20 GB | Build output is the most under-appreciated hog. |
| Docker `Docker.raw` | 23 GB → 8.8 GB | Prune dustlofts, and the raw file compacts afterwards. **Never `--volumes`.** |
| Ollama models | 16 GB | Trivially re-pullable. |
| `~/.cache` (huggingface, uv, puppeteer) | 10 GB | — |
| Orphaned Xcode simulator runtimes | 13 GB | Root-owned, needs admin; orphaned because Xcode was uninstalled. |
| Trash | 9.3 GB | Partly root-owned → needs admin. |
| A stale scratch folder of split CSV files | 9.3 GB | Left-behind intermediate data. |

### The two mistakes that shaped the safety model

**1. The glob that hid 55 GB.** The first pass used `du -shx $HOME/*`,
which silently skips dotfolders. `~/.ollama` (16 GB), `~/.cache` (10 GB) and
`~/.Trash` (9.3 GB) were invisible. **The app therefore enumerates with
`FileManager.contentsOfDirectory`, which includes hidden entries.** Never
reintroduce a `*` glob for enumeration.

**2. The repo that was nearly destroyed.** A request came in to remove a
project's data. Its `.git` was 2.2 GB and it had a GitHub remote configured, so
deleting it looked safe. Running `git ls-remote origin` showed the remote
**authenticated successfully but returned zero refs** — nothing had ever been
pushed. That local `.git` was the only copy of the project's history.

> **This is the app's headline feature.** Dustloft never offers to delete a
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

## 2b. Counting, and the promise around it

Dustloft had no idea how many Macs it ran on or whether it had ever actually
given anyone their disk back. It now sends **one line, about once a day**:
`{ id, cleaned, version }` — a random UUID belonging to that copy, the running
total of bytes reclaimed, and the build number. That is the entire payload, and
`MetricsReport` is written as a type so a fourth field cannot be added without a
visible diff and a failing test.

Rules, in the same spirit as the safety model — do not weaken these either:

- **Nothing about the contents of a disk.** No file name, no path, no listing,
  no account, no address. The operations log stays local, always.
- **The identifier is random and made on first use.** Not derived from hardware
  or user, and never created at all if reporting is off before the first report.
- **The IP address is used to rate limit and nothing else.** A salted hash of it
  becomes a counter with a sixty-second TTL; the address itself is never
  written, and neither it nor the hash is attached to a report. Without
  `DUSTLOFT_IP_SALT` the salt is random per server process and never persisted,
  so those counters cannot be correlated across processes or restarts. Do not
  write that requests "cannot be linked at all" — within one process and one
  minute they share a counter, and the docs say so.
- **The card is drawn before anything is sent.** `isReporting` requires
  `noticeShown`, which the notice sets when it first appears. Without it, a
  first run where someone cleans straight away could report before being told.
- **Off is one click, and permanent.** The first-run card leads with the literal
  three fields and carries the off switch; the switch then lives in the Overview
  footer. `DUSTLOFT_NO_METRICS=1` disables it without launching the app, and an
  unrecognised value fails closed.
- **Aggregates only on the way out.** `/api/stats` returns totals. Nothing
  returns one install's row; the per-install value exists so a duplicate report
  is not counted twice, and for no other reason.

Counting correctness lives in one Lua script (`site/api/_lua.mjs`) because the
three properties that make the numbers mean anything — count an install once,
ignore a replayed report, keep the version tally equal to the install set — do
not survive being split across round trips.

The client cap `MetricsRules.maxCleaned` and the server's `MAX_CLEANED` are the
same number on purpose. Move one and move the other.

If this section and the code ever disagree, so do `README.md` and
`site/privacy.html`, and all four need fixing together.

### Turning the counters on (one manual step)

The endpoints ship inert. Until a store is attached, `/api/ping` returns 202 and
throws the report away and `/api/stats` reports `configured: false` — a preview
deployment is never broken by the absence, and nothing is recorded.

1. In the Vercel project, **Storage → add a Redis store** (the first-party KV
   product or Upstash; both expose the same REST API). The free tier is far more
   than this needs: one hash field per install, plus two counters.
2. Vercel injects the credentials itself. `_store.mjs` accepts either naming —
   `KV_REST_API_URL`/`KV_REST_API_TOKEN` or
   `UPSTASH_REDIS_REST_URL`/`UPSTASH_REDIS_REST_TOKEN` — so whichever was
   attached works without a code change.
3. Redeploy. `/stats` fills in on its own.

Two optional variables: `DUSTLOFT_IP_SALT` makes rate limiting global rather
than per server process, and `DUSTLOFT_STATS_TOKEN` closes `/api/stats` behind a
bearer token if the figures should stop being public.

---

## 3. Architecture

```
Sources/Dustloft/
  DustloftApp.swift        @main entry point, WindowGroup
  DesignSystem.swift      DS.* semantic tokens; light+dark defined together
  Models.swift            SafetyTier, CleanAction, ScanItem, Category, GitSafety
  Settings.swift          persisted roots + exclusions (JSON in App Support)
  Shell.swift             Process wrapper, PATH resolution, admin via osascript
  Scanner.swift           ScanEngine (@MainActor) + Scanners (background)
  Cleaner.swift           executes CleanActions, batches admin into one prompt
  Metrics.swift           the anonymous install/reclaimed count, and its rules
  Views/
    Components.swift      Card, TierBadge, StorageMeter, CompositionBar, buttons
    ContentView.swift     RootView, sidebar, overview, action bar
    CategoryDetailView.swift  per-category item list
    ReviewSheet.swift     review → running → results
    MetricsNotice.swift   first-run disclosure card and the permanent switch

site/api/
  _store.mjs              Redis over REST; no-ops when no store is attached
  _lua.mjs                the one atomic script that does all the counting
  ping.mjs                POST one report
  stats.mjs               GET the aggregates
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
./build.sh     # swift build -c release, assemble dist/Dustloft.app, ad-hoc sign
./install.sh   # copy to /Applications
open -a Dustloft
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

### Testing

`swift test` covers the pure parsers and, more importantly, the safety
predicates: that synced folders and Brave can never be offered for deletion,
that clearing the user exclusion list cannot unprotect a hard exclusion, that a
lookalike prefix does not match, that Docker volumes never count as reclaimable,
and that a remote with zero refs reads as "only copy" while an unchecked remote
does not.

It also pins the reporting rules: the throttle, the saturating total, and the
literal bytes of the payload — that last one fails if a fourth field is ever
added, which is the point of it.

Tests run in CI, not locally: XCTest ships with full Xcode, which the runner has
and a Command Line Tools machine does not. Treat CI as the test environment.

The two site endpoints have their own suite, `./tools/api-tests/run.sh`, run by
the `Site API` workflow. It starts a throwaway `redis-server` and drives the
real handlers through a shim that speaks the store's REST dialect — the counting
rules are a Lua script Redis executes, so a mocked store would only ever test
the mock. It needs `redis-server` on PATH (`brew install redis`) and skips
cleanly without it.

### Known gaps / next steps

1. **Not notarised** — the build is signed with a stable local identity, not an
   Apple Developer ID, so a downloaded copy needs one right-click → Open. Fixing
   this needs a paid account; the path is `Developer ID Application` signing,
   `xcrun notarytool submit --wait`, then `xcrun stapler staple`, all of which
   the existing workflow could do on tag.
2. **No scheduling** — there is no periodic background scan. The scan is now
   fast and cached, so a background refresh on a timer would be cheap to add.
3. **No menu-bar mode** — the app is window-only.
4. **Simulator runtimes** are removed with `rm -rf`. When Xcode *is* installed,
   `xcrun simctl runtime delete` is the supported route and should be preferred.
   This is untested here because Xcode is not installed on the machine it was
   written on.
5. **In-app update does not verify the download.** It checks the HTTP status and
   that the mounted image contains `Dustloft.app`, but does not check a signature
   or checksum before replacing the installed bundle. Notarisation plus a
   published checksum would close this properly.
6. **`describe()` cost** — naming the largest subfolder inside an app runs a
   nested `du`, so it is limited to the twelve biggest apps. The rest show a
   generic label.
