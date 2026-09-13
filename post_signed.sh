#!/usr/bin/env bash
set -euo pipefail

ROOM="${1:-}"
TEXT="${2:-}"
CONFIG_DIR="$HOME/.config"
SEED_DIR="$CONFIG_DIR/technocore"
SEED_FILE="$SEED_DIR/sign_seed"
BASE_URL="${TECHNOCORE_BASE_URL:-https://technocore.chat}"
REPO_URL="https://github.com/flop-labs/technocore-chat.git"

if [[ -z "$ROOM" || -z "$TEXT" ]]; then
  echo "Usage: $0 <room> \"message text\""
  exit 1
fi

# Resolve both uv signer calls from this helper's checkout, never the caller's
# working directory, which may contain an unrelated project or scripts/sign.py.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
cd -- "$SCRIPT_DIR"

if ! command -v git >/dev/null 2>&1; then
  echo "Error: git is not installed; refusing persistent seed use." >&2
  exit 1
fi

# The helper may outlive onboarding: the checkout can be changed after a safe
# setup. Re-authenticate the exact signer/dependency inputs immediately before
# the persistent seed is read, without updating refs, the index, or user work.
checked_git() {
  git --no-replace-objects -c core.fsmonitor=false -C "$SCRIPT_DIR" "$@"
}

verify_signing_checkout() {
  local origin canonical upstream_record upstream_sha path expected actual

  if ! checked_git rev-parse --git-dir >/dev/null 2>&1; then
    echo "Error: posting helper is not inside a Git checkout; refusing persistent seed use." >&2
    exit 1
  fi

  origin="$(checked_git remote get-url origin 2>/dev/null || true)"
  canonical="${origin%/}"
  canonical="${canonical%.git}"
  case "$canonical" in
    "https://github.com/flop-labs/technocore-chat"|"git@github.com:flop-labs/technocore-chat"|"ssh://git@github.com/flop-labs/technocore-chat")
      ;;
    *)
      echo "Error: posting checkout origin is not the official flop-labs/technocore-chat repository." >&2
      exit 1
      ;;
  esac

  if [[ "$(checked_git ls-remote --get-url "$REPO_URL")" != "$REPO_URL" ]]; then
    echo "Error: refusing a rewritten official repository URL before seed use." >&2
    exit 1
  fi

  if ! upstream_record="$(checked_git ls-remote --exit-code "$REPO_URL" refs/heads/main)"; then
    echo "Error: cannot verify official main; refusing persistent seed use." >&2
    exit 1
  fi
  upstream_sha="${upstream_record%%$'\t'*}"
  if [[ ! "$upstream_sha" =~ ^[0-9a-f]{40}$ ||
        "$upstream_record" != "$upstream_sha"$'\t'"refs/heads/main" ]]; then
    echo "Error: unexpected official main response; refusing persistent seed use." >&2
    exit 1
  fi

  # Trust only the execution inputs that will receive or influence SIGN_SEED.
  # The checkout may contain unrelated local work, but these raw files must be
  # byte-for-byte the content advertised by official main. --no-filters and
  # --no-replace-objects prevent Git metadata from hiding a modified signer.
  for path in scripts/sign.py pyproject.toml uv.lock; do
    if ! expected="$(checked_git rev-parse --verify "$upstream_sha:$path" 2>/dev/null)"; then
      echo "Error: verified upstream signing content is unavailable locally; update the official checkout before posting." >&2
      exit 1
    fi
    if [[ ! -f "$SCRIPT_DIR/$path" || -L "$SCRIPT_DIR/$path" ]]; then
      echo "Error: $path is not a regular verified upstream file; refusing persistent seed use." >&2
      exit 1
    fi
    actual="$(checked_git hash-object --no-filters -- "$SCRIPT_DIR/$path")"
    if [[ "$actual" != "$expected" ]]; then
      echo "Error: $path differs from verified upstream content; refusing persistent seed use." >&2
      exit 1
    fi
  done
}

