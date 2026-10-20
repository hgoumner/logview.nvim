# logview.nvim

A dependency-free Lua plugin for Neovim 0.10+ that highlights log timestamps
and severity levels in place. Static log viewing does not rewrite text, change
the filetype, open another buffer, or install key mappings. Live commands can
also stream stdout into a dedicated log buffer.

## LazyVim installation

Add this spec to `lua/plugins/logview.lua` in your Neovim configuration:

```lua
return {
  {
    "hgoumner/logview.nvim",
    main = "logview",
    cmd = { "LogView", "LogFilter", "LogStream", "LogStreamStop" },
    event = { "BufReadPre *.log", "BufNewFile *.log" },
    opts = {
      auto = true,
      patterns = { "*.log" },
      error_background = 0.16,
    },
  },
}
```

For local development, replace `"hgoumner/logview.nvim"` with
`dir = "/path/to/logview.nvim"`. No changes to your existing Neovim
configuration are made by this project.

For Neovim's native package loader, place this directory in
`pack/plugins/start/logview.nvim`. It works with default settings immediately;
optionally call `require("logview").setup({ ... })` to configure it.

## Usage

| Command | Effect |
| --- | --- |
| `:LogView` or `:LogView on` | Enable highlighting for the current buffer, including pasted logs |
| `:LogView off` | Remove highlighting and clear any level filter from the current buffer |
| `:LogView toggle` | Toggle highlighting for the current buffer |
| `:LogFilter WARN` | Show WARN, ERROR and FATAL entries with their continuation lines |
| `:LogFilter ALL` | Clear the filter and show every line again |
| `:LogStream tail -n 100 -F /path/app.log` | Show a command's live stdout in the current window |
| `:LogStreamStop` | Stop the current stream, retaining its captured output |

Normal `*.log` buffers activate automatically. Highlighting follows edits,
appended lines, scrolling, and colorscheme changes. Explicitly disabling a
buffer keeps it disabled until you enable it again or wipe the buffer.
Other buffers are unaffected.

Highlighting parses only visible lines, using temporary decorations on each redraw.
Static highlighting needs no full-file scan, background job, or stored copy of the log.
Stack traces and other unrecognized text remain untouched; severity coloring
does not carry over to continuation lines.

### Live command output

Run a shell command with `:LogStream`, for example:

```vim
:LogStream tail -n 100 -F /path/app.log
:LogStream journalctl -f -o short-iso --no-pager
:LogStream kubectl logs -f my-pod
```

Or start it from your shell (after installing the plugin):

```sh
nvim -c 'LogStream tail -n 100 -F /path/app.log'
```

The command runs asynchronously through Neovim's configured shell, in the
current working directory, with stdin disconnected. Shell quoting, pipes and
redirects work normally; run only commands you trust. This is not a terminal:
interactive commands and password prompts are not supported. Producers may
need their own unbuffered-output option (for example, `python -u`).

Stdout appears in a read-only scratch buffer in the current window, without
opening a split. Your previous file buffer is not deleted. Partial lines are
updated as chunks arrive, without inserting extra line breaks. CRLF line
endings are handled; terminal escape sequences and carriage-return progress
animations are not interpreted. Prefer plain, non-colored output.

Each window follows new output while its cursor is on or beyond the last visible line
and that line is in view. Move up to pause following; press `G` to resume
even with a filter active. `:LogFilter ERROR` works on
live output too, including new entries and stack traces. Hidden lines remain
in the buffer, and captured output grows without a size cap.

Stderr is reported through `vim.notify`, separately from the log; to include it
in the log use shell redirection, such as `:LogStream my-command 2>&1`.
A nonzero exit status produces an error notification. A successful exit leaves
the captured output available. `:LogStreamStop` stops the producer without
discarding that output; closing/unloading the stream buffer or exiting Neovim
also stops it. `:LogView off` only disables highlighting/filtering, not the job.
The scratch buffer is wiped when its last window closes; save a copy first
with `:write! /path/captured.log` if you want to keep it.

For Lua callers, `require("logview.stream").open(command)` accepts a shell
command string or an argv list (which bypasses the shell), and returns the
buffer number and job ID. `stop(bufnr)` stops that buffer's producer; omit the
number for the current buffer. Buffer variables `logview_stream_job`,
`logview_stream_running`, and `logview_stream_exit_code` expose job status.

### Filtering

Filtering requires **Neovim 0.11+** (highlighting still works on 0.10).
Use `:LogFilter LEVEL` with `TRACE`, `DEBUG`, `INFO`, `WARN`, `ERROR`, or
`FATAL`. Level names are case-insensitive and accept the aliases listed below.
The threshold is inclusive: `ERROR` shows both ERROR and FATAL entries.
As with highlighting, the strongest detected level on a line determines its
severity.

