#!/usr/bin/env python3
"""Small helper to send Sentry events from shell/systemd-managed processes.

Designed for use by start_camilladsp-whip.sh to report:
- Process exits (camilladsp/whip-client)
- Reconnect loops / repeated failures
- Script-level errors via bash trap

Configuration is via environment variables:
- SENTRY_DSN (required)
- SENTRY_ENVIRONMENT (optional)
- SENTRY_RELEASE (optional)
- SENTRY_SERVER_NAME (optional)

This intentionally does not automatically capture all local vars/env;
use --extra/--tag explicitly from callers.
"""

from __future__ import annotations

import argparse
import os
import sys
from typing import Dict, List, Optional


def _parse_kv_list(items: Optional[List[str]]) -> Dict[str, str]:
    out: Dict[str, str] = {}
    if not items:
        return out
    for item in items:
        if "=" not in item:
            raise SystemExit(f"Invalid key/value (expected k=v): {item}")
        k, v = item.split("=", 1)
        k = k.strip()
        if not k:
            raise SystemExit(f"Invalid empty key in: {item}")
        out[k] = v
    return out


def _bool_env(name: str, default: bool = False) -> bool:
    val = os.getenv(name)
    if val is None:
        return default
    return val.strip().lower() in {"1", "true", "yes", "y", "on"}


def main() -> int:
    parser = argparse.ArgumentParser(description="Send a Sentry event from CLI")
    parser.add_argument("--level", default="error", choices=["fatal", "error", "warning", "info"])
    parser.add_argument("--message", required=True, help="Event message")
    parser.add_argument("--logger", default="soundscape", help="Logger name")
    parser.add_argument("--tag", action="append", help="Tags: k=v", default=[])
    parser.add_argument("--extra", action="append", help="Extra data: k=v", default=[])
    parser.add_argument("--fingerprint", action="append", default=[], help="Fingerprint item; repeat to build list")
    parser.add_argument("--attach", help="Optional path to attach (e.g. log tail file)")

    args = parser.parse_args()

    dsn = os.getenv("SENTRY_DSN")
    if not dsn:
        # Silently no-op when Sentry isn't configured.
        return 0

    try:
        import sentry_sdk
    except Exception as e:
        print(f"sentry_event.py: sentry-sdk not available: {e}", file=sys.stderr)
        return 0

    # Keep traffic minimal: we use this as an error reporter, not a log shipper.
    sentry_sdk.init(
        dsn=dsn,
        environment=os.getenv("SENTRY_ENVIRONMENT"),
        release=os.getenv("SENTRY_RELEASE"),
        server_name=os.getenv("SENTRY_SERVER_NAME"),
        debug=_bool_env("SENTRY_SDK_DEBUG", False),
        traces_sample_rate=0.0,
        send_default_pii=False,
        max_breadcrumbs=20,
    )

    tags = _parse_kv_list(args.tag)
    extras = _parse_kv_list(args.extra)

    # Basic secret scrubbing: callers should avoid passing secrets, but also defend here.
    def _scrub(s: str) -> str:
        lowered = s.lower()
        if "token" in lowered or "authorization" in lowered or "secret" in lowered:
            return "[redacted]"
        return s

    with sentry_sdk.new_scope() as scope:
        scope.set_tag("component", "soundscape")
        for k, v in tags.items():
            scope.set_tag(k, _scrub(v))
        for k, v in extras.items():
            scope.set_extra(k, _scrub(v))
        if args.fingerprint:
            scope.fingerprint = args.fingerprint
        if args.attach and os.path.exists(args.attach):
            scope.add_attachment(path=args.attach)

        # Allow opt-in debug printing
        if _bool_env("SENTRY_EVENT_DEBUG", False):
            print(
                f"sentry_event.py: sending level={args.level} msg={args.message!r} attach={args.attach!r}",
                file=sys.stderr,
            )

        sentry_sdk.capture_message(
            message=args.message,
            level=args.level,
        )
        sentry_sdk.flush(timeout=2.0)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
