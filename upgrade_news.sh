#!/usr/bin/env bash
# World Monitor — news capture add-on. Safe to run more than once.
# Adds collectors/news.py, installs feedparser, wires it into the 15-min sweep.
set -e
cd /root/world_monitor

# 1. write the news collector
cat > collectors/news.py << 'WMNEWS_EOF'
"""
News collector — captures headlines from RSS feeds into a clean monthly CSV.

Philosophy (set by the project owner): capture EVERY item from every feed, not
just keyword matches. Tags only annotate what we already saved. Un-captured
news is gone forever, so we over-capture and tag loosely.

Writes to  news_data/news_YYYY-MM.csv  (one file per month).
Dedup by hash so the same story isn't logged again every 15 minutes.
Timestamps are normalised to UTC so they join cleanly to the price data later.
"""
import os
import re
import sys
import csv
import hashlib
from datetime import datetime, timezone

import feedparser

# --- feeds: (name, category, url). Start narrow; widen later. ---
FEEDS = [
    ("bbc_world",     "geopolitics", "https://feeds.bbci.co.uk/news/world/rss.xml"),
    ("aljazeera",     "geopolitics", "https://www.aljazeera.com/xml/rss/all.xml"),
    ("fed_press",     "macro",       "https://www.federalreserve.gov/feeds/press_all.xml"),
    ("cnbc_markets",  "market",      "https://www.cnbc.com/id/20910258/device/rss/rss.html"),
    ("coindesk",      "crypto",      "https://www.coindesk.com/arc/outboundfeeds/rss/"),
    ("cointelegraph", "crypto",      "https://cointelegraph.com/rss"),
]

# --- loose keyword tags (capture-all; these only ANNOTATE) ---
TAG_KEYWORDS = {
    "iran":      ["iran", "tehran"],
    "china":     ["china", "chinese", "beijing"],
    "japan":     ["japan", "boj", "tokyo"],
    "russia":    ["russia", "putin", "kremlin", "moscow"],
    "military":  ["military", "troops", "navy", "missile", "strike",
                  "warship", "spy ship", "fighter jet"],
    "war":       ["war", "conflict", "invasion", "ceasefire", "airstrike"],
    "oil":       ["oil", "crude", "opec", "brent", "wti"],
    "fuel":      ["fuel", "gas price", "petrol", "diesel"],
    "inflation": ["inflation", "cpi", "consumer price"],
    "fed":       ["federal reserve", "fomc", "powell", "rate cut",
                  "rate hike", "interest rate"],
    "bitcoin":   ["bitcoin", "btc"],
    "crypto":    ["crypto", "ethereum", "token", "blockchain", "stablecoin"],
    "spacex":    ["spacex", "starship"],
    "sanctions": ["sanction", "embargo", "tariff"],
}

# Some feeds reject the default Python user-agent; present a browser-like one.
USER_AGENT = ("Mozilla/5.0 (compatible; WorldMonitor/1.0; "
              "+https://github.com/medo-labs/world-monitor)")

CSV_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "news_data"
)
CSV_FIELDS = ["captured_utc", "published_utc", "source", "category",
              "tags", "headline", "summary", "url", "dedup_hash"]


def _strip_html(s):
    s = re.sub(r"<[^>]+>", "", s or "")
    return re.sub(r"\s+", " ", s).strip()


def _to_utc_iso(entry):
    """feedparser already parses dates to a UTC struct_time when it can."""
    t = entry.get("published_parsed") or entry.get("updated_parsed")
    if t:
        return datetime(*t[:6], tzinfo=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return ""  # keep empty rather than invent a timestamp


# Short stems that would over-match as substrings (e.g. "war" inside "warm",
# "warning", "toward") are matched as whole words; everything else matches at a
# word start so plurals/inflections still hit ("sanction" -> "sanctions").
_EXACT_WORD = {"war"}
_TAG_PATTERNS = {
    tag: re.compile(
        "|".join(
            r"\b" + re.escape(k) + (r"\b" if k in _EXACT_WORD else "")
            for k in kws
        ),
        re.IGNORECASE,
    )
    for tag, kws in TAG_KEYWORDS.items()
}


def _tags_for(text):
    return "|".join(tag for tag, rx in _TAG_PATTERNS.items() if rx.search(text))


def _dedup_hash(source, link, title):
    return hashlib.sha1(
        f"{source}|{link}|{title}".encode("utf-8")
    ).hexdigest()[:16]


def _csv_path(now):
    return os.path.join(CSV_DIR, f"news_{now.strftime('%Y-%m')}.csv")


def _load_seen(path):
    seen = set()
    if os.path.exists(path):
        with open(path, newline="", encoding="utf-8") as f:
            for row in csv.DictReader(f):
                seen.add(row["dedup_hash"])
    return seen


def run():
    os.makedirs(CSV_DIR, exist_ok=True)
    now = datetime.now(timezone.utc)
    path = _csv_path(now)
    seen = _load_seen(path)
    new_file = not os.path.exists(path)
    captured = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    total_new = 0

    with open(path, "a", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=CSV_FIELDS)
        if new_file:
            writer.writeheader()

        for source, category, url in FEEDS:
            try:
                feed = feedparser.parse(url, agent=USER_AGENT)
            except Exception as e:
                print(f"[news] {source}: fetch error {e}", file=sys.stderr)
                continue
            if getattr(feed, "bozo", 0) and not feed.entries:
                print(f"[news] {source}: parse issue / no entries",
                      file=sys.stderr)
                continue

            n = 0
            for entry in feed.entries:
                title = (entry.get("title") or "").strip()
                link = (entry.get("link") or "").strip()
                if not title:
                    continue
                h = _dedup_hash(source, link, title)
                if h in seen:
                    continue
                seen.add(h)
                summary = _strip_html(entry.get("summary") or "")
                tags = _tags_for(title + " " + summary)
                writer.writerow({
                    "captured_utc": captured,
                    "published_utc": _to_utc_iso(entry),
                    "source": source,
                    "category": category,
                    "tags": tags,
                    "headline": title,
                    "summary": summary[:500],
                    "url": link,
                    "dedup_hash": h,
                })
                n += 1
            total_new += n
            print(f"[news] {source}: +{n} new (of {len(feed.entries)} in feed)")

    print(f"[news] wrote {total_new} new rows -> {path}")


if __name__ == "__main__":
    run()
WMNEWS_EOF
echo "[news-setup] collectors/news.py written"

# 2. add feedparser to requirements (once) and install it into the venv
grep -q '^feedparser' requirements.txt || echo 'feedparser>=6.0' >> requirements.txt
./venv/bin/pip install -q feedparser || ./venv/bin/pip install feedparser
echo "[news-setup] feedparser installed"

# 3. wire into run_once.sh (once), right after the markets sweep
if grep -q 'collectors.news' run_once.sh; then
  echo "[news-setup] run_once.sh already wired"
else
  sed -i '/collectors.markets all/a $PY -m collectors.news      || true' run_once.sh
  echo "[news-setup] run_once.sh updated"
fi

echo ""
echo "=== news capture installed. sweep now runs: ==="
grep -E 'collectors\.|alert_engine|breadth' run_once.sh
