# GreeBar — macOS AC menu bar controller

Native SwiftUI menu bar app with a dark control panel inspired by the reference video. It has separate **Preview** and **Production** modes. Requires **macOS 14 or newer** and Xcode Command Line Tools to build. No package manager, cloud account, or background server is required by the app.

## Build, deploy, and start locally

```bash
./start.sh
```

This compiles the source, creates and ad-hoc signs `build/GreeBar.app`, verifies it, copies it into `.local/GreeBar.app` inside this workspace, and opens it in **Preview** mode. Click the air conditioner icon marked **Demo** in the macOS menu bar. There is no Dock icon.

```bash
./start.sh --preview            # Build, deploy, launch simulated controls
./start.sh --production         # Build, deploy, launch real connection mode
./start.sh --no-launch          # Build and deploy without opening the app
./start.sh --help
```

The script resolves paths relative to itself, so it works from other directories and with spaces in the workspace path. Launching again closes the previously deployed workspace copy first. No files are installed into `/Applications`; no login item, service, or network configuration is added.

If the compiler is missing, run `xcode-select --install`, complete Apple's installation, then run the script again.

## Preview mode

Preview starts with a simulated powered-on AC at 24°C and a room reading of 25°C. Power, temperature, mode, fan, sleep, eco, and vertical airflow controls update only this in-memory state. **Preview never discovers, binds, polls, or commands an AC.** The menu bar says Demo, and the panel identifies the simulated device.

## Production mode

Switch to Production in the panel, or start with `./start.sh --production`. Production begins disconnected and does not send anything until you click **Find AC**.

1. Use Gree+ or EWPE Smart on your phone to connect a Wi-Fi-equipped AC to your home network, following the pairing instructions for your model.
2. Connect your Mac to the same network. Allow Local Network access if macOS asks.
3. Click **Find AC**. The default address `255.255.255.255` broadcasts discovery. If discovery fails, enter the AC's IPv4 address from your router and try again.
4. If multiple devices are discovered, choose one in the Device picker. Controls become available after binding and a successful status read.

Production supports Gree's **AES-128-ECB / PKCS7 local protocol (v1)** on UDP port 7000. **AES-GCM/v2, cloud-only modules, and infrared controllers are not implemented.** Your current non-Wi-Fi AC cannot be controlled directly by this app; Preview remains usable. A supported Wi-Fi unit or a separately implemented control bridge is needed for real operation.

The panel polls the selected device every 10 seconds. A command requires an acknowledgement followed by a fresh status read; it does not optimistically display a successful change. Connection failures disable controls. The last confirmed values may remain visible after a connection failure. Use Refresh or Find AC to retry. Mode and device changes are disabled while a network operation is running.

The temperature setpoint is 16–30°C. The room reading uses `TemSen - 40` when a plausible reading is returned. Sleep, eco, airflow, and fan-speed support vary by model; a reported protocol field does not guarantee every listed setting is supported.

## Development and documentation

- [Architecture and protocol](docs/architecture.md)
- [Local deployment and troubleshooting](docs/local-development.md)

Run the protocol checks:

```bash
./test.sh
```

These verify encryption against an independently checked AES vector, packet encoding/decoding, and invalid-key/address handling. They do not establish physical AC compatibility.

Quit the app using **Quit** at the bottom of its panel. It does not automatically start at login. The build output and deployment directory are ignored by Git. To remove the local deployment, quit the app and delete `.local/GreeBar.app` in Finder.
