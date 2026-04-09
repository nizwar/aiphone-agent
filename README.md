# AI-Phone

AI-Phone is a native macOS SwiftUI application for Android device management and automation. It combines ADB device control, on-demand screen mirroring powered by scrcpy, virtual camera streaming, app and file management, per-device profiles, and an optional AI agent runner into a single desktop interface.

Author: Mochamad Nizwar Syafuan

## Overview

AI-Phone gives you a native macOS interface for managing Android devices without switching between terminal windows. Core capabilities include:

- discovering and monitoring Android devices through ADB
- previewing live screenshots and device status (battery, Wi-Fi, mobile data, current app)
- on-demand screen mirroring via an embedded scrcpy server with H.264 decoding
- virtual camera support that streams a device screen as a macOS camera source
- browsing and managing installed applications on connected devices
- exploring the device file system
- storing per-device persona, preferred app, and note metadata
- configuring and running an AI automation agent with OpenAI-compatible endpoints
- reviewing streaming activity logs while the agent is working

## Key Features

### Native macOS interface

- Floating main prompt window built with SwiftUI and AppKit integration
- Devices window with a card grid showing live screenshots and device status
- In-window device detail dialog with dark overlay backdrop, dismissable by click-outside or close button
- Dock menu for quick access to all application windows
- Prompt history navigation with keyboard support

### Model configuration

- OpenAI-compatible endpoint, API key, and model selection
- Optional Language Enhancer endpoint for refining task text, typed inputs, and final responses
- Built-in validation and remote model fetching for both services

### Device management

- ADB device discovery with live preview snapshots
- Current app, battery, Wi-Fi, and mobile data status collection
- Installed app lookup and launch resolution through an internal catalog
- App manager for browsing and managing installed applications
- File explorer for browsing the device file system

### Screen mirroring and virtual camera

- On-demand screen mirror in the device detail view via an embedded scrcpy server
- H.264 Annex B stream decoding with AVSampleBufferDisplayLayer rendering
- Automatic fallback to screenshots when the stream has no active video
- Virtual camera system extension that exposes the mirrored device screen as a macOS camera source
- Camera options for resolution, bitrate, and codec configuration

### Per-device preferences

- Device persona profiles for tone and behavior adaptation
- Preferred apps and notes that are injected into the agent context
- Persistent profile storage in local user defaults

### Automation runtime

- Native Swift agent runner with structured action parsing
- Support for tap, double tap, long press, swipe, type, back, home, wait, list-app, launch, finish, and manual takeover flows
- Parallel multi-device execution with tabbed activity logs
- Smart log auto-scroll that stays pinned to the bottom unless the user scrolls away

### Optional tooling

- scrcpy launch integration with configurable window, video, audio, and control settings

## Project Structure

```text
.
├── Package.swift
├── README.md
├── project.yml
├── build.sh
├── scrcpy_playground.sh
└── Sources/
    ├── App/
    │   ├── AppMain.swift
    │   ├── AI-Phone.entitlements
    │   ├── Info.plist
    │   ├── ADB/
    │   │   ├── ADBAppCatalog.swift
    │   │   ├── ADBAppManagerView.swift
    │   │   ├── ADBDeviceDetailWindowView.swift
    │   │   ├── ADBDevicesWindowView.swift
    │   │   ├── ADBFileExplorerView.swift
    │   │   ├── ADBModels.swift
    │   │   └── ADBProvider.swift
    │   ├── Agent/
    │   │   ├── AIAgentRunner.swift
    │   │   └── AIEndpointValidator.swift
    │   ├── Audio/
    │   │   └── AudioTranscriptionStore.swift
    │   ├── Camera/
    │   │   ├── CameraOptionsStore.swift
    │   │   ├── CameraStreamStore.swift
    │   │   ├── ScreenMirrorStore.swift
    │   │   └── VirtualCameraProvider.swift
    │   ├── Scrcpy/
    │   │   ├── ScrcpyLaunchStore.swift
    │   │   └── ScrcpyServerProvider.swift
    │   ├── Settings/
    │   │   ├── AISettingsStore.swift
    │   │   └── AISettingsWindowView.swift
    │   ├── Assets.xcassets/
    │   └── Resources/
    │       ├── AppIcon.png
    │       ├── BrandMark.png
    │       └── scrcpy-server
    ├── CameraExtension/
    │   ├── CameraExtensionMain.swift
    │   ├── CameraExtension.entitlements
    │   └── Info.plist
    └── Shared/
        └── SharedFrameBuffer.swift
```

