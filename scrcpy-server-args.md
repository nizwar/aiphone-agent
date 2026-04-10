## SCRCPY-SERVER Arguments
Fetched https://raw.githubusercontent.com/Genymobile/scrcpy/v3.3.4/server/src/main/java/com/genymobile/scrcpy/Options.java

Fetched https://raw.githubusercontent.com/nickolay168/scrcpy/master/server/src/main/java/com/genymobile/scrcpy/Options.java

Here's the complete list of **scrcpy-server v3.3.4** parameters. The server is invoked via `app_process` and all options use `key=value` format:

```
adb shell CLASSPATH=/data/local/tmp/scrcpy-server.jar \
    app_process / com.genymobile.scrcpy.Server 3.3.4 [key=value ...]
```

The first arg **must** be the version string (`3.3.4`). Everything after is `key=value` pairs:

| Key | Type | Default | Description |
|---|---|---|---|
| `scid` | hex int | `-1` | 31-bit session ID (hex), -1 = none |
| `log_level` | string | `DEBUG` | `VERBOSE`, `DEBUG`, `INFO`, `WARN`, `ERROR` |
| **Video** |
| `video` | bool | `true` | Enable video stream |
| `video_codec` | string | `h264` | `h264`, `h265`, `av1` |
| `video_source` | string | `display` | `display`, `camera` |
| `video_bit_rate` | int | `8000000` | Video bitrate in bps |
| `video_codec_options` | string | | Codec-specific options |
| `video_encoder` | string | | Force specific encoder name |
| `max_size` | int | `0` | Max dimension (rounded to multiple of 8), 0=unlimited |
| `max_fps` | float | `0` | Max framerate, 0=unlimited |
| `angle` | float | `0` | Rotation angle |
| `crop` | string | | Crop region `width:height:x:y` |
| **Audio** |
| `audio` | bool | `true` | Enable audio stream |
| `audio_codec` | string | `opus` | `opus`, `aac`, `flac`, `raw` |
| `audio_source` | string | `output` | `output`, `mic` |
| `audio_dup` | bool | `false` | Duplicate audio |
| `audio_bit_rate` | int | `128000` | Audio bitrate in bps |
| `audio_codec_options` | string | | Codec-specific options |
| `audio_encoder` | string | | Force specific encoder name |
| **Camera** |
| `camera_id` | string | | Specific camera ID |
| `camera_size` | string | | Camera resolution `<w>x<h>` |
| `camera_facing` | string | | `front`, `back`, `external` |
| `camera_ar` | string | | Aspect ratio: `sensor`, `w:h`, or float |
| `camera_fps` | int | `0` | Camera framerate |
| `camera_high_speed` | bool | `false` | High-speed camera mode |
| **Display** |
| `display_id` | int | `0` | Target display ID |
| `new_display` | string | | Create virtual display: `<w>x<h>/<dpi>` or `/<dpi>` or empty |
| `vd_destroy_content` | bool | `true` | Destroy VD content on close |
| `vd_system_decorations` | bool | `true` | Show system decorations on VD |
| `capture_orientation` | string | | Lock orientation: `@` (lock initial), `@0`, `@90`, etc. |
| `display_ime_policy` | string | | `local`, `fallback`, `hide` |
| **Control & Behavior** |
| `control` | bool | `true` | Enable input control |
| `show_touches` | bool | `false` | Show touch indicators |
| `stay_awake` | bool | `false` | Keep device awake |
| `screen_off_timeout` | int | `-1` | Screen-off timeout in ms (-1=default) |
| `power_off_on_close` | bool | `false` | Turn screen off when disconnecting |
| `power_on` | bool | `true` | Turn screen on at start |
| `clipboard_autosync` | bool | `true` | Auto-sync clipboard |
| `downsize_on_error` | bool | `true` | Retry with smaller size on error |
| `cleanup` | bool | `true` | Restore device state on exit |
| **Network** |
| `tunnel_forward` | bool | `false` | Use forward (client connects) vs reverse (server connects) |
| **Stream Framing** *(for direct server use)* |
| `send_device_meta` | bool | `true` | Send device name + screen size |
| `send_frame_meta` | bool | `true` | Send PTS timestamps |
| `send_dummy_byte` | bool | `true` | Write a byte on start |
| `send_codec_meta` | bool | `true` | Write codec info before stream |
| `raw_stream` | bool | `false` | Shortcut: disables all 4 meta options above |
| **Listing (query-only)** |
| `list_encoders` | bool | `false` | List available encoders |
| `list_displays` | bool | `false` | List available displays |
| `list_cameras` | bool | `false` | List available cameras |
| `list_camera_sizes` | bool | `false` | List camera resolutions |
| `list_apps` | bool | `false` | List installed apps |

Your camera.sh is already using the key ones for a raw video stream. A typical direct-use invocation:

```bash
adb shell CLASSPATH=/data/local/tmp/scrcpy-server.jar \
    app_process / com.genymobile.scrcpy.Server 3.3.4 \
    tunnel_forward=true \
    audio=false \
    control=false \
    cleanup=false \
    raw_stream=true \
    send_frame_meta=false \
    max_size=1920 \
    max_fps=30 \
    video_bit_rate=4000000
```