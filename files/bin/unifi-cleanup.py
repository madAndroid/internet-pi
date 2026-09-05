
#!/usr/bin/env python3
"""
UDM SE / UniFi OS: bulk forget historic clients last seen > N days.

- Login (UniFi OS):        POST /api/auth/login
- Network API base (OS):   /proxy/network/api
- List all clients:        GET  /proxy/network/api/s/<site>/stat/alluser
- Bulk forget:             POST /proxy/network/api/s/<site>/cmd/stamgr
                           Body: {"cmd":"forget-sta","macs":[ "...", ... ]}
"""

import time
import json
import sys
import csv
from typing import List, Dict, Any, Tuple
from urllib.parse import urljoin

import requests
from requests.packages.urllib3.exceptions import InsecureRequestWarning
requests.packages.urllib3.disable_warnings(InsecureRequestWarning)

# ==== USER CONFIG ====
CONTROLLER_URL = "https://udm.stangl.co.za"   # e.g., https://192.168.1.1
USERNAME = "hass"
import os
PASSWORD = os.getenv("UNIFI_PASSWORD")  # Use env var or vault; avoid hardcoding in production

SITE_NAME = 'default'       # Set to "default" or your site name; None = discover and process all sites found.
DAYS_THRESHOLD = 30

# Safety toggles
EXCLUDE_NAMED = False   # False = include named/hostname clients in deletion
EXCLUDE_FIXED_IP = True # True = keep clients with 'use_fixedip' reservations

# Execution toggles
DRY_RUN = False          # True = preview only; False = perform forgetting
BATCH_SIZE = 200
VERIFY_SSL = False      # False accepts self-signed certs (typical on UDM SE)
EXPORT_CSV = True       # True = write a CSV of candidates per site before deletion
CSV_PATH = "unifi-candidates.csv"


def login(session: requests.Session) -> None:
    """Authenticate to UniFi OS and capture CSRF token if present; set headers."""
    url = urljoin(CONTROLLER_URL, "/api/auth/login")
    payload = {"username": USERNAME, "password": PASSWORD, "remember": True}
    r = session.post(url, json=payload, verify=VERIFY_SSL, timeout=15)
    if r.status_code != 200:
        raise RuntimeError(f"Login failed: HTTP {r.status_code} {r.text}")

    # Capture CSRF token from header or cookie; set headers for subsequent requests
    csrf = r.headers.get("X-CSRF-Token") or r.headers.get("x-csrf-token")
    if not csrf:
        csrf = session.cookies.get("csrf_token")

    base_headers = {
        "Accept": "application/json",
        "Content-Type": "application/json",
        # Some UniFi OS builds check Referer for CSRF
        "Referer": urljoin(CONTROLLER_URL, "/"),
    }
    if csrf:
        base_headers["X-CSRF-Token"] = csrf

    session.headers.update(base_headers)


def list_sites(session: requests.Session) -> List[str]:
    """Return list of site names; restrict to SITE_NAME if provided."""
    url = urljoin(CONTROLLER_URL, "/proxy/network/api/self/sites")
    r = session.get(url, verify=VERIFY_SSL, timeout=15)
    if r.status_code != 200:
        raise RuntimeError(f"Site listing failed: HTTP {r.status_code} {r.text}")
    data = r.json().get("data", [])
    names = [s.get("name") for s in data if s.get("name")]
    if SITE_NAME:
        return [SITE_NAME]
    return names or ["default"]


def get_all_clients(session: requests.Session, site: str) -> List[Dict[str, Any]]:
    """Fetch historic + active clients for a site."""
    url = urljoin(CONTROLLER_URL, f"/proxy/network/api/s/{site}/stat/alluser")
    r = session.get(url, verify=VERIFY_SSL, timeout=30)
    if r.status_code != 200:
        raise RuntimeError(f"[{site}] Listing clients failed: HTTP {r.status_code} {r.text}")
    return r.json().get("data", [])


def normalize_last_seen(value) -> int:
    """
    Returns last_seen in seconds.
    - If milliseconds (>= 1e12), convert to seconds.
    - If None/invalid, return -1 (treated as old).
    """
    if value is None:
        return -1
    try:
        v = int(value)
    except Exception:
        return -1
    return v // 1000 if v > 10**12 else v


def human_last_seen(sec: int) -> str:
    if sec < 0:
        return "unknown"
    try:
        return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(sec))
    except Exception:
        return str(sec)


def filter_old_clients(
    clients: List[Dict[str, Any]],
    days_threshold: int,
    exclude_named: bool,
    exclude_fixed: bool
) -> Tuple[List[Dict[str, Any]], Dict[str, int]]:
    """Filter clients older than cutoff with diagnostics."""
    cutoff = int(time.time()) - days_threshold * 24 * 3600
    selected = []
    reasons = {
        "excluded_named": 0,
        "excluded_fixed_ip": 0,
        "excluded_recent": 0,
        "excluded_missing_mac": 0,
        "excluded_duplicate_mac": 0
    }

    seen_macs = set()
    for c in clients:
        mac = (c.get("mac") or "").lower()
        if not mac:
            reasons["excluded_missing_mac"] += 1
            continue

        last_seen = normalize_last_seen(c.get("last_seen"))
        if last_seen >= 0 and last_seen >= cutoff:
            reasons["excluded_recent"] += 1
            continue

        # Safety filters
        if exclude_named and (c.get("name") or c.get("hostname")):
            reasons["excluded_named"] += 1
            continue
        if exclude_fixed and c.get("use_fixedip"):
            reasons["excluded_fixed_ip"] += 1
            continue

        # De-duplicate by MAC
        if mac in seen_macs:
            reasons["excluded_duplicate_mac"] += 1
            continue
        seen_macs.add(mac)
        selected.append(c)

    return selected, reasons


