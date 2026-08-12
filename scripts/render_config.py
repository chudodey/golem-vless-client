#!/usr/bin/env python3
"""Render a sing-box client config from provider-agnostic VLESS endpoints.

Reads:
  secrets/endpoints.txt   — vless:// URIs and/or https subscription URLs
  policy.conf             — what goes through the VPN, what doesn't (see file)

Writes:
  generated/config.json
  generated/outbounds.jsonl  — inventory of parsed nodes (no secrets dumped beyond host:port)
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any

# Node names routinely contain Cyrillic/emoji; the Windows console defaults to
# cp1251 and would crash the run on the first such name.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

ROOT = Path(__file__).resolve().parents[1]
SECRETS = ROOT / "secrets" / "endpoints.txt"
POLICY_PATH = ROOT / "policy.conf"
OUT_DIR = ROOT / "generated"
OUT_CONFIG = OUT_DIR / "config.json"

DEFAULT_MIXED_PORT = 1080
DEFAULT_TUN_ADDR = "172.19.0.1/30"
DEFAULT_TUN_NAME = "golem-tun"

POLICY_DEFAULTS = {
    "enabled": "yes",
    "interval": "5m",
    "candidates": "12",
    "tolerance": "50",
    "test_url": "https://www.gstatic.com/generate_204",
    # Optional temporary country lock (see _node_iso2 / main): comma list of
    # ISO alpha-2 (US, GB, DE...) or country names. Empty = no filter.
    "countries": "",
}


# ── country matching for the [auto-select] `countries` filter ────────────────
# Node names are provider-specific ("01 Austria 🇦🇹", "US 03 · Los Angeles",
# "🇺🇸 05 New York", "Россия → [Госуслуги]"). We derive a best-effort ISO
# alpha-2: exact flag emoji first, then name tokens against English/Russian
# names and common two-letter location codes. Unknown names yield None — under
# an active filter such a node is dropped with a warning (fail closed: during
# e.g. a card payment you do not want a misidentified exit to win).

_ISO2_BY_NAME = {
    "united states": "US", "usa": "US", "us": "US", "america": "US",
    "states": "US", "united states of america": "US",
    "united kingdom": "GB", "uk": "GB", "great britain": "GB",
    "britain": "GB", "england": "GB", "scotland": "GB", "wales": "GB",
    "northern ireland": "GB",
    "germany": "DE", "deutschland": "DE",
    "netherlands": "NL", "holland": "NL",
    "russia": "RU", "russian federation": "RU",
    "sweden": "SE", "norway": "NO", "denmark": "DK", "finland": "FI",
    "iceland": "IS", "estonia": "EE", "latvia": "LV", "lithuania": "LT",
    "poland": "PL", "czech republic": "CZ", "czechia": "CZ", "slovakia": "SK",
    "hungary": "HU", "romania": "RO", "bulgaria": "BG", "serbia": "RS",
    "croatia": "HR", "slovenia": "SI", "bosnia": "BA", "albania": "AL",
    "north macedonia": "MK", "macedonia": "MK", "greece": "GR",
    "turkey": "TR", "cyprus": "CY", "malta": "MT",
    "france": "FR", "italy": "IT", "spain": "ES", "portugal": "PT",
    "switzerland": "CH", "austria": "AT", "belgium": "BE", "ireland": "IE",
    "luxembourg": "LU",
    "canada": "CA", "australia": "AU", "new zealand": "NZ",
    "japan": "JP", "south korea": "KR", "korea": "KR", "singapore": "SG",
    "hong kong": "HK", "taiwan": "TW", "china": "CN", "india": "IN",
    "indonesia": "ID", "malaysia": "MY", "thailand": "TH", "vietnam": "VN",
    "philippines": "PH", "israel": "IL", "saudi arabia": "SA", "uae": "AE",
    "united arab emirates": "AE", "qatar": "QA",
    "kazakhstan": "KZ", "uzbekistan": "UZ", "georgia": "GE", "armenia": "AM",
    "azerbaijan": "AZ", "moldova": "MD", "belarus": "BY", "ukraine": "UA",
    "brazil": "BR", "argentina": "AR", "chile": "CL", "peru": "PE",
    "colombia": "CO", "mexico": "MX", "south africa": "ZA", "egypt": "EG",
    "nigeria": "NG", "kenya": "KE", "morocco": "MA",
}

_ISO2_BY_RU_NAME = {
    "сша": "US", "америка": "US", "штаты": "US", "соединенные штаты": "US",
    "соединённые штаты": "US",
    "великобритания": "GB", "англия": "GB", "британия": "GB",
    "германия": "DE",
    "нидерланды": "NL", "голландия": "NL",
    "россия": "RU",
    "швеция": "SE", "норвегия": "NO", "дания": "DK", "финляндия": "FI",
    "исландия": "IS", "эстония": "EE", "латвия": "LV", "литва": "LT",
    "польша": "PL", "чехия": "CZ", "словакия": "SK", "венгрия": "HU",
    "румыния": "RO", "болгария": "BG", "сербия": "RS", "хорватия": "HR",
    "словения": "SI", "греция": "GR", "турция": "TR", "кипр": "CY",
    "франция": "FR", "италия": "IT", "испания": "ES", "португалия": "PT",
    "швейцария": "CH", "австрия": "AT", "бельгия": "BE", "ирландия": "IE",
    "люксембург": "LU",
    "канада": "CA", "австралия": "AU", "новая зеландия": "NZ",
    "япония": "JP", "южная корея": "KR", "корея": "KR", "сингапур": "SG",
    "гонконг": "HK", "тайвань": "TW", "китай": "CN", "индия": "IN",
    "индонезия": "ID", "малайзия": "MY", "таиланд": "TH", "вьетнам": "VN",
    "филиппины": "PH", "израиль": "IL",
    "казахстан": "KZ", "узбекистан": "UZ", "грузия": "GE", "армения": "AM",
    "азербайджан": "AZ", "молдова": "MD", "беларусь": "BY", "украина": "UA",
    "бразилия": "BR", "аргентина": "AR", "чили": "CL", "перу": "PE",
    "колумбия": "CO", "мексика": "MX", "южная африка": "ZA", "египет": "EG",
}

# Common two-letter location prefixes in hostname-style names ("us01.foo",
# "de3.bar"); matched only when followed by a digit so "us" ≠ "usual".
_ISO2_HOST_PREFIX = {
    "us": "US", "gb": "GB", "uk": "GB", "de": "DE", "nl": "NL", "fr": "FR",
    "se": "SE", "fi": "FI", "no": "NO", "dk": "DK", "ee": "EE", "lv": "LV",
    "lt": "LT", "pl": "PL", "cz": "CZ", "at": "AT", "ch": "CH", "es": "ES",
    "it": "IT", "pt": "PT", "gr": "GR", "tr": "TR", "ca": "CA", "au": "AU",
    "jp": "JP", "kr": "KR", "sg": "SG", "hk": "HK", "tw": "TW", "ru": "RU",
    "ua": "UA", "kz": "KZ", "br": "BR", "mx": "MX", "ar": "AR", "in": "IN",
}

_EMOJI_STRIP_RE = re.compile(
    "["
    "\U0001F1E6-\U0001F1FF"  # regional indicator symbols (flag emoji)
    "\U0001F300-\U0001F5FF"
    "\U0001F600-\U0001F64F"
    "\U0001F680-\U0001F6FF"
    "\U00002600-\U000027BF"
    "\U0000FE0F"
    "\U00002B00-\U00002BFF"
    "]+"
)


def _flag_to_iso2(name: str) -> str | None:
    """ISO alpha-2 from a flag emoji (🇺🇸 → "US"); None if no flag present.

    Flag emoji are two regional-indicator letters; the letters map 1:1 onto
    ISO alpha-2, so every flag resolves without a lookup table.
    """
    m = _EMOJI_STRIP_RE.search(name)
    if not m:
        return None
    seq = m.group(0)
    if (
        len(seq) >= 4
        and "\U0001F1E6" <= seq[0] <= "\U0001F1FF"
        and "\U0001F1E6" <= seq[1] <= "\U0001F1FF"
    ):
        a = chr(ord(seq[0]) - 0x1F1E6 + ord("A"))
        b = chr(ord(seq[1]) - 0x1F1E6 + ord("A"))
        return a + b
    return None


def _node_iso2(name: str) -> str | None:
    """Best-effort ISO alpha-2 for a node display name, or None if unknown."""
    flag = _flag_to_iso2(name)
    if flag:
        return flag
    text = _EMOJI_STRIP_RE.sub(" ", name).lower()
    tokens = [t for t in re.split(r"[^a-zа-яё0-9]+", text) if t]
    # multi-word names first ("united states", "hong kong", "новая зеландия"),
    # any window of up to 3 consecutive tokens
    for width in (3, 2):
        for i in range(len(tokens) - width + 1):
            phrase = " ".join(tokens[i : i + width])
            if phrase in _ISO2_BY_NAME:
                return _ISO2_BY_NAME[phrase]
            if phrase in _ISO2_BY_RU_NAME:
                return _ISO2_BY_RU_NAME[phrase]
    for tok in tokens:
        if tok in _ISO2_BY_NAME:
            return _ISO2_BY_NAME[tok]
        if tok in _ISO2_BY_RU_NAME:
            return _ISO2_BY_RU_NAME[tok]
        # hostname-style prefix: "us01", "de3", "uk2"
        m = re.match(r"^([a-z]{2})\d+$", tok)
        if m and m.group(1) in _ISO2_HOST_PREFIX:
            return _ISO2_HOST_PREFIX[m.group(1)]
    return None


def _strip_comment(line: str) -> str:
    """Drop a trailing '# ...' comment, keeping the payload."""
    return line.split("#", 1)[0].strip()


def load_policy(path: Path) -> dict[str, Any]:
    """Parse policy.conf — the single user-facing config file.

    Returns {"processes": [...], "proxy_domains": [...], "direct_domains": [...],
             "auto": {...}, "found": bool}. A missing file yields empty lists
    and default auto-select settings (equivalent to "route everything direct,
    let the active/first node handle it").
    """
    out: dict[str, Any] = {
        "processes": [],
        "proxy_domains": [],
        "direct_domains": [],
        "auto": dict(POLICY_DEFAULTS),
        "found": False,
    }
    if not path.is_file():
        return out
    out["found"] = True

    section_key = {
        "processes-via-vpn": "processes",
        "domains-via-vpn": "proxy_domains",
        "domains-direct": "direct_domains",
    }
    current: str | None = None
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            current = line[1:-1].strip().lower()
            continue
        value = _strip_comment(line)
        if not value:
            continue
        if current == "auto-select":
            if "=" in value:
                k, v = value.split("=", 1)
                out["auto"][k.strip().lower()] = v.strip()
        elif current in section_key:
            out[section_key[current]].append(value)
    return out


def _split_domains(entries: list[str]) -> list[str]:
    """Normalize policy domain entries into sing-box `domain_suffix` values.

    policy.conf semantics: a bare "example.com" means the domain AND all its
    subdomains (api.example.com, ...); a leading-dot ".example.com" means
    subdomains only. sing-box's `domain` rule matches only the exact
    hostname, while `domain_suffix` matches the root plus subdomains, so
    both forms collapse to a single suffix list here.
    """
    suffixes: list[str] = []
    for raw in entries:
        entry = raw.strip().lower()
        if not entry:
            continue
        suffixes.append(entry.lstrip("."))
    return suffixes


def _decode_base64_blob(blob: str) -> list[str]:
    """Decode a base64 subscription body pasted straight into endpoints.txt.

    Returns [] when the line is not a base64 blob of vless:// URIs, so the
    caller can fall through to its normal "ignore unknown line" path.
    """
    text = blob.strip()
    if not text:
        return []
    # Subscription blobs are sometimes base64url and/or unpadded.
    candidate = text.replace("-", "+").replace("_", "/")
    padded = candidate + ("=" * (-len(candidate) % 4))
    try:
        decoded = base64.b64decode(padded, validate=False).decode(
            "utf-8", errors="replace"
        )
    except Exception:
        return []
    return [
        ln.strip() for ln in decoded.splitlines() if ln.strip().startswith("vless://")
    ]


def _fetch_subscription(url: str, timeout: float = 30.0) -> list[str]:
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "golem-vless-client/1.0"},
        method="GET",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = resp.read()
    text = body.decode("utf-8", errors="replace").strip()
    # Common: base64 blob of newline-separated URIs
    try:
        padded = text + ("=" * (-len(text) % 4))
        decoded = base64.b64decode(padded, validate=False).decode(
            "utf-8", errors="replace"
        )
        if "://" in decoded:
            text = decoded
    except Exception:
        pass
    uris: list[str] = []
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("vless://"):
            uris.append(line)
    return uris


def probe_nodes(
    nodes: list[dict[str, Any]], timeout: float = 2.0, concurrency: int = 16
) -> dict[int, int | None]:
    """Parallel TCP probe of every node's server:port.

    Returns {node_index: latency_ms_or_None}. A plain connect (before any
    tunnel exists — at render time the client is still cold) is a fast, cheap
    liveness+latency filter: it culls permanently-dead nodes and orders the
    rest by round-trip so the urltest pool is built from live, fast ones
    instead of blindly taking the first N of the subscription (which is why the
    "Auto/Оптимальная локация" node that answers only after ~1.6s used to win).
    """
    def _probe(idx: int, node: dict[str, Any]) -> tuple[int, int | None]:
        host = node["outbound"].get("server")
        port = int(node["outbound"].get("server_port") or 443)
        start = time.monotonic()
        try:
            with socket.create_connection((host, port), timeout=timeout):
                ms = int((time.monotonic() - start) * 1000)
                return idx, max(1, ms)
        except OSError:
            return idx, None

    results: dict[int, int | None] = {i: None for i in range(len(nodes))}
    with ThreadPoolExecutor(max_workers=max(1, concurrency)) as ex:
        futures = [ex.submit(_probe, i, n) for i, n in enumerate(nodes)]
        for f in futures:
            i, lat = f.result()
            results[i] = lat
    return results


PROBE_ANTHROPIC_URL = "https://api.anthropic.com/v1/models"
PROBE_YOUTUBE_URL = "https://www.youtube.com/"
# Reaching Anthropic's API unauthenticated answers 401 (missing key). Some
# endpoints now 404 on a bare GET; either means the exit is NOT blocked
# upstream (a blocked datacenter exit answers 403 and must be filtered out).
PROBE_DEFAULT_ANTHROPIC_OK = "401 404"
PROBE_DEFAULT_YOUTUBE_OK = "200"
PROBE_CACHE_TTL_HOURS = 6.0
PROBE_TIMEOUT = 5.0


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Refuse 3xx redirects so a proxied probe reports the raw status code.

    A node that answers a probe URL with 301/302 instead of the expected
    200/401 is degraded (e.g. YouTube would serve a redirect to a consent or
    block page) — without this handler urllib would silently follow the
    redirect and report the final 200, masking the problem.
    """

    def redirect_request(
        self, req, fp, code, msg, headers, newurl
    ):  # noqa: ANN001
        return None


def _http_status_via_proxy(port: int, url: str, timeout: float) -> int | None:
    """GET `url` through a local mixed proxy; return the HTTP status code.

    Returns None when the request could not be completed at all (TCP refused,
    TLS handshake timeout, proxy dead). HTTPError carries the interesting
    statuses here — 401 (Anthropic needs an API key) and 403 (blocked exit)
    are *expected* outcomes, not transport failures.
    """
    proxy = f"http://127.0.0.1:{port}"
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({"http": proxy, "https": proxy}),
        _NoRedirect(),
    )
    req = urllib.request.Request(
        url, headers={"User-Agent": "golem-vless-client/node-probe"}
    )
    try:
        with opener.open(req, timeout=timeout) as resp:
            return resp.status
    except urllib.error.HTTPError as exc:
        return exc.code
    except (urllib.error.URLError, OSError, TimeoutError):
        return None


