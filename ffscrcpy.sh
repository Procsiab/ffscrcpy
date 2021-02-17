## FFSCRCPY
#
# Use your android smartphone as a webcam
#
## Requirements:
# - scrcpy (Darkrol76's fork, on serve branch)
# - v4l2loopback kernel module
# - ffmpeg toolset
#
## Assumptions:
# - the user who runs the script has access without root to its Android device ADB session
# - the smartphone may run the OpenCamera app
# - the sockets on localhost from port 10080 to 10089 are bindable


# Print message based on verbosity level (default 1)
#
# Usage: _console_log LEVEL STRING
_VERBOSITY=1
function _console_log() {
    if [[ $_VERBOSITY -lt $1 ]]
    then
        return 0
    else
        case $1 in
            0)
                echo -e "[ERR] $2"
                ;;
            1)
                echo -e "[WARN] $2"
                ;;
            2)
                echo -e "[INFO] $2"
                ;;
            *)
                echo -e "[DBG] $2"
        esac
    fi
}


# Turn phone screen off, after scrcpy was called with --turn-screen-off
#
# Usage: _turn_screen_off
function _turn_screen_off() {
    # When terminating the program, send 3 POWER button presses to the phone to
    # unlock and lock again the screen: this prevents the battery from draining
    # because of the opened camera app in the background
    adb -s $DEVICE_SERIAL shell input keyevent POWER
    sleep 0.2
    adb -s $DEVICE_SERIAL shell input keyevent POWER
    sleep 0.2
    adb -s $DEVICE_SERIAL shell input keyevent POWER
    sleep 0.2
    # Moreover, disconnect the ADB server from all devices
    _disconnect_all
}

# Disconnect all ADB devices from the ADB server when the streaming terminates
#
# Usage: _disconnect_all
function _disconnect_all() {
    adb disconnect > /dev/null 2>&1
}

# Kill all background instances of scrcpy (they might be left over from inconsistent 
# teardowns of the wireless streaming mode)
#
# Usage: _killall_scrcpy
function _killall_scrcpy() {
    if [[ $(ps -u | grep "scrcpy --serial" | wc -l) -gt 1 ]]
    then
        _console_log 1 "killed all background instances of scrcpy"
        killall scrcpy
    fi
}


# Obtain the battery percentage from the phone
#
# Usage: _get_phone_battery
function _get_phone_battery() {
    return $(adb -s $DEVICE_SERIAL shell dumpsys battery | grep 'level' | grep -oE '[0-9]+')
}


# Parse command line arguments
_IS_SCREEN_ON=0
_IS_SKIP_CHECKS=0
_IS_LETTERBOXED=0
_IS_WIRELESS_ADB=0
_IS_CROPPED=1
_IS_FLIPPED=0
_IS_AUTO_LAUNCH=1
CUSTOM_CROP=""
MAX_DIMENSION=""
MAX_FPS=30
BITRATE=""
DEVICE_NUMBER=0
DEVICE_SERIAL=0000000
DEVICE_STREAM=""
LB_CUSTOM_SIZE=""
while getopts ":hoslwvfCAcmbnp" OPT
do
    case $OPT in
        h)
            echo "[HELP] Usage: ffscrcpy [-s] [-m] [-l <DIMENSIONS>] [-C] [-c X:Y:OFS_X:OFS_Y] [-A] [-m PIXELS] [-b MBPS] [-p FPS] [-n SERIAL:NUMBER] [-w] [-v LEVEL]"
            echo "[HELP]    -o: Keep phone screen on"
            echo "[HELP]    -s: Skip startup checks"
            echo "[HELP]    -l: Letterbox with phone screen dimensions
[HELP]        or specific ones, in the form of WxH in pixels"
            echo "[HELP]    -f: Flip horizontally the video source"
            echo "[HELP]    -C: Do not crop the canvas to hide the OpenCamera UI"
            echo "[HELP]    -A: Do not try to automatically launch the OpenCamera app"
            echo "[HELP]    -c: Crop the canvas using custom X:Y:OFS_X:OFS_Y dimensions"
            echo "[HELP]    -m: Maximum dimension for the viewport (will be scaled accordingly)"
            echo "[HELP]    -b: Bitrate in Megabits/s; an integer followed by a capital 'M'
[HELP]        (defaults to 8M)"
            echo "[HELP]    -p: Maximum FPS for video; provide an integer number"
            echo "[HELP]    -n: Choose the number to assign to the /dev/video device
