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

# PIDs of agent processes (global binary or dart entrypoint), excluding this script.
find_agent_pids() {
  local self=$$
  local pid cmd

  {
    [[ -f "$PID_FILE" ]] && cat "$PID_FILE" 2>/dev/null || true
    pgrep -f 'ip_ntfy_agent' 2>/dev/null || true
  } | sort -u | while read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    [[ "$pid" == "$self" ]] && continue
    kill -0 "$pid" 2>/dev/null || continue
    cmd="$(ps -p "$pid" -o args= 2>/dev/null || true)"
    [[ -z "$cmd" ]] && continue
    # Don't kill the management script itself (path may contain ip_ntfy_agent/)
    [[ "$cmd" == *scripts/agent.sh* ]] && continue
    echo "$pid"
  done
}

is_running() {
  local pids
  pids="$(find_agent_pids | tr '\n' ' ')"
  [[ -n "${pids// /}" ]]
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
    echo "already running:"
    find_agent_pids | while read -r pid; do
      echo "  pid $pid  $(ps -p "$pid" -o args= 2>/dev/null || true)"
    done
    echo "stop first: $0 stop"
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
  local -a pids=()
  while read -r pid; do
    [[ -n "$pid" ]] && pids+=("$pid")
  done < <(find_agent_pids)

  if ((${#pids[@]} == 0)); then
    echo "not running"
    rm -f "$PID_FILE"
    exit 0
  fi

  echo "stopping ${#pids[@]} process(es): ${pids[*]}"
  for pid in "${pids[@]}"; do
    kill "$pid" 2>/dev/null || true
  done

  local i=0
  local left
  while (( i < 20 )); do
    left="$(find_agent_pids | tr '\n' ' ')"
    [[ -z "${left// /}" ]] && break
    sleep 0.25
    i=$((i + 1))
  done

  left="$(find_agent_pids | tr '\n' ' ')"
  if [[ -n "${left// /}" ]]; then
    echo "force kill: $left"
    # shellcheck disable=SC2086
    kill -9 $left 2>/dev/null || true
  fi

  rm -f "$PID_FILE"
  echo "stopped"
}

cmd_status() {
  local -a pids=()
  while read -r pid; do
    [[ -n "$pid" ]] && pids+=("$pid")
  done < <(find_agent_pids)

  if ((${#pids[@]} == 0)); then
    echo "not running"
    exit 1
  fi

  echo "running (${#pids[@]}):"
  for pid in "${pids[@]}"; do
    echo "  pid $pid  $(ps -p "$pid" -o args= 2>/dev/null || true)"
  done
  echo "log: $LOG_FILE"
  exit 0
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
  stop          Stop all ip_ntfy_agent processes
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