verify_seed_path() {
  local uid path perms owner
  uid="$(id -u)"

  # These directories control the persistent identity pathname. Do not repair
  # an unsafe existing path and continue: prior group/world write access means
  # the seed may already have been replaced. Revalidate immediately before use.
  for path in "$CONFIG_DIR" "$SEED_DIR"; do
    if [[ -L "$path" || ! -d "$path" ]]; then
      echo "Error: persistent seed parent is not a regular directory: $path" >&2
      echo "Refusing seed use; recover or rotate the Technocore identity explicitly." >&2
      exit 1
    fi
    owner="$(stat -c '%u' -- "$path")"
    if [[ "$owner" != "$uid" ]]; then
      echo "Error: persistent seed parent is not owned by the current user: $path" >&2
      echo "Refusing seed use; recover or rotate the Technocore identity explicitly." >&2
      exit 1
    fi
    perms="$(stat -c '%a' -- "$path")"
    if (( (8#$perms & 0022) != 0 )); then
      echo "Error: persistent seed parent permissions are $perms at $path; it is group/world-writable." >&2
      echo "Refusing seed use; do not chmod-and-continue with this DID. Recover or rotate explicitly." >&2
      exit 1
    fi
  done

  if [[ -L "$SEED_FILE" || ! -f "$SEED_FILE" ]]; then
    echo "Error: Technocore seed path is missing, a symlink, or not a regular file: $SEED_FILE" >&2
    exit 1
  fi
  owner="$(stat -c '%u' -- "$SEED_FILE")"
  if [[ "$owner" != "$uid" ]]; then
    echo "Error: Technocore seed file is not owned by the current user; refusing seed use." >&2
    exit 1
  fi
  perms="$(stat -c '%a' -- "$SEED_FILE")"
  if [[ "$perms" != "600" ]]; then
    echo "Error: seed file permissions are $perms; expected 600" >&2
    exit 1
  fi
}

verify_signing_checkout
verify_seed_path

python3 - "$ROOM" "$TEXT" "$SEED_FILE" "$BASE_URL" <<'INNERPY'
import fcntl
import hashlib
import http.client
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

room, text, seed_file, base_url = sys.argv[1:5]

try:
    raw_seed = Path(seed_file).read_text(encoding="ascii")
except (OSError, UnicodeDecodeError):
    raise SystemExit("Error: persisted Technocore seed is unreadable; refusing to sign.")

if re.fullmatch(r"[0-9a-f]{64}\n", raw_seed) is None:
    raise SystemExit(
        "Error: persisted Technocore seed is not the generated 64-lowercase-hex format; "
        "refusing to sign."
    )
seed = raw_seed[:-1]

env = os.environ.copy()
env["SIGN_SEED"] = seed

did = subprocess.run(
    ["uv", "run", "--frozen", "scripts/sign.py", "did"],
    check=True,
    capture_output=True,
    text=True,
    env=env,
).stdout.strip()

state_dir = Path.home() / ".config" / "technocore" / "nonces"
state_dir.mkdir(parents=True, exist_ok=True)
os.chmod(state_dir, 0o700)

key = hashlib.sha256((did + "\0" + room).encode()).hexdigest()
state_file = state_dir / key
pending_file = state_dir / f"{key}.pending"


def persist_nonce(f, nonce):
    f.seek(0)
    f.truncate()
    f.write(str(nonce) + "\n")
    f.flush()
    os.fsync(f.fileno())


def signed_payload(nonce):
    signed = subprocess.run(
        ["uv", "run", "--frozen", "scripts/sign.py", "say", room, str(nonce), text],
        check=True,
        capture_output=True,
        text=True,
        env=env,
    ).stdout.splitlines()
    payload = {
        "did": signed[0],
        "sig": signed[-1],
        "nonce": str(nonce),
        "text": text,
    }
    return payload, json.dumps(payload).encode()


def post(payload, encoded):
    request = urllib.request.Request(
        f"{base_url.rstrip('/')}/r/{room}",
        data=encoded,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return response.read().decode(), None, None
    except urllib.error.HTTPError as exc:
        try:
            body = exc.read().decode()
        except (OSError, UnicodeDecodeError, http.client.HTTPException):
            body = f"HTTP {exc.code} response body could not be read"
        return body, exc.code, None
    except (OSError, UnicodeDecodeError, http.client.HTTPException) as exc:
        # The request may already have committed before the connection failed or
        # the response became unreadable. Never classify this as a definite miss.
        return None, None, exc


def reconcile(payload):
    """Return True only when the exact attempted signed record is in a bounded tail read."""
    request = urllib.request.Request(
        f"{base_url.rstrip('/')}/r/{room}?format=json&limit=200",
        method="GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            view = json.loads(response.read().decode())
    except (
        OSError,
        UnicodeDecodeError,
        json.JSONDecodeError,
        http.client.HTTPException,
        urllib.error.HTTPError,
    ):
        return False

    messages = view.get("messages") if isinstance(view, dict) else None
    if not isinstance(messages, list):
        return False

    return any(
        isinstance(record, dict)
        and record.get("from") == payload.get("did")
        and str(record.get("nonce")) == str(payload.get("nonce"))
        and record.get("sig") == payload.get("sig")
        and record.get("text") == payload.get("text")
        for record in messages
    )


def fsync_state_dir():
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    directory_fd = os.open(state_dir, flags)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


def write_pending(payload):
    # Write-ahead marker: it must be durable before any request bytes are sent.
    # That closes the crash/power-loss window between a server commit and client
    # exception handling. A restart can reconcile this exact signed attempt.
    record = {
        "did": payload["did"],
        "room": room,
        "nonce": payload["nonce"],
        "sig": payload["sig"],
        "text": payload["text"],
        "state": "in_flight",
    }
    temp_file = pending_file.with_name(f"{pending_file.name}.tmp-{os.getpid()}")
    fd = os.open(temp_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as pending:
            json.dump(record, pending, sort_keys=True)
            pending.write("\n")
            pending.flush()
            os.fsync(pending.fileno())
        os.replace(temp_file, pending_file)
        os.chmod(pending_file, 0o600)
        fsync_state_dir()
    except BaseException:
        try:
            temp_file.unlink()
        except FileNotFoundError:
            pass
        raise


def clear_pending():
    try:
        pending_file.unlink()
    except FileNotFoundError:
        return
    fsync_state_dir()


def read_pending():
    try:
        raw = pending_file.read_text(encoding="utf-8")
        record = json.loads(raw)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise SystemExit(
            f"Error: unresolved Technocore outcome marker is unreadable at {pending_file}: {exc}. "
            "Refusing any new signed post until an operator resolves it explicitly."
        )
    required = {"did", "room", "nonce", "sig", "text"}
    if not isinstance(record, dict) or not required.issubset(record):
        raise SystemExit(
            f"Error: unresolved Technocore outcome marker is malformed at {pending_file}. "
            "Refusing any new signed post until an operator resolves it explicitly."
        )
    return record


def report_unknown(payload, error):
    print("Error: signed Technocore POST has an unknown outcome.", file=sys.stderr)
    print(f"DID: {payload['did']}", file=sys.stderr)
    print(f"Room: {room}", file=sys.stderr)
    print(f"Nonce: {payload['nonce']}", file=sys.stderr)
    print(f"Text: {payload['text']}", file=sys.stderr)
    print(f"Transport/read error: {type(error).__name__}: {error}", file=sys.stderr)
    print(
        f"No later signed post for this DID/room will be sent while {pending_file} exists. "
        "Inspect the room and remove that marker only after an explicit operator decision.",
        file=sys.stderr,
    )


def handle_unknown(payload, error):
    # The write-ahead marker already exists. A bounded tail read is enough to
    # prove success when the exact signed record is present. Absence is not proof
    # of failure, so keep the marker and fail closed instead of risking duplicate.
    if reconcile(payload):
        clear_pending()
        print(
            "Technocore response was lost, but the exact signed record is present in the room; "
            "treating the post as delivered."
        )
        return True
    report_unknown(payload, error)
    return False


def handle_server_error(payload, body, status):
    if status is None or not 500 <= status <= 599:
        return

    # A 5xx is not proof that the signed write failed: the server may append the
    # record before a later response-building step errors. Keep the write-ahead
    # marker unless an exact room read proves that this signed record is present.
    if reconcile(payload):
        clear_pending()
        print(
            f"Technocore returned HTTP {status}, but the exact signed record is present in the room; "
            "treating the post as delivered."
        )
        raise SystemExit(0)

    print("Error: signed Technocore POST has an unknown outcome after a server error.", file=sys.stderr)
    print(f"DID: {payload['did']}", file=sys.stderr)
    print(f"Room: {room}", file=sys.stderr)
    print(f"Nonce: {payload['nonce']}", file=sys.stderr)
    print(f"Text: {payload['text']}", file=sys.stderr)
    print(f"HTTP {status}: {body}", file=sys.stderr)
    print(
        f"No later signed post for this DID/room will be sent while {pending_file} exists. "
        "Inspect the room and remove that marker only after an explicit operator decision.",
        file=sys.stderr,
    )
    raise SystemExit(2)


with state_file.open("a+", encoding="utf-8") as f:
    os.chmod(state_file, 0o600)
    fcntl.flock(f.fileno(), fcntl.LOCK_EX)

    # A prior process may have died after creating its write-ahead marker, perhaps
    # even after the server committed the post. Reconcile before allocating any
    # new nonce. If the exact record cannot be proven present, block all later
    # sends until an operator explicitly resolves the marker.
    if pending_file.exists():
        pending = read_pending()
        if reconcile(pending):
            clear_pending()
            if pending["text"] == text:
                print(
                    "Previous outcome-unknown post is present in the room; "
                    "not sending the same logical message again."
                )
                raise SystemExit(0)
        else:
            print("Error: a previous signed Technocore POST still has an unknown outcome.", file=sys.stderr)
            print(f"DID: {pending['did']}", file=sys.stderr)
            print(f"Room: {pending['room']}", file=sys.stderr)
            print(f"Nonce: {pending['nonce']}", file=sys.stderr)
            print(f"Text: {pending['text']}", file=sys.stderr)
            print(
                f"Refusing a new signed post. Inspect the room and remove {pending_file} only "
                "after an explicit operator decision.",
                file=sys.stderr,
            )
            raise SystemExit(2)

    f.seek(0)
    raw = f.read().strip()
    last = int(raw) if raw else 0
    clock = time.time_ns() // 1_000_000
    nonce = max(last + 1, clock)
    persist_nonce(f, nonce)

    payload, encoded = signed_payload(nonce)
    write_pending(payload)
    body, status, unknown = post(payload, encoded)
    if unknown is not None:
        if handle_unknown(payload, unknown):
            raise SystemExit(0)
        raise SystemExit(2)

    handle_server_error(payload, body, status)

    # Successful responses and definite 4xx refusals are safe to clear. A 5xx
    # is handled above as outcome-unknown because the server may have appended.
    clear_pending()
    if status is None:
        print(body)
        raise SystemExit(0)

    # Another machine using the same DID, or a restored nonce file, can leave the server's
    # per-DID/per-room high-water ahead of local state. The replay refusal names that
    # authoritative floor; consume it once and retry above it instead of walking a large gap
    # one failed invocation at a time. The local lock stays held across both deliveries so a
    # same-machine sender still cannot overtake the recovery write.
    match = re.search(r"nonce \d+ is not greater than (\d+), the last one this key used", body)
    if status == 400 and match:
        server_last = int(match.group(1))
        retry_nonce = max(server_last + 1, nonce + 1, time.time_ns() // 1_000_000)
        persist_nonce(f, retry_nonce)
        payload, encoded = signed_payload(retry_nonce)
        write_pending(payload)
        body, status, unknown = post(payload, encoded)
        if unknown is not None:
            if handle_unknown(payload, unknown):
                raise SystemExit(0)
            raise SystemExit(2)
        handle_server_error(payload, body, status)
        clear_pending()
        if status is None:
            print(body)
            raise SystemExit(0)

    print(f"Technocore returned HTTP {status}")
    print(body)
    raise SystemExit(1)
INNERPY