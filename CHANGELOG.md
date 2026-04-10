# Changelog

## v1.0.0 — Initial Release

**AI-Phone** — A native macOS SwiftUI application for Android device management and AI-powered automation

### Features

#### Device Management
- Discover and monitor Android devices via ADB (USB, Wi-Fi, Remote)
- Live device status dashboard: battery, Wi-Fi, mobile data, current app
- Per-device profile system with persona, preferred apps, and notes
- File explorer for browsing and managing device file system
- App manager for viewing and controlling installed applications

#### Screen Mirroring & Camera
- On-demand screen mirroring powered by embedded scrcpy server
- Low-latency H.264 stream decoder with frame-meta NAL parsing
- Virtual camera support — stream Android device as a macOS camera source
- Camera stream viewer with configurable resolution and source selection

#### AI Agent Runner
- Built-in AI automation agent with vision-language model support
- **Pluggable model provider architecture** — supports AutoGLM and OpenAI-compatible endpoints
- Structured action format: tap, swipe, type, long press, double tap, launch, back, home, wait, and more
- Automatic app resolution: fuzzy-match app names to installed packages
- Language Enhancer integration for natural text generation and task refinement
- Conversation context threading — language model receives full step history when generating text input
- Action retry loop with automatic reprompting on parse failures
- Input sanitization: strips leaked action wrappers from typed text
- Real-time streaming activity log during agent execution

#### Multi-Device Support
- Per-device selection menu in the toolbar for targeted agent runs
- Auto-select newly connected devices, auto-remove disconnected ones
- Run AI agent across multiple selected devices simultaneously

#### Settings & Configuration
- AI Provider picker with dynamic model lists (AutoGLM, OpenAI)
- Configurable server URL, API key, and model for both primary and language enhancer endpoints
- Per-device scrcpy overrides: window title, max FPS, max size, video bitrate, always-on-top, fullscreen
- ADB and scrcpy executable path configuration
- Endpoint validation with status indicators

#### Build & Distribution
- Automated DMG builder with code signing and notarization support
- Native macOS app bundle with proper entitlements

### Technical Highlights
- JPEG screenshot compression pipeline (replaces PNG/WebP) for faster AI model inference
- Shell injection guard on ADB app launch commands
- Extracted H264StreamDecoder as standalone module
- NSAppTransportSecurity configured for local development endpoints
