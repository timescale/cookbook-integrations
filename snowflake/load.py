"""
load.py — Fetch the full NYC Film Permits dataset and load it into Tiger Cloud.

What it does:
    Pages through the NYC Open Data Socrata API (16k+ rows as of writing),
    parses each record, and bulk-inserts into the film_permits hypertable.
    Idempotent — re-running skips rows that already exist via ON CONFLICT.

Usage:
    pip install -r requirements.txt    # or: uv pip install -r requirements.txt
    cp .env.example .env               # then edit .env with your TIGER_SERVICE_URL
    python load.py

Configurable env vars (set in .env):
    TIGER_SERVICE_URL    Postgres connection string for your Tiger Cloud service
                         e.g. postgres://tsdbadmin:PASSWORD@HOST:PORT/tsdb?sslmode=require
    PAGE_SIZE            Rows per API request (default 5000, max 50000)
    NYC_APP_TOKEN        Optional Socrata app token for higher rate limits
                         (get one at https://data.cityofnewyork.us/profile/app_tokens)
"""

import os
import sys
from datetime import datetime
from typing import Iterator, Optional

import psycopg
import requests
from dotenv import load_dotenv

load_dotenv()

DATASET_ID = "tg4x-b46p"
API_URL = f"https://data.cityofnewyork.us/resource/{DATASET_ID}.json"

TIGER_SERVICE_URL = os.getenv("TIGER_SERVICE_URL")
PAGE_SIZE = int(os.getenv("PAGE_SIZE", "5000"))
NYC_APP_TOKEN = os.getenv("NYC_APP_TOKEN")


def parse_ts(value: Optional[str]) -> Optional[datetime]:
    if not value:
        return None
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def fetch_pages() -> Iterator[list[dict]]:
    headers = {"X-App-Token": NYC_APP_TOKEN} if NYC_APP_TOKEN else {}
    offset = 0
    while True:
        params = {"$limit": PAGE_SIZE, "$offset": offset, "$order": "enddatetime"}
        print(f"  fetching rows {offset:,}–{offset + PAGE_SIZE:,}...")
        resp = requests.get(API_URL, params=params, headers=headers, timeout=60)
        resp.raise_for_status()
        rows = resp.json()
        if not rows:
            return
        yield rows
        if len(rows) < PAGE_SIZE:
            return
        offset += PAGE_SIZE


def to_record(row: dict) -> Optional[tuple]:
    enddt = parse_ts(row.get("enddatetime"))
    eventid = row.get("eventid")
    if enddt is None or eventid is None:
        return None
    return (
        int(eventid),
        enddt,
        parse_ts(row.get("startdatetime")),
        parse_ts(row.get("enteredon")),
        row.get("eventtype"),
        row.get("eventagency"),
        row.get("parkingheld"),
        row.get("borough"),
        row.get("communityboard_s"),
        row.get("policeprecinct_s"),
        row.get("category"),
        row.get("subcategoryname"),
        row.get("country"),
        row.get("zipcode_s"),
    )


INSERT_SQL = """
INSERT INTO film_permits (
    eventid, enddatetime, startdatetime, enteredon, eventtype, eventagency,
    parkingheld, borough, communityboard_s, policeprecinct_s,
    category, subcategoryname, country, zipcode_s
) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
ON CONFLICT (eventid, enddatetime) DO NOTHING
"""


def main() -> int:
    if not TIGER_SERVICE_URL:
        print("ERROR: TIGER_SERVICE_URL is not set.")
        print("  Copy .env.example to .env and fill in your Tiger Cloud connection string.")
        print("  Find it in Tiger Cloud Console → your service → Connection info.")
        return 1

    print(f"Connecting to Tiger Cloud...")
    total_inserted = 0
    total_seen = 0

    with psycopg.connect(TIGER_SERVICE_URL) as conn:
        with conn.cursor() as cur:
            for page in fetch_pages():
                records = [r for r in (to_record(row) for row in page) if r is not None]
                total_seen += len(page)
                if not records:
                    continue
                cur.executemany(INSERT_SQL, records)
                total_inserted += cur.rowcount if cur.rowcount > 0 else 0
                conn.commit()

    print(f"\nDone! Saw {total_seen:,} API rows, inserted {total_inserted:,} new rows.")
    print("(Existing rows were skipped — re-run anytime to pick up new permits.)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