[HELP]        (defaults to 2) and the serial of the Android device
[HELP]        (defaults to the first recognized device from ADB)"
            echo "[HELP]    -w: Enable wireless streaming (the device must be connected first)"
            echo "[HELP]    -v: Choose verbosity level between 0 and 3"
            exit 0
            ;;
        o)
            _IS_SCREEN_ON=1
            ;;
        s)
            _IS_SKIP_CHECKS=1
            ;;
        l)
            _IS_LETTERBOXED=1
            read _ARGUMENT _DISCARD <<<"${@:$OPTIND}"
            if [[ $_ARGUMENT =~ ^[0-9]+x[0-9]+$ ]]
            then
                LB_CUSTOM_SIZE=$_ARGUMENT
                shift
            else
                _console_log 0 "invalid letterboxing dimensions: use two integers separated by an 'x' (lowercase)"
                exit 1
            fi
            ;;
        f)
            _IS_FLIPPED=1
            ;;
        C)
            _IS_CROPPED=0
            ;;
        A)
            _IS_AUTO_LAUNCH=0
            ;;
        c)
            read _ARGUMENT _DISCARD <<<"${@:$OPTIND}"
            if [[ $_ARGUMENT =~ ^[0-9]+:[0-9]+:[0-9]+:[0-9]+$ ]]
            then
                CUSTOM_CROP=$_ARGUMENT
                shift
            else
                _console_log 0 "invalid custom crop size: you must provide four integers separated by ':' (colons)"
                exit 1
            fi
            ;;
        m)
            read _ARGUMENT _DISCARD <<<"${@:$OPTIND}"
            if [[ $_ARGUMENT =~ ^[0-9]+$ ]]
            then
                MAX_DIMENSION=$_ARGUMENT
                shift
            else
                _console_log 0 "invalid maximum dimension: provide an integer"
                exit 1
            fi
            ;;
        b)
            read _ARGUMENT _DISCARD <<<"${@:$OPTIND}"
            if [[ $_ARGUMENT =~ ^[0-9]+M$ ]]
            then
                BITRATE=$_ARGUMENT
                shift
            else
                _console_log 0 "invalid bitrate value: provide an integer followed by capital 'M'"
                exit 1
            fi
            ;;
        p)
            read _ARGUMENT _DISCARD <<<"${@:$OPTIND}"
            if [[ $_ARGUMENT =~ ^[0-9]+$ ]]
            then
                MAX_FPS=$_ARGUMENT
                shift
            else
                _console_log 0 "invalid FPS value: provide an integer"
                exit 1
            fi
            ;;
        n)
            read _ARGUMENT _DISCARD <<<"${@:$OPTIND}"
            if [[ $_ARGUMENT =~ ^[0-9a-zA-Z]+:[0-9]$ ]]
            then
                DEVICE_STREAM=$_ARGUMENT
                shift
            elif [[ $_ARGUMENT =~ ^[0-9]+.[0-9]+.[0-9]+.[0-9]+:[0-9]+:[0-9]$ ]]
            then
                DEVICE_STREAM=$_ARGUMENT
                shift
            else
                _console_log 0 "invalid device name: provide the serial number and the video device number, separated by a ':' (colon)"
                _console_log 0 "if you wish to connect through ADB over TCP, use IP:PORT:VIDEO_NUMBER syntax for this argument"
                exit 1
            fi
            ;;
        w)
            _IS_WIRELESS_ADB=1
            ;;
        v)
            read _ARGUMENT _DISCARD <<<"${@:$OPTIND}"
            if [[ $_ARGUMENT =~ ^[0-3]$ ]]
            then
                _VERBOSITY=$_ARGUMENT
                shift
            else
                _console_log 0 "invalid verbosity level: use an integer between 0 and 3"
                exit 1
            fi
            ;;
        \?)
            _console_log 0 "Invalid option: -$OPTARG" >&2
            exit 1
            ;;
    esac
done

# Ensure that no other scrcpy processes are already running
if [[ $_IS_SKIP_CHECKS -eq 0 ]]
then
    _killall_scrcpy
fi

# Start ADB server
if [[ $(adb devices | grep -w "device" | wc -l) -gt 0 ]]
then
    _console_log 2 "ADB server connected"
