#!/bin/bash

# Name: gkill.sh
# Author: Nikita Neverov (BMTLab)
# Version: 1.0.0
# Date: 2025-11-21
# License: MIT
#
# Description:
#   Gracefully terminates processes by escalating signals.
#   It attempts to stop a process using polite signals first,
#   waiting for the process to clean up resources,
#   before resorting to a forceful KILL.
#
#   Signal Escalation Chain:
#     1. SIGTERM (15): Request termination (allows cleanup).
#     2. SIGINT   (2): Interrupt (standard interactive stop signal).
#     3. SIGKILL  (9): Forceful immediate termination (kernel level).
#
#   Behavior:
#     - Accepts a PID or a Process Name Pattern (Extended Regex).
#     - Resolves the input to a list of PIDs (using pgrep -f).
#     - Excludes the script's own PID and its ancestors to prevent
#       terminating its own invocation chain (sudo, parent shells, etc.).
#     - Interactively asks for confirmation unless -f is provided.
#     - Waits a specified duration between signals to verify termination.
#
#   Permissions & Scope:
#     - Standard User: Searches and kills ONLY processes owned
#       by the current user. Root processes are ignored during pattern matching.
#     - Root/Sudo: Searches ALL processes on the system.
#
# Usage:
#   gkill.sh <pid|pattern>
#   gkill.sh -f nginx        # Force mode (no confirmation)
#   gkill.sh -t 10 <name>    # Wait 10 seconds between signals
#   gkill.sh -n <pattern>    # Dry-run (show what would be killed)
#   gkill.sh -v <pid>        # Verbose output
#   sudo gkill.sh <service>  # Kill system/any process (requires root)
#
#   Note on Patterns:
#     The pattern is interpreted as an Extended Regular Expression (ERE).
#     - 'ge'    matches any process command line containing "ge".
#     - '^ge'   matches processes starting with "ge".
#     - 'ge.*'  is the regex equivalent of shell wildcard "ge*".
#     WARNING: 'ge*' in regex means "g followed by zero or more e's",
#              which will match plain "g" and likely return many results.
#
# Exit Codes:
#   0: Success (All targeted processes terminated or operation canceled).
#   1: GK_ERR_GENERAL
#      Generic error.
#   2: GK_ERR_USAGE
#      Invalid usage or arguments.
#   3: GK_ERR_NO_PROCESS
#      No processes found matching the input.
#   4: GK_ERR_PARTIAL_FAILURE
#      Some processes could not be terminated (permission denied, etc.).
#   5: GK_ERR_MISSING_DEPENDENCY
#      Required system utility (pgrep) is missing.

# Detect whether script is sourced or executed.
# bashsupport disable=BP5001
if [[ ${BASH_SOURCE[0]} != "$0" ]]; then
  readonly GK_SCRIPT_SOURCED=true
else
  readonly GK_SCRIPT_SOURCED=false
  set -o errexit -o nounset -o pipefail
fi

# Error codes (readonly; safe for repeated sourcing)
if [[ -z ${GK_ERR_GENERAL+x} ]]; then
  readonly GK_ERR_GENERAL=1
fi
if [[ -z ${GK_ERR_USAGE+x} ]]; then
  readonly GK_ERR_USAGE=2
fi
if [[ -z ${GK_ERR_NO_PROCESS+x} ]]; then
  readonly GK_ERR_NO_PROCESS=3
fi
if [[ -z ${GK_ERR_PARTIAL_FAILURE+x} ]]; then
  readonly GK_ERR_PARTIAL_FAILURE=4
fi
if [[ -z ${GK_ERR_MISSING_DEPENDENCY+x} ]]; then
  readonly GK_ERR_MISSING_DEPENDENCY=5
fi

