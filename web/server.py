#!/usr/bin/env python3
"""Minimal static + JSON API server for the repo-scanner health dashboard.

Reads the report artifacts that scan.sh already writes into REPORT_DIR
(reports/YYYY-MM-DD.findings.json, .state.json, .webhook.json) and the
configured repo list, and serves a tiny dashboard over them. No external
dependencies — stdlib only.
"""

import argparse
import base64
import datetime
import glob
import hmac
import json
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
APP_ROOT = os.path.dirname(SCRIPT_DIR)
PUBLIC_DIR = os.path.join(SCRIPT_DIR, "public")

CONTENT_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".json": "application/json; charset=utf-8",
}


def list_repos():
    script = (
        'source lib/repos.sh; '
        'read_repos repos.txt; '
        'for r in "${REPOS[@]}"; do repo_display_name "$r"; done'
    )
    try:
        result = subprocess.run(
            ["bash", "-c", script],
            cwd=APP_ROOT,
            capture_output=True,
            text=True,
            timeout=10,
            check=True,
        )
    except (subprocess.CalledProcessError, OSError, subprocess.TimeoutExpired):
        return []
    return [line for line in result.stdout.splitlines() if line.strip()]


def all_dates_desc(report_dir):
    """All scan dates that have a state.json, most recent first."""
    state_files = sorted(glob.glob(os.path.join(report_dir, "*.state.json")), reverse=True)
    return [os.path.basename(f)[: len("YYYY-MM-DD")] for f in state_files]


def latest_date_str(report_dir):
    dates = all_dates_desc(report_dir)
    return dates[0] if dates else None