def chunk(lst: List[str], n: int) -> List[List[str]]:
    return [lst[i:i + n] for i in range(0, len(lst), n)]


def export_candidates_to_csv(site: str, candidates: List[Dict[str, Any]], path: str) -> None:
    """Append candidate list to CSV (site, mac, hostname, name, fixed_ip, last_seen)."""
    if not candidates:
        return
    header = ["site", "mac", "hostname", "name", "fixed_ip", "last_seen_epoch", "last_seen_human"]
    try:
        # Append; create header only if file is empty
        write_header = False
        try:
            with open(path, "r"):
                pass
        except FileNotFoundError:
            write_header = True

        with open(path, "a", newline="") as f:
            w = csv.writer(f)
            if write_header:
                w.writerow(header)
            for c in candidates:
                ls = normalize_last_seen(c.get("last_seen"))
                w.writerow([
                    site,
                    c.get("mac"),
                    c.get("hostname"),
                    c.get("name"),
                    bool(c.get("use_fixedip")),
                    ls,
                    human_last_seen(ls),
                ])
        print(f"[{site}] Exported {len(candidates)} candidates to {path}")
    except Exception as e:
        print(f"[{site}] [WARN] CSV export failed: {e}")


def forget_clients(session: requests.Session, site: str, macs: List[str]) -> None:
    """
    Perform bulk forget in batches with CSRF-aware headers.
    Endpoint: POST /proxy/network/api/s/<site>/cmd/stamgr
    Body: {"cmd": "forget-sta", "macs": [ "...", ... ]}
    """
    if not macs:
        print(f"[{site}] Nothing to forget.")
        return

    url = urljoin(CONTROLLER_URL, f"/proxy/network/api/s/{site}/cmd/stamgr")
    total = 0
    for group in chunk(macs, BATCH_SIZE):
        payload = {"cmd": "forget-sta", "macs": group}
        try:
            r = session.post(url, json=payload, verify=VERIFY_SSL, timeout=45)
        except requests.exceptions.RequestException as e:
            print(f"[{site}] [WARN] Batch network error: {e}")
            continue

        if r.status_code != 200:
            print(f"[{site}] [WARN] Batch failed: HTTP {r.status_code} {r.text}")
            # If forbidden, advise running on-box
            if r.status_code == 403:
                print(f"[{site}] [HINT] 403 Forbidden: If this persists, run the script ON the UDM SE via SSH; "
                      f"some UniFi OS builds restrict write endpoints to localhost.")
            continue

        # Optional: check meta rc
        try:
            resp = r.json()
            meta_rc = (resp.get("meta") or {}).get("rc")
            if meta_rc and meta_rc != "ok":
                print(f"[{site}] [WARN] Batch returned non-ok meta: {resp}")
            else:
                print(f"[{site}] [OK] Forgot {len(group)} clients")
        except ValueError:
            # Non-JSON response; assume success if 200
            print(f"[{site}] [OK] Forgot {len(group)} clients (no JSON meta)")
        total += len(group)

    print(f"[{site}] Total forgotten attempted: {total}")


def run_for_site(session: requests.Session, site: str) -> None:
    print(f"\n=== Site: {site} ===")
    clients = get_all_clients(session, site)
    print(f"[{site}] Total clients (historic + active): {len(clients)}")

    targets, reasons = filter_old_clients(
        clients,
        DAYS_THRESHOLD,
        EXCLUDE_NAMED,
        EXCLUDE_FIXED_IP
    )
    macs = [c["mac"].lower() for c in targets]
    print(f"[{site}] Candidates to forget (> {DAYS_THRESHOLD} days): {len(macs)}")
    print(f"[{site}] Exclusion breakdown: {json.dumps(reasons, indent=2)}")

    # Preview
    preview = [
        {
            "mac": c["mac"],
            "hostname": c.get("hostname"),
            "name": c.get("name"),
            "fixed_ip": bool(c.get("use_fixedip")),
            "last_seen": human_last_seen(normalize_last_seen(c.get("last_seen"))),
        }
        for c in targets[:25]
    ]
    print(f"[{site}] Preview (first 25):")
    print(json.dumps(preview, indent=2))

    # CSV archive of candidates (before deletion)
    if EXPORT_CSV:
        export_candidates_to_csv(site, targets, CSV_PATH)

    if DRY_RUN:
        print(f"[{site}] [DRY RUN] No changes made.")
        return

    print(f"[{site}] Forgetting clients in batches…")
    forget_clients(session, site, macs)


def main():
    session = requests.Session()
    # Basic headers will be extended in login() with CSRF + Referer
    session.headers.update({"Accept": "application/json", "Content-Type": "application/json"})

    print("Logging in to UniFi OS…")
    login(session)

    sites = list_sites(session)
    print(f"Sites to process: {sites}")

    for site in sites:
       run_for_site(session, site)

    print("\nAll done.")

if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"[ERROR] {e}")
