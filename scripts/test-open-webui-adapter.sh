#!/usr/bin/env bash
set -euo pipefail

IMAGE="greenmail/standalone:2.1.8"
NAME="mail-mcp-open-webui-adapter-test"
ADAPTER_PORT="${ADAPTER_PORT:-8787}"
ADAPTER_HOST="${ADAPTER_HOST:-127.0.0.1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ADAPTER_SCRIPT="$REPO_ROOT/scripts/run-open-webui-adapter.sh"

EXTERNAL_ENDPOINT=0
if [[ -n "${GREENMAIL_HOST+x}" || -n "${GREENMAIL_SMTP_PORT+x}" || -n "${GREENMAIL_IMAP_PORT+x}" ]]; then
  EXTERNAL_ENDPOINT=1
fi

GREENMAIL_HOST="${GREENMAIL_HOST:-localhost}"
GREENMAIL_SMTP_PORT="${GREENMAIL_SMTP_PORT:-3025}"
GREENMAIL_IMAP_PORT="${GREENMAIL_IMAP_PORT:-3143}"
GREENMAIL_USER="${GREENMAIL_USER:-test@localhost}"
GREENMAIL_PASS="${GREENMAIL_PASS:-test}"
GREENMAIL_PRELOAD_DIR="${GREENMAIL_PRELOAD_DIR:-$REPO_ROOT/tests/fixtures/greenmail-preload}"

GREENMAIL_OPTS_DEFAULT="-Dgreenmail.setup.test.all -Dgreenmail.hostname=0.0.0.0 -Dgreenmail.users=test:${GREENMAIL_PASS}@localhost -Dgreenmail.users.login=email -Dgreenmail.preload.dir=/greenmail-preload -Dgreenmail.verbose"
GREENMAIL_OPTS="${GREENMAIL_OPTS:-$GREENMAIL_OPTS_DEFAULT}"

started_local_container=0
ADAPTER_PID=""
cleanup() {
  if [[ -n "$ADAPTER_PID" ]]; then
    kill "$ADAPTER_PID" >/dev/null 2>&1 || true
    wait "$ADAPTER_PID" >/dev/null 2>&1 || true
  fi

  if [[ "$started_local_container" -eq 1 ]]; then
    docker rm -f "$NAME" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

probe_greenmail() {
  python3 - "$GREENMAIL_HOST" "$GREENMAIL_SMTP_PORT" "$GREENMAIL_IMAP_PORT" <<'PY'
import socket
import sys

host = sys.argv[1]
ports = [int(sys.argv[2]), int(sys.argv[3])]

for port in ports:
    try:
        with socket.create_connection((host, port), timeout=1.5):
            pass
    except Exception as exc:
        print(exc)
        sys.exit(1)
PY
}

wait_for_greenmail() {
  local attempts=60
  local last_probe_error=""

  echo "Waiting for GreenMail on ${GREENMAIL_HOST}:${GREENMAIL_SMTP_PORT} and ${GREENMAIL_HOST}:${GREENMAIL_IMAP_PORT}"

  for _ in $(seq 1 "$attempts"); do
    if last_probe_error=$(probe_greenmail 2>&1); then
      return 0
    fi
    sleep 1
  done

  echo "GreenMail unreachable at ${GREENMAIL_HOST}:${GREENMAIL_IMAP_PORT} after ${attempts}s: ${last_probe_error}" >&2
  return 1
}

ensure_command() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "${name} is required for adapter testing" >&2
    exit 1
  fi
}

ensure_mcpo() {
  if command -v mcpo >/dev/null 2>&1 || command -v uvx >/dev/null 2>&1 || python3 -c 'import mcpo' >/dev/null 2>&1; then
    return 0
  fi

  local venv_dir="/tmp/mail-mcp-open-webui-adapter-venv"
  python3 -m venv "$venv_dir"
  # shellcheck disable=SC1091
  source "$venv_dir/bin/activate"
  pip install --quiet mcpo
}

wait_for_adapter() {
  local url="http://${ADAPTER_HOST}:${ADAPTER_PORT}/openapi.json"
  local attempts=60

  for _ in $(seq 1 "$attempts"); do
    if curl --fail --silent --show-error "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  echo "adapter did not become ready at $url" >&2
  return 1
}

