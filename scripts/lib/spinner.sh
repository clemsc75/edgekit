#!/usr/bin/env bash
# =============================================================================
# scripts/lib/spinner.sh – Shared spinner / progress-indicator utilities
#
# Source this file from any EdgeKit script AFTER LOG_FILE is defined:
#
#   source "${REPO_ROOT}/scripts/lib/spinner.sh"
#   spinner_register_traps
#
# Then wrap long-running commands with:
#
#   run_with_spinner "Human-readable label" some_command --with args
#   run_with_spinner "Import image"         _my_helper_function
#
# VERBOSE mode (set before sourcing or via --verbose flag):
#   VERBOSE=1 ./scripts/k3s-master.sh  →  no spinner, raw output to terminal
# =============================================================================

# Guard against double-sourcing
[ -n "${_EDGEKIT_SPINNER_LOADED:-}" ] && return 0
_EDGEKIT_SPINNER_LOADED=1

# -----------------------------------------------------------------------------
# Internal state
# -----------------------------------------------------------------------------

_SPINNER_PID=""
_SPINNER_ACTIVE=0

# Braille spinner frames — smooth on any UTF-8 terminal (Ubuntu/Debian default)
readonly -a _SPINNER_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

# Width for the label column in the terminal (pad to align ✓/✗ markers)
readonly _SPINNER_LABEL_WIDTH=58

# -----------------------------------------------------------------------------
# _spinner_clear  – erase the current spinner line
# -----------------------------------------------------------------------------
_spinner_clear() {
  # Write directly to /dev/tty so it bypasses any exec-level tee redirect
  printf "\r%-$(( _SPINNER_LABEL_WIDTH + 10 ))s\r" " " > /dev/tty 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# _spinner_cleanup  – kill the background spinner sub-shell (used in traps)
# -----------------------------------------------------------------------------
_spinner_cleanup() {
  if [ "${_SPINNER_ACTIVE}" -eq 1 ] && [ -n "${_SPINNER_PID}" ]; then
    kill "${_SPINNER_PID}" 2>/dev/null || true
    wait "${_SPINNER_PID}" 2>/dev/null || true
    _SPINNER_PID=""
    _SPINNER_ACTIVE=0
    _spinner_clear
  fi
}

# -----------------------------------------------------------------------------
# spinner_register_traps
#
# Call once after sourcing this file. Sets up SIGINT / SIGTERM / EXIT traps
# to guarantee the spinner is killed even on Ctrl+C or unexpected crashes.
# Merges with any existing ERR trap the parent script may have.
# -----------------------------------------------------------------------------
spinner_register_traps() {
  # INT (Ctrl+C) → clean up spinner then exit with code 130
  trap '_spinner_cleanup; echo ""; echo "  Interrupted." >&2; exit 130' INT

  # TERM → clean up spinner then exit with code 143
  trap '_spinner_cleanup; exit 143' TERM

  # EXIT → best-effort cleanup (catches crashes / set -e exits)
  trap '_spinner_cleanup' EXIT
}

# -----------------------------------------------------------------------------
# _spinner_start <label>
# -----------------------------------------------------------------------------
_spinner_start() {
  local label="$1"
  _SPINNER_ACTIVE=1

  # Launch spinner animation in a sub-shell writing directly to /dev/tty
  (
    local i=0
    local n=${#_SPINNER_FRAMES[@]}
    while true; do
      local frame="${_SPINNER_FRAMES[$((i % n))]}"
      printf "\r  %s  %-${_SPINNER_LABEL_WIDTH}s" "${frame}" "${label}" > /dev/tty 2>/dev/null || true
      i=$(( i + 1 ))
      sleep 0.1
    done
  ) &

  _SPINNER_PID=$!
}

# -----------------------------------------------------------------------------
# _spinner_stop <exit_code> <label> [elapsed_seconds]
# -----------------------------------------------------------------------------
_spinner_stop() {
  local exit_code="$1"
  local label="$2"
  local elapsed="${3:-}"

  # Kill the background animation
  if [ -n "${_SPINNER_PID}" ]; then
    kill "${_SPINNER_PID}" 2>/dev/null || true
    wait "${_SPINNER_PID}" 2>/dev/null || true
    _SPINNER_PID=""
  fi
  _SPINNER_ACTIVE=0

  # Build elapsed string
  local elapsed_str=""
  if [ -n "${elapsed}" ]; then
    elapsed_str="$(printf "[%3ds]" "${elapsed}")"
  fi

  # Print final status line directly to /dev/tty
  if [ "${exit_code}" -eq 0 ]; then
    printf "\r  \033[32m✓\033[0m  %-${_SPINNER_LABEL_WIDTH}s %s\n" \
      "${label}" "${elapsed_str}" > /dev/tty 2>/dev/null || true
  else
    printf "\r  \033[31m✗\033[0m  %-${_SPINNER_LABEL_WIDTH}s  FAILED\n" \
      "${label}" > /dev/tty 2>/dev/null || true
  fi
}

# -----------------------------------------------------------------------------
# run_with_spinner <label> <command> [args...]
#
# In VERBOSE mode (VERBOSE=1): simply echoes the label and runs the command
# with full output to the terminal (no spinner, no redirection).
#
# In normal mode:
#   - Shows an animated braille spinner in the terminal
#   - Redirects all command stdout/stderr to LOG_FILE (append)
#   - On success: prints  ✓  label  [Xs]
#   - On failure: prints  ✗  label  FAILED
#                 + an error message pointing to LOG_FILE
#                 + returns the original exit code (set -e will catch it)
# -----------------------------------------------------------------------------
run_with_spinner() {
  local label="$1"
  shift

  # ------------------------------------------------------------------
  # VERBOSE mode: run directly with full terminal output
  # ------------------------------------------------------------------
  if [ "${VERBOSE:-0}" = "1" ]; then
    echo ""
    echo "==> ${label}"
    set -x
    "$@"
    local exit_code=$?
    set +x
    return $exit_code
  fi

  # ------------------------------------------------------------------
  # Spinner mode
  # ------------------------------------------------------------------

  # LOG_FILE must be defined by the calling script
  if [ -z "${LOG_FILE:-}" ]; then
    echo "WARN: LOG_FILE is not set – spinner will run command without logging" >&2
    "$@"
    return $?
  fi

  local start_time
  start_time=$(date +%s)

  _spinner_start "${label}"

  local exit_code=0
  # Run command with ALL output going only to the log file.
  # The exec-level tee redirect in the parent script captures script-level
  # echo/print_section messages; here we bypass it intentionally so the
  # raw command output stays out of the terminal.
  ( set -x; "$@" ) >> "${LOG_FILE}" 2>&1 || exit_code=$?

  local end_time
  end_time=$(date +%s)
  local elapsed=$(( end_time - start_time ))

  _spinner_stop "${exit_code}" "${label}" "${elapsed}"

  if [ "${exit_code}" -ne 0 ]; then
    echo "" >&2
    echo "  ┌─ ERROR ──────────────────────────────────────────────────┐" >&2
    echo "  │  '${label}' exited with code ${exit_code}." >&2
    echo "  │  Full output: ${LOG_FILE}" >&2
    echo "  └──────────────────────────────────────────────────────────┘" >&2
    echo "" >&2
    return "${exit_code}"
  fi

  return 0
}
