<h1 align="center">Dustloft</h1>

<p align="center">
  <b>Find out what is actually eating your Mac's disk — and get it back safely.</b><br>
  A native macOS app that never deletes anything you cannot get back without telling you first.
</p>

---

## Why

macOS reports tens or hundreds of gigabytes as "System Data" and gives you no way
to look inside it. Dustloft opens that box: it measures every real consumer of
space, sorts them by how recoverable they are, and makes you confirm before
anything is removed.

It was built after a manual cleanup took one 512 GB Mac from **20 GB free to
215 GB free** — and after that cleanup nearly destroyed a git repository whose
history existed nowhere else. Both the findings and the near-miss are baked into
the app's rules.

## Safety first

Dustloft sorts everything it finds into three tiers:

| Tier | Meaning |
|---|---|
| **Regenerable** | Comes back on its own — caches, build output, dependencies, Docker images |
| **Needs admin** | Safe to remove, but macOS asks for your password once |
| **Permanent** | Nothing rebuilds it. Never bulk-selected, needs a separate confirmation, and is moved to the Trash rather than deleted outright |

And it refuses, by design, to:

- delete a `.git` directory — it offers `git gc` only, and warns in red when a repo's history exists nowhere but your disk
- touch Dropbox, iCloud Drive or any synced folder, where a local delete propagates everywhere
- remove Docker volumes
- touch your MySQL data directory
- claim it can reclaim "purgeable" space, which no third-party app can reliably free

Every removal is appended to `~/Library/Logs/Dustloft/operations.log` — timestamp,
action, size and full path, tab separated. It stays on your machine; there is no
telemetry and nothing is uploaded.

## Install

### One command (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/kapil303196/dustloft/main/install-online.sh | bash
```

This downloads the latest release, installs it, and opens it. Use this if you
want it to just work.

### From the DMG

**[Download the latest release](https://github.com/kapil303196/dustloft/releases/latest)**
— one universal build that runs natively on Apple Silicon and Intel. Drag
Dustloft to Applications.

macOS will then say it **"could not verify this app is free from malware"**.
That is expected and is not a claim that anything was found. It means the build
is not *notarised* by Apple, which requires a paid Apple Developer Program
membership ($99/year). There is no free tier that grants a Developer ID
certificate or access to notarisation.

To open it anyway on **macOS 15 or later** — note that Control-click → Open no
longer works, Apple removed that:

1. Try to open Dustloft once and let it be blocked.
2. Go to **System Settings → Privacy & Security**, scroll down, and click
   **Open Anyway** next to the message about Dustloft.

Or in Terminal:

```bash
xattr -dr com.apple.quarantine /Applications/Dustloft.app
```

The one-command installer above avoids all of this, because macOS applies the
quarantine flag to browser downloads, not to `curl`.

Each release also publishes a `.sha256` file if you want to verify the download.

### From source

```bash
git clone https://github.com/kapil303196/dustloft.git
cd dustloft
./tools/setup_signing.sh    # optional, see below
./build.sh && ./install.sh
```

Needs only the Xcode Command Line Tools — no full Xcode install.

### Why `setup_signing.sh` exists

macOS ties Full Disk Access to an app's **code signature**. An ad-hoc signature
changes on every build, so each rebuild silently revokes the permission you
granted — and macOS quietly falls back to nagging you for Desktop and Downloads
access instead. This creates a stable local identity so the grant survives
rebuilds. Only needed when building from source.

### Full Disk Access

Dustloft asks for this on first run and explains why. Two things worth knowing:

- macOS applies the permission **only to a freshly launched process**, so
  Dustloft has to relaunch once after you grant it. It offers a button to do so.
- If you rebuild the app with a different signature, you must remove Dustloft
  from the Full Disk Access list and re-add it.

## Updating

Dustloft checks GitHub Releases on launch. When a newer build exists it offers
**Update now**, which downloads the DMG, mounts it, replaces the installed app
and restarts. **Check for Updates…** in the Dustloft menu does the same on
demand, and the running version is shown at the bottom of the Overview.

Every push to `main` builds a universal DMG in CI and publishes it as a release,
so there is always something to update to.

## What it looks at

**Every installed app, discovered dynamically** — no hardcoded list. Dustloft
measures each app's data, resolves folder names to real app names, and separates
an app's actual content from its disposable caches, so whatever happens to be
hoarding space on *your* Mac shows up on its own.

Alongside that: the Trash, old downloads, leftovers from uninstalled apps,
forgotten screen recordings, video-editing scratch caches, virtual machine
images, device backups, mail attachments, browser caches, offline media, and
Messages attachments — plus the developer set (node_modules, build output,
package stores, Docker, local LLM models, Xcode leftovers, Node runtimes and
oversized git repositories), which only appears when such things are found.

Scans are cached between launches, so opening Dustloft is instant and a full
rescan only happens when you ask or once results are genuinely stale.

## Contributing / continuing this work

Read [`DOCFILES.md`](DOCFILES.md) first. It carries the full context: why each
rule exists, the architecture, the threading model, and the known gaps.

## License

MIT
