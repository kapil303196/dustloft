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

Download `Reclaim-1.0.0.dmg` from Releases, drag Reclaim to Applications, then
**right-click it and choose Open** the first time.

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

## What it looks at

Caches, build output, dependency folders, package-manager stores, Docker,
local LLM models, Xcode leftovers, the Trash, old Node runtimes, WhatsApp
media, and oversized git repositories — plus advisory items it will show you
but deliberately never runs itself.

## Contributing / continuing this work

Read [`DOCFILES.md`](DOCFILES.md) first. It carries the full context: why each
rule exists, the architecture, the threading model, and the known gaps.

## Prior art

[a third-party cleaner](https://example.com) is an excellent, mature,
notarized open-source Mac cleaner. If you want a general-purpose cleaner with
an app uninstaller and scheduling, use it. Reclaim exists for a narrower
purpose and a stricter safety model.

## License

MIT
