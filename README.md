# gkill

A small, focused CLI helper to gracefully terminate Unix processes with signal escalation.

`gkill` wraps the standard `kill`/`pgrep` tooling and adds:

* a **safe escalation chain** (`SIGTERM → SIGINT → SIGKILL`) with configurable timeouts,
* **smart process selection** by PID or extended regular-expression pattern,
* **interactive confirmation** by default, plus dry-run and verbose modes.

---

## Features

1. **Graceful signal escalation**

   * Tries `SIGTERM` first to give the process a chance to shut down cleanly.
   * If the process survives, sends `SIGINT` and waits again.
   * As a last resort, sends `SIGKILL` and performs a final liveness check.
   * Timeout between signals is configurable via `-t <seconds>`.

2. **Flexible targeting (PID or pattern)**

   * Accepts either a **numeric PID** or an **Extended Regular Expression** pattern.
   * Uses `pgrep -f` to match against the full command line.
   * When running as a normal user, only targets **your own processes**.
   * When run via `sudo` or as root, searches **all system processes**.

3. **Self‑protection & safer defaults**

   * Walks the parent PID chain and automatically excludes:

     * the script itself,
     * parent shells,
     * `sudo` / `doas` / other wrappers up to PID 1.
   * This prevents accidentally killing the very shell session that launched `gkill`.

4. **Dry‑run and interactive confirmation**

   * `-n` / dry‑run: resolve and display matching processes without sending any signals.

   * In normal mode, shows a table of targets and asks:

     ```text
     Do you want to continue? [y/N]
     ```

   * `-f` / force mode: skip the confirmation prompt and proceed immediately.

5. **Verbose, TTY‑aware logging**

   * `-v` prints detailed steps for each PID (signals sent, timeouts, outcomes).
   * Automatically disables ANSI colors when stdout is not a TTY (e.g. when piping).
   * Clear separation between **info logs** and **error messages**.

6. **Script or function usage**

   * When executed directly, runs the `gkill` function and exits with its return code.
   * When sourced, only defines the `gkill` function and helpers; your shell remains in control.
   * The same exit codes are used whether the tool is executed or returned from.

> [!TIP]
> `gkill` is ideal when a process misbehaves and you want to **try clean shutdown first** before falling back to `kill -9`.

---

## Requirements

* Bash (tested with modern Bash; uses functions, arrays, `[[ ... ]]`, `getopts`, etc.)
* Standard Unix utilities: `ps`, `kill`, `pgrep`, `printf`, `sleep`
* A POSIX‑like environment (Linux, BSD, WSL, etc.)

The script has **no external runtime dependencies** beyond standard core utilities.

---

## Installation

### 1. Place the script somewhere permanent

Clone or download the script into a directory of your choice, then install it on your `PATH`:

```bash
chmod +x gkill.sh
ln -s /path/to/gkill.sh /usr/local/bin/gkill
```

Ensure `/usr/local/bin/` is on your `PATH` (for example by exporting it in your shell profile).

### 2. Or source it for function‑style use

If you prefer to define `gkill` as a shell function in every interactive session without spawning an extra process,
you can source the script from your shell startup file:

```bash
# ~/.bashrc or ~/.profile

if [[ -f "/path/to/gkill.sh" ]]; then
  # Source to make `gkill` function available in the current shell
  # (the script auto‑detects whether it was sourced or executed).
  source "/path/to/gkill.sh"
fi
```

Reload your shell configuration:

```bash
source ~/.bashrc
```

When executed as a script, `gkill.sh` runs `gkill "$@"` and exits with an appropriate status code.

---

## Quick start

### Kill processes by name pattern

```bash
# Gracefully terminate all matching processes for the current user
gkill geany

# As root, search across all users
sudo gkill sshd
```

### Dry‑run first

```bash
# Show what would be terminated, but send no signals
gkill -n geany
```

Dry‑run mode prints the same process table as normal mode, but with a **DRY‑RUN** header and without the confirmation prompt.

### Increase the timeout between signals

```bash
# Wait up to 10 seconds after each signal before escalating
gkill -t 10 my_long_running_app
```

### Verbose logging

```bash
# See detailed signal steps for each PID
gkill -v my_app
```

Verbose mode shows which signal was sent, whether it succeeded, and how the timeout resolved.

### Force mode (no confirmation)

```bash
# Immediately escalate through the signal chain without asking
gkill -f my_app
```

> [!IMPORTANT]
> `-f` can terminate multiple processes at once without additional prompts. Consider using a dry‑run (`-n`) first when working with broad regex patterns.

