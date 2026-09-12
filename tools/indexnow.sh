#!/usr/bin/env bash
# Submit the sitemap's URLs to IndexNow (Bing, Yandex, Seznam, Naver).
#
#   tools/indexnow.sh               # print the payload, send nothing
#   tools/indexnow.sh --submit      # actually submit
#
# Submitting is the default-off case on purpose: a mistyped command should not
# announce the whole site to a search engine.
#
# The key is the IndexNow key file already published at the site root:
#   site/<key>.txt   containing exactly <key>
# IndexNow requires the file name (without .txt) and its contents to match,
# so the script checks that and refuses to run if the file is missing or the
# contents do not match its name.
#
# Nothing here deploys. Submit only AFTER the new pages are live, otherwise
# the search engines are told to recrawl URLs that have not changed yet.
#
# Endpoint: https://api.indexnow.org/indexnow
# Accepted responses: 200 (OK) and 202 (accepted, key validation pending).
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"
SITE="$REPO/site"
SITEMAP="$SITE/sitemap.xml"
HOST="dustloft.com"
ENDPOINT="https://api.indexnow.org/indexnow"
BATCH=1000          # IndexNow allows up to 10000 URLs per request.

DRY_RUN=1          # send nothing unless --submit is passed explicitly
for arg in "$@"; do
  case "$arg" in
    --submit|--live) DRY_RUN=0 ;;
    --dry-run|-n) DRY_RUN=1 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# --- locate and validate the key file -------------------------------------
keyfile=""
while IFS= read -r f; do
  name="$(basename "$f" .txt)"
  case "$name" in
    [0-9a-fA-F]*) ;;
    *) continue ;;
  esac
  [ ${#name} -ge 8 ] || continue
  contents="$(tr -d '[:space:]' < "$f")"
  if [ "$contents" = "$name" ]; then keyfile="$f"; break; fi
done < <(find "$SITE" -maxdepth 1 -type f -name '*.txt' | LC_ALL=C sort)

if [ -z "$keyfile" ]; then
  echo "error: no IndexNow key file found in site/." >&2
  echo "       Expected a file named <key>.txt whose contents are exactly <key>." >&2
  exit 1
fi

KEY="$(basename "$keyfile" .txt)"
KEY_LOCATION="https://${HOST}/${KEY}.txt"
echo "key file:     site/$(basename "$keyfile")"
echo "keyLocation:  ${KEY_LOCATION}"

[ -f "$SITEMAP" ] || { echo "error: $SITEMAP not found; run tools/site-sitemap.sh first" >&2; exit 1; }

# --- read the URL list out of the sitemap ---------------------------------
url_list="$(python3 - "$SITEMAP" <<'PY'
import sys, xml.etree.ElementTree as ET
ns = {"s": "http://www.sitemaps.org/schemas/sitemap/0.9"}
root = ET.parse(sys.argv[1]).getroot()
for loc in root.findall(".//s:url/s:loc", ns):
    if loc.text:
        print(loc.text.strip())
PY
)" || { echo "error: could not parse $SITEMAP" >&2; exit 1; }

# bash 3.2 (the macOS system bash) has no mapfile.
URLS=()
while IFS= read -r u; do
  [ -n "$u" ] && URLS+=("$u")
done <<<"$url_list"

if [ "${#URLS[@]}" -eq 0 ]; then
  echo "error: sitemap contains no <loc> entries" >&2
  exit 1
fi
echo "urls:         ${#URLS[@]}"

# --- submit in batches ----------------------------------------------------
payload_file="$(mktemp -t indexnow)"
batch_file="$(mktemp -t indexnow-batch)"
trap 'rm -f "$payload_file" "$batch_file"' EXIT

total=${#URLS[@]}
batch_no=0
failed=0
i=0
while [ "$i" -lt "$total" ]; do
  batch=("${URLS[@]:i:BATCH}")
  batch_no=$((batch_no + 1))
  i=$((i + BATCH))

  printf '%s\n' "${batch[@]}" > "$batch_file"
  python3 -c '
import json, sys
host, key, key_location, path = sys.argv[1:5]
with open(path) as fh:
    urls = [ln.strip() for ln in fh if ln.strip()]
json.dump({"host": host, "key": key, "keyLocation": key_location,
           "urlList": urls}, sys.stdout, indent=2)
sys.stdout.write("\n")
' "$HOST" "$KEY" "$KEY_LOCATION" "$batch_file" > "$payload_file"

  if [ "$DRY_RUN" -eq 1 ]; then
    echo
    echo "--- DRY RUN: batch ${batch_no}, ${#batch[@]} urls ---"
    echo "POST ${ENDPOINT}"
    echo "Content-Type: application/json; charset=utf-8"
    echo
    cat "$payload_file"
    continue
  fi

  echo "submitting batch ${batch_no} (${#batch[@]} urls) ..."
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 60 \
            -X POST "$ENDPOINT" \
            -H 'Content-Type: application/json; charset=utf-8' \
            --data-binary @"$payload_file" || echo 000)"
  case "$code" in
    200) echo "  HTTP $code — OK, urls submitted" ;;
    202) echo "  HTTP $code — accepted, key validation pending" ;;
    400) echo "  HTTP $code — bad request (invalid JSON or url format)" >&2; failed=1 ;;
    403) echo "  HTTP $code — key not valid; check ${KEY_LOCATION} is reachable" >&2; failed=1 ;;
    422) echo "  HTTP $code — urls do not belong to ${HOST}, or key mismatch" >&2; failed=1 ;;
    429) echo "  HTTP $code — too many requests" >&2; failed=1 ;;
    *)   echo "  HTTP $code — unexpected response" >&2; failed=1 ;;
  esac
done

if [ "$DRY_RUN" -eq 1 ]; then
  echo
  echo "dry run only — nothing was sent. Pass --submit to send it."
  exit 0
fi

exit "$failed"
