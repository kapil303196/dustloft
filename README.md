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

```bash
git clone <this repo>
cd reclaim
./build.sh && ./install.sh
open -a Reclaim
```

Needs only the Xcode Command Line Tools — no full Xcode install.
Built and tested on macOS 26.5 with Swift 6.2.

For accurate sizes, grant Full Disk Access:
**System Settings → Privacy & Security → Full Disk Access → add Reclaim**.

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