def last_scan_timestamp(report_dir):
    """ISO 8601 UTC timestamp of the most recent scan, taken from the mtime of
    the latest state.json (already written by scan.sh every run — no new
    write needed, just reading an existing file's filesystem timestamp)."""
    date_str = latest_date_str(report_dir)
    if date_str is None:
        return None

    path = os.path.join(report_dir, f"{date_str}.state.json")
    try:
        mtime = os.path.getmtime(path)
    except OSError:
        return None

    return datetime.datetime.fromtimestamp(mtime, tz=datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_json(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


def empty_summary():
    return {"critical": 0, "high": 0, "moderate": 0, "low": 0, "unknown": 0}


def repo_health_for_date(report_dir, repo, date_str, include_findings=False):
    """Health snapshot for one repo on one specific scan date, or None if that
    date has no record for the repo at all."""
    if date_str is None:
        return None

    state = load_json(os.path.join(report_dir, f"{date_str}.state.json")) or []
    all_findings = load_json(os.path.join(report_dir, f"{date_str}.findings.json")) or []

    repo_state = next((s for s in state if s.get("repo") == repo), None)
    if repo_state is None:
        return None

    repo_findings = [f for f in all_findings if f.get("repo") == repo]

    summary = empty_summary()
    for finding in repo_findings:
        severity = finding.get("severity", "unknown")
        if severity not in summary:
            severity = "unknown"
        summary[severity] += 1

    health = {
        "repo": repo,
        "date": date_str,
        "status": repo_state.get("status", "unknown"),
        "manifests": repo_state.get("manifests", []),
        "summary": summary,
        "error": repo_state.get("error"),
    }
    if include_findings:
        health["findings"] = repo_findings
    return health


def unknown_health(repo, date_str=None, include_findings=False):
    health = {
        "repo": repo,
        "date": date_str,
        "status": "unknown",
        "manifests": [],
        "summary": empty_summary(),
        "error": None,
    }
    if include_findings:
        health["findings"] = []
    return health


def repo_health(report_dir, repo):
    date_str = latest_date_str(report_dir)
    return repo_health_for_date(report_dir, repo, date_str, include_findings=True) or unknown_health(
        repo, date_str, include_findings=True
    )


def webhook_status(report_dir):
    date_str = latest_date_str(report_dir)
    if date_str is None:
        return {"status": "not_configured", "checked_at": None}

    record = load_json(os.path.join(report_dir, f"{date_str}.webhook.json"))
    if record is None:
        return {"status": "not_configured", "checked_at": None}

    return {
        "status": "online" if record.get("success") else "down",
        "checked_at": record.get("checked_at"),
    }


def build_overview(report_dir):
    repos = list_repos()
    repo_healths = [repo_health(report_dir, repo) for repo in repos]
    clean_count = sum(1 for h in repo_healths if h["status"] == "clean")
    total = len(repos)

    return {
        "stats": {
            "total_repos": total,
            "clean_count": clean_count,
            "clearance_rate": (clean_count / total) if total else None,
            "webhook": webhook_status(report_dir),
            "last_scan_date": latest_date_str(report_dir),
            "last_scan_at": last_scan_timestamp(report_dir),
        },
        "repos": repo_healths,
    }


def build_runs(report_dir, repo, limit):
    runs = []
    for date_str in all_dates_desc(report_dir):
        if len(runs) >= limit:
            break
        health = repo_health_for_date(report_dir, repo, date_str)
        if health is not None:
            runs.append(health)

    return {"repo": repo, "runs": runs}


def scan_is_running(report_dir):
    """Non-blocking probe of scan.sh's flock lock (reports/.scan.lock). If the
    lock can be acquired and immediately released, no scan is in progress."""
    lock_path = os.path.join(report_dir, ".scan.lock")
    try:
        result = subprocess.run(
            ["flock", "-n", lock_path, "-c", "true"],
            capture_output=True,
            timeout=5,
        )
        return result.returncode != 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def trigger_scan():
    """Spawns scan.sh in the background and returns immediately. scan.sh's
    own flock guards against overlapping runs (including the scheduled loop
    in entrypoint.sh), so this never blocks waiting for a prior scan."""
    scan_script = os.path.join(APP_ROOT, "scan.sh")
    subprocess.Popen(
        ["bash", scan_script],
        cwd=APP_ROOT,
        stdout=sys.stdout,
        stderr=sys.stderr,
        start_new_session=True,
    )


def auth_configured():
    return bool(os.environ.get("DASHBOARD_USER")) and bool(os.environ.get("DASHBOARD_PASSWORD"))


def check_auth(authorization_header):
    """Constant-time check of an HTTP Basic Authorization header against
    DASHBOARD_USER/DASHBOARD_PASSWORD. Returns True if auth isn't configured
    (login is opt-in) or if the credentials match."""
    expected_user = os.environ.get("DASHBOARD_USER")
    expected_password = os.environ.get("DASHBOARD_PASSWORD")
    if not expected_user or not expected_password:
        return True

    if not authorization_header or not authorization_header.startswith("Basic "):
        return False

    try:
        decoded = base64.b64decode(authorization_header[len("Basic "):]).decode("utf-8")
        given_user, _, given_password = decoded.partition(":")
    except (ValueError, UnicodeDecodeError):
        return False

    return hmac.compare_digest(given_user, expected_user) and hmac.compare_digest(
        given_password, expected_password
    )


class Handler(BaseHTTPRequestHandler):
    report_dir = None  # set via make_handler

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _send_unauthorized(self):
        body = b"Authentication required"
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="Inspection Console"')
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_json(self, payload, status=200):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_static(self, rel_path):
        if rel_path in ("", "/"):
            rel_path = "index.html"
        rel_path = rel_path.lstrip("/")
        full_path = os.path.normpath(os.path.join(PUBLIC_DIR, rel_path))

        if os.path.commonpath([full_path, PUBLIC_DIR]) != PUBLIC_DIR or not os.path.isfile(full_path):
            self.send_response(404)
            self.end_headers()
            return

        ext = os.path.splitext(full_path)[1]
        content_type = CONTENT_TYPES.get(ext, "application/octet-stream")
        with open(full_path, "rb") as f:
            body = f.read()

        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if not check_auth(self.headers.get("Authorization")):
            self._send_unauthorized()
            return

        parsed = urlparse(self.path)

        if parsed.path == "/api/repos":
            self._send_json({"repos": list_repos()})
            return

        if parsed.path == "/api/overview":
            self._send_json(build_overview(self.report_dir))
            return

        if parsed.path == "/api/health":
            qs = parse_qs(parsed.query)
            repo = (qs.get("repo") or [""])[0]
            if not repo:
                self._send_json({"error": "missing 'repo' query parameter"}, status=400)
                return
            self._send_json(repo_health(self.report_dir, repo))
            return

        if parsed.path == "/api/runs":
            qs = parse_qs(parsed.query)
            repo = (qs.get("repo") or [""])[0]
            if not repo:
                self._send_json({"error": "missing 'repo' query parameter"}, status=400)
                return
            try:
                limit = int((qs.get("limit") or ["10"])[0])
            except ValueError:
                limit = 10
            self._send_json(build_runs(self.report_dir, repo, limit))
            return

        if parsed.path == "/api/scan/status":
            self._send_json({"running": scan_is_running(self.report_dir)})
            return

        self._send_static(parsed.path)

    def do_POST(self):
        if not check_auth(self.headers.get("Authorization")):
            self._send_unauthorized()
            return

        parsed = urlparse(self.path)

        if parsed.path == "/api/scan":
            if scan_is_running(self.report_dir):
                self._send_json({"status": "already_running"}, status=409)
                return
            trigger_scan()
            self._send_json({"status": "started"}, status=202)
            return

        self.send_response(404)
        self.end_headers()


def make_handler(report_dir):
    return type("BoundHandler", (Handler,), {"report_dir": report_dir})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=int(os.environ.get("WEB_PORT", "8080")))
    parser.add_argument("--report-dir", default=os.environ.get("REPORT_DIR", os.path.join(APP_ROOT, "reports")))
    args = parser.parse_args()

    if not auth_configured():
        print(
            "WARNING: DASHBOARD_USER/DASHBOARD_PASSWORD not set — dashboard is running without authentication.",
            file=sys.stderr,
        )

    handler_cls = make_handler(os.path.abspath(args.report_dir))
    server = ThreadingHTTPServer(("0.0.0.0", args.port), handler_cls)
    print(f"Dashboard server listening on :{args.port} (report dir: {args.report_dir})")
    server.serve_forever()


if __name__ == "__main__":
    main()
