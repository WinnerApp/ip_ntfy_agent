#!/usr/bin/env bash
# Manage ip_ntfy_agent as a background process (survives SSH disconnect).
#
# Usage:
#   ./scripts/agent.sh start [path/to/.env]
#   ./scripts/agent.sh stop
#   ./scripts/agent.sh restart [path/to/.env]
#   ./scripts/agent.sh status
#   ./scripts/agent.sh logs [-f]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="$ROOT/.run"
PID_FILE="$RUN_DIR/agent.pid"
LOG_FILE="$RUN_DIR/agent.log"

mkdir -p "$RUN_DIR"

is_running() {
  if [[ ! -f "$PID_FILE" ]]; then
    return 1
  fi
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ -z "${pid:-}" ]]; then
    return 1
  fi
  kill -0 "$pid" 2>/dev/null
}

resolve_cmd() {
  local env_path="${1:-}"
  local -a cmd=()

  if command -v ip_ntfy_agent >/dev/null 2>&1; then
    cmd=(ip_ntfy_agent)
  elif command -v dart >/dev/null 2>&1; then
    cmd=(dart run "$ROOT/bin/ip_ntfy_agent.dart")
  else
    echo "error: neither ip_ntfy_agent nor dart found in PATH" >&2
    exit 1
  fi

  if [[ -n "$env_path" ]]; then
    cmd+=("$env_path")
  elif [[ -f "$ROOT/.env" ]]; then
    cmd+=("$ROOT/.env")
  fi

  printf '%s\0' "${cmd[@]}"
}

cmd_start() {
  local env_path="${1:-}"

  if is_running; then
    echo "already running (pid $(cat "$PID_FILE"))"
    exit 0
  fi

  local -a cmd=()
  while IFS= read -r -d '' part; do
    cmd+=("$part")
  done < <(resolve_cmd "$env_path")

  if [[ -n "$env_path" && ! -f "$env_path" ]]; then
    echo "error: .env not found: $env_path" >&2
    exit 1
  fi
  if [[ -z "$env_path" && ! -f "$ROOT/.env" ]]; then
    echo "error: $ROOT/.env not found (copy .env.example or pass a path)" >&2
    exit 1
  fi

  cd "$ROOT"
  # nohup + disown: keep running after SSH / terminal closes
  nohup "${cmd[@]}" >>"$LOG_FILE" 2>&1 &
  local pid=$!
  disown "$pid" 2>/dev/null || true
  echo "$pid" >"$PID_FILE"

  sleep 0.5
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "error: process exited immediately; check $LOG_FILE" >&2
    rm -f "$PID_FILE"
    exit 1
  fi

  echo "started pid=$pid"
  echo "log: $LOG_FILE"
  echo "stop with: $0 stop"
}

cmd_stop() {
  if ! is_running; then
    echo "not running"
    rm -f "$PID_FILE"
    exit 0
  fi

  local pid
  pid="$(cat "$PID_FILE")"
  echo "stopping pid=$pid ..."
  kill "$pid" 2>/dev/null || true

  local i=0
  while kill -0 "$pid" 2>/dev/null && (( i < 20 )); do
    sleep 0.25
    i=$((i + 1))
  done

  if kill -0 "$pid" 2>/dev/null; then
    echo "force kill pid=$pid"
    kill -9 "$pid" 2>/dev/null || true
  fi

  rm -f "$PID_FILE"
  echo "stopped"
}

cmd_status() {
  if is_running; then
    echo "running (pid $(cat "$PID_FILE"))"
    echo "log: $LOG_FILE"
    exit 0
  fi
  echo "not running"
  exit 1
}

cmd_logs() {
  if [[ ! -f "$LOG_FILE" ]]; then
    echo "no log yet: $LOG_FILE"
    exit 1
  fi
  if [[ "${1:-}" == "-f" || "${1:-}" == "--follow" ]]; then
    tail -n 100 -f "$LOG_FILE"
  else
    tail -n 100 "$LOG_FILE"
  fi
}

cmd_restart() {
  cmd_stop || true
  cmd_start "${1:-}"
}

usage() {
  cat <<EOF
Usage: $0 <command> [args]

Commands:
  start [env]   Start agent in background (survives SSH disconnect)
  stop          Stop background agent
  restart [env] Restart agent
  status        Show running status
  logs [-f]     Show last 100 log lines (-f to follow)

Examples:
  $0 start
  $0 start /path/to/.env
  $0 logs -f
  $0 stop
EOF
}

main() {
  local action="${1:-}"
  shift || true

  case "$action" in
    start) cmd_start "${1:-}" ;;
    stop) cmd_stop ;;
    restart) cmd_restart "${1:-}" ;;
    status) cmd_status ;;
    logs) cmd_logs "${1:-}" ;;
    -h|--help|help|"") usage ;;
    *)
      echo "unknown command: $action" >&2
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
