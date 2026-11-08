"""
News digest — one Telegram message a day summarising the tagged headlines
captured in the last 24h, grouped by topic. Reads the CSV the news collector
writes; sends nothing live. Pairs with the price digest.
"""
import os
import csv
import sys
import glob
from datetime import datetime, timezone, timedelta

import config
import requests

NEWS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "news_data")

TOPIC_ORDER = [
    ("iran", "\U0001F6A8 Iran"),
    ("war", "\u2694\uFE0F War/Conflict"),
    ("military", "\u2694\uFE0F Military"),
    ("russia", "\U0001F1F7\U0001F1FA Russia"),
    ("china", "\U0001F1E8\U0001F1F3 China"),
    ("japan", "\U0001F1EF\U0001F1F5 Japan"),
    ("sanctions", "\U0001F6D1 Sanctions/Tariffs"),
    ("fed", "\U0001F4B5 Fed/Rates"),
    ("inflation", "\U0001F4C8 Inflation"),
    ("oil", "\U0001F6E2\uFE0F Oil"),
    ("fuel", "\u26FD Fuel"),
    ("bitcoin", "\u20BF Bitcoin"),
    ("crypto", "\U0001FA99 Crypto"),
    ("spacex", "\U0001F680 SpaceX"),
]
MAX_PER_TOPIC = 4


def send_telegram(text):
    if not config.TELEGRAM_TOKEN or not config.TELEGRAM_CHAT_ID:
        print("[news-digest] Telegram not configured", file=sys.stderr)
        return
    url = f"https://api.telegram.org/bot{config.TELEGRAM_TOKEN}/sendMessage"
    requests.post(url, data={"chat_id": config.TELEGRAM_CHAT_ID,
                             "text": text, "disable_web_page_preview": True},
                  timeout=30)


def _load_recent(hours=24):
    files = sorted(glob.glob(os.path.join(NEWS_DIR, "news_*.csv")))
    if not files:
        return []
    cutoff = datetime.now(timezone.utc) - timedelta(hours=hours)
    rows = []
    for path in files[-2:]:
        with open(path, newline="", encoding="utf-8") as f:
            for r in csv.DictReader(f):
                try:
                    cap = datetime.strptime(r["captured_utc"],
                                            "%Y-%m-%dT%H:%M:%SZ").replace(
                                                tzinfo=timezone.utc)
                except Exception:
                    continue
                if cap >= cutoff:
                    rows.append(r)
    return rows


def build_digest(rows):
    total = len(rows)
    tagged = [r for r in rows if r["tags"]]
    lines = [f"\U0001F30D NEWS DIGEST — last 24h",
             f"{total} captured, {len(tagged)} tagged", ""]

    shown = set()
    any_topic = False
    for tag, label in TOPIC_ORDER:
        hits = [r for r in tagged
                if tag in r["tags"].split("|") and r["dedup_hash"] not in shown]
        if not hits:
            continue
        any_topic = True
        lines.append(f"{label} ({len(hits)})")
        for r in hits[:MAX_PER_TOPIC]:
            lines.append(f" \u2022 {r['headline'][:90]}")
            shown.add(r["dedup_hash"])
        if len(hits) > MAX_PER_TOPIC:
            lines.append(f"   …+{len(hits) - MAX_PER_TOPIC} more")
        lines.append("")

    if not any_topic:
        lines.append("(no tagged headlines in the last 24h)")
    return "\n".join(lines).strip()


def run():
    rows = _load_recent(24)
    msg = build_digest(rows)
    send_telegram(msg)
    print(f"[news-digest] sent ({len(rows)} rows scanned)")


if __name__ == "__main__":
    run()