## Requirements

- macOS 13 or later
- Swift 5.9 or later
- Xcode 15 or later for packaging and distribution workflows
- `adb` installed and available in `PATH`, or configured manually in the app
- Optional: an OpenAI-compatible model endpoint for the AI automation agent
- Optional: `scrcpy` for external mirroring and direct device viewing

## Quick Start

### 1. Install desktop dependencies

```bash
brew install android-platform-tools
brew install scrcpy
```

If you prefer, you can also set custom paths for `adb` and `scrcpy` inside the application settings.

### 2. Build and run the app

Open the Xcode project and build:

```bash
open AI-Phone.xcodeproj
```

Or build from the command line:

```bash
xcodebuild -project AI-Phone.xcodeproj -scheme AI-Phone -configuration Release build
```

### 3. Prepare your Android device

- Enable Developer Options
- Enable USB Debugging
- Authorize the Mac when the device trust prompt appears
- Verify the connection:

```bash
adb devices
```

### 4. Configure model endpoints (optional)

If you want to use the AI automation agent, open the Settings window and provide:

- Server URL for an OpenAI-compatible endpoint
- API key
- Model name
- Optional Language Enhancer server, key, and model for refining task text and responses

Use the built-in `Validate` and `Fetch` actions to confirm the configuration.

## Typical Workflow

1. Launch AI-Phone.
2. Open the Devices window and refresh connected devices.
3. Review the screenshot cards and open Device Details for a specific phone.
4. Optionally start screen mirroring from the detail sidebar to see a live stream.
5. Set the device persona, preferred apps, notes, and any scrcpy overrides.
6. Return to the main prompt window and submit a task.
7. Monitor progress in the Agent Activity window.
8. Stop, inspect, and rerun tasks as needed.

## Virtual Camera

AI-Phone includes a Camera Extension system extension that exposes a connected device's mirrored screen as a virtual macOS camera. This allows other applications (video calls, OBS, etc.) to use the device screen as a camera input.

To install:

1. Open Device Details for a connected device.
2. Navigate to the Camera tab.
3. Click "Install Extension" and approve the system extension prompt.

Once installed, the virtual camera appears in any application's camera picker.

## Publish-Ready Setup Notes

The repository includes branding assets in `Sources/App/Resources/` and uses the bundled `BrandMark.png` at runtime for application identity.

For a production release, the recommended process is:

1. Open the project in Xcode.
2. Set your team, bundle identifier, version, and signing configuration.
3. Confirm the app name, icon, and About screen metadata.
4. Create a Release archive.
5. Notarize the build for macOS distribution.
6. Export a signed `.app`, `.zip`, or `.dmg` for end users.

## Credits and Attribution

AI-Phone is built on top of several excellent open-source projects:

- **[Android Debug Bridge (ADB)](https://developer.android.com/tools/adb)** — the foundational command-line tool for communicating with Android devices. AI-Phone uses ADB for device discovery, screenshot capture, app management, file transfer, and shell commands.
- **[scrcpy](https://github.com/Genymobile/scrcpy)** — provides the embedded scrcpy-server binary that runs on the Android device to capture and stream the screen as H.264 video. AI-Phone decodes this stream natively for real-time screen mirroring and virtual camera output.
- **[Open-AutoGLM](https://github.com/zai-org/Open-AutoGLM)** — the upstream research project by Z.ai that inspired the AI automation agent workflow. AI-Phone's agent runner implements a similar structured action loop for phone automation tasks.

## Safety and Usage Notes

This software is intended for research, development, workflow automation, and personal productivity scenarios. You are responsible for ensuring that any device control, content generation, and automation behavior complies with the terms of the services you use and with applicable laws and policies.

