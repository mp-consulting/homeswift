// THIS FILE IS GENERATED from ../config.schema.json by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

extension ReolinkPlugin {
    /// The plugin's config.schema.json, as written, for settings forms and the config copilot.
    public static let configurationSchemaJSON: String? = #"""
{
  "pluginAlias": "Reolink",
  "pluginType": "platform",
  "singular": true,
  "headerDisplay": "Reolink cameras, doorbells, NVRs and Home Hubs on the local network. Add them on Add accessories with their address and a local user.",
  "schema": {
    "type": "object",
    "properties": {
      "name": {
        "title": "Name",
        "type": "string",
        "description": "The name of the plugin in the log.",
        "default": "Reolink"
      },
      "videoProcessor": {
        "title": "FFmpeg executable",
        "type": "string",
        "description": "The FFmpeg that streams and records the cameras: a path, or a name in PATH.",
        "placeholder": "ffmpeg"
      },
      "webhookPort": {
        "title": "Event port for battery cameras",
        "type": "integer",
        "description": "Battery cameras on their own sleep between uses, so they post their motion and doorbell presses to the bridge on this port: the cameras must be able to reach it (open it in a firewall). Empty: a port chosen once and kept.",
        "minimum": 1,
        "maximum": 65535
      },
      "devices": {
        "title": "Devices",
        "type": "array",
        "description": "Reolink cameras, doorbells, NVRs and Home Hubs by address. Add accessories sets them up without editing this list.",
        "items": {
          "type": "object",
          "title": "Device",
          "x-rowTitle": "host",
          "properties": {
            "host": {
              "title": "Address",
              "type": "string",
              "description": "The IP address or host name of the camera, doorbell, NVR or Home Hub.",
              "format": "hostname",
              "required": true
            },
            "username": {
              "title": "User name",
              "type": "string",
              "description": "A local user of the device; an administrator can switch floodlights, sirens and IR lights.",
              "placeholder": "admin"
            },
            "port": {
              "title": "API port",
              "type": "integer",
              "description": "The HTTP(S) API's port. Empty: HTTPS on 443, then HTTP on 80.",
              "minimum": 1,
              "maximum": 65535
            },
            "useHttps": {
              "title": "Use HTTPS",
              "type": "boolean",
              "description": "Force HTTPS or HTTP; unset tries both. The device's certificate is trusted the first time and pinned."
            },
            "baichuanPort": {
              "title": "Baichuan port",
              "type": "integer",
              "description": "The TCP port of the device's push events (Baichuan).",
              "placeholder": 9000,
              "minimum": 1,
              "maximum": 65535
            },
            "channels": {
              "title": "Channels",
              "type": "array",
              "description": "An NVR's or a hub's channels to publish, counted from 0; empty for every online channel.",
              "items": {
                "type": "integer",
                "minimum": 0,
                "title": "Channel",
                "description": "A channel number, from 0."
              }
            },
            "streamProtocol": {
              "title": "Stream protocol",
              "type": "string",
              "description": "How FFmpeg reads the video.",
              "default": "rtsp",
              "oneOf": [
                {
                  "title": "RTSP (recommended)",
                  "enum": [
                    "rtsp"
                  ]
                },
                {
                  "title": "RTMP",
                  "enum": [
                    "rtmp"
                  ]
                },
                {
                  "title": "FLV",
                  "enum": [
                    "flv"
                  ]
                }
              ]
            },
            "pushEvents": {
              "title": "Push events",
              "type": "boolean",
              "description": "Motion, detections and rings pushed by the device; off polls them every few seconds instead.",
              "default": true
            },
            "pollInterval": {
              "title": "Refresh interval (seconds)",
              "type": "integer",
              "description": "How often the lights, battery and channel list are read. Empty: 60 seconds, 10 more per camera above six.",
              "minimum": 10
            },
            "motionPollInterval": {
              "title": "Motion polling interval (seconds)",
              "type": "integer",
              "description": "How often motion is asked for while push events are not active.",
              "placeholder": 5,
              "minimum": 1
            },
            "batteryCamera": {
              "title": "Battery camera without a hub",
              "type": "boolean",
              "description": "Experimental: a battery camera on its own Wi-Fi, without a Home Hub or NVR. It is reached over Reolink's own protocol (TCP 9000) only when HomeKit asks for video or a snapshot, so it can sleep. Setup turns this on when it finds one."
            },
            "takeOverEventPush": {
              "title": "Take over event push",
              "type": "boolean",
              "description": "A battery camera sends its events to one receiver only. On: the bridge takes the place of another receiver (Home Assistant's, say). Off: the other receiver keeps it, and the camera's motion and doorbell presses do not reach HomeKit."
            },
            "cameras": {
              "title": "Cameras",
              "type": "object",
              "description": "Options by channel number (\"0\", \"1\"…); once saved they move to each camera's settings.",
              "additionalProperties": {
                "type": "object",
                "title": "Camera",
                "properties": {
                  "name": {
                    "title": "Name",
                    "type": "string",
                    "description": "The camera's name; empty for the one the device gives."
                  },
                  "motionSensor": {
                    "title": "Motion sensor",
                    "type": "boolean",
                    "description": "A motion sensor, which also starts HomeKit Secure Video recordings.",
                    "default": true
                  },
                  "aiSensors": {
                    "title": "Detection sensors",
                    "type": "array",
                    "description": "A motion sensor for each kind of detection the camera makes; empty for every kind it supports.",
                    "uniqueItems": true,
                    "items": {
                      "type": "string",
                      "title": "Detection",
                      "description": "A kind of detection.",
                      "oneOf": [
                        {
                          "title": "Person",
                          "enum": [
                            "person"
                          ]
                        },
                        {
                          "title": "Vehicle",
                          "enum": [
                            "vehicle"
                          ]
                        },
                        {
                          "title": "Pet",
                          "enum": [
                            "pet"
                          ]
                        },
                        {
                          "title": "Face",
                          "enum": [
                            "face"
                          ]
                        },
                        {
                          "title": "Package",
                          "enum": [
                            "package"
                          ]
                        }
                      ]
                    }
                  },
                  "doorbell": {
                    "title": "Doorbell",
                    "type": "boolean",
                    "description": "A doorbell button; unset when the device says it is a doorbell."
                  },
                  "floodlight": {
                    "title": "Floodlight",
                    "type": "boolean",
                    "description": "The floodlight or spotlight as a light.",
                    "default": true
                  },
                  "siren": {
                    "title": "Siren",
                    "type": "boolean",
                    "description": "The siren as a switch (off by default: a siren in an automation is loud). It turns itself off after a minute.",
                    "default": false
                  },
                  "irLights": {
                    "title": "Infrared switch",
                    "type": "boolean",
                    "description": "A switch for the IR lights: on is automatic, off is off.",
                    "default": false
                  },
                  "stream": {
                    "title": "Stream",
                    "type": "string",
                    "description": "Which of the camera's streams answers HomeKit.",
                    "default": "auto",
                    "oneOf": [
                      {
                        "title": "Automatic: the sub stream for small sizes",
                        "enum": [
                          "auto"
                        ]
                      },
                      {
                        "title": "Main stream",
                        "enum": [
                          "main"
                        ]
                      },
                      {
                        "title": "Sub stream",
                        "enum": [
                          "sub"
                        ]
                      }
                    ]
                  },
                  "audio": {
                    "title": "Audio",
                    "type": "boolean",
                    "description": "The camera's sound in live streams.",
                    "default": false
                  },
                  "twoWayAudio": {
                    "title": "Two-way audio",
                    "type": "boolean",
                    "description": "Experimental: talk through the camera's speaker from the Home app. Only where the camera says it can, and with Push events on. Not yet tried on a Reolink device.",
                    "default": false
                  },
                  "recording": {
                    "title": "HomeKit Secure Video",
                    "type": "boolean",
                    "description": "Recordings in iCloud when motion is seen (needs a home hub and an iCloud plan).",
                    "default": false
                  },
                  "prebuffer": {
                    "title": "Prebuffer",
                    "type": "boolean",
                    "description": "Keeps the last seconds of video so recordings start before the motion (one stream always open).",
                    "default": false
                  },
                  "maxStreams": {
                    "title": "Simultaneous streams",
                    "type": "integer",
                    "description": "How many HomeKit viewers may watch at once.",
                    "placeholder": 2,
                    "minimum": 1,
                    "maximum": 4
                  },
                  "vcodec": {
                    "title": "Video encoding",
                    "type": "string",
                    "description": "Copy sends an H.264 stream as it is (light on the bridge); otherwise the video is encoded as HomeKit asks. H.265 is always encoded.",
                    "default": "libx264",
                    "oneOf": [
                      {
                        "title": "Encode",
                        "enum": [
                          "libx264"
                        ]
                      },
                      {
                        "title": "Copy",
                        "enum": [
                          "copy"
                        ]
                      }
                    ]
                  },
                  "encoderOptions": {
                    "title": "Encoder options",
                    "type": "string",
                    "description": "Extra FFmpeg options for the encoder, separated by spaces."
                  },
                  "debug": {
                    "title": "FFmpeg debug",
                    "type": "boolean",
                    "description": "FFmpeg's verbose output in the log.",
                    "default": false
                  },
                  "ringThrottleSeconds": {
                    "title": "Ring interval (seconds)",
                    "type": "integer",
                    "description": "Presses within this many seconds of a ring are ignored.",
                    "placeholder": 3,
                    "minimum": 0
                  },
                  "motionTimeout": {
                    "title": "Motion duration (seconds)",
                    "type": "integer",
                    "description": "How long a battery camera's motion stays on: it never says that motion stopped.",
                    "placeholder": 30,
                    "minimum": 5,
                    "maximum": 3600
                  }
                }
              }
            }
          }
        }
      }
    }
  },
  "accessorySchema": {
    "properties": {
      "host": {
        "title": "Address",
        "type": "string",
        "description": "The IP address or host name of the camera, doorbell, NVR or Home Hub.",
        "format": "hostname",
        "x-kinds": [
          "camera",
          "nvr"
        ]
      },
      "port": {
        "title": "API port",
        "type": "integer",
        "description": "The HTTP(S) API's port. Empty: HTTPS on 443, then HTTP on 80.",
        "minimum": 1,
        "maximum": 65535,
        "x-kinds": [
          "camera",
          "nvr"
        ]
      },
      "useHttps": {
        "title": "Use HTTPS",
        "type": "boolean",
        "description": "Force HTTPS or HTTP; unset tries both. The device's certificate is trusted the first time and pinned.",
        "x-kinds": [
          "camera",
          "nvr"
        ]
      },
      "baichuanPort": {
        "title": "Baichuan port",
        "type": "integer",
        "description": "The TCP port of the device's push events (Baichuan).",
        "placeholder": 9000,
        "minimum": 1,
        "maximum": 65535,
        "x-kinds": [
          "camera",
          "nvr"
        ]
      },
      "channels": {
        "title": "Channels",
        "type": "array",
        "description": "An NVR's or a hub's channels to publish, counted from 0; empty for every online channel.",
        "items": {
          "type": "integer",
          "minimum": 0,
          "title": "Channel",
          "description": "A channel number, from 0."
        },
        "x-kinds": [
          "camera",
          "nvr"
        ]
      },
      "streamProtocol": {
        "title": "Stream protocol",
        "type": "string",
        "description": "How FFmpeg reads the video.",
        "default": "rtsp",
        "oneOf": [
          {
            "title": "RTSP (recommended)",
            "enum": [
              "rtsp"
            ]
          },
          {
            "title": "RTMP",
            "enum": [
              "rtmp"
            ]
          },
          {
            "title": "FLV",
            "enum": [
              "flv"
            ]
          }
        ],
        "x-kinds": [
          "camera",
          "nvr"
        ]
      },
      "pushEvents": {
        "title": "Push events",
        "type": "boolean",
        "description": "Motion, detections and rings pushed by the device; off polls them every few seconds instead.",
        "default": true,
        "x-kinds": [
          "camera",
          "nvr"
        ]
      },
      "pollInterval": {
        "title": "Refresh interval (seconds)",
        "type": "integer",
        "description": "How often the lights, battery and channel list are read. Empty: 60 seconds, 10 more per camera above six.",
        "minimum": 10,
        "x-kinds": [
          "camera",
          "nvr"
        ]
      },
      "motionPollInterval": {
        "title": "Motion polling interval (seconds)",
        "type": "integer",
        "description": "How often motion is asked for while push events are not active.",
        "placeholder": 5,
        "minimum": 1,
        "x-kinds": [
          "camera",
          "nvr"
        ]
      },
      "batteryCamera": {
        "title": "Battery camera without a hub",
        "type": "boolean",
        "description": "Experimental: a battery camera on its own Wi-Fi, without a Home Hub or NVR. It is reached over Reolink's own protocol (TCP 9000) only when HomeKit asks for video or a snapshot, so it can sleep. Setup turns this on when it finds one.",
        "x-kinds": [
          "camera"
        ]
      },
      "takeOverEventPush": {
        "title": "Take over event push",
        "type": "boolean",
        "description": "A battery camera sends its events to one receiver only. On: the bridge takes the place of another receiver (Home Assistant's, say). Off: the other receiver keeps it, and the camera's motion and doorbell presses do not reach HomeKit.",
        "x-kinds": [
          "camera"
        ]
      },
      "motionSensor": {
        "title": "Motion sensor",
        "type": "boolean",
        "description": "A motion sensor, which also starts HomeKit Secure Video recordings.",
        "default": true,
        "x-kinds": [
          "camera"
        ]
      },
      "aiSensors": {
        "title": "Detection sensors",
        "type": "array",
        "description": "A motion sensor for each kind of detection the camera makes; empty for every kind it supports.",
        "uniqueItems": true,
        "items": {
          "type": "string",
          "title": "Detection",
          "description": "A kind of detection.",
          "oneOf": [
            {
              "title": "Person",
              "enum": [
                "person"
              ]
            },
            {
              "title": "Vehicle",
              "enum": [
                "vehicle"
              ]
            },
            {
              "title": "Pet",
              "enum": [
                "pet"
              ]
            },
            {
              "title": "Face",
              "enum": [
                "face"
              ]
            },
            {
              "title": "Package",
              "enum": [
                "package"
              ]
            }
          ]
        },
        "x-kinds": [
          "camera"
        ]
      },
      "doorbell": {
        "title": "Doorbell",
        "type": "boolean",
        "description": "A doorbell button; unset when the device says it is a doorbell.",
        "x-kinds": [
          "camera"
        ]
      },
      "floodlight": {
        "title": "Floodlight",
        "type": "boolean",
        "description": "The floodlight or spotlight as a light.",
        "default": true,
        "x-kinds": [
          "camera"
        ]
      },
      "siren": {
        "title": "Siren",
        "type": "boolean",
        "description": "The siren as a switch (off by default: a siren in an automation is loud). It turns itself off after a minute.",
        "default": false,
        "x-kinds": [
          "camera"
        ]
      },
      "irLights": {
        "title": "Infrared switch",
        "type": "boolean",
        "description": "A switch for the IR lights: on is automatic, off is off.",
        "default": false,
        "x-kinds": [
          "camera"
        ]
      },
      "stream": {
        "title": "Stream",
        "type": "string",
        "description": "Which of the camera's streams answers HomeKit.",
        "default": "auto",
        "oneOf": [
          {
            "title": "Automatic: the sub stream for small sizes",
            "enum": [
              "auto"
            ]
          },
          {
            "title": "Main stream",
            "enum": [
              "main"
            ]
          },
          {
            "title": "Sub stream",
            "enum": [
              "sub"
            ]
          }
        ],
        "x-kinds": [
          "camera"
        ]
      },
      "audio": {
        "title": "Audio",
        "type": "boolean",
        "description": "The camera's sound in live streams.",
        "default": false,
        "x-kinds": [
          "camera"
        ]
      },
      "twoWayAudio": {
        "title": "Two-way audio",
        "type": "boolean",
        "description": "Experimental: talk through the camera's speaker from the Home app. Only where the camera says it can, and with Push events on. Not yet tried on a Reolink device.",
        "default": false,
        "x-kinds": [
          "camera"
        ]
      },
      "recording": {
        "title": "HomeKit Secure Video",
        "type": "boolean",
        "description": "Recordings in iCloud when motion is seen (needs a home hub and an iCloud plan).",
        "default": false,
        "x-kinds": [
          "camera"
        ]
      },
      "prebuffer": {
        "title": "Prebuffer",
        "type": "boolean",
        "description": "Keeps the last seconds of video so recordings start before the motion (one stream always open).",
        "default": false,
        "x-kinds": [
          "camera"
        ]
      },
      "maxStreams": {
        "title": "Simultaneous streams",
        "type": "integer",
        "description": "How many HomeKit viewers may watch at once.",
        "placeholder": 2,
        "minimum": 1,
        "maximum": 4,
        "x-kinds": [
          "camera"
        ]
      },
      "vcodec": {
        "title": "Video encoding",
        "type": "string",
        "description": "Copy sends an H.264 stream as it is (light on the bridge); otherwise the video is encoded as HomeKit asks. H.265 is always encoded.",
        "default": "libx264",
        "oneOf": [
          {
            "title": "Encode",
            "enum": [
              "libx264"
            ]
          },
          {
            "title": "Copy",
            "enum": [
              "copy"
            ]
          }
        ],
        "x-kinds": [
          "camera"
        ]
      },
      "encoderOptions": {
        "title": "Encoder options",
        "type": "string",
        "description": "Extra FFmpeg options for the encoder, separated by spaces.",
        "x-kinds": [
          "camera"
        ]
      },
      "debug": {
        "title": "FFmpeg debug",
        "type": "boolean",
        "description": "FFmpeg's verbose output in the log.",
        "default": false,
        "x-kinds": [
          "camera"
        ]
      },
      "ringThrottleSeconds": {
        "title": "Ring interval (seconds)",
        "type": "integer",
        "description": "Presses within this many seconds of a ring are ignored.",
        "placeholder": 3,
        "minimum": 0,
        "x-kinds": [
          "camera"
        ]
      },
      "motionTimeout": {
        "title": "Motion duration (seconds)",
        "type": "integer",
        "description": "How long a battery camera's motion stays on: it never says that motion stopped.",
        "placeholder": 30,
        "minimum": 5,
        "maximum": 3600,
        "x-kinds": [
          "camera"
        ]
      },
      "presetSwitches": {
        "title": "Preset switches",
        "type": "boolean",
        "description": "A switch per PTZ preset that turns the camera there, then turns itself off.",
        "default": false,
        "x-kinds": [
          "camera"
        ]
      },
      "patrolSwitch": {
        "title": "Patrol switch",
        "type": "boolean",
        "description": "A switch that runs the camera's first PTZ patrol, set up in the Reolink app.",
        "default": false,
        "x-kinds": [
          "camera"
        ]
      },
      "privacySwitch": {
        "title": "Privacy switch",
        "type": "boolean",
        "description": "Where the camera has privacy mode, a switch that turns it on: no video, no detections, until it is off. It follows HomeKit's camera on and off.",
        "default": true,
        "x-kinds": [
          "camera"
        ]
      },
      "floodlightMode": {
        "title": "Floodlight mode",
        "type": "string",
        "description": "What the floodlight does on its own, set on the camera at start; empty leaves the camera's. Only the modes the camera offers are taken.",
        "oneOf": [
          {
            "title": "Off",
            "enum": [
              "off"
            ]
          },
          {
            "title": "At night when there is motion",
            "enum": [
              "auto"
            ]
          },
          {
            "title": "On at night",
            "enum": [
              "night"
            ]
          },
          {
            "title": "On a schedule",
            "enum": [
              "schedule"
            ]
          },
          {
            "title": "Adaptive, at night when there is motion",
            "enum": [
              "autoAdaptive"
            ]
          },
          {
            "title": "Adaptive brightness",
            "enum": [
              "adaptive"
            ]
          }
        ],
        "x-kinds": [
          "camera"
        ]
      },
      "chimeSwitch": {
        "title": "Chime switches",
        "type": "boolean",
        "description": "A doorbell's switch per Reolink Chime paired to it, which plays the tone below, then turns itself off.",
        "default": false,
        "x-kinds": [
          "camera"
        ]
      },
      "chimeTone": {
        "title": "Chime tone",
        "type": "string",
        "description": "The tone the chime switches play.",
        "default": "citybird",
        "oneOf": [
          {
            "title": "City bird",
            "enum": [
              "citybird"
            ]
          },
          {
            "title": "Original tune",
            "enum": [
              "originaltune"
            ]
          },
          {
            "title": "Piano key",
            "enum": [
              "pianokey"
            ]
          },
          {
            "title": "Loop",
            "enum": [
              "loop"
            ]
          },
          {
            "title": "Attraction",
            "enum": [
              "attraction"
            ]
          },
          {
            "title": "Hop hop",
            "enum": [
              "hophop"
            ]
          },
          {
            "title": "Good day",
            "enum": [
              "goodday"
            ]
          },
          {
            "title": "Operetta",
            "enum": [
              "operetta"
            ]
          },
          {
            "title": "Moonlight",
            "enum": [
              "moonlight"
            ]
          },
          {
            "title": "Way back home",
            "enum": [
              "waybackhome"
            ]
          }
        ],
        "x-kinds": [
          "camera"
        ]
      },
      "recordingSwitch": {
        "title": "Recording switch",
        "type": "boolean",
        "description": "A switch for the camera's own recording to its SD card or the NVR's disk (not HomeKit Secure Video). Off, nothing is recorded there.",
        "default": false,
        "x-kinds": [
          "camera"
        ]
      },
      "motionSensitivity": {
        "title": "Motion sensitivity",
        "type": "integer",
        "description": "How readily the camera sees motion, from 1 (least) to 50 (most), set on the camera at start; empty leaves the camera's.",
        "minimum": 1,
        "maximum": 50,
        "x-kinds": [
          "camera"
        ]
      },
      "aiSensitivity": {
        "title": "Detection sensitivity",
        "type": "integer",
        "description": "How readily the camera detects people, vehicles and pets, from 0 to 100, for every kind it detects, set on the camera at start; empty leaves the camera's.",
        "minimum": 0,
        "maximum": 100,
        "x-kinds": [
          "camera"
        ]
      }
    }
  },
  "layout": [
    "name",
    {
      "type": "fieldset",
      "title": "Advanced",
      "expandable": true,
      "expanded": false,
      "items": [
        "videoProcessor",
        "webhookPort",
        "devices"
      ]
    },
    {
      "type": "fieldset",
      "title": "Sensors",
      "expandable": true,
      "expanded": false,
      "items": [
        "motionSensor",
        "aiSensors",
        "motionSensitivity",
        "aiSensitivity",
        "doorbell",
        "ringThrottleSeconds",
        "motionTimeout"
      ]
    },
    {
      "type": "fieldset",
      "title": "Lights and switches",
      "expandable": true,
      "expanded": false,
      "items": [
        "floodlight",
        "floodlightMode",
        "irLights",
        "siren",
        "privacySwitch",
        "recordingSwitch",
        "presetSwitches",
        "patrolSwitch",
        "chimeSwitch",
        "chimeTone"
      ]
    },
    {
      "type": "fieldset",
      "title": "Video",
      "expandable": true,
      "expanded": false,
      "items": [
        "stream",
        "audio",
        "twoWayAudio",
        "recording",
        "prebuffer",
        "maxStreams",
        "vcodec",
        "encoderOptions",
        "debug"
      ]
    },
    {
      "type": "fieldset",
      "title": "Connection",
      "expandable": true,
      "expanded": false,
      "items": [
        "host",
        "port",
        "useHttps",
        "baichuanPort",
        "channels",
        "streamProtocol",
        "pushEvents",
        "pollInterval",
        "motionPollInterval",
        "batteryCamera",
        "takeOverEventPush"
      ]
    }
  ],
  "i18n": {
    "fr": {
      "A channel number, from 0.": "Un numéro de canal, à partir de 0.",
      "A doorbell button; unset when the device says it is a doorbell.": "Un bouton de sonnette ; sans réglage, quand l'appareil se dit sonnette.",
      "A doorbell's switch per Reolink Chime paired to it, which plays the tone below, then turns itself off.": "Un interrupteur de la sonnette par Reolink Chime associé, qui joue la mélodie ci-dessous puis s'éteint seul.",
      "A kind of detection.": "Un type de détection.",
      "A local user of the device; an administrator can switch floodlights, sirens and IR lights.": "Un utilisateur local de l'appareil ; un administrateur peut commander projecteurs, sirènes et éclairage infrarouge.",
      "A motion sensor for each kind of detection the camera makes; empty for every kind it supports.": "Un détecteur de mouvement par type de détection de la caméra ; vide pour tous ceux qu'elle prend en charge.",
      "A motion sensor, which also starts HomeKit Secure Video recordings.": "Un détecteur de mouvement, qui déclenche aussi les enregistrements HomeKit Secure Video.",
      "A switch for the IR lights: on is automatic, off is off.": "Un interrupteur de l'éclairage infrarouge : allumé est automatique, éteint est éteint.",
      "A switch for the camera's own recording to its SD card or the NVR's disk (not HomeKit Secure Video). Off, nothing is recorded there.": "Un interrupteur pour l'enregistrement propre de la caméra, sur sa carte SD ou le disque du NVR (pas HomeKit Secure Video). Éteint, rien n'y est enregistré.",
      "A switch per PTZ preset that turns the camera there, then turns itself off.": "Un interrupteur par position PTZ enregistrée, qui y tourne la caméra puis s'éteint seul.",
      "A switch that runs the camera's first PTZ patrol, set up in the Reolink app.": "Un interrupteur qui lance la première patrouille PTZ de la caméra, définie dans l'app Reolink.",
      "API port": "Port de l'API",
      "Adaptive brightness": "Luminosité adaptative",
      "Adaptive, at night when there is motion": "Adaptatif, la nuit en cas de mouvement",
      "Address": "Adresse",
      "Advanced": "Avancé",
      "An NVR's or a hub's channels to publish, counted from 0; empty for every online channel.": "Les canaux d'un NVR ou d'un hub à publier, comptés à partir de 0 ; vide pour tous les canaux en ligne.",
      "At night when there is motion": "La nuit, en cas de mouvement",
      "Attraction": "Attraction",
      "Audio": "Audio",
      "Automatic: the sub stream for small sizes": "Automatique : le flux secondaire pour les petites tailles",
      "Baichuan port": "Port Baichuan",
      "Camera": "Caméra",
      "Cameras": "Caméras",
      "Channel": "Canal",
      "Channels": "Canaux",
      "Chime switches": "Interrupteurs de carillon",
      "Chime tone": "Mélodie du carillon",
      "City bird": "Oiseau des villes",
      "Copy": "Copier",
      "Copy sends an H.264 stream as it is (light on the bridge); otherwise the video is encoded as HomeKit asks. H.265 is always encoded.": "Copier envoie un flux H.264 tel quel (léger pour le pont) ; sinon la vidéo est encodée comme HomeKit le demande. Le H.265 est toujours encodé.",
      "Detection": "Détection",
      "Detection sensitivity": "Sensibilité des détections",
      "Detection sensors": "Détecteurs de reconnaissance",
      "Device": "Appareil",
      "Devices": "Appareils",
      "Doorbell": "Sonnette",
      "Encode": "Encoder",
      "Encoder options": "Options de l'encodeur",
      "Extra FFmpeg options for the encoder, separated by spaces.": "Options FFmpeg supplémentaires pour l'encodeur, séparées par des espaces.",
      "FFmpeg debug": "Débogage FFmpeg",
      "FFmpeg executable": "Exécutable FFmpeg",
      "FFmpeg's verbose output in the log.": "La sortie détaillée de FFmpeg dans le journal.",
      "FLV": "FLV",
      "Face": "Visage",
      "Floodlight": "Projecteur",
      "Floodlight mode": "Mode du projecteur",
      "Force HTTPS or HTTP; unset tries both. The device's certificate is trusted the first time and pinned.": "Impose HTTPS ou HTTP ; sans réglage, les deux sont essayés. Le certificat de l'appareil est accepté la première fois puis épinglé.",
      "Good day": "Bonne journée",
      "HomeKit Secure Video": "HomeKit Secure Video",
      "Hop hop": "Hop hop",
      "How FFmpeg reads the video.": "Comment FFmpeg lit la vidéo.",
      "How many HomeKit viewers may watch at once.": "Combien de spectateurs HomeKit peuvent regarder à la fois.",
      "How often motion is asked for while push events are not active.": "La fréquence d'interrogation des mouvements tant que les événements poussés ne sont pas actifs.",
      "How often the lights, battery and channel list are read. Empty: 60 seconds, 10 more per camera above six.": "La fréquence de lecture des lumières, de la batterie et des canaux. Vide : 60 secondes, 10 de plus par caméra au-delà de six.",
      "How readily the camera detects people, vehicles and pets, from 0 to 100, for every kind it detects, set on the camera at start; empty leaves the camera's.": "La facilité avec laquelle la caméra détecte personnes, véhicules et animaux, de 0 à 100, pour chaque type qu'elle détecte, réglée sur la caméra au démarrage ; vide garde celle de la caméra.",
      "How readily the camera sees motion, from 1 (least) to 50 (most), set on the camera at start; empty leaves the camera's.": "La facilité avec laquelle la caméra voit un mouvement, de 1 (le moins) à 50 (le plus), réglée sur la caméra au démarrage ; vide garde celle de la caméra.",
      "Infrared switch": "Interrupteur infrarouge",
      "Keeps the last seconds of video so recordings start before the motion (one stream always open).": "Garde les dernières secondes de vidéo pour que les enregistrements commencent avant le mouvement (un flux toujours ouvert).",
      "Loop": "Boucle",
      "Main stream": "Flux principal",
      "Moonlight": "Clair de lune",
      "Motion polling interval (seconds)": "Intervalle d'interrogation des mouvements (secondes)",
      "Motion sensitivity": "Sensibilité au mouvement",
      "Motion sensor": "Détecteur de mouvement",
      "Motion, detections and rings pushed by the device; off polls them every few seconds instead.": "Mouvements, détections et sonneries poussés par l'appareil ; désactivé, ils sont interrogés toutes les quelques secondes.",
      "Name": "Nom",
      "Off": "Éteint",
      "On a schedule": "Selon un horaire",
      "On at night": "Allumé la nuit",
      "Operetta": "Opérette",
      "Options by channel number (\"0\", \"1\"…); once saved they move to each camera's settings.": "Options par numéro de canal (« 0 », « 1 »…) ; une fois enregistrées, elles passent dans les réglages de chaque caméra.",
      "Original tune": "Mélodie d'origine",
      "Package": "Colis",
      "Password": "Mot de passe",
      "Patrol switch": "Interrupteur de patrouille",
      "Person": "Personne",
      "Pet": "Animal",
      "Piano key": "Touche de piano",
      "Prebuffer": "Prémémoire",
      "Preset switches": "Interrupteurs de positions",
      "Presses within this many seconds of a ring are ignored.": "Les appuis dans ce nombre de secondes après une sonnerie sont ignorés.",
      "Privacy switch": "Interrupteur de confidentialité",
      "Push events": "Événements poussés",
      "RTMP": "RTMP",
      "RTSP (recommended)": "RTSP (recommandé)",
      "Recording switch": "Interrupteur d'enregistrement",
      "Recordings in iCloud when motion is seen (needs a home hub and an iCloud plan).": "Des enregistrements dans iCloud quand un mouvement est vu (il faut un concentrateur et un forfait iCloud).",
      "Refresh interval (seconds)": "Intervalle d'actualisation (secondes)",
      "Reolink cameras, doorbells, NVRs and Home Hubs by address. Add accessories sets them up without editing this list.": "Caméras, sonnettes, NVR et Home Hubs Reolink par adresse. Ajouter des accessoires les configure sans modifier cette liste.",
      "Reolink cameras, doorbells, NVRs and Home Hubs on the local network. Add them on Add accessories with their address and a local user.": "Caméras, sonnettes, NVR et Home Hubs Reolink du réseau local. Ajoutez-les dans Ajouter des accessoires avec leur adresse et un utilisateur local.",
      "Ring interval (seconds)": "Intervalle entre sonneries (secondes)",
      "Simultaneous streams": "Flux simultanés",
      "Siren": "Sirène",
      "Stream": "Flux",
      "Stream protocol": "Protocole des flux",
      "Sub stream": "Flux secondaire",
      "The FFmpeg that streams and records the cameras: a path, or a name in PATH.": "Le FFmpeg qui diffuse et enregistre les caméras : un chemin, ou un nom dans le PATH.",
      "The HTTP(S) API's port. Empty: HTTPS on 443, then HTTP on 80.": "Le port de l'API HTTP(S). Vide : HTTPS sur 443, puis HTTP sur 80.",
      "The IP address or host name of the camera, doorbell, NVR or Home Hub.": "L'adresse IP ou le nom d'hôte de la caméra, de la sonnette, du NVR ou du Home Hub.",
      "The TCP port of the device's push events (Baichuan).": "Le port TCP des événements poussés par l'appareil (Baichuan).",
      "The camera's name; empty for the one the device gives.": "Le nom de la caméra ; vide pour celui que donne l'appareil.",
      "The camera's sound in live streams.": "Le son de la caméra dans les flux en direct.",
      "The floodlight or spotlight as a light.": "Le projecteur comme une lampe.",
      "The name of the plugin in the log.": "Le nom du plugin dans le journal.",
      "The siren as a switch (off by default: a siren in an automation is loud). It turns itself off after a minute.": "La sirène comme interrupteur (désactivée par défaut : une sirène dans une automatisation est bruyante). Il s'éteint seul après une minute.",
      "The tone the chime switches play.": "La mélodie que jouent les interrupteurs de carillon.",
      "Use HTTPS": "Utiliser HTTPS",
      "User name": "Nom d'utilisateur",
      "Vehicle": "Véhicule",
      "Video encoding": "Encodage vidéo",
      "Way back home": "Retour à la maison",
      "What the floodlight does on its own, set on the camera at start; empty leaves the camera's. Only the modes the camera offers are taken.": "Ce que fait le projecteur de lui-même, réglé sur la caméra au démarrage ; vide garde celui de la caméra. Seuls les modes que la caméra propose sont pris.",
      "Where the camera has privacy mode, a switch that turns it on: no video, no detections, until it is off. It follows HomeKit's camera on and off.": "Si la caméra a un mode confidentialité, un interrupteur qui l'active : ni vidéo ni détection tant qu'il est allumé. Il suit la caméra allumée ou éteinte dans HomeKit.",
      "Which of the camera's streams answers HomeKit.": "Lequel des flux de la caméra répond à HomeKit.",
      "Sensors": "Capteurs",
      "Lights and switches": "Lumières et interrupteurs",
      "Video": "Vidéo",
      "Connection": "Connexion",
      "Battery camera without a hub": "Caméra sur batterie sans hub",
      "Experimental: a battery camera on its own Wi-Fi, without a Home Hub or NVR. It is reached over Reolink's own protocol (TCP 9000) only when HomeKit asks for video or a snapshot, so it can sleep. Setup turns this on when it finds one.": "Expérimental : une caméra sur batterie sur son propre Wi-Fi, sans Home Hub ni NVR. Elle est jointe par le protocole de Reolink (TCP 9000) seulement quand HomeKit demande la vidéo ou une image, pour qu'elle puisse dormir. La configuration l'active quand elle en trouve une.",
      "Take over event push": "Reprendre l'envoi des événements",
      "A battery camera sends its events to one receiver only. On: the bridge takes the place of another receiver (Home Assistant's, say). Off: the other receiver keeps it, and the camera's motion and doorbell presses do not reach HomeKit.": "Une caméra sur batterie n'envoie ses événements qu'à un seul destinataire. Activé : le pont prend la place d'un autre destinataire (Home Assistant, par exemple). Désactivé : l'autre destinataire le garde, et les mouvements et appuis de sonnette de la caméra n'arrivent pas à HomeKit.",
      "Motion duration (seconds)": "Durée du mouvement (secondes)",
      "How long a battery camera's motion stays on: it never says that motion stopped.": "Combien de temps le mouvement d'une caméra sur batterie reste actif : elle ne dit jamais qu'il a cessé.",
      "Event port for battery cameras": "Port des événements des caméras sur batterie",
      "Battery cameras on their own sleep between uses, so they post their motion and doorbell presses to the bridge on this port: the cameras must be able to reach it (open it in a firewall). Empty: a port chosen once and kept.": "Les caméras sur batterie autonomes dorment entre deux utilisations : elles envoient donc leurs mouvements et leurs appuis de sonnette au pont sur ce port, que les caméras doivent pouvoir joindre (ouvrez-le dans un pare-feu). Vide : un port choisi une fois et conservé.",
      "Two-way audio": "Audio bidirectionnel",
      "Experimental: talk through the camera's speaker from the Home app. Only where the camera says it can, and with Push events on. Not yet tried on a Reolink device.": "Expérimental : parler dans le haut-parleur de la caméra depuis l'app Maison. Seulement là où la caméra dit le pouvoir, et avec Événements poussés activé. Pas encore essayé sur un appareil Reolink."
    },
    "es": {
      "A channel number, from 0.": "Un número de canal, desde 0.",
      "A doorbell button; unset when the device says it is a doorbell.": "Un botón de timbre; sin ajuste, cuando el dispositivo dice ser un timbre.",
      "A doorbell's switch per Reolink Chime paired to it, which plays the tone below, then turns itself off.": "Un interruptor del timbre por cada Reolink Chime emparejado, que reproduce la melodía de abajo y luego se apaga solo.",
      "A kind of detection.": "Un tipo de detección.",
      "A local user of the device; an administrator can switch floodlights, sirens and IR lights.": "Un usuario local del dispositivo; un administrador puede controlar focos, sirenas e infrarrojos.",
      "A motion sensor for each kind of detection the camera makes; empty for every kind it supports.": "Un sensor de movimiento por tipo de detección de la cámara; vacío para todos los que admite.",
      "A motion sensor, which also starts HomeKit Secure Video recordings.": "Un sensor de movimiento, que también inicia las grabaciones de HomeKit Secure Video.",
      "A switch for the IR lights: on is automatic, off is off.": "Un interruptor de los infrarrojos: encendido es automático, apagado es apagado.",
      "A switch for the camera's own recording to its SD card or the NVR's disk (not HomeKit Secure Video). Off, nothing is recorded there.": "Un interruptor para la grabación propia de la cámara en su tarjeta SD o en el disco del NVR (no HomeKit Secure Video). Apagado, no se graba nada allí.",
      "A switch per PTZ preset that turns the camera there, then turns itself off.": "Un interruptor por posición PTZ guardada, que gira la cámara hacia ella y luego se apaga solo.",
      "A switch that runs the camera's first PTZ patrol, set up in the Reolink app.": "Un interruptor que inicia la primera patrulla PTZ de la cámara, definida en la app Reolink.",
      "API port": "Puerto de la API",
      "Adaptive brightness": "Brillo adaptativo",
      "Adaptive, at night when there is motion": "Adaptativo, de noche si hay movimiento",
      "Address": "Dirección",
      "Advanced": "Avanzado",
      "An NVR's or a hub's channels to publish, counted from 0; empty for every online channel.": "Los canales de un NVR o un hub que publicar, contados desde 0; vacío para todos los canales en línea.",
      "At night when there is motion": "De noche, si hay movimiento",
      "Attraction": "Atracción",
      "Audio": "Audio",
      "Automatic: the sub stream for small sizes": "Automático: el flujo secundario para tamaños pequeños",
      "Baichuan port": "Puerto Baichuan",
      "Camera": "Cámara",
      "Cameras": "Cámaras",
      "Channel": "Canal",
      "Channels": "Canales",
      "Chime switches": "Interruptores de timbre",
      "Chime tone": "Melodía del timbre",
      "City bird": "Pájaro urbano",
      "Copy": "Copiar",
      "Copy sends an H.264 stream as it is (light on the bridge); otherwise the video is encoded as HomeKit asks. H.265 is always encoded.": "Copiar envía un flujo H.264 tal cual (ligero para el puente); si no, el vídeo se codifica como pide HomeKit. El H.265 siempre se codifica.",
      "Detection": "Detección",
      "Detection sensitivity": "Sensibilidad de las detecciones",
      "Detection sensors": "Sensores de detección",
      "Device": "Dispositivo",
      "Devices": "Dispositivos",
      "Doorbell": "Timbre",
      "Encode": "Codificar",
      "Encoder options": "Opciones del codificador",
      "Extra FFmpeg options for the encoder, separated by spaces.": "Opciones adicionales de FFmpeg para el codificador, separadas por espacios.",
      "FFmpeg debug": "Depuración de FFmpeg",
      "FFmpeg executable": "Ejecutable de FFmpeg",
      "FFmpeg's verbose output in the log.": "La salida detallada de FFmpeg en el registro.",
      "FLV": "FLV",
      "Face": "Cara",
      "Floodlight": "Foco",
      "Floodlight mode": "Modo del foco",
      "Force HTTPS or HTTP; unset tries both. The device's certificate is trusted the first time and pinned.": "Fuerza HTTPS o HTTP; sin ajuste se prueban ambos. El certificado del dispositivo se acepta la primera vez y se fija.",
      "Good day": "Buen día",
      "HomeKit Secure Video": "HomeKit Secure Video",
      "Hop hop": "Hop hop",
      "How FFmpeg reads the video.": "Cómo lee FFmpeg el vídeo.",
      "How many HomeKit viewers may watch at once.": "Cuántos espectadores de HomeKit pueden mirar a la vez.",
      "How often motion is asked for while push events are not active.": "Cada cuánto se consulta el movimiento mientras los eventos enviados no están activos.",
      "How often the lights, battery and channel list are read. Empty: 60 seconds, 10 more per camera above six.": "Cada cuánto se leen las luces, la batería y los canales. Vacío: 60 segundos, 10 más por cámara a partir de seis.",
      "How readily the camera detects people, vehicles and pets, from 0 to 100, for every kind it detects, set on the camera at start; empty leaves the camera's.": "Con qué facilidad la cámara detecta personas, vehículos y mascotas, de 0 a 100, para cada tipo que detecta, ajustada en la cámara al arrancar; vacío deja la de la cámara.",
      "How readily the camera sees motion, from 1 (least) to 50 (most), set on the camera at start; empty leaves the camera's.": "Con qué facilidad la cámara ve movimiento, de 1 (menos) a 50 (más), ajustada en la cámara al arrancar; vacío deja la de la cámara.",
      "Infrared switch": "Interruptor de infrarrojos",
      "Keeps the last seconds of video so recordings start before the motion (one stream always open).": "Guarda los últimos segundos de vídeo para que las grabaciones empiecen antes del movimiento (un flujo siempre abierto).",
      "Loop": "Bucle",
      "Main stream": "Flujo principal",
      "Moonlight": "Luz de luna",
      "Motion polling interval (seconds)": "Intervalo de consulta de movimiento (segundos)",
      "Motion sensitivity": "Sensibilidad al movimiento",
      "Motion sensor": "Sensor de movimiento",
      "Motion, detections and rings pushed by the device; off polls them every few seconds instead.": "Movimiento, detecciones y timbres enviados por el dispositivo; desactivado, se consultan cada pocos segundos.",
      "Name": "Nombre",
      "Off": "Apagado",
      "On a schedule": "Según un horario",
      "On at night": "Encendido de noche",
      "Operetta": "Opereta",
      "Options by channel number (\"0\", \"1\"…); once saved they move to each camera's settings.": "Opciones por número de canal («0», «1»…); una vez guardadas pasan a los ajustes de cada cámara.",
      "Original tune": "Melodía original",
      "Package": "Paquete",
      "Password": "Contraseña",
      "Patrol switch": "Interruptor de patrulla",
      "Person": "Persona",
      "Pet": "Mascota",
      "Piano key": "Tecla de piano",
      "Prebuffer": "Prebúfer",
      "Preset switches": "Interruptores de posiciones",
      "Presses within this many seconds of a ring are ignored.": "Las pulsaciones en estos segundos tras un timbre se ignoran.",
      "Privacy switch": "Interruptor de privacidad",
      "Push events": "Eventos enviados",
      "RTMP": "RTMP",
      "RTSP (recommended)": "RTSP (recomendado)",
      "Recording switch": "Interruptor de grabación",
      "Recordings in iCloud when motion is seen (needs a home hub and an iCloud plan).": "Grabaciones en iCloud cuando se ve movimiento (necesita un concentrador y un plan de iCloud).",
      "Refresh interval (seconds)": "Intervalo de actualización (segundos)",
      "Reolink cameras, doorbells, NVRs and Home Hubs by address. Add accessories sets them up without editing this list.": "Cámaras, timbres, NVR y Home Hubs de Reolink por dirección. Añadir accesorios los configura sin editar esta lista.",
      "Reolink cameras, doorbells, NVRs and Home Hubs on the local network. Add them on Add accessories with their address and a local user.": "Cámaras, timbres, NVR y Home Hubs de Reolink de la red local. Añádalos en Añadir accesorios con su dirección y un usuario local.",
      "Ring interval (seconds)": "Intervalo entre timbres (segundos)",
      "Simultaneous streams": "Flujos simultáneos",
      "Siren": "Sirena",
      "Stream": "Flujo",
      "Stream protocol": "Protocolo de flujo",
      "Sub stream": "Flujo secundario",
      "The FFmpeg that streams and records the cameras: a path, or a name in PATH.": "El FFmpeg que transmite y graba las cámaras: una ruta, o un nombre del PATH.",
      "The HTTP(S) API's port. Empty: HTTPS on 443, then HTTP on 80.": "El puerto de la API HTTP(S). Vacío: HTTPS en 443 y luego HTTP en 80.",
      "The IP address or host name of the camera, doorbell, NVR or Home Hub.": "La dirección IP o el nombre de host de la cámara, el timbre, el NVR o el Home Hub.",
      "The TCP port of the device's push events (Baichuan).": "El puerto TCP de los eventos que envía el dispositivo (Baichuan).",
      "The camera's name; empty for the one the device gives.": "El nombre de la cámara; vacío para el que da el dispositivo.",
      "The camera's sound in live streams.": "El sonido de la cámara en los flujos en directo.",
      "The floodlight or spotlight as a light.": "El foco como una luz.",
      "The name of the plugin in the log.": "El nombre del plugin en el registro.",
      "The siren as a switch (off by default: a siren in an automation is loud). It turns itself off after a minute.": "La sirena como interruptor (desactivada por defecto: una sirena en una automatización hace ruido). Se apaga sola al cabo de un minuto.",
      "The tone the chime switches play.": "La melodía que reproducen los interruptores de timbre.",
      "Use HTTPS": "Usar HTTPS",
      "User name": "Nombre de usuario",
      "Vehicle": "Vehículo",
      "Video encoding": "Codificación de vídeo",
      "Way back home": "De vuelta a casa",
      "What the floodlight does on its own, set on the camera at start; empty leaves the camera's. Only the modes the camera offers are taken.": "Lo que hace el foco por sí solo, ajustado en la cámara al arrancar; vacío deja el de la cámara. Solo se aceptan los modos que ofrece la cámara.",
      "Where the camera has privacy mode, a switch that turns it on: no video, no detections, until it is off. It follows HomeKit's camera on and off.": "Si la cámara tiene modo de privacidad, un interruptor que lo activa: sin vídeo ni detecciones mientras esté encendido. Sigue el encendido y apagado de la cámara en HomeKit.",
      "Which of the camera's streams answers HomeKit.": "Qué flujo de la cámara responde a HomeKit.",
      "Sensors": "Sensores",
      "Lights and switches": "Luces e interruptores",
      "Video": "Vídeo",
      "Connection": "Conexión",
      "Battery camera without a hub": "Cámara de batería sin hub",
      "Experimental: a battery camera on its own Wi-Fi, without a Home Hub or NVR. It is reached over Reolink's own protocol (TCP 9000) only when HomeKit asks for video or a snapshot, so it can sleep. Setup turns this on when it finds one.": "Experimental: una cámara de batería en su propia Wi-Fi, sin Home Hub ni NVR. Se le llega por el protocolo propio de Reolink (TCP 9000) solo cuando HomeKit pide vídeo o una imagen, para que pueda dormir. La configuración lo activa cuando encuentra una.",
      "Take over event push": "Tomar el envío de eventos",
      "A battery camera sends its events to one receiver only. On: the bridge takes the place of another receiver (Home Assistant's, say). Off: the other receiver keeps it, and the camera's motion and doorbell presses do not reach HomeKit.": "Una cámara de batería envía sus eventos a un solo destinatario. Activado: el puente ocupa el lugar de otro destinatario (Home Assistant, por ejemplo). Desactivado: el otro destinatario lo conserva, y los movimientos y pulsaciones del timbre de la cámara no llegan a HomeKit.",
      "Motion duration (seconds)": "Duración del movimiento (segundos)",
      "How long a battery camera's motion stays on: it never says that motion stopped.": "Cuánto tiempo sigue activo el movimiento de una cámara de batería: nunca dice que ha terminado.",
      "Event port for battery cameras": "Puerto de eventos de las cámaras de batería",
      "Battery cameras on their own sleep between uses, so they post their motion and doorbell presses to the bridge on this port: the cameras must be able to reach it (open it in a firewall). Empty: a port chosen once and kept.": "Las cámaras de batería independientes duermen entre usos, así que envían sus movimientos y pulsaciones del timbre al puente en este puerto: las cámaras deben poder alcanzarlo (ábralo en un cortafuegos). Vacío: un puerto elegido una vez y conservado.",
      "Two-way audio": "Audio bidireccional",
      "Experimental: talk through the camera's speaker from the Home app. Only where the camera says it can, and with Push events on. Not yet tried on a Reolink device.": "Experimental: hablar por el altavoz de la cámara desde la app Casa. Solo donde la cámara dice que puede, y con Eventos enviados activado. Aún no probado en un dispositivo Reolink."
    },
    "pt": {
      "A channel number, from 0.": "Um número de canal, a partir de 0.",
      "A doorbell button; unset when the device says it is a doorbell.": "Um botão de campainha; sem definição, quando o dispositivo diz ser uma campainha.",
      "A doorbell's switch per Reolink Chime paired to it, which plays the tone below, then turns itself off.": "Um interruptor da campainha por cada Reolink Chime emparelhado, que toca a melodia abaixo e depois se desliga sozinho.",
      "A kind of detection.": "Um tipo de deteção.",
      "A local user of the device; an administrator can switch floodlights, sirens and IR lights.": "Um utilizador local do dispositivo; um administrador pode controlar projetores, sirenes e infravermelhos.",
      "A motion sensor for each kind of detection the camera makes; empty for every kind it supports.": "Um sensor de movimento por tipo de deteção da câmara; vazio para todos os que suporta.",
      "A motion sensor, which also starts HomeKit Secure Video recordings.": "Um sensor de movimento, que também inicia as gravações do HomeKit Secure Video.",
      "A switch for the IR lights: on is automatic, off is off.": "Um interruptor dos infravermelhos: ligado é automático, desligado é desligado.",
      "A switch for the camera's own recording to its SD card or the NVR's disk (not HomeKit Secure Video). Off, nothing is recorded there.": "Um interruptor para a gravação própria da câmara no seu cartão SD ou no disco do NVR (não HomeKit Secure Video). Desligado, nada é gravado aí.",
      "A switch per PTZ preset that turns the camera there, then turns itself off.": "Um interruptor por posição PTZ guardada, que vira a câmara para ela e depois se desliga sozinho.",
      "A switch that runs the camera's first PTZ patrol, set up in the Reolink app.": "Um interruptor que inicia a primeira patrulha PTZ da câmara, definida na app Reolink.",
      "API port": "Porta da API",
      "Adaptive brightness": "Brilho adaptativo",
      "Adaptive, at night when there is motion": "Adaptativo, à noite quando há movimento",
      "Address": "Endereço",
      "Advanced": "Avançado",
      "An NVR's or a hub's channels to publish, counted from 0; empty for every online channel.": "Os canais de um NVR ou hub a publicar, contados a partir de 0; vazio para todos os canais em linha.",
      "At night when there is motion": "À noite, quando há movimento",
      "Attraction": "Atração",
      "Audio": "Áudio",
      "Automatic: the sub stream for small sizes": "Automático: o fluxo secundário para tamanhos pequenos",
      "Baichuan port": "Porta Baichuan",
      "Camera": "Câmara",
      "Cameras": "Câmaras",
      "Channel": "Canal",
      "Channels": "Canais",
      "Chime switches": "Interruptores de campainha",
      "Chime tone": "Melodia da campainha",
      "City bird": "Pássaro da cidade",
      "Copy": "Copiar",
      "Copy sends an H.264 stream as it is (light on the bridge); otherwise the video is encoded as HomeKit asks. H.265 is always encoded.": "Copiar envia um fluxo H.264 tal como está (leve para a ponte); caso contrário o vídeo é codificado como o HomeKit pede. O H.265 é sempre codificado.",
      "Detection": "Deteção",
      "Detection sensitivity": "Sensibilidade das deteções",
      "Detection sensors": "Sensores de deteção",
      "Device": "Dispositivo",
      "Devices": "Dispositivos",
      "Doorbell": "Campainha",
      "Encode": "Codificar",
      "Encoder options": "Opções do codificador",
      "Extra FFmpeg options for the encoder, separated by spaces.": "Opções adicionais do FFmpeg para o codificador, separadas por espaços.",
      "FFmpeg debug": "Depuração do FFmpeg",
      "FFmpeg executable": "Executável do FFmpeg",
      "FFmpeg's verbose output in the log.": "A saída detalhada do FFmpeg no registo.",
      "FLV": "FLV",
      "Face": "Rosto",
      "Floodlight": "Projetor",
      "Floodlight mode": "Modo do projetor",
      "Force HTTPS or HTTP; unset tries both. The device's certificate is trusted the first time and pinned.": "Força HTTPS ou HTTP; sem definição, tenta os dois. O certificado do dispositivo é aceite da primeira vez e fixado.",
      "Good day": "Bom dia",
      "HomeKit Secure Video": "HomeKit Secure Video",
      "Hop hop": "Hop hop",
      "How FFmpeg reads the video.": "Como o FFmpeg lê o vídeo.",
      "How many HomeKit viewers may watch at once.": "Quantos espectadores do HomeKit podem ver ao mesmo tempo.",
      "How often motion is asked for while push events are not active.": "Com que frequência o movimento é consultado enquanto os eventos enviados não estão ativos.",
      "How often the lights, battery and channel list are read. Empty: 60 seconds, 10 more per camera above six.": "Com que frequência são lidas as luzes, a bateria e os canais. Vazio: 60 segundos, mais 10 por câmara acima de seis.",
      "How readily the camera detects people, vehicles and pets, from 0 to 100, for every kind it detects, set on the camera at start; empty leaves the camera's.": "A facilidade com que a câmara deteta pessoas, veículos e animais, de 0 a 100, para cada tipo que deteta, definida na câmara ao arrancar; vazio mantém a da câmara.",
      "How readily the camera sees motion, from 1 (least) to 50 (most), set on the camera at start; empty leaves the camera's.": "A facilidade com que a câmara vê movimento, de 1 (menos) a 50 (mais), definida na câmara ao arrancar; vazio mantém a da câmara.",
      "Infrared switch": "Interruptor de infravermelhos",
      "Keeps the last seconds of video so recordings start before the motion (one stream always open).": "Guarda os últimos segundos de vídeo para que as gravações comecem antes do movimento (um fluxo sempre aberto).",
      "Loop": "Ciclo",
      "Main stream": "Fluxo principal",
      "Moonlight": "Luar",
      "Motion polling interval (seconds)": "Intervalo de consulta de movimento (segundos)",
      "Motion sensitivity": "Sensibilidade ao movimento",
      "Motion sensor": "Sensor de movimento",
      "Motion, detections and rings pushed by the device; off polls them every few seconds instead.": "Movimento, deteções e toques enviados pelo dispositivo; desativado, são consultados de poucos em poucos segundos.",
      "Name": "Nome",
      "Off": "Desligado",
      "On a schedule": "Segundo um horário",
      "On at night": "Ligado à noite",
      "Operetta": "Opereta",
      "Options by channel number (\"0\", \"1\"…); once saved they move to each camera's settings.": "Opções por número de canal («0», «1»…); uma vez guardadas passam para as definições de cada câmara.",
      "Original tune": "Melodia original",
      "Package": "Encomenda",
      "Password": "Palavra-passe",
      "Patrol switch": "Interruptor de patrulha",
      "Person": "Pessoa",
      "Pet": "Animal",
      "Piano key": "Tecla de piano",
      "Prebuffer": "Pré-memória",
      "Preset switches": "Interruptores de posições",
      "Presses within this many seconds of a ring are ignored.": "Os toques nestes segundos após um toque são ignorados.",
      "Privacy switch": "Interruptor de privacidade",
      "Push events": "Eventos enviados",
      "RTMP": "RTMP",
      "RTSP (recommended)": "RTSP (recomendado)",
      "Recording switch": "Interruptor de gravação",
      "Recordings in iCloud when motion is seen (needs a home hub and an iCloud plan).": "Gravações no iCloud quando se vê movimento (precisa de um hub doméstico e de um plano iCloud).",
      "Refresh interval (seconds)": "Intervalo de atualização (segundos)",
      "Reolink cameras, doorbells, NVRs and Home Hubs by address. Add accessories sets them up without editing this list.": "Câmaras, campainhas, NVR e Home Hubs Reolink por endereço. Adicionar acessórios configura-os sem editar esta lista.",
      "Reolink cameras, doorbells, NVRs and Home Hubs on the local network. Add them on Add accessories with their address and a local user.": "Câmaras, campainhas, NVR e Home Hubs Reolink da rede local. Adicione-os em Adicionar acessórios com o seu endereço e um utilizador local.",
      "Ring interval (seconds)": "Intervalo entre toques (segundos)",
      "Simultaneous streams": "Fluxos simultâneos",
      "Siren": "Sirene",
      "Stream": "Fluxo",
      "Stream protocol": "Protocolo do fluxo",
      "Sub stream": "Fluxo secundário",
      "The FFmpeg that streams and records the cameras: a path, or a name in PATH.": "O FFmpeg que transmite e grava as câmaras: um caminho, ou um nome no PATH.",
      "The HTTP(S) API's port. Empty: HTTPS on 443, then HTTP on 80.": "A porta da API HTTP(S). Vazio: HTTPS na 443, depois HTTP na 80.",
      "The IP address or host name of the camera, doorbell, NVR or Home Hub.": "O endereço IP ou o nome de anfitrião da câmara, da campainha, do NVR ou do Home Hub.",
      "The TCP port of the device's push events (Baichuan).": "A porta TCP dos eventos enviados pelo dispositivo (Baichuan).",
      "The camera's name; empty for the one the device gives.": "O nome da câmara; vazio para o que o dispositivo dá.",
      "The camera's sound in live streams.": "O som da câmara nos fluxos em direto.",
      "The floodlight or spotlight as a light.": "O projetor como uma luz.",
      "The name of the plugin in the log.": "O nome do plugin no registo.",
      "The siren as a switch (off by default: a siren in an automation is loud). It turns itself off after a minute.": "A sirene como interruptor (desativada por omissão: uma sirene numa automatização é barulhenta). Desliga-se sozinho ao fim de um minuto.",
      "The tone the chime switches play.": "A melodia que os interruptores de campainha tocam.",
      "Use HTTPS": "Usar HTTPS",
      "User name": "Nome de utilizador",
      "Vehicle": "Veículo",
      "Video encoding": "Codificação de vídeo",
      "Way back home": "De volta a casa",
      "What the floodlight does on its own, set on the camera at start; empty leaves the camera's. Only the modes the camera offers are taken.": "O que o projetor faz sozinho, definido na câmara ao arrancar; vazio mantém o da câmara. Só são aceites os modos que a câmara oferece.",
      "Where the camera has privacy mode, a switch that turns it on: no video, no detections, until it is off. It follows HomeKit's camera on and off.": "Se a câmara tiver modo de privacidade, um interruptor que o ativa: sem vídeo nem deteções enquanto estiver ligado. Acompanha a câmara ligada ou desligada no HomeKit.",
      "Which of the camera's streams answers HomeKit.": "Qual dos fluxos da câmara responde ao HomeKit.",
      "Sensors": "Sensores",
      "Lights and switches": "Luzes e interruptores",
      "Video": "Vídeo",
      "Connection": "Ligação",
      "Battery camera without a hub": "Câmara de bateria sem hub",
      "Experimental: a battery camera on its own Wi-Fi, without a Home Hub or NVR. It is reached over Reolink's own protocol (TCP 9000) only when HomeKit asks for video or a snapshot, so it can sleep. Setup turns this on when it finds one.": "Experimental: uma câmara de bateria na sua própria Wi-Fi, sem Home Hub nem NVR. É contactada pelo protocolo da Reolink (TCP 9000) só quando o HomeKit pede vídeo ou uma imagem, para poder dormir. A configuração ativa-o quando encontra uma.",
      "Take over event push": "Assumir o envio de eventos",
      "A battery camera sends its events to one receiver only. On: the bridge takes the place of another receiver (Home Assistant's, say). Off: the other receiver keeps it, and the camera's motion and doorbell presses do not reach HomeKit.": "Uma câmara de bateria envia os eventos a um só destinatário. Ligado: a ponte ocupa o lugar de outro destinatário (o Home Assistant, por exemplo). Desligado: o outro destinatário mantém-no, e os movimentos e toques da campainha da câmara não chegam ao HomeKit.",
      "Motion duration (seconds)": "Duração do movimento (segundos)",
      "How long a battery camera's motion stays on: it never says that motion stopped.": "Quanto tempo o movimento de uma câmara de bateria fica ativo: nunca diz que terminou.",
      "Event port for battery cameras": "Porta de eventos das câmaras de bateria",
      "Battery cameras on their own sleep between uses, so they post their motion and doorbell presses to the bridge on this port: the cameras must be able to reach it (open it in a firewall). Empty: a port chosen once and kept.": "As câmaras de bateria autónomas dormem entre utilizações, por isso enviam os movimentos e os toques da campainha para a ponte nesta porta: as câmaras têm de a conseguir alcançar (abra-a numa firewall). Vazio: uma porta escolhida uma vez e mantida.",
      "Two-way audio": "Áudio bidirecional",
      "Experimental: talk through the camera's speaker from the Home app. Only where the camera says it can, and with Push events on. Not yet tried on a Reolink device.": "Experimental: falar pelo altifalante da câmara a partir da app Casa. Só onde a câmara diz que pode, e com Eventos enviados ligado. Ainda não experimentado num dispositivo Reolink."
    }
  }
}
"""#
}
