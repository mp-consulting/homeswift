// THIS FILE IS GENERATED from ../config.schema.json by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

extension HTTPWebhooksPlugin {
    /// The plugin's config.schema.json, as written, for settings forms and the config copilot.
    public static let configurationSchemaJSON: String? = #"""
{
  "pluginAlias": "HttpWebHooks",
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
        "default": "HTTP Webhooks"
      },
      "webhook_port": {
        "title": "Port",
        "type": "string",
        "description": "The port the webhook server listens on, 51828 by default",
        "placeholder": "51828"
      },
      "webhook_listen_host": {
        "title": "Listen address",
        "type": "string",
        "description": "0.0.0.0 by default (every IPv4 address); :: for IPv6 too, 127.0.0.1 for this machine alone",
        "placeholder": "0.0.0.0"
      },
      "webhook_enable_cors": {
        "title": "Allow browsers (CORS)",
        "type": "boolean",
        "description": "Answers OPTIONS and lets web pages of any site call the webhooks"
      },
      "http_auth_user": {
        "title": "User name",
        "type": "string",
        "description": "With the password, every request must give these with Basic authentication"
      },
      "http_auth_pass": {
        "title": "Password",
        "type": "string",
        "description": "Sealed in config.json by the bridge, or a vault: reference"
      },
      "https": {
        "title": "HTTPS",
        "type": "boolean",
        "description": "Serves the webhooks over HTTPS, with the files below or a self-signed certificate"
      },
      "https_keyfile": {
        "title": "Key file",
        "type": "string",
        "description": "The path of a PEM private key, with the certificate file"
      },
      "https_certfile": {
        "title": "Certificate file",
        "type": "string",
        "description": "The path of a PEM certificate, with the key file"
      },
      "cache_directory": {
        "title": "Cache directory",
        "type": "string",
        "description": "Read by Homebridge only: Homeswift keeps the states in the plugin's own folder"
      },
      "sensors": {
        "title": "Sensors",
        "type": "array",
        "description": "Set by state=true or false (contact, motion, occupancy, smoke) or value=<number>",
        "items": {
          "title": "Sensor",
          "type": "object",
          "properties": {
            "id": {
              "title": "ID",
              "type": "string",
              "description": "The webhook's accessoryId, and the key of the accessory's saved state",
              "required": true
            },
            "name": {
              "title": "Name",
              "type": "string",
              "description": "The accessory's name in HomeKit. It is also its identity: renaming the entry makes a new accessory",
              "required": true
            },
            "type": {
              "title": "Type",
              "type": "string",
              "description": "What the sensor measures or detects",
              "required": true,
              "oneOf": [
                {
                  "title": "Contact",
                  "enum": [
                    "contact"
                  ]
                },
                {
                  "title": "Motion",
                  "enum": [
                    "motion"
                  ]
                },
                {
                  "title": "Occupancy",
                  "enum": [
                    "occupancy"
                  ]
                },
                {
                  "title": "Smoke",
                  "enum": [
                    "smoke"
                  ]
                },
                {
                  "title": "Temperature",
                  "enum": [
                    "temperature"
                  ]
                },
                {
                  "title": "Humidity",
                  "enum": [
                    "humidity"
                  ]
                },
                {
                  "title": "Air quality",
                  "enum": [
                    "airquality"
                  ]
                },
                {
                  "title": "Light",
                  "enum": [
                    "light"
                  ]
                },
                {
                  "title": "Leak",
                  "enum": [
                    "leak"
                  ]
                }
              ]
            },
            "autoRelease": {
              "title": "Auto release",
              "type": "boolean",
              "description": "Contact, motion and occupancy sensors go back to rest on their own after the time below"
            },
            "autoReleaseTime": {
              "title": "Auto release time (in milliseconds)",
              "type": "integer",
              "description": "How long the sensor stays triggered, 5000 by default",
              "placeholder": 5000,
              "minimum": 0
            }
          }
        }
      },
      "switches": {
        "title": "Switches",
        "type": "array",
        "description": "Set by state=true or false",
        "items": {
          "title": "Switch",
          "type": "object",
          "properties": {
            "id": {
              "title": "ID",
              "type": "string",
              "description": "The webhook's accessoryId, and the key of the accessory's saved state",
              "required": true
            },
            "name": {
              "title": "Name",
              "type": "string",
              "description": "The accessory's name in HomeKit. It is also its identity: renaming the entry makes a new accessory",
              "required": true
            },
            "rejectUnauthorized": {
              "title": "Verify certificates",
              "type": "boolean",
              "description": "Check the certificate of the HTTPS URLs called. Off accepts a self-signed one",
              "default": true
            },
            "on_url": {
              "title": "On URL",
              "type": "string",
              "description": "The URL called when HomeKit turns it on"
            },
            "on_method": {
              "title": "Method",
              "type": "string",
              "description": "The request's HTTP method, GET by default. A body is sent with POST, PUT and PATCH",
              "placeholder": "GET"
            },
            "on_body": {
              "title": "Body",
              "type": "string",
              "description": "Sent as written with POST, PUT and PATCH; give its Content-Type in the headers"
            },
            "on_headers": {
              "title": "Headers",
              "type": "string",
              "description": "The request's headers, as a JSON object written as text. Kept in config.json as written: a token here is not sealed in the vault",
              "placeholder": "{}"
            },
            "off_url": {
              "title": "Off URL",
              "type": "string",
              "description": "The URL called when HomeKit turns it off"
            },
            "off_method": {
              "title": "Method",
              "type": "string",
              "description": "The request's HTTP method, GET by default. A body is sent with POST, PUT and PATCH",
              "placeholder": "GET"
            },
            "off_body": {
              "title": "Body",
              "type": "string",
              "description": "Sent as written with POST, PUT and PATCH; give its Content-Type in the headers"
            },
            "off_headers": {
              "title": "Headers",
              "type": "string",
              "description": "The request's headers, as a JSON object written as text. Kept in config.json as written: a token here is not sealed in the vault",
              "placeholder": "{}"
            }
          }
        }
      },
      "pushbuttons": {
        "title": "Push buttons",
        "type": "array",
        "description": "Switches that turn off a second after they are turned on; state=true presses one",
        "items": {
          "title": "Push button",
          "type": "object",
          "properties": {
            "id": {
              "title": "ID",
              "type": "string",
              "description": "The webhook's accessoryId, and the key of the accessory's saved state",
              "required": true
            },
            "name": {
              "title": "Name",
              "type": "string",
              "description": "The accessory's name in HomeKit. It is also its identity: renaming the entry makes a new accessory",
              "required": true
            },
            "rejectUnauthorized": {
              "title": "Verify certificates",
              "type": "boolean",
              "description": "Check the certificate of the HTTPS URLs called. Off accepts a self-signed one",
              "default": true
            },
            "push_url": {
              "title": "Push URL",
              "type": "string",
              "description": "The URL called when HomeKit presses the button"
            },
            "push_method": {
              "title": "Method",
              "type": "string",
              "description": "The request's HTTP method, GET by default. A body is sent with POST, PUT and PATCH",
              "placeholder": "GET"
            },
            "push_body": {
              "title": "Body",
              "type": "string",
              "description": "Sent as written with POST, PUT and PATCH; give its Content-Type in the headers"
            },
            "push_headers": {
              "title": "Headers",
              "type": "string",
              "description": "The request's headers, as a JSON object written as text. Kept in config.json as written: a token here is not sealed in the vault",
              "placeholder": "{}"
            }
          }
        }
      },
      "doorbells": {
        "title": "Doorbells",
        "type": "array",
        "description": "Rung by event=0 (single), 1 (double) or 2 (long press)",
        "items": {
          "title": "Doorbell",
          "type": "object",
          "properties": {
            "id": {
              "title": "ID",
              "type": "string",
              "description": "The webhook's accessoryId, and the key of the accessory's saved state",
              "required": true
            },
            "name": {
              "title": "Name",
              "type": "string",
              "description": "The accessory's name in HomeKit. It is also its identity: renaming the entry makes a new accessory",
              "required": true
            },
            "single_press": {
              "title": "Single press",
              "type": "boolean",
              "description": "Allows the single press event. On when missing"
            },
            "double_press": {
              "title": "Double press",
              "type": "boolean",
              "description": "Allows the double press event. On when missing"
            },
            "long_press": {
              "title": "Long press",
              "type": "boolean",
              "description": "Allows the long press event. On when missing"
            }
          }
        }
      },
      "lights": {
        "title": "Lights",
        "type": "array",
        "description": "Set by state=true or false and value=<brightness>",
        "items": {
          "title": "Light",
          "type": "object",
          "properties": {
            "id": {
              "title": "ID",
              "type": "string",
              "description": "The webhook's accessoryId, and the key of the accessory's saved state",
              "required": true
            },
            "name": {
              "title": "Name",
              "type": "string",
              "description": "The accessory's name in HomeKit. It is also its identity: renaming the entry makes a new accessory",
              "required": true
            },
            "rejectUnauthorized": {
              "title": "Verify certificates",
              "type": "boolean",
              "description": "Check the certificate of the HTTPS URLs called. Off accepts a self-signed one",
              "default": true
            },
            "brightness_factor": {
              "title": "Brightness factor",
              "type": "number",
              "description": "HomeKit's brightness (0 to 100) times this is the system's: 2.55 for 0 to 255. Webhook values are divided by it",
              "placeholder": 1
            },
            "on_url": {
              "title": "On URL",
              "type": "string",
              "description": "The URL called when HomeKit turns it on"
            },
            "on_method": {
              "title": "Method",
              "type": "string",
              "description": "The request's HTTP method, GET by default. A body is sent with POST, PUT and PATCH",
              "placeholder": "GET"
            },
            "on_body": {
              "title": "Body",
              "type": "string",
              "description": "Sent as written with POST, PUT and PATCH; give its Content-Type in the headers"
            },
            "on_headers": {
              "title": "Headers",
              "type": "string",
              "description": "The request's headers, as a JSON object written as text. Kept in config.json as written: a token here is not sealed in the vault",
              "placeholder": "{}"
            },
            "off_url": {
              "title": "Off URL",
              "type": "string",
              "description": "The URL called when HomeKit turns it off"
            },
            "off_method": {
              "title": "Method",
              "type": "string",
              "description": "The request's HTTP method, GET by default. A body is sent with POST, PUT and PATCH",
              "placeholder": "GET"
            },
            "off_body": {
              "title": "Body",
              "type": "string",
              "description": "Sent as written with POST, PUT and PATCH; give its Content-Type in the headers"
            },
            "off_headers": {
              "title": "Headers",
              "type": "string",
              "description": "The request's headers, as a JSON object written as text. Kept in config.json as written: a token here is not sealed in the vault",
              "placeholder": "{}"
            },
            "brightness_url": {
              "title": "Brightness URL",
              "type": "string",
              "description": "The URL called when HomeKit changes the brightness: %brightnessPlaceholder is the brightness times the factor, %statusPlaceholder true or false"
            },
            "brightness_method": {
              "title": "Method",
              "type": "string",
              "description": "The request's HTTP method, GET by default. A body is sent with POST, PUT and PATCH",
              "placeholder": "GET"
            },
            "brightness_body": {
              "title": "Body",
              "type": "string",
              "description": "Sent as written with POST, PUT and PATCH; give its Content-Type in the headers"
            },
            "brightness_headers": {
              "title": "Headers",
              "type": "string",
              "description": "The request's headers, as a JSON object written as text. Kept in config.json as written: a token here is not sealed in the vault",
              "placeholder": "{}"
            }
          }
        }
      },
      "thermostats": {
        "title": "Thermostats",
        "type": "array",
        "description": "Set by currenttemperature, targettemperature, currentstate and targetstate",
        "items": {
          "title": "Thermostat",
          "type": "object",
          "properties": {
            "id": {
              "title": "ID",
              "type": "string",
              "description": "The webhook's accessoryId, and the key of the accessory's saved state",
              "required": true
            },
            "name": {
              "title": "Name",
              "type": "string",
              "description": "The accessory's name in HomeKit. It is also its identity: renaming the entry makes a new accessory",
              "required": true
            },
            "rejectUnauthorized": {
              "title": "Verify certificates",
              "type": "boolean",
              "description": "Check the certificate of the HTTPS URLs called. Off accepts a self-signed one",
              "default": true
            },
            "minTemp": {
              "title": "Minimum target temperature",
              "type": "number",
              "description": "In degrees Celsius, 15 by default",
              "placeholder": 15
            },
            "maxTemp": {
              "title": "Maximum target temperature",
              "type": "number",
              "description": "In degrees Celsius, 30 by default",
              "placeholder": 30
            },
            "minStep": {
              "title": "Target temperature step",
              "type": "number",
              "description": "In degrees Celsius, 0.5 by default",
              "placeholder": 0.5
            },
            "set_target_temperature_url": {
              "title": "Target temperature URL",
              "type": "string",
              "description": "The URL called when HomeKit changes the target temperature, which replaces %f in it"
            },
            "set_target_temperature_method": {
              "title": "Method",
              "type": "string",
              "description": "The request's HTTP method, GET by default. A body is sent with POST, PUT and PATCH",
              "placeholder": "GET"
            },
            "set_target_temperature_body": {
              "title": "Body",
              "type": "string",
              "description": "Sent as written with POST, PUT and PATCH; give its Content-Type in the headers"
            },
            "set_target_temperature_headers": {
              "title": "Headers",
              "type": "string",
              "description": "The request's headers, as a JSON object written as text. Kept in config.json as written: a token here is not sealed in the vault",
              "placeholder": "{}"
            },
            "set_target_heating_cooling_state_url": {
              "title": "Mode URL",
              "type": "string",
              "description": "The URL called when HomeKit changes the mode, which replaces %b in it: 0 off, 1 heat, 2 cool, 3 auto"
            },
            "set_target_heating_cooling_state_method": {
              "title": "Method",
              "type": "string",
              "description": "The request's HTTP method, GET by default. A body is sent with POST, PUT and PATCH",
              "placeholder": "GET"
            },
            "set_target_heating_cooling_state_body": {
              "title": "Body",
              "type": "string",
              "description": "Sent as written with POST, PUT and PATCH; give its Content-Type in the headers"
            },
            "set_target_heating_cooling_state_headers": {
              "title": "Headers",
              "type": "string",
              "description": "The request's headers, as a JSON object written as text. Kept in config.json as written: a token here is not sealed in the vault",
              "placeholder": "{}"
            }
          }
        }
      },
      "outlets": {
        "title": "Outlets",
        "type": "array",
        "description": "Set by state=true or false and stateOutletInUse=true or false",
        "items": {
          "title": "Outlet",
          "type": "object",
          "properties": {
            "id": {
              "title": "ID",
              "type": "string",
              "description": "The webhook's accessoryId, and the key of the accessory's saved state",
              "required": true
            },
            "name": {
              "title": "Name",
              "type": "string",
              "description": "The accessory's name in HomeKit. It is also its identity: renaming the entry makes a new accessory",
              "required": true
            },
            "rejectUnauthorized": {
              "title": "Verify certificates",
              "type": "boolean",
              "description": "Check the certificate of the HTTPS URLs called. Off accepts a self-signed one",
              "default": true
            },
            "on_url": {
              "title": "On URL",
              "type": "string",
              "description": "The URL called when HomeKit turns it on"
            },
            "on_method": {
              "title": "Method",
              "type": "string",
              "description": "The request's HTTP method, GET by default. A body is sent with POST, PUT and PATCH",
              "placeholder": "GET"
            },
            "on_body": {
              "title": "Body",
              "type": "string",
              "description": "Sent as written with POST, PUT and PATCH; give its Content-Type in the headers"
            },
            "on_headers": {
              "title": "Headers",
              "type": "string",
              "description": "The request's headers, as a JSON object written as text. Kept in config.json as written: a token here is not sealed in the vault",
              "placeholder": "{}"
            },
            "off_url": {
              "title": "Off URL",
              "type": "string",
              "description": "The URL called when HomeKit turns it off"
            },
            "off_method": {
              "title": "Method",
              "type": "string",
              "description": "The request's HTTP method, GET by default. A body is sent with POST, PUT and PATCH",
              "placeholder": "GET"
            },
            "off_body": {
              "title": "Body",
              "type": "string",
              "description": "Sent as written with POST, PUT and PATCH; give its Content-Type in the headers"
            },
            "off_headers": {
              "title": "Headers",
              "type": "string",
              "description": "The request's headers, as a JSON object written as text. Kept in config.json as written: a token here is not sealed in the vault",
              "placeholder": "{}"
            }
          }
        }
      },
      "security": {
        "title": "Security systems",
        "type": "array",
        "description": "Set by currentstate (0 to 4) and targetstate (0 to 3)",
        "items": {
          "title": "Security system",
          "type": "object",
          "properties": {
            "id": {
              "title": "ID",
              "type": "string",
              "description": "The webhook's accessoryId, and the key of the accessory's saved state",
              "required": true
            },
            "name": {
              "title": "Name",
              "type": "string",
              "description": "The accessory's name in HomeKit. It is also its identity: renaming the entry makes a new accessory",
              "required": true
            },
            "rejectUnauthorized": {
              "title": "Verify certificates",
              "type": "boolean",
              "description": "Check the certificate of the HTTPS URLs called. Off accepts a self-signed one",
              "default": true
            },
            "set_state_url": {
              "title": "Security mode URL",
              "type": "string",
              "description": "The URL called when HomeKit changes the security mode, which replaces %d in it: 0 home, 1 away, 2 night, 3 off"
            },
            "set_state_method": {
              "title": "Method",
              "type": "string",
              "description": "The request's HTTP method, GET by default. A body is sent with POST, PUT and PATCH",
              "placeholder": "GET"
            },
            "set_state_body": {
              "title": "Body",
              "type": "string",
              "description": "Sent as written with POST, PUT and PATCH; give its Content-Type in the headers"
            },
            "set_state_headers": {
              "title": "Headers",
              "type": "string",
              "description": "The request's headers, as a JSON object written as text. Kept in config.json as written: a token here is not sealed in the vault",
              "placeholder": "{}"
            }
          }
        }
      },
      "garagedooropeners": {
        "title": "Garage doors",
        "type": "array",
        "description": "Set by currentdoorstate, targetdoorstate and obstructiondetected",
        "items": {
          "title": "Garage door",
          "type": "object",
          "properties": {
            "id": {
              "title": "ID",
              "type": "string",
              "description": "The webhook's accessoryId, and the key of the accessory's saved state",
              "required": true
            },
            "name": {
              "title": "Name",
              "type": "string",
              "description": "The accessory's name in HomeKit. It is also its identity: renaming the entry makes a new accessory",
              "required": true
            },
            "rejectUnauthorized": {
              "title": "Verify certificates",
              "type": "boolean",
              "description": "Check the certificate of the HTTPS URLs called. Off accepts a self-signed one",
              "default": true
            },
            "open_url": {
              "title": "Open URL",
              "type": "string",
              "description": "The URL called when HomeKit opens the door"
            },
            "open_method": {
              "title": "Method",
              "type": "string",
              "description": "The request's HTTP method, GET by default. A body is sent with POST, PUT and PATCH",
              "placeholder": "GET"
            },
            "open_body": {
              "title": "Body",
              "type": "string",
              "description": "Sent as written with POST, PUT and PATCH; give its Content-Type in the headers"
            },
            "open_headers": {
              "title": "Headers",
              "type": "string",
              "description": "The request's headers, as a JSON object written as text. Kept in config.json as written: a token here is not sealed in the vault",
              "placeholder": "{}"
            },
            "close_url": {
              "title": "Close URL",
              "type": "string",
              "description": "The URL called when HomeKit closes the door"
            },
            "close_method": {
              "title": "Method",
              "type": "string",
              "description": "The request's HTTP method, GET by default. A body is sent with POST, PUT and PATCH",
              "placeholder": "GET"
            },
            "close_body": {
              "title": "Body",
              "type": "string",
              "description": "Sent as written with POST, PUT and PATCH; give its Content-Type in the headers"
            },
            "close_headers": {
              "title": "Headers",
              "type": "string",
              "description": "The request's headers, as a JSON object written as text. Kept in config.json as written: a token here is not sealed in the vault",
              "placeholder": "{}"
            }
          }
        }
      },
      "statelessswitches": {
        "title": "Stateless switches",
        "type": "array",
        "description": "Buttons pressed by buttonName=<name> and event=0, 1 or 2",
        "items": {
          "title": "Stateless switch",
          "type": "object",
          "properties": {
            "id": {
              "title": "ID",
              "type": "string",
              "description": "The webhook's accessoryId, and the key of the accessory's saved state",
              "required": true
            },
            "name": {
              "title": "Name",
              "type": "string",
              "description": "The accessory's name in HomeKit. It is also its identity: renaming the entry makes a new accessory",
              "required": true
            },
            "buttons": {
              "title": "Buttons",
              "type": "array",
              "description": "One button per entry, in order; a webhook presses it by its name",
              "items": {
                "title": "Button",
                "type": "object",
                "properties": {
                  "name": {
                    "title": "Name",
                    "type": "string",
                    "description": "The button's name, the webhook's buttonName",
                    "required": true
                  },
                  "single_press": {
                    "title": "Single press",
                    "type": "boolean",
                    "description": "Allows the single press event. On when missing"
                  },
                  "double_press": {
                    "title": "Double press",
                    "type": "boolean",
                    "description": "Allows the double press event. On when missing"
                  },
                  "long_press": {
                    "title": "Long press",
                    "type": "boolean",
                    "description": "Allows the long press event. On when missing"
                  }
                }
              }
            }
          }
        }
      },
      "windowcoverings": {
        "title": "Window coverings",
        "type": "array",
        "description": "Set by currentposition, targetposition (0 to 100) and positionstate",
        "items": {
          "title": "Window covering",
          "type": "object",
          "properties": {
            "id": {
              "title": "ID",
              "type": "string",
              "description": "The webhook's accessoryId, and the key of the accessory's saved state",
              "required": true
            },
            "name": {
              "title": "Name",
              "type": "string",
              "description": "The accessory's name in HomeKit. It is also its identity: renaming the entry makes a new accessory",
              "required": true
            },
            "rejectUnauthorized": {
              "title": "Verify certificates",
              "type": "boolean",
              "description": "Check the certificate of the HTTPS URLs called. Off accepts a self-signed one",
              "default": true
            },
            "auto_set_current_position": {
              "title": "Set the current position",
              "type": "boolean",
              "description": "Once a call worked, the current position follows the target a second later"
            },
            "open_url": {
              "title": "Position 0 URL",
              "type": "string",
              "description": "The URL called when HomeKit sets the position to 0"
            },
            "open_method": {
              "title": "Method",
              "type": "string",
              "description": "The request's HTTP method, GET by default. A body is sent with POST, PUT and PATCH",
              "placeholder": "GET"
            },
            "open_body": {
              "title": "Body",
              "type": "string",
              "description": "Sent as written with POST, PUT and PATCH; give its Content-Type in the headers"
            },
            "open_headers": {
              "title": "Headers",
              "type": "string",
              "description": "The request's headers, as a JSON object written as text. Kept in config.json as written: a token here is not sealed in the vault",
              "placeholder": "{}"
            },
            "open_20_url": {
              "title": "Position 1–25 URL",
              "type": "string",
              "description": "The URL called when HomeKit sets the position to 1–25"
            },
            "open_20_method": {
              "title": "Method",
              "type": "string",
              "description": "The request's HTTP method, GET by default. A body is sent with POST, PUT and PATCH",
              "placeholder": "GET"
            },
            "open_20_body": {
              "title": "Body",
              "type": "string",
              "description": "Sent as written with POST, PUT and PATCH; give its Content-Type in the headers"
            },
            "open_20_headers": {
              "title": "Headers",
              "type": "string",
              "description": "The request's headers, as a JSON object written as text. Kept in config.json as written: a token here is not sealed in the vault",
              "placeholder": "{}"
            },
            "open_40_url": {
              "title": "Position 26–45 URL",
              "type": "string",
              "description": "The URL called when HomeKit sets the position to 26–45"
            },
            "open_40_method": {
              "title": "Method",
              "type": "string",
              "description": "The request's HTTP method, GET by default. A body is sent with POST, PUT and PATCH",
              "placeholder": "GET"
            },
            "open_40_body": {
              "title": "Body",
              "type": "string",
              "description": "Sent as written with POST, PUT and PATCH; give its Content-Type in the headers"
            },
            "open_40_headers": {
              "title": "Headers",
              "type": "string",
              "description": "The request's headers, as a JSON object written as text. Kept in config.json as written: a token here is not sealed in the vault",
              "placeholder": "{}"
            },
            "open_60_url": {
              "title": "Position 46–65 URL",
              "type": "string",
              "description": "The URL called when HomeKit sets the position to 46–65"
            },
            "open_60_method": {
              "title": "Method",
              "type": "string",
              "description": "The request's HTTP method, GET by default. A body is sent with POST, PUT and PATCH",
              "placeholder": "GET"
            },
            "open_60_body": {
              "title": "Body",
              "type": "string",
              "description": "Sent as written with POST, PUT and PATCH; give its Content-Type in the headers"
            },
            "open_60_headers": {
              "title": "Headers",
              "type": "string",
              "description": "The request's headers, as a JSON object written as text. Kept in config.json as written: a token here is not sealed in the vault",
              "placeholder": "{}"
            },
            "open_80_url": {
              "title": "Position 66–94 URL",
              "type": "string",
              "description": "The URL called when HomeKit sets the position to 66–94"
            },
            "open_80_method": {
              "title": "Method",
              "type": "string",
              "description": "The request's HTTP method, GET by default. A body is sent with POST, PUT and PATCH",
              "placeholder": "GET"
            },
            "open_80_body": {
              "title": "Body",
              "type": "string",
              "description": "Sent as written with POST, PUT and PATCH; give its Content-Type in the headers"
            },
            "open_80_headers": {
              "title": "Headers",
              "type": "string",
              "description": "The request's headers, as a JSON object written as text. Kept in config.json as written: a token here is not sealed in the vault",
              "placeholder": "{}"
            },
            "close_url": {
              "title": "Position 95–100 URL",
              "type": "string",
              "description": "The URL called when HomeKit sets the position to 95–100"
            },
            "close_method": {
              "title": "Method",
              "type": "string",
              "description": "The request's HTTP method, GET by default. A body is sent with POST, PUT and PATCH",
              "placeholder": "GET"
            },
            "close_body": {
              "title": "Body",
              "type": "string",
              "description": "Sent as written with POST, PUT and PATCH; give its Content-Type in the headers"
            },
            "close_headers": {
              "title": "Headers",
              "type": "string",
              "description": "The request's headers, as a JSON object written as text. Kept in config.json as written: a token here is not sealed in the vault",
              "placeholder": "{}"
            }
          }
        }
      },
      "lockmechanisms": {
        "title": "Locks",
        "type": "array",
        "description": "Set by lockcurrentstate (0 to 3) and locktargetstate (0 or 1)",
        "items": {
          "title": "Lock",
          "type": "object",
          "properties": {
            "id": {
              "title": "ID",
              "type": "string",
              "description": "The webhook's accessoryId, and the key of the accessory's saved state",
              "required": true
            },
            "name": {
              "title": "Name",
              "type": "string",
              "description": "The accessory's name in HomeKit. It is also its identity: renaming the entry makes a new accessory",
              "required": true
            },
            "rejectUnauthorized": {
              "title": "Verify certificates",
              "type": "boolean",
              "description": "Check the certificate of the HTTPS URLs called. Off accepts a self-signed one",
              "default": true
            },
            "open_url": {
              "title": "Unlock URL",
              "type": "string",
              "description": "The URL called when HomeKit unlocks it"
            },
            "open_method": {
              "title": "Method",
              "type": "string",
              "description": "The request's HTTP method, GET by default. A body is sent with POST, PUT and PATCH",
              "placeholder": "GET"
            },
            "open_body": {
              "title": "Body",
              "type": "string",
              "description": "Sent as written with POST, PUT and PATCH; give its Content-Type in the headers"
            },
            "open_headers": {
              "title": "Headers",
              "type": "string",
              "description": "The request's headers, as a JSON object written as text. Kept in config.json as written: a token here is not sealed in the vault",
              "placeholder": "{}"
            },
            "close_url": {
              "title": "Lock URL",
              "type": "string",
              "description": "The URL called when HomeKit locks it"
            },
            "close_method": {
              "title": "Method",
              "type": "string",
              "description": "The request's HTTP method, GET by default. A body is sent with POST, PUT and PATCH",
              "placeholder": "GET"
            },
            "close_body": {
              "title": "Body",
              "type": "string",
              "description": "Sent as written with POST, PUT and PATCH; give its Content-Type in the headers"
            },
            "close_headers": {
              "title": "Headers",
              "type": "string",
              "description": "The request's headers, as a JSON object written as text. Kept in config.json as written: a token here is not sealed in the vault",
              "placeholder": "{}"
            }
          }
        }
      },
      "fanv2s": {
        "title": "Fans",
        "type": "array",
        "description": "Set by state, speed, rotationDirection, lockstate, targetState and swingMode",
        "items": {
          "title": "Fan",
          "type": "object",
          "properties": {
            "id": {
              "title": "ID",
              "type": "string",
              "description": "The webhook's accessoryId, and the key of the accessory's saved state",
              "required": true
            },
            "name": {
              "title": "Name",
              "type": "string",
              "description": "The accessory's name in HomeKit. It is also its identity: renaming the entry makes a new accessory",
              "required": true
            },
            "rejectUnauthorized": {
              "title": "Verify certificates",
              "type": "boolean",
              "description": "Check the certificate of the HTTPS URLs called. Off accepts a self-signed one",
              "default": true
            },
            "speed_factor": {
              "title": "Speed factor",
              "type": "number",
              "description": "HomeKit's speed (0 to 100) times this is sent to the system",
              "placeholder": 1
            },
            "enableLockPhysicalControls": {
              "title": "Lock physical controls",
              "type": "boolean",
              "description": "Adds Lock Physical Controls (lockstate)"
            },
            "enableTargetStateControls": {
              "title": "Fan mode",
              "type": "boolean",
              "description": "Adds Target Fan State, manual or auto (targetState)"
            },
            "enableSwingModeControls": {
              "title": "Swing mode",
              "type": "boolean",
              "description": "Adds Swing Mode (swingMode)"
            },
            "on_url": {
              "title": "On URL",
              "type": "string",
              "description": "The URL called when HomeKit turns it on"
            },
            "on_method": {
              "title": "Method",
              "type": "string",
              "description": "The request's HTTP method, GET by default. A body is sent with POST, PUT and PATCH",
              "placeholder": "GET"
            },
            "on_body": {
              "title": "Body",
              "type": "string",
              "description": "Sent as written with POST, PUT and PATCH; give its Content-Type in the headers"
            },
            "on_headers": {
              "title": "Headers",
              "type": "string",
              "description": "The request's headers, as a JSON object written as text. Kept in config.json as written: a token here is not sealed in the vault",
              "placeholder": "{}"
            },
            "off_url": {
              "title": "Off URL",
              "type": "string",
              "description": "The URL called when HomeKit turns it off"
            },
            "off_method": {
              "title": "Method",
              "type": "string",
              "description": "The request's HTTP method, GET by default. A body is sent with POST, PUT and PATCH",
              "placeholder": "GET"
            },
            "off_body": {
              "title": "Body",
              "type": "string",
              "description": "Sent as written with POST, PUT and PATCH; give its Content-Type in the headers"
            },
            "off_headers": {
              "title": "Headers",
              "type": "string",
              "description": "The request's headers, as a JSON object written as text. Kept in config.json as written: a token here is not sealed in the vault",
              "placeholder": "{}"
            },
            "speed_url": {
              "title": "Speed URL",
              "type": "string",
              "description": "The URL called when HomeKit changes the speed: %speedPlaceholder is the speed times the factor, %statusPlaceholder true or false"
            },
            "speed_method": {
              "title": "Method",
              "type": "string",
              "description": "The request's HTTP method, GET by default. A body is sent with POST, PUT and PATCH",
              "placeholder": "GET"
            },
            "speed_body": {
              "title": "Body",
              "type": "string",
              "description": "Sent as written with POST, PUT and PATCH; give its Content-Type in the headers"
            },
            "speed_headers": {
              "title": "Headers",
              "type": "string",
              "description": "The request's headers, as a JSON object written as text. Kept in config.json as written: a token here is not sealed in the vault",
              "placeholder": "{}"
            },
            "lock_url": {
              "title": "Lock controls URL",
              "type": "string",
              "description": "The URL called when HomeKit locks the physical controls"
            },
            "lock_method": {
              "title": "Method",
              "type": "string",
              "description": "The request's HTTP method, GET by default. A body is sent with POST, PUT and PATCH",
              "placeholder": "GET"
            },
            "lock_body": {
              "title": "Body",
              "type": "string",
              "description": "Sent as written with POST, PUT and PATCH; give its Content-Type in the headers"
            },
            "lock_headers": {
              "title": "Headers",
              "type": "string",
              "description": "The request's headers, as a JSON object written as text. Kept in config.json as written: a token here is not sealed in the vault",
              "placeholder": "{}"
            },
            "unlock_url": {
              "title": "Unlock controls URL",
              "type": "string",
              "description": "The URL called when HomeKit unlocks the physical controls"
            },
            "unlock_method": {
              "title": "Method",
              "type": "string",
              "description": "The request's HTTP method, GET by default. A body is sent with POST, PUT and PATCH",
              "placeholder": "GET"
            },
            "unlock_body": {
              "title": "Body",
              "type": "string",
              "description": "Sent as written with POST, PUT and PATCH; give its Content-Type in the headers"
            },
            "unlock_headers": {
              "title": "Headers",
              "type": "string",
              "description": "The request's headers, as a JSON object written as text. Kept in config.json as written: a token here is not sealed in the vault",
              "placeholder": "{}"
            },
            "target_state_url": {
              "title": "Fan mode URL",
              "type": "string",
              "description": "The URL called when HomeKit changes the fan mode, which replaces %targetState in it and in the body: 0 manual, 1 auto"
            },
            "target_state_method": {
              "title": "Method",
              "type": "string",
              "description": "The request's HTTP method, GET by default. A body is sent with POST, PUT and PATCH",
              "placeholder": "GET"
            },
            "target_state_body": {
              "title": "Body",
              "type": "string",
              "description": "Sent as written with POST, PUT and PATCH; give its Content-Type in the headers"
            },
            "target_state_headers": {
              "title": "Headers",
              "type": "string",
              "description": "The request's headers, as a JSON object written as text. Kept in config.json as written: a token here is not sealed in the vault",
              "placeholder": "{}"
            },
            "swing_mode_url": {
              "title": "Swing mode URL",
              "type": "string",
              "description": "The URL called when HomeKit changes the swing mode, which replaces %swingMode in it and in the body"
            },
            "swing_mode_method": {
              "title": "Method",
              "type": "string",
              "description": "The request's HTTP method, GET by default. A body is sent with POST, PUT and PATCH",
              "placeholder": "GET"
            },
            "swing_mode_body": {
              "title": "Body",
              "type": "string",
              "description": "Sent as written with POST, PUT and PATCH; give its Content-Type in the headers"
            },
            "swing_mode_headers": {
              "title": "Headers",
              "type": "string",
              "description": "The request's headers, as a JSON object written as text. Kept in config.json as written: a token here is not sealed in the vault",
              "placeholder": "{}"
            },
            "rotation_direction_url": {
              "title": "Rotation direction URL",
              "type": "string",
              "description": "The URL called when HomeKit changes the rotation direction, which replaces %rotationDirection in it and in the body"
            },
            "rotation_direction_method": {
              "title": "Method",
              "type": "string",
              "description": "The request's HTTP method, GET by default. A body is sent with POST, PUT and PATCH",
              "placeholder": "GET"
            },
            "rotation_direction_body": {
              "title": "Body",
              "type": "string",
              "description": "Sent as written with POST, PUT and PATCH; give its Content-Type in the headers"
            },
            "rotation_direction_headers": {
              "title": "Headers",
              "type": "string",
              "description": "The request's headers, as a JSON object written as text. Kept in config.json as written: a token here is not sealed in the vault",
              "placeholder": "{}"
            }
          }
        }
      },
      "co2sensors": {
        "title": "CO2 sensors",
        "type": "array",
        "description": "Set by value=<ppm>",
        "items": {
          "title": "CO2 sensor",
          "type": "object",
          "properties": {
            "id": {
              "title": "ID",
              "type": "string",
              "description": "The webhook's accessoryId, and the key of the accessory's saved state",
              "required": true
            },
            "name": {
              "title": "Name",
              "type": "string",
              "description": "The accessory's name in HomeKit. It is also its identity: renaming the entry makes a new accessory",
              "required": true
            },
            "co2_peak_level": {
              "title": "Peak level (ppm)",
              "type": "integer",
              "description": "Above this level the sensor reports abnormal, 1200 by default",
              "placeholder": 1200
            }
          }
        }
      },
      "valves": {
        "title": "Valves",
        "type": "array",
        "description": "Set by state=true or false and statusFault=true or false",
        "items": {
          "title": "Valve",
          "type": "object",
          "properties": {
            "id": {
              "title": "ID",
              "type": "string",
              "description": "The webhook's accessoryId, and the key of the accessory's saved state",
              "required": true
            },
            "name": {
              "title": "Name",
              "type": "string",
              "description": "The accessory's name in HomeKit. It is also its identity: renaming the entry makes a new accessory",
              "required": true
            },
            "rejectUnauthorized": {
              "title": "Verify certificates",
              "type": "boolean",
              "description": "Check the certificate of the HTTPS URLs called. Off accepts a self-signed one",
              "default": true
            },
            "type": {
              "title": "Valve type",
              "type": "string",
              "description": "How the Home app shows the valve",
              "oneOf": [
                {
                  "title": "Generic valve",
                  "enum": [
                    "generic valve"
                  ]
                },
                {
                  "title": "Irrigation",
                  "enum": [
                    "irrigation"
                  ]
                },
                {
                  "title": "Shower head",
                  "enum": [
                    "shower head"
                  ]
                },
                {
                  "title": "Water faucet",
                  "enum": [
                    "water faucet"
                  ]
                }
              ]
            },
            "on_url": {
              "title": "On URL",
              "type": "string",
              "description": "The URL called when HomeKit turns it on"
            },
            "on_method": {
              "title": "Method",
              "type": "string",
              "description": "The request's HTTP method, GET by default. A body is sent with POST, PUT and PATCH",
              "placeholder": "GET"
            },
            "on_body": {
              "title": "Body",
              "type": "string",
              "description": "Sent as written with POST, PUT and PATCH; give its Content-Type in the headers"
            },
            "on_headers": {
              "title": "Headers",
              "type": "string",
              "description": "The request's headers, as a JSON object written as text. Kept in config.json as written: a token here is not sealed in the vault",
              "placeholder": "{}"
            },
            "off_url": {
              "title": "Off URL",
              "type": "string",
              "description": "The URL called when HomeKit turns it off"
            },
            "off_method": {
              "title": "Method",
              "type": "string",
              "description": "The request's HTTP method, GET by default. A body is sent with POST, PUT and PATCH",
              "placeholder": "GET"
            },
            "off_body": {
              "title": "Body",
              "type": "string",
              "description": "Sent as written with POST, PUT and PATCH; give its Content-Type in the headers"
            },
            "off_headers": {
              "title": "Headers",
              "type": "string",
              "description": "The request's headers, as a JSON object written as text. Kept in config.json as written: a token here is not sealed in the vault",
              "placeholder": "{}"
            }
          }
        }
      }
    }
  },
  "i18n": {
    "fr": {
      "0.0.0.0 by default (every IPv4 address); :: for IPv6 too, 127.0.0.1 for this machine alone": "0.0.0.0 par défaut (toutes les adresses IPv4) ; :: pour IPv6 aussi, 127.0.0.1 pour cette machine seule",
      "Above this level the sensor reports abnormal, 1200 by default": "Au-dessus de ce niveau, le capteur signale une valeur anormale, 1200 par défaut",
      "Adds Lock Physical Controls (lockstate)": "Ajoute Lock Physical Controls (lockstate)",
      "Adds Swing Mode (swingMode)": "Ajoute Swing Mode (swingMode)",
      "Adds Target Fan State, manual or auto (targetState)": "Ajoute Target Fan State, manuel ou auto (targetState)",
      "Air quality": "Qualité de l'air",
      "Allow browsers (CORS)": "Autoriser les navigateurs (CORS)",
      "Allows the double press event. On when missing": "Autorise l'événement double appui. Activé s'il manque",
      "Allows the long press event. On when missing": "Autorise l'événement appui long. Activé s'il manque",
      "Allows the single press event. On when missing": "Autorise l'événement appui simple. Activé s'il manque",
      "Answers OPTIONS and lets web pages of any site call the webhooks": "Répond à OPTIONS et laisse les pages web de tout site appeler les webhooks",
      "Auto release": "Retour automatique",
      "Auto release time (in milliseconds)": "Délai du retour automatique (en millisecondes)",
      "Body": "Corps",
      "Brightness URL": "URL de luminosité",
      "Brightness factor": "Facteur de luminosité",
      "Button": "Bouton",
      "Buttons": "Boutons",
      "Buttons pressed by buttonName=<name> and event=0, 1 or 2": "Boutons actionnés par buttonName=<nom> et event=0, 1 ou 2",
      "CO2 sensor": "Capteur de CO2",
      "CO2 sensors": "Capteurs de CO2",
      "Cache directory": "Dossier du cache",
      "Certificate file": "Fichier de certificat",
      "Check the certificate of the HTTPS URLs called. Off accepts a self-signed one": "Vérifier le certificat des URL HTTPS appelées. Désactivé, un certificat auto-signé est accepté",
      "Close URL": "URL de fermeture",
      "Contact": "Contact",
      "Contact, motion and occupancy sensors go back to rest on their own after the time below": "Les capteurs de contact, de mouvement et de présence reviennent seuls au repos après le délai ci-dessous",
      "Doorbell": "Sonnette",
      "Doorbells": "Sonnettes",
      "Double press": "Double appui",
      "Fan": "Ventilateur",
      "Fan mode": "Mode du ventilateur",
      "Fan mode URL": "URL de mode du ventilateur",
      "Fans": "Ventilateurs",
      "Garage door": "Porte de garage",
      "Garage doors": "Portes de garage",
      "Generic valve": "Vanne générique",
      "HTTPS": "HTTPS",
      "Headers": "En-têtes",
      "HomeKit's brightness (0 to 100) times this is the system's: 2.55 for 0 to 255. Webhook values are divided by it": "La luminosité de HomeKit (0 à 100) multipliée par ce facteur donne celle du système : 2,55 pour 0 à 255. Les valeurs des webhooks sont divisées par lui",
      "HomeKit's speed (0 to 100) times this is sent to the system": "La vitesse de HomeKit (0 à 100) multipliée par ce facteur est envoyée au système",
      "How long the sensor stays triggered, 5000 by default": "Combien de temps le capteur reste déclenché, 5000 par défaut",
      "How the Home app shows the valve": "Comment l'app Maison affiche la vanne",
      "Humidity": "Humidité",
      "ID": "Identifiant",
      "In degrees Celsius, 0.5 by default": "En degrés Celsius, 0,5 par défaut",
      "In degrees Celsius, 15 by default": "En degrés Celsius, 15 par défaut",
      "In degrees Celsius, 30 by default": "En degrés Celsius, 30 par défaut",
      "Irrigation": "Arrosage",
      "Key file": "Fichier de clé",
      "Leak": "Fuite",
      "Light": "Lumière",
      "Lights": "Lumières",
      "Listen address": "Adresse d'écoute",
      "Lock": "Serrure",
      "Lock URL": "URL de verrouillage",
      "Lock controls URL": "URL de verrouillage des commandes",
      "Lock physical controls": "Verrouillage des commandes physiques",
      "Locks": "Serrures",
      "Long press": "Appui long",
      "Maximum target temperature": "Température cible maximale",
      "Method": "Méthode",
      "Minimum target temperature": "Température cible minimale",
      "Mode URL": "URL de mode",
      "Motion": "Mouvement",
      "Name": "Nom",
      "Occupancy": "Présence",
      "Off URL": "URL d'extinction",
      "On URL": "URL d'allumage",
      "Once a call worked, the current position follows the target a second later": "Une fois l'appel réussi, la position actuelle suit la cible une seconde plus tard",
      "One button per entry, in order; a webhook presses it by its name": "Un bouton par entrée, dans l'ordre ; un webhook l'actionne par son nom",
      "Open URL": "URL d'ouverture",
      "Outlet": "Prise",
      "Outlets": "Prises",
      "Password": "Mot de passe",
      "Peak level (ppm)": "Seuil (ppm)",
      "Plugin name as shown in the logs": "Nom du plugin tel qu'affiché dans les journaux",
      "Port": "Port",
      "Position 0 URL": "URL de position 0",
      "Position 1–25 URL": "URL de position 1–25",
      "Position 26–45 URL": "URL de position 26–45",
      "Position 46–65 URL": "URL de position 46–65",
      "Position 66–94 URL": "URL de position 66–94",
      "Position 95–100 URL": "URL de position 95–100",
      "Push URL": "URL d'appui",
      "Push button": "Bouton poussoir",
      "Push buttons": "Boutons poussoirs",
      "Read by Homebridge only: Homeswift keeps the states in the plugin's own folder": "Lu par Homebridge seulement : Homeswift garde les états dans le dossier du plugin",
      "Rotation direction URL": "URL de sens de rotation",
      "Rung by event=0 (single), 1 (double) or 2 (long press)": "Sonnées par event=0 (simple), 1 (double) ou 2 (appui long)",
      "Sealed in config.json by the bridge, or a vault: reference": "Scellé dans config.json par le pont, ou une référence vault:",
      "Security mode URL": "URL de mode de sécurité",
      "Security system": "Système de sécurité",
      "Security systems": "Systèmes de sécurité",
      "Sensor": "Capteur",
      "Sensors": "Capteurs",
      "Sent as written with POST, PUT and PATCH; give its Content-Type in the headers": "Envoyé tel quel avec POST, PUT et PATCH ; indiquez son Content-Type dans les en-têtes",
      "Serves the webhooks over HTTPS, with the files below or a self-signed certificate": "Sert les webhooks en HTTPS, avec les fichiers ci-dessous ou un certificat auto-signé",
      "Set by currentdoorstate, targetdoorstate and obstructiondetected": "Réglées par currentdoorstate, targetdoorstate et obstructiondetected",
      "Set by currentposition, targetposition (0 to 100) and positionstate": "Réglés par currentposition, targetposition (0 à 100) et positionstate",
      "Set by currentstate (0 to 4) and targetstate (0 to 3)": "Réglés par currentstate (0 à 4) et targetstate (0 à 3)",
      "Set by currenttemperature, targettemperature, currentstate and targetstate": "Réglés par currenttemperature, targettemperature, currentstate et targetstate",
      "Set by lockcurrentstate (0 to 3) and locktargetstate (0 or 1)": "Réglées par lockcurrentstate (0 à 3) et locktargetstate (0 ou 1)",
      "Set by state, speed, rotationDirection, lockstate, targetState and swingMode": "Réglés par state, speed, rotationDirection, lockstate, targetState et swingMode",
      "Set by state=true or false": "Réglés par state=true ou false",
      "Set by state=true or false (contact, motion, occupancy, smoke) or value=<number>": "Réglés par state=true ou false (contact, mouvement, présence, fumée) ou value=<nombre>",
      "Set by state=true or false and stateOutletInUse=true or false": "Réglées par state=true ou false et stateOutletInUse=true ou false",
      "Set by state=true or false and statusFault=true or false": "Réglées par state=true ou false et statusFault=true ou false",
      "Set by state=true or false and value=<brightness>": "Réglées par state=true ou false et value=<luminosité>",
      "Set by value=<ppm>": "Réglés par value=<ppm>",
      "Set the current position": "Régler la position actuelle",
      "Shower head": "Pomme de douche",
      "Single press": "Appui simple",
      "Smoke": "Fumée",
      "Speed URL": "URL de vitesse",
      "Speed factor": "Facteur de vitesse",
      "Stateless switch": "Interrupteur sans état",
      "Stateless switches": "Interrupteurs sans état",
      "Swing mode": "Oscillation",
      "Swing mode URL": "URL d'oscillation",
      "Switch": "Interrupteur",
      "Switches": "Interrupteurs",
      "Switches that turn off a second after they are turned on; state=true presses one": "Interrupteurs qui s'éteignent une seconde après avoir été allumés ; state=true en actionne un",
      "Target temperature URL": "URL de température cible",
      "Target temperature step": "Pas de la température cible",
      "Temperature": "Température",
      "The URL called when HomeKit changes the brightness: %brightnessPlaceholder is the brightness times the factor, %statusPlaceholder true or false": "L'URL appelée quand HomeKit change la luminosité : %brightnessPlaceholder est la luminosité multipliée par le facteur, %statusPlaceholder true ou false",
      "The URL called when HomeKit changes the fan mode, which replaces %targetState in it and in the body: 0 manual, 1 auto": "L'URL appelée quand HomeKit change le mode du ventilateur, qui remplace %targetState dans l'URL et le corps : 0 manuel, 1 auto",
      "The URL called when HomeKit changes the mode, which replaces %b in it: 0 off, 1 heat, 2 cool, 3 auto": "L'URL appelée quand HomeKit change le mode, qui y remplace %b : 0 arrêt, 1 chauffage, 2 refroidissement, 3 auto",
      "The URL called when HomeKit changes the rotation direction, which replaces %rotationDirection in it and in the body": "L'URL appelée quand HomeKit change le sens de rotation, qui remplace %rotationDirection dans l'URL et le corps",
      "The URL called when HomeKit changes the security mode, which replaces %d in it: 0 home, 1 away, 2 night, 3 off": "L'URL appelée quand HomeKit change le mode de sécurité, qui y remplace %d : 0 domicile, 1 absence, 2 nuit, 3 désactivé",
      "The URL called when HomeKit changes the speed: %speedPlaceholder is the speed times the factor, %statusPlaceholder true or false": "L'URL appelée quand HomeKit change la vitesse : %speedPlaceholder est la vitesse multipliée par le facteur, %statusPlaceholder true ou false",
      "The URL called when HomeKit changes the swing mode, which replaces %swingMode in it and in the body": "L'URL appelée quand HomeKit change l'oscillation, qui remplace %swingMode dans l'URL et le corps",
      "The URL called when HomeKit changes the target temperature, which replaces %f in it": "L'URL appelée quand HomeKit change la température cible, qui y remplace %f",
      "The URL called when HomeKit closes the door": "L'URL appelée quand HomeKit ferme la porte",
      "The URL called when HomeKit locks it": "L'URL appelée quand HomeKit le verrouille",
      "The URL called when HomeKit locks the physical controls": "L'URL appelée quand HomeKit verrouille les commandes physiques",
      "The URL called when HomeKit opens the door": "L'URL appelée quand HomeKit ouvre la porte",
      "The URL called when HomeKit presses the button": "L'URL appelée quand HomeKit appuie sur le bouton",
      "The URL called when HomeKit sets the position to 0": "L'URL appelée quand HomeKit règle la position sur 0",
      "The URL called when HomeKit sets the position to 1–25": "L'URL appelée quand HomeKit règle la position sur 1–25",
      "The URL called when HomeKit sets the position to 26–45": "L'URL appelée quand HomeKit règle la position sur 26–45",
      "The URL called when HomeKit sets the position to 46–65": "L'URL appelée quand HomeKit règle la position sur 46–65",
      "The URL called when HomeKit sets the position to 66–94": "L'URL appelée quand HomeKit règle la position sur 66–94",
      "The URL called when HomeKit sets the position to 95–100": "L'URL appelée quand HomeKit règle la position sur 95–100",
      "The URL called when HomeKit turns it off": "L'URL appelée quand HomeKit l'éteint",
      "The URL called when HomeKit turns it on": "L'URL appelée quand HomeKit l'allume",
      "The URL called when HomeKit unlocks it": "L'URL appelée quand HomeKit le déverrouille",
      "The URL called when HomeKit unlocks the physical controls": "L'URL appelée quand HomeKit déverrouille les commandes physiques",
      "The accessory's name in HomeKit. It is also its identity: renaming the entry makes a new accessory": "Le nom de l'accessoire dans HomeKit. C'est aussi son identité : renommer l'entrée crée un nouvel accessoire",
      "The button's name, the webhook's buttonName": "Le nom du bouton, le buttonName du webhook",
      "The path of a PEM certificate, with the key file": "Le chemin d'un certificat PEM, avec le fichier de clé",
      "The path of a PEM private key, with the certificate file": "Le chemin d'une clé privée PEM, avec le fichier de certificat",
      "The port the webhook server listens on, 51828 by default": "Le port d'écoute du serveur de webhooks, 51828 par défaut",
      "The request's HTTP method, GET by default. A body is sent with POST, PUT and PATCH": "La méthode HTTP de la requête, GET par défaut. Un corps est envoyé avec POST, PUT et PATCH",
      "The request's headers, as a JSON object written as text. Kept in config.json as written: a token here is not sealed in the vault": "Les en-têtes de la requête, un objet JSON écrit en texte. Gardés dans config.json tels quels : un jeton ici n'est pas scellé dans le coffre",
      "The webhook's accessoryId, and the key of the accessory's saved state": "L'accessoryId du webhook, et la clé de l'état enregistré de l'accessoire",
      "Thermostat": "Thermostat",
      "Thermostats": "Thermostats",
      "Type": "Type",
      "Unlock URL": "URL de déverrouillage",
      "Unlock controls URL": "URL de déverrouillage des commandes",
      "User name": "Nom d'utilisateur",
      "Valve": "Vanne",
      "Valve type": "Type de vanne",
      "Valves": "Vannes",
      "Verify certificates": "Vérifier les certificats",
      "Water faucet": "Robinet",
      "What the sensor measures or detects": "Ce que le capteur mesure ou détecte",
      "Window covering": "Store",
      "Window coverings": "Stores",
      "With the password, every request must give these with Basic authentication": "Avec le mot de passe, chaque requête doit les donner en authentification Basic"
    },
    "es": {
      "0.0.0.0 by default (every IPv4 address); :: for IPv6 too, 127.0.0.1 for this machine alone": "0.0.0.0 por defecto (todas las direcciones IPv4); :: también para IPv6, 127.0.0.1 solo para esta máquina",
      "Above this level the sensor reports abnormal, 1200 by default": "Por encima de este nivel, el sensor indica un valor anómalo, 1200 por defecto",
      "Adds Lock Physical Controls (lockstate)": "Añade Lock Physical Controls (lockstate)",
      "Adds Swing Mode (swingMode)": "Añade Swing Mode (swingMode)",
      "Adds Target Fan State, manual or auto (targetState)": "Añade Target Fan State, manual o auto (targetState)",
      "Air quality": "Calidad del aire",
      "Allow browsers (CORS)": "Permitir navegadores (CORS)",
      "Allows the double press event. On when missing": "Permite el evento pulsación doble. Activado si falta",
      "Allows the long press event. On when missing": "Permite el evento pulsación larga. Activado si falta",
      "Allows the single press event. On when missing": "Permite el evento pulsación simple. Activado si falta",
      "Answers OPTIONS and lets web pages of any site call the webhooks": "Responde a OPTIONS y deja que las páginas web de cualquier sitio llamen a los webhooks",
      "Auto release": "Retorno automático",
      "Auto release time (in milliseconds)": "Tiempo del retorno automático (en milisegundos)",
      "Body": "Cuerpo",
      "Brightness URL": "URL de brillo",
      "Brightness factor": "Factor de brillo",
      "Button": "Botón",
      "Buttons": "Botones",
      "Buttons pressed by buttonName=<name> and event=0, 1 or 2": "Botones pulsados con buttonName=<nombre> y event=0, 1 o 2",
      "CO2 sensor": "Sensor de CO2",
      "CO2 sensors": "Sensores de CO2",
      "Cache directory": "Carpeta de la caché",
      "Certificate file": "Archivo de certificado",
      "Check the certificate of the HTTPS URLs called. Off accepts a self-signed one": "Comprobar el certificado de las URL HTTPS a las que se llama. Desactivado, se acepta uno autofirmado",
      "Close URL": "URL de cierre",
      "Contact": "Contacto",
      "Contact, motion and occupancy sensors go back to rest on their own after the time below": "Los sensores de contacto, movimiento y presencia vuelven solos al reposo tras el tiempo de abajo",
      "Doorbell": "Timbre",
      "Doorbells": "Timbres",
      "Double press": "Pulsación doble",
      "Fan": "Ventilador",
      "Fan mode": "Modo del ventilador",
      "Fan mode URL": "URL de modo del ventilador",
      "Fans": "Ventiladores",
      "Garage door": "Puerta de garaje",
      "Garage doors": "Puertas de garaje",
      "Generic valve": "Válvula genérica",
      "HTTPS": "HTTPS",
      "Headers": "Encabezados",
      "HomeKit's brightness (0 to 100) times this is the system's: 2.55 for 0 to 255. Webhook values are divided by it": "El brillo de HomeKit (0 a 100) multiplicado por este factor es el del sistema: 2,55 para 0 a 255. Los valores de los webhooks se dividen por él",
      "HomeKit's speed (0 to 100) times this is sent to the system": "La velocidad de HomeKit (0 a 100) multiplicada por este factor se envía al sistema",
      "How long the sensor stays triggered, 5000 by default": "Cuánto tiempo sigue activado el sensor, 5000 por defecto",
      "How the Home app shows the valve": "Cómo muestra la app Casa la válvula",
      "Humidity": "Humedad",
      "ID": "Identificador",
      "In degrees Celsius, 0.5 by default": "En grados Celsius, 0,5 por defecto",
      "In degrees Celsius, 15 by default": "En grados Celsius, 15 por defecto",
      "In degrees Celsius, 30 by default": "En grados Celsius, 30 por defecto",
      "Irrigation": "Riego",
      "Key file": "Archivo de clave",
      "Leak": "Fuga",
      "Light": "Luz",
      "Lights": "Luces",
      "Listen address": "Dirección de escucha",
      "Lock": "Cerradura",
      "Lock URL": "URL de bloqueo",
      "Lock controls URL": "URL de bloqueo de controles",
      "Lock physical controls": "Bloqueo de controles físicos",
      "Locks": "Cerraduras",
      "Long press": "Pulsación larga",
      "Maximum target temperature": "Temperatura objetivo máxima",
      "Method": "Método",
      "Minimum target temperature": "Temperatura objetivo mínima",
      "Mode URL": "URL de modo",
      "Motion": "Movimiento",
      "Name": "Nombre",
      "Occupancy": "Presencia",
      "Off URL": "URL de apagado",
      "On URL": "URL de encendido",
      "Once a call worked, the current position follows the target a second later": "Cuando la llamada funciona, la posición actual sigue al objetivo un segundo después",
      "One button per entry, in order; a webhook presses it by its name": "Un botón por entrada, en orden; un webhook lo pulsa por su nombre",
      "Open URL": "URL de apertura",
      "Outlet": "Enchufe",
      "Outlets": "Enchufes",
      "Password": "Contraseña",
      "Peak level (ppm)": "Nivel máximo (ppm)",
      "Plugin name as shown in the logs": "Nombre del plugin tal como aparece en los registros",
      "Port": "Puerto",
      "Position 0 URL": "URL de posición 0",
      "Position 1–25 URL": "URL de posición 1–25",
      "Position 26–45 URL": "URL de posición 26–45",
      "Position 46–65 URL": "URL de posición 46–65",
      "Position 66–94 URL": "URL de posición 66–94",
      "Position 95–100 URL": "URL de posición 95–100",
      "Push URL": "URL de pulsación",
      "Push button": "Pulsador",
      "Push buttons": "Pulsadores",
      "Read by Homebridge only: Homeswift keeps the states in the plugin's own folder": "Solo lo lee Homebridge: Homeswift guarda los estados en la carpeta del plugin",
      "Rotation direction URL": "URL de sentido de giro",
      "Rung by event=0 (single), 1 (double) or 2 (long press)": "Suenan con event=0 (simple), 1 (doble) o 2 (pulsación larga)",
      "Sealed in config.json by the bridge, or a vault: reference": "Sellada en config.json por el puente, o una referencia vault:",
      "Security mode URL": "URL de modo de seguridad",
      "Security system": "Sistema de seguridad",
      "Security systems": "Sistemas de seguridad",
      "Sensor": "Sensor",
      "Sensors": "Sensores",
      "Sent as written with POST, PUT and PATCH; give its Content-Type in the headers": "Se envía tal cual con POST, PUT y PATCH; indica su Content-Type en los encabezados",
      "Serves the webhooks over HTTPS, with the files below or a self-signed certificate": "Sirve los webhooks por HTTPS, con los archivos de abajo o un certificado autofirmado",
      "Set by currentdoorstate, targetdoorstate and obstructiondetected": "Se fijan con currentdoorstate, targetdoorstate y obstructiondetected",
      "Set by currentposition, targetposition (0 to 100) and positionstate": "Se fijan con currentposition, targetposition (0 a 100) y positionstate",
      "Set by currentstate (0 to 4) and targetstate (0 to 3)": "Se fijan con currentstate (0 a 4) y targetstate (0 a 3)",
      "Set by currenttemperature, targettemperature, currentstate and targetstate": "Se fijan con currenttemperature, targettemperature, currentstate y targetstate",
      "Set by lockcurrentstate (0 to 3) and locktargetstate (0 or 1)": "Se fijan con lockcurrentstate (0 a 3) y locktargetstate (0 o 1)",
      "Set by state, speed, rotationDirection, lockstate, targetState and swingMode": "Se fijan con state, speed, rotationDirection, lockstate, targetState y swingMode",
      "Set by state=true or false": "Se fijan con state=true o false",
      "Set by state=true or false (contact, motion, occupancy, smoke) or value=<number>": "Se fijan con state=true o false (contacto, movimiento, presencia, humo) o value=<número>",
      "Set by state=true or false and stateOutletInUse=true or false": "Se fijan con state=true o false y stateOutletInUse=true o false",
      "Set by state=true or false and statusFault=true or false": "Se fijan con state=true o false y statusFault=true o false",
      "Set by state=true or false and value=<brightness>": "Se fijan con state=true o false y value=<brillo>",
      "Set by value=<ppm>": "Se fijan con value=<ppm>",
      "Set the current position": "Fijar la posición actual",
      "Shower head": "Ducha",
      "Single press": "Pulsación simple",
      "Smoke": "Humo",
      "Speed URL": "URL de velocidad",
      "Speed factor": "Factor de velocidad",
      "Stateless switch": "Interruptor sin estado",
      "Stateless switches": "Interruptores sin estado",
      "Swing mode": "Oscilación",
      "Swing mode URL": "URL de oscilación",
      "Switch": "Interruptor",
      "Switches": "Interruptores",
      "Switches that turn off a second after they are turned on; state=true presses one": "Interruptores que se apagan un segundo después de encenderse; state=true pulsa uno",
      "Target temperature URL": "URL de temperatura objetivo",
      "Target temperature step": "Paso de la temperatura objetivo",
      "Temperature": "Temperatura",
      "The URL called when HomeKit changes the brightness: %brightnessPlaceholder is the brightness times the factor, %statusPlaceholder true or false": "La URL a la que se llama cuando HomeKit cambia el brillo: %brightnessPlaceholder es el brillo multiplicado por el factor, %statusPlaceholder true o false",
      "The URL called when HomeKit changes the fan mode, which replaces %targetState in it and in the body: 0 manual, 1 auto": "La URL a la que se llama cuando HomeKit cambia el modo del ventilador, que sustituye %targetState en ella y en el cuerpo: 0 manual, 1 auto",
      "The URL called when HomeKit changes the mode, which replaces %b in it: 0 off, 1 heat, 2 cool, 3 auto": "La URL a la que se llama cuando HomeKit cambia el modo, que sustituye %b en ella: 0 apagado, 1 calor, 2 frío, 3 auto",
      "The URL called when HomeKit changes the rotation direction, which replaces %rotationDirection in it and in the body": "La URL a la que se llama cuando HomeKit cambia el sentido de giro, que sustituye %rotationDirection en ella y en el cuerpo",
      "The URL called when HomeKit changes the security mode, which replaces %d in it: 0 home, 1 away, 2 night, 3 off": "La URL a la que se llama cuando HomeKit cambia el modo de seguridad, que sustituye %d en ella: 0 en casa, 1 fuera, 2 noche, 3 desactivado",
      "The URL called when HomeKit changes the speed: %speedPlaceholder is the speed times the factor, %statusPlaceholder true or false": "La URL a la que se llama cuando HomeKit cambia la velocidad: %speedPlaceholder es la velocidad multiplicada por el factor, %statusPlaceholder true o false",
      "The URL called when HomeKit changes the swing mode, which replaces %swingMode in it and in the body": "La URL a la que se llama cuando HomeKit cambia la oscilación, que sustituye %swingMode en ella y en el cuerpo",
      "The URL called when HomeKit changes the target temperature, which replaces %f in it": "La URL a la que se llama cuando HomeKit cambia la temperatura objetivo, que sustituye %f en ella",
      "The URL called when HomeKit closes the door": "La URL a la que se llama cuando HomeKit cierra la puerta",
      "The URL called when HomeKit locks it": "La URL a la que se llama cuando HomeKit lo bloquea",
      "The URL called when HomeKit locks the physical controls": "La URL a la que se llama cuando HomeKit bloquea los controles físicos",
      "The URL called when HomeKit opens the door": "La URL a la que se llama cuando HomeKit abre la puerta",
      "The URL called when HomeKit presses the button": "La URL a la que se llama cuando HomeKit pulsa el botón",
      "The URL called when HomeKit sets the position to 0": "La URL a la que se llama cuando HomeKit pone la posición en 0",
      "The URL called when HomeKit sets the position to 1–25": "La URL a la que se llama cuando HomeKit pone la posición en 1–25",
      "The URL called when HomeKit sets the position to 26–45": "La URL a la que se llama cuando HomeKit pone la posición en 26–45",
      "The URL called when HomeKit sets the position to 46–65": "La URL a la que se llama cuando HomeKit pone la posición en 46–65",
      "The URL called when HomeKit sets the position to 66–94": "La URL a la que se llama cuando HomeKit pone la posición en 66–94",
      "The URL called when HomeKit sets the position to 95–100": "La URL a la que se llama cuando HomeKit pone la posición en 95–100",
      "The URL called when HomeKit turns it off": "La URL a la que se llama cuando HomeKit lo apaga",
      "The URL called when HomeKit turns it on": "La URL a la que se llama cuando HomeKit lo enciende",
      "The URL called when HomeKit unlocks it": "La URL a la que se llama cuando HomeKit lo desbloquea",
      "The URL called when HomeKit unlocks the physical controls": "La URL a la que se llama cuando HomeKit desbloquea los controles físicos",
      "The accessory's name in HomeKit. It is also its identity: renaming the entry makes a new accessory": "El nombre del accesorio en HomeKit. También es su identidad: cambiar el nombre de la entrada crea un accesorio nuevo",
      "The button's name, the webhook's buttonName": "El nombre del botón, el buttonName del webhook",
      "The path of a PEM certificate, with the key file": "La ruta de un certificado PEM, con el archivo de clave",
      "The path of a PEM private key, with the certificate file": "La ruta de una clave privada PEM, con el archivo de certificado",
      "The port the webhook server listens on, 51828 by default": "El puerto en el que escucha el servidor de webhooks, 51828 por defecto",
      "The request's HTTP method, GET by default. A body is sent with POST, PUT and PATCH": "El método HTTP de la petición, GET por defecto. Se envía un cuerpo con POST, PUT y PATCH",
      "The request's headers, as a JSON object written as text. Kept in config.json as written: a token here is not sealed in the vault": "Los encabezados de la petición, un objeto JSON escrito como texto. Se guardan en config.json tal cual: un token aquí no se sella en la bóveda",
      "The webhook's accessoryId, and the key of the accessory's saved state": "El accessoryId del webhook, y la clave del estado guardado del accesorio",
      "Thermostat": "Termostato",
      "Thermostats": "Termostatos",
      "Type": "Tipo",
      "Unlock URL": "URL de desbloqueo",
      "Unlock controls URL": "URL de desbloqueo de controles",
      "User name": "Nombre de usuario",
      "Valve": "Válvula",
      "Valve type": "Tipo de válvula",
      "Valves": "Válvulas",
      "Verify certificates": "Verificar certificados",
      "Water faucet": "Grifo",
      "What the sensor measures or detects": "Lo que mide o detecta el sensor",
      "Window covering": "Persiana",
      "Window coverings": "Persianas",
      "With the password, every request must give these with Basic authentication": "Con la contraseña, cada petición debe darlos con autenticación Basic"
    },
    "pt": {
      "0.0.0.0 by default (every IPv4 address); :: for IPv6 too, 127.0.0.1 for this machine alone": "0.0.0.0 por predefinição (todos os endereços IPv4); :: também para IPv6, 127.0.0.1 apenas para esta máquina",
      "Above this level the sensor reports abnormal, 1200 by default": "Acima deste nível, o sensor indica um valor anómalo, 1200 por predefinição",
      "Adds Lock Physical Controls (lockstate)": "Adiciona Lock Physical Controls (lockstate)",
      "Adds Swing Mode (swingMode)": "Adiciona Swing Mode (swingMode)",
      "Adds Target Fan State, manual or auto (targetState)": "Adiciona Target Fan State, manual ou auto (targetState)",
      "Air quality": "Qualidade do ar",
      "Allow browsers (CORS)": "Permitir browsers (CORS)",
      "Allows the double press event. On when missing": "Permite o evento pressão dupla. Ativado se faltar",
      "Allows the long press event. On when missing": "Permite o evento pressão longa. Ativado se faltar",
      "Allows the single press event. On when missing": "Permite o evento pressão simples. Ativado se faltar",
      "Answers OPTIONS and lets web pages of any site call the webhooks": "Responde a OPTIONS e deixa páginas web de qualquer site chamar os webhooks",
      "Auto release": "Retorno automático",
      "Auto release time (in milliseconds)": "Tempo do retorno automático (em milissegundos)",
      "Body": "Corpo",
      "Brightness URL": "URL de brilho",
      "Brightness factor": "Fator de brilho",
      "Button": "Botão",
      "Buttons": "Botões",
      "Buttons pressed by buttonName=<name> and event=0, 1 or 2": "Botões premidos por buttonName=<nome> e event=0, 1 ou 2",
      "CO2 sensor": "Sensor de CO2",
      "CO2 sensors": "Sensores de CO2",
      "Cache directory": "Pasta da cache",
      "Certificate file": "Ficheiro do certificado",
      "Check the certificate of the HTTPS URLs called. Off accepts a self-signed one": "Verificar o certificado dos URL HTTPS chamados. Desativado, um certificado autoassinado é aceite",
      "Close URL": "URL de fechar",
      "Contact": "Contacto",
      "Contact, motion and occupancy sensors go back to rest on their own after the time below": "Os sensores de contacto, movimento e presença voltam sozinhos ao repouso após o tempo abaixo",
      "Doorbell": "Campainha",
      "Doorbells": "Campainhas",
      "Double press": "Pressão dupla",
      "Fan": "Ventoinha",
      "Fan mode": "Modo da ventoinha",
      "Fan mode URL": "URL de modo da ventoinha",
      "Fans": "Ventoinhas",
      "Garage door": "Portão de garagem",
      "Garage doors": "Portões de garagem",
      "Generic valve": "Válvula genérica",
      "HTTPS": "HTTPS",
      "Headers": "Cabeçalhos",
      "HomeKit's brightness (0 to 100) times this is the system's: 2.55 for 0 to 255. Webhook values are divided by it": "O brilho do HomeKit (0 a 100) multiplicado por este fator é o do sistema: 2,55 para 0 a 255. Os valores dos webhooks são divididos por ele",
      "HomeKit's speed (0 to 100) times this is sent to the system": "A velocidade do HomeKit (0 a 100) multiplicada por este fator é enviada ao sistema",
      "How long the sensor stays triggered, 5000 by default": "Quanto tempo o sensor fica ativado, 5000 por predefinição",
      "How the Home app shows the valve": "Como a app Casa mostra a válvula",
      "Humidity": "Humidade",
      "ID": "Identificador",
      "In degrees Celsius, 0.5 by default": "Em graus Celsius, 0,5 por predefinição",
      "In degrees Celsius, 15 by default": "Em graus Celsius, 15 por predefinição",
      "In degrees Celsius, 30 by default": "Em graus Celsius, 30 por predefinição",
      "Irrigation": "Rega",
      "Key file": "Ficheiro da chave",
      "Leak": "Fuga",
      "Light": "Luz",
      "Lights": "Luzes",
      "Listen address": "Endereço de escuta",
      "Lock": "Fechadura",
      "Lock URL": "URL de trancar",
      "Lock controls URL": "URL de bloquear controlos",
      "Lock physical controls": "Bloqueio dos controlos físicos",
      "Locks": "Fechaduras",
      "Long press": "Pressão longa",
      "Maximum target temperature": "Temperatura alvo máxima",
      "Method": "Método",
      "Minimum target temperature": "Temperatura alvo mínima",
      "Mode URL": "URL de modo",
      "Motion": "Movimento",
      "Name": "Nome",
      "Occupancy": "Presença",
      "Off URL": "URL de desligar",
      "On URL": "URL de ligar",
      "Once a call worked, the current position follows the target a second later": "Quando a chamada resulta, a posição atual segue o alvo um segundo depois",
      "One button per entry, in order; a webhook presses it by its name": "Um botão por entrada, por ordem; um webhook prime-o pelo nome",
      "Open URL": "URL de abrir",
      "Outlet": "Tomada",
      "Outlets": "Tomadas",
      "Password": "Palavra-passe",
      "Peak level (ppm)": "Nível máximo (ppm)",
      "Plugin name as shown in the logs": "Nome do plugin tal como aparece nos registos",
      "Port": "Porta",
      "Position 0 URL": "URL de posição 0",
      "Position 1–25 URL": "URL de posição 1–25",
      "Position 26–45 URL": "URL de posição 26–45",
      "Position 46–65 URL": "URL de posição 46–65",
      "Position 66–94 URL": "URL de posição 66–94",
      "Position 95–100 URL": "URL de posição 95–100",
      "Push URL": "URL de pressão",
      "Push button": "Botão de pressão",
      "Push buttons": "Botões de pressão",
      "Read by Homebridge only: Homeswift keeps the states in the plugin's own folder": "Lido apenas pelo Homebridge: o Homeswift guarda os estados na pasta do plugin",
      "Rotation direction URL": "URL de sentido de rotação",
      "Rung by event=0 (single), 1 (double) or 2 (long press)": "Tocam com event=0 (simples), 1 (dupla) ou 2 (pressão longa)",
      "Sealed in config.json by the bridge, or a vault: reference": "Selada no config.json pela ponte, ou uma referência vault:",
      "Security mode URL": "URL de modo de segurança",
      "Security system": "Sistema de segurança",
      "Security systems": "Sistemas de segurança",
      "Sensor": "Sensor",
      "Sensors": "Sensores",
      "Sent as written with POST, PUT and PATCH; give its Content-Type in the headers": "Enviado tal como está com POST, PUT e PATCH; indique o seu Content-Type nos cabeçalhos",
      "Serves the webhooks over HTTPS, with the files below or a self-signed certificate": "Serve os webhooks por HTTPS, com os ficheiros abaixo ou um certificado autoassinado",
      "Set by currentdoorstate, targetdoorstate and obstructiondetected": "Definidos por currentdoorstate, targetdoorstate e obstructiondetected",
      "Set by currentposition, targetposition (0 to 100) and positionstate": "Definidos por currentposition, targetposition (0 a 100) e positionstate",
      "Set by currentstate (0 to 4) and targetstate (0 to 3)": "Definidos por currentstate (0 a 4) e targetstate (0 a 3)",
      "Set by currenttemperature, targettemperature, currentstate and targetstate": "Definidos por currenttemperature, targettemperature, currentstate e targetstate",
      "Set by lockcurrentstate (0 to 3) and locktargetstate (0 or 1)": "Definidas por lockcurrentstate (0 a 3) e locktargetstate (0 ou 1)",
      "Set by state, speed, rotationDirection, lockstate, targetState and swingMode": "Definidas por state, speed, rotationDirection, lockstate, targetState e swingMode",
      "Set by state=true or false": "Definidos por state=true ou false",
      "Set by state=true or false (contact, motion, occupancy, smoke) or value=<number>": "Definidos por state=true ou false (contacto, movimento, presença, fumo) ou value=<número>",
      "Set by state=true or false and stateOutletInUse=true or false": "Definidas por state=true ou false e stateOutletInUse=true ou false",
      "Set by state=true or false and statusFault=true or false": "Definidas por state=true ou false e statusFault=true ou false",
      "Set by state=true or false and value=<brightness>": "Definidas por state=true ou false e value=<brilho>",
      "Set by value=<ppm>": "Definidos por value=<ppm>",
      "Set the current position": "Definir a posição atual",
      "Shower head": "Chuveiro",
      "Single press": "Pressão simples",
      "Smoke": "Fumo",
      "Speed URL": "URL de velocidade",
      "Speed factor": "Fator de velocidade",
      "Stateless switch": "Interruptor sem estado",
      "Stateless switches": "Interruptores sem estado",
      "Swing mode": "Oscilação",
      "Swing mode URL": "URL de oscilação",
      "Switch": "Interruptor",
      "Switches": "Interruptores",
      "Switches that turn off a second after they are turned on; state=true presses one": "Interruptores que se desligam um segundo depois de ligados; state=true prime um",
      "Target temperature URL": "URL de temperatura alvo",
      "Target temperature step": "Passo da temperatura alvo",
      "Temperature": "Temperatura",
      "The URL called when HomeKit changes the brightness: %brightnessPlaceholder is the brightness times the factor, %statusPlaceholder true or false": "O URL chamado quando o HomeKit muda o brilho: %brightnessPlaceholder é o brilho multiplicado pelo fator, %statusPlaceholder true ou false",
      "The URL called when HomeKit changes the fan mode, which replaces %targetState in it and in the body: 0 manual, 1 auto": "O URL chamado quando o HomeKit muda o modo da ventoinha, que substitui %targetState nele e no corpo: 0 manual, 1 auto",
      "The URL called when HomeKit changes the mode, which replaces %b in it: 0 off, 1 heat, 2 cool, 3 auto": "O URL chamado quando o HomeKit muda o modo, que substitui %b nele: 0 desligado, 1 aquecer, 2 arrefecer, 3 auto",
      "The URL called when HomeKit changes the rotation direction, which replaces %rotationDirection in it and in the body": "O URL chamado quando o HomeKit muda o sentido de rotação, que substitui %rotationDirection nele e no corpo",
      "The URL called when HomeKit changes the security mode, which replaces %d in it: 0 home, 1 away, 2 night, 3 off": "O URL chamado quando o HomeKit muda o modo de segurança, que substitui %d nele: 0 em casa, 1 ausente, 2 noite, 3 desativado",
      "The URL called when HomeKit changes the speed: %speedPlaceholder is the speed times the factor, %statusPlaceholder true or false": "O URL chamado quando o HomeKit muda a velocidade: %speedPlaceholder é a velocidade multiplicada pelo fator, %statusPlaceholder true ou false",
      "The URL called when HomeKit changes the swing mode, which replaces %swingMode in it and in the body": "O URL chamado quando o HomeKit muda a oscilação, que substitui %swingMode nele e no corpo",
      "The URL called when HomeKit changes the target temperature, which replaces %f in it": "O URL chamado quando o HomeKit muda a temperatura alvo, que substitui %f nele",
      "The URL called when HomeKit closes the door": "O URL chamado quando o HomeKit fecha a porta",
      "The URL called when HomeKit locks it": "O URL chamado quando o HomeKit o tranca",
      "The URL called when HomeKit locks the physical controls": "O URL chamado quando o HomeKit bloqueia os controlos físicos",
      "The URL called when HomeKit opens the door": "O URL chamado quando o HomeKit abre a porta",
      "The URL called when HomeKit presses the button": "O URL chamado quando o HomeKit prime o botão",
      "The URL called when HomeKit sets the position to 0": "O URL chamado quando o HomeKit define a posição em 0",
      "The URL called when HomeKit sets the position to 1–25": "O URL chamado quando o HomeKit define a posição em 1–25",
      "The URL called when HomeKit sets the position to 26–45": "O URL chamado quando o HomeKit define a posição em 26–45",
      "The URL called when HomeKit sets the position to 46–65": "O URL chamado quando o HomeKit define a posição em 46–65",
      "The URL called when HomeKit sets the position to 66–94": "O URL chamado quando o HomeKit define a posição em 66–94",
      "The URL called when HomeKit sets the position to 95–100": "O URL chamado quando o HomeKit define a posição em 95–100",
      "The URL called when HomeKit turns it off": "O URL chamado quando o HomeKit o desliga",
      "The URL called when HomeKit turns it on": "O URL chamado quando o HomeKit o liga",
      "The URL called when HomeKit unlocks it": "O URL chamado quando o HomeKit o destranca",
      "The URL called when HomeKit unlocks the physical controls": "O URL chamado quando o HomeKit desbloqueia os controlos físicos",
      "The accessory's name in HomeKit. It is also its identity: renaming the entry makes a new accessory": "O nome do acessório no HomeKit. É também a sua identidade: mudar o nome da entrada cria um novo acessório",
      "The button's name, the webhook's buttonName": "O nome do botão, o buttonName do webhook",
      "The path of a PEM certificate, with the key file": "O caminho de um certificado PEM, com o ficheiro da chave",
      "The path of a PEM private key, with the certificate file": "O caminho de uma chave privada PEM, com o ficheiro do certificado",
      "The port the webhook server listens on, 51828 by default": "A porta em que o servidor de webhooks escuta, 51828 por predefinição",
      "The request's HTTP method, GET by default. A body is sent with POST, PUT and PATCH": "O método HTTP do pedido, GET por predefinição. É enviado um corpo com POST, PUT e PATCH",
      "The request's headers, as a JSON object written as text. Kept in config.json as written: a token here is not sealed in the vault": "Os cabeçalhos do pedido, um objeto JSON escrito como texto. Guardados no config.json tal como estão: um token aqui não é selado no cofre",
      "The webhook's accessoryId, and the key of the accessory's saved state": "O accessoryId do webhook, e a chave do estado guardado do acessório",
      "Thermostat": "Termóstato",
      "Thermostats": "Termóstatos",
      "Type": "Tipo",
      "Unlock URL": "URL de destrancar",
      "Unlock controls URL": "URL de desbloquear controlos",
      "User name": "Nome de utilizador",
      "Valve": "Válvula",
      "Valve type": "Tipo de válvula",
      "Valves": "Válvulas",
      "Verify certificates": "Verificar certificados",
      "Water faucet": "Torneira",
      "What the sensor measures or detects": "O que o sensor mede ou deteta",
      "Window covering": "Estore",
      "Window coverings": "Estores",
      "With the password, every request must give these with Basic authentication": "Com a palavra-passe, cada pedido tem de os dar com autenticação Basic"
    }
  }
}
"""#
}