def _probe_config(node: dict[str, Any], listen_port: int) -> dict[str, Any]:
    """Minimal sing-box config that dials HTTP only through `node`.

    One mixed inbound on an ephemeral localhost port, the node as the only
    usable outbound, direct/block as inert exits. DNS stays local — we want to
    prove the *exit* IP of the tunnel is allowed, not exercise DNS routing.
    Route final is the node: any CONNECT (api.anthropic.com:443) goes through
    the tunnel, exactly like a real proxied request.
    """
    outbound = dict(node["outbound"])
    outbound["tag"] = "proxy"
    return {
        "log": {"level": "error"},
        "inbounds": [
            {
                "type": "mixed",
                "tag": "probe-in",
                "listen": "127.0.0.1",
                "listen_port": listen_port,
                "set_system_proxy": False,
            }
        ],
        "outbounds": [
            outbound,
            {"type": "direct", "tag": "direct"},
            {"type": "block", "tag": "block"},
        ],
        "dns": {
            "servers": [
                {"tag": "dns-local", "type": "local"},
                {
                    "tag": "dns-remote",
                    "type": "https",
                    "server": "1.1.1.1",
                    "detour": "proxy",
                },
            ],
            "strategy": "prefer_ipv4",
            "final": "dns-local",
            # Resolve the probe targets the same way production does (over the
            # tunnel) so the check reflects real routed traffic, not the local
            # RU resolver — otherwise a poisoned local answer can mask a node
            # that actually works (or vice versa).
            "rules": [
                {
                    "domain": ["api.anthropic.com", "www.youtube.com"],
                    "server": "dns-remote",
                }
            ],
        },
        "route": {
            "rules": [
                {"action": "sniff"},
                {"protocol": "dns", "action": "hijack-dns"},
            ],
            "final": "proxy",
            "default_domain_resolver": {"server": "dns-local"},
        },
    }


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _run_throwaway_probe(
    binary: str, run_args: list[str], cfg: dict[str, Any], port: int, timeout: float
) -> tuple[int | None, int | None]:
    """Write `cfg` to a temp file, run `binary run_args... -c cfg`, probe
    Anthropic + YouTube through the port it opens, then tear it down.

    Engine-agnostic: sing-box and xray-core both take "run -c <file>" and
    both open their inbound almost immediately, so the same wait/probe/kill
    sequence works for either.
    """
    cfg_path = None
    proc = None
    try:
        fd, cfg_path = tempfile.mkstemp(
            prefix="golem-probe-", suffix=".json", dir=tempfile.gettempdir()
        )
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(cfg, fh)
        creationflags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
        proc = subprocess.Popen(
            [binary, *run_args, "-c", cfg_path],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            creationflags=creationflags,
        )
        # wait for the inbound to accept connections
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                return None, None  # process exited: bad node/config
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.3):
                    break
            except OSError:
                time.sleep(0.1)
        else:
            return None, None
        anth = _http_status_via_proxy(port, PROBE_ANTHROPIC_URL, timeout)
        yt = _http_status_via_proxy(port, PROBE_YOUTUBE_URL, timeout)
        return anth, yt
    finally:
        if proc is not None:
            proc.terminate()
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()
        if cfg_path is not None:
            try:
                os.unlink(cfg_path)
            except OSError:
                pass


