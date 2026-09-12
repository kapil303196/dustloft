#!/usr/bin/env bash
# The deploy path for dustloft.com.
#
# IMPORTANT: this Vercel project has NO git integration. Merging to main does
# not deploy anything. The site goes live only when somebody runs
# `vercel --prod` from site/, which uploads the folder as-is. This script is
# that path: it regenerates the derived files, tells you the exact command to
# run, waits for you to run it, and then pings IndexNow.
#
#   tools/deploy-site.sh              # regenerate, prompt, then submit
#   tools/deploy-site.sh --dry-run    # regenerate, prompt, IndexNow dry run
#   tools/deploy-site.sh --check      # verify the derived files are current
#
# The script never runs `vercel` itself. Deploying is your call, made with
# your credentials, in your terminal.
#
# Order matters. IndexNow must be told about URLs only once they are live,
# so the submission happens after you confirm the deploy finished -- never
# before.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"

DRY_RUN=0
CHECK_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) DRY_RUN=1 ;;
    --check)      CHECK_ONLY=1 ;;
    -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

hr() { printf '%s\n' "------------------------------------------------------------"; }

if [ "$CHECK_ONLY" -eq 1 ]; then
  hr; echo "Checking derived files are up to date"; hr
  "$REPO/tools/site-sitemap.sh" --check
  python3 "$REPO/tools/make-llms-full.py" --check
  exit 0
fi

hr
echo "1/3  Regenerating derived files"
hr
"$REPO/tools/site-sitemap.sh"
python3 "$REPO/tools/make-llms-full.py"

if command -v xmllint >/dev/null 2>&1; then
  xmllint --noout "$REPO/site/sitemap.xml"
  echo "sitemap.xml is well-formed XML"
fi

echo
hr
echo "2/3  Deploy — run this yourself, in this repo:"
hr
echo
echo "    cd \"$REPO/site\" && vercel --prod"
echo
echo "(There is no git integration on this project. Nothing ships until that"
echo " command completes. Commit the regenerated sitemap.xml and llms-full.txt"
echo " too, so the repo matches what is live.)"
echo

if [ ! -t 0 ]; then
  echo "Not an interactive terminal — stopping before the IndexNow step."
  echo "Run 'tools/indexnow.sh --submit' by hand once the deploy is live."
  exit 0
fi

printf 'Press Enter once `vercel --prod` has finished, or Ctrl-C to skip IndexNow: '
read -r _ || { echo; echo "skipped."; exit 0; }

echo
hr
echo "3/3  Submitting the sitemap URLs to IndexNow"
hr
if [ "$DRY_RUN" -eq 1 ]; then
  "$REPO/tools/indexnow.sh" --dry-run
else
  "$REPO/tools/indexnow.sh" --submit
fi

echo
echo "Done."
