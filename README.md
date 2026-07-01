# notepad-replacer-go

Redirects `notepad.exe` to a different editor of your choice, system-wide, via the
Windows `Image File Execution Options` (IFEO) "Debugger" hijack. Comes with an
NSIS installer that asks for your target editor + args and writes the config for you.

## Files

| File                        | Purpose                                                              |
|-----------------------------|-----------------------------------------------------------------------|
| `main.go`                   | Source for `invis.exe` — the native shim that reads `config.json` and launches the real editor, hidden. |
| `invis.exe`                 | Compiled shim (see build instructions below). Primary/recommended option. |
| `invis.vbs`                 | Self-contained VBScript fallback shim — same job as `invis.exe`, for cases where an unsigned `.exe` gets blocked (SmartScreen, AV policy, etc). |
| `NotepadReplacerSetup.nsi`  | NSIS installer script — asks for the editor path/args, writes `config.json`, registers the IFEO key. |
| `NotepadReplacerSetup.exe`  | Compiled installer (see build instructions below). |
| `config.json`               | Written to `%USERPROFILE%\.notepad-replacer\config.json` by the installer. `{ "exe": "...", "args": [...] }` |
| `uninstall.exe`             | Removes the registry key + installed files. |

## How it works

1. The installer writes `notepad.exe`'s `Debugger` value under
   `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\`
   (and the Wow6432Node equivalent) to point at `invis.exe` (or `invis.vbs`).
2. Whenever Windows is about to launch `notepad.exe`, it launches the shim instead,
   passing the original command line through.
3. The shim reads `config.json`, then launches the configured editor with your
   default args plus the file Windows was trying to open in Notepad.

Since `notepad.exe` only ever opens one file at a time, the shim always rejoins any
trailing arguments into a single filename before handing off — this also papers over
a common Windows quirk where a file association's `open` command doesn't quote its
`%1` placeholder, which otherwise splits filenames with spaces into multiple words.

Requires admin rights, since IFEO lives under `HKLM`.

## Build instructions

### `invis.exe` (from `main.go`)

1. Install Go (1.20+ recommended) from https://go.dev/dl/
2. Open an elevated command prompt, and from the directory containing `main.go`, run:
   ```
   go build -ldflags="-s -w" -o invis.exe main.go
   ```
   (`-ldflags="-s -w"` strips debug symbols/DWARF info to keep the binary smaller.)

### `NotepadReplacerSetup.exe` (from `NotepadReplacerSetup.nsi`)

1. Install NSIS (3.x) from https://nsis.sourceforge.io/Download
2. Make sure `invis.exe` and `invis.vbs` are present in the same directory as the
   `.nsi` script — the installer packages them via `File "invis.exe"` / `File "invis.vbs"`.
3. Right-click `NotepadReplacerSetup.nsi` → **Compile NSIS Script**, or from a command
   prompt:
   ```
   makensis NotepadReplacerSetup.nsi
   ```
4. This produces `NotepadReplacerSetup.exe` in the same directory.

No third-party NSIS plugins are required — `config.json` reading/writing is
hand-rolled directly in the `.nsi` script (see `JsonExtractString` /
`WriteConfigJson`), rather than depending on a JSON plugin's exact array semantics.

## Reconfiguring

Re-run `NotepadReplacerSetup.exe`. If a registry key already exists, you'll be asked
whether to remove it (uninstall) or keep going (reconfigure) — reconfiguring re-opens
the editor-path/args page pre-filled with your current `config.json` values.

## Uninstalling

Run `uninstall.exe` from the install directory (`%USERPROFILE%\.notepad-replacer\`),
or use the installer's own prompt when it detects an existing installation.

## Copyright, License

Original Node.js version: MIT © Oliver Lohmann https://github.com/olohmann/notepad-replacer

Go, NSIS version: MIT © 2026 oshirinap, Claude