def _probe_single_node(
    node: dict[str, Any],
    sing_box: str,
    timeout: float,
    xray: str | None = None,
) -> tuple[int | None, int | None]:
    """Probe one node's actual reachability (Anthropic + YouTube).

    Dispatches by node["meta"]["engine"]: sing-box-native nodes get a
    throwaway sing-box instance; xhttp/splithttp nodes (engine="xray") need
    a throwaway Xray-core instance instead, since sing-box cannot dial them
    at all (see B-007). Returns (None, None) for an xray node when no xray
    binary is available — it is skipped, not falsely marked reachable.
    """
    engine = node["meta"].get("engine", "sing-box")
    port = _free_port()
    if engine == "xray":
        if xray is None:
            return None, None
        return _run_throwaway_probe(xray, ["run"], build_xray_config([node], port), port, timeout)
    return _run_throwaway_probe(sing_box, ["run"], _probe_config(node, port), port, timeout)


def _node_fingerprint(node: dict[str, Any]) -> str:
    """Stable identity of a node for the probe cache.

    Server + port + transport are what actually matter for reachability; the
    uuid/account is shared across the Durev pool. Using only the dialable bits
    keeps cache hits high across subscription refreshes.
    """
    ob = node["outbound"]
    core = {
        "server": ob.get("server"),
        "server_port": ob.get("server_port"),
        "transport": ob.get("transport"),
    }
    return hashlib.sha256(
        json.dumps(core, sort_keys=True, default=str).encode("utf-8")
    ).hexdigest()[:20]


