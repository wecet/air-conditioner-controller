# Local development and deployment

## Prerequisites

- macOS 14+ on Apple Silicon or Intel.
- Apple's Xcode Command Line Tools, with `swiftc`, `codesign`, `plutil`, and `ditto` on PATH.
- A compatible Wi-Fi AC for Production testing. Preview needs no AC or network access.

`start.sh` uses the host architecture and targets macOS 14. It has no remote dependency downloads. Compiler module caches live in `build/ModuleCache` inside the workspace.

## Build lifecycle

`./start.sh` compiles both Swift files with the CommonCrypto bridging header and links SwiftUI/AppKit. It creates the `.app` bundle, validates its plist, signs it with a local ad-hoc signature, verifies that signature, and copies the bundle to `.local/GreeBar.app`. With launch enabled, it closes a running instance of the deployed workspace app and launches the new bundle with the selected mode argument.

Use `--no-launch` in automated build checks. A failed build exits before deployment. The app is not notarized or packaged for public distribution. No administrator rights are needed for this workspace-local deployment.

## Daily workflow

1. Edit files in `Sources/`.
2. Run `./test.sh` after protocol changes.
3. Run `./start.sh --preview` to review controls.
4. With compatible hardware, run `./start.sh --production` and discover the AC.

## Manual verification

- Preview: menu bar shows Demo; every control updates simulated state; power does not affect a real AC.
- Mode switch: Production clears sample values and disables controls until connection succeeds. Switching back restores the preview defaults.
- Production: discovery lists the intended unit; status matches its remote; a temperature command is confirmed by a status read and the physical unit.
- Failure: disconnect the AC and refresh; an error appears and controls disable. Reconnect and refresh to recover.
- Quit: the menu bar item disappears and does not return at login.

## Troubleshooting

**No menu bar icon:** Look for the AC symbol and Demo label near the right of the menu bar. Quit other copies, then rerun `./start.sh`. The app intentionally has no Dock window.

**Compiler missing:** Install Command Line Tools with `xcode-select --install`. If Xcode was moved, check `xcode-select -p`.

**Cannot discover:** Verify the AC really has a Wi-Fi module and has joined the network. The Wi-Fi button alone does not establish this. Avoid guest networks/client isolation. Try the exact AC IPv4 address from your router, or the subnet broadcast address.

**Permission blocked:** Check System Settings → Privacy & Security → Local Network when available on your macOS version. Permit GreeBar and retry. Preview requires no network permission.

**Discovery works but binding/status fails:** The unit may use AES-GCM/v2 or lack compatible local control. This app currently implements AES v1 only. It cannot control a non-Wi-Fi AC directly.

**A setting has no effect:** Some units report fields for unsupported features or support only some fan/swing positions. Confirm the setting with a status refresh and the physical unit.

## Uninstall

Quit through the panel. Delete `.local/GreeBar.app` in Finder. Delete `build/` to remove compiled artifacts and caches. Sources and documentation remain available for rebuilding. Nothing is registered in Login Items or installed as a service.