#######################################
# Print usage information.
#
# Outputs:
#   Usage text to stdout.
#######################################
function __gk_usage() {
  cat << 'EOF'
gkill - terminate processes with graceful signal escalation

Usage:
  gkill [-f] [-t seconds] [-n] [-v] [-h] <pid|pattern>

Options:
  -f            Force mode. Do not ask for confirmation before killing.
  -t <seconds>  Timeout in seconds to wait after each signal (default: 5).
                The script waits up to this time for the process to exit
                before escalating to the next, stronger signal.
  -n            Dry-run. List matching processes but do not send signals.
  -v            Verbose mode. Show detailed status messages.
  -h            Show this help message.

Patterns:
  Input is treated as an Extended Regex (pgrep -f).
  Example: 'my_app' matches any command line containing "my_app".
  Note: 'app*' in regex means "ap" followed by zero or more "p"s.

Permissions:
  - Without sudo: Limits search to your own processes.
  - With sudo: Searches all system processes.
EOF
}

#######################################
# Print error message and return/exit with code.
#
# Arguments:
#   1: Message text.
#   2: Return code (optional, default: GK_ERR_GENERAL).
#
# Outputs:
#   Error message to stderr.
#######################################
function __gk_error() {
  local -r message="$1"
  local -ir code="${2:-$GK_ERR_GENERAL}"

  printf 'ERROR: %s\n' "$message" >&2

  if [[ $GK_SCRIPT_SOURCED == true ]]; then
    return "$code"
  else
    exit "$code"
  fi
}

#######################################
# Centralized logging function.
# Handles verbosity checks and color formatting.
#
# Automatically detects if stdout is a TTY.
# If piped (not a TTY), suppresses color codes to keep logs clean.
#
# Arguments:
#   1: Should Log (bool) - usually passed from is_verbose.
#   2: Message (string).
#   3: Color Code (string, optional).
#   4: No Newline Flag (bool, optional) - if true, uses printf without \n.
#
# Outputs:
#   Formatted message to stdout.
#######################################
function __gk_log() {
  local -r should_perform_logging="$1"
  local -r log_message_content="$2"
  local text_color_ansi="${3:-}"
  local -r should_omit_newline="${4:-false}"

  if [[ $should_perform_logging == false ]]; then
    return 0
  fi

  # Auto-disable color if stdout is not a terminal
  if [[ ! -t 1 ]]; then
    text_color_ansi=''
  fi

  local -r color_reset='\033[0m'

  if [[ -n $text_color_ansi ]]; then
    if [[ $should_omit_newline == true ]]; then
      printf '%b%s%b' \
        "$text_color_ansi" "$log_message_content" "$color_reset"
    else
      printf '%b%s%b\n' \
        "$text_color_ansi" "$log_message_content" "$color_reset"
    fi
  else
    if [[ $should_omit_newline == true ]]; then
      printf '%s' "$log_message_content"
    else
      printf '%s\n' "$log_message_content"
    fi
  fi
}

#######################################
# Check if a process is currently running.
#
# Uses `ps -p` to avoid confusion between "no permission" and
# "no such process" that can occur with `kill -0`.
#
# Arguments:
#   1: PID to check.
#
# Returns:
#   0: Process exists.
#   1: Process does not exist.
#######################################
function __gk_process_exists() {
  local -ir pid_to_check="$1"

  if ps -p "$pid_to_check" > /dev/null 2>&1; then
    return 0
  fi

  return 1
}

