#!/usr/bin/env python3
import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

import boto3
from botocore.exceptions import BotoCoreError, ClientError


def extract_account_id_from_arn(arn: str) -> str | None:
    """Extract a 12-digit AWS account ID from a standard ARN, or return None."""
    # arn:partition:service:region:account-id:resource
    m = re.match(r"^arn:[^:]+:[^:]+:[^:]*:(\d{12}):.+$", arn)
    return m.group(1) if m else None


def try_print_caller_identity(region: str | None):
    """Best-effort print of the active AWS identity (useful for debugging auth)."""
    try:
        session_kwargs = {}
        if region:
            session_kwargs["region_name"] = region
        sts = boto3.client("sts", **session_kwargs)
        ident = sts.get_caller_identity()
        arn = ident.get("Arn")
        account = ident.get("Account")
        user_id = ident.get("UserId")
        print(f"AWS caller identity: Account={account} Arn={arn} UserId={user_id}")
        return ident
    except Exception as e:
        print(f"(debug) Unable to fetch AWS caller identity via STS: {e}")
        return None


def load_existing_token(path: Path):
    """Return (meta_dict, raw_contents) or (None, None) if missing/invalid."""
    if not path.exists():
        return None, None

    raw = path.read_text().strip()
    try:
        meta = json.loads(raw)
        # must at least have token + expirationTime
        if "token" in meta and "expirationTime" in meta:
            return meta, raw
    except json.JSONDecodeError:
        pass

    # Unknown / legacy format; treat as expired but preserve contents for rename
    return None, raw


def is_token_valid(meta: dict, safety_margin_seconds: int = 300) -> bool:
    """
    Returns True if token is still valid, with a safety margin.
    meta["expirationTime"] is ISO 8601 string from IVS.
    """
    try:
        exp = meta["expirationTime"]
        # boto3 returns a datetime in the response object, but if we persisted it
        # as a string we parse it here.
        if isinstance(exp, str):
            # Handles formats like '2025-12-11T10:30:00+00:00'
            expiration = datetime.fromisoformat(exp)
        elif isinstance(exp, datetime):
            expiration = exp
        else:
            return False

        if expiration.tzinfo is None:
            expiration = expiration.replace(tzinfo=timezone.utc)

        now = datetime.now(timezone.utc)
        return now + timedelta(seconds=safety_margin_seconds) < expiration
    except Exception:
        return False


def create_new_token(
    stage_arn: str,
    duration_minutes: int,
    region: str | None,
    user_id: str | None,
    capabilities: list[str] | None,
) -> dict:
    """
    Calls IVS Real-Time CreateParticipantToken and returns the participantToken dict.
    """
    session_kwargs = {}
    if region:
        session_kwargs["region_name"] = region

    client = boto3.client("ivs-realtime", **session_kwargs)

    kwargs = {
        "stageArn": stage_arn,
        "duration": duration_minutes,
    }
    if user_id:
        kwargs["userId"] = user_id
    if capabilities:
        kwargs["capabilities"] = capabilities

    resp = client.create_participant_token(**kwargs)
    return resp["participantToken"]


def backup_old_file(path: Path, old_raw: str | None):
    """Rename existing token file to token.<timestamp>.bak, preserving contents."""
    if not path.exists():
        return
    ts = datetime.now().strftime("%Y%m%dT%H%M%S")
    backup_path = path.with_name(f"{path.name}.{ts}.bak")
    # Either rename the file, or rewrite content (to be robust if old_raw given)
    try:
        path.rename(backup_path)
    except OSError:
        # Fallback: write backup separately
        backup_path.write_text(old_raw or "")


def write_new_token(path: Path, stage_arn: str, participant_token: dict):
    """
    Persist token + metadata as JSON:
    {
        "stageArn": "...",
        "token": "...",
        "participantId": "...",
        "expirationTime": "...ISO...",
        "duration": 720,
        "capabilities": [...],
        "userId": "..."
    }
    """
    # expirationTime is a datetime in boto3, convert to ISO string
    exp = participant_token.get("expirationTime")
    if isinstance(exp, datetime):
        exp_str = exp.astimezone(timezone.utc).isoformat()
    else:
        exp_str = str(exp)

    meta = {
        "stageArn": stage_arn,
        "token": participant_token.get("token"),
        "participantId": participant_token.get("participantId"),
        "expirationTime": exp_str,
        "duration": participant_token.get("duration"),
        "capabilities": participant_token.get("capabilities"),
        "userId": participant_token.get("userId"),
    }

    path.write_text(json.dumps(meta, indent=2))


