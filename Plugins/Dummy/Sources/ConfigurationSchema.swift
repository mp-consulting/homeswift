// THIS FILE IS GENERATED from ../config.schema.json by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

extension DummyPlugin {
    /// The plugin's config.schema.json, as written, for settings forms and the config copilot.
    public static let configurationSchemaJSON: String? = #"""
{
  "pluginAlias": "HomebridgeDummy",
  "pluginType": "platform",
  "singular": true,
  "schema": {
    "type": "object",
    "properties": {
      "name": {
        "title": "Name",
        "type": "string",
        "description": "Plugin name as shown in the logs",
        "required": true,
        "default": "Homebridge Dummy"
      },
      "verbose": {
        "title": "Verbose logging",
        "type": "boolean",
        "description": "Logs condition checks, webhook requests, history entries and reachability changes"
      },
      "webhookConfig": {
        "title": "Webhooks",
        "type": "object",
        "description": "The HTTP server that sets and reads the accessories that enable webhooks",
        "properties": {
          "port": {
            "title": "Port",
            "type": "integer",
            "description": "The webhook server's port (63743 when empty)",
            "minimum": 1,
            "maximum": 65535,
            "placeholder": 63743
          },
          "disableSSL": {
            "title": "Plain HTTP",
            "type": "boolean",
            "description": "Serve the webhooks over HTTP even when a key and a certificate are given"
          },
          "key": {
            "title": "Key file",
            "type": "string",
            "description": "Path of the PEM private key for HTTPS"
          },
          "cert": {
            "title": "Certificate file",
            "type": "string",
            "description": "Path of the PEM certificate for HTTPS"
          },
          "bindAddress": {
            "title": "Listen address",
            "type": "string",
            "description": "The address the webhook server listens on: 0.0.0.0 for every interface, 127.0.0.1 for this machine only",
            "placeholder": "0.0.0.0"
          }
        }
      },
      "accessories": {
        "title": "Accessories",
        "type": "array",
        "description": "The dummy accessories",
        "items": {
          "type": "object",
          "title": "Accessory",
          "properties": {
            "id": {
              "title": "Identifier",
              "type": "string",
              "description": "Keeps the accessory's identity; without one it comes from its type and name"
            },
            "name": {
              "title": "Name",
              "type": "string",
              "description": "The accessory's name",
              "required": true
            },
            "type": {
              "title": "Type",
              "type": "string",
              "description": "What the accessory is in HomeKit",
              "required": true,
              "oneOf": [
                {
                  "title": "Switch",
                  "enum": [
                    "Switch"
                  ]
                },
                {
                  "title": "Outlet",
                  "enum": [
                    "Outlet"
                  ]
                },
                {
                  "title": "Lightbulb",
                  "enum": [
                    "Lightbulb"
                  ]
                },
                {
                  "title": "Button",
                  "enum": [
                    "StatelessProgrammableSwitch"
                  ]
                },
                {
                  "title": "Lock",
                  "enum": [
                    "LockMechanism"
                  ]
                },
                {
                  "title": "Door",
                  "enum": [
                    "Door"
                  ]
                },
                {
                  "title": "Window",
                  "enum": [
                    "Window"
                  ]
                },
                {
                  "title": "Window covering",
                  "enum": [
                    "WindowCovering"
                  ]
                },
                {
                  "title": "Garage door",
                  "enum": [
                    "GarageDoorOpener"
                  ]
                },
                {
                  "title": "Valve",
                  "enum": [
                    "Valve"
                  ]
                },
                {
                  "title": "Humidifier or dehumidifier",
                  "enum": [
                    "HumidifierDehumidifier"
                  ]
                },
                {
                  "title": "Thermostat",
                  "enum": [
                    "Thermostat"
                  ]
                },
                {
                  "title": "Temperature sensor",
                  "enum": [
                    "TemperatureSensor"
                  ]
                },
                {
                  "title": "Humidity sensor",
                  "enum": [
                    "HumiditySensor"
                  ]
                },
                {
                  "title": "Carbon dioxide sensor",
                  "enum": [
                    "CarbonDioxideSensor"
                  ]
                },
                {
                  "title": "Carbon monoxide sensor",
                  "enum": [
                    "CarbonMonoxideSensor"
                  ]
                },
                {
                  "title": "Contact sensor",
                  "enum": [
                    "ContactSensor"
                  ]
                },
                {
                  "title": "Leak sensor",
                  "enum": [
                    "LeakSensor"
                  ]
                },
                {
                  "title": "Motion sensor",
                  "enum": [
                    "MotionSensor"
                  ]
                },
                {
                  "title": "Occupancy sensor",
                  "enum": [
                    "OccupancySensor"
                  ]
                },
                {
                  "title": "Smoke sensor",
                  "enum": [
                    "SmokeSensor"
                  ]
                }
              ]
            },
            "protocol": {
              "title": "Protocol",
              "type": "string",
              "description": "HomeKit, or Matter for a switch, an outlet or a light: Homeswift's Matter bridge shows it and it stays out of the Home app",
              "oneOf": [
                {
                  "title": "HomeKit",
                  "enum": [
                    "HomeKit"
                  ]
                },
                {
                  "title": "Matter",
                  "enum": [
                    "Matter"
                  ]
                }
              ]
            },
            "groupName": {
              "title": "Group",
              "type": "string",
              "description": "Accessories with the same group are services of one accessory"
            },
            "defaultState": {
              "title": "Default state",
              "type": "string",
              "description": "The state it rests in, and goes back to on a reset",
              "oneOf": [
                {
                  "title": "Off",
                  "enum": [
                    "off"
                  ]
                },
                {
                  "title": "On",
                  "enum": [
                    "on"
                  ]
                }
              ]
            },
            "isDimmer": {
              "title": "Dimmer",
              "type": "boolean",
              "description": "Gives the light a brightness"
            },
            "defaultLockState": {
              "title": "Default lock state",
              "type": "string",
              "description": "Locked or unlocked at rest",
              "oneOf": [
                {
                  "title": "Locked",
                  "enum": [
                    "locked"
                  ]
                },
                {
                  "title": "Unlocked",
                  "enum": [
                    "unlocked"
                  ]
                }
              ]
            },
            "defaultPosition": {
              "title": "Default position",
              "type": "string",
              "description": "Open or closed at rest",
              "oneOf": [
                {
                  "title": "Closed",
                  "enum": [
                    "closed"
                  ]
                },
                {
                  "title": "Open",
                  "enum": [
                    "open"
                  ]
                }
              ]
            },
            "exactPosition": {
              "title": "Exact position",
              "type": "boolean",
              "description": "Homeswift only: keeps the position set (0 to 100 %), as a real shutter does, rather than open or closed"
            },
            "temperatureUnits": {
              "title": "Temperature units",
              "type": "string",
              "description": "The unit of the temperatures here and in webhooks",
              "oneOf": [
                {
                  "title": "Celsius",
                  "enum": [
                    "C"
                  ]
                },
                {
                  "title": "Fahrenheit",
                  "enum": [
                    "F"
                  ]
                }
              ]
            },
            "defaultThermostatState": {
              "title": "Default mode",
              "type": "string",
              "description": "The thermostat's mode at first",
              "oneOf": [
                {
                  "title": "Off",
                  "enum": [
                    "off"
                  ]
                },
                {
                  "title": "Heat",
                  "enum": [
                    "heat"
                  ]
                },
                {
                  "title": "Cool",
                  "enum": [
                    "cool"
                  ]
                },
                {
                  "title": "Auto",
                  "enum": [
                    "auto"
                  ]
                }
              ]
            },
            "defaultTemperature": {
              "title": "Default temperature",
              "type": "number",
              "description": "The target temperature at first (20 °C when empty)"
            },
            "minimumTemperature": {
              "title": "Minimum temperature",
              "type": "number",
              "description": "The lowest temperature (10 °C when empty)"
            },
            "maximumTemperature": {
              "title": "Maximum temperature",
              "type": "number",
              "description": "The highest temperature (38 °C when empty)"
            },
            "validStates": {
              "title": "Modes",
              "type": "array",
              "description": "The modes the thermostat offers (all four when empty)",
              "uniqueItems": true,
              "items": {
                "type": "string",
                "oneOf": [
                  {
                    "title": "Off",
                    "enum": [
                      "off"
                    ]
                  },
                  {
                    "title": "Heat",
                    "enum": [
                      "heat"
                    ]
                  },
                  {
                    "title": "Cool",
                    "enum": [
                      "cool"
                    ]
                  },
                  {
                    "title": "Auto",
                    "enum": [
                      "auto"
                    ]
                  }
                ]
              }
            },
            "humidifierType": {
              "title": "Humidifier type",
              "type": "string",
              "description": "Whether it adds or removes humidity",
              "oneOf": [
                {
                  "title": "Humidifier",
                  "enum": [
                    "humidifier"
                  ]
                },
                {
                  "title": "Dehumidifier",
                  "enum": [
                    "dehumidifier"
                  ]
                }
              ]
            },
            "valveType": {
              "title": "Valve type",
              "type": "string",
              "description": "How the Home app shows the valve",
              "oneOf": [
                {
                  "title": "Generic",
                  "enum": [
                    "generic"
                  ]
                },
                {
                  "title": "Faucet",
                  "enum": [
                    "faucet"
                  ]
                },
                {
                  "title": "Irrigation",
                  "enum": [
                    "irrigation"
                  ]
                },
                {
                  "title": "Shower",
                  "enum": [
                    "shower"
                  ]
                }
              ]
            },
            "sensor": {
              "title": "Sensor",
              "type": "object",
              "description": "A sensor added to the accessory, active while it is not in its default state",
              "properties": {
                "type": {
                  "title": "Sensor type",
                  "type": "string",
                  "description": "What the added sensor is",
                  "oneOf": [
                    {
                      "title": "Carbon dioxide sensor",
                      "enum": [
                        "CarbonDioxideSensor"
                      ]
                    },
                    {
                      "title": "Carbon monoxide sensor",
                      "enum": [
                        "CarbonMonoxideSensor"
                      ]
                    },
                    {
                      "title": "Contact sensor",
                      "enum": [
                        "ContactSensor"
                      ]
                    },
                    {
                      "title": "Leak sensor",
                      "enum": [
                        "LeakSensor"
                      ]
                    },
                    {
                      "title": "Motion sensor",
                      "enum": [
                        "MotionSensor"
                      ]
                    },
                    {
                      "title": "Occupancy sensor",
                      "enum": [
                        "OccupancySensor"
                      ]
                    },
                    {
                      "title": "Smoke sensor",
                      "enum": [
                        "SmokeSensor"
                      ]
                    }
                  ]
                },
                "behavior": {
                  "title": "Behaviour",
                  "type": "string",
                  "description": "Mirror the accessory, or go active for a second when a timer or a condition resets it",
                  "oneOf": [
                    {
                      "title": "Mirror",
                      "enum": [
                        "MIRROR"
                      ]
                    },
                    {
                      "title": "Timer",
                      "enum": [
                        "TIMER"
                      ]
                    }
                  ]
                }
              }
            },
            "schedule": {
              "title": "Schedule",
              "type": "object",
              "description": "When to trigger it: put it in the state other than its default",
              "properties": {
                "type": {
                  "title": "Schedule type",
                  "type": "string",
                  "description": "A delay, a repeating interval, a cron expression or a time of the sun",
                  "oneOf": [
                    {
                      "title": "Timeout",
                      "enum": [
                        "TIMEOUT"
                      ]
                    },
                    {
                      "title": "Interval",
                      "enum": [
                        "INTERVAL"
                      ]
                    },
                    {
                      "title": "Cron",
                      "enum": [
                        "CRON"
                      ]
                    },
                    {
                      "title": "Sunrise",
                      "enum": [
                        "SUNRISE"
                      ]
                    },
                    {
                      "title": "Sunset",
                      "enum": [
                        "SUNSET"
                      ]
                    },
                    {
                      "title": "Dawn",
                      "enum": [
                        "DAWN"
                      ]
                    },
                    {
                      "title": "Dusk",
                      "enum": [
                        "DUSK"
                      ]
                    },
                    {
                      "title": "Golden hour",
                      "enum": [
                        "GOLDEN_HOUR"
                      ]
                    },
                    {
                      "title": "Night",
                      "enum": [
                        "NIGHT"
                      ]
                    }
                  ]
                },
                "time": {
                  "title": "Time",
                  "type": "integer",
                  "description": "How long, in the units below",
                  "minimum": 1
                },
                "units": {
                  "title": "Units",
                  "type": "string",
                  "description": "The unit of the time",
                  "oneOf": [
                    {
                      "title": "Milliseconds",
                      "enum": [
                        "MILLISECONDS"
                      ]
                    },
                    {
                      "title": "Seconds",
                      "enum": [
                        "SECONDS"
                      ]
                    },
                    {
                      "title": "Minutes",
                      "enum": [
                        "MINUTES"
                      ]
                    },
                    {
                      "title": "Hours",
                      "enum": [
                        "HOURS"
                      ]
                    }
                  ]
                },
                "random": {
                  "title": "Random",
                  "type": "boolean",
                  "description": "A random time up to the one given, drawn each time"
                },
                "cron": {
                  "title": "Cron",
                  "type": "string",
                  "description": "When a cron schedule fires: a preset, or Custom for the expression below",
                  "oneOf": [
                    {
                      "title": "Every second",
                      "enum": [
                        "@secondly"
                      ]
                    },
                    {
                      "title": "Every minute",
                      "enum": [
                        "@minutely"
                      ]
                    },
                    {
                      "title": "Every hour",
                      "enum": [
                        "@hourly"
                      ]
                    },
                    {
                      "title": "Every day at midnight",
                      "enum": [
                        "@daily"
                      ]
                    },
                    {
                      "title": "Every Sunday at midnight",
                      "enum": [
                        "@weekly"
                      ]
                    },
                    {
                      "title": "Weekdays at midnight",
                      "enum": [
                        "@weekdays"
                      ]
                    },
                    {
                      "title": "Weekends at midnight",
                      "enum": [
                        "@weekends"
                      ]
                    },
                    {
                      "title": "The 1st of each month",
                      "enum": [
                        "@monthly"
                      ]
                    },
                    {
                      "title": "Every 1 January",
                      "enum": [
                        "@yearly"
                      ]
                    },
                    {
                      "title": "Custom",
                      "enum": [
                        "CRON_CUSTOM"
                      ]
                    }
                  ]
                },
                "cronCustom": {
                  "title": "Cron expression",
                  "type": "string",
                  "description": "Five fields (minute hour day month weekday) or six with seconds first",
                  "placeholder": "0 7 * * 1-5"
                },
                "offset": {
                  "title": "Offset",
                  "type": "number",
                  "description": "Minutes added to the time of the sun; negative for earlier"
                },
                "latitude": {
                  "title": "Latitude",
                  "type": "number",
                  "description": "Where the sun is watched, in decimal degrees",
                  "minimum": -90,
                  "maximum": 90
                },
                "longitude": {
                  "title": "Longitude",
                  "type": "number",
                  "description": "Where the sun is watched, in decimal degrees",
                  "minimum": -180,
                  "maximum": 180
                }
              }
            },
            "autoReset": {
              "title": "Auto-reset",
              "type": "object",
              "description": "When to put it back in its default state",
              "properties": {
                "type": {
                  "title": "Schedule type",
                  "type": "string",
                  "description": "A delay, a repeating interval, a cron expression or a time of the sun",
                  "oneOf": [
                    {
                      "title": "Timeout",
                      "enum": [
                        "TIMEOUT"
                      ]
                    },
                    {
                      "title": "Interval",
                      "enum": [
                        "INTERVAL"
                      ]
                    },
                    {
                      "title": "Cron",
                      "enum": [
                        "CRON"
                      ]
                    },
                    {
                      "title": "Sunrise",
                      "enum": [
                        "SUNRISE"
                      ]
                    },
                    {
                      "title": "Sunset",
                      "enum": [
                        "SUNSET"
                      ]
                    },
                    {
                      "title": "Dawn",
                      "enum": [
                        "DAWN"
                      ]
                    },
                    {
                      "title": "Dusk",
                      "enum": [
                        "DUSK"
                      ]
                    },
                    {
                      "title": "Golden hour",
                      "enum": [
                        "GOLDEN_HOUR"
                      ]
                    },
                    {
                      "title": "Night",
                      "enum": [
                        "NIGHT"
                      ]
                    }
                  ]
                },
                "time": {
                  "title": "Time",
                  "type": "integer",
                  "description": "How long, in the units below",
                  "minimum": 1
                },
                "units": {
                  "title": "Units",
                  "type": "string",
                  "description": "The unit of the time",
                  "oneOf": [
                    {
                      "title": "Milliseconds",
                      "enum": [
                        "MILLISECONDS"
                      ]
                    },
                    {
                      "title": "Seconds",
                      "enum": [
                        "SECONDS"
                      ]
                    },
                    {
                      "title": "Minutes",
                      "enum": [
                        "MINUTES"
                      ]
                    },
                    {
                      "title": "Hours",
                      "enum": [
                        "HOURS"
                      ]
                    }
                  ]
                },
                "random": {
                  "title": "Random",
                  "type": "boolean",
                  "description": "A random time up to the one given, drawn each time"
                },
                "cron": {
                  "title": "Cron",
                  "type": "string",
                  "description": "When a cron schedule fires: a preset, or Custom for the expression below",
                  "oneOf": [
                    {
                      "title": "Every second",
                      "enum": [
                        "@secondly"
                      ]
                    },
                    {
                      "title": "Every minute",
                      "enum": [
                        "@minutely"
                      ]
                    },
                    {
                      "title": "Every hour",
                      "enum": [
                        "@hourly"
                      ]
                    },
                    {
                      "title": "Every day at midnight",
                      "enum": [
                        "@daily"
                      ]
                    },
                    {
                      "title": "Every Sunday at midnight",
                      "enum": [
                        "@weekly"
                      ]
                    },
                    {
                      "title": "Weekdays at midnight",
                      "enum": [
                        "@weekdays"
                      ]
                    },
                    {
                      "title": "Weekends at midnight",
                      "enum": [
                        "@weekends"
                      ]
                    },
                    {
                      "title": "The 1st of each month",
                      "enum": [
                        "@monthly"
                      ]
                    },
                    {
                      "title": "Every 1 January",
                      "enum": [
                        "@yearly"
                      ]
                    },
                    {
                      "title": "Custom",
                      "enum": [
                        "CRON_CUSTOM"
                      ]
                    }
                  ]
                },
                "cronCustom": {
                  "title": "Cron expression",
                  "type": "string",
                  "description": "Five fields (minute hour day month weekday) or six with seconds first",
                  "placeholder": "0 7 * * 1-5"
                },
                "offset": {
                  "title": "Offset",
                  "type": "number",
                  "description": "Minutes added to the time of the sun; negative for earlier"
                },
                "latitude": {
                  "title": "Latitude",
                  "type": "number",
                  "description": "Where the sun is watched, in decimal degrees",
                  "minimum": -90,
                  "maximum": 90
                },
                "longitude": {
                  "title": "Longitude",
                  "type": "number",
                  "description": "Where the sun is watched, in decimal degrees",
                  "minimum": -180,
                  "maximum": 180
                }
              }
            },
            "limiter": {
              "title": "Limiter",
              "type": "object",
              "description": "The longest it may stay out of its default state in each period",
              "properties": {
                "limit": {
                  "title": "Limit",
                  "type": "number",
                  "description": "The time allowed in each period, in the units below",
                  "minimum": 0
                },
                "units": {
                  "title": "Units",
                  "type": "string",
                  "description": "The unit of the time",
                  "oneOf": [
                    {
                      "title": "Seconds",
                      "enum": [
                        "SECONDS"
                      ]
                    },
                    {
                      "title": "Minutes",
                      "enum": [
                        "MINUTES"
                      ]
                    },
                    {
                      "title": "Hours",
                      "enum": [
                        "HOURS"
                      ]
                    }
                  ]
                },
                "period": {
                  "title": "Period",
                  "type": "string",
                  "description": "The period the limit is for",
                  "oneOf": [
                    {
                      "title": "Hour",
                      "enum": [
                        "HOUR"
                      ]
                    },
                    {
                      "title": "Day",
                      "enum": [
                        "DAY"
                      ]
                    },
                    {
                      "title": "Week",
                      "enum": [
                        "WEEK"
                      ]
                    },
                    {
                      "title": "Month",
                      "enum": [
                        "MONTH"
                      ]
                    }
                  ]
                },
                "resetOnRestart": {
                  "title": "Reset on restart",
                  "type": "boolean",
                  "description": "Forget the time used on a restart"
                }
              }
            },
            "conditions": {
              "title": "Conditions",
              "type": "object",
              "description": "Trigger it when other accessories, the log or a host say so; reset it when they no longer do",
              "properties": {
                "operator": {
                  "title": "When",
                  "type": "string",
                  "description": "All conditions, or any of them",
                  "oneOf": [
                    {
                      "title": "ALL conditions are met",
                      "enum": [
                        "and"
                      ]
                    },
                    {
                      "title": "ANY conditions are met",
                      "enum": [
                        "or"
                      ]
                    }
                  ]
                },
                "operands": {
                  "title": "Condition list",
                  "type": "array",
                  "description": "The conditions",
                  "items": {
                    "type": "object",
                    "title": "Condition",
                    "properties": {
                      "type": {
                        "title": "Condition type",
                        "type": "string",
                        "description": "Another accessory's state, a line of the log, or whether a host answers",
                        "oneOf": [
                          {
                            "title": "Accessory state",
                            "enum": [
                              "ACCESSORY"
                            ]
                          },
                          {
                            "title": "Log line",
                            "enum": [
                              "LOG"
                            ]
                          },
                          {
                            "title": "Reachability",
                            "enum": [
                              "PING"
                            ]
                          }
                        ]
                      },
                      "accessoryId": {
                        "title": "Accessory identifier",
                        "type": "string",
                        "description": "The identifier of another dummy accessory"
                      },
                      "accessoryState": {
                        "title": "State",
                        "type": "string",
                        "description": "The state that accessory must be in",
                        "oneOf": [
                          {
                            "title": "On",
                            "enum": [
                              "on"
                            ]
                          },
                          {
                            "title": "Off",
                            "enum": [
                              "off"
                            ]
                          },
                          {
                            "title": "Open",
                            "enum": [
                              "open"
                            ]
                          },
                          {
                            "title": "Closed",
                            "enum": [
                              "closed"
                            ]
                          },
                          {
                            "title": "Locked",
                            "enum": [
                              "locked"
                            ]
                          },
                          {
                            "title": "Unlocked",
                            "enum": [
                              "unlocked"
                            ]
                          }
                        ]
                      },
                      "pattern": {
                        "title": "Pattern",
                        "type": "string",
                        "description": "A regular expression matched against each new line of the bridge's log"
                      },
                      "pingHost": {
                        "title": "Host",
                        "type": "string",
                        "description": "A host name, an address or a URL, checked over TCP"
                      },
                      "pingAvailability": {
                        "title": "Availability",
                        "type": "string",
                        "description": "Whether the host must answer or not",
                        "oneOf": [
                          {
                            "title": "Available",
                            "enum": [
                              "AVAILABLE"
                            ]
                          },
                          {
                            "title": "Not available",
                            "enum": [
                              "NOT_AVAILABLE"
                            ]
                          }
                        ]
                      },
                      "checkInterval": {
                        "title": "Check every",
                        "type": "integer",
                        "description": "How often the host is checked (60 when empty)",
                        "minimum": 1
                      },
                      "checkUnits": {
                        "title": "Units",
                        "type": "string",
                        "description": "The unit of the check's period",
                        "oneOf": [
                          {
                            "title": "Milliseconds",
                            "enum": [
                              "MILLISECONDS"
                            ]
                          },
                          {
                            "title": "Seconds",
                            "enum": [
                              "SECONDS"
                            ]
                          },
                          {
                            "title": "Minutes",
                            "enum": [
                              "MINUTES"
                            ]
                          },
                          {
                            "title": "Hours",
                            "enum": [
                              "HOURS"
                            ]
                          }
                        ]
                      }
                    }
                  }
                }
              }
            },
            "simulation": {
              "title": "Simulation",
              "type": "object",
              "description": "Makes doors, windows and coverings take time to open and close",
              "properties": {
                "enabled": {
                  "title": "Simulate movement",
                  "type": "boolean",
                  "description": "Move a percent at a time instead of at once"
                },
                "time": {
                  "title": "Time",
                  "type": "integer",
                  "description": "How long, in the units below",
                  "minimum": 1
                },
                "units": {
                  "title": "Units",
                  "type": "string",
                  "description": "The unit of the time",
                  "oneOf": [
                    {
                      "title": "Milliseconds",
                      "enum": [
                        "MILLISECONDS"
                      ]
                    },
                    {
                      "title": "Seconds",
                      "enum": [
                        "SECONDS"
                      ]
                    },
                    {
                      "title": "Minutes",
                      "enum": [
                        "MINUTES"
                      ]
                    },
                    {
                      "title": "Hours",
                      "enum": [
                        "HOURS"
                      ]
                    }
                  ]
                }
              }
            },
            "fadeOut": {
              "title": "Fade out",
              "type": "object",
              "description": "A dimmer that dims to off once on",
              "properties": {
                "type": {
                  "title": "Fade type",
                  "type": "string",
                  "description": "Fixed: the whole fade takes the time; Incremental: each percent does",
                  "oneOf": [
                    {
                      "title": "Fixed",
                      "enum": [
                        "FIXED"
                      ]
                    },
                    {
                      "title": "Incremental",
                      "enum": [
                        "INCREMENTAL"
                      ]
                    }
                  ]
                },
                "time": {
                  "title": "Time",
                  "type": "integer",
                  "description": "How long, in the units below",
                  "minimum": 1
                },
                "units": {
                  "title": "Units",
                  "type": "string",
                  "description": "The unit of the time",
                  "oneOf": [
                    {
                      "title": "Milliseconds",
                      "enum": [
                        "MILLISECONDS"
                      ]
                    },
                    {
                      "title": "Seconds",
                      "enum": [
                        "SECONDS"
                      ]
                    },
                    {
                      "title": "Minutes",
                      "enum": [
                        "MINUTES"
                      ]
                    },
                    {
                      "title": "Hours",
                      "enum": [
                        "HOURS"
                      ]
                    }
                  ]
                }
              }
            },
            "notification": {
              "title": "Notification",
              "type": "object",
              "description": "A push notification when it is triggered or reset; its token goes in config.json or the vault",
              "properties": {
                "api": {
                  "title": "Service",
                  "type": "string",
                  "description": "The push service",
                  "oneOf": [
                    {
                      "title": "Notify!",
                      "enum": [
                        "PINGIE_NOTIFY"
                      ]
                    },
                    {
                      "title": "Pushover",
                      "enum": [
                        "PUSHOVER"
                      ]
                    }
                  ]
                },
                "id": {
                  "title": "Device or application",
                  "type": "string",
                  "description": "Notify!: the device or group id; Pushover: your application's token"
                },
                "title": {
                  "title": "Title",
                  "type": "string",
                  "description": "The title of the notification when it is triggered"
                },
                "text": {
                  "title": "Text",
                  "type": "string",
                  "description": "The text when it is triggered; none is sent without it"
                },
                "resetTitle": {
                  "title": "Reset title",
                  "type": "string",
                  "description": "The title of the notification when it is reset"
                },
                "resetText": {
                  "title": "Reset text",
                  "type": "string",
                  "description": "The text when it is reset; none is sent without it"
                },
                "groupType": {
                  "title": "Group type",
                  "type": "string",
                  "description": "Notify! only: passed on as it is"
                },
                "iconURL": {
                  "title": "Icon address",
                  "type": "string",
                  "description": "Notify! only: the notification's icon"
                }
              }
            },
            "resetOnRestart": {
              "title": "Reset on restart",
              "type": "boolean",
              "description": "Starts in the default state after a restart instead of the last one"
            },
            "enableWebhook": {
              "title": "Enable webhooks",
              "type": "boolean",
              "description": "Lets the webhook server read and set it"
            },
            "enableHistory": {
              "title": "Enable history",
              "type": "boolean",
              "description": "Keeps an Eve history of its changes"
            },
            "disableLogging": {
              "title": "Quiet",
              "type": "boolean",
              "description": "Leaves its routine changes out of the log; problems are still logged"
            }
          }
        }
      }
    }
  },
  "accessorySchema": {
    "properties": {}
  },
  "i18n": {
    "fr": {
      "A delay, a repeating interval, a cron expression or a time of the sun": "Un délai, un intervalle répété, une expression cron ou une heure du soleil",
      "A dimmer that dims to off once on": "Un variateur qui baisse jusqu'à s'éteindre une fois allumé",
      "A host name, an address or a URL, checked over TCP": "Un nom d'hôte, une adresse ou une URL, vérifiés en TCP",
      "A push notification when it is triggered or reset; its token goes in config.json or the vault": "Une notification push quand il est déclenché ou remis à zéro ; son jeton va dans config.json ou le coffre",
      "A random time up to the one given, drawn each time": "Une durée aléatoire jusqu'à celle donnée, tirée à chaque fois",
      "A regular expression matched against each new line of the bridge's log": "Une expression régulière comparée à chaque nouvelle ligne du journal du pont",
      "A sensor added to the accessory, active while it is not in its default state": "Un capteur ajouté à l'accessoire, actif tant qu'il n'est pas dans son état par défaut",
      "ALL conditions are met": "TOUTES les conditions sont remplies",
      "ANY conditions are met": "UNE des conditions est remplie",
      "Accessories": "Accessoires",
      "Accessories with the same group are services of one accessory": "Les accessoires du même groupe sont les services d'un seul accessoire",
      "Accessory": "Accessoire",
      "Accessory identifier": "Identifiant de l'accessoire",
      "Accessory state": "État d'un accessoire",
      "All conditions, or any of them": "Toutes les conditions, ou l'une d'elles",
      "Another accessory's state, a line of the log, or whether a host answers": "L'état d'un autre accessoire, une ligne du journal, ou si un hôte répond",
      "Auto": "Auto",
      "Auto-reset": "Remise à zéro automatique",
      "Availability": "Disponibilité",
      "Available": "Disponible",
      "Behaviour": "Comportement",
      "Button": "Bouton",
      "Carbon dioxide sensor": "Capteur de dioxyde de carbone",
      "Carbon monoxide sensor": "Capteur de monoxyde de carbone",
      "Celsius": "Celsius",
      "Certificate file": "Fichier du certificat",
      "Check every": "Vérifier toutes les",
      "Closed": "Fermée",
      "Condition": "Condition",
      "Condition list": "Liste des conditions",
      "Condition type": "Type de condition",
      "Conditions": "Conditions",
      "Contact sensor": "Capteur de contact",
      "Cool": "Refroidissement",
      "Cron": "Cron",
      "Cron expression": "Expression cron",
      "Custom": "Personnalisé",
      "Dawn": "Aube",
      "Day": "Jour",
      "Default lock state": "État par défaut de la serrure",
      "Default mode": "Mode par défaut",
      "Default position": "Position par défaut",
      "Default state": "État par défaut",
      "Default temperature": "Température par défaut",
      "Dehumidifier": "Déshumidificateur",
      "Device or application": "Appareil ou application",
      "Dimmer": "Variateur",
      "Door": "Porte",
      "Dusk": "Crépuscule",
      "Enable history": "Activer l'historique",
      "Enable webhooks": "Activer les webhooks",
      "Every 1 January": "Chaque 1er janvier",
      "Every Sunday at midnight": "Chaque dimanche à minuit",
      "Every day at midnight": "Chaque jour à minuit",
      "Every hour": "Chaque heure",
      "Every minute": "Chaque minute",
      "Every second": "Chaque seconde",
      "Fade out": "Extinction progressive",
      "Fade type": "Type d'extinction",
      "Fahrenheit": "Fahrenheit",
      "Faucet": "Robinet",
      "Five fields (minute hour day month weekday) or six with seconds first": "Cinq champs (minute heure jour mois jour de la semaine) ou six avec les secondes en premier",
      "Fixed": "Fixe",
      "Fixed: the whole fade takes the time; Incremental: each percent does": "Fixe : toute l'extinction dure ce temps ; Progressive : chaque pour cent le dure",
      "Forget the time used on a restart": "Oublier le temps utilisé au redémarrage",
      "Garage door": "Porte de garage",
      "Generic": "Générique",
      "Gives the light a brightness": "Donne une luminosité à la lampe",
      "Golden hour": "Heure dorée",
      "Group": "Groupe",
      "Group type": "Type de groupe",
      "Heat": "Chauffage",
      "HomeKit": "HomeKit",
      "HomeKit, or Matter for a switch, an outlet or a light: Homeswift's Matter bridge shows it and it stays out of the Home app": "HomeKit, ou Matter pour un interrupteur, une prise ou une lampe : le pont Matter de Homeswift le montre et il reste hors de l'app Maison",
      "Host": "Hôte",
      "Hour": "Heure",
      "Hours": "Heures",
      "How long, in the units below": "Combien de temps, dans l'unité ci-dessous",
      "How often the host is checked (60 when empty)": "La fréquence de vérification de l'hôte (60 si vide)",
      "How the Home app shows the valve": "Comment l'app Maison montre la vanne",
      "Humidifier": "Humidificateur",
      "Humidifier or dehumidifier": "Humidificateur ou déshumidificateur",
      "Humidifier type": "Type d'humidificateur",
      "Humidity sensor": "Capteur d'humidité",
      "Icon address": "Adresse de l'icône",
      "Identifier": "Identifiant",
      "Incremental": "Progressive",
      "Interval": "Intervalle",
      "Irrigation": "Arrosage",
      "Keeps an Eve history of its changes": "Garde un historique Eve de ses changements",
      "Keeps the accessory's identity; without one it comes from its type and name": "Garde l'identité de l'accessoire ; sans lui, elle vient de son type et de son nom",
      "Key file": "Fichier de la clé",
      "Latitude": "Latitude",
      "Leak sensor": "Capteur de fuite",
      "Leaves its routine changes out of the log; problems are still logged": "Laisse ses changements courants hors du journal ; les problèmes y restent",
      "Lets the webhook server read and set it": "Permet au serveur de webhooks de le lire et de le régler",
      "Lightbulb": "Ampoule",
      "Limit": "Limite",
      "Limiter": "Limiteur",
      "Listen address": "Adresse d'écoute",
      "Lock": "Serrure",
      "Locked": "Verrouillée",
      "Locked or unlocked at rest": "Verrouillée ou déverrouillée au repos",
      "Log line": "Ligne du journal",
      "Logs condition checks, webhook requests, history entries and reachability changes": "Note les vérifications des conditions, les requêtes des webhooks, l'historique et les changements de joignabilité",
      "Longitude": "Longitude",
      "Makes doors, windows and coverings take time to open and close": "Fait que portes, fenêtres et stores prennent du temps pour s'ouvrir et se fermer",
      "Matter": "Matter",
      "Maximum temperature": "Température maximale",
      "Milliseconds": "Millisecondes",
      "Minimum temperature": "Température minimale",
      "Minutes": "Minutes",
      "Minutes added to the time of the sun; negative for earlier": "Minutes ajoutées à l'heure du soleil ; négatives pour plus tôt",
      "Mirror": "Suivre",
      "Mirror the accessory, or go active for a second when a timer or a condition resets it": "Suivre l'accessoire, ou s'activer une seconde quand un minuteur ou une condition le remet à zéro",
      "Modes": "Modes",
      "Month": "Mois",
      "Motion sensor": "Détecteur de mouvement",
      "Move a percent at a time instead of at once": "Bouger d'un pour cent à la fois plutôt que d'un coup",
      "Name": "Nom",
      "Night": "Nuit",
      "Not available": "Indisponible",
      "Notification": "Notification",
      "Notify!": "Notify!",
      "Notify! only: passed on as it is": "Notify! seulement : transmis tel quel",
      "Notify! only: the notification's icon": "Notify! seulement : l'icône de la notification",
      "Notify!: the device or group id; Pushover: your application's token": "Notify! : l'identifiant de l'appareil ou du groupe ; Pushover : le jeton de votre application",
      "Occupancy sensor": "Détecteur de présence",
      "Off": "Éteint",
      "Offset": "Décalage",
      "On": "Allumé",
      "Open": "Ouverte",
      "Open or closed at rest": "Ouverte ou fermée au repos",
      "Outlet": "Prise",
      "Path of the PEM certificate for HTTPS": "Chemin du certificat PEM pour HTTPS",
      "Path of the PEM private key for HTTPS": "Chemin de la clé privée PEM pour HTTPS",
      "Pattern": "Motif",
      "Period": "Période",
      "Plain HTTP": "HTTP simple",
      "Plugin name as shown in the logs": "Nom du plugin dans le journal",
      "Port": "Port",
      "Protocol": "Protocole",
      "Pushover": "Pushover",
      "Quiet": "Discret",
      "Random": "Aléatoire",
      "Reachability": "Joignabilité",
      "Reset on restart": "Remise à zéro au redémarrage",
      "Reset text": "Texte de remise à zéro",
      "Reset title": "Titre de remise à zéro",
      "Schedule": "Programmation",
      "Schedule type": "Type de programmation",
      "Seconds": "Secondes",
      "Sensor": "Capteur",
      "Sensor type": "Type de capteur",
      "Serve the webhooks over HTTP even when a key and a certificate are given": "Sert les webhooks en HTTP même avec une clé et un certificat",
      "Service": "Service",
      "Shower": "Douche",
      "Simulate movement": "Simuler le mouvement",
      "Simulation": "Simulation",
      "Smoke sensor": "Détecteur de fumée",
      "Starts in the default state after a restart instead of the last one": "Démarre dans l'état par défaut après un redémarrage plutôt que dans le dernier",
      "State": "État",
      "Sunrise": "Lever du soleil",
      "Sunset": "Coucher du soleil",
      "Switch": "Interrupteur",
      "Temperature sensor": "Capteur de température",
      "Temperature units": "Unité de température",
      "Text": "Texte",
      "The 1st of each month": "Le 1er de chaque mois",
      "The HTTP server that sets and reads the accessories that enable webhooks": "Le serveur HTTP qui règle et lit les accessoires dont les webhooks sont activés",
      "The accessory's name": "Le nom de l'accessoire",
      "The address the webhook server listens on: 0.0.0.0 for every interface, 127.0.0.1 for this machine only": "L'adresse où écoute le serveur de webhooks : 0.0.0.0 pour toutes les interfaces, 127.0.0.1 pour cette machine seulement",
      "The conditions": "Les conditions",
      "The dummy accessories": "Les accessoires factices",
      "The highest temperature (38 °C when empty)": "La température la plus haute (38 °C si vide)",
      "The identifier of another dummy accessory": "L'identifiant d'un autre accessoire factice",
      "The longest it may stay out of its default state in each period": "Le plus longtemps qu'il peut rester hors de son état par défaut à chaque période",
      "The lowest temperature (10 °C when empty)": "La température la plus basse (10 °C si vide)",
      "The modes the thermostat offers (all four when empty)": "Les modes que propose le thermostat (les quatre si vide)",
      "The period the limit is for": "La période de la limite",
      "The push service": "Le service de notifications",
      "The state it rests in, and goes back to on a reset": "L'état où il reste et auquel il revient à une remise à zéro",
      "The state that accessory must be in": "L'état où doit être cet accessoire",
      "The target temperature at first (20 °C when empty)": "La température cible au départ (20 °C si vide)",
      "The text when it is reset; none is sent without it": "Le texte à la remise à zéro ; rien n'est envoyé sans lui",
      "The text when it is triggered; none is sent without it": "Le texte au déclenchement ; rien n'est envoyé sans lui",
      "The thermostat's mode at first": "Le mode du thermostat au départ",
      "The time allowed in each period, in the units below": "Le temps permis à chaque période, dans l'unité ci-dessous",
      "The title of the notification when it is reset": "Le titre de la notification à la remise à zéro",
      "The title of the notification when it is triggered": "Le titre de la notification au déclenchement",
      "The unit of the check's period": "L'unité de la période de vérification",
      "The unit of the temperatures here and in webhooks": "L'unité des températures ici et dans les webhooks",
      "The unit of the time": "L'unité du temps",
      "The webhook server's port (63743 when empty)": "Le port du serveur de webhooks (63743 si vide)",
      "Thermostat": "Thermostat",
      "Time": "Durée",
      "Timeout": "Délai",
      "Timer": "Minuteur",
      "Title": "Titre",
      "Trigger it when other accessories, the log or a host say so; reset it when they no longer do": "Le déclencher quand d'autres accessoires, le journal ou un hôte le disent ; le remettre à zéro quand ce n'est plus le cas",
      "Type": "Type",
      "Units": "Unité",
      "Unlocked": "Déverrouillée",
      "Valve": "Vanne",
      "Valve type": "Type de vanne",
      "Verbose logging": "Journal détaillé",
      "Webhooks": "Webhooks",
      "Week": "Semaine",
      "Weekdays at midnight": "En semaine à minuit",
      "Weekends at midnight": "Le week-end à minuit",
      "What the accessory is in HomeKit": "Ce qu'est l'accessoire dans HomeKit",
      "What the added sensor is": "Ce qu'est le capteur ajouté",
      "When": "Quand",
      "When a cron schedule fires: a preset, or Custom for the expression below": "Quand une programmation cron se déclenche : un préréglage, ou Personnalisé pour l'expression ci-dessous",
      "When to put it back in its default state": "Quand le remettre dans son état par défaut",
      "When to trigger it: put it in the state other than its default": "Quand le déclencher : le mettre dans l'état autre que celui par défaut",
      "Where the sun is watched, in decimal degrees": "Où le soleil est observé, en degrés décimaux",
      "Whether it adds or removes humidity": "S'il ajoute ou retire de l'humidité",
      "Whether the host must answer or not": "Si l'hôte doit répondre ou non",
      "Window": "Fenêtre",
      "Window covering": "Store",
      "Exact position": "Position exacte",
      "Homeswift only: keeps the position set (0 to 100 %), as a real shutter does, rather than open or closed": "Homeswift seulement : garde la position réglée (de 0 à 100 %), comme un vrai volet, plutôt qu'ouvert ou fermé"
    },
    "es": {
      "A delay, a repeating interval, a cron expression or a time of the sun": "Un retraso, un intervalo repetido, una expresión cron o una hora del sol",
      "A dimmer that dims to off once on": "Una luz regulable que baja hasta apagarse una vez encendida",
      "A host name, an address or a URL, checked over TCP": "Un nombre de host, una dirección o una URL, comprobados por TCP",
      "A push notification when it is triggered or reset; its token goes in config.json or the vault": "Una notificación push cuando se dispara o se restablece; su token va en config.json o en la bóveda",
      "A random time up to the one given, drawn each time": "Un tiempo aleatorio hasta el indicado, sorteado cada vez",
      "A regular expression matched against each new line of the bridge's log": "Una expresión regular comparada con cada nueva línea del registro del puente",
      "A sensor added to the accessory, active while it is not in its default state": "Un sensor añadido al accesorio, activo mientras no esté en su estado predeterminado",
      "ALL conditions are met": "Se cumplen TODAS las condiciones",
      "ANY conditions are met": "Se cumple ALGUNA condición",
      "Accessories": "Accesorios",
      "Accessories with the same group are services of one accessory": "Los accesorios del mismo grupo son servicios de un solo accesorio",
      "Accessory": "Accesorio",
      "Accessory identifier": "Identificador del accesorio",
      "Accessory state": "Estado de un accesorio",
      "All conditions, or any of them": "Todas las condiciones, o cualquiera de ellas",
      "Another accessory's state, a line of the log, or whether a host answers": "El estado de otro accesorio, una línea del registro, o si un host responde",
      "Auto": "Automático",
      "Auto-reset": "Restablecimiento automático",
      "Availability": "Disponibilidad",
      "Available": "Disponible",
      "Behaviour": "Comportamiento",
      "Button": "Botón",
      "Carbon dioxide sensor": "Sensor de dióxido de carbono",
      "Carbon monoxide sensor": "Sensor de monóxido de carbono",
      "Celsius": "Celsius",
      "Certificate file": "Archivo del certificado",
      "Check every": "Comprobar cada",
      "Closed": "Cerrada",
      "Condition": "Condición",
      "Condition list": "Lista de condiciones",
      "Condition type": "Tipo de condición",
      "Conditions": "Condiciones",
      "Contact sensor": "Sensor de contacto",
      "Cool": "Frío",
      "Cron": "Cron",
      "Cron expression": "Expresión cron",
      "Custom": "Personalizado",
      "Dawn": "Alba",
      "Day": "Día",
      "Default lock state": "Estado predeterminado de la cerradura",
      "Default mode": "Modo predeterminado",
      "Default position": "Posición predeterminada",
      "Default state": "Estado predeterminado",
      "Default temperature": "Temperatura predeterminada",
      "Dehumidifier": "Deshumidificador",
      "Device or application": "Dispositivo o aplicación",
      "Dimmer": "Regulable",
      "Door": "Puerta",
      "Dusk": "Anochecer",
      "Enable history": "Activar historial",
      "Enable webhooks": "Activar webhooks",
      "Every 1 January": "Cada 1 de enero",
      "Every Sunday at midnight": "Cada domingo a medianoche",
      "Every day at midnight": "Cada día a medianoche",
      "Every hour": "Cada hora",
      "Every minute": "Cada minuto",
      "Every second": "Cada segundo",
      "Fade out": "Atenuación",
      "Fade type": "Tipo de atenuación",
      "Fahrenheit": "Fahrenheit",
      "Faucet": "Grifo",
      "Five fields (minute hour day month weekday) or six with seconds first": "Cinco campos (minuto hora día mes día de la semana) o seis con los segundos primero",
      "Fixed": "Fija",
      "Fixed: the whole fade takes the time; Incremental: each percent does": "Fija: toda la atenuación dura ese tiempo; Incremental: cada uno por ciento lo dura",
      "Forget the time used on a restart": "Olvidar el tiempo usado al reiniciar",
      "Garage door": "Puerta de garaje",
      "Generic": "Genérica",
      "Gives the light a brightness": "Da brillo a la luz",
      "Golden hour": "Hora dorada",
      "Group": "Grupo",
      "Group type": "Tipo de grupo",
      "Heat": "Calor",
      "HomeKit": "HomeKit",
      "HomeKit, or Matter for a switch, an outlet or a light: Homeswift's Matter bridge shows it and it stays out of the Home app": "HomeKit, o Matter para un interruptor, un enchufe o una luz: el puente Matter de Homeswift lo muestra y queda fuera de la app Casa",
      "Host": "Host",
      "Hour": "Hora",
      "Hours": "Horas",
      "How long, in the units below": "Cuánto tiempo, en la unidad de abajo",
      "How often the host is checked (60 when empty)": "Cada cuánto se comprueba el host (60 si está vacío)",
      "How the Home app shows the valve": "Cómo muestra la válvula la app Casa",
      "Humidifier": "Humidificador",
      "Humidifier or dehumidifier": "Humidificador o deshumidificador",
      "Humidifier type": "Tipo de humidificador",
      "Humidity sensor": "Sensor de humedad",
      "Icon address": "Dirección del icono",
      "Identifier": "Identificador",
      "Incremental": "Incremental",
      "Interval": "Intervalo",
      "Irrigation": "Riego",
      "Keeps an Eve history of its changes": "Guarda un historial Eve de sus cambios",
      "Keeps the accessory's identity; without one it comes from its type and name": "Mantiene la identidad del accesorio; sin él, procede de su tipo y su nombre",
      "Key file": "Archivo de la clave",
      "Latitude": "Latitud",
      "Leak sensor": "Sensor de fugas",
      "Leaves its routine changes out of the log; problems are still logged": "Deja sus cambios habituales fuera del registro; los problemas siguen registrándose",
      "Lets the webhook server read and set it": "Permite al servidor de webhooks leerlo y ajustarlo",
      "Lightbulb": "Bombilla",
      "Limit": "Límite",
      "Limiter": "Limitador",
      "Listen address": "Dirección de escucha",
      "Lock": "Cerradura",
      "Locked": "Bloqueada",
      "Locked or unlocked at rest": "Bloqueada o desbloqueada en reposo",
      "Log line": "Línea del registro",
      "Logs condition checks, webhook requests, history entries and reachability changes": "Registra las comprobaciones de condiciones, las solicitudes de webhooks, el historial y los cambios de accesibilidad",
      "Longitude": "Longitud",
      "Makes doors, windows and coverings take time to open and close": "Hace que puertas, ventanas y persianas tarden en abrirse y cerrarse",
      "Matter": "Matter",
      "Maximum temperature": "Temperatura máxima",
      "Milliseconds": "Milisegundos",
      "Minimum temperature": "Temperatura mínima",
      "Minutes": "Minutos",
      "Minutes added to the time of the sun; negative for earlier": "Minutos añadidos a la hora del sol; negativos para antes",
      "Mirror": "Reflejar",
      "Mirror the accessory, or go active for a second when a timer or a condition resets it": "Seguir al accesorio, o activarse un segundo cuando un temporizador o una condición lo restablece",
      "Modes": "Modos",
      "Month": "Mes",
      "Motion sensor": "Sensor de movimiento",
      "Move a percent at a time instead of at once": "Moverse un uno por ciento cada vez en lugar de a la vez",
      "Name": "Nombre",
      "Night": "Noche",
      "Not available": "No disponible",
      "Notification": "Notificación",
      "Notify!": "Notify!",
      "Notify! only: passed on as it is": "Solo Notify!: se transmite tal cual",
      "Notify! only: the notification's icon": "Solo Notify!: el icono de la notificación",
      "Notify!: the device or group id; Pushover: your application's token": "Notify!: el id del dispositivo o grupo; Pushover: el token de tu aplicación",
      "Occupancy sensor": "Sensor de presencia",
      "Off": "Apagado",
      "Offset": "Desfase",
      "On": "Encendido",
      "Open": "Abierta",
      "Open or closed at rest": "Abierta o cerrada en reposo",
      "Outlet": "Enchufe",
      "Path of the PEM certificate for HTTPS": "Ruta del certificado PEM para HTTPS",
      "Path of the PEM private key for HTTPS": "Ruta de la clave privada PEM para HTTPS",
      "Pattern": "Patrón",
      "Period": "Periodo",
      "Plain HTTP": "HTTP simple",
      "Plugin name as shown in the logs": "Nombre del plugin en el registro",
      "Port": "Puerto",
      "Protocol": "Protocolo",
      "Pushover": "Pushover",
      "Quiet": "Silencioso",
      "Random": "Aleatorio",
      "Reachability": "Accesibilidad",
      "Reset on restart": "Restablecer al reiniciar",
      "Reset text": "Texto de restablecimiento",
      "Reset title": "Título de restablecimiento",
      "Schedule": "Programación",
      "Schedule type": "Tipo de programación",
      "Seconds": "Segundos",
      "Sensor": "Sensor",
      "Sensor type": "Tipo de sensor",
      "Serve the webhooks over HTTP even when a key and a certificate are given": "Sirve los webhooks por HTTP aunque haya una clave y un certificado",
      "Service": "Servicio",
      "Shower": "Ducha",
      "Simulate movement": "Simular el movimiento",
      "Simulation": "Simulación",
      "Smoke sensor": "Detector de humo",
      "Starts in the default state after a restart instead of the last one": "Arranca en el estado predeterminado tras un reinicio en lugar del último",
      "State": "Estado",
      "Sunrise": "Amanecer",
      "Sunset": "Atardecer",
      "Switch": "Interruptor",
      "Temperature sensor": "Sensor de temperatura",
      "Temperature units": "Unidad de temperatura",
      "Text": "Texto",
      "The 1st of each month": "El día 1 de cada mes",
      "The HTTP server that sets and reads the accessories that enable webhooks": "El servidor HTTP que ajusta y lee los accesorios con webhooks activados",
      "The accessory's name": "El nombre del accesorio",
      "The address the webhook server listens on: 0.0.0.0 for every interface, 127.0.0.1 for this machine only": "La dirección donde escucha el servidor de webhooks: 0.0.0.0 para todas las interfaces, 127.0.0.1 solo para esta máquina",
      "The conditions": "Las condiciones",
      "The dummy accessories": "Los accesorios ficticios",
      "The highest temperature (38 °C when empty)": "La temperatura más alta (38 °C si está vacía)",
      "The identifier of another dummy accessory": "El identificador de otro accesorio ficticio",
      "The longest it may stay out of its default state in each period": "Lo máximo que puede estar fuera de su estado predeterminado en cada periodo",
      "The lowest temperature (10 °C when empty)": "La temperatura más baja (10 °C si está vacía)",
      "The modes the thermostat offers (all four when empty)": "Los modos que ofrece el termostato (los cuatro si está vacío)",
      "The period the limit is for": "El periodo del límite",
      "The push service": "El servicio de notificaciones",
      "The state it rests in, and goes back to on a reset": "El estado en el que reposa y al que vuelve al restablecerse",
      "The state that accessory must be in": "El estado en el que debe estar ese accesorio",
      "The target temperature at first (20 °C when empty)": "La temperatura objetivo al principio (20 °C si está vacía)",
      "The text when it is reset; none is sent without it": "El texto al restablecerse; sin él no se envía nada",
      "The text when it is triggered; none is sent without it": "El texto al dispararse; sin él no se envía nada",
      "The thermostat's mode at first": "El modo del termostato al principio",
      "The time allowed in each period, in the units below": "El tiempo permitido en cada periodo, en la unidad de abajo",
      "The title of the notification when it is reset": "El título de la notificación al restablecerse",
      "The title of the notification when it is triggered": "El título de la notificación al dispararse",
      "The unit of the check's period": "La unidad del periodo de comprobación",
      "The unit of the temperatures here and in webhooks": "La unidad de las temperaturas aquí y en los webhooks",
      "The unit of the time": "La unidad del tiempo",
      "The webhook server's port (63743 when empty)": "El puerto del servidor de webhooks (63743 si está vacío)",
      "Thermostat": "Termostato",
      "Time": "Tiempo",
      "Timeout": "Retraso",
      "Timer": "Temporizador",
      "Title": "Título",
      "Trigger it when other accessories, the log or a host say so; reset it when they no longer do": "Dispararlo cuando otros accesorios, el registro o un host lo indiquen; restablecerlo cuando ya no",
      "Type": "Tipo",
      "Units": "Unidad",
      "Unlocked": "Desbloqueada",
      "Valve": "Válvula",
      "Valve type": "Tipo de válvula",
      "Verbose logging": "Registro detallado",
      "Webhooks": "Webhooks",
      "Week": "Semana",
      "Weekdays at midnight": "Entre semana a medianoche",
      "Weekends at midnight": "Fines de semana a medianoche",
      "What the accessory is in HomeKit": "Lo que es el accesorio en HomeKit",
      "What the added sensor is": "Lo que es el sensor añadido",
      "When": "Cuándo",
      "When a cron schedule fires: a preset, or Custom for the expression below": "Cuándo se dispara una programación cron: un ajuste predefinido, o Personalizado para la expresión de abajo",
      "When to put it back in its default state": "Cuándo devolverlo a su estado predeterminado",
      "When to trigger it: put it in the state other than its default": "Cuándo dispararlo: ponerlo en el estado distinto del predeterminado",
      "Where the sun is watched, in decimal degrees": "Dónde se observa el sol, en grados decimales",
      "Whether it adds or removes humidity": "Si añade o quita humedad",
      "Whether the host must answer or not": "Si el host debe responder o no",
      "Window": "Ventana",
      "Window covering": "Persiana",
      "Exact position": "Posición exacta",
      "Homeswift only: keeps the position set (0 to 100 %), as a real shutter does, rather than open or closed": "Solo Homeswift: mantiene la posición fijada (de 0 a 100 %), como una persiana real, en lugar de abierta o cerrada"
    },
    "pt": {
      "A delay, a repeating interval, a cron expression or a time of the sun": "Um atraso, um intervalo repetido, uma expressão cron ou uma hora do sol",
      "A dimmer that dims to off once on": "Uma luz regulável que baixa até desligar uma vez ligada",
      "A host name, an address or a URL, checked over TCP": "Um nome de anfitrião, um endereço ou um URL, verificados por TCP",
      "A push notification when it is triggered or reset; its token goes in config.json or the vault": "Uma notificação push quando é disparado ou reposto; o seu token vai no config.json ou no cofre",
      "A random time up to the one given, drawn each time": "Um tempo aleatório até ao indicado, sorteado de cada vez",
      "A regular expression matched against each new line of the bridge's log": "Uma expressão regular comparada com cada nova linha do registo da ponte",
      "A sensor added to the accessory, active while it is not in its default state": "Um sensor adicionado ao acessório, ativo enquanto não estiver no estado predefinido",
      "ALL conditions are met": "TODAS as condições se cumprem",
      "ANY conditions are met": "ALGUMA condição se cumpre",
      "Accessories": "Acessórios",
      "Accessories with the same group are services of one accessory": "Os acessórios do mesmo grupo são serviços de um só acessório",
      "Accessory": "Acessório",
      "Accessory identifier": "Identificador do acessório",
      "Accessory state": "Estado de um acessório",
      "All conditions, or any of them": "Todas as condições, ou qualquer uma delas",
      "Another accessory's state, a line of the log, or whether a host answers": "O estado de outro acessório, uma linha do registo, ou se um anfitrião responde",
      "Auto": "Automático",
      "Auto-reset": "Reposição automática",
      "Availability": "Disponibilidade",
      "Available": "Disponível",
      "Behaviour": "Comportamento",
      "Button": "Botão",
      "Carbon dioxide sensor": "Sensor de dióxido de carbono",
      "Carbon monoxide sensor": "Sensor de monóxido de carbono",
      "Celsius": "Celsius",
      "Certificate file": "Ficheiro do certificado",
      "Check every": "Verificar a cada",
      "Closed": "Fechada",
      "Condition": "Condição",
      "Condition list": "Lista de condições",
      "Condition type": "Tipo de condição",
      "Conditions": "Condições",
      "Contact sensor": "Sensor de contacto",
      "Cool": "Arrefecimento",
      "Cron": "Cron",
      "Cron expression": "Expressão cron",
      "Custom": "Personalizado",
      "Dawn": "Aurora",
      "Day": "Dia",
      "Default lock state": "Estado predefinido da fechadura",
      "Default mode": "Modo predefinido",
      "Default position": "Posição predefinida",
      "Default state": "Estado predefinido",
      "Default temperature": "Temperatura predefinida",
      "Dehumidifier": "Desumidificador",
      "Device or application": "Dispositivo ou aplicação",
      "Dimmer": "Regulável",
      "Door": "Porta",
      "Dusk": "Crepúsculo",
      "Enable history": "Ativar histórico",
      "Enable webhooks": "Ativar webhooks",
      "Every 1 January": "Todos os 1 de janeiro",
      "Every Sunday at midnight": "Todos os domingos à meia-noite",
      "Every day at midnight": "Todos os dias à meia-noite",
      "Every hour": "Cada hora",
      "Every minute": "Cada minuto",
      "Every second": "Cada segundo",
      "Fade out": "Desvanecimento",
      "Fade type": "Tipo de desvanecimento",
      "Fahrenheit": "Fahrenheit",
      "Faucet": "Torneira",
      "Five fields (minute hour day month weekday) or six with seconds first": "Cinco campos (minuto hora dia mês dia da semana) ou seis com os segundos primeiro",
      "Fixed": "Fixo",
      "Fixed: the whole fade takes the time; Incremental: each percent does": "Fixo: todo o desvanecimento dura esse tempo; Incremental: cada por cento dura-o",
      "Forget the time used on a restart": "Esquecer o tempo usado ao reiniciar",
      "Garage door": "Portão de garagem",
      "Generic": "Genérica",
      "Gives the light a brightness": "Dá brilho à luz",
      "Golden hour": "Hora dourada",
      "Group": "Grupo",
      "Group type": "Tipo de grupo",
      "Heat": "Aquecimento",
      "HomeKit": "HomeKit",
      "HomeKit, or Matter for a switch, an outlet or a light: Homeswift's Matter bridge shows it and it stays out of the Home app": "HomeKit, ou Matter para um interruptor, uma tomada ou uma luz: a ponte Matter do Homeswift mostra-o e fica fora da app Casa",
      "Host": "Anfitrião",
      "Hour": "Hora",
      "Hours": "Horas",
      "How long, in the units below": "Quanto tempo, na unidade abaixo",
      "How often the host is checked (60 when empty)": "Com que frequência o anfitrião é verificado (60 se vazio)",
      "How the Home app shows the valve": "Como a app Casa mostra a válvula",
      "Humidifier": "Humidificador",
      "Humidifier or dehumidifier": "Humidificador ou desumidificador",
      "Humidifier type": "Tipo de humidificador",
      "Humidity sensor": "Sensor de humidade",
      "Icon address": "Endereço do ícone",
      "Identifier": "Identificador",
      "Incremental": "Incremental",
      "Interval": "Intervalo",
      "Irrigation": "Rega",
      "Keeps an Eve history of its changes": "Guarda um histórico Eve das suas mudanças",
      "Keeps the accessory's identity; without one it comes from its type and name": "Mantém a identidade do acessório; sem ele, vem do seu tipo e do seu nome",
      "Key file": "Ficheiro da chave",
      "Latitude": "Latitude",
      "Leak sensor": "Sensor de fugas",
      "Leaves its routine changes out of the log; problems are still logged": "Deixa as suas mudanças habituais fora do registo; os problemas continuam registados",
      "Lets the webhook server read and set it": "Permite ao servidor de webhooks lê-lo e ajustá-lo",
      "Lightbulb": "Lâmpada",
      "Limit": "Limite",
      "Limiter": "Limitador",
      "Listen address": "Endereço de escuta",
      "Lock": "Fechadura",
      "Locked": "Trancada",
      "Locked or unlocked at rest": "Trancada ou destrancada em repouso",
      "Log line": "Linha do registo",
      "Logs condition checks, webhook requests, history entries and reachability changes": "Regista as verificações das condições, os pedidos de webhooks, o histórico e as mudanças de acessibilidade",
      "Longitude": "Longitude",
      "Makes doors, windows and coverings take time to open and close": "Faz com que portas, janelas e estores demorem a abrir e fechar",
      "Matter": "Matter",
      "Maximum temperature": "Temperatura máxima",
      "Milliseconds": "Milissegundos",
      "Minimum temperature": "Temperatura mínima",
      "Minutes": "Minutos",
      "Minutes added to the time of the sun; negative for earlier": "Minutos somados à hora do sol; negativos para mais cedo",
      "Mirror": "Espelhar",
      "Mirror the accessory, or go active for a second when a timer or a condition resets it": "Seguir o acessório, ou ativar-se um segundo quando um temporizador ou uma condição o repõe",
      "Modes": "Modos",
      "Month": "Mês",
      "Motion sensor": "Sensor de movimento",
      "Move a percent at a time instead of at once": "Mover-se um por cento de cada vez em vez de uma só vez",
      "Name": "Nome",
      "Night": "Noite",
      "Not available": "Indisponível",
      "Notification": "Notificação",
      "Notify!": "Notify!",
      "Notify! only: passed on as it is": "Só Notify!: transmitido tal como está",
      "Notify! only: the notification's icon": "Só Notify!: o ícone da notificação",
      "Notify!: the device or group id; Pushover: your application's token": "Notify!: o id do dispositivo ou grupo; Pushover: o token da sua aplicação",
      "Occupancy sensor": "Sensor de presença",
      "Off": "Desligado",
      "Offset": "Desvio",
      "On": "Ligado",
      "Open": "Aberta",
      "Open or closed at rest": "Aberta ou fechada em repouso",
      "Outlet": "Tomada",
      "Path of the PEM certificate for HTTPS": "Caminho do certificado PEM para HTTPS",
      "Path of the PEM private key for HTTPS": "Caminho da chave privada PEM para HTTPS",
      "Pattern": "Padrão",
      "Period": "Período",
      "Plain HTTP": "HTTP simples",
      "Plugin name as shown in the logs": "Nome do plugin no registo",
      "Port": "Porta",
      "Protocol": "Protocolo",
      "Pushover": "Pushover",
      "Quiet": "Silencioso",
      "Random": "Aleatório",
      "Reachability": "Acessibilidade",
      "Reset on restart": "Repor ao reiniciar",
      "Reset text": "Texto de reposição",
      "Reset title": "Título de reposição",
      "Schedule": "Agendamento",
      "Schedule type": "Tipo de agendamento",
      "Seconds": "Segundos",
      "Sensor": "Sensor",
      "Sensor type": "Tipo de sensor",
      "Serve the webhooks over HTTP even when a key and a certificate are given": "Serve os webhooks por HTTP mesmo com uma chave e um certificado",
      "Service": "Serviço",
      "Shower": "Duche",
      "Simulate movement": "Simular o movimento",
      "Simulation": "Simulação",
      "Smoke sensor": "Detetor de fumo",
      "Starts in the default state after a restart instead of the last one": "Arranca no estado predefinido após um reinício em vez do último",
      "State": "Estado",
      "Sunrise": "Nascer do sol",
      "Sunset": "Pôr do sol",
      "Switch": "Interruptor",
      "Temperature sensor": "Sensor de temperatura",
      "Temperature units": "Unidade de temperatura",
      "Text": "Texto",
      "The 1st of each month": "O dia 1 de cada mês",
      "The HTTP server that sets and reads the accessories that enable webhooks": "O servidor HTTP que ajusta e lê os acessórios com webhooks ativados",
      "The accessory's name": "O nome do acessório",
      "The address the webhook server listens on: 0.0.0.0 for every interface, 127.0.0.1 for this machine only": "O endereço onde o servidor de webhooks escuta: 0.0.0.0 para todas as interfaces, 127.0.0.1 só para esta máquina",
      "The conditions": "As condições",
      "The dummy accessories": "Os acessórios fictícios",
      "The highest temperature (38 °C when empty)": "A temperatura mais alta (38 °C se vazia)",
      "The identifier of another dummy accessory": "O identificador de outro acessório fictício",
      "The longest it may stay out of its default state in each period": "O máximo que pode ficar fora do estado predefinido em cada período",
      "The lowest temperature (10 °C when empty)": "A temperatura mais baixa (10 °C se vazia)",
      "The modes the thermostat offers (all four when empty)": "Os modos que o termóstato oferece (os quatro se vazio)",
      "The period the limit is for": "O período do limite",
      "The push service": "O serviço de notificações",
      "The state it rests in, and goes back to on a reset": "O estado em que fica e ao qual volta ao repor",
      "The state that accessory must be in": "O estado em que esse acessório tem de estar",
      "The target temperature at first (20 °C when empty)": "A temperatura alvo ao início (20 °C se vazia)",
      "The text when it is reset; none is sent without it": "O texto ao repor; sem ele nada é enviado",
      "The text when it is triggered; none is sent without it": "O texto ao disparar; sem ele nada é enviado",
      "The thermostat's mode at first": "O modo do termóstato ao início",
      "The time allowed in each period, in the units below": "O tempo permitido em cada período, na unidade abaixo",
      "The title of the notification when it is reset": "O título da notificação ao repor",
      "The title of the notification when it is triggered": "O título da notificação ao disparar",
      "The unit of the check's period": "A unidade do período de verificação",
      "The unit of the temperatures here and in webhooks": "A unidade das temperaturas aqui e nos webhooks",
      "The unit of the time": "A unidade do tempo",
      "The webhook server's port (63743 when empty)": "A porta do servidor de webhooks (63743 se vazio)",
      "Thermostat": "Termóstato",
      "Time": "Tempo",
      "Timeout": "Atraso",
      "Timer": "Temporizador",
      "Title": "Título",
      "Trigger it when other accessories, the log or a host say so; reset it when they no longer do": "Dispará-lo quando outros acessórios, o registo ou um anfitrião o indicarem; repô-lo quando deixarem de o fazer",
      "Type": "Tipo",
      "Units": "Unidade",
      "Unlocked": "Destrancada",
      "Valve": "Válvula",
      "Valve type": "Tipo de válvula",
      "Verbose logging": "Registo detalhado",
      "Webhooks": "Webhooks",
      "Week": "Semana",
      "Weekdays at midnight": "Dias úteis à meia-noite",
      "Weekends at midnight": "Fins de semana à meia-noite",
      "What the accessory is in HomeKit": "O que o acessório é no HomeKit",
      "What the added sensor is": "O que é o sensor adicionado",
      "When": "Quando",
      "When a cron schedule fires: a preset, or Custom for the expression below": "Quando um agendamento cron dispara: uma predefinição, ou Personalizado para a expressão abaixo",
      "When to put it back in its default state": "Quando o repor no estado predefinido",
      "When to trigger it: put it in the state other than its default": "Quando o disparar: pô-lo no estado diferente do predefinido",
      "Where the sun is watched, in decimal degrees": "Onde o sol é observado, em graus decimais",
      "Whether it adds or removes humidity": "Se adiciona ou retira humidade",
      "Whether the host must answer or not": "Se o anfitrião tem de responder ou não",
      "Window": "Janela",
      "Window covering": "Estore",
      "Exact position": "Posição exata",
      "Homeswift only: keeps the position set (0 to 100 %), as a real shutter does, rather than open or closed": "Só Homeswift: mantém a posição definida (de 0 a 100 %), como um estore real, em vez de aberto ou fechado"
    }
  }
}
"""#
}
