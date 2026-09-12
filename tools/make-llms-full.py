#!/usr/bin/env python3
"""Regenerate site/llms-full.txt from the HTML pages actually present in site/.

A single plain-markdown dump of every indexable page, for AI agents that fetch
one file instead of crawling. Pages carrying `noindex`, plus 404.html and
stats.html, are skipped.

Never edit site/llms-full.txt by hand -- run this script instead:

    tools/make-llms-full.py            # writes site/llms-full.txt
    tools/make-llms-full.py --stdout   # print instead of writing
    tools/make-llms-full.py --check    # exit 1 if the file is out of date

Stdlib only: no pandoc, no pip install.
"""

from __future__ import annotations

import html
import re
import subprocess
import sys
from datetime import datetime
from html.parser import HTMLParser
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SITE = REPO / "site"
OUT = SITE / "llms-full.txt"
BASE = "https://dustloft.com"

# Never included, regardless of their robots meta.
SKIP_FILES = {"404.html", "stats.html"}

# Elements whose entire subtree is dropped.
DROP = {
    "script", "style", "head", "header", "nav", "footer", "svg", "button",
    "form", "input", "select", "textarea", "noscript", "template", "iframe",
    "picture", "source", "audio", "video",
}

VOID = {
    "area", "base", "br", "col", "embed", "hr", "img", "input", "link",
    "meta", "param", "source", "track", "wbr",
}

BLOCK = {
    "p", "div", "section", "article", "main", "ul", "ol", "li", "table",
    "thead", "tbody", "tr", "pre", "blockquote", "h1", "h2", "h3", "h4",
    "h5", "h6", "dl", "dt", "dd", "figure", "figcaption", "hr",
}


class Node:
    __slots__ = ("tag", "attrs", "kids")

    def __init__(self, tag: str, attrs: dict | None = None):
        self.tag = tag
        self.attrs = attrs or {}
        self.kids: list = []


