# Vibe Status

Vibe Status is a native, dockless macOS menu-bar app that monitors loaded root
Codex CLI tasks on remote hosts. It connects through aliases already configured
in OpenSSH and never acts as another chat client.

The menu bar always shows three counts:

- Blue — working but waiting for user input or approval
- Yellow — working
- Green — ready for the next turn

Opening the popover groups tasks by those states. Spawned subagents and
temporary side conversations do not appear as separate tasks. Host and protocol
errors appear separately from the counts.

## Tester requirements

- macOS 14 or newer
- One or more literal aliases in `~/.ssh/config`
- Key- or agent-based SSH authentication that works non-interactively
- Codex CLI 0.145.0 or a compatible newer version on each remote host

Vibe Status does not store passwords, private keys, or SSH-agent credentials.
`BatchMode=yes` is intentional, so hosts that require a password or MFA prompt
for every connection are not supported. Before onboarding, confirm that this
works without a password prompt:

```sh
ssh -T <ssh-alias> true
```

## First-run setup

1. Launch Vibe Status and open its menu-bar popover.
2. Select one or more aliases discovered from your SSH configuration, or enter
   a literal alias manually.
3. Optionally edit the display name.
4. Leave the Codex path empty for automatic detection. If detection fails,
   enter an absolute path or a path beginning with `$HOME/`.
5. Test every enabled host, then select **Start Monitoring**.

No hosts are selected automatically on a clean installation. Existing saved
host profiles continue to load after upgrades.

Automatic detection checks the remote non-interactive `PATH`, the common
`$HOME/.local/bin/codex` location, and finally the remote account's login
shell. The resolved absolute path is saved in that host profile.

## Remote behavior

For each enabled host, Vibe Status launches one local `/usr/bin/ssh` child:

```text
NSStatusItem
  ← DashboardModel
  ← MonitoringEngine
  ← ClusterSupervisor
  ← CodexRPCClient
  ← SwiftNIO WebSocket over SSH stdin/stdout
  ← remote Codex app-server daemon
```

After resolving the configured Codex executable, the remote operation is
equivalent to:

```sh
"<remote-codex-path>" app-server daemon start 1>&2 &&
exec "<remote-codex-path>" app-server proxy
```

`daemon start` is idempotent and reuses a daemon already started by
`codex remote-control start`. Vibe Status never stops or restarts the remote
daemon and never changes Remote Control settings.

Only these app-server operations are sent:

- `initialize`
- `initialized`
- `thread/loaded/list`
- `thread/read` with `includeTurns: false`
- `thread/unsubscribe`

Vibe Status does not send prompts, turns, approvals, filesystem operations, or
configuration mutations. Unexpected server requests receive a
method-not-supported response and are never approved.

## Data and privacy

Host aliases, labels, resolved executable paths, enabled state, and preferences
are stored in versioned `UserDefaults`.

Codex metadata-only responses can include a task name, prompt preview, working
directory, status, and timestamps. Vibe Status may use the first preview line
as a display-name fallback. This task metadata, all counts, and bounded SSH
diagnostics remain in memory and are discarded when the app exits. There is no
transcript cache, analytics, or telemetry.

“Open” follows Codex's loaded-thread semantics. Codex may retain an
unsubscribed task during its unload grace period; Vibe Status does not infer
Terminal-tab state.

## Development requirements

- A full Xcode installation with the macOS SDK selected by `xcode-select`
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) when regenerating the
  committed project

Build the app:

```sh
brew install xcodegen
sh scripts/generate_project.sh
xcodebuild \
  -project VibeStatus.xcodeproj \
  -scheme VibeStatus \
  -configuration Debug \
  -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
open DerivedData/Build/Products/Debug/VibeStatus.app
```

If your active developer directory points at Command Line Tools instead of
Xcode, select the full toolchain first or set `DEVELOPER_DIR` for the command.

Run the core tests:

```sh
swift test --disable-sandbox
```

Run the macOS app and core tests:

```sh
xcodebuild \
  -project VibeStatus.xcodeproj \
  -scheme VibeStatus \
  -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  test
```

The generated `VibeStatus.xcodeproj` is included alongside `project.yml`.
Regenerate it after adding or removing source files.

## Diagnostic probes

The Python protocol spike requires an explicit remote path and avoids printing
task names, prompt previews, or working directories:

```sh
python3 Tools/codex_proxy_spike.py <ssh-alias> \
  --codex-path '$HOME/.local/bin/codex'
```

The compiled Swift probe uses the same automatic path detection as onboarding:

```sh
swift run --disable-sandbox vibe-status-probe <ssh-alias>
```

Both tools list only loaded identifiers internally, immediately unsubscribe,
read metadata without turns, and print aggregate counts.

## Distribution status

The repository still produces a local development build. A friend-facing
binary should be built in Release configuration and signed/notarized before
general distribution. Until that packaging step is added, share source or a
clearly labeled development build rather than treating the Debug artifact as a
finished release.