### Kill by explicit PID

```bash
# Terminate a single known PID
gkill 12345
```

If the PID no longer exists when `gkill` runs, it is treated as a successful no‑op.

---

## Pattern semantics

`gkill` treats the `<pattern>` argument as an **Extended Regular Expression (ERE)** and uses `pgrep -f` to match against the **full command line** of running processes.

Some examples:

```bash
# Any command line containing "geany"
gkill geany

# Commands whose name or args start with "python"
gkill '^python'

# Rough equivalent of shell wildcard "myapp*"
gkill 'myapp.*'
```

> [!CAUTION]
> Remember that regex and shell globs are different:
>
> * `ge.*`  - regex: "ge" followed by any characters (including none).
> * `ge*`   - regex: "g" followed by zero or more `e` characters; this may match just `g`.
>
> If in doubt, run with `-n` first to inspect the list of matching processes.

---

## Command‑line usage

```bash
gkill [-f] [-t seconds] [-n] [-v] [-h] <pid|pattern>
```

### Options

| Option         | Type      | Default    | Description                                                               |                                                                             |
| -------------- | --------- | ---------- | ------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| `-h`           | flag      | -          | Show help/usage and exit.                                                 |                                                                             |
| `-f`           | flag      | `false`    | **Force mode**: skip the confirmation prompt and start termination.       |                                                                             |
| `-t <seconds>` | integer   | `5`        | Timeout to wait after each signal before escalating to the next one.      |                                                                             |
| `-n`           | flag      | `false`    | **Dry‑run**: resolve and list targets, but do not send any signals.       |                                                                             |
| `-v`           | flag      | `false`    | **Verbose** output: log every signal step and timeout result per process. |                                                                             |
| `<pid          | pattern>` | positional | -                                                                         | Target PID or Extended Regex pattern to match against process command line. |

Behavior summary:

* With a **PID**, `gkill` attempts to terminate exactly that process.
* With a **pattern**, it uses `pgrep` and may match multiple processes.
* Without a PID/pattern, usage is considered invalid and `gkill` returns an error.

---

## Signal escalation model

For each target PID, `gkill` performs the following steps (unless in dry‑run mode):

1. **Check liveness** - if the PID is already gone, it is treated as success.
2. **Send `SIGTERM` (15)** and wait up to `-t` seconds.
3. If still alive, **send `SIGINT` (2)** and wait up to `-t` seconds again.
4. If the process still has not exited, **send `SIGKILL` (9)** and wait briefly.
5. If the PID survives even `SIGKILL`, `gkill` reports a failure for that process (likely a zombie or permission issue).

Each of these steps is logged when `-v` is enabled.

---

## Exit codes

`gkill` uses structured exit codes for reliable scripting.

When executed as a script, it calls `exit` with these codes. When sourced, the `gkill` function
**returns** the same codes.

| Code | Constant                    | Meaning                                                              |
| ---- | --------------------------- | -------------------------------------------------------------------- |
| `0`  | -                           | Success (all targeted processes terminated, or operation cancelled). |
| `1`  | `GK_ERR_GENERAL`            | General or unexpected error.                                         |
| `2`  | `GK_ERR_USAGE`              | Invalid usage (bad arguments, missing PID/pattern, invalid timeout). |
| `3`  | `GK_ERR_NO_PROCESS`         | No running processes matched the given PID or pattern.               |
| `4`  | `GK_ERR_PARTIAL_FAILURE`    | Some processes could not be terminated (e.g. permission denied).     |
| `5`  | `GK_ERR_MISSING_DEPENDENCY` | Required system utility (currently `pgrep`) is missing.              |

Example usage in a script:

```bash
if ! gkill -f my_app; then
  echo "gkill failed with code $?" >&2
fi
```

---

## Safety & limitations

* `gkill` does **not** attempt to inspect or manage process trees; it only targets the PIDs returned by `pgrep` or passed explicitly.
* When run as root, it can terminate **any** process that the OS allows; double‑check patterns and consider a dry‑run before forcing.
* Processes that are in a zombie state or protected by special kernel mechanisms may remain even after `SIGKILL`.

> [!WARNING]
> Use with care on production systems. Signal‑based termination can cause data loss if applications are not designed to handle abrupt shutdown.

---

## License

This project is licensed under the [MIT License](./LICENSE).

---

## Contributing

Bug reports and pull requests are welcome.

If you encounter edge cases (e.g. certain process trees, unusual init systems, or platform‑specific behavior), 
please document how to reproduce the scenario so that `gkill` can remain robust and maintainable over time :innocent:
