#!/usr/bin/env python3
"""Provider/node telemetry for golem-vless — autonomous 24/7 observation.

Records a durable, append-only event journal so provider quality can be
measured over months: which nodes stay alive longest, which countries are
most stable, how the pool churns, and (once several providers are present)
which provider to prefer.

Data model
----------
Events live under ``<state>/stats/events-YYYY-MM.jsonl`` (one JSON object
per line, one file per month). A ``nodes.json`` snapshot keeps the last-seen
node fingerprint set so birth/death events can be emitted on each run.

Event types (``type`` field):
  render      — config was built; active node + pool size + counts
  probe_tcp   — per-node TCP latency from a parallel connect probe
  probe_http  — per-node Anthropic/YouTube verdict (B-010)
  seen        — node present in the subscription at this run
  born        — node first appeared in the pool
  died        — node stopped appearing
  selection   — which node the running client is using right now

A node's identity is the render_config fingerprint (sha256 of
server:port:transport, first 20 hex) — stable across subscription refreshes
even when the provider renames the node.

CLI
---
  stats.py collect [--light] ...   run a collection cycle (30-min task)
  stats.py report [--months N] ... print summary tables
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# Names carry Cyrillic/emoji; Windows cp1251 would crash on the first line.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

STATE_DIR_DEFAULT = Path("/var/lib/golem-vless")
LIGHT_INTERVAL_SECONDS = 30 * 60


# ── journal helpers ───────────────────────────────────────────────────────────

def _stats_dir(state_dir: Path) -> Path:
    return state_dir / "stats"


def _events_path(state_dir: Path, ts: float | None = None) -> Path:
    now = datetime.now(timezone.utc) if ts is None else datetime.fromtimestamp(ts, timezone.utc)
    return _stats_dir(state_dir) / f"events-{now:%Y-%m}.jsonl"


def _snapshot_path(state_dir: Path) -> Path:
    return _stats_dir(state_dir) / "nodes.json"


def _append(state_dir: Path, evt: dict[str, Any]) -> None:
    dir = _stats_dir(state_dir)
    dir.mkdir(parents=True, exist_ok=True)
    with _events_path(state_dir).open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(evt, ensure_ascii=False, default=str) + "\n")


def iter_events(state_dir: Path) -> list[dict[str, Any]]:
    """All journal events, oldest first."""
    out: list[dict[str, Any]] = []
    for path in sorted(_stats_dir(state_dir).glob("events-*.jsonl")):
        try:
            for line in path.read_text(encoding="utf-8").splitlines():
                if not line.strip():
                    continue
                try:
                    out.append(json.loads(line))
                except ValueError:
                    continue
        except OSError:
            continue
    out.sort(key=lambda e: e.get("ts", 0))
    return out


# ── node helpers ──────────────────────────────────────────────────────────────

def node_fingerprint(node: dict[str, Any]) -> str:
    """Stable node identity — mirrors render_config._node_fingerprint."""
    import hashlib

    ob = node.get("outbound", {})
    core = {
        "server": ob.get("server"),
        "server_port": ob.get("server_port"),
        "transport": ob.get("transport"),
    }
    return hashlib.sha256(
        json.dumps(core, sort_keys=True, default=str).encode("utf-8")
    ).hexdigest()[:20]


_EMOJI = re.compile(
    "["
    "\U0001F1E6-\U0001F1FF"
    "\U0001F300-\U0001F5FF"
    "\U0001F900-\U0001F9FF"
    "\U0001F600-\U0001F64F"
    "\U0001F680-\U0001F6FF"
    "\U00002600-\U000027BF"
    "\U0000FE0F"
    "\U00002B00-\U00002BFF"
    "]+"
)


def node_country(node: dict[str, Any]) -> str:
    """Best-effort country from the node's display name.

    Durev names look like "Albania 🔥", "Germany 52", "Russia → [Госуслуги]".
    We take the first alpha token; wrappers like "Auto → ..." become "Auto".
    """
    name = str((node.get("meta") or {}).get("name") or "")
    name = _EMOJI.sub(" ", name).strip()
    m = re.search(r"[A-Za-zА-Яа-яЁё]+", name)
    return m.group(0) if m else "?"


# ── birth/death tracking ──────────────────────────────────────────────────────

def _load_snapshot(state_dir: Path) -> dict[str, Any]:
    path = _snapshot_path(state_dir)
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def _save_snapshot(state_dir: Path, snapshot: dict[str, Any]) -> None:
    _stats_dir(state_dir).mkdir(parents=True, exist_ok=True)
    _snapshot_path(state_dir).write_text(
        json.dumps(snapshot, ensure_ascii=False, indent=1), encoding="utf-8"
    )


def _record_seen(state_dir: Path, nodes: list[dict[str, Any]], ts: float) -> None:
    """Append seen/born/died events by diffing against the last snapshot."""
    snap = _load_snapshot(state_dir)
    now_fps = set(snap.get("nodes", []))
    cur_fps: set[str] = set()
    for node in nodes:
        fp = node_fingerprint(node)
        cur_fps.add(fp)
        meta = node.get("meta") or {}
        _append(
            state_dir,
            {
                "ts": ts,
                "type": "seen",
                "fp": fp,
                "provider": meta.get("provider"),
                "name": meta.get("name"),
                "country": node_country(node),
                "server": meta.get("server"),
            },
        )
        if fp not in now_fps:
            _append(
                state_dir,
                {
                    "ts": ts,
                    "type": "born",
                    "fp": fp,
                    "provider": meta.get("provider"),
                    "name": meta.get("name"),
                },
            )
    for fp in now_fps - cur_fps:
        old = snap.get("nodes", {}).get(fp, {})
        _append(
            state_dir,
            {
                "ts": ts,
                "type": "died",
                "fp": fp,
                "provider": old.get("provider"),
                "name": old.get("name"),
            },
        )
    snap["nodes"] = {fp: {"name": next((str((n.get("meta") or {}).get("name") or "") for n in nodes if node_fingerprint(n) == fp), ""), "provider": next((n.get("meta", {}).get("provider") for n in nodes if node_fingerprint(n) == fp), None)} for fp in cur_fps}
    _save_snapshot(state_dir, snap)


# ── recording from a render ──────────────────────────────────────────────────

def record_render(
    state_dir: Path,
    *,
    nodes: list[dict[str, Any]],
    active: int,
    provider: str | None,
    probe: dict[int, int | None] | None = None,
    http_results: dict[int, tuple[int | None, int | None] | None] | None = None,
) -> None:
    """Record one config render: seen set, per-node probes, render summary."""
    ts = time.time()
    _record_seen(state_dir, nodes, ts)
    alive = 0
    for i, node in enumerate(nodes):
        fp = node_fingerprint(node)
        meta = node.get("meta") or {}
        lat = probe.get(i) if probe else None
        if lat is not None:
            alive += 1
        _append(
            state_dir,
            {
                "ts": ts,
                "type": "probe_tcp",
                "fp": fp,
                "provider": meta.get("provider"),
                "name": meta.get("name"),
                "country": node_country(node),
                "lat_ms": lat,
            },
        )
        if http_results:
            verdict = http_results.get(i)
            if verdict is not None:
                anth, yt = verdict
                _append(
                    state_dir,
                    {
                        "ts": ts,
                        "type": "probe_http",
                        "fp": fp,
                        "provider": meta.get("provider"),
                        "name": meta.get("name"),
                        "anthropic": anth,
                        "youtube": yt,
                        "passed": bool(anth is not None and yt is not None),
                    },
                )
    chosen = nodes[active - 1] if 0 < active <= len(nodes) else None
    _append(
        state_dir,
        {
            "ts": ts,
            "type": "render",
            "provider": provider,
            "node_count": len(nodes),
            "alive_count": alive,
            "active_index": active,
            "active_fp": node_fingerprint(chosen) if chosen else None,
            "active_name": (chosen.get("meta") or {}).get("name") if chosen else None,
        },
    )


def record_selection(
    state_dir: Path, *, fp: str | None, provider: str | None, name: str | None
) -> None:
    """Record which node the live client is currently using."""
    _append(
        state_dir,
        {
            "ts": time.time(),
            "type": "selection",
            "fp": fp,
            "provider": provider,
            "name": name,
        },
    )


# ── collection ────────────────────────────────────────────────────────────────

def _clash_now(api: str) -> str | None:
    """Current selected outbound tag from sing-box Clash API, if running."""
    try:
        with urllib.request.urlopen(f"{api}/proxies/proxy", timeout=3) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        return data.get("now")
    except (urllib.error.URLError, ValueError, OSError, KeyError):
        return None


def collect(
    state_dir: Path,
    endpoints: Path,
    *,
    light: bool = False,
    http_probe: bool = True,
    fetch: bool = False,
) -> int:
    """Run one collection cycle.

    Always: load the current node list, TCP-probe every node, record
    seen/born/died. In full mode (not --light) also run the B-010 HTTP probe.
    """
    import render_config

    nodes, active = render_config.load_endpoints(
        endpoints,
        fetch_subs=fetch,
        sub_cache=state_dir / "last-subscription.txt",
    )

    probe = render_config.probe_nodes(nodes, timeout=2.0, concurrency=16)
    alive = sum(1 for v in probe.values() if v is not None)
    print(f"TCP-probe: {alive}/{len(nodes)} alive", file=sys.stderr)

    http_results: dict[int, tuple[int | None, int | None] | None] | None = None
    if not light and http_probe:
        sing_box = render_config.find_sing_box()
        if sing_box is not None:
            cache = state_dir / "node-probe-cache.json"
            _passing, verdicts = render_config.probe_nodes_http(
                nodes,
                sing_box,
                xray=None,
                cache_path=cache,
            )
            http_results = verdicts
        else:
            print("WARN: sing-box not found — skipping HTTP probe", file=sys.stderr)

    record_render(
        state_dir,
        nodes=nodes,
        active=active,
        provider=(nodes[0].get("meta") or {}).get("provider") if nodes else None,
        probe=probe,
        http_results=http_results,
    )

    # If the client is up, log which node it actually selected right now.
    try:
        from render_config import DEFAULT_XRAY_PORT  # noqa: F401
    except ImportError:
        pass
    now = _clash_now("http://127.0.0.1:9090")
    if now:
        # Match the tag (e.g. "03 Germany") back to a node fingerprint.
        name = re.sub(r"^\d+\s+", "", now).strip()
        match = next(
            (n for n in nodes if str((n.get("meta") or {}).get("name") or "").strip() == name),
            None,
        )
        record_selection(
            state_dir,
            fp=node_fingerprint(match) if match else None,
            provider=(match.get("meta") or {}).get("provider") if match else None,
            name=name,
        )
        print(f"Clash API: client currently on '{now}'", file=sys.stderr)
    return 0


# ── reporting ─────────────────────────────────────────────────────────────────

def _fmt_ts(ts: float | None) -> str:
    if not ts:
        return "—"
    return datetime.fromtimestamp(ts).strftime("%d.%m %H:%M")


def _fmt_days(seconds: float | None) -> str:
    if seconds is None:
        return "—"
    if seconds < 0:
        return "0д"
    return f"{seconds / 86400:.0f}д"


def _pct(num: int, den: int) -> str:
    return f"{100.0 * num / den:.0f}%" if den else "—"


def report(state_dir: Path, months: int = 0) -> int:
    """Print summary tables: providers, node lifetime, countries, dynamics."""
    events = iter_events(state_dir)
    if not events:
        print("Нет данных. Сначала: stats.py collect", file=sys.stderr)
        return 1
    now = time.time()
    cutoff = now - months * 30 * 86400 if months > 0 else 0.0
    events = [e for e in events if e.get("ts", 0) >= cutoff] if cutoff else events

    # ── per-fingerprint aggregation ──────────────────────────────────────────
    seen_country: dict[str, str] = {
        e["fp"]: str(e.get("country") or "?")
        for e in events
        if e.get("type") == "seen" and e.get("fp")
    }
    nodes: dict[str, dict[str, Any]] = {}
    provider_totals: dict[str, dict[str, Any]] = {}
    for e in events:
        t = e.get("type")
        if t not in ("seen", "born", "died", "probe_tcp", "probe_http"):
            continue
        fp = e.get("fp")
        prov = e.get("provider") or "?"
        if prov not in provider_totals:
            provider_totals[prov] = {
                "nodes": set(), "born": 0, "died": 0,
                "tcp_samples": 0, "tcp_alive": 0, "lats": [],
            }
        pt = provider_totals[prov]
        if t == "seen" and fp:
            pt["nodes"].add(fp)
        if t == "born":
            pt["born"] += 1
        if t == "died":
            pt["died"] += 1
        if t == "probe_tcp" and fp:
            n = nodes.setdefault(
                fp,
                {
                    "fp": fp, "provider": prov, "name": e.get("name") or "",
                    "country": e.get("country") or seen_country.get(fp) or "?", "first": e.get("ts"),
                    "last": e.get("ts"), "lats": [], "tcp_samples": 0,
                    "tcp_alive": 0, "born_ts": None, "died_ts": None,
                    "alive_now": False,
                },
            )
            n["country"] = n["country"] or seen_country.get(fp) or "?"
            lat = e.get("lat_ms")
            if lat is not None:
                n["lats"].append(int(lat))
            n["tcp_samples"] += 1
            if lat is not None:
                n["tcp_alive"] += 1
            n["first"] = min(n["first"], e["ts"])
            n["last"] = max(n["last"], e["ts"])
            pt["tcp_samples"] += 1
            if lat is not None:
                pt["tcp_alive"] += 1
                pt["lats"].append(int(lat))
        if t == "born" and fp in nodes:
            nodes[fp]["born_ts"] = e.get("ts")
        if t == "died" and fp in nodes:
            nodes[fp]["died_ts"] = e.get("ts")
        if t == "seen" and fp in nodes:
            nodes[fp]["alive_now"] = e.get("ts", 0) >= now - LIGHT_INTERVAL_SECONDS * 2

    def _avg(lats: list[int]) -> str:
        return f"{sum(lats) / len(lats):.0f}мс" if lats else "—"

    def _latest_seen(fp: str) -> bool:
        n = nodes[fp]
        return n["alive_now"] or (n["died_ts"] is None and n["last"] >= now - 86400)

    # ── 1. providers ─────────────────────────────────────────────────────────
    print("\n═══ ПРОВАЙДЕРЫ ═══")
    print(
        f"{'провайдер':<12} {'нод':>4} {'живых':>5} {'доступн':>7} "
        f"{'ср.пинг':>7} {'родилось':>8} {'умерло':>6}"
    )
    for prov in sorted(provider_totals):
        pt = provider_totals[prov]
        cur_alive = sum(1 for fp in pt["nodes"] if _latest_seen(fp))
        print(
            f"{prov:<12} {len(pt['nodes']):>4} {cur_alive:>5} "
            f"{_pct(pt['tcp_alive'], pt['tcp_samples']):>7} "
            f"{_avg(pt['lats']):>7} {pt['born']:>8} {pt['died']:>6}"
        )

    # ── 2. node lifetime ─────────────────────────────────────────────────────
    print("\n═══ ВРЕМЯ ЖИЗНИ НОД (по времени в пуле) ═══")
    print(
        f"{'провайдер':<10} {'страна':<12} {'нода':<24} {'первое':>11} "
        f"{'последнее':>11} {'жизнь':>6} {'пинг':>7} {'статус':>6}"
    )
    rows = sorted(
        nodes.values(),
        key=lambda n: (n.get("died_ts") or now) - n["first"],
        reverse=True,
    )
    for n in rows[:40]:
        status = "жива" if _latest_seen(n["fp"]) else "умерла"
        life = (n.get("died_ts") or now) - n["first"] if not _latest_seen(n["fp"]) else now - n["first"]
        print(
            f"{(n['provider'] or '?'):<10} {(n['country'] or '?'):<12} "
            f"{(n['name'] or '')[:24]:<24} {_fmt_ts(n['first']):>11} "
            f"{_fmt_ts(n.get('died_ts') or n['last']):>11} "
            f"{_fmt_days(life):>6} {_avg(n['lats']):>7} {status:>6}"
        )

    # ── 3. countries ─────────────────────────────────────────────────────────
    print("\n═══ СТРАНЫ ═══")
    countries: dict[str, dict[str, Any]] = {}
    for n in nodes.values():
        c = countries.setdefault(
            n["country"], {"count": 0, "lats": [], "alive": 0}
        )
        c["count"] += 1
        c["lats"].extend(n["lats"])
        if _latest_seen(n["fp"]):
            c["alive"] += 1
    print(f"{'страна':<16} {'нод':>4} {'живых':>5} {'ср.пинг':>7}")
    for c in sorted(countries, key=lambda x: (-countries[x]["count"])):
        d = countries[c]
        print(f"{c:<16} {d['count']:>4} {d['alive']:>5} {_avg(d['lats']):>7}")

    # ── 4. monthly dynamics ──────────────────────────────────────────────────
    print("\n═══ ДИНАМИКА ПО МЕСЯЦАМ ═══")
    months_map: dict[str, dict[str, Any]] = {}
    for e in events:
        if e.get("type") not in ("seen", "born", "died"):
            continue
        m = datetime.fromtimestamp(e["ts"]).strftime("%Y-%m")
        d = months_map.setdefault(m, {"seen": set(), "born": 0, "died": 0})
        if e["type"] == "seen" and e.get("fp"):
            d["seen"].add(e["fp"])
        elif e["type"] == "born":
            d["born"] += 1
        elif e["type"] == "died":
            d["died"] += 1
    print(f"{'месяц':<9} {'нод в конце':>11} {'родилось':>8} {'умерло':>6}")
    for m in sorted(months_map):
        d = months_map[m]
        print(
            f"{m:<9} {len(d['seen']):>11} {d['born']:>8} {d['died']:>6}"
        )

    # ── 5. current selection ─────────────────────────────────────────────────
    sel = [e for e in events if e.get("type") == "selection"]
    if sel:
        last = sel[-1]
        print(
            f"\nТекущий выбор клиента: {last.get('name') or '—'} "
            f"({last.get('provider') or '—'}) [{_fmt_ts(last.get('ts'))}]"
        )
    return 0


# ── CLI ───────────────────────────────────────────────────────────────────────

def main() -> int:
    ap = argparse.ArgumentParser(description="Golem VLESS telemetry")
    sub = ap.add_subparsers(dest="cmd", required=True)

    pc = sub.add_parser("collect", help="run a collection cycle")
    pc.add_argument("--endpoints", type=Path, default=None, help="endpoints.txt")
    pc.add_argument("--state-dir", type=Path, default=STATE_DIR_DEFAULT, help="state dir")
    pc.add_argument(
        "--light",
        action="store_true",
        help="TCP probe only, skip the expensive B-010 HTTP probe",
    )
    pc.add_argument("--no-http", action="store_true", help="alias for --light")
    pc.add_argument(
        "--fetch",
        action="store_true",
        help="Fetch https subscription URLs in endpoints.txt",
    )
    pc.set_defaults(func=cmd_collect)

    pr = sub.add_parser("report", help="print summary tables")
    pr.add_argument("--state-dir", type=Path, default=STATE_DIR_DEFAULT, help="state dir")
    pr.add_argument(
        "--months", type=int, default=0, help="only look back N months (0 = all)"
    )
    pr.set_defaults(func=cmd_report)

    args = ap.parse_args()
    return args.func(args)


def cmd_collect(args: argparse.Namespace) -> int:
    endpoints = args.endpoints or (args.state_dir.parent / "endpoints.txt")
    light = args.light or args.no_http
    return collect(
        args.state_dir,
        endpoints,
        light=light,
        http_probe=not light,
        fetch=args.fetch,
    )


def cmd_report(args: argparse.Namespace) -> int:
    return report(args.state_dir, months=args.months)


if __name__ == "__main__":
    raise SystemExit(main())
