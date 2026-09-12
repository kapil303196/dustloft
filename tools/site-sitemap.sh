#!/usr/bin/env bash
# Regenerate site/sitemap.xml from the files actually present under site/.
#
#   tools/site-sitemap.sh              # rewrite site/sitemap.xml
#   tools/site-sitemap.sh --stdout     # print instead of writing
#   tools/site-sitemap.sh --check      # exit 1 if the file is out of date
#
# Included: every .html under site/ except 404.html, stats.html and anything
# carrying a `noindex` robots meta.
#
# <loc>      clean URL, matching vercel.json's cleanUrls -- no .html suffix,
#            directory index pages as /path/.
# <lastmod>  the file's last commit date (git log -1 --format=%cs), falling
#            back to its mtime when the file is uncommitted or modified in
#            the working tree. Re-run this whenever page edits land, and
#            always before a deploy.
#
# Safe to re-run: output is deterministic for a given working tree.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"
SITE="$REPO/site"
OUT="$SITE/sitemap.xml"
BASE="https://dustloft.com"

SKIP_NAMES="404.html stats.html"

mode="write"
for arg in "$@"; do
  case "$arg" in
    --stdout) mode="stdout" ;;
    --check)  mode="check" ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

file_date() {
  # Commit date when the file is clean and tracked; mtime otherwise.
  local f="$1" rel status d
  rel="${f#"$REPO"/}"
  status="$(git status --porcelain -- "$rel" 2>/dev/null || true)"
  if [ -z "$status" ]; then
    d="$(git log -1 --format=%cs -- "$rel" 2>/dev/null || true)"
    if [ -n "$d" ]; then printf '%s\n' "$d"; return; fi
  fi
  if date -r 0 >/dev/null 2>&1; then
    stat -f '%Sm' -t '%Y-%m-%d' "$f"        # BSD / macOS
  else
    date -u -d "@$(stat -c '%Y' "$f")" +%Y-%m-%d   # GNU / Linux
  fi
}

clean_url() {
  local rel="$1"
  case "$rel" in
    index.html)   printf '%s/\n' "$BASE" ;;
    */index.html) printf '%s/%s\n' "$BASE" "${rel%index.html}" ;;
    *)            printf '%s/%s\n' "$BASE" "${rel%.html}" ;;
  esac
}

# priority and changefreq, by clean path.
rank() {
  case "$1" in
    "$BASE/")                                          echo "1.0 weekly" ;;
    "$BASE/blog/")                                     echo "0.9 weekly" ;;
    "$BASE/blog/why-is-system-data-so-large-on-mac")   echo "0.9 weekly" ;;
    "$BASE/blog/how-to-clear-system-data-mac")         echo "0.9 weekly" ;;
    "$BASE/safety")                                    echo "0.9 weekly" ;;
    "$BASE/privacy")                                   echo "0.6 monthly" ;;
    *)                                                 echo "0.8 weekly" ;;
  esac
}

# Sort order: home, blog index, blog posts, safety, privacy, then the rest.
sort_rank() {
  case "$1" in
    index.html)      echo 0 ;;
    blog/index.html) echo 1 ;;
    blog/*)          echo 2 ;;
    safety.html)     echo 3 ;;
    privacy.html)    echo 4 ;;
    */*)             echo 5 ;;
    *)               echo 6 ;;
  esac
}

pages=""
while IFS= read -r f; do
  rel="${f#"$SITE"/}"
  case "$rel" in .*|*/.*) continue ;; esac
  base="$(basename "$rel")"
  for skip in $SKIP_NAMES; do
    [ "$base" = "$skip" ] && continue 2
  done
  # noindex check: match the robots meta content, not the word "index".
  if grep -qiE '<meta[^>]+name=["'"'"']robots["'"'"'][^>]*content=["'"'"'][^"'"'"']*noindex' "$f"; then
    continue
  fi
  pages="${pages}$(sort_rank "$rel")	${rel}
"
done < <(find "$SITE" -type f -name '*.html' | LC_ALL=C sort)

body=""
count=0
warnings=""
while IFS=$'\t' read -r _ rel; do
  [ -n "$rel" ] || continue
  loc="$(clean_url "$rel")"
  lastmod="$(file_date "$SITE/$rel")"
  read -r prio freq <<<"$(rank "$loc")"

  # Cross-check against the page's own canonical, if it declares one.
  canon="$(grep -oiE '<link[^>]+rel=["'"'"']canonical["'"'"'][^>]*href=["'"'"'][^"'"'"']+' "$SITE/$rel" \
            | sed -E 's/.*href=["'"'"']//' | head -1 || true)"
  if [ -n "$canon" ] && [ "$canon" != "$loc" ] && [ "${canon%/}" != "${loc%/}" ]; then
    warnings="${warnings}  warning: $rel canonical is $canon but sitemap loc is $loc
"
  fi

  body="${body}  <url><loc>${loc}</loc><lastmod>${lastmod}</lastmod><changefreq>${freq}</changefreq><priority>${prio}</priority></url>
"
  count=$((count + 1))
done <<<"$(printf '%s' "$pages" | LC_ALL=C sort -t'	' -k1,1n -k2,2)"

xml="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">
${body}</urlset>"

case "$mode" in
  stdout) printf '%s\n' "$xml" ;;
  check)
    if [ "$(cat "$OUT" 2>/dev/null || true)" != "$xml" ]; then
      echo "site/sitemap.xml is out of date; run tools/site-sitemap.sh" >&2
      exit 1
    fi
    echo "site/sitemap.xml is up to date ($count URLs)"
    ;;
  write)
    printf '%s\n' "$xml" > "$OUT"
    echo "wrote site/sitemap.xml ($count URLs)"
    ;;
esac

[ -n "$warnings" ] && printf '%s' "$warnings" >&2
exit 0