else
    _console_log 0 "no authorized Android device was detected: ensure you have connected it and you run this program with the correct permissions"
    exit 1
fi

# Check if a custom device streaming association was provided
if [[ -n $DEVICE_STREAM ]]
then
    if [[ $(echo $DEVICE_STREAM | cut -d ':' -f2 | wc -m) -eq 2 ]]
    then
        DEVICE_SERIAL=$(echo $DEVICE_STREAM | cut -d ':' -f 1)
        DEVICE_NUMBER=$(echo $DEVICE_STREAM | cut -d ':' -f 2)
    else
        DEVICE_SERIAL="$(echo $DEVICE_STREAM | cut -d ':' -f 1):$(echo $DEVICE_STREAM | cut -d ':' -f 2)"
        DEVICE_NUMBER=$(echo $DEVICE_STREAM | cut -d ':' -f 3)
    fi
else
    DEVICE_SERIAL=$(adb devices | tail -n+2 | head -n1 | grep -oE "^[0-9a-zA-Z]+")
    _LAST_DEV=$(ls /dev/video* | sed -rn 's/\/dev\/video([0-9]+)/\1/p' | tail -n1)
    DEVICE_NUMBER=$((_LAST_DEV + 1))
fi
_console_log 2 "this script will stream the screen from Android device $DEVICE_SERIAL to the loopback device /dev/video$DEVICE_NUMBER"

# Startup checks, perform if not skipped
if [[ $_IS_SKIP_CHECKS -eq 0 ]]
then
    # Load video loopback kernel module, under /dev/video2
    if [[ $(lsmod | grep v4l2loopback | wc -l) -gt 0 ]]
    then
        _console_log 2 "module already loaded, no new video device will be created"
    else
        _console_log 1 "requesting module loading: grant root permissions"
        sudo modprobe v4l2loopback video_nr="$DEVICE_NUMBER" card_label="Android Camera" exclusive_caps=1
        _console_log 2 "loaded /dev/video$DEVICE_NUMBER device with name \"Android Camera\""
    fi

    # Check battery level above 30%
    _get_phone_battery
    _BAT_LEVEL=$?
    _console_log 2 "phone battery level at $_BAT_LEVEL%"
    if [[ $_BAT_LEVEL -lt 30 ]]
    then
        read -p "[WARN] the phone battery is below 30%: do you still wish to continue? [y/N]" -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]
        then
            exit 0
        fi
    fi
fi

# If wireless streaming is enabled, the ADB server is restarted into TCP mode
SCRCPY_DEVICE_ID=""
if [[ $_IS_WIRELESS_ADB -eq 1 ]]
then
    _console_log 2 "starting ADB server in TCP mode on port 5555"
    adb tcpip 5555 > /dev/null 2>&1
    sleep 2
    _console_log 2 "obtaining Android device's IP address (wlan0)"
    DEVICE_IP=$(adb -s $DEVICE_SERIAL shell ip addr show wlan0 2> /dev/null | grep -w "inet" | grep -oE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | head -n1)
    if [[ -z $DEVICE_IP ]]
    then
        _console_log 0 "unable to establish a connection to the Android device: ensure its WiFi is turned on"
        adb kill-server
        exit 1
    else
        adb connect $DEVICE_IP:5555 > /dev/null 2>&1
        _ADB_DEVICES=$(adb devices | grep -w "device" | wc -l)
        _console_log 1 "connected to $DEVICE_IP: now you MUST disconnect the device cable"
        _console_log 1 "                                   ^^^^"
        # Wait until the number of adb devices is one less than before
        while [[ $(adb devices | grep -w "device" | wc -l) -ge $_ADB_DEVICES ]]
        do
            sleep 0.33
        done
        # Wait to let the ADB daemon establish the connection
        sleep 10
        # Prepare the argument with the device serial for scrcpy to recognize it
        SCRCPY_DEVICE_ID="$DEVICE_IP:5555"
        # Use the IP instead of the serial, because of ADB wireless mode
        DEVICE_SERIAL="$DEVICE_IP"
    fi
else
    SCRCPY_DEVICE_ID="$DEVICE_SERIAL"
fi

