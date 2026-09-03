# cleanup scripts

The batch files the app's **Cleanup…** dialog lists and runs. They are published to
`dist\cleanup\` next to `DiskSizeGrowthMon.exe`, and the dialog also lists any `*.bat` you drop
directly beside the exe.

Nothing runs on its own. You double-click one, watch its output, and it stops when it stops.

| Script | What it clears | Notes |
|---|---|---|
| `01-node-caches.bat` | npm, yarn, pnpm, bun, node-gyp, Electron download caches | `node_modules` is never touched |
| `02-dev-toolchain-caches.bat` | NuGet/.NET, pip/uv/poetry, Gradle build cache, cargo registry, Go build cache | Leaves Gradle `modules-2` and the Go module cache alone |
| `03-temp-files.bat` | `%TEMP%`, `C:\Windows\Temp`, crash dumps, WER reports, WinINet cache | Skips `%TEMP%\.net` — the running app's own extracted libraries live there |
| `04-windows-update-cache.bat` | `SoftwareDistribution\Download`, Delivery Optimization, `catroot2` | Stops and restarts wuauserv/BITS/DoSvc/CryptSvc |
| `05-windows-cleanmgr.bat` | Disk Cleanup, unattended, safe handlers only | Writes its own `StateFlags4242`; excludes Windows.old and the ESD image |
| `06-dism-component-store.bat` | Superseded WinSxS component versions | 5–20 minutes, no output while it works. No `/ResetBase` |
| `07-shell-and-gpu-caches.bat` | Thumbnail, icon, font and D3D/NVIDIA/AMD/Intel shader caches | Does not restart Explorer; locked cache files are reported and left |
| `08-recycle-bin.bat` | The Recycle Bin, all drives | **The only script that can lose something you wanted.** Prints sizes first |
| `09-docker-prune.bat` | Stopped containers, dangling images, build cache | No `--volumes`, no `-a`. Run `10-` after it to give the space back to Windows |
| `10-wsl-compact-vhdx.bat` | Compacts WSL2 `ext4.vhdx` files | Shuts down every distro. Asks for confirmation in a dialog first |
| `11-gradle-caches.bat` | `~\.gradle\caches\*` except the downloads, plus daemon logs | Stops the daemons first. No re-download — just one slower build |
| `12-gradle-deep-clean.bat` | `caches\modules-2` and `wrapper\dists` | Confirms first: this one costs a full dependency re-download |
| `13-android-studio-and-sdk-caches.bat` | Studio index/caches/logs, SDK scratch dirs, `~\.android\cache` | Refuses while Studio is open. Reports SDK component sizes rather than guessing what is unused |
| `14-android-emulator-snapshots.bat` | AVD Quick Boot snapshots and `/cache` | Apps and data survive; next launch is a cold boot. Confirms first |
| `15-android-emulator-wipe-data.bat` | AVD `userdata`, snapshots, `/cache`, SD-card delta | **Factory-resets every emulator.** Confirms first |

`_common.cmd` holds the shared prologue/epilogue and helpers: the UTF-8 code page, the free-space
before/after summary, `rmdir` (refuses to touch a drive root), `dirsize` (for the "here is what is
big, prune it yourself" reports), `running` (is an IDE or emulator holding these files open?) and
`confirm` (the yes/no dialog). It is a `.cmd` rather than a `.bat` so the dialog, which globs
`*.bat`, never offers it as a runnable script.

`confirm` and `dirsize` pass their text to PowerShell through **environment variables** rather than
interpolating it into the command line. That is not stylistic: an apostrophe in the message
(`Gradle's downloads`) closes PowerShell's single-quoted string, the command dies with a parse
error, and the non-zero exit reads back as "the user said no" — so the script silently does nothing,
every time.

## Writing your own

Any `.bat` in this folder or beside the exe shows up in the dialog. Two things to know about how
the app runs them:

- **stdin is closed.** A script that reads input gets EOF rather than hanging forever, so `set /p`
  and `pause` return immediately. `timeout` refuses to run at all — use
  `ping -n <seconds+1> 127.0.0.1 > nul` to sleep. For a real prompt, pop a dialog the way
  `10-wsl-compact-vhdx.bat` does.
- **Output is decoded as UTF-8.** Start with `chcp 65001 > nul`, or call
  `call "%~dp0_common.cmd" begin "description"` which does it for you.

They run elevated, because the app is. `net session > nul 2>&1` is the usual check for scripts that
need it.
