#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: run-open-webui-adapter.sh

Wrap mail-mcp with the mcpo MCP-to-OpenAPI adapter so Open WebUI can connect
to it as an OpenAPI tool server.

Environment:
  MAIL_MCP_BIN     Path to the mail-mcp binary.
                   Default: target/release/mail-mcp, then target/debug/mail-mcp,
                   then mail-mcp from PATH.
  MCPO_COMMAND     Override the adapter launcher (for example: "uvx mcpo" or
                   "python3 -m mcpo").
  MCPO_HOST        HTTP bind address for mcpo. Default: 0.0.0.0
  MCPO_PORT        HTTP bind port for mcpo. Default: 8000
  MCPO_API_KEY     Optional API key for mcpo authentication.
  MCPO_ROOT_PATH   Optional root path prefix, such as /mail.
  MCPO_LOG_LEVEL   mcpo log level. Default: INFO

mail-mcp itself still uses the normal MAIL_* account configuration variables.
EOF
}

resolve_mail_mcp_bin() {
  if [[ -n "${MAIL_MCP_BIN:-}" ]]; then
    printf '%s\n' "$MAIL_MCP_BIN"
    return 0
  fi

  local candidates=(
    "$REPO_ROOT/target/release/mail-mcp"
    "$REPO_ROOT/target/debug/mail-mcp"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  if command -v mail-mcp >/dev/null 2>&1; then
    command -v mail-mcp
    return 0
  fi

  cat >&2 <<EOF
Unable to find the mail-mcp binary.

Build it first with:
  cargo build --release

Or set MAIL_MCP_BIN to the binary you want to expose.
EOF
  return 1
}

resolve_mcpo_command() {
  if [[ -n "${MCPO_COMMAND:-}" ]]; then
    read -r -a MCPO_CMD <<<"${MCPO_COMMAND}"
    return 0
  fi

  if command -v mcpo >/dev/null 2>&1; then
    MCPO_CMD=(mcpo)
    return 0
  fi

  if command -v uvx >/dev/null 2>&1; then
    MCPO_CMD=(uvx mcpo)
    return 0
  fi

  if python3 -c 'import mcpo' >/dev/null 2>&1; then
    MCPO_CMD=(python3 -m mcpo)
    return 0
  fi

  cat >&2 <<'EOF'
Unable to find mcpo.

Install one of the supported launchers, for example:
  pip install mcpo
  uv tool install mcpo

Or set MCPO_COMMAND explicitly, such as:
  MCPO_COMMAND="python3 -m mcpo"
EOF
  return 1
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ $# -gt 0 ]]; then
  usage >&2
  exit 1
fi

MAIL_MCP_BIN="$(resolve_mail_mcp_bin)"
resolve_mcpo_command

MCPO_HOST="${MCPO_HOST:-0.0.0.0}"
MCPO_PORT="${MCPO_PORT:-8000}"
MCPO_LOG_LEVEL="${MCPO_LOG_LEVEL:-INFO}"

MCPO_ARGS=(
  --host "$MCPO_HOST"
  --port "$MCPO_PORT"
  --log-level "$MCPO_LOG_LEVEL"
)

if [[ -n "${MCPO_API_KEY:-}" ]]; then
  MCPO_ARGS+=(--api-key "$MCPO_API_KEY")
fi

if [[ -n "${MCPO_ROOT_PATH:-}" ]]; then
  MCPO_ARGS+=(--root-path "$MCPO_ROOT_PATH")
fi

exec "${MCPO_CMD[@]}" "${MCPO_ARGS[@]}" -- "$MAIL_MCP_BIN"
