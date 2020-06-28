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
# - there will be only one android device connected
# - the user who runs the script has access without root to its Android device ADB session
# - the smartphone will run the OpenCamera app
# - the socket 127.0.0.1:10080 is bindable


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
    adb shell input keyevent POWER
    sleep 0.2
    adb shell input keyevent POWER
    sleep 0.2
    adb shell input keyevent POWER
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
    return $(adb shell dumpsys battery | grep 'level' | grep -oE '[0-9]+')
}


# Parse command line arguments
_IS_SCREEN_ON=0
_IS_SKIP_CHECKS=0
_IS_LETTERBOXED=0
_IS_WIRELESS_ADB=0
_IS_CROPPED=1
LB_CUSTOM_SIZE=""
while getopts ":hoslwvC" OPT
do
    case $OPT in
        h)
            echo "[HELP] Usage: android-cam [-s] [-m] [-l <DIMENSIONS>] [-C] [-v LEVEL]"
            echo "[HELP]    -o: Keep phone screen on"
            echo "[HELP]    -s: Skip startup checks"
            echo "[HELP]    -l: Letterbox with phone screen dimensions
[HELP]        or specific ones, in the form of WxH in pixels"
            echo "[HELP]    -C: Do not crop the canvas to hide the OpenCamera UI"
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
            fi
            ;;
        C)
            _IS_CROPPED=0
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
            fi
            ;;
        \?)
            _console_log 0 "Invalid option: -$OPTARG" >&2
            exit 1
            ;;
    esac
done

# Ensure that no other scrcpy processes are already running
_killall_scrcpy

# Startup checks, perform if not skipped
if [[ $_IS_SKIP_CHECKS -eq 0 ]]
then
    # Load video loopback kernel module, under /dev/video2
    if [[ $(lsmod | grep v4l2loopback | wc -l) -gt 0 ]]
    then
        _console_log 2 "module already loaded"
    else
        _console_log 1 "requesting module loading: grant root permissions"
        sudo modprobe v4l2loopback video_nr=2 card_label="Android Camera"
        _console_log 2 "loaded /dev/video2 device with name \"Android Camera\""
    fi

    # Start ADB server
    if [[ $(adb get-state > /dev/null 2>&1; echo $?) -eq 0 ]]
    then
        _console_log 2 "ADB server connected"
    elif [[ $(adb get-state > /dev/null 2>&1; echo $?) -eq 1 ]]
    then
        _console_log 0 "no Android device was detected: ensure you have connected it and you run this program with the correct permissions"
        exit 1
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
SCRCPY_DEVICE_IP=""
if [[ $_IS_WIRELESS_ADB -eq 1 ]]
then
    _console_log 2 "starting ADB server in TCP mode on port 5555"
    adb tcpip 5555 > /dev/null 2>&1
    sleep 2
    _console_log 2 "obtaining Android device's IP address (wlan0)"
    DEVICE_IP=$(adb shell ip addr show wlan0 2> /dev/null | grep -w "inet" | grep -oE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | head -n1)
    if [[ -z $DEVICE_IP ]]
    then
        _console_log 0 "unable to establish a connection to the Android device: ensure its WiFi is turned on"
        adb kill-server
        exit 1
    else
        adb connect $DEVICE_IP:5555 > /dev/null 2>&1
        _console_log 1 "connected to $DEVICE_IP: now you MUST disconnect the device cable"
        _console_log 1 "                                   ^^^^"
        # Wait until the number of adb devices is only 1
        while [[ $(adb devices | grep -w "device" | wc -l) -gt 1 ]]
        do
            sleep 0.33
        done
        # Prepare the argument with the device serial for scrcpy to recognize it
        SCRCPY_DEVICE_IP="--serial $DEVICE_IP:5555 "
    fi
fi

if [[ $_IS_SCREEN_ON -eq 0 ]]
then
    # Unlock phone, turn off screen and let the user open the camera app
    _console_log 1 "unlock your device and open the camera app; then close the scrcpy window"
    scrcpy $SCRCPY_DEVICE_IP\
        --turn-screen-off \
        > /dev/null 2>&1
fi

# Obtain screen size from ADB shell
SCR_SIZE=$(adb shell wm size | cut -d ' ' -f 3)
SCR_WIDTH=$(echo $SCR_SIZE | cut -d 'x' -f 1)
SCR_HEIGHT=$(echo $SCR_SIZE | cut -d 'x' -f 2)

# Crop the OpenCamera UI
OC_UI_WIDTH=240
# Capture the Android smartphone screen, crop it and send it to the socket 127.0.0.1:10080
if [[ $_IS_SCREEN_ON -eq 0 ]]
then
    if [[ $_IS_CROPPED -eq 1 ]]
    then
        scrcpy $SCRCPY_DEVICE_IP\
            --max-fps 30 \
            --turn-screen-off \
            --crop $SCR_WIDTH:$(($SCR_HEIGHT - $(($OC_UI_WIDTH * 2)))):0:240 \
            --no-display \
            --serve tcp:localhost:10080 \
            > /dev/null 2>&1 &
    else
        scrcpy $SCRCPY_DEVICE_IP\
            --max-fps 30 \
            --turn-screen-off \
            --no-display \
            --serve tcp:localhost:10080 \
            > /dev/null 2>&1 &
    fi
else
    if [[ $_IS_CROPPED -eq 1 ]]
    then
    scrcpy $SCRCPY_DEVICE_IP\
        --max-fps 30 \
        --crop $SCR_WIDTH:$(($SCR_HEIGHT - $(($OC_UI_WIDTH * 2)))):0:240 \
        --no-display \
        --serve tcp:localhost:10080 \
        > /dev/null 2>&1 &
    else
    scrcpy $SCRCPY_DEVICE_IP\
        --max-fps 30 \
        --no-display \
        --serve tcp:localhost:10080 \
        > /dev/null 2>&1 &
    fi
fi
_console_log 2 "scrcpy is capturing the screen, streaming it to localhost:10080"

# Wait for the capture to begin
sleep 1

# Inform the user on how to quit ffmpeg (once done the scrcpy server will automatically shutdown)
_console_log 2 "streaming with ffmpeg from local socket to /dev/video2 device"
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
    ffmpeg -i tcp://localhost:10080 \
        -loglevel quiet \
        -c:v rawvideo \
        -vf "scale=(iw*sar)*min($LB_WIDTH/(iw*sar)\,$LB_HEIGHT/ih):ih*min($LB_WIDTH/(iw*sar)\,$LB_HEIGHT/ih), pad=$LB_WIDTH:$LB_HEIGHT:($LB_WIDTH-iw*min($LB_WIDTH/iw\,$LB_HEIGHT/ih))/2:($LB_HEIGHT-ih*min($LB_WIDTH/iw\,$LB_HEIGHT/ih))/2" \
        -pix_fmt yuv420p \
        -f v4l2 \
        -framerate 30 \
        /dev/video2
else
    # Pipe the scrcpy stream inside the loopback video device /dev/video2
    ffmpeg -i tcp://localhost:10080 \
        -loglevel quiet \
        -c:v rawvideo \
        -pix_fmt yuv420p \
        -f v4l2 \
        -framerate 30 \
        /dev/video2
fi

# Turn screen off again and disconnect all ADB devices
if [[ $_IS_SCREEN_ON -eq 0 ]]
then
    _turn_screen_off &
else
    _disconnect_all &
fi