def probe_nodes_http(
    nodes: list[dict[str, Any]],
    sing_box: str,
    *,
    xray: str | None = None,
    timeout: float = PROBE_TIMEOUT,
    anthropic_ok: str = PROBE_DEFAULT_ANTHROPIC_OK,
    youtube_ok: str = PROBE_DEFAULT_YOUTUBE_OK,
    cache_path: Path | None = None,
    cache_ttl_hours: float = PROBE_CACHE_TTL_HOURS,
) -> tuple[set[int], dict[int, tuple[int | None, int | None]]]:
    """HTTP-probe every node through a throwaway sing-box/xray instance.

    Expected outcomes (see B-008/B-010): api.anthropic.com must answer
    401 (no API key sent; 403 = blocked upstream exit) and www.youtube.com
    must answer 200. Returns (passing_indices, per_index (anthropic, youtube)).

    Each node is probed through whichever engine can actually dial it
    (node["meta"]["engine"] — sing-box for native transports, xray-core for
    xhttp/splithttp, see B-007). Passing `xray=None` when no Xray binary is
    installed simply means xhttp nodes are skipped (probed as unreachable)
    rather than crashing the whole render.

    Results are cached in `cache_path` (JSON keyed by node fingerprint) so a
    stable pool is not re-dialed on every render. Passed nodes are reused for
    `cache_ttl_hours`; failed nodes are always re-probed (they may have
    recovered, and the whole point of B-010 is that the pool must be current).
    """
    accepted_anth = {
        int(c) for c in anthropic_ok.replace(",", " ").split() if c.strip().isdigit()
    }
    accepted_yt = {
        int(c) for c in youtube_ok.replace(",", " ").split() if c.strip().isdigit()
    }

    cache: dict[str, dict[str, Any]] = {}
    if cache_path is not None and cache_path.is_file():
        try:
            cache = json.loads(cache_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            cache = {}

    results: dict[int, tuple[int | None, int | None]] = {}
    passing: set[int] = set()
    to_probe: list[tuple[int, dict[str, Any], str]] = []

    now = time.time()
    for i, node in enumerate(nodes):
        fp = _node_fingerprint(node)
        hit = cache.get(fp)
        if hit and hit.get("passed") and now - hit.get("at", 0) < cache_ttl_hours * 3600:
            passing.add(i)
            results[i] = (hit.get("anthropic"), hit.get("youtube"))
        else:
            to_probe.append((i, node, fp))

    if to_probe:
        print(
            f"Проверяю ноды по HTTP (api.anthropic.com → 401, "
            f"www.youtube.com → 200)... {len(to_probe)} к проверке",
            file=sys.stderr,
        )
        with ThreadPoolExecutor(max_workers=min(8, len(to_probe))) as ex:

            def _worker(
                i: int, node: dict[str, Any]
            ) -> tuple[int, int | None, int | None]:
                return (i, *_probe_single_node(node, sing_box, timeout, xray=xray))

            futures = [
                ex.submit(_worker, i, node) for i, node, _fp in to_probe
            ]
            fp_by_index = {i: fp for i, _node, fp in to_probe}
            for f in futures:
                i, anth, yt = f.result()
                results[i] = (anth, yt)
                fp = fp_by_index[i]
                ok = anth in accepted_anth and yt in accepted_yt
                cache[fp] = {
                    "passed": bool(ok),
                    "anthropic": anth,
                    "youtube": yt,
                    "at": time.time(),
                }
                name = nodes[i]["meta"]["name"]
                print(
                    f"  #{i + 1} {name}: anthropic={anth} "
                    f"youtube={yt} → {'OK' if ok else 'FAIL'}",
                    file=sys.stderr,
                )
                if ok:
                    passing.add(i)

        if cache_path is not None:
            cache_path.parent.mkdir(parents=True, exist_ok=True)
            cache_path.write_text(
                json.dumps(cache, ensure_ascii=False, indent=1),
                encoding="utf-8",
            )

    return passing, results


def find_sing_box() -> str | None:
    """Locate the sing-box binary used for HTTP probing.

    The renderer itself never needs sing-box, but B-010's per-node HTTP probe
    dials the tunnel through a throwaway sing-box instance. Resolution order:
    env SING_BOX, PATH, then the Windows install dir next to this script's
    sync copy (%LOCALAPPDATA%\\GolemVLESS\\bin).
    """
    env = os.environ.get("SING_BOX")
    if env and Path(env).is_file():
        return env
    on_path = shutil.which("sing-box")
    if on_path:
        return on_path
    local = os.environ.get("LOCALAPPDATA")
    if local:
        cand = Path(local) / "GolemVLESS" / "bin" / "sing-box.exe"
        if cand.is_file():
            return str(cand)
    return None


def _qbool(params: dict[str, list[str]], key: str, default: bool = False) -> bool:
    vals = params.get(key)
    if not vals:
        return default
    return vals[0].lower() in ("1", "true", "yes", "on")


def _q(
    params: dict[str, list[str]], key: str, default: str | None = None
) -> str | None:
    vals = params.get(key)
    if not vals or vals[0] == "":
        return default
    return vals[0]


def parse_vless_uri(uri: str, provider: str | None = None) -> dict[str, Any]:
    """Parse vless://uuid@host:port?query#name into sing-box outbound fragment."""
    if not uri.startswith("vless://"):
        raise ValueError(f"not a vless URI: {uri[:32]}...")

    parsed = urllib.parse.urlparse(uri)
    uuid = urllib.parse.unquote(parsed.username or "")
    host = parsed.hostname
    port = parsed.port or 443
    if not uuid or not host:
        raise ValueError("vless URI missing uuid or host")

    params = urllib.parse.parse_qs(parsed.query)
    name = (
        urllib.parse.unquote(parsed.fragment) if parsed.fragment else f"{host}:{port}"
    )
    security = (_q(params, "security") or "none").lower()
    network = (_q(params, "type") or _q(params, "network") or "tcp").lower()
    flow = _q(params, "flow") or ""
    encryption = _q(params, "encryption") or "none"

    outbound: dict[str, Any] = {
        "type": "vless",
        "tag": "proxy",  # overwritten when multiple
        "server": host,
        "server_port": int(port),
        "uuid": uuid,
        "packet_encoding": "xudp",
    }
    if flow:
        outbound["flow"] = flow
    # encryption field is legacy; sing-box ignores for VLESS usually

    # TLS / REALITY
    if security in ("tls", "reality"):
        tls: dict[str, Any] = {
            "enabled": True,
            "server_name": _q(params, "sni") or _q(params, "host") or host,
            "insecure": _qbool(params, "allowInsecure") or _qbool(params, "insecure"),
        }
        fp = _q(params, "fp") or _q(params, "fingerprint")
        if fp:
            tls["utls"] = {"enabled": True, "fingerprint": fp}
        alpn = _q(params, "alpn")
        if alpn:
            tls["alpn"] = [p.strip() for p in alpn.split(",") if p.strip()]
        if security == "reality":
            pbk = _q(params, "pbk") or _q(params, "publicKey")
            if not pbk:
                raise ValueError(f"REALITY without pbk: {name}")
            reality: dict[str, Any] = {
                "enabled": True,
                "public_key": pbk,
            }
            sid = _q(params, "sid") or _q(params, "shortId")
            if sid:
                reality["short_id"] = sid
            spx = _q(params, "spx") or _q(params, "spiderX")
            if spx:
                reality["spider_x"] = spx
            tls["reality"] = reality
        outbound["tls"] = tls

    # Transport
    if network == "ws":
        transport: dict[str, Any] = {
            "type": "ws",
            "path": _q(params, "path") or "/",
        }
        host_header = _q(params, "host") or _q(params, "sni")
        if host_header:
            transport["headers"] = {"Host": host_header}
        outbound["transport"] = transport
    elif network == "grpc":
        outbound["transport"] = {
            "type": "grpc",
            "service_name": _q(params, "serviceName")
            or _q(params, "service_name")
            or "",
        }
    elif network == "http":
        outbound["transport"] = {
            "type": "http",
            "path": _q(params, "path") or "/",
            "host": [h for h in (_q(params, "host") or host).split(",") if h],
        }
    elif network in ("tcp", "raw"):
        header_type = (
            _q(params, "headerType") or _q(params, "header_type") or ""
        ).lower()
        if header_type == "http":
            outbound["transport"] = {
                "type": "http",
                "path": _q(params, "path") or "/",
                "host": [h for h in (_q(params, "host") or host).split(",") if h],
            }
    elif network in ("httpupgrade", "http_upgrade"):
        outbound["transport"] = {
            "type": "httpupgrade",
            "path": _q(params, "path") or "/",
            "host": _q(params, "host") or host,
        }
    elif network in ("xhttp", "splithttp"):
        # sing-box implements neither "xhttp" nor "splithttp" (verified 1.13.16:
        # "unknown transport type"). parse keeps it outbound-shaped for the
        # xhttp-detection/filter in load_endpoints, but it will never dial.
        outbound["transport"] = {
            "type": "xhttp",
            "path": _q(params, "path") or "/",
            "host": _q(params, "host") or _q(params, "sni") or host,
            "mode": _q(params, "mode") or "auto",
        }

    meta = {
        "name": name,
        "provider": provider,
        "server": host,
        "server_port": int(port),
        "security": security,
        "network": network,
        "encryption": encryption,
        # xhttp/splithttp nodes are dialed through Xray instead of sing-box
        # (see B-007); build_xray_config() re-parses this into Xray's own
        # outbound schema rather than reusing the sing-box-shaped one below.
        "engine": "xray" if network in ("xhttp", "splithttp") else "sing-box",
        "raw_uri": uri,
        "uri_preview": re.sub(r"vless://[^@]+@", "vless://***@", uri)[:120],
    }
    return {"outbound": outbound, "meta": meta}


DEFAULT_XRAY_PORT = 2081


def find_xray() -> str | None:
    """Locate the Xray-core binary.

    sing-box implements neither "xhttp" nor "splithttp" transport (verified
    1.11.15 and 1.13.16: "unknown transport type"). Xray-core does — this is
    exactly the chain Durev's own official app uses internally (sing-box for
    TUN, xray-core as a child process for xhttp), confirmed by inspecting its
    running processes (2026-08-09: PIDs for "sing-box" and "xray" both owned
    by "Durev VPN", the xray child listening on 127.0.0.1:13001). Resolution
    order mirrors find_sing_box().
    """
    env = os.environ.get("XRAY")
    if env and Path(env).is_file():
        return env
    on_path = shutil.which("xray")
    if on_path:
        return on_path
    local = os.environ.get("LOCALAPPDATA")
    if local:
        cand = Path(local) / "GolemVLESS" / "bin" / "xray.exe"
        if cand.is_file():
            return str(cand)
    return None


def vless_uri_to_xray_outbound(uri: str, tag: str) -> dict[str, Any]:
    """Parse vless://... into an Xray-core outbound fragment.

    Deliberately independent of parse_vless_uri()'s sing-box-shaped output:
    Xray's VLESS outbound schema (vnext/streamSettings) is structurally
    different, and Xray is the only engine here that understands
    xhttp/splithttp — the entire reason this function exists (see B-007).
    """
    if not uri.startswith("vless://"):
        raise ValueError(f"not a vless URI: {uri[:32]}...")
    parsed = urllib.parse.urlparse(uri)
    uuid = urllib.parse.unquote(parsed.username or "")
    host = parsed.hostname
    port = parsed.port or 443
    if not uuid or not host:
        raise ValueError("vless URI missing uuid or host")

    params = urllib.parse.parse_qs(parsed.query)
    security = (_q(params, "security") or "none").lower()
    network = (_q(params, "type") or _q(params, "network") or "tcp").lower()
    flow = _q(params, "flow") or ""

    user: dict[str, Any] = {"id": uuid, "encryption": "none"}
    # XTLS flow control is a raw-TCP+REALITY feature; setting it on an xhttp
    # outbound is a startup-time validation error in Xray, not a soft no-op.
    if flow and network in ("tcp", "raw"):
        user["flow"] = flow

    stream: dict[str, Any] = {
        "network": "raw" if network in ("tcp", "raw") else network
    }

    if security in ("tls", "reality"):
        sni = _q(params, "sni") or _q(params, "host") or host
        fp = _q(params, "fp") or _q(params, "fingerprint")
        if security == "reality":
            pbk = _q(params, "pbk") or _q(params, "publicKey")
            if not pbk:
                raise ValueError(f"REALITY without pbk: {uri[:40]}...")
            reality: dict[str, Any] = {
                "show": False,
                "serverName": sni,
                "publicKey": pbk,
            }
            if fp:
                reality["fingerprint"] = fp
            sid = _q(params, "sid") or _q(params, "shortId")
            if sid:
                reality["shortId"] = sid
            spx = _q(params, "spx") or _q(params, "spiderX")
            if spx:
                reality["spiderX"] = spx
            stream["security"] = "reality"
            stream["realitySettings"] = reality
        else:
            tls: dict[str, Any] = {
                "serverName": sni,
                "allowInsecure": _qbool(params, "allowInsecure")
                or _qbool(params, "insecure"),
            }
            if fp:
                tls["fingerprint"] = fp
            alpn = _q(params, "alpn")
            if alpn:
                tls["alpn"] = [p.strip() for p in alpn.split(",") if p.strip()]
            stream["security"] = "tls"
            stream["tlsSettings"] = tls

    if network == "ws":
        ws: dict[str, Any] = {"path": _q(params, "path") or "/"}
        host_header = _q(params, "host") or _q(params, "sni")
        if host_header:
            ws["headers"] = {"Host": host_header}
        stream["wsSettings"] = ws
    elif network == "grpc":
        stream["grpcSettings"] = {
            "serviceName": _q(params, "serviceName")
            or _q(params, "service_name")
            or "",
        }
    elif network in ("xhttp", "splithttp"):
        stream["network"] = "xhttp"
        stream["xhttpSettings"] = {
            "path": _q(params, "path") or "/",
            "host": _q(params, "host") or _q(params, "sni") or host,
            "mode": _q(params, "mode") or "auto",
        }
    elif network in ("httpupgrade", "http_upgrade"):
        stream["network"] = "httpupgrade"
        stream["httpupgradeSettings"] = {
            "path": _q(params, "path") or "/",
            "host": _q(params, "host") or host,
        }

    return {
        "tag": tag,
        "protocol": "vless",
        "settings": {"vnext": [{"address": host, "port": int(port), "users": [user]}]},
        "streamSettings": stream,
    }


def build_xray_config(nodes: list[dict[str, Any]], listen_port: int) -> dict[str, Any]:
    """Xray-core config: one vless outbound per node behind a leastPing
    balancer, exposed as a single local SOCKS proxy.

    Xray's built-in Observatory pings every balancer member on a timer, and
    the leastPing strategy always routes to the fastest member that is
    currently alive — Xray's own equivalent of sing-box's urltest, applied
    here to the pool of nodes sing-box itself cannot dial (xhttp/splithttp).
    sing-box then treats this whole pool as one extra candidate (a local
    SOCKS outbound) in its own urltest race against natively-supported
    nodes — see build_config()'s "xray-pool" outbound.

    Also used (with a single-node list) to probe one xhttp node in
    probe_nodes_http(); a 1-member balancer degrades harmlessly to "use the
    only member".
    """
    tags = [f"x{i}" for i in range(len(nodes))]
    outbounds = [
        vless_uri_to_xray_outbound(n["meta"]["raw_uri"], tag)
        for n, tag in zip(nodes, tags)
    ]
    outbounds.append({"tag": "direct", "protocol": "freedom"})
    outbounds.append({"tag": "block", "protocol": "blackhole"})

    return {
        "log": {"loglevel": "warning"},
        "inbounds": [
            {
                "tag": "in",
                "listen": "127.0.0.1",
                "port": listen_port,
                "protocol": "socks",
                "settings": {"auth": "noauth", "udp": True},
            }
        ],
        "outbounds": outbounds,
        "routing": {
            "domainStrategy": "AsIs",
            "balancers": [
                {"tag": "pool", "selector": tags, "strategy": {"type": "leastPing"}}
            ],
            "rules": [{"type": "field", "inboundTag": ["in"], "balancerTag": "pool"}],
        },
        "observatory": {
            "subjectSelector": tags,
            "probeUrl": "https://www.gstatic.com/generate_204",
            "probeInterval": "30s",
        },
    }


def _load_subscription_cache(path: Path) -> list[str]:
    """Read cached vless:// URIs saved from the last successful fetch."""
    if not path.is_file():
        return []
    return [
        ln.strip()
        for ln in path.read_text(encoding="utf-8-sig").splitlines()
        if ln.strip().startswith("vless://")
    ]


def load_endpoints(
    path: Path, fetch_subs: bool, sub_cache: Path | None = None
) -> tuple[list[dict[str, Any]], int]:
    if not path.is_file():
        raise FileNotFoundError(
            f"Missing {path}. Copy secrets/endpoints.example.txt → endpoints.txt and paste a key."
        )

    provider: str | None = None
    active = 1
    collected: list[dict[str, Any]] = []

    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.upper().startswith("ACTIVE="):
            active = int(line.split("=", 1)[1].strip())
            continue
        if line.lower().startswith("@provider"):
            parts = line.split(None, 1)
            provider = parts[1].strip() if len(parts) > 1 else None
            continue

        uris: list[str] = []
        if line.startswith("vless://"):
            uris = [line]
        elif line.startswith("http://") or line.startswith("https://"):
            if not fetch_subs:
                print(
                    f"WARN: skip subscription (use --fetch): {line[:60]}...",
                    file=sys.stderr,
                )
                continue
            try:
                uris = _fetch_subscription(line)
                print(
                    f"INFO: subscription fetched {len(uris)} vless URI(s) from {line[:60]}",
                    file=sys.stderr,
                )
                # Persist the successful fetch so a later outage of the
                # subscription host degrades to the last known node list
                # instead of killing the render (daily auto-refresh source).
                if sub_cache is not None:
                    sub_cache.parent.mkdir(parents=True, exist_ok=True)
                    sub_cache.write_text(
                        # Sort for a stable sha256 between runs: the provider
                        # shuffles node order on each fetch, which would
                        # otherwise make the refresh watchdog restart the
                        # client needlessly on every check.
                        "\n".join(sorted(uris)) + "\n",
                        encoding="utf-8",
                    )
            except (urllib.error.URLError, TimeoutError, ValueError, OSError) as exc:
                cached = _load_subscription_cache(sub_cache) if sub_cache is not None else []
                if cached:
                    print(
                        f"WARN: subscription fetch failed ({exc}); "
                        f"using {len(cached)} cached vless URI(s) from last successful fetch "
                        f"({sub_cache.name})",
                        file=sys.stderr,
                    )
                    uris = cached
                else:
                    raise RuntimeError(
                        f"subscription fetch failed: {line[:80]}: {exc}"
                    ) from exc
        else:
            # Subscription body pasted directly (base64 blob), for when DPI
            # blocks fetching the subscription URL from this network.
            uris = _decode_base64_blob(line)
            if uris:
                print(
                    f"INFO: decoded {len(uris)} vless URI(s) from pasted base64",
                    file=sys.stderr,
                )
            else:
                print(f"WARN: ignore line: {line[:80]}", file=sys.stderr)
                continue

        for uri in uris:
            try:
                node = parse_vless_uri(uri, provider=provider)
            except ValueError as exc:
                print(f"WARN: skip bad URI ({exc})", file=sys.stderr)
                continue
            # xhttp/splithttp nodes are kept, not dropped: they route through
            # Xray-core instead of sing-box (engine="xray", see B-007 and
            # build_xray_config()).
            collected.append(node)

    if not collected:
        raise RuntimeError(
            "No usable VLESS endpoints. Paste vless://... into secrets/endpoints.txt"
        )
    if active < 1 or active > len(collected):
        raise RuntimeError(f"ACTIVE={active} out of range 1..{len(collected)}")
    return collected, active


def build_config(
    nodes: list[dict[str, Any]],
    active: int,
    *,
    mixed_port: int,
    enable_tun: bool,
    use_rule_sets: bool,
    tun_stack: str = "gvisor",
    tun_name: str = DEFAULT_TUN_NAME,
    log_level: str = "info",
    default_interface: str | None = None,
    state_dir: Path | None = None,
    policy_path: Path = POLICY_PATH,
    probe: dict[int, int | None] | None = None,
    xray_port: int = DEFAULT_XRAY_PORT,
) -> dict[str, Any]:
    chosen = nodes[active - 1]
    # xhttp/splithttp nodes (engine="xray", see B-007) cannot be embedded as
    # sing-box outbounds at all — parse_vless_uri() only shapes them enough
    # to carry raw_uri through. They get a single combined slot below
    # ("xray-pool": a local SOCKS outbound backed by build_xray_config()'s
    # own leastPing balancer across all of them), never the per-node
    # treatment native nodes get.
    xray_nodes = [n for n in nodes if n["meta"].get("engine") == "xray"]

    policy = load_policy(policy_path)
    auto = policy["auto"]
    auto_on = str(auto.get("enabled", "yes")).strip().lower() in {
        "yes",
        "true",
        "1",
        "on",
    }

    proxy_suffixes = _split_domains(policy["proxy_domains"])
    direct_suffixes = _split_domains(policy["direct_domains"])

    # --- outbound(s): either one fixed node, or a latency-raced pool ---------
    # Providers often mark tuned routes as "Gemini" or "Roblox". Put matching
    # nodes first, so urltest includes them in its limited candidate pool but
    # can still fail over to ordinary nodes when they are unavailable.
    # (Only re-sort the list when there is no probe to filter with — the probe
    # path orders the pool by measured latency below, and re-sorting `nodes`
    # here would desync the probe's node indices.)
    native_nodes = [n for n in nodes if n["meta"].get("engine", "sing-box") != "xray"]

    preferred = [
        s.strip().lower()
        for s in str(auto.get("preferred_tags", "")).split(",")
        if s.strip()
    ]
    if preferred and probe is None:
        native_nodes = sorted(
            native_nodes,
            key=lambda node: (
                0
                if any(
                    tag in str((node.get("meta") or {}).get("name", "")).lower()
                    for tag in preferred
                )
                else 1
            ),
        )

    proxy_outbounds: list[dict[str, Any]] = []
    if auto_on and (len(native_nodes) + (1 if xray_nodes else 0)) > 1:
        try:
            candidates = max(2, int(str(auto.get("candidates", "12")).strip()))
        except ValueError:
            candidates = 12
        try:
            tolerance = int(str(auto.get("tolerance", "50")).strip())
        except ValueError:
            tolerance = 50
        if probe:
            # Filter out dead nodes and order the urltest pool by measured
            # latency, so the client always races live, fast nodes instead of
            # blindly taking the first N of the subscription. preferred_tags
            # get a small tolerance-sized head start so a Gemini/Roblox route
            # still wins when it is roughly as fast as the leader.
            effective: list[tuple[int, int, dict[str, Any]]] = []
            for i, node in enumerate(nodes):
                if node["meta"].get("engine") == "xray":
                    continue  # handled separately via the xray-pool outbound
                lat = probe.get(i)
                if lat is None:
                    nm = str((node.get("meta") or {}).get("name") or f"#{i + 1}")
                    print(
                        f"WARN: нода #{i + 1} ({nm}) не отвечает — исключаю из пула",
                        file=sys.stderr,
                    )
                    continue
                eff = lat
                nm_low = str((node.get("meta") or {}).get("name") or "").lower()
                if preferred and any(tag in nm_low for tag in preferred):
                    eff -= tolerance
                effective.append((eff, lat, node))
            if len(effective) >= 2:
                effective.sort(key=lambda t: t[0])
                pool = [n for _, _, n in effective[:candidates]]
            else:
                print(
                    "WARN: живых нод меньше двух — оставляю пул как есть",
                    file=sys.stderr,
                )
                pool = native_nodes[:candidates]
        else:
            pool = native_nodes[:candidates]
        member_tags: list[str] = []
        for idx, node in enumerate(pool, start=1):
            ob = dict(node["outbound"])
            # Readable tag ("03 Germany") so `vpnctl nodes` shows the country
            # instead of an opaque index. Emoji/flags are stripped: they break
            # column alignment in the terminal.
            raw_name = str((node.get("meta") or {}).get("name") or "").strip()
            clean = "".join(
                ch for ch in raw_name if ch.isalnum() or ch in " -_"
            ).strip()
            clean = " ".join(clean.split())
            # Provider labels the first node "Auto → [Оптимальная локация]";
            # keep just "Auto" so the column stays readable.
            if clean.lower().startswith("auto"):
                clean = "Auto"
            clean = clean[:20]
            ob["tag"] = f"{idx:02d} {clean}".strip() if clean else f"node-{idx:02d}"
            proxy_outbounds.append(ob)
            member_tags.append(ob["tag"])
        if xray_nodes:
            # The whole xhttp/splithttp pool (see B-007) races as a single
            # extra candidate: Xray's own leastPing balancer has already
            # picked its best member by the time sing-box dials this socks
            # outbound, so sing-box's urltest is really racing "best native
            # node" against "best xray-managed node", not against 40+
            # individual xhttp entries it could not embed anyway.
            xray_tag = "xray-pool"
            proxy_outbounds.append(
                {
                    "type": "socks",
                    "tag": xray_tag,
                    "server": "127.0.0.1",
                    "server_port": xray_port,
                }
            )
            member_tags.append(xray_tag)
        proxy_outbounds.append(
            {
                "type": "urltest",
                "tag": "proxy",
                "outbounds": member_tags,
                "url": str(auto.get("test_url", POLICY_DEFAULTS["test_url"])).strip(),
                "interval": str(auto.get("interval", "5m")).strip(),
                "tolerance": tolerance,
            }
        )
    else:
        if chosen["meta"].get("engine") == "xray":
            # chosen["outbound"] is not dialable by sing-box at all for an
            # xhttp/splithttp node (see B-007) — route to it via the local
            # Xray instance instead. A single-member "balancer" there
            # degrades harmlessly to "use the only node".
            single = {
                "type": "socks",
                "tag": "proxy",
                "server": "127.0.0.1",
                "server_port": xray_port,
            }
        else:
            single = dict(chosen["outbound"])
            single["tag"] = "proxy"
        proxy_outbounds.append(single)

    dns: dict[str, Any] = {
        "servers": [
            {"tag": "dns-direct", "type": "local"},
            {
                "tag": "dns-remote",
                "type": "https",
                "server": "1.1.1.1",
                "detour": "proxy",
            },
        ],
        "strategy": "prefer_ipv4",
        "final": "dns-direct",
    }

    # Domains routed via VPN must resolve via DNS-remote (1.1.1.1 over the
    # tunnel), otherwise RU DNS poisoning for openai.com & co. would defeat the
    # whole split. This must apply even when rule-sets are disabled, so it is
    # built unconditionally and only the rule_set-based DNS rules are gated.
    proxy_dns_rules: list[dict[str, Any]] = []
    if proxy_suffixes:
        proxy_dns_rules.append({"domain_suffix": proxy_suffixes, "server": "dns-remote"})

    inbounds: list[dict[str, Any]] = [
        {
            "type": "mixed",
            "tag": "mixed-in",
            "listen": "127.0.0.1",
            "listen_port": mixed_port,
            "set_system_proxy": False,
        }
    ]
    if enable_tun:
        inbounds.insert(
            0,
            {
                "type": "tun",
                "tag": "tun-in",
                "interface_name": tun_name,
                "address": [DEFAULT_TUN_ADDR],
                "mtu": 1500,
                "auto_route": True,
                "strict_route": False,
                # gvisor (userspace) rather than "system": with the system stack
                # packets reach the TUN but connections never complete on this
                # host, so nothing routed through the TUN works at all.
                "stack": tun_stack,
            },
        )

    outbounds: list[dict[str, Any]] = [
        *proxy_outbounds,
        {"type": "direct", "tag": "direct"},
        {"type": "block", "tag": "block"},
    ]

    def route_to(outbound: str, **match: Any) -> dict[str, Any]:
        return {**match, "action": "route", "outbound": outbound}

    route_rules: list[dict[str, Any]] = [
        {"action": "sniff"},
        {"protocol": "dns", "action": "hijack-dns"},
        route_to("direct", ip_is_private=True),
    ]

    # Per-process rules come before the domain lists: "this app always goes
    # through the VPN" must win over "this domain is direct".
    # Entries containing "/" are matched as full paths, the rest by name.
    # Windows paths use backslashes; retain the Linux behaviour while allowing
    # the same policy file to describe exact Windows executables.
    proc_names = [p for p in policy["processes"] if "/" not in p and "\\" not in p]
    proc_paths = [p for p in policy["processes"] if "/" in p or "\\" in p]
    if proc_names:
        expanded_names: list[str] = []
        for name in proc_names:
            if name not in expanded_names:
                expanded_names.append(name)
            if not name.lower().endswith(".exe"):
                exe_name = f"{name}.exe"
                if exe_name not in expanded_names:
                    expanded_names.append(exe_name)
        route_rules.append(route_to("proxy", process_name=expanded_names))
    if proc_paths:
        route_rules.append(route_to("proxy", process_path=proc_paths))

    if direct_suffixes:
        route_rules.append(route_to("direct", domain_suffix=direct_suffixes))
    if proxy_suffixes:
        route_rules.append(route_to("proxy", domain_suffix=proxy_suffixes))

    # Telegram Desktop ignores the system proxy and dials MTProto servers by
    # IP (149.154.x/91.108.x:443/80) straight through the TUN. With the gvisor
    # TUN stack neither process_name nor domain sniffing matches those — only
    # an explicit IP rule can. These blocks ship the official Telegram ranges
    # (via telegram.org instructions); keep them in sync with the DNS-remote
    # rule set when rule-sets are re-enabled.
    TELEGRAM_CIDRS = [
        "91.108.4.0/22",
        "91.108.8.0/21",
        "91.108.16.0/21",
        "91.108.56.0/22",
        "91.108.58.0/23",
        "149.154.160.0/20",
        "95.161.64.0/20",
        "185.76.151.0/24",
    ]
    route_rules.append(route_to("proxy", ip_cidr=TELEGRAM_CIDRS))

    rule_sets: list[dict[str, Any]] = []
    if use_rule_sets:
        # Remote geosite sets — downloaded by sing-box on start
        rule_sets = [
            {
                "tag": "geosite-telegram",
                "type": "remote",
                "format": "binary",
                "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-telegram.srs",
                "download_detour": "direct",
            },
            {
                "tag": "geosite-category-ru",
                "type": "remote",
                "format": "binary",
                "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ru.srs",
                "download_detour": "direct",
            },
            {
                "tag": "geoip-ru",
                "type": "remote",
                "format": "binary",
                "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs",
                "download_detour": "direct",
            },
        ]
        route_rules.extend(
            [
                route_to("direct", rule_set="geosite-category-ru"),
                route_to("direct", rule_set="geoip-ru"),
                route_to("proxy", rule_set="geosite-telegram"),
            ]
        )
        dns["rules"] = [
            {"rule_set": "geosite-category-ru", "server": "dns-direct"},
            {"rule_set": "geosite-telegram", "server": "dns-remote"},
            *proxy_dns_rules,
        ]
    elif proxy_dns_rules:
        dns["rules"] = proxy_dns_rules

    # auto_detect_interface and default_interface are mutually exclusive in
    # sing-box. Autodetect by default; only pin a specific uplink when the
    # caller provides an unambiguous one (see Run-GolemVless.ps1).
    route: dict[str, Any] = {
        "rules": route_rules,
        "final": "direct",
        # Direct outbound connections with a domain destination resolve the
        # hostname via the local resolver (needed since sing-box 1.12; legacy
        # implicit missing-resolver behaviour is removed in 1.14).
        "default_domain_resolver": {"server": "dns-direct"},
    }
    if default_interface:
        route["default_interface"] = default_interface
    if rule_sets:
        route["rule_set"] = rule_sets

    cache_path = str((state_dir or OUT_DIR) / "cache.db")

    return {
        "log": {"level": log_level, "timestamp": True},
        "dns": dns,
        "inbounds": inbounds,
        "outbounds": outbounds,
        "route": route,
        "experimental": {
            "cache_file": {
                "enabled": True,
                "path": cache_path,
            },
            # Localhost-only control API: lets vpnctl read live latencies and
            # switch nodes without restarting the service (which would drop
            # every open connection).
            "clash_api": {
                "external_controller": "127.0.0.1:9090",
                "default_mode": "rule",
            },
        },
    }


def _record_render_stats(
    nodes: list[dict[str, Any]],
    active: int,
    probe: dict[int, int | None] | None,
    http_verdict: dict[int, tuple[int | None, int | None]] | None,
    passing: set[int],
    *,
    state_dir: Path,
) -> None:
    """Best-effort B-015 telemetry dump; never let stats break the render."""
    try:
        import stats as _stats
    except ImportError:
        return
    http_results = None
    if http_verdict:
        if passing and len(passing) != len(nodes):
            order = sorted(passing)
        else:
            order = list(range(len(nodes)))
        http_results = {
            j: http_verdict[ii]
            for j, ii in enumerate(order)
            if ii in http_verdict and http_verdict[ii] is not None
        }
    try:
        _stats.record_render(
            state_dir,
            nodes=nodes,
            active=active,
            provider=(nodes[active - 1].get("meta") or {}).get("provider")
            if 0 < active <= len(nodes)
            else None,
            probe=probe,
            http_results=http_results,
        )
    except Exception as exc:  # noqa: BLE001 — telemetry must be fail-soft
        print(f"WARN: stats skipped: {exc}", file=sys.stderr)


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Render a sing-box config from endpoints.txt + policy.conf"
    )
    ap.add_argument(
        "--endpoints", type=Path, default=SECRETS, help="Path to endpoints.txt"
    )
    ap.add_argument(
        "--policy", type=Path, default=POLICY_PATH, help="Path to policy.conf"
    )
    ap.add_argument(
        "--out", type=Path, default=OUT_CONFIG, help="Where to write config.json"
    )
    ap.add_argument(
        "--state-dir",
        type=Path,
        default=None,
        help="Durable dir for sing-box's own cache.db (default: next to --out)",
    )
    ap.add_argument(
        "--fetch", action="store_true", help="Fetch https subscription URLs"
    )
    ap.add_argument(
        "--no-tun", action="store_true", help="Only mixed SOCKS/HTTP on localhost"
    )
    ap.add_argument(
        "--no-rule-sets", action="store_true", help="Skip remote geosite/geoip"
    )
    ap.add_argument("--mixed-port", type=int, default=DEFAULT_MIXED_PORT)
    ap.add_argument("--tun-name", default=DEFAULT_TUN_NAME, help="TUN interface name")
    ap.add_argument(
        "--default-interface",
        help="Physical uplink interface name (Windows TUN loop prevention)",
    )
    ap.add_argument(
        "--tun-stack",
        choices=["gvisor", "system", "mixed"],
        default="gvisor",
        help=(
            "TUN network stack. 'system' can leave the TUN completely dead "
            "(packets flow, no connection ever completes) on some kernels/VMs "
            "with no error logged — if nothing works after enabling TUN, this "
            "is the first thing to check. 'gvisor' (userspace) is slower but reliable."
        ),
    )
    ap.add_argument(
        "--log-level",
        choices=["trace", "debug", "info", "warn", "error"],
        default="info",
        help="sing-box log level ('debug' shows process-matching decisions)",
    )
    ap.add_argument(
        "--check-only",
        action="store_true",
        help="Parse endpoints, print index, no write",
    )
    ap.add_argument(
        "--no-probe",
        action="store_true",
        help="Skip the live TCP probe of nodes before building the config",
    )
    ap.add_argument(
        "--probe-timeout",
        type=float,
        default=2.0,
        help="TCP probe connect timeout, seconds",
    )
    ap.add_argument(
        "--probe-out",
        type=Path,
        default=None,
        help=(
            "Write per-node TCP-probe latency as JSONL ({\"index\": 1, "
            "\"lat_ms\": 12|null}) for GUI node-quality previews"
        ),
    )
    ap.add_argument(
        "--probe-concurrency",
        type=int,
        default=16,
        help="Parallel probe threads (default: 16)",
    )
    ap.add_argument(
        "--no-http-probe",
        action="store_true",
        help="Skip the per-node HTTP probe (B-010); rely on TCP probe/name filter only",
    )
    ap.add_argument(
        "--http-probe-timeout",
        type=float,
        default=PROBE_TIMEOUT,
        help="Per-node HTTP request timeout+startup wait in seconds (default: 5.0)",
    )
    ap.add_argument(
        "--http-probe-anthropic",
        default=PROBE_DEFAULT_ANTHROPIC_OK,
        help="Space/comma-separated acceptable statuses for api.anthropic.com (default: 401)",
    )
    ap.add_argument(
        "--http-probe-youtube",
        default=PROBE_DEFAULT_YOUTUBE_OK,
        help="Space/comma-separated acceptable statuses for www.youtube.com (default: 200)",
    )
    ap.add_argument(
        "--http-probe-cache-ttl",
        type=float,
        default=PROBE_CACHE_TTL_HOURS,
        help="Hours to reuse a passed node without re-probing (default: 6.0)",
    )
    ap.add_argument(
        "--xray-port",
        type=int,
        default=DEFAULT_XRAY_PORT,
        help="Local SOCKS port for the Xray-managed xhttp/splithttp pool (default: 2081)",
    )
    ap.add_argument(
        "--no-xray",
        action="store_true",
        help=(
            "Drop xhttp/splithttp nodes entirely instead of routing them "
            "through Xray-core (old behavior, pre-B-007 fix; use if Xray is "
            "unavailable and you would rather have a clean sing-box-only pool)"
        ),
    )
    args = ap.parse_args()

    sub_cache = (args.state_dir or args.out.parent) / "last-subscription.txt"
    nodes, active = load_endpoints(
        args.endpoints, fetch_subs=args.fetch, sub_cache=sub_cache
    )
    if args.no_xray:
        dropped = [n for n in nodes if n["meta"].get("engine") == "xray"]
        if dropped:
            print(
                f"INFO: --no-xray: dropping {len(dropped)} xhttp/splithttp node(s)",
                file=sys.stderr,
            )
        old_active_node = nodes[active - 1] if 0 < active <= len(nodes) else None
        kept_nodes = [n for n in nodes if n["meta"].get("engine") != "xray"]
        if not kept_nodes:
            raise RuntimeError(
                "--no-xray dropped every node (subscription is xhttp-only); "
                "remove --no-xray or add sing-box-compatible nodes"
            )
        nodes = kept_nodes
        # Re-anchor ACTIVE to the (possibly shorter, possibly reindexed) list.
        if old_active_node is not None and any(n is old_active_node for n in nodes):
            active = next(i for i, n in enumerate(nodes) if n is old_active_node) + 1
        else:
            active = 1

    _pol = load_policy(args.policy)
    _auto_on = str(_pol["auto"].get("enabled", "yes")).strip().lower() in {
        "yes",
        "true",
        "1",
        "on",
    }

    # --- optional country lock ([auto-select] countries = US,GB) ------------
    # A temporary exit-country pin, e.g. while paying for a service with a US
    # card. Applied here, before the probes and before both config builders,
    # so the TCP probe, the B-010 HTTP probe, the urltest pool AND the
    # xray-managed xhttp pool all see only allowed countries (and ACTIVE keeps
    # pointing at the same node if it survived the filter). Empty = no filter.
    countries_raw = str(_pol["auto"].get("countries", "")).strip()
    if countries_raw:
        wanted = {c.strip().upper() for c in countries_raw.split(",") if c.strip()}
        if not wanted:
            raise RuntimeError(
                "countries in policy.conf is not empty but parses to nothing "
                "(comma-separated ISO codes, e.g. countries = US, GB)"
            )
        kept_nodes: list[dict[str, Any]] = []
        for node in nodes:
            code = _node_iso2(str((node.get("meta") or {}).get("name") or ""))
            if code in wanted:
                kept_nodes.append(node)
            else:
                print(
                    f"INFO: countries={','.join(sorted(wanted))}: исключена нода "
                    f"'{node['meta'].get('name')}' (страна: {code or '?'})",
                    file=sys.stderr,
                )
        if not kept_nodes:
            raise RuntimeError(
                "countries filter removed every node "
                f"(allowed: {','.join(sorted(wanted))}); проверьте имена нод "
                "в --check-only или уберите строку countries из policy.conf"
            )
        old_active_node = nodes[active - 1] if 0 < active <= len(nodes) else None
        nodes = kept_nodes
        # Re-anchor ACTIVE against the reduced list (same rule as --no-xray and
        # the B-010 filter): keep the pinned node if it survived, else #1.
        if old_active_node is not None and any(n is old_active_node for n in nodes):
            active = next(i for i, n in enumerate(nodes) if n is old_active_node) + 1
        else:
            active = 1
        print(
            f"...после фильтра по странам {','.join(sorted(wanted))}: "
            f"осталось {len(nodes)} нод",
            file=sys.stderr,
        )

    probe: dict[int, int | None] | None = None
    if not args.check_only and not args.no_probe:
        print("Проверяю живость нод (TCP)...", file=sys.stderr)
        probe = probe_nodes(nodes, timeout=args.probe_timeout, concurrency=args.probe_concurrency)
        alive = [
            (probe[i], i + 1, n["meta"]["name"])
            for i, n in enumerate(nodes)
            if probe.get(i) is not None
        ]
        print(f"...живых {len(alive)}/{len(nodes)}", file=sys.stderr)
        if alive:
            alive_sorted = sorted(alive, key=lambda t: t[0])
            best_i, best_lat, best_name = alive_sorted[0]
            print(
                f"...быстрейшая: #{best_i} {best_name} — {best_lat} мс",
                file=sys.stderr,
            )
        # With auto-select disabled, ACTIVE is a single pinned node: if it is
        # dead, fall back to the fastest live one instead of silently running
        # on a node that cannot carry a byte.
        if not _auto_on and probe.get(active - 1) is None:
            alive_idx = [
                (probe[i], i + 1) for i in range(len(nodes)) if probe.get(i) is not None
            ]
            if alive_idx:
                alive_idx.sort(key=lambda t: t[0])
                old, active = active, alive_idx[0][1]
                print(
                    f"WARN: ACTIVE #{old} не отвечает — выбираю живую ноду "
                    f"#{active} ({alive_idx[0][0]} мс)",
                    file=sys.stderr,
                )

    # --- B-010: per-node HTTP probe (re-filter the live pool by actual API
    # access, not just TCP reachability) --------------------------------------
    # A node that passes the TCP ping can still be blocked upstream (403 on
    # Anthropic) or fail YouTube (redirect/consent) — exactly the churn that
    # makes a static endpoints.txt stale within days. Dial Anthropic + YouTube
    # through a throwaway sing-box instance per node and keep only nodes that
    # answer as expected. This is the "auto-refilter at each build" step.
    passing: set[int] = set()
    http_verdict: dict[int, tuple[int | None, int | None]] | None = None
    if not args.check_only and not args.no_http_probe:
        sing_box = find_sing_box()
        xray_bin = None if args.no_xray else find_xray()
        if sing_box is None:
            print(
                "WARN: sing-box не найден — пропускаю HTTP-проверку нод "
                "(B-010); полагаюсь на TCP-probe и ручной фильтр",
                file=sys.stderr,
            )
        else:
            if xray_bin is None and any(n["meta"].get("engine") == "xray" for n in nodes):
                print(
                    "WARN: xray не найден — xhttp/splithttp-ноды не пройдут "
                    "HTTP-проверку (см. B-007); установите xray-core или "
                    "передайте --no-xray",
                    file=sys.stderr,
                )
            cache_path = (args.state_dir or args.out.parent) / "node-probe-cache.json"
            passing, http_verdict = probe_nodes_http(
                nodes,
                sing_box,
                xray=xray_bin,
                timeout=args.http_probe_timeout,
                anthropic_ok=args.http_probe_anthropic,
                youtube_ok=args.http_probe_youtube,
                cache_path=cache_path,
                cache_ttl_hours=args.http_probe_cache_ttl,
            )
            if not passing:
                print(
                    "WARN: ни одна нода не прошла HTTP-проверку — "
                    "оставляю весь список (без фильтра B-010)",
                    file=sys.stderr,
                )
            elif len(passing) != len(nodes):
                kept = len(nodes)
                old_active_node = nodes[active - 1] if 0 < active <= len(nodes) else None
                passing_sorted = sorted(passing)
                nodes = [nodes[i] for i in passing_sorted]
                if probe is not None:
                    probe = {j: probe[old_i] for j, old_i in enumerate(passing_sorted)}
                # Recompute ACTIVE against the reduced list: map the previously
                # pinned node to its new position; if it was filtered out, fall
                # back to the first surviving node.
                if old_active_node is not None and any(n is old_active_node for n in nodes):
                    active = next(i for i, n in enumerate(nodes) if n is old_active_node) + 1
                else:
                    active = 1
                print(
                    f"...после HTTP-проверки осталось {len(nodes)}/{kept} нод",
                    file=sys.stderr,
                )

    # Record render telemetry (B-015). `nodes`/`probe` are already in their
    # final filtered order here; HTTP verdicts are keyed by original index and
    # `passing` maps them back onto the surviving list.
    if not args.check_only:
        _record_render_stats(
            nodes,
            active,
            probe,
            http_verdict,
            passing,
            state_dir=args.state_dir or args.out.parent,
        )

    meta = nodes[active - 1]["meta"]
    print(
        f"Active outbound #{active}/{len(nodes)}: "
        f"provider={meta.get('provider') or '-'} name={meta['name']} "
        f"{meta['server']}:{meta['server_port']} ({meta['security']}/{meta['network']})",
        file=sys.stderr,
    )

    if args.check_only:
        for i, n in enumerate(nodes, 1):
            m = n["meta"]
            mark = "*" if i == active else " "
            print(f"{mark}{i:3d}  {m.get('provider') or '-':12s}  {m['name']}")
        return 0

    cfg = build_config(
        nodes,
        active,
        mixed_port=args.mixed_port,
        enable_tun=not args.no_tun,
        use_rule_sets=not args.no_rule_sets,
        tun_stack=args.tun_stack,
        tun_name=args.tun_name,
        log_level=args.log_level,
        default_interface=args.default_interface,
        state_dir=args.state_dir,
        policy_path=args.policy,
        probe=probe,
        xray_port=args.xray_port,
    )

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(
        json.dumps(cfg, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    # Sibling Xray-core config for the xhttp/splithttp pool (B-007). Written
    # even when empty is not desired: absence of this file is exactly how
    # the Windows launcher decides whether to start xray.exe at all.
    xray_nodes_final = [n for n in nodes if n["meta"].get("engine") == "xray"]
    xray_config_path = args.out.parent / "xray-config.json"
    if xray_nodes_final:
        xray_cfg = build_xray_config(xray_nodes_final, args.xray_port)
        xray_config_path.write_text(
            json.dumps(xray_cfg, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        print(
            f"Wrote {xray_config_path} ({len(xray_nodes_final)} xhttp/splithttp node(s), "
            f"port {args.xray_port})",
            file=sys.stderr,
        )
    elif xray_config_path.is_file():
        # No xray-managed nodes survived this render — remove the stale file
        # so the launcher does not start xray.exe pointed at a dead pool.
        xray_config_path.unlink()

    index_path = args.out.parent / "outbounds.jsonl"
    with index_path.open("w", encoding="utf-8") as fh:
        for i, n in enumerate(nodes, 1):
            row = {"index": i, "active": i == active, **n["meta"]}
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")

    # Per-node latency report for UI previews (B-019), index = outbounds.jsonl
    # index (1-based), lat_ms = null when the TCP probe timed out ("dead").
    # Written from the FINAL (filtered/reindexed) list, so it always lines up
    # with outbounds.jsonl even after the B-010 HTTP filter reorders nodes.
    if args.probe_out and probe is not None:
        probe_out_path = Path(args.probe_out)
        with probe_out_path.open("w", encoding="utf-8") as fh:
            for i, _node in enumerate(nodes, 1):
                fh.write(json.dumps({"index": i, "lat_ms": probe.get(i - 1)}) + "\n")
        print(
            f"Wrote {probe_out_path} ({len(nodes)} probe result(s))",
            file=sys.stderr,
        )

    print(f"Wrote {args.out}", file=sys.stderr)
    print(f"Wrote {index_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001 — CLI boundary
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