Lines without a recognized level inherit the preceding entry's level for
filtering, preserving stack traces and multiline messages. Unclassified lines
before the first recognized entry are hidden. `TRACE` therefore shows all
recognized entries and their continuations, whereas `ALL` restores every line,
including unclassified headers.

Nonmatching lines are concealed in the original buffer, not deleted or copied
to another buffer. A filter scans the full buffer when applied, then recomputes
from the changed entry/range after edits or appends; highlighting alone remains
viewport-only.
If nothing matches, the view is empty and the command reports zero visible
lines. Clear the filter with `:LogFilter ALL` or `:LogView off`.

Filters apply to every window displaying the filtered buffer. While filtering,
the plugin temporarily sets `conceallevel=3` and `concealcursor=nvic`, restoring
each window's previous values when the filter is cleared or the window switches
buffers. Navigation retains original line numbers. The underlying buffer is
unchanged: saving, searching, copying ranges, and other editing commands can
still include hidden lines.

### Recognized formats

Timestamp detection is independent of severity detection, so mixed-format logs
and lines containing only one of these fields work too:

```text
2026-10-20T11:28:04.646Z INFO application started
2026-10-20 11:28:04,646 WARNING retrying
[2026-10-20, 11:28:04.646 UTC] ERROR - task failed
2026/10/20 11:28:04 [error] upstream unavailable
26/10/20 11:28:04 WARN Spark logger
Oct 20 11:28:04 host service: ERROR failed
[20/Oct/2026:11:28:04 +0000] INFO request
11:28:04.646 DEBUG message
{"timestamp":"2026-10-20T11:28:04+02:00","level":"error","message":"failed"}
ERROR: script returned exit code 1
```

Fractions using `.` or `,`, `Z`, numeric timezone offsets (`+02:00` or `+0200`),
and common timezone abbreviations are supported. Timestamps are highlighted,
not normalized or converted. Detection is heuristic, not a strict date validator
or a full JSON parser; Unix epoch numbers are deliberately not guessed.

Levels are `TRACE`, `DEBUG`, `INFO`, `WARN`/`WARNING`, `ERR`/`ERROR`, and
`FATAL`/`CRIT`/`CRITICAL`. Syslog's `NOTICE` maps to info, and
`ALERT`/`EMERG`/`EMERGENCY` map to fatal. Uppercase standalone level tokens are
recognized anywhere. Mixed/lowercase levels are recognized at the start of a
line, after a timestamp, inside square brackets, or in `level`/`severity`
fields. Ordinary lowercase prose and level words inside filenames or identifiers
are left alone. If several levels occur on one line, the strongest controls
the error background.

### Configuration and colors

```lua
require("logview").setup({
  auto = true,                     -- false: activate only with :LogView
  patterns = { "*.log", "*.out" }, -- filename globs for automatic activation
  error_background = 0.16,         -- 0 disables the tint; range: 0 to 1
})
```

With lazy.nvim, put these settings in the spec's `opts` instead.
An existing buffer's enabled/disabled state survives repeated `setup()` calls.
Configuration changes to automatic activation apply to buffers without an
existing state, not buffers you already activated.

Colors inherit your active theme (including TokyoNight), rather than hard-coded
severity colors:

| Highlight group | Default link |
| --- | --- |
| `LogViewTimestamp` | `Special` |
| `LogViewTRACE` | `Comment` |
| `LogViewDEBUG` | `DiagnosticHint` |
| `LogViewINFO` | `DiagnosticInfo` |
| `LogViewWARN` | `DiagnosticWarn` |
| `LogViewERROR`, `LogViewFATAL` | `DiagnosticError` |

`LogViewErrorLine` blends the diagnostic error color into `Normal`'s background
and is recomputed when the colorscheme changes. Transparent themes use a dark
or light fallback background for this tint; use `error_background = 0` to keep
all backgrounds transparent.
Token highlight links can be overridden with `vim.api.nvim_set_hl`.
To keep overrides across theme changes, set them in a `ColorScheme` autocmd.
This plugin does not disable existing syntax or Tree-sitter highlighting.

The Lua API also provides `enable(bufnr)`, `disable(bufnr)`, `toggle(bufnr)`,
and `is_enabled(bufnr)`. Omit the buffer number (or pass `0`) for the current
buffer. `filter(level, bufnr)` applies a minimum-severity filter and returns the
visible and total line counts; `filter("ALL", bufnr)` clears it.

## Development

Run the dependency-free tests from the project directory:

```sh
nvim --headless -u NONE -l tests/run.lua
```
