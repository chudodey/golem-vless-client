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
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
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
}


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


def _split_domains(entries: list[str]) -> tuple[list[str], list[str]]:
    """Split entries into exact domains and suffix matches ('.example.com')."""
    domains: list[str] = []
    suffixes: list[str] = []
    for raw in entries:
        entry = raw.strip().lower()
        if not entry:
            continue
        if entry.startswith("."):
            suffixes.append(entry.lstrip("."))
        else:
            domains.append(entry)
    return domains, suffixes


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
        decoded = base64.b64decode(padded, validate=False).decode("utf-8", errors="replace")
    except Exception:
        return []
    return [ln.strip() for ln in decoded.splitlines() if ln.strip().startswith("vless://")]


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
        decoded = base64.b64decode(padded, validate=False).decode("utf-8", errors="replace")
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


def _qbool(params: dict[str, list[str]], key: str, default: bool = False) -> bool:
    vals = params.get(key)
    if not vals:
        return default
    return vals[0].lower() in ("1", "true", "yes", "on")


def _q(params: dict[str, list[str]], key: str, default: str | None = None) -> str | None:
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
    name = urllib.parse.unquote(parsed.fragment) if parsed.fragment else f"{host}:{port}"
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
            "service_name": _q(params, "serviceName") or _q(params, "service_name") or "",
        }
    elif network == "http":
        outbound["transport"] = {
            "type": "http",
            "path": _q(params, "path") or "/",
            "host": [h for h in (_q(params, "host") or host).split(",") if h],
        }
    elif network in ("tcp", "raw"):
        header_type = (_q(params, "headerType") or _q(params, "header_type") or "").lower()
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
        # sing-box 1.10+ may use "xhttp"; keep as tcp+tls if unsupported later
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
        "uri_preview": re.sub(r"vless://[^@]+@", "vless://***@", uri)[:120],
    }
    return {"outbound": outbound, "meta": meta}


def load_endpoints(path: Path, fetch_subs: bool) -> tuple[list[dict[str, Any]], int]:
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
                print(f"WARN: skip subscription (use --fetch): {line[:60]}...", file=sys.stderr)
                continue
            try:
                uris = _fetch_subscription(line)
                print(f"INFO: subscription fetched {len(uris)} vless URI(s) from {line[:60]}", file=sys.stderr)
            except (urllib.error.URLError, TimeoutError, ValueError) as exc:
                raise RuntimeError(f"subscription fetch failed: {line[:80]}: {exc}") from exc
        else:
            # Subscription body pasted directly (base64 blob), for when DPI
            # blocks fetching the subscription URL from this network.
            uris = _decode_base64_blob(line)
            if uris:
                print(f"INFO: decoded {len(uris)} vless URI(s) from pasted base64", file=sys.stderr)
            else:
                print(f"WARN: ignore line: {line[:80]}", file=sys.stderr)
                continue

        for uri in uris:
            try:
                collected.append(parse_vless_uri(uri, provider=provider))
            except ValueError as exc:
                print(f"WARN: skip bad URI ({exc})", file=sys.stderr)

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
    state_dir: Path | None = None,
    policy_path: Path = POLICY_PATH,
) -> dict[str, Any]:
    chosen = nodes[active - 1]

    policy = load_policy(policy_path)
    auto = policy["auto"]
    auto_on = str(auto.get("enabled", "yes")).strip().lower() in {"yes", "true", "1", "on"}

    proxy_domains, proxy_suffixes = _split_domains(policy["proxy_domains"])
    direct_domains, direct_suffixes = _split_domains(policy["direct_domains"])

    # --- outbound(s): either one fixed node, or a latency-raced pool ---------
    proxy_outbounds: list[dict[str, Any]] = []
    if auto_on and len(nodes) > 1:
        try:
            candidates = max(2, int(str(auto.get("candidates", "12")).strip()))
        except ValueError:
            candidates = 12
        try:
            tolerance = int(str(auto.get("tolerance", "50")).strip())
        except ValueError:
            tolerance = 50
        pool = nodes[:candidates]
        member_tags: list[str] = []
        for idx, node in enumerate(pool, start=1):
            ob = dict(node["outbound"])
            # Readable tag ("03 Germany") so `vpnctl nodes` shows the country
            # instead of an opaque index. Emoji/flags are stripped: they break
            # column alignment in the terminal.
            raw_name = str((node.get("meta") or {}).get("name") or "").strip()
            clean = "".join(ch for ch in raw_name if ch.isalnum() or ch in " -_").strip()
            clean = " ".join(clean.split())
            # Provider labels the first node "Auto → [Оптимальная локация]";
            # keep just "Auto" so the column stays readable.
            if clean.lower().startswith("auto"):
                clean = "Auto"
            clean = clean[:20]
            ob["tag"] = f"{idx:02d} {clean}".strip() if clean else f"node-{idx:02d}"
            proxy_outbounds.append(ob)
            member_tags.append(ob["tag"])
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
        single = dict(chosen["outbound"])
        single["tag"] = "proxy"
        proxy_outbounds.append(single)

    dns: dict[str, Any] = {
        "servers": [
            {"tag": "dns-direct", "address": "local", "detour": "direct"},
            {
                "tag": "dns-remote",
                "address": "https://1.1.1.1/dns-query",
                "detour": "proxy",
            },
        ],
        "strategy": "prefer_ipv4",
        "final": "dns-direct",
    }

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
                "sniff": True,
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
    proc_names = [p for p in policy["processes"] if "/" not in p]
    proc_paths = [p for p in policy["processes"] if "/" in p]
    if proc_names:
        route_rules.append(route_to("proxy", process_name=proc_names))
    if proc_paths:
        route_rules.append(route_to("proxy", process_path=proc_paths))

    if direct_domains:
        route_rules.append(route_to("direct", domain=direct_domains))
    if direct_suffixes:
        route_rules.append(route_to("direct", domain_suffix=direct_suffixes))
    if proxy_domains:
        route_rules.append(route_to("proxy", domain=proxy_domains))
    if proxy_suffixes:
        route_rules.append(route_to("proxy", domain_suffix=proxy_suffixes))

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
            {"domain": proxy_domains, "server": "dns-remote"} if proxy_domains else None,
            {"domain_suffix": proxy_suffixes, "server": "dns-remote"} if proxy_suffixes else None,
        ]
        dns["rules"] = [r for r in dns["rules"] if r]

    route: dict[str, Any] = {
        "rules": route_rules,
        "final": "direct",
        "auto_detect_interface": True,
    }
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


def main() -> int:
    ap = argparse.ArgumentParser(description="Render a sing-box config from endpoints.txt + policy.conf")
    ap.add_argument("--endpoints", type=Path, default=SECRETS, help="Path to endpoints.txt")
    ap.add_argument("--policy", type=Path, default=POLICY_PATH, help="Path to policy.conf")
    ap.add_argument("--out", type=Path, default=OUT_CONFIG, help="Where to write config.json")
    ap.add_argument(
        "--state-dir",
        type=Path,
        default=None,
        help="Durable dir for sing-box's own cache.db (default: next to --out)",
    )
    ap.add_argument("--fetch", action="store_true", help="Fetch https subscription URLs")
    ap.add_argument("--no-tun", action="store_true", help="Only mixed SOCKS/HTTP on localhost")
    ap.add_argument("--no-rule-sets", action="store_true", help="Skip remote geosite/geoip")
    ap.add_argument("--mixed-port", type=int, default=DEFAULT_MIXED_PORT)
    ap.add_argument("--tun-name", default=DEFAULT_TUN_NAME, help="TUN interface name")
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
    ap.add_argument("--check-only", action="store_true", help="Parse endpoints, print index, no write")
    args = ap.parse_args()

    nodes, active = load_endpoints(args.endpoints, fetch_subs=args.fetch)
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
        state_dir=args.state_dir,
        policy_path=args.policy,
    )

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(cfg, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    index_path = args.out.parent / "outbounds.jsonl"
    with index_path.open("w", encoding="utf-8") as fh:
        for i, n in enumerate(nodes, 1):
            row = {"index": i, "active": i == active, **n["meta"]}
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")

    print(f"Wrote {args.out}", file=sys.stderr)
    print(f"Wrote {index_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001 — CLI boundary
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
