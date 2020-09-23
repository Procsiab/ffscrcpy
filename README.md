# ffscrcpy

ffmpeg + scrcpy + v4l2loopback = 📷

This script is an automation that combine the three aforementioned tools into a 
not-totally-stable-but-still-works webcam: you will be able to stream the screen 
of your Android smartphone to any application that uses a `/dev/video` device as 
a webcam.

I recommend pairing this script with the [OpenCamera](https://play.google.com/store/apps/details?id=net.sourceforge.opencamera) Android app, which offers complete UI hiding on top of other more "mainstream" features (like face detection). Also, the automatic letterboxing is hardcoded, based on the black bars from the OpenCamera UI.

### Features

- granular logging level setting
- automatic 16:9 letterboxing, based on the device resolution
- streaming over WiFi, using ADB in `tcpip` mode
- checks the device battery on startup, and locks the screen when video terminates
- stream specific Android device to specific loopback video device

## Use multiple Android devices

**DISCLAIMER**: before attempting to follow the instructions below, you must 
install all the dependencies and know how to use this script: you must have 
read through this guide at least once!

#### Load multiple video devices

This is a new proof of concept that I recently tested out: first of all, ensure 
that there is no other loopback device already created by unloading the kernel 
module; you should run the following command:

```bash
sudo rmmod v4l2loopback
```

If you get the error "*rmmod: ERROR: Module v4l2loopback is in use*", then you 
can try to log out and log back in to your account, or at worse try to reboot 
the system.

Now, you **must** manually load the kernel module `v4l2loopback` with the 
following command (bare in mint that it is an example, and you cannot copy-paste 
it directly):

```bash
sudo modprobe v4l2loopback video_nr=2,3 card_label="Android device 123","Android device 456"
```

- the list of numbers following `video_nr` will determine how many devices will be 
created and which numbers will they be given (in this case, */dev/video2* and */dev/video3*);
- the argument `card_label` and the list of strings that follows are optional, 
and represent the labels that will be assigned to the video devices.

#### Run multiple instances of the script

For each Android device you want to stream the screen to a loopback video device, 
run this script with the `-n` argument, specifying the device's serial number and 
the video device number you would like to be streamed to (following the previous 
example):

```bash
./ffscrcpy -n 000000000123:2
./ffscrcpy -n 000000000456:3
```

You can obtain the serial number though the `adb devices` command; its output 
would look like (when all devices are attached and authorized):

```
List of devices attached
000000000123	device
000000000456	device
```

## Build the dependencies

The following instructions are meant to be run on a recent RHEL/Fedora based OS, 
however they might also apply to any other Unix system, with the correct assumptions.

### ffmpeg

You may just install this from your package manager:

```bash
sudo dnf install ffmpeg
```

[Here](https://ffmpeg.org/) you can find more information on this tool.

### v4l2loopback

[This](https://github.com/umlaeute/v4l2loopback) is a kernel module that you must compile yourself; however, it's pretty straightforward:

1. clone the repository and enter it

```bash
git clone https://github.com/umlaeute/v4l2loopback.git && cd v4l2loopback
```

2. compile the kernel module


```bash
make && sudo make install
sudo depmod -a
```

#### [optional] sign your kernel module

1. Create a compatible certificate

```bash
CERT_NAME="v4l2lb-mok"
MODULE_NAME="v4l2loopback"
openssl req -new -x509 -newkey rsa:2048 -keyout $CERT_NAME.priv -outform DER -out $CERT_NAME.der -nodes -days 36500 -subj "/CN=V4L2 LoopBack @ $(hostname)/"
```

2. Sign the module with the certificate

```bash
sudo /usr/src/kernels/$(uname -r)/scripts/sign-file sha256 ./$CERT_NAME.priv ./$CERT_NAME.der $(modinfo -n $MODULE_NAME)
```

3. Import the certificate and choose a password to apply it

```bash
sudo mokutil --import $CERT\_NAME.der
```

4. Reboot and follow the on-screen instructions, to enrol the certificate key

```bash
sudo systemctl reboot --now
```

**NOTE**: to sign the same module with the same certificate, for a new version of the kernel, after compiling it just repeat the step 2.

#### [bonus] show timeout image

To show a specific image when the loopback device has no stream fed into it, you need two additional tools:

- `v4l-utils`, a package that will install the v4l2-ctl CLI;
- `v4l2loopback-ctl`, the CLI to interact with the loopback devices, which can be installed by running the following command inside the repository of `v4l2loopback`:
    ```bash
    sudo make install-utils
    ```

At this point, **AFTER** piping a video stream into your loopback device (e.g. `/dev/video1`), you can set a custom timeout picture running the command:
```bash
v4l2loopback-ctl set-timeout-image /path/to/image.png /dev/video1
```


### scrcpy

A [fork](https://github.com/Darkroll76/scrcpy/tree/serve) of the [original](https://github.com/Genymobile/scrcpy) project, which enables a TCP connection to the scrcpy server.

To compile it, just follow the [instructions](https://github.com/Genymobile/scrcpy/blob/master/BUILD.md#system-specific-steps) on the official documentation.

## Create a UDev rule for an USB connected Android smartphone

1. Check that the group `plugdev` exists, or else create it

```bash
sudo groupadd plugdev
```

2. Add your user to that group

```bash
sudo usermod -aG plugdev $(whoami)
```
3. Find your phone from `lsusb`, and take note of its name

```bash
lsusb
```

For example, let's assume the phone has the entry:
```
Bus 001 Device 011: ID 0000:0000 Google Inc. USB2.0 Hub
```
In this case, *'Google Inc.'* is the device name.

**PRO TIP**: use the command `watch -n1 lsusb`, then unplug and plug in your phone to observe the entry that changes.

4. Create a UDev rule using the vendor and product ID from `lsusb` (we're still assuming the device name from the previous example):

```bash
ID_INFO=$(lsusb | grep 'Google Inc.' | cut -d ' ' -f 6)
VENDOR_ID=$(echo $ID_INFO | cut -d ':' -f 1)
PRODUCT_ID=$(echo $ID_INFO | cut -d ':' -f 2)
echo "SUBSYSTEM==\"usb\", ATTR{idVendor}==\"$VENDOR_ID\", ATTR{idProduct}==\"$PRODUCT_ID\", MODE=\"0666\", GROUP=\"plugdev\"" | sudo tee /etc/udev/rules.d/51-android.rules
```

5. Reboot the system to make the changes take effect

```bash
systemctl reboot now
```

## Run the script

Finally! Plug your android phone into your PC and run this script:
```bash
./ffscrcpy.sh
```

To get more information about different working modes, use the `-h` argument to summon the integrated help.