#######################################
# Collect ancestor PIDs for the current process.
#
# The resulting array includes:
#   - The script's own PID ($$).
#   - All parents up to (and including) PID 1, when available.
#
# Arguments:
#   1: Output nameref array (_ancestors_array).
#######################################
function __gk_collect_ancestor_pids() {
  local -n _ancestors_array="$1"

  _ancestors_array=()

  local current_pid="$$"
  local parent_pid=''

  # Walk up the PPID chain until we reach PID 1 or an unknown parent.
  while [[ -n $current_pid ]]; do
    _ancestors_array+=("$current_pid")

    if ! parent_pid=$(ps -o ppid= -p "$current_pid" 2> /dev/null); then
      break
    fi

    # Strip whitespace from ps output
    parent_pid=${parent_pid//[[:space:]]/}

    # Stop if parent is empty or self
    if [[ -z $parent_pid || $parent_pid == "$current_pid" ]]; then
      break
    fi

    if [[ $parent_pid == 1 ]]; then
      _ancestors_array+=("1")
      break
    fi

    current_pid="$parent_pid"
  done

  return 0
}

#######################################
# Build pgrep flags taking into account current privileges.
#
# Arguments:
#   1: Output nameref array (_pgrep_flags_array).
#######################################
function __gk_build_pgrep_flags() {
  local -n _pgrep_flags_array="$1"

  _pgrep_flags_array=('-f') # Match full command line

  # If NOT root, restrict search to current user's UID
  if [[ $EUID -ne 0 ]]; then
    _pgrep_flags_array+=('-u' "$EUID")
  fi
}

#######################################
# Determine whether PID should be skipped as part of
# the current invocation ancestor chain (self, sudo, shells, etc.).
#
# Arguments:
#   1: Nameref array of ancestor PIDs.
#   2: PID to check.
#
# Returns:
#   0: PID belongs to ancestor chain (should be skipped).
#   1: PID is not an ancestor (can be processed).
#######################################
function __gk_should_skip_pid() {
  # shellcheck disable=SC2178
  local -n _ancestors_array="$1"
  local -r candidate_pid="$2"

  local anc_pid
  for anc_pid in "${_ancestors_array[@]}"; do
    if [[ $candidate_pid -eq $anc_pid ]]; then
      return 0
    fi
  done

  return 1
}

#######################################
# Resolve input query to an array of unique PIDs.
#
# Handles explicit PIDs and name patterns via pgrep.
# Excludes the current script's PID and all of its ancestors
# (sudo, parent shells, etc.) to prevent killing its own invocation.
#
# Scope logic:
#   If running as root ($EUID 0), searches all processes.
#   If running as user, adds '-u $EUID' to pgrep
#   to search only owned processes.
#
# Arguments:
#   1: Query string (PID or Name).
#   2: Output nameref array for PIDs (_resolved_pids_array).
#
# Returns:
#   0: PIDs found.
#   1: No PIDs found.
#######################################
function __gk_resolve_pids() {
  local -r search_query_string="$1"
  local -n _resolved_pids_array="$2"

  _resolved_pids_array=()

  # Guard against empty pattern matching everything
  if [[ -z $search_query_string ]]; then
    return 1
  fi

  # Precompute ancestor PIDs so we never target our own invocation chain.
  local -a ancestor_pids_array=()
  __gk_collect_ancestor_pids ancestor_pids_array

  # 1. Check if input is a valid integer (PID)
  # Note: If a user provides a specific PID of a root process,
  # we still attempt to add it here.
  # The 'kill' command later will handle the "Permission denied" error.
  # This is standard behavior.
  if [[ $search_query_string =~ ^[0-9]+$ ]]; then
    # Verify it actually exists
    if __gk_process_exists "$search_query_string"; then
      _resolved_pids_array+=("$search_query_string")
      return 0
    fi
  fi

  # 2. Use pgrep to find by name/pattern (Extended Regex)
  # We verify pgrep availability in gkill main function.
  local -a pgrep_flags=()
  __gk_build_pgrep_flags pgrep_flags

  local raw_pgrep_output
  if raw_pgrep_output=$(pgrep "${pgrep_flags[@]}" "$search_query_string"); then
    local current_pid_item

    # Split by newlines
    while IFS= read -r current_pid_item; do
      # Skip self / ancestor processes (sudo, shells, etc.)
      if __gk_should_skip_pid ancestor_pids_array "$current_pid_item"; then
        continue
      fi

      _resolved_pids_array+=("$current_pid_item")
    done <<< "$raw_pgrep_output"
  fi

  if [[ ${#_resolved_pids_array[@]} -gt 0 ]]; then
    return 0
  fi

  return 1
}

#######################################
# Get the name of a process by PID for display.
#
# Arguments:
#   1: PID.
#
# Outputs:
#   Process name (comm) to stdout.
#######################################
function __gk_get_process_name() {
  local -ir pid_to_lookup="$1"
  local process_comm_name=''

  # ps -p <pid> -o comm= outputs just the command name without headers
  if process_comm_name=$(ps -p "$pid_to_lookup" -o comm= 2> /dev/null); then
    printf '%s' "$process_comm_name"
  else
    printf 'unknown'
  fi
}

#######################################
# Get the effective user (owner) of a process for display.
#
# Arguments:
#   1: PID.
#
# Outputs:
#   Process owner username to stdout.
#######################################
function __gk_get_process_owner() {
  local -ir pid_to_lookup="$1"
  local process_owner_name=''

  # ps -p <pid> -o user= outputs the effective username
  if process_owner_name=$(ps -p "$pid_to_lookup" -o user= 2> /dev/null); then
    printf '%s' "$process_owner_name"
  else
    printf 'unknown'
  fi
}

#######################################
# Get the full command line (args) of a process by PID.
#
# Arguments:
#   1: PID.
#
# Outputs:
#   Full command line to stdout.
#######################################
function __gk_get_process_cmdline() {
  local -ir pid_to_lookup="$1"
  local process_cmdline=''

  # ps -p <pid> -o args= outputs the full command line without headers
  if process_cmdline=$(ps -p "$pid_to_lookup" -o args= 2> /dev/null); then
    printf '%s' "$process_cmdline"
  else
    printf 'unknown'
  fi
}

#######################################
# Wait for a process to exit for a specified duration.
#
# Loops in small intervals checking if the process is still alive.
#
# Arguments:
#   1: PID to watch.
#   2: Max wait time in seconds.
#
# Returns:
#   0: Process is gone (success).
#   1: Process is still alive after timeout.
#######################################
function __gk_wait_for_pid_death() {
  local -ir pid_to_monitor="$1"
  local -ir timeout_limit_seconds="$2"

  # Calculate max cycles because we sleep 0.5s (2 cycles = 1 second)
  local -ir max_cycles=$((timeout_limit_seconds * 2))
  local -i current_cycle_count=0

  # Non-integer sleep supported by modern coreutils
  local -r check_interval_seconds=0.5

  while __gk_process_exists "$pid_to_monitor"; do
    if ((current_cycle_count >= max_cycles)); then
      return 1
    fi

    sleep "$check_interval_seconds"
    current_cycle_count=$((current_cycle_count + 1))
  done

  return 0
}

#######################################
# Execute a single signal step (Send -> Log -> Wait -> Check).
#
# Encapsulates the logic of trying a specific signal and waiting for result.
#
# Arguments:
#   1: PID.
#   2: Signal Number (e.g. 15 or 2).
#   3: Signal Name (e.g. "SIGTERM").
#   4: Timeout (seconds).
#   5: Verbose Flag (bool).
#   6: Color for log (string).
#
# Returns:
#   0: Process successfully terminated.
#   1: Process still alive or error sending signal.
#######################################
function __gk_attempt_signal_step() {
  local -ir target_pid="$1"
  local -ir signal_number="$2"
  local -r signal_label="$3"
  local -ir step_timeout_seconds="$4"
  local -r is_verbose_mode="$5"
  local -r log_color_code="$6"

  # 1. Send Signal
  __gk_log "$is_verbose_mode" \
    "  > Sending ${signal_label}..." \
    "$log_color_code" true

  if ! kill "-${signal_number}" "$target_pid" 2> /dev/null; then
    # Determine whether the PID still exists to refine the message.
    local reason_msg='Permission denied or PID gone'
    if __gk_process_exists "$target_pid"; then
      reason_msg='Permission denied'
    else
      reason_msg='PID already gone'
    fi

    __gk_log "$is_verbose_mode" " FAILED (${reason_msg})"
    return 1
  fi

  # 2. Wait
  if __gk_wait_for_pid_death "$target_pid" "$step_timeout_seconds"; then
    __gk_log "$is_verbose_mode" ' Terminated.'
    return 0
  fi

  # 3. Timeout reached
  __gk_log "$is_verbose_mode" ' Timed out.'

  return 1
}

#######################################
# Attempt to kill a single PID with escalation.
#
# Steps:
#   1. SIGTERM -> Wait
#   2. SIGINT  -> Wait
#   3. SIGKILL -> Check
#
# Arguments:
#   1: PID.
#   2: Timeout per signal (seconds).
#   3: Verbose flag (bool).
#   4: Dry-run flag (bool).
#
# Returns:
#   0: Successfully killed or already gone.
#   1: Failed to kill.
#######################################
function __gk_kill_single_pid() {
  local -ir pid_to_kill="$1"
  local -ir timeout_per_signal_seconds="$2"
  local -r enable_verbose_logging="$3"
  local -r enable_dry_run_mode="$4"

  local -r process_name="$(__gk_get_process_name "$pid_to_kill")"
  local -r process_owner="$(__gk_get_process_owner "$pid_to_kill")"

  # Local Colors
  local -r color_red='\033[31m'
  local -r color_yellow='\033[33m'
  local -r color_green='\033[32m'
  local -r color_reset='\033[0m'

  # Header Log (Always show if verbose or dry-run)
  local should_log_header=false
  if [[ $enable_verbose_logging == true || $enable_dry_run_mode == true ]]; then
    should_log_header=true
  fi

  if [[ $should_log_header == true ]]; then
    local -r header_log_msg=$(printf \
      'Targeting PID: %b%d%b (%s) [Owner: %s]' \
      "$color_yellow" "$pid_to_kill" "$color_reset" \
      "$process_name" "$process_owner")
    __gk_log true "$header_log_msg"
  fi

  # If process already died between discovery and handling, treat as success.
  if ! __gk_process_exists "$pid_to_kill"; then
    if [[ $enable_verbose_logging == true ]] \
      || [[ $enable_dry_run_mode == true ]]; then
      __gk_log true "$(printf '  Not running anymore. Skipping.')"
    fi
    return 0
  fi

  if [[ $enable_dry_run_mode == true ]]; then
    return 0
  fi

  # Step 1: SIGTERM (15)
  if __gk_attempt_signal_step \
    "$pid_to_kill" 15 'SIGTERM' "$timeout_per_signal_seconds" \
    "$enable_verbose_logging" "$color_green"; then
    return 0
  fi

  # Step 2: SIGINT (2)
  if __gk_attempt_signal_step \
    "$pid_to_kill" 2 'SIGINT' "$timeout_per_signal_seconds" \
    "$enable_verbose_logging" "$color_yellow"; then
    return 0
  fi

  # Step 3: SIGKILL (9)
  __gk_log "$enable_verbose_logging" \
    '  > Sending SIGKILL...' "$color_red" true

  kill -9 "$pid_to_kill" 2> /dev/null
  sleep 0.5 # Kernel cleanup time

  if ! __gk_process_exists "$pid_to_kill"; then
    __gk_log "$enable_verbose_logging" " Killed!"
    return 0
  fi

  # Failure
  local -r failure_log_msg=$(
    printf \
      '  %bERROR: PID %d is still alive (Zombie, or Permission Denied)%b' \
      "$color_red" "$pid_to_kill" "$color_reset"
  )
  # Always log error
  __gk_log true "$failure_log_msg"

  return 1
}

#######################################
# Parse command line arguments.
#
# Arguments:
#   1: Nameref for timeout (_timeout_seconds).
#   2: Nameref for dry_run (_is_dry_run).
#   3: Nameref for force flag (_is_force_mode).
#   4: Nameref for verbose (_is_verbose).
#   5: Nameref for help flag (_is_help_requested).
#   6: Nameref for input query (_search_query).
#   7+: Command line arguments ("$@").
#
# Returns:
#   0: Success.
#   1: Error during parsing.
#######################################
function __gk_parse_cli_args() {
  local -n _timeout_seconds="$1"
  local -n _is_dry_run="$2"
  local -n _is_force_mode="$3"
  local -n _is_verbose="$4"
  local -n _is_help_requested="$5"
  local -n _search_query="$6"
  shift 6

  # Default values
  _timeout_seconds=5
  _is_dry_run=false
  _is_force_mode=false
  _is_verbose=false
  _is_help_requested=false

  local OPTIND=1
  local current_option_flag
  local current_option_arg

  while getopts ':t:nfvh' current_option_flag; do
    case "$current_option_flag" in
      t)
        current_option_arg="$OPTARG"
        if [[ ! $current_option_arg =~ ^[0-9]+$ ]]; then
          __gk_error 'Timeout must be an integer.' "$GK_ERR_USAGE" \
            || return "$?"
        fi
        _timeout_seconds="$current_option_arg"
        ;;
      n)
        _is_dry_run=true
        ;;
      f)
        _is_force_mode=true
        ;;
      v)
        _is_verbose=true
        ;;
      h)
        _is_help_requested=true
        return 0
        ;;
      :)
        __gk_error "Option -$OPTARG requires an argument." \
          "$GK_ERR_USAGE" \
          || return "$?"
        ;;
      \?)
        __gk_error "Invalid option: -$OPTARG" \
          "$GK_ERR_USAGE" \
          || return "$?"
        ;;
    esac
  done
  shift $((OPTIND - 1))

  if [[ $# -eq 0 ]]; then
    __gk_error 'No PID or process name specified.' \
      "$GK_ERR_USAGE" \
      || return "$?"
  fi

  _search_query="$1"

  # Validate empty query here to avoid downstream issues
  if [[ -z $_search_query ]]; then
    __gk_error 'PID or process name cannot be empty.' \
      "$GK_ERR_USAGE" \
      || return "$?"
  fi

  return 0
}

#######################################
# Show targets table and optionally ask for confirmation.
#
# In dry-run mode, only prints the table with a DRY-RUN header.
# In normal mode, prints the table and asks the user to confirm.
#
# Arguments:
#   1: Nameref array of PIDs.
#   2: Dry-run flag (bool).
#
# Returns:
#   0: Proceed / acknowledged (or dry-run).
#   1: User declined to proceed (normal mode).
#######################################
function __gk_show_targets() {
  local -n _in_target_pids_array="$1"
  local -r is_dry_run_mode="$2"

  local -r color_red='\033[31m'
  local -r color_reset='\033[0m'

  if [[ $is_dry_run_mode == true ]]; then
    printf '\nDRY-RUN: The following processes match your query:\n'
  else
    printf '\nThe following processes will be %bTERMINATED%b:\n' \
      "$color_red" "$color_reset"
  fi

  # Header row
  printf '  %-8s %-12s %-20s %s\n' \
    'PID' 'Owner' 'Name' 'CMD'

  local current_pid
  local current_proc_name
  local current_proc_owner
  local current_proc_cmdline

  for current_pid in "${_in_target_pids_array[@]}"; do
    current_proc_name=$(__gk_get_process_name "$current_pid")
    current_proc_owner=$(__gk_get_process_owner "$current_pid")
    current_proc_cmdline=$(__gk_get_process_cmdline "$current_pid")

    printf '  %-8d %-12s %-20s %s\n' \
      "$current_pid" "$current_proc_owner" \
      "$current_proc_name" "$current_proc_cmdline"
  done

  if [[ $is_dry_run_mode == true ]]; then
    printf '\n'
    return 0
  fi

  printf '\nDo you want to continue? [y/N] '
  local user_response
  read -r user_response

  if [[ $user_response =~ ^[yY]([eE][sS])?$ ]]; then
    return 0
  fi

  return 1
}

#######################################
# Iterate over target PIDs and attempt termination.
#
# Arguments:
#   1: Name of array with PIDs (nameref).
#   2: Timeout (int).
#   3: Verbose flag (bool).
#   4: Dry run flag (bool).
#   5: Nameref for failure count output (_failure_count).
#######################################
function __gk_process_batch_termination() {
  local -n _in_targets_pids_array="$1"
  local -ir timeout_limit="$2"
  local -r is_verbose="$3"
  local -r is_dry_run="$4"
  local -n _failure_count="$5"

  _failure_count=0
  local current_target_pid

  for current_target_pid in "${_in_targets_pids_array[@]}"; do
    if ! __gk_kill_single_pid \
      "$current_target_pid" \
      "$timeout_limit" \
      "$is_verbose" \
      "$is_dry_run"; then
      _failure_count=$((_failure_count + 1))
    fi
  done
}

#######################################
# Main logic orchestrator.
#
# Arguments:
#   $@: Command line arguments.
#
# Returns:
#   0: Success.
#   Non-zero: Error.
#######################################
function gkill() {
  local -i timeout_duration_seconds=0
  local is_dry_run_mode=false
  local is_force_mode=false
  local is_verbose_mode=false
  local is_help_requested=false
  local user_search_query=''

  # 1. Parse Arguments
  __gk_parse_cli_args \
    timeout_duration_seconds \
    is_dry_run_mode \
    is_force_mode \
    is_verbose_mode \
    is_help_requested \
    user_search_query \
    "$@" || return "$?"

  # 2. Handle Help
  if [[ $is_help_requested == true ]]; then
    __gk_usage
    return 0
  fi

  # 3. Dependency Check (pgrep is critical)
  if ! command -v pgrep > /dev/null 2>&1; then
    __gk_error 'Required utility "pgrep" is not installed.' \
      "$GK_ERR_MISSING_DEPENDENCY" \
      || return "$?"
  fi

  # 4. Resolve PIDs
  local -a resolved_target_pids_array=()
  if ! __gk_resolve_pids \
    "$user_search_query" \
    resolved_target_pids_array; then
    __gk_error "No running processes found matching: '$user_search_query'" \
      "$GK_ERR_NO_PROCESS" \
      || return "$?"
  fi

  local -ir total_processes_count=${#resolved_target_pids_array[@]}
  # At this point we know there is at least one PID.

  # 5. Dry-run: show table and exit
  if [[ $is_dry_run_mode == true ]]; then
    __gk_show_targets resolved_target_pids_array true
    return 0
  fi

  # 6. Confirmation (only if NOT force)
  if [[ $is_force_mode == false ]]; then
    if ! __gk_show_targets resolved_target_pids_array false; then
      __gk_log true 'Aborted by user.'
      return 0
    fi
  fi

  # 7. Process Batch
  local -i failed_terminations_count=0
  __gk_process_batch_termination \
    resolved_target_pids_array \
    "$timeout_duration_seconds" \
    "$is_verbose_mode" \
    false \
    failed_terminations_count

  # 8. Final Report/Exit
  if [[ $failed_terminations_count -gt 0 ]]; then
    local -r final_error_msg=$(printf \
      'Failed to terminate %d/%d processes.' \
      "$failed_terminations_count" "$total_processes_count")
    __gk_error "$final_error_msg" "$GK_ERR_PARTIAL_FAILURE" \
      || return "$?"
  fi

  return 0
}

# Execution Guard:
# If the script is executed directly (not sourced), run the main function.
# If sourced, do nothing (just load the function).
if [[ $GK_SCRIPT_SOURCED == false ]]; then
  gkill "$@"
  exit_code=$?
  exit "$exit_code"
fi
### End
