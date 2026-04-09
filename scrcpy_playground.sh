#!/usr/bin/env bash
#This is my playground for testing scrcpy server queries and streaming. 
#It is not intended to be a complete or polished script, but rather a collection of useful functions for development and debugging.
#Script got enhanced by AI, stream_display() and stream_camera() is the hack way to make the SCRCPY-Server not laggy
#^-

set -euo pipefail

SERVER_JAR="/data/local/tmp/scrcpy-server.jar"
SERVER_VERSION="3.3.4"
LOCAL_SERVER="Sources/App/Resources/scrcpy-server"
 
scrcpy_query() {
    local query_args="$*"
    push_server
    adb logcat -c
    adb shell "CLASSPATH=${SERVER_JAR} app_process / com.genymobile.scrcpy.Server ${SERVER_VERSION} ${query_args} log_level=INFO" 2>&1 || true
    sleep 0.5
    adb logcat -d -s scrcpy:I | grep -v "^-"
}

push_server() {
    adb push "$LOCAL_SERVER" "$SERVER_JAR"
}

list_cameras() {
    scrcpy_query "list_cameras=true"
}

list_camera_sizes() {
    local camera_id="${1:-0}"
    scrcpy_query "list_camera_sizes=true camera_id=${camera_id}"
}

list_encoders() {
    scrcpy_query "list_encoders=true"
}

list_displays() {
    scrcpy_query "list_displays=true"
}

list_apps() {
    scrcpy_query "list_apps=true"
}

stream_display() {
    local port="${1:-1234}"
    local max_size="${2:-0}"

    adb forward "tcp:${port}" localabstract:scrcpy

    adb shell "CLASSPATH=${SERVER_JAR} app_process / com.genymobile.scrcpy.Server ${SERVER_VERSION} \
        tunnel_forward=true audio=false control=false cleanup=false \
        raw_stream=true send_frame_meta=false \
        max_size=${max_size}" &

    sleep 0.5
    ffplay -i "tcp://localhost:${port}" \
        -f h264 \
        -flags low_delay -strict experimental \
        -probesize 32 -analyzeduration 0 \
        -framedrop -sync ext -vf "setpts=0"
}

stream_camera() {
    local camera_id="${1:-0}"
    local port="${2:-1234}"
    local max_size="${3:-720}"

    adb forward "tcp:${port}" localabstract:scrcpy

    adb shell "CLASSPATH=${SERVER_JAR} app_process / com.genymobile.scrcpy.Server ${SERVER_VERSION} \
        tunnel_forward=true audio=false control=false cleanup=false \
        raw_stream=true send_frame_meta=false \
        video_source=camera camera_id=${camera_id} \
        max_size=${max_size}" &

    sleep 0.5
    ffplay -i "tcp://localhost:${port}" \
        -f h264 \
        -flags low_delay -strict experimental \
        -probesize 32 -analyzeduration 0 \
        -framedrop -sync ext -vf "setpts=0"
}
 
if [[ $# -gt 0 ]]; then
    "$@"
else
    echo "Usage: $0 <command> [args...]"
    echo "Commands:"
    echo "  push_server                  Push scrcpy-server to device"
    echo "  list_cameras                 List available cameras"
    echo "  list_camera_sizes [id]       List camera sizes (default: camera 0)"
    echo "  list_encoders                List available encoders"
    echo "  list_displays                List available displays"
    echo "  list_apps                    List installed apps"
    echo "  stream_display [port] [max]  Stream display via ffplay"
    echo "  stream_camera [id] [port] [max]  Stream camera via ffplay"
fi