# AI-Phone

AI-Phone is a native macOS SwiftUI application for Android device management and automation. It combines ADB device control, on-demand screen mirroring powered by scrcpy, virtual camera streaming, app and file management, per-device profiles, and an optional AI agent runner into a single desktop interface.

Author: Mochamad Nizwar Syafuan

> **Important:** The built-in AI automation feature is designed exclusively for [Open-AutoGLM](https://github.com/zai-org/Open-AutoGLM) models. If you want to use a different AI agent or model provider, consider using [aiphone-agent](https://github.com/nizwar/aiphone-agent) instead — an MCP-based alternative that works with any compatible agent framework.

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

The AI automation agent requires an [AutoGLM-Phone](https://huggingface.co/zai-org/AutoGLM-Phone-9B-Multilingual) model service. You can either use a hosted third-party provider or deploy the model yourself.

#### Option A: Use a third-party hosted service (recommended)

Several providers already host the AutoGLM model so you can get started without any GPU or local deployment:

| Provider | Base URL | Model name |
|---|---|---|
| [z.ai](https://docs.z.ai/api-reference/introduction) | `https://api.z.ai/api/paas/v4` | `autoglm-phone-multilingual` |
| [Novita AI](https://novita.ai/models/model-detail/zai-org-autoglm-phone-9b-multilingual) | `https://api.novita.ai/openai` | `zai-org/autoglm-phone-9b-multilingual` |
| [Parasail](https://www.saas.parasail.io/serverless?name=auto-glm-9b-multilingual) | `https://api.parasail.io/v1` | `parasail-auto-glm-9b-multilingual` |

Sign up on the provider's platform to obtain an API key, then enter the **Base URL**, **Model name**, and **API key** in the AI-Phone Settings window.

#### Option B: Deploy the model yourself

If you prefer to run the model on your own hardware (requires an NVIDIA GPU with 24 GB+ VRAM):

1. Install [vLLM](https://docs.vllm.ai/):

   ```bash
   pip install vllm
   ```

2. Start the model service (the model weights will be downloaded automatically, ~20 GB):

   ```bash
   python3 -m vllm.entrypoints.openai.api_server \
     --served-model-name autoglm-phone-9b-multilingual \
     --allowed-local-media-path / \
     --mm-encoder-tp-mode data \
     --mm_processor_cache_type shm \
     --mm_processor_kwargs '{"max_pixels":5000000}' \
     --max-model-len 25480 \
     --chat-template-content-format string \
     --limit-mm-per-prompt '{"image":10}' \
     --model zai-org/AutoGLM-Phone-9B-Multilingual \
     --port 8000
   ```

3. Once the service is running, use `http://localhost:8000/v1` as the **Server URL** in AI-Phone Settings.

For full deployment details, model download links, and troubleshooting, refer to the [Open-AutoGLM Model Service guide](https://github.com/zai-org/Open-AutoGLM/blob/main/README_en.md#3-start-model-service).

#### Entering settings in AI-Phone

Open the Settings window and provide:

- **Server URL** — the base URL from your chosen provider or your self-hosted endpoint
- **API Key** — your authentication key
- **Model** — the model name matching the provider table above
- **Language Enhancer** (optional) — a separate endpoint, key, and model for refining task text and final responses

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

## Virtual Camera [EXPERIMENTAL]

AI-Phone includes a Camera Extension system extension that exposes a connected device's mirrored screen as a virtual macOS camera. This allows other applications (video calls, OBS, etc.) to use the device screen as a camera input.

To install:

1. Open Device Details for a connected device.
2. Navigate to the Camera tab.
3. Click "Install Extension" and approve the system extension prompt.

Once installed, the virtual camera appears in any application's camera picker.
 
## Credits and Attribution

AI-Phone is built on top of several excellent open-source projects:

- **[Android Debug Bridge (ADB)](https://developer.android.com/tools/adb)** — the foundational command-line tool for communicating with Android devices. AI-Phone uses ADB for device discovery, screenshot capture, app management, file transfer, and shell commands.
- **[scrcpy](https://github.com/Genymobile/scrcpy)** — provides the embedded scrcpy-server binary that runs on the Android device to capture and stream the screen as H.264 video. AI-Phone decodes this stream natively for real-time screen mirroring and virtual camera output.
- **[Open-AutoGLM](https://github.com/zai-org/Open-AutoGLM)** — the upstream research project by Z.ai that inspired the AI automation agent workflow. AI-Phone's agent runner implements a similar structured action loop for phone automation tasks.

## Safety and Usage Notes

This software is intended for research, development, workflow automation, and personal productivity scenarios. You are responsible for ensuring that any device control, content generation, and automation behavior complies with the terms of the services you use and with applicable laws and policies.


Made with Love and Curiosity by Mochamad Nizwar Syafuan ❤️