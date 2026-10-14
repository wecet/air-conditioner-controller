# Architecture

## Source layout

| File | Responsibility |
| --- | --- |
| `Sources/App.swift` | SwiftUI menu bar app, panel, mode selection, state and command orchestration |
| `Sources/GreeClient.swift` | UDP discovery, binding, status, commands, response validation, AES v1 encoding |
| `Sources/AnimationProfile.swift` | Independent Mode/Fan/Swing/Sleep attributes composed by the Canvas illustration |
| `Sources/OffTimer.swift` | Deadline calculation and countdown formatting |
| `Sources/Crypto.h` | Bridge to Apple's CommonCrypto |
| `Info.plist` | App identity, minimum OS, menu bar-only lifecycle, network usage description |
| `start.sh` | Compile, sign, verify, copy into workspace-local deployment, launch |
| `test.sh` | Compile and execute protocol checks |

## Mode boundaries

The controller launches in Preview unless `--production` is passed. Mode changes clear the selected device, discovered devices, connection state, and device session keys. Preview resets to sample state and mutates that state synchronously. Every discovery and refresh entry point checks Production mode. The command entry point returns after updating simulated state in Preview.

Production network operations execute on one serial queue. UI state updates return to the main queue. A busy operation disables mode switching and further network/control operations. The timer requests a refresh every 10 seconds and skips ticks in Preview, while busy, or before device selection. Operations have bounded receive deadlines (2 seconds for discovery, 3 seconds per bind/status/command exchange).

## Local protocol

1. Send `{ "t": "scan" }` to UDP port 7000 at the chosen IPv4 address.
2. Decode discovered device responses with the protocol's shared AES key.
3. Bind to a selected device to obtain its 16-byte session key.
4. Request named status columns with that key.
5. Send commands as parallel `opt` and `p` arrays. Wait for `res`, then request status again.

Encrypted payloads are JSON → AES-128-ECB with PKCS7 padding → Base64 inside a JSON `pack` envelope. Responses are filtered by source port and payload type. Non-discovery exchanges also require the selected source IP and reject a mismatched MAC when reported. Status column/value lengths and duplicate columns are validated before constructing state.

The implementation follows the [documented Gree v1 protocol](https://github.com/tomikaa87/gree-remote#protocol-details). It is independently implemented and is not an official Gree SDK. AES v1 is a device compatibility requirement, not a modern authenticated transport.

## State and persistence

Only the last discovery address is stored in `UserDefaults` under `mt.owen.GreeBar`. Wi-Fi credentials are not collected. Session keys exist in process memory and are cleared on mode changes. Device selection and mode are not saved; normal launches default to Preview. There are no cloud calls, telemetry, external services, or startup agents.

## Limits

AES-GCM/v2 and infrared bridge integrations need separate protocol work. Device capabilities are not automatically negotiated. Real hardware testing is required before treating production support as verified for a particular model. Build and protocol checks are not end-to-end device tests.

## App-managed off timer

The controller uses a one-second common-run-loop timer to update a wall-clock deadline. Production expiration sends one power-off command and confirms status; it can attempt this even if a preceding poll marked the device disconnected. It waits for any active network operation to finish. Failures remain visible and are not retried. Preview expiration only updates simulated power. The timer is bound to the current mode/device by cancelling on mode change, discovery, or selection; it is also cancelled on manual off or confirmed off status. No device-side schedule is created or read. Deadlines and countdown formatting are checked in `Tests/ProtocolTests.swift`.

## Combined setting visuals

`AnimationProfile` translates protocol settings into independent mode symbols, fan durations/density, fixed or oscillating blade angles, and sleep brightness. The Canvas applies four drawing passes (mode particles, fan flow, swing blade, sleep badge) to a single timeline. Swing also steers mode particles and fan flow; sleep lowers their opacity without hiding the fan level or changing device settings. Auto fan uses a bounded phase variation to keep motion smooth over long uptime. Reduce Motion pauses updates and draws a static frame. The illustration has no hit targets and adds no network calls.
