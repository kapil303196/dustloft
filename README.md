<h1 align="center">Reclaim</h1>

<p align="center">
  <b>Find out what is actually eating your Mac's disk — and get it back safely.</b><br>
  A native macOS app that never deletes anything you cannot get back without telling you first.
</p>

---

## Why

macOS reports tens or hundreds of gigabytes as "System Data" and gives you no way
to look inside it. Reclaim opens that box: it measures every real consumer of
space, sorts them by how recoverable they are, and makes you confirm before
anything is removed.

It was built after a manual cleanup took one 512 GB Mac from **20 GB free to
215 GB free** — and after that cleanup nearly destroyed a git repository whose
history existed nowhere else. Both the findings and the near-miss are baked into
the app's rules.

## Safety first

Reclaim sorts everything it finds into three tiers:

| Tier | Meaning |
|---|---|
| **Regenerable** | Comes back on its own — caches, build output, dependencies, Docker images |
| **Needs admin** | Safe to remove, but macOS asks for your password once |
| **Permanent** | Cannot be recovered. Never bulk-selected; needs a separate confirmation |

And it refuses, by design, to:

- delete a `.git` directory — it offers `git gc` only, and warns in red when a repo's history exists nowhere but your disk
- touch Dropbox, iCloud Drive or any synced folder, where a local delete propagates everywhere
- remove Docker volumes
- touch your MySQL data directory
- claim it can reclaim "purgeable" space, which no third-party app can reliably free

## Install

### From the DMG (most people)

**[Download the latest release](https://github.com/kapil303196/reclaim/releases/latest)**
— a single universal build that runs natively on both Apple Silicon and Intel
Macs. Drag Reclaim to Applications, then **right-click it and choose Open** the
first time.

After that, Reclaim checks for new versions itself and can install them from
inside the app.

That right-click is necessary because this build is **not notarised by Apple**.
Notarisation requires a paid Apple Developer ID, and without one Gatekeeper will
refuse a normal double-click on a downloaded app. Nothing about the app is
unusual; it simply has no Apple-issued certificate. You do this once.

### From source

```bash
git clone <this repo>
cd reclaim
./tools/setup_signing.sh    # optional but recommended, see below
./build.sh && ./install.sh
open -a Reclaim
```

Needs only the Xcode Command Line Tools — no full Xcode install.
Built and tested on macOS 26.5 with Swift 6.2.

### Why `setup_signing.sh` exists

macOS ties Full Disk Access to an app's **code signature**. An ad-hoc signature
(`codesign -s -`) changes on every single build, so each rebuild silently revokes
the permission you granted — and macOS quietly falls back to nagging you for
Desktop and Downloads access instead. `setup_signing.sh` creates a stable,
self-signed local identity so the grant survives rebuilds. It is only needed if
you build from source.

### Full Disk Access

Reclaim asks for this on first run and explains why. Two things worth knowing:

- macOS applies the permission **only to a freshly launched process**, so
  Reclaim has to relaunch once after you grant it. It offers a button to do so.
- If you rebuild the app with a different signature, you must remove Reclaim
  from the Full Disk Access list and re-add it.

## Updating

Reclaim checks GitHub Releases on launch. When a newer build exists it offers
**Update now**, which downloads the DMG, mounts it, replaces the installed app
and restarts. **Check for Updates…** in the Reclaim menu does the same on
demand, and the running version is shown at the bottom of the Overview.

Every push to `main` builds a universal DMG in CI and publishes it as a release,
so there is always something to update to.

## What it looks at

**Every installed app, discovered dynamically** — no hardcoded list. Reclaim
measures each app's data, resolves folder names to real app names, and separates
an app's actual content from its disposable caches, so whatever happens to be
hoarding space on *your* Mac shows up on its own.

Alongside that: the Trash, old downloads, leftovers from uninstalled apps,
forgotten screen recordings, video-editing scratch caches, virtual machine
images, device backups, mail attachments, browser caches, offline media, and
Messages attachments — plus the developer set (node_modules, build output,
package stores, Docker, local LLM models, Xcode leftovers, Node runtimes and
oversized git repositories), which only appears when such things are found.

Scans are cached between launches, so opening Reclaim is instant and a full
rescan only happens when you ask or once results are genuinely stale.

## Contributing / continuing this work

Read [`DOCFILES.md`](DOCFILES.md) first. It carries the full context: why each
rule exists, the architecture, the threading model, and the known gaps.

## License

MIT