if [[ "$EXTERNAL_ENDPOINT" -eq 0 ]] && probe_greenmail >/dev/null 2>&1; then
  EXTERNAL_ENDPOINT=1
  echo "Detected running GreenMail endpoint on default host/ports"
fi

if [[ "$EXTERNAL_ENDPOINT" -eq 1 ]]; then
  echo "Using externally managed GreenMail endpoint"
else
  ensure_command docker

  if [[ ! -d "$GREENMAIL_PRELOAD_DIR" ]]; then
    echo "missing preload fixture directory: $GREENMAIL_PRELOAD_DIR" >&2
    exit 1
  fi

  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker pull "$IMAGE"

  docker run -d --rm --name "$NAME" \
    -e GREENMAIL_OPTS="$GREENMAIL_OPTS" \
    -v "$GREENMAIL_PRELOAD_DIR:/greenmail-preload:ro" \
    -p "$GREENMAIL_SMTP_PORT:3025" \
    -p "$GREENMAIL_IMAP_PORT:3993" \
    "$IMAGE"

  started_local_container=1
fi

wait_for_greenmail

ensure_command cargo
ensure_command curl
ensure_command jq
ensure_command python3
ensure_mcpo

cd "$REPO_ROOT"

echo "Building server binary"
cargo build --quiet

SERVER_BIN="$REPO_ROOT/target/debug/mail-mcp"
if [[ ! -x "$SERVER_BIN" ]]; then
  echo "expected binary not found: $SERVER_BIN" >&2
  exit 1
fi

export MAIL_IMAP_DEFAULT_HOST="$GREENMAIL_HOST"
export MAIL_IMAP_DEFAULT_PORT="$GREENMAIL_IMAP_PORT"
export MAIL_IMAP_DEFAULT_SECURE="true"
export MAIL_IMAP_DEFAULT_USER="$GREENMAIL_USER"
export MAIL_IMAP_DEFAULT_PASS="$GREENMAIL_PASS"
export MAIL_IMAP_WRITE_ENABLED="true"

echo "Starting Open WebUI adapter"
MAIL_MCP_BIN="$SERVER_BIN" \
MCPO_HOST="$ADAPTER_HOST" \
MCPO_PORT="$ADAPTER_PORT" \
"$ADAPTER_SCRIPT" >/tmp/mail-mcp-open-webui-adapter.log 2>&1 &
ADAPTER_PID=$!

wait_for_adapter

echo "Checking generated OpenAPI schema"
OPENAPI_JSON="$(curl --fail --silent --show-error "http://${ADAPTER_HOST}:${ADAPTER_PORT}/openapi.json")"
printf '%s\n' "$OPENAPI_JSON" | jq -e '
  .paths
  | has("/list_all_accounts")
    and has("/imap_verify_account")
    and has("/imap_search_messages")
' >/dev/null

echo "Checking list_all_accounts through adapter"
LIST_JSON="$(curl --fail --silent --show-error \
  -X POST \
  -H 'content-type: application/json' \
  -d '{}' \
  "http://${ADAPTER_HOST}:${ADAPTER_PORT}/list_all_accounts")"
printf '%s\n' "$LIST_JSON" | jq -e '
  ((.data.accounts // []) | map(.account_id) | index("default")) != null
' >/dev/null

echo "Checking imap_verify_account through adapter"
VERIFY_JSON="$(curl --fail --silent --show-error \
  -X POST \
  -H 'content-type: application/json' \
  -d '{"account_id":"default"}' \
  "http://${ADAPTER_HOST}:${ADAPTER_PORT}/imap_verify_account")"
printf '%s\n' "$VERIFY_JSON" | jq -e '
  .data.account_id == "default"
' >/dev/null

echo "Checking imap_search_messages through adapter"
SEARCH_JSON="$(curl --fail --silent --show-error \
  -X POST \
  -H 'content-type: application/json' \
  -d '{"account_id":"default","mailbox":"INBOX","limit":5}' \
  "http://${ADAPTER_HOST}:${ADAPTER_PORT}/imap_search_messages")"
printf '%s\n' "$SEARCH_JSON" | jq -e '
  (.data.messages | length) > 0
' >/dev/null

echo "Open WebUI adapter smoke test passed"