if [[ $_IS_SCREEN_ON -eq 0 ]]
then
    # Check if the screen is locked
    if [[ $(adb -s $DEVICE_SERIAL shell dumpsys power | grep -o -e 'mHoldingWakeLockSuspendBlocker=false' -e 'mHoldingDisplaySuspendBlocker=false' | wc -l) -eq 2 || $_IS_AUTO_LAUNCH -eq 0 ]]
    then
        # In case the screen is locked, open a scrcpy window and ask the user to unlock and launch the camera
        _console_log 1 "unlock your device and open the camera app; then close the scrcpy window"
        scrcpy --serial $SCRCPY_DEVICE_ID \
            --turn-screen-off \
            > /dev/null 2>&1
    else
        # If the screen is unlocked, run directly scrcpy with turn off display flag and stop it
        _console_log 2 "turning screen off during the streaming"
        scrcpy --serial $SCRCPY_DEVICE_ID \
            --turn-screen-off \
            > /dev/null 2>&1 &
        _PID_SCRCPY_OFF_SCREEN=$!
        sleep 2
        kill $_PID_SCRCPY_OFF_SCREEN
    fi
    if [[ $_IS_AUTO_LAUNCH -eq 1 ]]
    then
        # If the screen is unlocked, try to launch the OpenCamera app if it exists
        if [[ $(adb -s $DEVICE_SERIAL shell pm list packages -3 | grep -o net.sourceforge.opencamera) ]]
        then
            adb -s $DEVICE_SERIAL shell am start -n net.sourceforge.opencamera/net.sourceforge.opencamera.MainActivity > /dev/null 2>&1
            _console_log 2 "launched the OpenCamera app automatically"
        else
            # If OpenCamera is not installed, inform the user
            _console_log 1 "OpenCamera app was not found: the current screen will be captured"
        fi
    fi
fi

# Manage custom cropping
if [[ -z $CUSTOM_CROP ]]
then
    # Obtain screen size from ADB shell
    SCR_SIZE=$(adb -s $DEVICE_SERIAL shell wm size | cut -d ' ' -f 3)
    SCR_WIDTH=$(echo $SCR_SIZE | cut -d 'x' -f 1)
    SCR_HEIGHT=$(echo $SCR_SIZE | cut -d 'x' -f 2)
    # Crop the OpenCamera UI
    OC_UI_WIDTH=240
    # Set the cropping pattern inside the related variable
    CUSTOM_CROP="$SCR_WIDTH:$(($SCR_HEIGHT - $(($OC_UI_WIDTH * 2)))):0:$OC_UI_WIDTH"
fi

# Check custom bitrate and viewport scaling parameters
if [[ ! -z $MAX_DIMENSION ]]
then
    MAX_DIMENSION="-m $MAX_DIMENSION "
fi
if [[ ! -z $BITRATE ]]
then
    BITRATE="-b $BITRATE "
fi
_CUSTOM_OPTS="$MAX_DIMENSION$BITRATE"

# Capture the Android smartphone screen, crop it and send it to the socket 127.0.0.1:10080+DEVICE_NUMBER
_LOCAL_STREAMING_PORT=$((10080 + $DEVICE_NUMBER))
if [[ $_IS_SCREEN_ON -eq 0 ]]
then
    if [[ $_IS_CROPPED -eq 1 ]]
    then
        # Screen off and cropping enabled
        scrcpy --serial $SCRCPY_DEVICE_ID $_CUSTOM_OPTS\
            --max-fps $MAX_FPS \
            --turn-screen-off \
            --crop $CUSTOM_CROP \
            --no-display \
            --serve tcp:localhost:$_LOCAL_STREAMING_PORT \
            > /dev/null 2>&1 &
    else
        # Screen off and cropping disabled
        scrcpy --serial $SCRCPY_DEVICE_ID $_CUSTOM_OPTS\
            --max-fps $MAX_FPS \
            --turn-screen-off \
            --no-display \
            --serve tcp:localhost:$_LOCAL_STREAMING_PORT \
            > /dev/null 2>&1 &
    fi
else
    if [[ $_IS_CROPPED -eq 1 ]]
    then
        # Screen on and cropping enabled
        scrcpy --serial $SCRCPY_DEVICE_ID $_CUSTOM_OPTS\
            --max-fps $MAX_FPS \
            --crop $CUSTOM_CROP \
            --no-display \
            --serve tcp:localhost:$_LOCAL_STREAMING_PORT \
            > /dev/null 2>&1 &
    else
        # Screen on and cropping disabled
        scrcpy --serial $SCRCPY_DEVICE_ID $_CUSTOM_OPTS\
            --max-fps $MAX_FPS \
            --no-display \
            --serve tcp:localhost:$_LOCAL_STREAMING_PORT \
            > /dev/null 2>&1 &
    fi
