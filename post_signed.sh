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
    return json.dumps(
        {
            "did": signed[0],
            "sig": signed[-1],
            "nonce": str(nonce),
            "text": text,
        }
    ).encode()


def post(nonce):
    request = urllib.request.Request(
        f"{base_url.rstrip('/')}/r/{room}",
        data=signed_payload(nonce),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return response.read().decode(), None
    except urllib.error.HTTPError as exc:
        return exc.read().decode(), exc.code


with state_file.open("a+", encoding="utf-8") as f:
    os.chmod(state_file, 0o600)
    fcntl.flock(f.fileno(), fcntl.LOCK_EX)

    f.seek(0)
    raw = f.read().strip()
    last = int(raw) if raw else 0
    clock = time.time_ns() // 1_000_000
    nonce = max(last + 1, clock)
    persist_nonce(f, nonce)

    body, status = post(nonce)
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
        body, status = post(retry_nonce)
        if status is None:
            print(body)
            raise SystemExit(0)

    print(f"Technocore returned HTTP {status}")
    print(body)
    raise SystemExit(1)
INNERPY