def parse_args():
    parser = argparse.ArgumentParser(
        description="Refresh Amazon IVS Real-Time participant token file if expired."
    )
    parser.add_argument(
        "--stage-arn",
        required=True,
        help="ARN of the IVS Real-Time stage (arn:aws:ivs:region:acct:stage/...).",
    )
    parser.add_argument(
        "--token-file",
        required=True,
        help="Path to JSON file containing token + metadata.",
    )
    parser.add_argument(
        "--duration-minutes",
        type=int,
        required=True,
        help=(
            "Token duration in minutes (1–20160). "
            "Matches the CreateParticipantToken 'duration' parameter."
        ),
    )
    parser.add_argument(
        "--region",
        help="AWS region for IVS (otherwise uses usual AWS defaults).",
    )
    parser.add_argument(
        "--user-id",
        help="Optional userId label to embed in the token.",
    )
    parser.add_argument(
        "--capability",
        action="append",
        choices=["PUBLISH", "SUBSCRIBE"],
        help=(
            "Optional capabilities. Specify multiple times, e.g. "
            "--capability PUBLISH --capability SUBSCRIBE. "
            "Default is both if omitted."
        ),
    )
    parser.add_argument(
        "--no-safety-margin",
        action="store_true",
        help="Skip the 5-minute safety margin when checking expiry.",
    )
    return parser.parse_args()


from datetime import timedelta  # import here to avoid clutter at top


def main():
    args = parse_args()
    token_path = Path(args.token_file)

    # Harden: ensure the target directory exists (common case: /run/audiostream on Linux).
    # If it doesn't exist, attempt to create it; otherwise fail with a clear error.
    if token_path.exists() and token_path.is_dir():
        print(
            f"ERROR: token-file points to a directory, not a file: {token_path}",
            file=sys.stderr,
        )
        sys.exit(1)

    token_dir = token_path.parent
    if not token_dir.exists():
        try:
            token_dir.mkdir(parents=True, exist_ok=True)
            print(f"Created missing directory: {token_dir}")
        except OSError as e:
            print(
                f"ERROR: token-file directory does not exist and could not be created: {token_dir}\n"
                f"Reason: {e}",
                file=sys.stderr,
            )
            sys.exit(1)

    if not token_dir.is_dir():
        print(
            f"ERROR: token-file parent is not a directory: {token_dir}",
            file=sys.stderr,
        )
        sys.exit(1)

    stage_account = extract_account_id_from_arn(args.stage_arn)
    if stage_account is None:
        print(
            "ERROR: stage-arn does not look like a valid ARN with a 12-digit account ID.\n"
            f"Got: {args.stage_arn}",
            file=sys.stderr,
        )
        sys.exit(1)

    if args.duration_minutes < 1 or args.duration_minutes > 20160:
        # 20160 minutes = 14 days :contentReference[oaicite:0]{index=0}
        print("ERROR: duration-minutes must be between 1 and 20160.", file=sys.stderr)
        sys.exit(1)

    safety_margin = 0 if args.no_safety_margin else 300

    meta, old_raw = load_existing_token(token_path)
    if meta and is_token_valid(meta, safety_margin_seconds=safety_margin):
        # Already good, nothing to do
        print("Existing token is still valid; no refresh needed.")
        print("Token:", meta["token"])
        return

    # Need a new token
    print("Existing token missing/invalid/expired; creating a new one...")

    capabilities = args.capability
    if not capabilities:
        capabilities = ["PUBLISH", "SUBSCRIBE"]

    try:
        pt = create_new_token(
            stage_arn=args.stage_arn,
            duration_minutes=args.duration_minutes,
            region=args.region,
            user_id=args.user_id,
            capabilities=capabilities,
        )
    except (BotoCoreError, ClientError) as e:
        print(f"ERROR: Failed to create participant token: {e}", file=sys.stderr)
        print(f"(debug) Stage account from ARN: {stage_account}", file=sys.stderr)
        ident = try_print_caller_identity(args.region)
        if ident and ident.get("Account") and ident.get("Account") != stage_account:
            print(
                "(hint) Your active AWS credentials are for a different account than the stage ARN.\n"
                f"       credentials account: {ident.get('Account')}\n"
                f"       stage ARN account:   {stage_account}",
                file=sys.stderr,
            )
        sys.exit(2)

    # Backup old file (if existed), then write new one
    backup_old_file(token_path, old_raw)
    write_new_token(token_path, args.stage_arn, pt)

    print(f"New token written to {token_path}")
    print("Token:", pt["token"])


if __name__ == "__main__":
    main()