class Tree(HTMLParser):
    """Builds a forgiving element tree. Unclosed tags are tolerated."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = Node("#root")
        self.stack = [self.root]
        self.dropping = 0
        self.drop_tag = None

    def handle_starttag(self, tag, attrs):
        if self.dropping:
            if tag == self.drop_tag and tag not in VOID:
                self.dropping += 1
            return
        if tag in DROP:
            if tag in VOID:
                return
            self.dropping = 1
            self.drop_tag = tag
            return
        if tag in VOID:
            self.stack[-1].kids.append(Node(tag, dict(attrs)))
            return
        node = Node(tag, dict(attrs))
        self.stack[-1].kids.append(node)
        self.stack.append(node)

    def handle_startendtag(self, tag, attrs):
        if self.dropping or tag in DROP:
            return
        self.stack[-1].kids.append(Node(tag, dict(attrs)))

    def handle_endtag(self, tag):
        if self.dropping:
            if tag == self.drop_tag:
                self.dropping -= 1
                if self.dropping == 0:
                    self.drop_tag = None
            return
        for i in range(len(self.stack) - 1, 0, -1):
            if self.stack[i].tag == tag:
                del self.stack[i:]
                return

    def handle_data(self, data):
        if self.dropping:
            return
        self.stack[-1].kids.append(data)


def find(node: Node, tag: str):
    if isinstance(node, str):
        return None
    if node.tag == tag:
        return node
    for kid in node.kids:
        hit = find(kid, tag)
        if hit is not None:
            return hit
    return None


def absolutise(href: str) -> str:
    href = href.strip()
    if href.startswith("/"):
        return BASE + href
    return href


WS = re.compile(r"[ \t\r\n]+")

# Structural containers that may appear inside otherwise-inline content.
WRAPPER = {
    "div", "span", "p", "li", "dt", "dd", "section", "figcaption", "small",
    "label", "td", "th", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol",
}


def inline(node, in_code: bool = False) -> str:
    """Render inline content of a node to markdown."""
    out = []
    for kid in node.kids:
        if isinstance(kid, str):
            out.append(kid if in_code else WS.sub(" ", kid))
            continue
        t = kid.tag
        if t == "br":
            out.append("\n" if in_code else " ")
        elif t in ("strong", "b"):
            inner = inline(kid, in_code).strip()
            out.append(f"**{inner}**" if inner else "")
        elif t in ("em", "i"):
            inner = inline(kid, in_code).strip()
            out.append(f"*{inner}*" if inner else "")
        elif t == "code" and not in_code:
            inner = inline(kid, True).strip()
            out.append(f"`{inner}`" if inner else "")
        elif t == "a":
            inner = inline(kid, in_code).strip()
            href = absolutise(kid.attrs.get("href", ""))
            if inner and href:
                out.append(f"[{inner}]({href})")
            else:
                out.append(inner)
        elif t in ("img", "svg"):
            continue
        elif t in WRAPPER and not in_code:
            # Sibling wrappers often sit flush against each other in the
            # minified HTML; keep their text from fusing into one word.
            inner = inline(kid).strip()
            if inner:
                out.append(" " + inner + " ")
        else:
            out.append(inline(kid, in_code))
    joined = "".join(out)
    return joined if in_code else WS.sub(" ", joined)


def inline_self(node) -> str:
    """Render a node *including* its own tag (so <a href> survives)."""
    holder = Node("#holder")
    holder.kids = [node]
    return inline(holder)


def cell(node) -> str:
    return inline(node).strip().replace("|", "\\|")


def render(node, blocks: list[str], depth: int = 0) -> None:
    """Walk block-level structure, appending markdown blocks."""
    for kid in node.kids:
        if isinstance(kid, str):
            if kid.strip():
                text = WS.sub(" ", kid).strip()
                if text:
                    blocks.append(text)
            continue
        t = kid.tag

        if t in ("h1", "h2", "h3", "h4", "h5", "h6"):
            level = int(t[1])
            text = inline(kid).strip()
            if text:
                blocks.append("#" * max(2, min(level, 6)) + " " + text)

        elif t == "p":
            text = inline(kid).strip()
            if text:
                blocks.append(text)

        elif t == "pre":
            code = find(kid, "code") or kid
            body = inline(code, True).strip("\n").rstrip()
            if body:
                blocks.append("```\n" + body + "\n```")

        elif t == "blockquote":
            sub: list[str] = []
            render(kid, sub)
            if sub:
                quoted = "\n>\n".join(
                    "\n".join("> " + ln for ln in b.split("\n")) for b in sub
                )
                blocks.append(quoted)

        elif t in ("ul", "ol"):
            marker_n = 1
            items = []
            for li in kid.kids:
                if isinstance(li, str) or li.tag != "li":
                    continue
                sub: list[str] = []
                if has_block(li):
                    render(li, sub)
                else:
                    text = inline(li).strip()
                    if text:
                        sub = [text]
                if not sub:
                    continue
                bullet = "- " if t == "ul" else f"{marker_n}. "
                marker_n += 1
                body = "\n\n".join(sub)
                lines = body.split("\n")
                out = bullet + lines[0]
                pad = " " * len(bullet)
                for ln in lines[1:]:
                    out += "\n" + (pad + ln if ln else "")
                items.append(out)
            if items:
                blocks.append("\n".join(items))

        elif t == "table":
            rows = []
            head = None
            for tr in iter_rows(kid):
                cells = [c for c in tr.kids if not isinstance(c, str) and c.tag in ("th", "td")]
                if not cells:
                    continue
                vals = [cell(c) for c in cells]
                if head is None and all(c.tag == "th" for c in cells):
                    head = vals
                else:
                    rows.append(vals)
            if head is None and rows:
                head, rows = rows[0], rows[1:]
            if head:
                width = max([len(head)] + [len(r) for r in rows]) if rows else len(head)
                head += [""] * (width - len(head))
                lines = ["| " + " | ".join(head) + " |",
                         "|" + "|".join([" --- "] * width) + "|"]
                for r in rows:
                    r = r + [""] * (width - len(r))
                    lines.append("| " + " | ".join(r) + " |")
                blocks.append("\n".join(lines))

        elif t == "hr":
            continue

        elif t == "dl":
            parts = []
            for d in kid.kids:
                if isinstance(d, str) or d.tag not in ("dt", "dd"):
                    continue
                text = inline(d).strip()
                if not text:
                    continue
                parts.append(f"**{text}**" if d.tag == "dt" else text)
            if parts:
                blocks.append("\n\n".join(parts))

        elif not has_block(kid):
            # A wrapper holding only inline content (links, spans, bare text):
            # emit it as one paragraph so the link markup survives.
            text = inline_self(kid).strip()
            if text:
                blocks.append(text)

        else:
            render(kid, blocks, depth + 1)


def has_block(node) -> bool:
    """True when the subtree contains a block-level element worth splitting on."""
    for kid in node.kids:
        if isinstance(kid, str):
            continue
        if kid.tag in BLOCK or kid.tag in ("table", "pre", "blockquote"):
            return True
        if has_block(kid):
            return True
    return False


def iter_rows(table: Node):
    for kid in table.kids:
        if isinstance(kid, str):
            continue
        if kid.tag == "tr":
            yield kid
        elif kid.tag in ("thead", "tbody", "tfoot"):
            yield from iter_rows(kid)


META_ROBOTS = re.compile(
    r'<meta[^>]+name=["\']robots["\'][^>]*content=["\']([^"\']*)["\']', re.I)
CANONICAL = re.compile(
    r'<link[^>]+rel=["\']canonical["\'][^>]*href=["\']([^"\']+)["\']', re.I)
TITLE = re.compile(r"<title>(.*?)</title>", re.I | re.S)


def is_noindex(raw: str) -> bool:
    m = META_ROBOTS.search(raw)
    return bool(m and re.search(r"\bnoindex\b", m.group(1), re.I))


def clean_url(path: Path) -> str:
    rel = path.relative_to(SITE).as_posix()
    if rel == "index.html":
        return BASE + "/"
    if rel.endswith("/index.html"):
        return BASE + "/" + rel[: -len("index.html")]
    return BASE + "/" + rel[: -len(".html")]


def page_date(path: Path) -> str:
    """Commit date of the file, or its mtime when uncommitted or dirty."""
    rel = str(path.relative_to(REPO))
    try:
        dirty = subprocess.run(
            ["git", "status", "--porcelain", "--", rel],
            cwd=REPO, capture_output=True, text=True, check=True).stdout.strip()
        if not dirty:
            out = subprocess.run(
                ["git", "log", "-1", "--format=%cs", "--", rel],
                cwd=REPO, capture_output=True, text=True, check=True).stdout.strip()
            if re.fullmatch(r"\d{4}-\d{2}-\d{2}", out):
                return out
    except (OSError, subprocess.CalledProcessError):
        pass
    return datetime.fromtimestamp(path.stat().st_mtime).strftime("%Y-%m-%d")


def sort_key(path: Path):
    rel = path.relative_to(SITE).as_posix()
    if rel == "index.html":
        return (0, rel)
    if rel == "blog/index.html":
        return (1, rel)
    if rel.startswith("blog/"):
        return (2, rel)
    if rel == "safety.html":
        return (3, rel)
    if rel == "privacy.html":
        return (4, rel)
    if "/" in rel:
        return (5, rel)
    return (6, rel)


def discover() -> list[Path]:
    pages = []
    for path in sorted(SITE.rglob("*.html")):
        rel = path.relative_to(SITE).as_posix()
        if rel.split("/")[0].startswith("."):
            continue
        if path.name in SKIP_FILES:
            continue
        if is_noindex(path.read_text(encoding="utf-8", errors="replace")):
            continue
        pages.append(path)
    return sorted(pages, key=sort_key)


def page_markdown(path: Path) -> str:
    raw = path.read_text(encoding="utf-8", errors="replace")
    tree = Tree()
    tree.feed(raw)
    body = find(tree.root, "main") or find(tree.root, "article") or find(tree.root, "body") or tree.root

    h1 = find(body, "h1")
    if h1 is not None:
        title = inline(h1).strip()
        h1.tag = "#skip"
        h1.kids = []
    else:
        m = TITLE.search(raw)
        title = html.unescape(m.group(1)).strip() if m else path.stem

    m = CANONICAL.search(raw)
    source = html.unescape(m.group(1)) if m else clean_url(path)

    blocks: list[str] = []
    render(body, blocks)

    # Drop consecutive duplicate blocks left behind by nested wrappers.
    deduped: list[str] = []
    for b in blocks:
        b = b.strip()
        if b and (not deduped or deduped[-1] != b):
            deduped.append(b)

    head = [f"# {title}", f"Source: {source}", f"Updated: {page_date(path)}"]
    return "\n".join(head) + "\n\n" + "\n\n".join(deduped) + "\n"


def build() -> str:
    pages = discover()
    parts = [
        "# Dustloft — full text of every indexable page",
        "",
        "Generated by tools/make-llms-full.py — do not edit by hand.",
        f"Site: {BASE}  ·  Source: https://github.com/kapil303196/dustloft",
        f"Pages: {len(pages)}",
        "",
    ]
    body = "\n\n---\n\n".join(page_markdown(p) for p in pages)
    return "\n".join(parts) + "\n" + body


def main(argv: list[str]) -> int:
    text = build()
    if "--stdout" in argv:
        sys.stdout.write(text)
        return 0
    if "--check" in argv:
        current = OUT.read_text(encoding="utf-8") if OUT.exists() else ""
        if current != text:
            print("site/llms-full.txt is out of date; run tools/make-llms-full.py",
                  file=sys.stderr)
            return 1
        print("site/llms-full.txt is up to date")
        return 0
    OUT.write_text(text, encoding="utf-8")
    print(f"wrote {OUT.relative_to(REPO)} "
          f"({len(text.encode('utf-8')) / 1024:.1f} KB, {len(discover())} pages)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
