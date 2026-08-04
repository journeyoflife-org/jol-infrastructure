#!/usr/bin/env python3
# Ollama metrics exporter — llm-prod-lt01
#
# Polls the local Ollama runtime (/api/ps, /api/tags, /api/version) and the
# FastAPI auth bridge (/healthz) every POLL_INTERVAL seconds, and serves a
# Prometheus text-format exposition on 127.0.0.1:9101. Stdlib only — no
# third-party dependencies, so it survives air-gap deployments untouched.
#
# Deployed by infra/playbooks/05-monitoring.yml to
# /opt/jol/monitoring/ollama-metrics.py (systemd unit: ollama-exporter).
# Netdata ingests this endpoint via its prometheus plugin; alert thresholds
# live in monitoring/netdata/health.d/ollama.conf.
#
# Bridge /healthz contract (JSON, served by ollama-api-bridge):
#   {
#     "status": "ok",
#     "queue_depth": 0,              # requests waiting for an inference slot
#     "tokens_per_second": 1.42,     # rolling aggregate of recent streams
#     "requests_5xx_total": 3,       # counter since bridge start
#     "uptime_seconds": 81234
#   }
# Missing fields degrade to 0; bridge unreachable sets ollama_bridge_up 0.
#
# Compliance note: this exporter collects runtime telemetry only. It never
# sees, stores, or logs prompt or completion content (0-day retention policy,
# security/policies/data-retention-policy.md).

import json
import os
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

