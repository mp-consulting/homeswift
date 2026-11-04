// THIS FILE IS GENERATED from ../config.schema.json by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

extension UniFiProtectPlugin {
    /// The plugin's config.schema.json, as written, for settings forms and the config copilot.
    public static let configurationSchemaJSON: String? = #"""
{
  "pluginAlias": "UniFi Protect",
  "pluginType": "platform",
  "headerDisplay": "Full HomeKit support UniFi Protect devices. See the [homebridge-unifi-protect](https://github.com/mp-consulting/homebridge-unifi-protect) developer page for detailed documentation.",
  "footerDisplay": "A working **FFmpeg** installation is required for this plugin to work. For audio support, make sure your version of ffmpeg is compiled with support for the **fdk-aac** codec, or with **libopus** (as the Homeswift container image's ffmpeg-for-homeswift is).",
  "singular": true,
  "customUi": true,
  "schema": {
    "type": "object",
    "properties": {
      "controllers": {
        "type": "array",
        "title": "UniFi Protect Controllers",
        "description": "UniFi consoles by address, for those discovery does not find; each is signed in to in Add accessories, and its login kept in the vault.",
        "items": {
          "type": "object",
          "title": "UniFi Protect Controller",
          "properties": {
            "address": {
              "type": "string",
              "title": "Controller Address",
              "required": true,
              "format": "hostname",
              "placeholder": "e.g. 1.2.3.4",
              "description": "Hostname or IP address of your UniFi Protect controller."
            },
            "doorbellMessages": {
              "type": "array",
              "title": "Doorbell Messages",
              "description": "Extra message presets for this controller's doorbells with a screen. While doorbell messages are enabled, each preset appears as a switch that shows it.",
              "items": {
                "type": "object",
                "title": "Doorbell Message",
                "properties": {
                  "duration": {
                    "type": "integer",
                    "title": "Message Duration (seconds)",
                    "required": false,
                    "minimum": 0,
                    "placeholder": "e.g. 60",
                    "description": "Length of time to display the message on your doorbell. Use 0 to display the message indefinitely. Default: 60."
                  },
                  "message": {
                    "type": "string",
                    "title": "Message Name",
                    "required": false,
                    "maxLength": 30,
                    "placeholder": "e.g. I'll be there soon.",
                    "description": "Message to display on your doorbell. Default: None."
                  }
                }
              }
            },
            "mqttTopic": {
              "type": "string",
              "title": "MQTT Base Topic",
              "required": false,
              "placeholder": "e.g. unifi/protect",
              "description": "Base topic for the events. Empty: unifi/protect."
            },
            "mqttVerifyTls": {
              "type": "boolean",
              "title": "Verify MQTT Broker TLS Certificate",
              "required": false,
              "default": true,
              "description": "Check the broker's certificate over mqtts:// or ssl://. Turn off for a self-signed one."
            },
            "mqttUrl": {
              "type": "string",
              "title": "MQTT Broker URL",
              "required": false,
              "format": "uri",
              "placeholder": "e.g. mqtt://1.2.3.4",
              "description": "Broker to publish events to."
            },
            "name": {
              "type": "string",
              "title": "Controller Name",
              "required": false,
              "placeholder": "e.g. UNVR",
              "description": "Name for this UniFi Protect controller to be used for logging purposes. Default: Defined by the controller."
            },
            "overrideAddress": {
              "type": "string",
              "title": "Override Controller Address",
              "required": false,
              "description": "Address to stream from instead, for a VPN or remote access. Not for stacked controllers."
            },
            "playlistAddress": {
              "type": "string",
              "title": "M3U Playlist Bind Address",
              "required": false,
              "placeholder": "e.g. 127.0.0.1",
              "description": "Local address the M3U playlist listens on. Empty: every interface."
            },
            "verifyTls": {
              "type": "boolean",
              "title": "Verify TLS Certificate",
              "required": false,
              "description": "Check the controller's certificate against trusted authorities. Off, as UniFi consoles sign their own: the first certificate seen is pinned and any other refused."
            }
          }
        }
      },
      "debug": {
        "type": "boolean",
        "title": "Debug Logging",
        "required": false,
        "description": "Enable debug logging for this plugin. This creates a large volume of log output and should only be used when troubleshooting. Default: false."
      },
      "name": {
        "type": "string",
        "title": "Plugin Name",
        "required": true,
        "default": "UniFi Protect",
        "description": "Name to use for logging purposes. Default: UniFi Protect."
      },
      "options": {
        "type": "array",
        "title": "Feature Options",
        "description": "Feature options of a Homebridge block that no setting says (Enable.<option> or Disable.<option>, optionally followed by a device's MAC), one per entry. The bridge moves the others into the settings.",
        "items": {
          "type": "string",
          "required": false,
          "description": "One option per entry, as the Homebridge plugin's README spells them.",
          "placeholder": "e.g. Disable.Device"
        }
      },
      "ringDelay": {
        "type": "integer",
        "title": "Doorbell Ring Delay (seconds)",
        "required": false,
        "minimum": 0,
        "maximum": 60,
        "placeholder": "e.g. 5",
        "description": "Delay between doorbell rings. Setting this to a non-zero value will prevent multiple rings of a doorbell over the specified duration. Default: 0."
      },
      "verboseFfmpeg": {
        "type": "boolean",
        "title": "Verbose FFmpeg Logging",
        "required": false,
        "description": "Enable additional logging for FFmpeg. This will create additional logging when video streams are running. Default: false."
      },
      "videoProcessor": {
        "type": "string",
        "title": "FFmpeg Location",
        "required": false,
        "placeholder": "e.g. /usr/local/bin/ffmpeg",
        "description": "Path to the FFmpeg executable. Most users should not use this setting. Default: the first ffmpeg found in PATH."
      },
      "audio": {
        "type": "boolean",
        "title": "Audio",
        "default": true,
        "description": "Audio support."
      },
      "audioFilterNoise": {
        "type": "boolean",
        "title": "Noise Filter",
        "default": false,
        "description": "Audio filter for ambient noise suppression."
      },
      "audioFilterNoiseFftNr": {
        "type": "number",
        "title": "Noise Reduction (dB)",
        "placeholder": 14,
        "description": "Noise reduction amount, in decibels, for the FFmpeg afftdn filter."
      },
      "audioFilterNoiseHighPass": {
        "type": "number",
        "title": "High-Pass Filter (Hz)",
        "placeholder": 150,
        "description": "Frequency, in Hertz, for the FFmpeg highpass filter."
      },
      "audioFilterNoiseLowPass": {
        "type": "number",
        "title": "Low-Pass Filter (Hz)",
        "placeholder": 9000,
        "description": "Frequency, in Hertz, for the FFmpeg lowpass filter."
      },
      "audioTwoWay": {
        "type": "boolean",
        "title": "Two-Way Audio",
        "default": true,
        "description": "Two-way audio support on supported cameras."
      },
      "audioTwoWayDirect": {
        "type": "boolean",
        "title": "Two-Way Audio Straight to the Camera",
        "default": false,
        "description": "Send two-way audio directly to supported cameras, bypassing the controller. Useful for working around bugs in some Protect controller firmware versions."
      },
      "deviceStatusLed": {
        "type": "boolean",
        "title": "Status Light",
        "default": true,
        "description": "Enable the status indicator light for this device in HomeKit."
      },
      "deviceStatusLedSwitch": {
        "type": "boolean",
        "title": "Status Light Switch",
        "default": false,
        "description": "Add a switch accessory to control the status indicator light in HomeKit."
      },
      "deviceNightVision": {
        "type": "boolean",
        "title": "Night Vision",
        "default": true,
        "description": "Enable the night vision indicator light for this device in HomeKit."
      },
      "deviceNightVisionDimmer": {
        "type": "boolean",
        "title": "Night Vision Dimmer",
        "default": false,
        "description": "Add a dimmer accessory to control the night vision state in HomeKit."
      },
      "deviceStandalone": {
        "type": "boolean",
        "title": "Standalone Accessory",
        "default": false,
        "description": "Make this a standalone device in HomeKit that will need to be added to HomeKit through the Home app."
      },
      "deviceSelfHealing": {
        "type": "boolean",
        "title": "Restart When Misbehaving",
        "default": true,
        "description": "Attempt to restart misbehaving devices. This is always done very conservatively and only after periods of extended device-specific issues."
      },
      "deviceSyncName": {
        "type": "boolean",
        "title": "Sync Names",
        "default": false,
        "description": "Synchronize the UniFi Protect name of this device with HomeKit. Synchronization is one-way only, syncing the device name from UniFi Protect to HomeKit."
      },
      "doorbellAuthSensor": {
        "type": "boolean",
        "title": "Fingerprint and NFC Sensor",
        "default": false,
        "description": "Add a contact sensor that gets activates when a fingerprint or NFC successfully authenticates on a Protect doorbell."
      },
      "doorbellMute": {
        "type": "boolean",
        "title": "Mute Switch",
        "default": false,
        "description": "Add a switch accessory to control whether HomeKit will chime when the doorbell is pressed."
      },
      "doorbellMessagesEnabled": {
        "type": "boolean",
        "title": "Doorbell Messages",
        "default": false,
        "description": "Enable the doorbell messages feature."
      },
      "doorbellMessagesFromDoorbell": {
        "type": "boolean",
        "title": "Messages Saved on the NVR",
        "default": true,
        "description": "Use messages saved to the Protect NVR as message switches."
      },
      "doorbellVolumeDimmer": {
        "type": "boolean",
        "title": "Chime Volume Dimmer",
        "default": false,
        "description": "Add a dimmer accessory to control the Protect chime volume in HomeKit."
      },
      "doorbellPhysicalChime": {
        "type": "boolean",
        "title": "Physical Chime Switches",
        "default": false,
        "description": "Add switch accessories to control the physical chimes attached to a Protect doorbell."
      },
      "doorbellPhysicalChimeDurationDigital": {
        "type": "number",
        "title": "Digital Chime Duration (ms)",
        "placeholder": 1000,
        "description": "Chime duration, in milliseconds, of a digital physical chime attached to a Protect doorbell."
      },
      "doorbellPackageCameraFlashlight": {
        "type": "boolean",
        "title": "Package Camera Flashlight",
        "default": true,
        "description": "Add a light accessory to control the flashlight on a Protect doorbell package camera."
      },
      "doorbellTrigger": {
        "type": "boolean",
        "title": "Doorbell Trigger Switch",
        "default": false,
        "description": "Add a switch accessory to trigger doorbell ring events on a Protect camera or doorbell."
      },
      "logDoorbell": {
        "type": "boolean",
        "title": "Log Doorbell Rings",
        "default": true,
        "description": "Write doorbell rings to the log."
      },
      "logHKSV": {
        "type": "boolean",
        "title": "Log HomeKit Secure Video",
        "default": false,
        "description": "Write HomeKit Secure Video recording events to the log."
      },
      "logMotion": {
        "type": "boolean",
        "title": "Log Motion",
        "default": false,
        "description": "Write motion events to the log."
      },
      "motionDuration": {
        "type": "number",
        "title": "Motion Event Length (seconds)",
        "placeholder": 10,
        "description": "Duration, in seconds, of a single motion event, before allowing a new one."
      },
      "motionOccupancySensor": {
        "type": "boolean",
        "title": "Occupancy Sensor",
        "default": false,
        "description": "Add an occupancy sensor accessory using motion sensor activity to determine occupancy. By default, any motion will trigger occupancy. If the smart detection feature option is enabled, it will be used instead."
      },
      "motionOccupancySensorDuration": {
        "type": "number",
        "title": "Occupancy Timeout (seconds)",
        "placeholder": 300,
        "description": "Duration, in seconds, to wait without receiving a motion event to determine when occupancy is no longer detected."
      },
      "motionOccupancySensorAnimal": {
        "type": "boolean",
        "title": "Animal",
        "default": false,
        "description": "Count Protect's animal detection as occupancy."
      },
      "motionOccupancySensorFace": {
        "type": "boolean",
        "title": "Face",
        "default": true,
        "description": "Count Protect's face detection as occupancy."
      },
      "motionOccupancySensorLicensePlate": {
        "type": "boolean",
        "title": "License Plate",
        "default": false,
        "description": "Count Protect's license plate detection as occupancy."
      },
      "motionOccupancySensorPackage": {
        "type": "boolean",
        "title": "Package",
        "default": false,
        "description": "Count Protect's package detection as occupancy."
      },
      "motionOccupancySensorPerson": {
        "type": "boolean",
        "title": "Person",
        "default": true,
        "description": "Count Protect's person detection as occupancy."
      },
      "motionOccupancySensorVehicle": {
        "type": "boolean",
        "title": "Vehicle",
        "default": false,
        "description": "Count Protect's vehicle detection as occupancy."
      },
      "motionOccupancySensorAlrmBabyCry": {
        "type": "boolean",
        "title": "Baby Crying",
        "default": false,
        "description": "Count Protect's baby crying detection as occupancy."
      },
      "motionOccupancySensorAlrmBark": {
        "type": "boolean",
        "title": "Barking",
        "default": false,
        "description": "Count Protect's barking detection as occupancy."
      },
      "motionOccupancySensorAlrmBurglar": {
        "type": "boolean",
        "title": "Burglar Alarm",
        "default": false,
        "description": "Count Protect's burglar alarm detection as occupancy."
      },
      "motionOccupancySensorAlrmCarHorn": {
        "type": "boolean",
        "title": "Car Horn",
        "default": false,
        "description": "Count Protect's car horn detection as occupancy."
      },
      "motionOccupancySensorAlrmCmonx": {
        "type": "boolean",
        "title": "CO Alarm",
        "default": false,
        "description": "Count Protect's CO alarm detection as occupancy."
      },
      "motionOccupancySensorAlrmGlassBreak": {
        "type": "boolean",
        "title": "Glass Break",
        "default": false,
        "description": "Count Protect's glass break detection as occupancy."
      },
      "motionOccupancySensorAlrmSiren": {
        "type": "boolean",
        "title": "Siren",
        "default": false,
        "description": "Count Protect's siren detection as occupancy."
      },
      "motionOccupancySensorAlrmSmoke": {
        "type": "boolean",
        "title": "Smoke Alarm",
        "default": false,
        "description": "Count Protect's smoke alarm detection as occupancy."
      },
      "motionOccupancySensorAlrmSpeak": {
        "type": "boolean",
        "title": "Speaking",
        "default": false,
        "description": "Count Protect's speaking detection as occupancy."
      },
      "motionOccupancySensorSmokeCmonx": {
        "type": "boolean",
        "title": "Smoke and CO Alarm",
        "default": false,
        "description": "Count Protect's smoke and CO alarm detection as occupancy."
      },
      "motionSmartDetect": {
        "type": "boolean",
        "title": "Smart Detection",
        "default": false,
        "description": "Use UniFi Protect smart detection for HomeKit motion events when on a supported device."
      },
      "motionSmartDetectObjectSensors": {
        "type": "boolean",
        "title": "Object Sensors",
        "default": false,
        "description": "Add contact sensors for each smart detection object type that UniFi Protect supports."
      },
      "motionSmartDetectObjectSensorsLicensePlate": {
        "type": "string",
        "title": "License Plates to Match",
        "description": "Add a contact sensor accessory that will match a specific license plate detected by UniFi Protect. You may specify multiple license plates by using hyphens to distinguish unique license plates (e.g. PLATE1-PLATE2-PLATE3)."
      },
      "motionSwitch": {
        "type": "boolean",
        "title": "Motion Detection Switch",
        "default": false,
        "description": "Add a switch accessory to activate or deactivate motion detection in HomeKit."
      },
      "motionTrigger": {
        "type": "boolean",
        "title": "Motion Trigger Switch",
        "default": false,
        "description": "Add a switch accessory to manually trigger a motion detection event in HomeKit."
      },
      "nvrServicePlaylist": {
        "type": "number",
        "title": "M3U Playlist Port",
        "placeholder": 10110,
        "description": "Publish an M3U playlist of the Protect cameras on this port of the bridge, for apps such as Channels DVR that play livestreams."
      },
      "nvrDelayDeviceRemoval": {
        "type": "number",
        "title": "Device Removal Delay (seconds)",
        "placeholder": 60,
        "description": "Delay, in seconds, before removing devices that are no longer detected on the Protect controller. If disabled, devices are removed in realtime when the Protect controller does so."
      },
      "nvrPublishTelemetry": {
        "type": "boolean",
        "title": "Publish Telemetry",
        "default": false,
        "description": "Publish all the realtime telemetry received from the Protect controller to MQTT."
      },
      "nvrRecordingSwitch": {
        "type": "boolean",
        "title": "Recording Switches",
        "default": false,
        "description": "Add switch accessories to control the native recording capabilities of the UniFi Protect NVR."
      },
      "nvrSystemInfo": {
        "type": "boolean",
        "title": "System Info Sensors",
        "default": false,
        "description": "Add sensor accessories to display the Protect controller system information (currently only the temperature)."
      },
      "securitySystemAlarm": {
        "type": "boolean",
        "title": "Alarm Switch",
        "default": false,
        "description": "Add a switch accessory to trigger the security system accessory, when using the liveview feature option."
      },
      "sensorMoistureSensor": {
        "type": "boolean",
        "title": "Leak Sensor as Contact Sensor",
        "default": false,
        "description": "Expose the Protect leak sensor as a contact sensor instead of a leak sensor. This is useful for automation scenarios since HomeKit contact sensors offer more flexible automation options than leak sensors, which are primarily designed for alerts."
      },
      "uniFiAccessLock": {
        "type": "boolean",
        "title": "UniFi Access Lock",
        "default": true,
        "description": "Add a lock accessory to unlock. Currently, Protect only supports unlocking Access readers with a camera on the same controller as Protect."
      },
      "videoTranscodeHardware": {
        "type": "boolean",
        "title": "Hardware Transcoding",
        "default": true,
        "description": "Use hardware-accelerated transcoding when available (Apple Macs, Intel Quick Sync Video-enabled CPUs, Raspberry Pi 4)."
      },
      "videoStreamUseApi": {
        "type": "boolean",
        "title": "Protect Livestream API",
        "default": true,
        "description": "Use the native Protect livestream API to view livestreams."
      },
      "videoTranscode": {
        "type": "boolean",
        "title": "Transcode at Home",
        "default": true,
        "description": "When streaming to low-latency clients (e.g. at home), transcode livestreams, instead of transmuxing them."
      },
      "videoTranscodeBitrate": {
        "type": "number",
        "title": "Bitrate at Home (kbps)",
        "placeholder": 2000,
        "description": "Bitrate, in kilobits per second, to use when transcoding to low-latency (e.g. at home) clients, ignoring the bitrate HomeKit requests. HomeKit typically requests lower video quality than you may desire in your environment."
      },
      "videoTranscodeHighLatency": {
        "type": "boolean",
        "title": "Transcode Away",
        "default": true,
        "description": "When streaming to high-latency clients (e.g. cellular connections), transcode livestreams instead of transmuxing them."
      },
      "videoTranscodeHighLatencyBitrate": {
        "type": "number",
        "title": "Bitrate Away (kbps)",
        "placeholder": 1000,
        "description": "Bitrate, in kilobits per second, to use when transcoding to high-latency (e.g. cellular) clients, ignoring the bitrate HomeKit requests. HomeKit typically requests lower video quality than you may desire in your environment."
      },
      "videoStreamOnlyHigh": {
        "type": "boolean",
        "title": "High Quality Only",
        "default": false,
        "description": "When viewing livestreams, force the use of the high quality video stream from the Protect controller."
      },
      "videoStreamOnlyMedium": {
        "type": "boolean",
        "title": "Medium Quality Only",
        "default": false,
        "description": "When viewing livestreams, force the use of the medium quality video stream from the Protect controller."
      },
      "videoStreamOnlyLow": {
        "type": "boolean",
        "title": "Low Quality Only",
        "default": false,
        "description": "When viewing livestreams, force the use of the low quality video stream from the Protect controller."
      },
      "videoCrop": {
        "type": "boolean",
        "title": "Crop",
        "default": false,
        "description": "Crop the camera video stream. Enabling this option will also force transcoding of livestreams."
      },
      "videoCropX": {
        "type": "number",
        "title": "Left (%)",
        "placeholder": 0,
        "description": "Left offset of the crop window, as a percentage of the original image width."
      },
      "videoCropY": {
        "type": "number",
        "title": "Top (%)",
        "placeholder": 0,
        "description": "Top offset of the crop window, as a percentage of the original image height."
      },
      "videoCropWidth": {
        "type": "number",
        "title": "Width (%)",
        "placeholder": 100,
        "description": "Width of the crop window, as a percentage of original image width."
      },
      "videoCropHeight": {
        "type": "number",
        "title": "Height (%)",
        "placeholder": 100,
        "description": "Height of the crop window, as a percentage of original image height."
      },
      "videoHighResSnapshots": {
        "type": "boolean",
        "title": "High-Resolution Snapshots",
        "default": true,
        "description": "Enable higher quality snapshots."
      },
      "videoHKSVStatusLedIndicator": {
        "type": "boolean",
        "title": "Status Light While Recording",
        "default": false,
        "description": "Use the camera status indicator light to show when an HKSV event is being recorded."
      },
      "videoHKSVRecordingSwitch": {
        "type": "boolean",
        "title": "Recording Switch",
        "default": false,
        "description": "Add a switch accessory to enable or disable HKSV event recording."
      },
      "videoHKSVRecordOnlyHigh": {
        "type": "boolean",
        "title": "Record High Quality Only",
        "default": false,
        "description": "When recording HomeKit Secure Video events, force the use of the high quality video stream from the Protect controller."
      },
      "videoHKSVRecordOnlyMedium": {
        "type": "boolean",
        "title": "Record Medium Quality Only",
        "default": false,
        "description": "When recording HomeKit Secure Video events, force the use of the medium quality video stream from the Protect controller."
      },
      "videoHKSVRecordOnlyLow": {
        "type": "boolean",
        "title": "Record Low Quality Only",
        "default": false,
        "description": "When recording HomeKit Secure Video events, force the use of the low quality video stream from the Protect controller."
      }
    }
  },
  "accessorySchema": {
    "properties": {
      "address": {
        "type": "string",
        "title": "Controller Address",
        "format": "hostname",
        "placeholder": "e.g. 1.2.3.4",
        "description": "Hostname or IP address of your UniFi Protect controller.",
        "x-kinds": [
          "nvr"
        ]
      },
      "overrideAddress": {
        "type": "string",
        "title": "Override Controller Address",
        "description": "Address to stream from instead, for a VPN or remote access. Not for stacked controllers.",
        "x-kinds": [
          "nvr"
        ]
      },
      "verifyTls": {
        "type": "boolean",
        "title": "Verify TLS Certificate",
        "description": "Check the controller's certificate against trusted authorities. Off, as UniFi consoles sign their own: the first certificate seen is pinned and any other refused.",
        "x-kinds": [
          "nvr"
        ]
      },
      "mqttUrl": {
        "type": "string",
        "title": "MQTT Broker URL",
        "format": "uri",
        "placeholder": "e.g. mqtt://1.2.3.4",
        "description": "Broker to publish events to.",
        "x-kinds": [
          "nvr"
        ]
      },
      "mqttTopic": {
        "type": "string",
        "title": "MQTT Base Topic",
        "placeholder": "e.g. unifi/protect",
        "description": "Base topic for the events. Empty: unifi/protect.",
        "x-kinds": [
          "nvr"
        ]
      },
      "mqttVerifyTls": {
        "type": "boolean",
        "title": "Verify MQTT Broker TLS Certificate",
        "default": true,
        "description": "Check the broker's certificate over mqtts:// or ssl://. Turn off for a self-signed one.",
        "x-kinds": [
          "nvr"
        ]
      },
      "playlistAddress": {
        "type": "string",
        "title": "M3U Playlist Bind Address",
        "placeholder": "e.g. 127.0.0.1",
        "description": "Local address the M3U playlist listens on. Empty: every interface.",
        "x-kinds": [
          "nvr"
        ]
      },
      "doorbellMessages": {
        "type": "array",
        "title": "Doorbell Messages",
        "description": "Extra message presets for this controller's doorbells with a screen. While doorbell messages are enabled, each preset appears as a switch that shows it.",
        "items": {
          "type": "object",
          "title": "Doorbell Message",
          "properties": {
            "duration": {
              "type": "integer",
              "title": "Message Duration (seconds)",
              "required": false,
              "minimum": 0,
              "placeholder": "e.g. 60",
              "description": "Length of time to display the message on your doorbell. Use 0 to display the message indefinitely. Default: 60."
            },
            "message": {
              "type": "string",
              "title": "Message Name",
              "required": false,
              "maxLength": 30,
              "placeholder": "e.g. I'll be there soon.",
              "description": "Message to display on your doorbell. Default: None."
            }
          }
        },
        "x-kinds": [
          "nvr"
        ]
      },
      "rtspUrl": {
        "type": "string",
        "title": "Direct RTSP / RTSPS URL",
        "placeholder": "e.g. rtsp://user:pass@192.168.1.50:8554/stream",
        "description": "Full RTSP or RTSPS URL pointing directly at the camera's own RTSP server, bypassing the Protect controller. Credentials may be embedded.",
        "x-kinds": [
          "thirdPartyCamera"
        ]
      },
      "snapshotUrl": {
        "type": "string",
        "title": "Direct Snapshot URL",
        "placeholder": "e.g. http://192.168.1.50:8080/snapshot",
        "description": "Full HTTP or HTTPS URL pointing at the camera's snapshot endpoint. Credentials may be embedded. Self-signed certificates are accepted.",
        "x-kinds": [
          "thirdPartyCamera"
        ]
      },
      "onvifPort": {
        "type": "integer",
        "title": "ONVIF Port",
        "minimum": 1,
        "maximum": 65535,
        "description": "ONVIF service port remembered for the discovery panel. Leave empty to let the panel try common defaults.",
        "x-kinds": [
          "thirdPartyCamera"
        ]
      },
      "onvifUsername": {
        "type": "string",
        "title": "ONVIF Username",
        "description": "Username remembered for the ONVIF discovery panel. Stored in plaintext alongside the controller credentials.",
        "x-kinds": [
          "thirdPartyCamera"
        ]
      },
      "onvifServicePath": {
        "type": "string",
        "title": "ONVIF Service Path",
        "placeholder": "/onvif/device_service",
        "description": "Optional ONVIF device service path remembered for the discovery panel. Defaults to /onvif/device_service when blank.",
        "x-kinds": [
          "thirdPartyCamera"
        ]
      },
      "audio": {
        "type": "boolean",
        "title": "Audio",
        "description": "Audio support.",
        "x-kinds": [
          "camera",
          "thirdPartyCamera"
        ],
        "x-default": "audio"
      },
      "audioFilterNoise": {
        "type": "boolean",
        "title": "Noise Filter",
        "description": "Audio filter for ambient noise suppression.",
        "x-kinds": [
          "camera",
          "thirdPartyCamera"
        ],
        "x-default": "audioFilterNoise"
      },
      "audioFilterNoiseFftNr": {
        "type": "number",
        "title": "Noise Reduction (dB)",
        "placeholder": 14,
        "description": "Noise reduction amount, in decibels, for the FFmpeg afftdn filter.",
        "x-kinds": [
          "camera",
          "thirdPartyCamera"
        ],
        "x-default": "audioFilterNoiseFftNr"
      },
      "audioFilterNoiseHighPass": {
        "type": "number",
        "title": "High-Pass Filter (Hz)",
        "placeholder": 150,
        "description": "Frequency, in Hertz, for the FFmpeg highpass filter.",
        "x-kinds": [
          "camera",
          "thirdPartyCamera"
        ],
        "x-default": "audioFilterNoiseHighPass"
      },
      "audioFilterNoiseLowPass": {
        "type": "number",
        "title": "Low-Pass Filter (Hz)",
        "placeholder": 9000,
        "description": "Frequency, in Hertz, for the FFmpeg lowpass filter.",
        "x-kinds": [
          "camera",
          "thirdPartyCamera"
        ],
        "x-default": "audioFilterNoiseLowPass"
      },
      "audioTwoWay": {
        "type": "boolean",
        "title": "Two-Way Audio",
        "description": "Two-way audio support on supported cameras.",
        "x-kinds": [
          "camera",
          "thirdPartyCamera"
        ],
        "x-default": "audioTwoWay"
      },
      "audioTwoWayDirect": {
        "type": "boolean",
        "title": "Two-Way Audio Straight to the Camera",
        "description": "Send two-way audio directly to supported cameras, bypassing the controller. Useful for working around bugs in some Protect controller firmware versions.",
        "x-kinds": [
          "camera",
          "thirdPartyCamera"
        ],
        "x-default": "audioTwoWayDirect"
      },
      "deviceStatusLed": {
        "type": "boolean",
        "title": "Status Light",
        "description": "Enable the status indicator light for this device in HomeKit.",
        "x-kinds": [
          "camera",
          "thirdPartyCamera"
        ],
        "x-default": "deviceStatusLed"
      },
      "deviceNightVision": {
        "type": "boolean",
        "title": "Night Vision",
        "description": "Enable the night vision indicator light for this device in HomeKit.",
        "x-kinds": [
          "camera",
          "thirdPartyCamera"
        ],
        "x-default": "deviceNightVision"
      },
      "deviceStandalone": {
        "type": "boolean",
        "title": "Standalone Accessory",
        "description": "Make this a standalone device in HomeKit that will need to be added to HomeKit through the Home app.",
        "x-kinds": [
          "camera",
          "thirdPartyCamera",
          "chime",
          "light",
          "sensor",
          "viewer",
          "nvr"
        ],
        "x-default": "deviceStandalone"
      },
      "deviceSelfHealing": {
        "type": "boolean",
        "title": "Restart When Misbehaving",
        "description": "Attempt to restart misbehaving devices. This is always done very conservatively and only after periods of extended device-specific issues.",
        "x-kinds": [
          "camera",
          "thirdPartyCamera"
        ],
        "x-default": "deviceSelfHealing"
      },
      "deviceSyncName": {
        "type": "boolean",
        "title": "Sync Names",
        "description": "Synchronize the UniFi Protect name of this device with HomeKit. Synchronization is one-way only, syncing the device name from UniFi Protect to HomeKit.",
        "x-kinds": [
          "camera",
          "thirdPartyCamera",
          "chime",
          "light",
          "sensor",
          "viewer",
          "nvr"
        ],
        "x-default": "deviceSyncName"
      },
      "doorbellMessagesEnabled": {
        "type": "boolean",
        "title": "Doorbell Messages",
        "description": "Enable the doorbell messages feature.",
        "x-kinds": [
          "camera",
          "thirdPartyCamera"
        ],
        "x-default": "doorbellMessagesEnabled"
      },
      "doorbellMessagesFromDoorbell": {
        "type": "boolean",
        "title": "Messages Saved on the NVR",
        "description": "Use messages saved to the Protect NVR as message switches.",
        "x-kinds": [
          "camera",
          "thirdPartyCamera"
        ],
        "x-default": "doorbellMessagesFromDoorbell"
      },
      "doorbellVolumeDimmer": {
        "type": "boolean",
        "title": "Chime Volume Dimmer",
        "description": "Add a dimmer accessory to control the Protect chime volume in HomeKit.",
        "x-kinds": [
          "camera",
          "thirdPartyCamera"
        ],
        "x-default": "doorbellVolumeDimmer"
      },
      "doorbellPhysicalChimeDurationDigital": {
        "type": "number",
        "title": "Digital Chime Duration (ms)",
        "placeholder": 1000,
        "description": "Chime duration, in milliseconds, of a digital physical chime attached to a Protect doorbell.",
        "x-kinds": [
          "camera",
          "thirdPartyCamera"
        ],
        "x-default": "doorbellPhysicalChimeDurationDigital"
      },
      "doorbellTrigger": {
        "type": "boolean",
        "title": "Doorbell Trigger Switch",
        "description": "Add a switch accessory to trigger doorbell ring events on a Protect camera or doorbell.",
        "x-kinds": [
          "camera",
          "thirdPartyCamera"
        ],
        "x-default": "doorbellTrigger"
      },
      "logDoorbell": {
        "type": "boolean",
        "title": "Log Doorbell Rings",
        "description": "Write doorbell rings to the log.",
        "x-kinds": [
          "camera",
          "thirdPartyCamera"
        ],
        "x-default": "logDoorbell"
      },
      "logHKSV": {
        "type": "boolean",
        "title": "Log HomeKit Secure Video",
        "description": "Write HomeKit Secure Video recording events to the log.",
        "x-kinds": [
          "camera"
        ],
        "x-default": "logHKSV"
      },
      "logMotion": {
        "type": "boolean",
        "title": "Log Motion",
        "description": "Write motion events to the log.",
        "x-kinds": [
          "camera",
          "light",
          "sensor"
        ],
        "x-default": "logMotion"
      },
      "motionDuration": {
        "type": "number",
        "title": "Motion Event Length (seconds)",
        "placeholder": 10,
        "description": "Duration, in seconds, of a single motion event, before allowing a new one.",
        "x-kinds": [
          "camera",
          "light",
          "sensor"
        ],
        "x-default": "motionDuration"
      },
      "motionOccupancySensorDuration": {
        "type": "number",
        "title": "Occupancy Timeout (seconds)",
        "placeholder": 300,
        "description": "Duration, in seconds, to wait without receiving a motion event to determine when occupancy is no longer detected.",
        "x-kinds": [
          "camera",
          "light",
          "sensor"
        ],
        "x-default": "motionOccupancySensorDuration"
      },
      "motionOccupancySensorAnimal": {
        "type": "boolean",
        "title": "Animal",
        "x-kinds": [
          "camera",
          "light",
          "sensor"
        ],
        "x-default": "motionOccupancySensorAnimal",
        "description": "Count Protect's animal detection as occupancy."
      },
      "motionOccupancySensorFace": {
        "type": "boolean",
        "title": "Face",
        "x-kinds": [
          "camera",
          "light",
          "sensor"
        ],
        "x-default": "motionOccupancySensorFace",
        "description": "Count Protect's face detection as occupancy."
      },
      "motionOccupancySensorLicensePlate": {
        "type": "boolean",
        "title": "License Plate",
        "x-kinds": [
          "camera",
          "light",
          "sensor"
        ],
        "x-default": "motionOccupancySensorLicensePlate",
        "description": "Count Protect's license plate detection as occupancy."
      },
      "motionOccupancySensorPackage": {
        "type": "boolean",
        "title": "Package",
        "x-kinds": [
          "camera",
          "light",
          "sensor"
        ],
        "x-default": "motionOccupancySensorPackage",
        "description": "Count Protect's package detection as occupancy."
      },
      "motionOccupancySensorPerson": {
        "type": "boolean",
        "title": "Person",
        "x-kinds": [
          "camera",
          "light",
          "sensor"
        ],
        "x-default": "motionOccupancySensorPerson",
        "description": "Count Protect's person detection as occupancy."
      },
      "motionOccupancySensorVehicle": {
        "type": "boolean",
        "title": "Vehicle",
        "x-kinds": [
          "camera",
          "light",
          "sensor"
        ],
        "x-default": "motionOccupancySensorVehicle",
        "description": "Count Protect's vehicle detection as occupancy."
      },
      "motionOccupancySensorAlrmBabyCry": {
        "type": "boolean",
        "title": "Baby Crying",
        "x-kinds": [
          "camera",
          "light",
          "sensor"
        ],
        "x-default": "motionOccupancySensorAlrmBabyCry",
        "description": "Count Protect's baby crying detection as occupancy."
      },
      "motionOccupancySensorAlrmBark": {
        "type": "boolean",
        "title": "Barking",
        "x-kinds": [
          "camera",
          "light",
          "sensor"
        ],
        "x-default": "motionOccupancySensorAlrmBark",
        "description": "Count Protect's barking detection as occupancy."
      },
      "motionOccupancySensorAlrmBurglar": {
        "type": "boolean",
        "title": "Burglar Alarm",
        "x-kinds": [
          "camera",
          "light",
          "sensor"
        ],
        "x-default": "motionOccupancySensorAlrmBurglar",
        "description": "Count Protect's burglar alarm detection as occupancy."
      },
      "motionOccupancySensorAlrmCarHorn": {
        "type": "boolean",
        "title": "Car Horn",
        "x-kinds": [
          "camera",
          "light",
          "sensor"
        ],
        "x-default": "motionOccupancySensorAlrmCarHorn",
        "description": "Count Protect's car horn detection as occupancy."
      },
      "motionOccupancySensorAlrmCmonx": {
        "type": "boolean",
        "title": "CO Alarm",
        "x-kinds": [
          "camera",
          "light",
          "sensor"
        ],
        "x-default": "motionOccupancySensorAlrmCmonx",
        "description": "Count Protect's CO alarm detection as occupancy."
      },
      "motionOccupancySensorAlrmGlassBreak": {
        "type": "boolean",
        "title": "Glass Break",
        "x-kinds": [
          "camera",
          "light",
          "sensor"
        ],
        "x-default": "motionOccupancySensorAlrmGlassBreak",
        "description": "Count Protect's glass break detection as occupancy."
      },
      "motionOccupancySensorAlrmSiren": {
        "type": "boolean",
        "title": "Siren",
        "x-kinds": [
          "camera",
          "light",
          "sensor"
        ],
        "x-default": "motionOccupancySensorAlrmSiren",
        "description": "Count Protect's siren detection as occupancy."
      },
      "motionOccupancySensorAlrmSmoke": {
        "type": "boolean",
        "title": "Smoke Alarm",
        "x-kinds": [
          "camera",
          "light",
          "sensor"
        ],
        "x-default": "motionOccupancySensorAlrmSmoke",
        "description": "Count Protect's smoke alarm detection as occupancy."
      },
      "motionOccupancySensorAlrmSpeak": {
        "type": "boolean",
        "title": "Speaking",
        "x-kinds": [
          "camera",
          "light",
          "sensor"
        ],
        "x-default": "motionOccupancySensorAlrmSpeak",
        "description": "Count Protect's speaking detection as occupancy."
      },
      "motionOccupancySensorSmokeCmonx": {
        "type": "boolean",
        "title": "Smoke and CO Alarm",
        "x-kinds": [
          "camera",
          "light",
          "sensor"
        ],
        "x-default": "motionOccupancySensorSmokeCmonx",
        "description": "Count Protect's smoke and CO alarm detection as occupancy."
      },
      "motionSmartDetect": {
        "type": "boolean",
        "title": "Smart Detection",
        "description": "Use UniFi Protect smart detection for HomeKit motion events when on a supported device.",
        "x-kinds": [
          "camera",
          "light",
          "sensor"
        ],
        "x-default": "motionSmartDetect"
      },
      "motionSmartDetectObjectSensors": {
        "type": "boolean",
        "title": "Object Sensors",
        "description": "Add contact sensors for each smart detection object type that UniFi Protect supports.",
        "x-kinds": [
          "camera",
          "light",
          "sensor"
        ],
        "x-default": "motionSmartDetectObjectSensors"
      },
      "motionSmartDetectObjectSensorsLicensePlate": {
        "type": "string",
        "title": "License Plates to Match",
        "description": "Add a contact sensor accessory that will match a specific license plate detected by UniFi Protect. You may specify multiple license plates by using hyphens to distinguish unique license plates (e.g. PLATE1-PLATE2-PLATE3).",
        "x-kinds": [
          "camera",
          "light",
          "sensor"
        ],
        "x-default": "motionSmartDetectObjectSensorsLicensePlate"
      },
      "motionTrigger": {
        "type": "boolean",
        "title": "Motion Trigger Switch",
        "description": "Add a switch accessory to manually trigger a motion detection event in HomeKit.",
        "x-kinds": [
          "camera",
          "light",
          "sensor"
        ],
        "x-default": "motionTrigger"
      },
      "nvrServicePlaylist": {
        "type": "number",
        "title": "M3U Playlist Port",
        "placeholder": 10110,
        "description": "Publish an M3U playlist of the Protect cameras on this port of the bridge, for apps such as Channels DVR that play livestreams.",
        "x-kinds": [
          "nvr"
        ],
        "x-default": "nvrServicePlaylist"
      },
      "nvrDelayDeviceRemoval": {
        "type": "number",
        "title": "Device Removal Delay (seconds)",
        "placeholder": 60,
        "description": "Delay, in seconds, before removing devices that are no longer detected on the Protect controller. If disabled, devices are removed in realtime when the Protect controller does so.",
        "x-kinds": [
          "nvr"
        ],
        "x-default": "nvrDelayDeviceRemoval"
      },
      "nvrPublishTelemetry": {
        "type": "boolean",
        "title": "Publish Telemetry",
        "description": "Publish all the realtime telemetry received from the Protect controller to MQTT.",
        "x-kinds": [
          "nvr"
        ],
        "x-default": "nvrPublishTelemetry"
      },
      "nvrRecordingSwitch": {
        "type": "boolean",
        "title": "Recording Switches",
        "description": "Add switch accessories to control the native recording capabilities of the UniFi Protect NVR.",
        "x-kinds": [
          "camera",
          "thirdPartyCamera"
        ],
        "x-default": "nvrRecordingSwitch"
      },
      "nvrSystemInfo": {
        "type": "boolean",
        "title": "System Info Sensors",
        "description": "Add sensor accessories to display the Protect controller system information (currently only the temperature).",
        "x-kinds": [
          "nvr"
        ],
        "x-default": "nvrSystemInfo"
      },
      "securitySystemAlarm": {
        "type": "boolean",
        "title": "Alarm Switch",
        "description": "Add a switch accessory to trigger the security system accessory, when using the liveview feature option.",
        "x-kinds": [
          "nvr"
        ],
        "x-default": "securitySystemAlarm"
      },
      "sensorMoistureSensor": {
        "type": "boolean",
        "title": "Leak Sensor as Contact Sensor",
        "description": "Expose the Protect leak sensor as a contact sensor instead of a leak sensor. This is useful for automation scenarios since HomeKit contact sensors offer more flexible automation options than leak sensors, which are primarily designed for alerts.",
        "x-kinds": [
          "sensor"
        ],
        "x-default": "sensorMoistureSensor"
      },
      "uniFiAccessLock": {
        "type": "boolean",
        "title": "UniFi Access Lock",
        "description": "Add a lock accessory to unlock. Currently, Protect only supports unlocking Access readers with a camera on the same controller as Protect.",
        "x-kinds": [
          "camera",
          "thirdPartyCamera"
        ],
        "x-default": "uniFiAccessLock"
      },
      "videoTranscodeHardware": {
        "type": "boolean",
        "title": "Hardware Transcoding",
        "description": "Use hardware-accelerated transcoding when available (Apple Macs, Intel Quick Sync Video-enabled CPUs, Raspberry Pi 4).",
        "x-kinds": [
          "camera",
          "thirdPartyCamera"
        ],
        "x-default": "videoTranscodeHardware"
      },
      "videoStreamUseApi": {
        "type": "boolean",
        "title": "Protect Livestream API",
        "description": "Use the native Protect livestream API to view livestreams.",
        "x-kinds": [
          "camera"
        ],
        "x-default": "videoStreamUseApi"
      },
      "videoTranscode": {
        "type": "boolean",
        "title": "Transcode at Home",
        "description": "When streaming to low-latency clients (e.g. at home), transcode livestreams, instead of transmuxing them.",
        "x-kinds": [
          "camera",
          "thirdPartyCamera"
        ],
        "x-default": "videoTranscode"
      },
      "videoTranscodeBitrate": {
        "type": "number",
        "title": "Bitrate at Home (kbps)",
        "placeholder": 2000,
        "description": "Bitrate, in kilobits per second, to use when transcoding to low-latency (e.g. at home) clients, ignoring the bitrate HomeKit requests. HomeKit typically requests lower video quality than you may desire in your environment.",
        "x-kinds": [
          "camera",
          "thirdPartyCamera"
        ],
        "x-default": "videoTranscodeBitrate"
      },
      "videoTranscodeHighLatency": {
        "type": "boolean",
        "title": "Transcode Away",
        "description": "When streaming to high-latency clients (e.g. cellular connections), transcode livestreams instead of transmuxing them.",
        "x-kinds": [
          "camera",
          "thirdPartyCamera"
        ],
        "x-default": "videoTranscodeHighLatency"
      },
      "videoTranscodeHighLatencyBitrate": {
        "type": "number",
        "title": "Bitrate Away (kbps)",
        "placeholder": 1000,
        "description": "Bitrate, in kilobits per second, to use when transcoding to high-latency (e.g. cellular) clients, ignoring the bitrate HomeKit requests. HomeKit typically requests lower video quality than you may desire in your environment.",
        "x-kinds": [
          "camera",
          "thirdPartyCamera"
        ],
        "x-default": "videoTranscodeHighLatencyBitrate"
      },
      "videoStreamOnlyHigh": {
        "type": "boolean",
        "title": "High Quality Only",
        "description": "When viewing livestreams, force the use of the high quality video stream from the Protect controller.",
        "x-kinds": [
          "camera",
          "thirdPartyCamera"
        ],
        "x-default": "videoStreamOnlyHigh"
      },
      "videoStreamOnlyMedium": {
        "type": "boolean",
        "title": "Medium Quality Only",
        "description": "When viewing livestreams, force the use of the medium quality video stream from the Protect controller.",
        "x-kinds": [
          "camera",
          "thirdPartyCamera"
        ],
        "x-default": "videoStreamOnlyMedium"
      },
      "videoStreamOnlyLow": {
        "type": "boolean",
        "title": "Low Quality Only",
        "description": "When viewing livestreams, force the use of the low quality video stream from the Protect controller.",
        "x-kinds": [
          "camera",
          "thirdPartyCamera"
        ],
        "x-default": "videoStreamOnlyLow"
      },
      "videoCrop": {
        "type": "boolean",
        "title": "Crop",
        "description": "Crop the camera video stream. Enabling this option will also force transcoding of livestreams.",
        "x-kinds": [
          "camera",
          "thirdPartyCamera"
        ],
        "x-default": "videoCrop"
      },
      "videoCropX": {
        "type": "number",
        "title": "Left (%)",
        "placeholder": 0,
        "description": "Left offset of the crop window, as a percentage of the original image width.",
        "x-kinds": [
          "camera",
          "thirdPartyCamera"
        ],
        "x-default": "videoCropX"
      },
      "videoCropY": {
        "type": "number",
        "title": "Top (%)",
        "placeholder": 0,
        "description": "Top offset of the crop window, as a percentage of the original image height.",
        "x-kinds": [
          "camera",
          "thirdPartyCamera"
        ],
        "x-default": "videoCropY"
      },
      "videoCropWidth": {
        "type": "number",
        "title": "Width (%)",
        "placeholder": 100,
        "description": "Width of the crop window, as a percentage of original image width.",
        "x-kinds": [
          "camera",
          "thirdPartyCamera"
        ],
        "x-default": "videoCropWidth"
      },
      "videoCropHeight": {
        "type": "number",
        "title": "Height (%)",
        "placeholder": 100,
        "description": "Height of the crop window, as a percentage of original image height.",
        "x-kinds": [
          "camera",
          "thirdPartyCamera"
        ],
        "x-default": "videoCropHeight"
      },
      "videoHighResSnapshots": {
        "type": "boolean",
        "title": "High-Resolution Snapshots",
        "description": "Enable higher quality snapshots.",
        "x-kinds": [
          "camera",
          "thirdPartyCamera"
        ],
        "x-default": "videoHighResSnapshots"
      },
      "videoHKSVStatusLedIndicator": {
        "type": "boolean",
        "title": "Status Light While Recording",
        "description": "Use the camera status indicator light to show when an HKSV event is being recorded.",
        "x-kinds": [
          "camera"
        ],
        "x-default": "videoHKSVStatusLedIndicator"
      },
      "videoHKSVRecordOnlyHigh": {
        "type": "boolean",
        "title": "Record High Quality Only",
        "description": "When recording HomeKit Secure Video events, force the use of the high quality video stream from the Protect controller.",
        "x-kinds": [
          "camera"
        ],
        "x-default": "videoHKSVRecordOnlyHigh"
      },
      "videoHKSVRecordOnlyMedium": {
        "type": "boolean",
        "title": "Record Medium Quality Only",
        "description": "When recording HomeKit Secure Video events, force the use of the medium quality video stream from the Protect controller.",
        "x-kinds": [
          "camera"
        ],
        "x-default": "videoHKSVRecordOnlyMedium"
      },
      "videoHKSVRecordOnlyLow": {
        "type": "boolean",
        "title": "Record Low Quality Only",
        "description": "When recording HomeKit Secure Video events, force the use of the low quality video stream from the Protect controller.",
        "x-kinds": [
          "camera"
        ],
        "x-default": "videoHKSVRecordOnlyLow"
      }
    }
  },
  "layout": [
    "name",
    {
      "type": "section",
      "title": "UniFi Protect Controllers",
      "expandable": true,
      "expanded": false,
      "items": [
        {
          "key": "controllers",
          "type": "array",
          "name": " ",
          "orderable": false,
          "buttonText": "Add UniFi Protect Controller",
          "items": [
            "controllers[].address",
            "controllers[].name",
            "controllers[].overrideAddress",
            "controllers[].verifyTls",
            "controllers[].mqttUrl",
            "controllers[].mqttTopic",
            "controllers[].mqttVerifyTls",
            "controllers[].playlistAddress",
            {
              "key": "controllers[].doorbellMessages",
              "type": "array",
              "name": " ",
              "orderable": false,
              "buttonText": "Add Doorbell Message",
              "items": [
                "controllers[].doorbellMessages[].message",
                "controllers[].doorbellMessages[].duration"
              ]
            }
          ]
        }
      ]
    },
    {
      "type": "fieldset",
      "title": "Audio",
      "expandable": true,
      "expanded": false,
      "items": [
        "audio",
        "audioFilterNoise",
        "audioFilterNoiseFftNr",
        "audioFilterNoiseHighPass",
        "audioFilterNoiseLowPass",
        "audioTwoWay",
        "audioTwoWayDirect"
      ]
    },
    {
      "type": "fieldset",
      "title": "Device",
      "expandable": true,
      "expanded": false,
      "items": [
        "deviceStatusLed",
        "deviceStatusLedSwitch",
        "deviceNightVision",
        "deviceNightVisionDimmer",
        "deviceStandalone",
        "deviceSelfHealing",
        "deviceSyncName",
        "sensorMoistureSensor"
      ]
    },
    {
      "type": "fieldset",
      "title": "Doorbell",
      "expandable": true,
      "expanded": false,
      "items": [
        "doorbellAuthSensor",
        "doorbellMute",
        "doorbellMessagesEnabled",
        "doorbellMessagesFromDoorbell",
        "doorbellVolumeDimmer",
        "doorbellPhysicalChime",
        "doorbellPhysicalChimeDurationDigital",
        "doorbellPackageCameraFlashlight",
        "doorbellTrigger",
        "uniFiAccessLock"
      ]
    },
    {
      "type": "fieldset",
      "title": "Logging",
      "expandable": true,
      "expanded": false,
      "items": [
        "logDoorbell",
        "logHKSV",
        "logMotion"
      ]
    },
    {
      "type": "fieldset",
      "title": "Motion",
      "expandable": true,
      "expanded": false,
      "items": [
        "motionDuration",
        "motionOccupancySensor",
        "motionOccupancySensorDuration",
        "motionSmartDetect",
        "motionSmartDetectObjectSensors",
        "motionSmartDetectObjectSensorsLicensePlate",
        "motionSwitch",
        "motionTrigger",
        {
          "type": "fieldset",
          "title": "Occupancy Triggers",
          "description": "With Occupancy Sensor and Smart Detection both on, what Protect detects that counts as someone there.",
          "items": [
            "motionOccupancySensorAnimal",
            "motionOccupancySensorFace",
            "motionOccupancySensorLicensePlate",
            "motionOccupancySensorPackage",
            "motionOccupancySensorPerson",
            "motionOccupancySensorVehicle",
            "motionOccupancySensorAlrmBabyCry",
            "motionOccupancySensorAlrmBark",
            "motionOccupancySensorAlrmBurglar",
            "motionOccupancySensorAlrmCarHorn",
            "motionOccupancySensorAlrmCmonx",
            "motionOccupancySensorAlrmGlassBreak",
            "motionOccupancySensorAlrmSiren",
            "motionOccupancySensorAlrmSmoke",
            "motionOccupancySensorAlrmSpeak",
            "motionOccupancySensorSmokeCmonx"
          ]
        }
      ]
    },
    {
      "type": "fieldset",
      "title": "NVR",
      "expandable": true,
      "expanded": false,
      "items": [
        "nvrServicePlaylist",
        "nvrDelayDeviceRemoval",
        "nvrPublishTelemetry",
        "nvrRecordingSwitch",
        "nvrSystemInfo",
        "securitySystemAlarm"
      ]
    },
    {
      "type": "fieldset",
      "title": "Video",
      "expandable": true,
      "expanded": false,
      "items": [
        "videoHighResSnapshots",
        {
          "type": "fieldset",
          "title": "Transcoding",
          "items": [
            "videoTranscodeHardware",
            "videoTranscode",
            "videoTranscodeBitrate",
            "videoTranscodeHighLatency",
            "videoTranscodeHighLatencyBitrate"
          ]
        },
        {
          "type": "fieldset",
          "title": "Livestream",
          "items": [
            "videoStreamUseApi",
            "videoStreamOnlyHigh",
            "videoStreamOnlyMedium",
            "videoStreamOnlyLow"
          ]
        },
        {
          "type": "fieldset",
          "title": "Crop",
          "items": [
            "videoCrop",
            "videoCropX",
            "videoCropY",
            "videoCropWidth",
            "videoCropHeight"
          ]
        }
      ]
    },
    {
      "type": "fieldset",
      "title": "HomeKit Secure Video",
      "expandable": true,
      "expanded": false,
      "items": [
        "videoHKSVStatusLedIndicator",
        "videoHKSVRecordingSwitch",
        "videoHKSVRecordOnlyHigh",
        "videoHKSVRecordOnlyMedium",
        "videoHKSVRecordOnlyLow"
      ]
    },
    {
      "type": "section",
      "title": "Feature Options",
      "expandable": true,
      "expanded": false,
      "items": [
        {
          "key": "options",
          "type": "array",
          "name": " ",
          "orderable": true,
          "buttonText": "Add Feature Option",
          "items": [
            "options[]"
          ]
        }
      ]
    },
    {
      "type": "section",
      "title": "Advanced",
      "expandable": true,
      "expanded": false,
      "items": [
        "videoProcessor",
        "verboseFfmpeg",
        "ringDelay",
        "debug"
      ]
    }
  ],
  "i18n": {
    "fr": {
      "e.g. I'll be there soon.": "Par ex. J'arrive tout de suite.",
      "Controller Address": "Adresse du contrôleur",
      "Controller Name": "Nom du contrôleur",
      "Debug Logging": "Journal de débogage",
      "Delay between doorbell rings. Setting this to a non-zero value will prevent multiple rings of a doorbell over the specified duration. Default: 0.": "Délai entre les sonneries d'une sonnette. Une valeur non nulle ignore les sonneries répétées d'une sonnette pendant cette durée. Par défaut : 0.",
      "Direct RTSP / RTSPS URL": "URL RTSP / RTSPS directe",
      "Direct Snapshot URL": "URL de capture directe",
      "Doorbell Message": "Message de sonnette",
      "Doorbell Messages": "Messages de la sonnette",
      "Doorbell Ring Delay (seconds)": "Délai entre sonneries (secondes)",
      "Enable additional logging for FFmpeg. This will create additional logging when video streams are running. Default: false.": "Active un journal plus détaillé pour FFmpeg, qui écrit davantage pendant la diffusion des flux vidéo. Par défaut : désactivé.",
      "Enable debug logging for this plugin. This creates a large volume of log output and should only be used when troubleshooting. Default: false.": "Active le journal de débogage de ce plugin. Il produit un grand volume de messages et ne doit servir qu'au dépannage. Par défaut : désactivé.",
      "Extra message presets for this controller's doorbells with a screen. While doorbell messages are enabled, each preset appears as a switch that shows it.": "Messages prédéfinis supplémentaires pour les sonnettes à écran de ce contrôleur. Quand les messages de sonnette sont activés, chaque message apparaît comme un interrupteur qui l'affiche.",
      "FFmpeg Location": "Emplacement de FFmpeg",
      "Feature Options": "Options de fonctionnalités",
      "Full HTTP or HTTPS URL pointing at the camera's snapshot endpoint. Credentials may be embedded. Self-signed certificates are accepted.": "URL HTTP ou HTTPS complète du point d'accès de capture de la caméra. Elle peut contenir des identifiants. Les certificats autosignés sont acceptés.",
      "Full RTSP or RTSPS URL pointing directly at the camera's own RTSP server, bypassing the Protect controller. Credentials may be embedded.": "URL RTSP ou RTSPS complète qui pointe directement vers le serveur RTSP de la caméra, sans passer par le contrôleur Protect. Elle peut contenir des identifiants.",
      "Hostname or IP address of your UniFi Protect controller.": "Nom d'hôte ou adresse IP de votre contrôleur UniFi Protect.",
      "Length of time to display the message on your doorbell. Use 0 to display the message indefinitely. Default: 60.": "Durée d'affichage du message sur votre sonnette. 0 l'affiche indéfiniment. Par défaut : 60.",
      "M3U Playlist Bind Address": "Adresse d'écoute de la liste de lecture M3U",
      "MQTT Base Topic": "Sujet MQTT de base",
      "MQTT Broker URL": "URL du broker MQTT",
      "Message Duration (seconds)": "Durée du message (secondes)",
      "Message Name": "Nom du message",
      "Message to display on your doorbell. Default: None.": "Message à afficher sur votre sonnette. Par défaut : aucun.",
      "Name for this UniFi Protect controller to be used for logging purposes. Default: Defined by the controller.": "Nom de ce contrôleur UniFi Protect utilisé dans le journal. Par défaut : celui que donne le contrôleur.",
      "Name to use for logging purposes. Default: UniFi Protect.": "Nom utilisé dans le journal. Par défaut : UniFi Protect.",
      "ONVIF Port": "Port ONVIF",
      "ONVIF Service Path": "Chemin du service ONVIF",
      "ONVIF Username": "Nom d'utilisateur ONVIF",
      "ONVIF service port remembered for the discovery panel. Leave empty to let the panel try common defaults.": "Port du service ONVIF mémorisé pour le panneau de découverte. Laissez vide pour que le panneau essaie les valeurs courantes.",
      "Optional ONVIF device service path remembered for the discovery panel. Defaults to /onvif/device_service when blank.": "Chemin facultatif du service de l'appareil ONVIF, mémorisé pour le panneau de découverte. Vide, c'est /onvif/device_service.",
      "Override Controller Address": "Adresse de remplacement du contrôleur",
      "Path to the FFmpeg executable. Most users should not use this setting. Default: the first ffmpeg found in PATH.": "Chemin de l'exécutable FFmpeg. La plupart des utilisateurs n'ont pas besoin de ce réglage. Par défaut : le premier ffmpeg trouvé dans le PATH.",
      "Plugin Name": "Nom du plugin",
      "UniFi Protect Controller": "Contrôleur UniFi Protect",
      "UniFi Protect Controllers": "Contrôleurs UniFi Protect",
      "Username remembered for the ONVIF discovery panel. Stored in plaintext alongside the controller credentials.": "Nom d'utilisateur mémorisé pour le panneau de découverte ONVIF. Enregistré en clair avec les identifiants du contrôleur.",
      "Verbose FFmpeg Logging": "Journal FFmpeg détaillé",
      "Verify MQTT Broker TLS Certificate": "Vérifier le certificat TLS du broker MQTT",
      "Verify TLS Certificate": "Vérifier le certificat TLS",
      "Audio": "Audio",
      "Audio support.": "Prise en charge de l'audio.",
      "Audio filter for ambient noise suppression.": "Filtre audio de suppression du bruit ambiant.",
      "Noise reduction amount, in decibels, for the FFmpeg afftdn filter.": "Niveau de réduction du bruit, en décibels, pour le filtre afftdn de FFmpeg.",
      "Frequency, in Hertz, for the FFmpeg highpass filter.": "Fréquence, en hertz, pour le filtre highpass de FFmpeg.",
      "Frequency, in Hertz, for the FFmpeg lowpass filter.": "Fréquence, en hertz, pour le filtre lowpass de FFmpeg.",
      "Two-way audio support on supported cameras.": "Audio bidirectionnel sur les caméras compatibles.",
      "Send two-way audio directly to supported cameras, bypassing the controller. Useful for working around bugs in some Protect controller firmware versions.": "Envoyer l'audio bidirectionnel directement aux caméras compatibles, sans passer par le contrôleur. Utile pour contourner des bugs de certaines versions du firmware des contrôleurs Protect.",
      "Enable the status indicator light for this device in HomeKit.": "Activer le voyant d'état de cet appareil dans HomeKit.",
      "Add a switch accessory to control the status indicator light in HomeKit.": "Ajouter un accessoire interrupteur pour contrôler le voyant d'état dans HomeKit.",
      "Enable the night vision indicator light for this device in HomeKit.": "Activer le voyant de vision nocturne de cet appareil dans HomeKit.",
      "Add a dimmer accessory to control the night vision state in HomeKit.": "Ajouter un accessoire variateur pour contrôler la vision nocturne dans HomeKit.",
      "Make this a standalone device in HomeKit that will need to be added to HomeKit through the Home app.": "Faire de cet appareil un accessoire autonome dans HomeKit, à ajouter séparément depuis l'app Maison.",
      "Attempt to restart misbehaving devices. This is always done very conservatively and only after periods of extended device-specific issues.": "Tenter de redémarrer les appareils qui fonctionnent mal. Cela se fait toujours avec une grande prudence, et seulement après des problèmes prolongés propres à l'appareil.",
      "Synchronize the UniFi Protect name of this device with HomeKit. Synchronization is one-way only, syncing the device name from UniFi Protect to HomeKit.": "Synchroniser le nom UniFi Protect de cet appareil avec HomeKit. La synchronisation est à sens unique : le nom va d'UniFi Protect vers HomeKit.",
      "Add a contact sensor that gets activates when a fingerprint or NFC successfully authenticates on a Protect doorbell.": "Ajouter un capteur de contact qui s'active quand une empreinte digitale ou un badge NFC est authentifié sur une sonnette Protect.",
      "Add a switch accessory to control whether HomeKit will chime when the doorbell is pressed.": "Ajouter un accessoire interrupteur pour choisir si HomeKit sonne quand on appuie sur la sonnette.",
      "Enable the doorbell messages feature.": "Activer la fonction des messages de la sonnette.",
      "Use messages saved to the Protect NVR as message switches.": "Utiliser les messages enregistrés sur le NVR Protect comme interrupteurs de message.",
      "Add a dimmer accessory to control the Protect chime volume in HomeKit.": "Ajouter un accessoire variateur pour contrôler le volume du carillon Protect dans HomeKit.",
      "Add switch accessories to control the physical chimes attached to a Protect doorbell.": "Ajouter des accessoires interrupteurs pour contrôler les carillons physiques reliés à une sonnette Protect.",
      "Chime duration, in milliseconds, of a digital physical chime attached to a Protect doorbell.": "Durée de la sonnerie, en millisecondes, d'un carillon physique numérique relié à une sonnette Protect.",
      "Add a light accessory to control the flashlight on a Protect doorbell package camera.": "Ajouter un accessoire lampe pour contrôler la lampe de la caméra à colis d'une sonnette Protect.",
      "Add a switch accessory to trigger doorbell ring events on a Protect camera or doorbell.": "Ajouter un accessoire interrupteur pour déclencher des événements de sonnerie sur une caméra ou une sonnette Protect.",
      "Duration, in seconds, of a single motion event, before allowing a new one.": "Durée, en secondes, d'un événement de mouvement avant d'en autoriser un nouveau.",
      "Add an occupancy sensor accessory using motion sensor activity to determine occupancy. By default, any motion will trigger occupancy. If the smart detection feature option is enabled, it will be used instead.": "Ajouter un accessoire capteur de présence qui déduit la présence de l'activité du détecteur de mouvement. Par défaut, tout mouvement déclenche la présence. Si l'option détection intelligente est activée, elle est utilisée à la place.",
      "Duration, in seconds, to wait without receiving a motion event to determine when occupancy is no longer detected.": "Durée, en secondes, à attendre sans événement de mouvement avant de considérer que la présence n'est plus détectée.",
      "Use UniFi Protect smart detection for HomeKit motion events when on a supported device.": "Utiliser la détection intelligente de UniFi Protect pour les événements de mouvement HomeKit sur un appareil compatible.",
      "Add contact sensors for each smart detection object type that UniFi Protect supports.": "Ajouter des capteurs de contact pour chaque type d'objet de la détection intelligente que UniFi Protect prend en charge.",
      "Add a contact sensor accessory that will match a specific license plate detected by UniFi Protect. You may specify multiple license plates by using hyphens to distinguish unique license plates (e.g. PLATE1-PLATE2-PLATE3).": "Ajouter un accessoire capteur de contact qui correspond à une plaque d'immatriculation précise détectée par UniFi Protect. Vous pouvez indiquer plusieurs plaques en les séparant par des tirets (p. ex. PLAQUE1-PLAQUE2-PLAQUE3).",
      "Add a switch accessory to activate or deactivate motion detection in HomeKit.": "Ajouter un accessoire interrupteur pour activer ou désactiver la détection de mouvement dans HomeKit.",
      "Add a switch accessory to manually trigger a motion detection event in HomeKit.": "Ajouter un accessoire interrupteur pour déclencher manuellement un événement de détection de mouvement dans HomeKit.",
      "Nvr.Service.Playlist": "Nvr.Service.Playlist",
      "Delay, in seconds, before removing devices that are no longer detected on the Protect controller. If disabled, devices are removed in realtime when the Protect controller does so.": "Délai, en secondes, avant de supprimer les appareils qui ne sont plus détectés sur le contrôleur Protect. Si l'option est désactivée, les appareils sont supprimés en temps réel, en même temps que sur le contrôleur Protect.",
      "Publish all the realtime telemetry received from the Protect controller to MQTT.": "Publier sur MQTT toute la télémétrie en temps réel reçue du contrôleur Protect.",
      "Add switch accessories to control the native recording capabilities of the UniFi Protect NVR.": "Ajouter des accessoires interrupteurs pour contrôler l'enregistrement natif du NVR UniFi Protect.",
      "Add sensor accessories to display the Protect controller system information (currently only the temperature).": "Ajouter des accessoires capteurs pour afficher les informations système du contrôleur Protect (pour l'instant, seulement la température).",
      "Add a switch accessory to trigger the security system accessory, when using the liveview feature option.": "Ajouter un accessoire interrupteur pour déclencher l'accessoire système de sécurité, avec l'option liveview.",
      "Expose the Protect leak sensor as a contact sensor instead of a leak sensor. This is useful for automation scenarios since HomeKit contact sensors offer more flexible automation options than leak sensors, which are primarily designed for alerts.": "Présenter le capteur de fuite Protect comme un capteur de contact plutôt qu'un capteur de fuite. Utile pour les automatisations, car les capteurs de contact HomeKit offrent plus d'options d'automatisation que les capteurs de fuite, conçus surtout pour les alertes.",
      "Add a lock accessory to unlock. Currently, Protect only supports unlocking Access readers with a camera on the same controller as Protect.": "Ajouter un accessoire serrure pour déverrouiller. Pour l'instant, Protect ne permet de déverrouiller que les lecteurs Access dotés d'une caméra, sur le même contrôleur que Protect.",
      "Use hardware-accelerated transcoding when available (Apple Macs, Intel Quick Sync Video-enabled CPUs, Raspberry Pi 4).": "Utiliser le transcodage accéléré par le matériel quand il est disponible (Mac Apple, processeurs Intel avec Quick Sync Video, Raspberry Pi 4).",
      "Use the native Protect livestream API to view livestreams.": "Utiliser l'API de diffusion en direct native de Protect pour afficher les flux en direct.",
      "When streaming to low-latency clients (e.g. at home), transcode livestreams, instead of transmuxing them.": "Pour les clients à faible latence (p. ex. à la maison), transcoder les flux en direct au lieu de les remultiplexer.",
      "Bitrate, in kilobits per second, to use when transcoding to low-latency (e.g. at home) clients, ignoring the bitrate HomeKit requests. HomeKit typically requests lower video quality than you may desire in your environment.": "Débit, en kilobits par seconde, pour le transcodage vers les clients à faible latence (p. ex. à la maison), sans tenir compte du débit demandé par HomeKit. HomeKit demande généralement une qualité vidéo inférieure à celle que vous pourriez souhaiter.",
      "When streaming to high-latency clients (e.g. cellular connections), transcode livestreams instead of transmuxing them.": "Pour les clients à latence élevée (p. ex. connexions cellulaires), transcoder les flux en direct au lieu de les remultiplexer.",
      "Bitrate, in kilobits per second, to use when transcoding to high-latency (e.g. cellular) clients, ignoring the bitrate HomeKit requests. HomeKit typically requests lower video quality than you may desire in your environment.": "Débit, en kilobits par seconde, pour le transcodage vers les clients à latence élevée (p. ex. cellulaires), sans tenir compte du débit demandé par HomeKit. HomeKit demande généralement une qualité vidéo inférieure à celle que vous pourriez souhaiter.",
      "When viewing livestreams, force the use of the high quality video stream from the Protect controller.": "Pour les flux en direct, forcer le flux vidéo de haute qualité du contrôleur Protect.",
      "When viewing livestreams, force the use of the medium quality video stream from the Protect controller.": "Pour les flux en direct, forcer le flux vidéo de moyenne qualité du contrôleur Protect.",
      "When viewing livestreams, force the use of the low quality video stream from the Protect controller.": "Pour les flux en direct, forcer le flux vidéo de basse qualité du contrôleur Protect.",
      "Crop the camera video stream. Enabling this option will also force transcoding of livestreams.": "Recadrer le flux vidéo de la caméra. Activer cette option force aussi le transcodage des flux en direct.",
      "Left offset of the crop window, as a percentage of the original image width.": "Décalage gauche de la zone de recadrage, en pourcentage de la largeur de l'image d'origine.",
      "Top offset of the crop window, as a percentage of the original image height.": "Décalage haut de la zone de recadrage, en pourcentage de la hauteur de l'image d'origine.",
      "Width of the crop window, as a percentage of original image width.": "Largeur de la zone de recadrage, en pourcentage de la largeur de l'image d'origine.",
      "Height of the crop window, as a percentage of original image height.": "Hauteur de la zone de recadrage, en pourcentage de la hauteur de l'image d'origine.",
      "Enable higher quality snapshots.": "Activer des instantanés de meilleure qualité.",
      "Use the camera status indicator light to show when an HKSV event is being recorded.": "Utiliser le voyant d'état de la caméra pour signaler l'enregistrement d'un événement HKSV.",
      "Add a switch accessory to enable or disable HKSV event recording.": "Ajouter un accessoire interrupteur pour activer ou désactiver l'enregistrement des événements HKSV.",
      "When recording HomeKit Secure Video events, force the use of the high quality video stream from the Protect controller.": "Pour l'enregistrement des événements HomeKit Secure Video, forcer le flux vidéo de haute qualité du contrôleur Protect.",
      "When recording HomeKit Secure Video events, force the use of the medium quality video stream from the Protect controller.": "Pour l'enregistrement des événements HomeKit Secure Video, forcer le flux vidéo de moyenne qualité du contrôleur Protect.",
      "When recording HomeKit Secure Video events, force the use of the low quality video stream from the Protect controller.": "Pour l'enregistrement des événements HomeKit Secure Video, forcer le flux vidéo de basse qualité du contrôleur Protect.",
      "Device": "Appareil",
      "Doorbell": "Sonnette",
      "Logging": "Journalisation",
      "Motion": "Mouvement",
      "NVR": "NVR",
      "Sensor": "Capteur",
      "UniFi Access": "UniFi Access",
      "Video": "Vidéo",
      "HomeKit Secure Video": "HomeKit Secure Video",
      "UniFi consoles by address, for those discovery does not find; each is signed in to in Add accessories, and its login kept in the vault.": "Des consoles UniFi par adresse, pour celles que la découverte ne trouve pas ; on se connecte à chacune dans Ajouter des accessoires, et son identifiant est gardé dans le coffre.",
      "Feature options of a Homebridge block that no setting says (Enable.<option> or Disable.<option>, optionally followed by a device's MAC), one per entry. The bridge moves the others into the settings.": "Les options de fonctionnalité d'un bloc Homebridge qu'aucun réglage n'exprime (Enable.<option> ou Disable.<option>, suivies au besoin du MAC d'un appareil), une par entrée. Le pont déplace les autres dans les réglages.",
      "One option per entry, as the Homebridge plugin's README spells them.": "Une option par entrée, écrite comme dans le README du plugin Homebridge.",
      "Noise Filter": "Filtre anti-bruit",
      "Noise Reduction (dB)": "Réduction du bruit (dB)",
      "High-Pass Filter (Hz)": "Filtre passe-haut (Hz)",
      "Low-Pass Filter (Hz)": "Filtre passe-bas (Hz)",
      "Two-Way Audio": "Audio bidirectionnel",
      "Two-Way Audio Straight to the Camera": "Audio bidirectionnel direct vers la caméra",
      "Status Light": "Voyant d'état",
      "Status Light Switch": "Interrupteur du voyant d'état",
      "Night Vision": "Vision nocturne",
      "Night Vision Dimmer": "Variateur de vision nocturne",
      "Standalone Accessory": "Accessoire indépendant",
      "Restart When Misbehaving": "Redémarrer en cas de dysfonctionnement",
      "Sync Names": "Synchroniser les noms",
      "Fingerprint and NFC Sensor": "Capteur d'empreinte et NFC",
      "Mute Switch": "Interrupteur de sourdine",
      "Messages Saved on the NVR": "Messages enregistrés sur le NVR",
      "Chime Volume Dimmer": "Variateur du volume du carillon",
      "Physical Chime Switches": "Interrupteurs du carillon physique",
      "Digital Chime Duration (ms)": "Durée du carillon numérique (ms)",
      "Package Camera Flashlight": "Lampe de la caméra à colis",
      "Doorbell Trigger Switch": "Interrupteur de déclenchement de la sonnette",
      "Log Doorbell Rings": "Consigner les sonneries",
      "Write doorbell rings to the log.": "Écrire les sonneries dans le journal.",
      "Log HomeKit Secure Video": "Consigner HomeKit Secure Video",
      "Write HomeKit Secure Video recording events to the log.": "Écrire les événements d'enregistrement HomeKit Secure Video dans le journal.",
      "Log Motion": "Consigner les mouvements",
      "Write motion events to the log.": "Écrire les événements de mouvement dans le journal.",
      "Motion Event Length (seconds)": "Durée d'un mouvement (secondes)",
      "Occupancy Sensor": "Capteur de présence",
      "Occupancy Timeout (seconds)": "Délai de présence (secondes)",
      "Animal": "Animal",
      "Face": "Visage",
      "License Plate": "Plaque d'immatriculation",
      "Package": "Colis",
      "Person": "Personne",
      "Vehicle": "Véhicule",
      "Baby Crying": "Pleurs de bébé",
      "Barking": "Aboiements",
      "Burglar Alarm": "Alarme antivol",
      "Car Horn": "Klaxon",
      "CO Alarm": "Alarme CO",
      "Glass Break": "Bris de vitre",
      "Siren": "Sirène",
      "Smoke Alarm": "Alarme incendie",
      "Speaking": "Parole",
      "Smoke and CO Alarm": "Alarme fumée et CO",
      "Smart Detection": "Détection intelligente",
      "Object Sensors": "Capteurs d'objets",
      "License Plates to Match": "Plaques à reconnaître",
      "Motion Detection Switch": "Interrupteur de détection de mouvement",
      "Motion Trigger Switch": "Interrupteur de déclenchement de mouvement",
      "M3U Playlist Port": "Port de la liste M3U",
      "Publish an M3U playlist of the Protect cameras on this port of the bridge, for apps such as Channels DVR that play livestreams.": "Publier une liste M3U des caméras Protect sur ce port du pont, pour des apps comme Channels DVR qui lisent les directs.",
      "Device Removal Delay (seconds)": "Délai de retrait des appareils (secondes)",
      "Publish Telemetry": "Publier la télémétrie",
      "Recording Switches": "Interrupteurs d'enregistrement",
      "System Info Sensors": "Capteurs d'informations système",
      "Alarm Switch": "Interrupteur d'alarme",
      "Leak Sensor as Contact Sensor": "Capteur de fuite en capteur de contact",
      "UniFi Access Lock": "Serrure UniFi Access",
      "Hardware Transcoding": "Transcodage matériel",
      "Protect Livestream API": "API de direct Protect",
      "Transcode at Home": "Transcoder à la maison",
      "Bitrate at Home (kbps)": "Débit à la maison (kbit/s)",
      "Transcode Away": "Transcoder à distance",
      "Bitrate Away (kbps)": "Débit à distance (kbit/s)",
      "High Quality Only": "Haute qualité uniquement",
      "Medium Quality Only": "Qualité moyenne uniquement",
      "Low Quality Only": "Basse qualité uniquement",
      "Crop": "Recadrer",
      "Left (%)": "Gauche (%)",
      "Top (%)": "Haut (%)",
      "Width (%)": "Largeur (%)",
      "Height (%)": "Hauteur (%)",
      "High-Resolution Snapshots": "Instantanés haute résolution",
      "Status Light While Recording": "Voyant d'état pendant l'enregistrement",
      "Recording Switch": "Interrupteur d'enregistrement",
      "Record High Quality Only": "Enregistrer en haute qualité uniquement",
      "Record Medium Quality Only": "Enregistrer en qualité moyenne uniquement",
      "Record Low Quality Only": "Enregistrer en basse qualité uniquement",
      "Occupancy Triggers": "Déclencheurs de présence",
      "With Occupancy Sensor and Smart Detection both on, what Protect detects that counts as someone there.": "Avec Capteur de présence et Détection intelligente activés, ce que Protect détecte et qui compte comme une présence.",
      "Transcoding": "Transcodage",
      "Livestream": "Direct",
      "Advanced": "Avancé",
      "Address to stream from instead, for a VPN or remote access. Not for stacked controllers.": "Adresse d'où diffuser à la place, pour un VPN ou un accès à distance. Pas pour des contrôleurs empilés.",
      "Check the controller's certificate against trusted authorities. Off, as UniFi consoles sign their own: the first certificate seen is pinned and any other refused.": "Vérifier le certificat du contrôleur auprès d'autorités de confiance. Désactivé, car les consoles UniFi signent le leur : le premier certificat vu est épinglé et tout autre refusé.",
      "Broker to publish events to.": "Broker où publier les événements.",
      "Base topic for the events. Empty: unifi/protect.": "Sujet de base des événements. Vide : unifi/protect.",
      "Check the broker's certificate over mqtts:// or ssl://. Turn off for a self-signed one.": "Vérifier le certificat du broker en mqtts:// ou ssl://. À désactiver pour un certificat auto-signé.",
      "Local address the M3U playlist listens on. Empty: every interface.": "Adresse locale où écoute la liste M3U. Vide : toutes les interfaces.",
      "Count Protect's animal detection as occupancy.": "Compter la détection d'animaux par Protect comme une présence.",
      "Count Protect's face detection as occupancy.": "Compter la détection de visages par Protect comme une présence.",
      "Count Protect's license plate detection as occupancy.": "Compter la détection de plaques par Protect comme une présence.",
      "Count Protect's package detection as occupancy.": "Compter la détection de colis par Protect comme une présence.",
      "Count Protect's person detection as occupancy.": "Compter la détection de personnes par Protect comme une présence.",
      "Count Protect's vehicle detection as occupancy.": "Compter la détection de véhicules par Protect comme une présence.",
      "Count Protect's baby crying detection as occupancy.": "Compter la détection de pleurs de bébé par Protect comme une présence.",
      "Count Protect's barking detection as occupancy.": "Compter la détection d'aboiements par Protect comme une présence.",
      "Count Protect's burglar alarm detection as occupancy.": "Compter la détection d'alarme antivol par Protect comme une présence.",
      "Count Protect's car horn detection as occupancy.": "Compter la détection de klaxon par Protect comme une présence.",
      "Count Protect's CO alarm detection as occupancy.": "Compter la détection d'alarme CO par Protect comme une présence.",
      "Count Protect's glass break detection as occupancy.": "Compter la détection de bris de vitre par Protect comme une présence.",
      "Count Protect's siren detection as occupancy.": "Compter la détection de sirène par Protect comme une présence.",
      "Count Protect's smoke alarm detection as occupancy.": "Compter la détection d'alarme incendie par Protect comme une présence.",
      "Count Protect's speaking detection as occupancy.": "Compter la détection de parole par Protect comme une présence.",
      "Count Protect's smoke and CO alarm detection as occupancy.": "Compter la détection d'alarme fumée et CO par Protect comme une présence."
    },
    "es": {
      "e.g. I'll be there soon.": "Por ejemplo: Ahora mismo voy.",
      "Controller Address": "Dirección del controlador",
      "Controller Name": "Nombre del controlador",
      "Debug Logging": "Registro de depuración",
      "Delay between doorbell rings. Setting this to a non-zero value will prevent multiple rings of a doorbell over the specified duration. Default: 0.": "Tiempo entre llamadas de un timbre. Un valor distinto de cero ignora las llamadas repetidas de un timbre durante ese tiempo. Por defecto: 0.",
      "Direct RTSP / RTSPS URL": "URL RTSP / RTSPS directa",
      "Direct Snapshot URL": "URL de instantánea directa",
      "Doorbell Message": "Mensaje del timbre",
      "Doorbell Messages": "Mensajes del timbre",
      "Doorbell Ring Delay (seconds)": "Retardo entre llamadas del timbre (segundos)",
      "Enable additional logging for FFmpeg. This will create additional logging when video streams are running. Default: false.": "Activa un registro más detallado de FFmpeg, que escribe más mientras se reproducen flujos de vídeo. Por defecto: desactivado.",
      "Enable debug logging for this plugin. This creates a large volume of log output and should only be used when troubleshooting. Default: false.": "Activa el registro de depuración de este plugin. Genera un gran volumen de mensajes y solo debe usarse para resolver problemas. Por defecto: desactivado.",
      "Extra message presets for this controller's doorbells with a screen. While doorbell messages are enabled, each preset appears as a switch that shows it.": "Mensajes predefinidos adicionales para los timbres con pantalla de este controlador. Si los mensajes del timbre están activados, cada mensaje aparece como un interruptor que lo muestra.",
      "FFmpeg Location": "Ubicación de FFmpeg",
      "Feature Options": "Opciones de funciones",
      "Full HTTP or HTTPS URL pointing at the camera's snapshot endpoint. Credentials may be embedded. Self-signed certificates are accepted.": "URL HTTP o HTTPS completa del punto de acceso de instantáneas de la cámara. Puede incluir credenciales. Se aceptan certificados autofirmados.",
      "Full RTSP or RTSPS URL pointing directly at the camera's own RTSP server, bypassing the Protect controller. Credentials may be embedded.": "URL RTSP o RTSPS completa que apunta directamente al servidor RTSP de la cámara, sin pasar por el controlador Protect. Puede incluir credenciales.",
      "Hostname or IP address of your UniFi Protect controller.": "Nombre de host o dirección IP de tu controlador UniFi Protect.",
      "Length of time to display the message on your doorbell. Use 0 to display the message indefinitely. Default: 60.": "Tiempo que se muestra el mensaje en tu timbre. Usa 0 para mostrarlo indefinidamente. Por defecto: 60.",
      "M3U Playlist Bind Address": "Dirección de escucha de la lista de reproducción M3U",
      "MQTT Base Topic": "Tema MQTT base",
      "MQTT Broker URL": "URL del broker MQTT",
      "Message Duration (seconds)": "Duración del mensaje (segundos)",
      "Message Name": "Nombre del mensaje",
      "Message to display on your doorbell. Default: None.": "Mensaje que se muestra en tu timbre. Por defecto: ninguno.",
      "Name for this UniFi Protect controller to be used for logging purposes. Default: Defined by the controller.": "Nombre de este controlador UniFi Protect que se usa en el registro. Por defecto: el que indica el controlador.",
      "Name to use for logging purposes. Default: UniFi Protect.": "Nombre que se usa en el registro. Por defecto: UniFi Protect.",
      "ONVIF Port": "Puerto ONVIF",
      "ONVIF Service Path": "Ruta del servicio ONVIF",
      "ONVIF Username": "Nombre de usuario ONVIF",
      "ONVIF service port remembered for the discovery panel. Leave empty to let the panel try common defaults.": "Puerto del servicio ONVIF que se recuerda para el panel de detección. Déjalo vacío para que el panel pruebe los valores habituales.",
      "Optional ONVIF device service path remembered for the discovery panel. Defaults to /onvif/device_service when blank.": "Ruta opcional del servicio del dispositivo ONVIF que se recuerda para el panel de detección. Si está vacía, es /onvif/device_service.",
      "Override Controller Address": "Dirección alternativa del controlador",
      "Path to the FFmpeg executable. Most users should not use this setting. Default: the first ffmpeg found in PATH.": "Ruta del ejecutable de FFmpeg. La mayoría de usuarios no necesita este ajuste. Por defecto: el primer ffmpeg que se encuentre en el PATH.",
      "Plugin Name": "Nombre del plugin",
      "UniFi Protect Controller": "Controlador UniFi Protect",
      "UniFi Protect Controllers": "Controladores UniFi Protect",
      "Username remembered for the ONVIF discovery panel. Stored in plaintext alongside the controller credentials.": "Nombre de usuario que se recuerda para el panel de detección ONVIF. Se guarda en texto plano junto a las credenciales del controlador.",
      "Verbose FFmpeg Logging": "Registro detallado de FFmpeg",
      "Verify MQTT Broker TLS Certificate": "Verificar el certificado TLS del broker MQTT",
      "Verify TLS Certificate": "Verificar el certificado TLS",
      "Audio": "Audio",
      "Audio support.": "Compatibilidad con audio.",
      "Audio filter for ambient noise suppression.": "Filtro de audio para suprimir el ruido ambiente.",
      "Noise reduction amount, in decibels, for the FFmpeg afftdn filter.": "Nivel de reducción de ruido, en decibelios, para el filtro afftdn de FFmpeg.",
      "Frequency, in Hertz, for the FFmpeg highpass filter.": "Frecuencia, en hercios, para el filtro highpass de FFmpeg.",
      "Frequency, in Hertz, for the FFmpeg lowpass filter.": "Frecuencia, en hercios, para el filtro lowpass de FFmpeg.",
      "Two-way audio support on supported cameras.": "Audio bidireccional en las cámaras compatibles.",
      "Send two-way audio directly to supported cameras, bypassing the controller. Useful for working around bugs in some Protect controller firmware versions.": "Enviar el audio bidireccional directamente a las cámaras compatibles, sin pasar por el controlador. Útil para sortear errores de algunas versiones del firmware de los controladores Protect.",
      "Enable the status indicator light for this device in HomeKit.": "Activar la luz indicadora de estado de este dispositivo en HomeKit.",
      "Add a switch accessory to control the status indicator light in HomeKit.": "Añadir un accesorio interruptor para controlar la luz indicadora de estado en HomeKit.",
      "Enable the night vision indicator light for this device in HomeKit.": "Activar la luz indicadora de visión nocturna de este dispositivo en HomeKit.",
      "Add a dimmer accessory to control the night vision state in HomeKit.": "Añadir un accesorio regulador para controlar la visión nocturna en HomeKit.",
      "Make this a standalone device in HomeKit that will need to be added to HomeKit through the Home app.": "Convertir este dispositivo en un dispositivo independiente en HomeKit, que habrá que añadir a HomeKit desde la app Casa.",
      "Attempt to restart misbehaving devices. This is always done very conservatively and only after periods of extended device-specific issues.": "Intentar reiniciar los dispositivos que fallan. Siempre se hace con mucha prudencia y solo tras periodos prolongados de problemas propios del dispositivo.",
      "Synchronize the UniFi Protect name of this device with HomeKit. Synchronization is one-way only, syncing the device name from UniFi Protect to HomeKit.": "Sincronizar el nombre de UniFi Protect de este dispositivo con HomeKit. La sincronización es solo en un sentido: el nombre pasa de UniFi Protect a HomeKit.",
      "Add a contact sensor that gets activates when a fingerprint or NFC successfully authenticates on a Protect doorbell.": "Añadir un sensor de contacto que se activa cuando una huella dactilar o un NFC se autentica en un timbre Protect.",
      "Add a switch accessory to control whether HomeKit will chime when the doorbell is pressed.": "Añadir un accesorio interruptor para elegir si HomeKit suena cuando se pulsa el timbre.",
      "Enable the doorbell messages feature.": "Activar la función de mensajes del timbre.",
      "Use messages saved to the Protect NVR as message switches.": "Usar los mensajes guardados en el NVR Protect como interruptores de mensaje.",
      "Add a dimmer accessory to control the Protect chime volume in HomeKit.": "Añadir un accesorio regulador para controlar el volumen del carillón Protect en HomeKit.",
      "Add switch accessories to control the physical chimes attached to a Protect doorbell.": "Añadir accesorios interruptores para controlar los carillones físicos conectados a un timbre Protect.",
      "Chime duration, in milliseconds, of a digital physical chime attached to a Protect doorbell.": "Duración del sonido, en milisegundos, de un carillón físico digital conectado a un timbre Protect.",
      "Add a light accessory to control the flashlight on a Protect doorbell package camera.": "Añadir un accesorio de luz para controlar la linterna de la cámara de paquetes de un timbre Protect.",
      "Add a switch accessory to trigger doorbell ring events on a Protect camera or doorbell.": "Añadir un accesorio interruptor para activar eventos de llamada en una cámara o un timbre Protect.",
      "Duration, in seconds, of a single motion event, before allowing a new one.": "Duración, en segundos, de un evento de movimiento antes de permitir uno nuevo.",
      "Add an occupancy sensor accessory using motion sensor activity to determine occupancy. By default, any motion will trigger occupancy. If the smart detection feature option is enabled, it will be used instead.": "Añadir un accesorio sensor de ocupación que usa la actividad del sensor de movimiento para determinar la ocupación. De forma predeterminada, cualquier movimiento activa la ocupación. Si la opción de detección inteligente está activada, se usa en su lugar.",
      "Duration, in seconds, to wait without receiving a motion event to determine when occupancy is no longer detected.": "Duración, en segundos, que se espera sin recibir eventos de movimiento para considerar que ya no hay ocupación.",
      "Use UniFi Protect smart detection for HomeKit motion events when on a supported device.": "Usar la detección inteligente de UniFi Protect para los eventos de movimiento de HomeKit en un dispositivo compatible.",
      "Add contact sensors for each smart detection object type that UniFi Protect supports.": "Añadir sensores de contacto para cada tipo de objeto de detección inteligente que admite UniFi Protect.",
      "Add a contact sensor accessory that will match a specific license plate detected by UniFi Protect. You may specify multiple license plates by using hyphens to distinguish unique license plates (e.g. PLATE1-PLATE2-PLATE3).": "Añadir un accesorio sensor de contacto que corresponde a una matrícula concreta detectada por UniFi Protect. Puedes indicar varias matrículas separándolas con guiones (p. ej., MATRICULA1-MATRICULA2-MATRICULA3).",
      "Add a switch accessory to activate or deactivate motion detection in HomeKit.": "Añadir un accesorio interruptor para activar o desactivar la detección de movimiento en HomeKit.",
      "Add a switch accessory to manually trigger a motion detection event in HomeKit.": "Añadir un accesorio interruptor para activar manualmente un evento de detección de movimiento en HomeKit.",
      "Nvr.Service.Playlist": "Nvr.Service.Playlist",
      "Delay, in seconds, before removing devices that are no longer detected on the Protect controller. If disabled, devices are removed in realtime when the Protect controller does so.": "Retardo, en segundos, antes de eliminar los dispositivos que ya no se detectan en el controlador Protect. Si está desactivado, los dispositivos se eliminan en tiempo real cuando lo hace el controlador Protect.",
      "Publish all the realtime telemetry received from the Protect controller to MQTT.": "Publicar en MQTT toda la telemetría en tiempo real recibida del controlador Protect.",
      "Add switch accessories to control the native recording capabilities of the UniFi Protect NVR.": "Añadir accesorios interruptores para controlar la grabación nativa del NVR UniFi Protect.",
      "Add sensor accessories to display the Protect controller system information (currently only the temperature).": "Añadir accesorios sensores para mostrar la información del sistema del controlador Protect (por ahora, solo la temperatura).",
      "Add a switch accessory to trigger the security system accessory, when using the liveview feature option.": "Añadir un accesorio interruptor para activar el accesorio sistema de seguridad, al usar la opción liveview.",
      "Expose the Protect leak sensor as a contact sensor instead of a leak sensor. This is useful for automation scenarios since HomeKit contact sensors offer more flexible automation options than leak sensors, which are primarily designed for alerts.": "Mostrar el sensor de fugas Protect como sensor de contacto en lugar de sensor de fugas. Es útil para las automatizaciones, ya que los sensores de contacto de HomeKit ofrecen más opciones de automatización que los sensores de fugas, pensados sobre todo para alertas.",
      "Add a lock accessory to unlock. Currently, Protect only supports unlocking Access readers with a camera on the same controller as Protect.": "Añadir un accesorio cerradura para desbloquear. Por ahora, Protect solo permite desbloquear lectores Access con cámara en el mismo controlador que Protect.",
      "Use hardware-accelerated transcoding when available (Apple Macs, Intel Quick Sync Video-enabled CPUs, Raspberry Pi 4).": "Usar la transcodificación acelerada por hardware cuando esté disponible (Mac de Apple, CPU Intel con Quick Sync Video, Raspberry Pi 4).",
      "Use the native Protect livestream API to view livestreams.": "Usar la API nativa de transmisión en directo de Protect para ver las transmisiones en directo.",
      "When streaming to low-latency clients (e.g. at home), transcode livestreams, instead of transmuxing them.": "Al transmitir a clientes de baja latencia (p. ej., en casa), transcodificar las transmisiones en directo en lugar de remultiplexarlas.",
      "Bitrate, in kilobits per second, to use when transcoding to low-latency (e.g. at home) clients, ignoring the bitrate HomeKit requests. HomeKit typically requests lower video quality than you may desire in your environment.": "Tasa de bits, en kilobits por segundo, para transcodificar a clientes de baja latencia (p. ej., en casa), sin tener en cuenta la que pide HomeKit. HomeKit suele pedir menos calidad de vídeo de la que podrías querer.",
      "When streaming to high-latency clients (e.g. cellular connections), transcode livestreams instead of transmuxing them.": "Al transmitir a clientes de alta latencia (p. ej., conexiones móviles), transcodificar las transmisiones en directo en lugar de remultiplexarlas.",
      "Bitrate, in kilobits per second, to use when transcoding to high-latency (e.g. cellular) clients, ignoring the bitrate HomeKit requests. HomeKit typically requests lower video quality than you may desire in your environment.": "Tasa de bits, en kilobits por segundo, para transcodificar a clientes de alta latencia (p. ej., móviles), sin tener en cuenta la que pide HomeKit. HomeKit suele pedir menos calidad de vídeo de la que podrías querer.",
      "When viewing livestreams, force the use of the high quality video stream from the Protect controller.": "Al ver transmisiones en directo, forzar el flujo de vídeo de alta calidad del controlador Protect.",
      "When viewing livestreams, force the use of the medium quality video stream from the Protect controller.": "Al ver transmisiones en directo, forzar el flujo de vídeo de media calidad del controlador Protect.",
      "When viewing livestreams, force the use of the low quality video stream from the Protect controller.": "Al ver transmisiones en directo, forzar el flujo de vídeo de baja calidad del controlador Protect.",
      "Crop the camera video stream. Enabling this option will also force transcoding of livestreams.": "Recortar el flujo de vídeo de la cámara. Activar esta opción también fuerza la transcodificación de las transmisiones en directo.",
      "Left offset of the crop window, as a percentage of the original image width.": "Desplazamiento izquierdo del recorte, como porcentaje del ancho de la imagen original.",
      "Top offset of the crop window, as a percentage of the original image height.": "Desplazamiento superior del recorte, como porcentaje del alto de la imagen original.",
      "Width of the crop window, as a percentage of original image width.": "Ancho del recorte, como porcentaje del ancho de la imagen original.",
      "Height of the crop window, as a percentage of original image height.": "Alto del recorte, como porcentaje del alto de la imagen original.",
      "Enable higher quality snapshots.": "Activar instantáneas de mayor calidad.",
      "Use the camera status indicator light to show when an HKSV event is being recorded.": "Usar la luz indicadora de estado de la cámara para mostrar cuándo se graba un evento HKSV.",
      "Add a switch accessory to enable or disable HKSV event recording.": "Añadir un accesorio interruptor para activar o desactivar la grabación de eventos HKSV.",
      "When recording HomeKit Secure Video events, force the use of the high quality video stream from the Protect controller.": "Al grabar eventos de HomeKit Secure Video, forzar el flujo de vídeo de alta calidad del controlador Protect.",
      "When recording HomeKit Secure Video events, force the use of the medium quality video stream from the Protect controller.": "Al grabar eventos de HomeKit Secure Video, forzar el flujo de vídeo de media calidad del controlador Protect.",
      "When recording HomeKit Secure Video events, force the use of the low quality video stream from the Protect controller.": "Al grabar eventos de HomeKit Secure Video, forzar el flujo de vídeo de baja calidad del controlador Protect.",
      "Device": "Dispositivo",
      "Doorbell": "Timbre",
      "Logging": "Registro",
      "Motion": "Movimiento",
      "NVR": "NVR",
      "Sensor": "Sensor",
      "UniFi Access": "UniFi Access",
      "Video": "Vídeo",
      "HomeKit Secure Video": "HomeKit Secure Video",
      "UniFi consoles by address, for those discovery does not find; each is signed in to in Add accessories, and its login kept in the vault.": "Consolas UniFi por dirección, para las que la búsqueda no encuentra; se inicia sesión en cada una en Añadir accesorios, y sus datos de acceso se guardan en el almacén.",
      "Feature options of a Homebridge block that no setting says (Enable.<option> or Disable.<option>, optionally followed by a device's MAC), one per entry. The bridge moves the others into the settings.": "Las opciones de función de un bloque de Homebridge que ningún ajuste expresa (Enable.<option> o Disable.<option>, seguidas si hace falta del MAC de un dispositivo), una por entrada. El puente pasa las demás a los ajustes.",
      "One option per entry, as the Homebridge plugin's README spells them.": "Una opción por entrada, escrita como en el README del plugin de Homebridge.",
      "Noise Filter": "Filtro de ruido",
      "Noise Reduction (dB)": "Reducción de ruido (dB)",
      "High-Pass Filter (Hz)": "Filtro paso alto (Hz)",
      "Low-Pass Filter (Hz)": "Filtro paso bajo (Hz)",
      "Two-Way Audio": "Audio bidireccional",
      "Two-Way Audio Straight to the Camera": "Audio bidireccional directo a la cámara",
      "Status Light": "Luz de estado",
      "Status Light Switch": "Interruptor de la luz de estado",
      "Night Vision": "Visión nocturna",
      "Night Vision Dimmer": "Regulador de visión nocturna",
      "Standalone Accessory": "Accesorio independiente",
      "Restart When Misbehaving": "Reiniciar si falla",
      "Sync Names": "Sincronizar nombres",
      "Fingerprint and NFC Sensor": "Sensor de huella y NFC",
      "Mute Switch": "Interruptor de silencio",
      "Messages Saved on the NVR": "Mensajes guardados en el NVR",
      "Chime Volume Dimmer": "Regulador del volumen del timbre",
      "Physical Chime Switches": "Interruptores del timbre físico",
      "Digital Chime Duration (ms)": "Duración del timbre digital (ms)",
      "Package Camera Flashlight": "Linterna de la cámara de paquetes",
      "Doorbell Trigger Switch": "Interruptor de activación del timbre",
      "Log Doorbell Rings": "Registrar los timbrazos",
      "Write doorbell rings to the log.": "Escribir los timbrazos en el registro.",
      "Log HomeKit Secure Video": "Registrar HomeKit Secure Video",
      "Write HomeKit Secure Video recording events to the log.": "Escribir los eventos de grabación de HomeKit Secure Video en el registro.",
      "Log Motion": "Registrar el movimiento",
      "Write motion events to the log.": "Escribir los eventos de movimiento en el registro.",
      "Motion Event Length (seconds)": "Duración de un movimiento (segundos)",
      "Occupancy Sensor": "Sensor de ocupación",
      "Occupancy Timeout (seconds)": "Tiempo de ocupación (segundos)",
      "Animal": "Animal",
      "Face": "Rostro",
      "License Plate": "Matrícula",
      "Package": "Paquete",
      "Person": "Persona",
      "Vehicle": "Vehículo",
      "Baby Crying": "Llanto de bebé",
      "Barking": "Ladridos",
      "Burglar Alarm": "Alarma antirrobo",
      "Car Horn": "Bocina",
      "CO Alarm": "Alarma de CO",
      "Glass Break": "Rotura de cristal",
      "Siren": "Sirena",
      "Smoke Alarm": "Alarma de humo",
      "Speaking": "Voz",
      "Smoke and CO Alarm": "Alarma de humo y CO",
      "Smart Detection": "Detección inteligente",
      "Object Sensors": "Sensores de objetos",
      "License Plates to Match": "Matrículas a reconocer",
      "Motion Detection Switch": "Interruptor de detección de movimiento",
      "Motion Trigger Switch": "Interruptor de activación de movimiento",
      "M3U Playlist Port": "Puerto de la lista M3U",
      "Publish an M3U playlist of the Protect cameras on this port of the bridge, for apps such as Channels DVR that play livestreams.": "Publicar una lista M3U de las cámaras de Protect en este puerto del puente, para apps como Channels DVR que reproducen directos.",
      "Device Removal Delay (seconds)": "Retraso de eliminación de dispositivos (segundos)",
      "Publish Telemetry": "Publicar la telemetría",
      "Recording Switches": "Interruptores de grabación",
      "System Info Sensors": "Sensores de información del sistema",
      "Alarm Switch": "Interruptor de alarma",
      "Leak Sensor as Contact Sensor": "Sensor de fugas como sensor de contacto",
      "UniFi Access Lock": "Cerradura UniFi Access",
      "Hardware Transcoding": "Transcodificación por hardware",
      "Protect Livestream API": "API de directo de Protect",
      "Transcode at Home": "Transcodificar en casa",
      "Bitrate at Home (kbps)": "Tasa de bits en casa (kbps)",
      "Transcode Away": "Transcodificar fuera",
      "Bitrate Away (kbps)": "Tasa de bits fuera (kbps)",
      "High Quality Only": "Solo calidad alta",
      "Medium Quality Only": "Solo calidad media",
      "Low Quality Only": "Solo calidad baja",
      "Crop": "Recortar",
      "Left (%)": "Izquierda (%)",
      "Top (%)": "Arriba (%)",
      "Width (%)": "Ancho (%)",
      "Height (%)": "Alto (%)",
      "High-Resolution Snapshots": "Instantáneas de alta resolución",
      "Status Light While Recording": "Luz de estado al grabar",
      "Recording Switch": "Interruptor de grabación",
      "Record High Quality Only": "Grabar solo en calidad alta",
      "Record Medium Quality Only": "Grabar solo en calidad media",
      "Record Low Quality Only": "Grabar solo en calidad baja",
      "Occupancy Triggers": "Activadores de ocupación",
      "With Occupancy Sensor and Smart Detection both on, what Protect detects that counts as someone there.": "Con Sensor de ocupación y Detección inteligente activados, lo que Protect detecta y cuenta como alguien presente.",
      "Transcoding": "Transcodificación",
      "Livestream": "Directo",
      "Advanced": "Avanzado",
      "Address to stream from instead, for a VPN or remote access. Not for stacked controllers.": "Dirección desde la que transmitir en su lugar, para una VPN o acceso remoto. No para controladores apilados.",
      "Check the controller's certificate against trusted authorities. Off, as UniFi consoles sign their own: the first certificate seen is pinned and any other refused.": "Comprobar el certificado del controlador con autoridades de confianza. Desactivado, ya que las consolas UniFi firman el suyo: el primer certificado visto se fija y cualquier otro se rechaza.",
      "Broker to publish events to.": "Broker al que publicar los eventos.",
      "Base topic for the events. Empty: unifi/protect.": "Tema base de los eventos. Vacío: unifi/protect.",
      "Check the broker's certificate over mqtts:// or ssl://. Turn off for a self-signed one.": "Comprobar el certificado del broker con mqtts:// o ssl://. Desactívelo para uno autofirmado.",
      "Local address the M3U playlist listens on. Empty: every interface.": "Dirección local en la que escucha la lista M3U. Vacía: todas las interfaces.",
      "Count Protect's animal detection as occupancy.": "Contar la detección de animales de Protect como ocupación.",
      "Count Protect's face detection as occupancy.": "Contar la detección de rostros de Protect como ocupación.",
      "Count Protect's license plate detection as occupancy.": "Contar la detección de matrículas de Protect como ocupación.",
      "Count Protect's package detection as occupancy.": "Contar la detección de paquetes de Protect como ocupación.",
      "Count Protect's person detection as occupancy.": "Contar la detección de personas de Protect como ocupación.",
      "Count Protect's vehicle detection as occupancy.": "Contar la detección de vehículos de Protect como ocupación.",
      "Count Protect's baby crying detection as occupancy.": "Contar la detección de llanto de bebé de Protect como ocupación.",
      "Count Protect's barking detection as occupancy.": "Contar la detección de ladridos de Protect como ocupación.",
      "Count Protect's burglar alarm detection as occupancy.": "Contar la detección de alarma antirrobo de Protect como ocupación.",
      "Count Protect's car horn detection as occupancy.": "Contar la detección de bocina de Protect como ocupación.",
      "Count Protect's CO alarm detection as occupancy.": "Contar la detección de alarma de CO de Protect como ocupación.",
      "Count Protect's glass break detection as occupancy.": "Contar la detección de rotura de cristal de Protect como ocupación.",
      "Count Protect's siren detection as occupancy.": "Contar la detección de sirena de Protect como ocupación.",
      "Count Protect's smoke alarm detection as occupancy.": "Contar la detección de alarma de humo de Protect como ocupación.",
      "Count Protect's speaking detection as occupancy.": "Contar la detección de voz de Protect como ocupación.",
      "Count Protect's smoke and CO alarm detection as occupancy.": "Contar la detección de alarma de humo y CO de Protect como ocupación."
    },
    "pt": {
      "e.g. I'll be there soon.": "Por exemplo: Já vou.",
      "Controller Address": "Endereço do controlador",
      "Controller Name": "Nome do controlador",
      "Debug Logging": "Registo de depuração",
      "Delay between doorbell rings. Setting this to a non-zero value will prevent multiple rings of a doorbell over the specified duration. Default: 0.": "Intervalo entre toques de uma campainha. Um valor diferente de zero ignora os toques repetidos de uma campainha durante esse tempo. Predefinição: 0.",
      "Direct RTSP / RTSPS URL": "URL RTSP / RTSPS direto",
      "Direct Snapshot URL": "URL de instantâneo direto",
      "Doorbell Message": "Mensagem da campainha",
      "Doorbell Messages": "Mensagens da campainha",
      "Doorbell Ring Delay (seconds)": "Intervalo entre toques da campainha (segundos)",
      "Enable additional logging for FFmpeg. This will create additional logging when video streams are running. Default: false.": "Ativa um registo mais detalhado do FFmpeg, que escreve mais enquanto há transmissões de vídeo. Predefinição: desativado.",
      "Enable debug logging for this plugin. This creates a large volume of log output and should only be used when troubleshooting. Default: false.": "Ativa o registo de depuração deste plugin. Gera um grande volume de mensagens e só deve ser usado para resolver problemas. Predefinição: desativado.",
      "Extra message presets for this controller's doorbells with a screen. While doorbell messages are enabled, each preset appears as a switch that shows it.": "Mensagens predefinidas adicionais para as campainhas com ecrã deste controlador. Com as mensagens da campainha ativadas, cada mensagem aparece como um interruptor que a mostra.",
      "FFmpeg Location": "Localização do FFmpeg",
      "Feature Options": "Opções de funcionalidades",
      "Full HTTP or HTTPS URL pointing at the camera's snapshot endpoint. Credentials may be embedded. Self-signed certificates are accepted.": "URL HTTP ou HTTPS completo do ponto de acesso de instantâneos da câmara. Pode incluir credenciais. São aceites certificados autoassinados.",
      "Full RTSP or RTSPS URL pointing directly at the camera's own RTSP server, bypassing the Protect controller. Credentials may be embedded.": "URL RTSP ou RTSPS completo que aponta diretamente para o servidor RTSP da câmara, sem passar pelo controlador Protect. Pode incluir credenciais.",
      "Hostname or IP address of your UniFi Protect controller.": "Nome de anfitrião ou endereço IP do controlador UniFi Protect.",
      "Length of time to display the message on your doorbell. Use 0 to display the message indefinitely. Default: 60.": "Tempo durante o qual a mensagem é apresentada na campainha. Com 0, é apresentada indefinidamente. Predefinição: 60.",
      "M3U Playlist Bind Address": "Endereço de escuta da lista de reprodução M3U",
      "MQTT Base Topic": "Tópico MQTT base",
      "MQTT Broker URL": "URL do broker MQTT",
      "Message Duration (seconds)": "Duração da mensagem (segundos)",
      "Message Name": "Nome da mensagem",
      "Message to display on your doorbell. Default: None.": "Mensagem a apresentar na campainha. Predefinição: nenhuma.",
      "Name for this UniFi Protect controller to be used for logging purposes. Default: Defined by the controller.": "Nome deste controlador UniFi Protect usado no registo. Predefinição: o indicado pelo controlador.",
      "Name to use for logging purposes. Default: UniFi Protect.": "Nome usado no registo. Predefinição: UniFi Protect.",
      "ONVIF Port": "Porta ONVIF",
      "ONVIF Service Path": "Caminho do serviço ONVIF",
      "ONVIF Username": "Nome de utilizador ONVIF",
      "ONVIF service port remembered for the discovery panel. Leave empty to let the panel try common defaults.": "Porta do serviço ONVIF memorizada para o painel de deteção. Deixe vazio para o painel experimentar os valores habituais.",
      "Optional ONVIF device service path remembered for the discovery panel. Defaults to /onvif/device_service when blank.": "Caminho opcional do serviço do dispositivo ONVIF, memorizado para o painel de deteção. Vazio, é /onvif/device_service.",
      "Override Controller Address": "Endereço alternativo do controlador",
      "Path to the FFmpeg executable. Most users should not use this setting. Default: the first ffmpeg found in PATH.": "Caminho do executável do FFmpeg. A maioria dos utilizadores não precisa desta definição. Predefinição: o primeiro ffmpeg encontrado no PATH.",
      "Plugin Name": "Nome do plugin",
      "UniFi Protect Controller": "Controlador UniFi Protect",
      "UniFi Protect Controllers": "Controladores UniFi Protect",
      "Username remembered for the ONVIF discovery panel. Stored in plaintext alongside the controller credentials.": "Nome de utilizador memorizado para o painel de deteção ONVIF. Guardado em texto simples junto das credenciais do controlador.",
      "Verbose FFmpeg Logging": "Registo detalhado do FFmpeg",
      "Verify MQTT Broker TLS Certificate": "Verificar o certificado TLS do broker MQTT",
      "Verify TLS Certificate": "Verificar o certificado TLS",
      "Audio": "Áudio",
      "Audio support.": "Suporte de áudio.",
      "Audio filter for ambient noise suppression.": "Filtro de áudio para suprimir o ruído ambiente.",
      "Noise reduction amount, in decibels, for the FFmpeg afftdn filter.": "Nível de redução de ruído, em decibéis, para o filtro afftdn do FFmpeg.",
      "Frequency, in Hertz, for the FFmpeg highpass filter.": "Frequência, em hertz, para o filtro highpass do FFmpeg.",
      "Frequency, in Hertz, for the FFmpeg lowpass filter.": "Frequência, em hertz, para o filtro lowpass do FFmpeg.",
      "Two-way audio support on supported cameras.": "Áudio bidirecional nas câmaras compatíveis.",
      "Send two-way audio directly to supported cameras, bypassing the controller. Useful for working around bugs in some Protect controller firmware versions.": "Enviar o áudio bidirecional diretamente para as câmaras compatíveis, sem passar pelo controlador. Útil para contornar erros de algumas versões do firmware dos controladores Protect.",
      "Enable the status indicator light for this device in HomeKit.": "Ativar a luz indicadora de estado deste dispositivo no HomeKit.",
      "Add a switch accessory to control the status indicator light in HomeKit.": "Adicionar um acessório interruptor para controlar a luz indicadora de estado no HomeKit.",
      "Enable the night vision indicator light for this device in HomeKit.": "Ativar a luz indicadora de visão noturna deste dispositivo no HomeKit.",
      "Add a dimmer accessory to control the night vision state in HomeKit.": "Adicionar um acessório regulador para controlar a visão noturna no HomeKit.",
      "Make this a standalone device in HomeKit that will need to be added to HomeKit through the Home app.": "Tornar este dispositivo independente no HomeKit, sendo necessário adicioná-lo ao HomeKit através da app Casa.",
      "Attempt to restart misbehaving devices. This is always done very conservatively and only after periods of extended device-specific issues.": "Tentar reiniciar os dispositivos com falhas. Isto é sempre feito com muita prudência e apenas após períodos prolongados de problemas específicos do dispositivo.",
      "Synchronize the UniFi Protect name of this device with HomeKit. Synchronization is one-way only, syncing the device name from UniFi Protect to HomeKit.": "Sincronizar o nome UniFi Protect deste dispositivo com o HomeKit. A sincronização é apenas num sentido: o nome passa do UniFi Protect para o HomeKit.",
      "Add a contact sensor that gets activates when a fingerprint or NFC successfully authenticates on a Protect doorbell.": "Adicionar um sensor de contacto que é ativado quando uma impressão digital ou um NFC é autenticado numa campainha Protect.",
      "Add a switch accessory to control whether HomeKit will chime when the doorbell is pressed.": "Adicionar um acessório interruptor para escolher se o HomeKit toca quando a campainha é premida.",
      "Enable the doorbell messages feature.": "Ativar a funcionalidade de mensagens da campainha.",
      "Use messages saved to the Protect NVR as message switches.": "Usar as mensagens guardadas no NVR Protect como interruptores de mensagem.",
      "Add a dimmer accessory to control the Protect chime volume in HomeKit.": "Adicionar um acessório regulador para controlar o volume do carrilhão Protect no HomeKit.",
      "Add switch accessories to control the physical chimes attached to a Protect doorbell.": "Adicionar acessórios interruptores para controlar os carrilhões físicos ligados a uma campainha Protect.",
      "Chime duration, in milliseconds, of a digital physical chime attached to a Protect doorbell.": "Duração do toque, em milissegundos, de um carrilhão físico digital ligado a uma campainha Protect.",
      "Add a light accessory to control the flashlight on a Protect doorbell package camera.": "Adicionar um acessório de luz para controlar a lanterna da câmara de encomendas de uma campainha Protect.",
      "Add a switch accessory to trigger doorbell ring events on a Protect camera or doorbell.": "Adicionar um acessório interruptor para acionar eventos de toque numa câmara ou campainha Protect.",
      "Duration, in seconds, of a single motion event, before allowing a new one.": "Duração, em segundos, de um evento de movimento antes de permitir um novo.",
      "Add an occupancy sensor accessory using motion sensor activity to determine occupancy. By default, any motion will trigger occupancy. If the smart detection feature option is enabled, it will be used instead.": "Adicionar um acessório sensor de ocupação que usa a atividade do sensor de movimento para determinar a ocupação. Por predefinição, qualquer movimento ativa a ocupação. Se a opção de deteção inteligente estiver ativada, é usada em vez disso.",
      "Duration, in seconds, to wait without receiving a motion event to determine when occupancy is no longer detected.": "Duração, em segundos, a aguardar sem receber eventos de movimento para considerar que a ocupação deixou de ser detetada.",
      "Use UniFi Protect smart detection for HomeKit motion events when on a supported device.": "Usar a deteção inteligente do UniFi Protect para os eventos de movimento do HomeKit num dispositivo compatível.",
      "Add contact sensors for each smart detection object type that UniFi Protect supports.": "Adicionar sensores de contacto para cada tipo de objeto da deteção inteligente suportado pelo UniFi Protect.",
      "Add a contact sensor accessory that will match a specific license plate detected by UniFi Protect. You may specify multiple license plates by using hyphens to distinguish unique license plates (e.g. PLATE1-PLATE2-PLATE3).": "Adicionar um acessório sensor de contacto que corresponde a uma matrícula específica detetada pelo UniFi Protect. É possível indicar várias matrículas separando-as com hífenes (p. ex. MATRICULA1-MATRICULA2-MATRICULA3).",
      "Add a switch accessory to activate or deactivate motion detection in HomeKit.": "Adicionar um acessório interruptor para ativar ou desativar a deteção de movimento no HomeKit.",
      "Add a switch accessory to manually trigger a motion detection event in HomeKit.": "Adicionar um acessório interruptor para acionar manualmente um evento de deteção de movimento no HomeKit.",
      "Nvr.Service.Playlist": "Nvr.Service.Playlist",
      "Delay, in seconds, before removing devices that are no longer detected on the Protect controller. If disabled, devices are removed in realtime when the Protect controller does so.": "Atraso, em segundos, antes de remover os dispositivos que deixaram de ser detetados no controlador Protect. Se estiver desativado, os dispositivos são removidos em tempo real quando o controlador Protect o faz.",
      "Publish all the realtime telemetry received from the Protect controller to MQTT.": "Publicar no MQTT toda a telemetria em tempo real recebida do controlador Protect.",
      "Add switch accessories to control the native recording capabilities of the UniFi Protect NVR.": "Adicionar acessórios interruptores para controlar a gravação nativa do NVR UniFi Protect.",
      "Add sensor accessories to display the Protect controller system information (currently only the temperature).": "Adicionar acessórios sensores para mostrar as informações do sistema do controlador Protect (por agora, apenas a temperatura).",
      "Add a switch accessory to trigger the security system accessory, when using the liveview feature option.": "Adicionar um acessório interruptor para acionar o acessório sistema de segurança, ao usar a opção liveview.",
      "Expose the Protect leak sensor as a contact sensor instead of a leak sensor. This is useful for automation scenarios since HomeKit contact sensors offer more flexible automation options than leak sensors, which are primarily designed for alerts.": "Apresentar o sensor de fugas Protect como sensor de contacto em vez de sensor de fugas. É útil para automatizações, porque os sensores de contacto do HomeKit oferecem mais opções de automatização do que os sensores de fugas, pensados sobretudo para alertas.",
      "Add a lock accessory to unlock. Currently, Protect only supports unlocking Access readers with a camera on the same controller as Protect.": "Adicionar um acessório fechadura para destrancar. Por agora, o Protect só permite destrancar leitores Access com câmara no mesmo controlador que o Protect.",
      "Use hardware-accelerated transcoding when available (Apple Macs, Intel Quick Sync Video-enabled CPUs, Raspberry Pi 4).": "Usar a transcodificação acelerada por hardware quando disponível (Mac da Apple, CPU Intel com Quick Sync Video, Raspberry Pi 4).",
      "Use the native Protect livestream API to view livestreams.": "Usar a API nativa de transmissão em direto do Protect para ver as transmissões em direto.",
      "When streaming to low-latency clients (e.g. at home), transcode livestreams, instead of transmuxing them.": "Ao transmitir para clientes de baixa latência (p. ex. em casa), transcodificar as transmissões em direto em vez de as remultiplexar.",
      "Bitrate, in kilobits per second, to use when transcoding to low-latency (e.g. at home) clients, ignoring the bitrate HomeKit requests. HomeKit typically requests lower video quality than you may desire in your environment.": "Taxa de bits, em kilobits por segundo, a usar na transcodificação para clientes de baixa latência (p. ex. em casa), ignorando a pedida pelo HomeKit. O HomeKit costuma pedir uma qualidade de vídeo inferior à que se pode desejar.",
      "When streaming to high-latency clients (e.g. cellular connections), transcode livestreams instead of transmuxing them.": "Ao transmitir para clientes de alta latência (p. ex. ligações móveis), transcodificar as transmissões em direto em vez de as remultiplexar.",
      "Bitrate, in kilobits per second, to use when transcoding to high-latency (e.g. cellular) clients, ignoring the bitrate HomeKit requests. HomeKit typically requests lower video quality than you may desire in your environment.": "Taxa de bits, em kilobits por segundo, a usar na transcodificação para clientes de alta latência (p. ex. móveis), ignorando a pedida pelo HomeKit. O HomeKit costuma pedir uma qualidade de vídeo inferior à que se pode desejar.",
      "When viewing livestreams, force the use of the high quality video stream from the Protect controller.": "Ao ver transmissões em direto, forçar o fluxo de vídeo de alta qualidade do controlador Protect.",
      "When viewing livestreams, force the use of the medium quality video stream from the Protect controller.": "Ao ver transmissões em direto, forçar o fluxo de vídeo de média qualidade do controlador Protect.",
      "When viewing livestreams, force the use of the low quality video stream from the Protect controller.": "Ao ver transmissões em direto, forçar o fluxo de vídeo de baixa qualidade do controlador Protect.",
      "Crop the camera video stream. Enabling this option will also force transcoding of livestreams.": "Recortar o fluxo de vídeo da câmara. Ativar esta opção também força a transcodificação das transmissões em direto.",
      "Left offset of the crop window, as a percentage of the original image width.": "Deslocamento esquerdo da área de recorte, em percentagem da largura da imagem original.",
      "Top offset of the crop window, as a percentage of the original image height.": "Deslocamento superior da área de recorte, em percentagem da altura da imagem original.",
      "Width of the crop window, as a percentage of original image width.": "Largura da área de recorte, em percentagem da largura da imagem original.",
      "Height of the crop window, as a percentage of original image height.": "Altura da área de recorte, em percentagem da altura da imagem original.",
      "Enable higher quality snapshots.": "Ativar instantâneos de maior qualidade.",
      "Use the camera status indicator light to show when an HKSV event is being recorded.": "Usar a luz indicadora de estado da câmara para mostrar quando um evento HKSV está a ser gravado.",
      "Add a switch accessory to enable or disable HKSV event recording.": "Adicionar um acessório interruptor para ativar ou desativar a gravação de eventos HKSV.",
      "When recording HomeKit Secure Video events, force the use of the high quality video stream from the Protect controller.": "Ao gravar eventos do HomeKit Secure Video, forçar o fluxo de vídeo de alta qualidade do controlador Protect.",
      "When recording HomeKit Secure Video events, force the use of the medium quality video stream from the Protect controller.": "Ao gravar eventos do HomeKit Secure Video, forçar o fluxo de vídeo de média qualidade do controlador Protect.",
      "When recording HomeKit Secure Video events, force the use of the low quality video stream from the Protect controller.": "Ao gravar eventos do HomeKit Secure Video, forçar o fluxo de vídeo de baixa qualidade do controlador Protect.",
      "Device": "Dispositivo",
      "Doorbell": "Campainha",
      "Logging": "Registo",
      "Motion": "Movimento",
      "NVR": "NVR",
      "Sensor": "Sensor",
      "UniFi Access": "UniFi Access",
      "Video": "Vídeo",
      "HomeKit Secure Video": "HomeKit Secure Video",
      "UniFi consoles by address, for those discovery does not find; each is signed in to in Add accessories, and its login kept in the vault.": "Consolas UniFi por endereço, para as que a descoberta não encontra; cada uma inicia sessão em Adicionar acessórios, e as credenciais ficam guardadas no cofre.",
      "Feature options of a Homebridge block that no setting says (Enable.<option> or Disable.<option>, optionally followed by a device's MAC), one per entry. The bridge moves the others into the settings.": "As opções de funcionalidade de um bloco do Homebridge que nenhuma definição exprime (Enable.<option> ou Disable.<option>, seguidas se preciso do MAC de um dispositivo), uma por entrada. A ponte passa as outras para as definições.",
      "One option per entry, as the Homebridge plugin's README spells them.": "Uma opção por entrada, escrita como no README do plugin do Homebridge.",
      "Noise Filter": "Filtro de ruído",
      "Noise Reduction (dB)": "Redução de ruído (dB)",
      "High-Pass Filter (Hz)": "Filtro passa-alto (Hz)",
      "Low-Pass Filter (Hz)": "Filtro passa-baixo (Hz)",
      "Two-Way Audio": "Áudio bidirecional",
      "Two-Way Audio Straight to the Camera": "Áudio bidirecional direto para a câmara",
      "Status Light": "Luz de estado",
      "Status Light Switch": "Interruptor da luz de estado",
      "Night Vision": "Visão noturna",
      "Night Vision Dimmer": "Regulador de visão noturna",
      "Standalone Accessory": "Acessório independente",
      "Restart When Misbehaving": "Reiniciar em caso de falha",
      "Sync Names": "Sincronizar nomes",
      "Fingerprint and NFC Sensor": "Sensor de impressão digital e NFC",
      "Mute Switch": "Interruptor de silêncio",
      "Messages Saved on the NVR": "Mensagens guardadas no NVR",
      "Chime Volume Dimmer": "Regulador do volume do sinal",
      "Physical Chime Switches": "Interruptores do sinal físico",
      "Digital Chime Duration (ms)": "Duração do sinal digital (ms)",
      "Package Camera Flashlight": "Lanterna da câmara de encomendas",
      "Doorbell Trigger Switch": "Interruptor de acionamento da campainha",
      "Log Doorbell Rings": "Registar os toques",
      "Write doorbell rings to the log.": "Escrever os toques no registo.",
      "Log HomeKit Secure Video": "Registar HomeKit Secure Video",
      "Write HomeKit Secure Video recording events to the log.": "Escrever os eventos de gravação do HomeKit Secure Video no registo.",
      "Log Motion": "Registar o movimento",
      "Write motion events to the log.": "Escrever os eventos de movimento no registo.",
      "Motion Event Length (seconds)": "Duração de um movimento (segundos)",
      "Occupancy Sensor": "Sensor de ocupação",
      "Occupancy Timeout (seconds)": "Tempo de ocupação (segundos)",
      "Animal": "Animal",
      "Face": "Rosto",
      "License Plate": "Matrícula",
      "Package": "Encomenda",
      "Person": "Pessoa",
      "Vehicle": "Veículo",
      "Baby Crying": "Choro de bebé",
      "Barking": "Latidos",
      "Burglar Alarm": "Alarme de intrusão",
      "Car Horn": "Buzina",
      "CO Alarm": "Alarme de CO",
      "Glass Break": "Quebra de vidro",
      "Siren": "Sirene",
      "Smoke Alarm": "Alarme de fumo",
      "Speaking": "Voz",
      "Smoke and CO Alarm": "Alarme de fumo e CO",
      "Smart Detection": "Deteção inteligente",
      "Object Sensors": "Sensores de objetos",
      "License Plates to Match": "Matrículas a reconhecer",
      "Motion Detection Switch": "Interruptor de deteção de movimento",
      "Motion Trigger Switch": "Interruptor de acionamento de movimento",
      "M3U Playlist Port": "Porta da lista M3U",
      "Publish an M3U playlist of the Protect cameras on this port of the bridge, for apps such as Channels DVR that play livestreams.": "Publicar uma lista M3U das câmaras do Protect nesta porta da ponte, para apps como o Channels DVR que reproduzem transmissões.",
      "Device Removal Delay (seconds)": "Atraso de remoção de dispositivos (segundos)",
      "Publish Telemetry": "Publicar a telemetria",
      "Recording Switches": "Interruptores de gravação",
      "System Info Sensors": "Sensores de informação do sistema",
      "Alarm Switch": "Interruptor de alarme",
      "Leak Sensor as Contact Sensor": "Sensor de fugas como sensor de contacto",
      "UniFi Access Lock": "Fechadura UniFi Access",
      "Hardware Transcoding": "Transcodificação por hardware",
      "Protect Livestream API": "API de transmissão do Protect",
      "Transcode at Home": "Transcodificar em casa",
      "Bitrate at Home (kbps)": "Taxa de bits em casa (kbps)",
      "Transcode Away": "Transcodificar fora",
      "Bitrate Away (kbps)": "Taxa de bits fora (kbps)",
      "High Quality Only": "Apenas alta qualidade",
      "Medium Quality Only": "Apenas qualidade média",
      "Low Quality Only": "Apenas baixa qualidade",
      "Crop": "Recortar",
      "Left (%)": "Esquerda (%)",
      "Top (%)": "Topo (%)",
      "Width (%)": "Largura (%)",
      "Height (%)": "Altura (%)",
      "High-Resolution Snapshots": "Instantâneos de alta resolução",
      "Status Light While Recording": "Luz de estado durante a gravação",
      "Recording Switch": "Interruptor de gravação",
      "Record High Quality Only": "Gravar apenas em alta qualidade",
      "Record Medium Quality Only": "Gravar apenas em qualidade média",
      "Record Low Quality Only": "Gravar apenas em baixa qualidade",
      "Occupancy Triggers": "Acionadores de ocupação",
      "With Occupancy Sensor and Smart Detection both on, what Protect detects that counts as someone there.": "Com Sensor de ocupação e Deteção inteligente ativos, o que o Protect deteta e conta como alguém presente.",
      "Transcoding": "Transcodificação",
      "Livestream": "Transmissão em direto",
      "Advanced": "Avançado",
      "Address to stream from instead, for a VPN or remote access. Not for stacked controllers.": "Endereço de onde transmitir em vez deste, para uma VPN ou acesso remoto. Não para controladores empilhados.",
      "Check the controller's certificate against trusted authorities. Off, as UniFi consoles sign their own: the first certificate seen is pinned and any other refused.": "Verificar o certificado do controlador junto de autoridades de confiança. Desativado, pois as consolas UniFi assinam o seu: o primeiro certificado visto é fixado e qualquer outro recusado.",
      "Broker to publish events to.": "Broker onde publicar os eventos.",
      "Base topic for the events. Empty: unifi/protect.": "Tópico base dos eventos. Vazio: unifi/protect.",
      "Check the broker's certificate over mqtts:// or ssl://. Turn off for a self-signed one.": "Verificar o certificado do broker em mqtts:// ou ssl://. Desative para um autoassinado.",
      "Local address the M3U playlist listens on. Empty: every interface.": "Endereço local onde a lista M3U escuta. Vazio: todas as interfaces.",
      "Count Protect's animal detection as occupancy.": "Contar a deteção de animais pelo Protect como ocupação.",
      "Count Protect's face detection as occupancy.": "Contar a deteção de rostos pelo Protect como ocupação.",
      "Count Protect's license plate detection as occupancy.": "Contar a deteção de matrículas pelo Protect como ocupação.",
      "Count Protect's package detection as occupancy.": "Contar a deteção de encomendas pelo Protect como ocupação.",
      "Count Protect's person detection as occupancy.": "Contar a deteção de pessoas pelo Protect como ocupação.",
      "Count Protect's vehicle detection as occupancy.": "Contar a deteção de veículos pelo Protect como ocupação.",
      "Count Protect's baby crying detection as occupancy.": "Contar a deteção de choro de bebé pelo Protect como ocupação.",
      "Count Protect's barking detection as occupancy.": "Contar a deteção de latidos pelo Protect como ocupação.",
      "Count Protect's burglar alarm detection as occupancy.": "Contar a deteção de alarme de intrusão pelo Protect como ocupação.",
      "Count Protect's car horn detection as occupancy.": "Contar a deteção de buzina pelo Protect como ocupação.",
      "Count Protect's CO alarm detection as occupancy.": "Contar a deteção de alarme de CO pelo Protect como ocupação.",
      "Count Protect's glass break detection as occupancy.": "Contar a deteção de quebra de vidro pelo Protect como ocupação.",
      "Count Protect's siren detection as occupancy.": "Contar a deteção de sirene pelo Protect como ocupação.",
      "Count Protect's smoke alarm detection as occupancy.": "Contar a deteção de alarme de fumo pelo Protect como ocupação.",
      "Count Protect's speaking detection as occupancy.": "Contar a deteção de voz pelo Protect como ocupação.",
      "Count Protect's smoke and CO alarm detection as occupancy.": "Contar a deteção de alarme de fumo e CO pelo Protect como ocupação."
    }
  }
}
"""#
}
