# stopat

![Downloads](https://github.com/sunc11xy/stopat/total)

**stopat** is a lightweight, privacy-first macOS menu-bar utility that helps protect your screen when another person appears to be looking toward it. It uses the built-in webcam and Apple's on-device Vision framework—no accounts, network requests, recordings, or telemetry.

> Face orientation is an estimate, not eye tracking. Treat stopat as a privacy aid, not proof that someone is reading the screen.

## Features

- Runs entirely on-device with AVFoundation and Vision.
- Checks the camera at a capped 5 FPS to keep CPU/GPU use and fan noise low.
- Uses face count plus conservative head orientation to distinguish a likely user from an additional screen-facing person.
- Shows a green **Secure** or yellow **Warning** menu-bar status; alerts flash red.
- Offers three sensitivity levels:
  - **Light:** alert after 10 seconds; blur after another 5 seconds.
  - **Medium:** alert after 5 seconds; blur after another 3 seconds.
  - **High:** alert and blur immediately.
- Uses a full-screen privacy blur that follows macOS Spaces and full-screen applications.
- Provides a bottom-right slider to lock the blur in place or release it.
- Lets you show, hide, and customize the centered blur message.
- Includes menu localization for English, Chinese, Japanese, and Korean.
- Includes an optional local face-detection preview after camera access is granted.

## Download and install

### Requirements

- macOS 13.0 or later
- A Mac with an available camera

### Installation

1. Download the latest **stopat.dmg** from the project's [GitHub Releases](../../releases) page.
2. Open the downloaded disk image.
3. Drag **stopat.app** to your **Applications** folder.
4. Open **stopat** from Applications.
5. Approve the macOS camera permission prompt.

stopat starts monitoring when it launches and appears as an eye icon in the menu bar.

### First launch on macOS

The GitHub release is intentionally unsigned, so macOS will show an “unidentified developer” warning the first time you open it. This is expected:

1. Click **Done** on the warning.
2. Open **System Settings → Privacy & Security**.
3. Scroll to the security notice for stopat and click **Open Anyway**.
4. Confirm, then grant camera access when prompted.

You only need to approve stopat once. If camera permission was previously denied, enable it in **System Settings → Privacy & Security → Camera**, then reopen the app.

## How detection works

stopat expects one screen-facing face: the primary user. A second face begins a warning only when it is sufficiently oriented toward the camera/screen. A face turned away does not count toward the alert policy. If no additional screen-facing face remains, the state returns to Secure and an unlocked blur is removed.

The orientation check uses Vision face landmarks and a conservative yaw threshold. It reduces obvious false positives, but cannot determine exactly where a person's eyes are looking.

## Sensitivity and blur behavior

| Sensitivity | Alert delay | Blur delay after alert | Blur transition |
| --- | ---: | ---: | ---: |
| Light | 10 seconds | 5 seconds | 1.0 seconds |
| Medium | 5 seconds | 3 seconds | 0.55 seconds |
| High | Immediate | Immediate | 0.25 seconds |

Selecting **High** adds a pulsing red “Instant” confirmation in the menu. The blur and its lock control stay above normal desktops and full-screen windows, including when moving between Spaces.

## Privacy

- Camera frames are processed locally in memory.
- No frames, face data, identifiers, or video are saved.
- The app performs no network requests and sends no telemetry.
- Face rectangles are used only for live local detection; stopat does not identify people.

## Architecture

- `BackgroundMonitoringService` owns the state machine, camera-session lifecycle, and alert timing.
- `VisionProcessor` throttles frames and runs `VNDetectFaceRectanglesRequest` and landmark analysis off the main thread.
- `MenuBarController` manages the status item, settings, localization, and alert indicator.
- `ScreenBlurController` manages all-Spaces, full-screen-compatible privacy panels and the blur lock control.
- `FaceRecognitionPreviewPanelController` renders the optional live local detection preview.

`BackgroundMonitoringService` publishes UI state on the main actor. AVFoundation capture work runs on dedicated queues, and Vision results are handed back to the main actor only after processing completes. Swift ARC retains sample buffers for the duration of asynchronous processing, so the frame loop does not require manual `CFRetain` or `CFRelease` calls.

## Credits

Built with Codex.

## Maintainers: publish a release

Use [`scripts/create_dmg.sh`](scripts/create_dmg.sh) to build an unsigned `stopat.dmg`, then attach it to a GitHub Release. See [RELEASE_WORKFLOW.md](RELEASE_WORKFLOW.md) for the complete checklist.