fi
_console_log 2 "scrcpy is capturing the screen, streaming it to localhost:$_LOCAL_STREAMING_PORT"

# Wait for the capture to begin
sleep 1

# Inform the user on how to quit ffmpeg (once done the scrcpy server will automatically shutdown)
_console_log 2 "streaming with ffmpeg from local socket to /dev/video$DEVICE_NUMBER device"
_console_log 2 "press 'q' to terminate the streaming"

# Manage video stream letterboxing
if [[ $_IS_LETTERBOXED -ne 0 ]]
then
    # Choose the letterboxing dimensions for the video stream
    if [[ -z $LB_CUSTOM_SIZE ]]
    then
        LB_WIDTH=$SCR_WIDTH
        LB_HEIGHT=$SCR_HEIGHT
    else
        LB_WIDTH=$(echo $LB_CUSTOM_SIZE | cut -d 'x' -f 1)
        LB_HEIGHT=$(echo $LB_CUSTOM_SIZE | cut -d 'x' -f 2)
    fi
    # Set the dimensions to a 16:9 aspect ratio, swapping them if on portrait display
    if [[ $LB_HEIGHT -gt $LB_WIDTH ]]
    then
        read LB_HEIGHT LB_WIDTH <<<"$LB_WIDTH $LB_HEIGHT"
    fi
    _console_log 3 "letterbox dimensions: $LB_WIDTH x $LB_HEIGHT"
    # Pipe the letterboxed stream inside the loopback video device /dev/video2
    if [[ $_IS_FLIPPED -eq 0 ]]
    then
        ffmpeg -i tcp://localhost:$_LOCAL_STREAMING_PORT \
            -loglevel quiet \
            -c:v rawvideo \
            -vf "scale=(iw*sar)*min($LB_WIDTH/(iw*sar)\,$LB_HEIGHT/ih):ih*min($LB_WIDTH/(iw*sar)\,$LB_HEIGHT/ih), pad=$LB_WIDTH:$LB_HEIGHT:($LB_WIDTH-iw*min($LB_WIDTH/iw\,$LB_HEIGHT/ih))/2:($LB_HEIGHT-ih*min($LB_WIDTH/iw\,$LB_HEIGHT/ih))/2" \
            -pix_fmt yuv420p \
            -f v4l2 \
            "/dev/video$DEVICE_NUMBER"
    else
        _console_log 3 "Video flipped horizontally"
        ffmpeg -i tcp://localhost:$_LOCAL_STREAMING_PORT \
            -loglevel quiet \
            -c:v rawvideo \
            -vf "scale=(iw*sar)*min($LB_WIDTH/(iw*sar)\,$LB_HEIGHT/ih):ih*min($LB_WIDTH/(iw*sar)\,$LB_HEIGHT/ih), pad=$LB_WIDTH:$LB_HEIGHT:($LB_WIDTH-iw*min($LB_WIDTH/iw\,$LB_HEIGHT/ih))/2:($LB_HEIGHT-ih*min($LB_WIDTH/iw\,$LB_HEIGHT/ih))/2" \
            -vf "transpose=2,transpose=0" \
            -pix_fmt yuv420p \
            -f v4l2 \
            "/dev/video$DEVICE_NUMBER"
    fi
else
    # Pipe the scrcpy stream inside the loopback video device /dev/video2
    if [[ $_IS_FLIPPED -eq 0 ]]
    then
        ffmpeg -i tcp://localhost:$_LOCAL_STREAMING_PORT \
            -loglevel quiet \
            -c:v rawvideo \
            -pix_fmt yuv420p \
            -f v4l2 \
            "/dev/video$DEVICE_NUMBER"
    else
        _console_log 3 "Video flipped horizontally"
        ffmpeg -i tcp://localhost:$_LOCAL_STREAMING_PORT \
            -loglevel quiet \
            -c:v rawvideo \
            -pix_fmt yuv420p \
            -vf "transpose=2,transpose=0" \
            -f v4l2 \
            "/dev/video$DEVICE_NUMBER"
    fi
fi

# Turn screen off again and disconnect all ADB devices
if [[ $_IS_SCREEN_ON -eq 0 ]]
then
    _turn_screen_off &
else
    _disconnect_all &
fi