OLLAMA_URL = os.environ.get("OLLAMA_METRICS_OLLAMA_URL", "http://127.0.0.1:11434")
BRIDGE_URL = os.environ.get("OLLAMA_METRICS_BRIDGE_URL", "http://127.0.0.1:8901")
LISTEN_HOST = os.environ.get("OLLAMA_METRICS_LISTEN_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("OLLAMA_METRICS_LISTEN_PORT", "9101"))
POLL_INTERVAL = int(os.environ.get("OLLAMA_METRICS_POLL_INTERVAL", "10"))
HTTP_TIMEOUT = 5  # seconds; both endpoints are loopback-local

PRIMARY_MODEL = os.environ.get("OLLAMA_METRICS_PRIMARY_MODEL", "qwen3-32b-q8_0")


def fetch_json(url: str):
    """GET a JSON endpoint; return parsed dict or None on any failure."""
    try:
        req = urllib.request.Request(url, headers={"Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            return json.loads(resp.read().decode("utf-8", "replace"))
    except Exception:
        return None


class Snapshot:
    """Immutable-ish snapshot of the last poll, rendered on each scrape."""

    def __init__(self):
        self.lock = threading.Lock()
        self.ollama_up = 0
        self.ollama_version = "unknown"
        self.models_installed = 0
        self.resident = {}          # model name -> {size, vram, ...}
        self.bridge_up = 0
        self.queue_depth = 0.0
        self.tokens_per_second = 0.0
        self.requests_5xx_total = 0.0
        self.poll_ts = 0.0
        self.poll_errors = 0

    def refresh(self):
        version_doc = fetch_json(f"{OLLAMA_URL}/api/version")
        tags_doc = fetch_json(f"{OLLAMA_URL}/api/tags")
        ps_doc = fetch_json(f"{OLLAMA_URL}/api/ps")
        bridge_doc = fetch_json(f"{BRIDGE_URL}/healthz")

        with self.lock:
            self.ollama_up = 1 if version_doc is not None else 0
            if version_doc:
                self.ollama_version = str(version_doc.get("version", "unknown"))
            self.models_installed = (
                len(tags_doc.get("models", [])) if tags_doc else 0
            )
            self.resident = {}
            if ps_doc:
                for m in ps_doc.get("models", []):
                    self.resident[str(m.get("name", "unknown"))] = {
                        "size": float(m.get("size", 0) or 0),
                        "vram": float(m.get("size_vram", 0) or 0),
                        "expires": str(m.get("expires", "")),
                    }
            if bridge_doc:
                self.bridge_up = 1
                self.queue_depth = float(bridge_doc.get("queue_depth", 0) or 0)
                self.tokens_per_second = float(
                    bridge_doc.get("tokens_per_second", 0) or 0
                )
                self.requests_5xx_total = float(
                    bridge_doc.get("requests_5xx_total", 0) or 0
                )
            else:
                self.bridge_up = 0
            self.poll_ts = time.time()
            self.poll_errors += (version_doc is None) + (bridge_doc is None)


SNAPSHOT = Snapshot()


def render_metrics(snap: Snapshot) -> str:
    """Render the current snapshot in Prometheus text exposition format."""
    lines = []
    add = lines.append
    with snap.lock:
        add("# HELP ollama_up 1 if the Ollama runtime answered the last poll.")
        add("# TYPE ollama_up gauge")
        add(f"ollama_up {snap.ollama_up}")

        add("# HELP ollama_version_info Version label of the running Ollama.")
        add("# TYPE ollama_version_info gauge")
        ver = snap.ollama_version.replace('"', "")
        add(f'ollama_version_info{{version="{ver}"}} 1')

        add("# HELP ollama_models_installed Models present in the local registry.")
        add("# TYPE ollama_models_installed gauge")
        add(f"ollama_models_installed {snap.models_installed}")

        add("# HELP ollama_model_resident 1 if the named model is loaded in RAM.")
        add("# TYPE ollama_model_resident gauge")
        if snap.resident:
            for name in sorted(snap.resident):
                add(f'ollama_model_resident{{model="{name}"}} 1')
        # Primary-model gauge must always exist so health.d alerts have data.
        if PRIMARY_MODEL not in snap.resident:
            add(f'ollama_model_resident{{model="{PRIMARY_MODEL}"}} 0')

        add("# HELP ollama_model_size_bytes RAM footprint of a resident model.")
        add("# TYPE ollama_model_size_bytes gauge")
        for name, m in sorted(snap.resident.items()):
            add(f'ollama_model_size_bytes{{model="{name}"}} {m["size"]:.0f}')

        add("# HELP ollama_bridge_up 1 if the auth bridge /healthz answered.")
        add("# TYPE ollama_bridge_up gauge")
        add(f"ollama_bridge_up {snap.bridge_up}")

        add("# HELP ollama_bridge_queue_depth Requests queued at the bridge.")
        add("# TYPE ollama_bridge_queue_depth gauge")
        add(f"ollama_bridge_queue_depth {snap.queue_depth}")

        add("# HELP ollama_generate_tokens_per_second Rolling generation throughput.")
        add("# TYPE ollama_generate_tokens_per_second gauge")
        add(f"ollama_generate_tokens_per_second {snap.tokens_per_second}")

        add("# HELP ollama_bridge_requests_5xx_total 5xx responses since bridge start.")
        add("# TYPE ollama_bridge_requests_5xx_total counter")
        add(f"ollama_bridge_requests_5xx_total {snap.requests_5xx_total}")

        add("# HELP ollama_exporter_last_poll_timestamp_seconds Unix time of last poll.")
        add("# TYPE ollama_exporter_last_poll_timestamp_seconds gauge")
        add(f"ollama_exporter_last_poll_timestamp_seconds {snap.poll_ts:.3f}")

        add("# HELP ollama_exporter_poll_errors_total Failed upstream polls since start.")
        add("# TYPE ollama_exporter_poll_errors_total counter")
        add(f"ollama_exporter_poll_errors_total {snap.poll_errors}")
    add("")
    return "\n".join(lines)


class MetricsHandler(BaseHTTPRequestHandler):
    server_version = "jol-ollama-exporter/1.0"

    def do_GET(self):
        if self.path == "/healthz":
            body = b'{"status":"ok"}\n'
            ctype = "application/json"
        elif self.path in ("/", "/metrics"):
            body = render_metrics(SNAPSHOT).encode("utf-8")
            ctype = "text/plain; version=0.0.4; charset=utf-8"
        else:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):  # noqa: N802 — keep access log silent
        pass


def poll_loop():
    while True:
        SNAPSHOT.refresh()
        time.sleep(POLL_INTERVAL)


def main():
    threading.Thread(target=poll_loop, daemon=True, name="poller").start()
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), MetricsHandler)
    print(f"ollama-metrics exporter on {LISTEN_HOST}:{LISTEN_PORT}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
