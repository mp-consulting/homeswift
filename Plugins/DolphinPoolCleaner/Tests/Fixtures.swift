// The shadows of the Homebridge plugin's test fixtures: an idle robot and one cleaning with a full filter.

enum Fixtures {
    static let idleShadow = #"""
{
  "state": {
    "reported": {
      "LastReceiveData": {
        "dynamicTopics": [
          "Maytronics/E3086OFG/main"
        ],
        "robotSerial": "E3086OFG2M",
        "timestamp": 1767951075
      },
      "isConnected": {
        "connected": true
      },
      "systemState": {
        "pwsState": "on",
        "robotState": "finished",
        "robotType": "M5",
        "isBusy": false,
        "rTurnOnCount": 655,
        "timeZone": 60,
        "timeZoneName": "Europe/Lisbon"
      },
      "debug": {
        "systemTime": 1768753664,
        "dynamicFlg": 2,
        "weeklyNextOp": 0,
        "automationMode": 0,
        "WIFI_RSSI": -70,
        "dataUploadNumber": 0,
        "updateTime": {
          "hour": 2,
          "min": 0
        },
        "resetSource": 96,
        "bleMacAddress": "00:00:00:00:00:00",
        "wifiMacAddress": "30:09:F9:7A:FF:08",
        "rtcFlag": true,
        "disconnectionTrigger": {
          "code": 12,
          "timeStamp": 1768753664
        }
      },
      "filterBagIndication": {
        "state": 0,
        "resetFBI": false
      },
      "cycleInfo": {
        "cleaningMode": {
          "cycleTime": 150,
          "mode": "all"
        },
        "cycleStartTime": 0,
        "cycleStartTimeUTC": 0
      },
      "dynamicTopics": [
        "Maytronics/E3086OFG/main"
      ],
      "robotSerial": "E3086OFG2M",
      "nextCycleInfo": {
        "cleaningMode": {
          "mode": "all"
        },
        "nextCycleDuration": 150
      },
      "robotError": {
        "errorCode": 0,
        "pcbHours": 891,
        "pcbMin": 50,
        "turnOnCount": 645,
        "faultValue1": 0
      },
      "pwsError": {
        "errorCode": 255,
        "pcbHours": 65535,
        "pcbMin": 255,
        "turnOnCount": 65535,
        "holdCount": 0,
        "faultValue1": 65535,
        "faultValue2": 65535
      },
      "navMode": {
        "isSmart": false
      },
      "cleaningModes": {
        "all": 150,
        "short": 150,
        "cove": 120,
        "floor": 150,
        "water": 150,
        "ultra": 150,
        "spot": 120,
        "wall": 120,
        "tictac": 600,
        "custom": 120,
        "pickup": 5
      },
      "weeklySettings": {
        "isInRepeatMode": true,
        "triggeredBy": "none",
        "sunday": {
          "isEnabled": false,
          "time": {
            "hours": 10,
            "minutes": 0
          },
          "cleaningMode": {
            "mode": "all"
          }
        },
        "monday": {
          "isEnabled": false,
          "time": {
            "hours": 10,
            "minutes": 0
          },
          "cleaningMode": {
            "mode": "all"
          }
        },
        "tuesday": {
          "isEnabled": false,
          "time": {
            "hours": 10,
            "minutes": 0
          },
          "cleaningMode": {
            "mode": "all"
          }
        },
        "wednesday": {
          "isEnabled": false,
          "time": {
            "hours": 10,
            "minutes": 0
          },
          "cleaningMode": {
            "mode": "all"
          }
        },
        "thursday": {
          "isEnabled": false,
          "time": {
            "hours": 10,
            "minutes": 0
          },
          "cleaningMode": {
            "mode": "all"
          }
        },
        "friday": {
          "isEnabled": false,
          "time": {
            "hours": 10,
            "minutes": 0
          },
          "cleaningMode": {
            "mode": "all"
          }
        },
        "saturday": {
          "isEnabled": false,
          "time": {
            "hours": 10,
            "minutes": 0
          },
          "cleaningMode": {
            "mode": "all"
          }
        }
      },
      "delay": {
        "isEnabled": false,
        "triggeredBy": "none",
        "startTime": {
          "hours": 0,
          "minutes": 0
        },
        "cleaningMode": {
          "mode": "all"
        }
      },
      "versions": {
        "sysVersion": "2.01.00",
        "pwsVersion": {
          "pwsHwVersion": "2.00.00",
          "pwsSwVersion": "2.00.00",
          "pwsBootloaderVersion": "0.03.00"
        },
        "robotVersion": {
          "muHwVersion": "2.00.00",
          "muSwVersion": "2.00.00"
        }
      },
      "featureEn": {
        "delay": true,
        "floor": true,
        "weeklyTimer": {
          "status": true,
          "frequency": 7
        },
        "short": true,
        "pickup": true,
        "fbiLED": true
      },
      "wifi": {
        "netName": "MyNetwork"
      }
    }
  },
  "metadata": {
    "reported": {
      "LastReceiveData": {
        "timestamp": 1767951075
      }
    }
  },
  "version": 774555,
  "timestamp": 1768754987
}
"""#

    static let cleaningShadow = #"""
{
  "state": {
    "reported": {
      "LastReceiveData": {
        "dynamicTopics": [
          "Maytronics/E3086OFG/main"
        ],
        "robotSerial": "E3086OFG2M",
        "timestamp": 1768747264
      },
      "isConnected": {
        "connected": true
      },
      "systemState": {
        "pwsState": "on",
        "robotState": "scanning",
        "robotType": "M5",
        "isBusy": true,
        "rTurnOnCount": 656,
        "timeZone": 60,
        "timeZoneName": "Europe/Lisbon"
      },
      "debug": {
        "systemTime": 1768753664,
        "dynamicFlg": 2,
        "weeklyNextOp": 0,
        "automationMode": 0,
        "WIFI_RSSI": -70,
        "dataUploadNumber": 0,
        "updateTime": {
          "hour": 2,
          "min": 0
        },
        "resetSource": 96,
        "bleMacAddress": "00:00:00:00:00:00",
        "wifiMacAddress": "30:09:F9:7A:FF:08",
        "rtcFlag": true,
        "disconnectionTrigger": {
          "code": 12,
          "timeStamp": 1768753664
        }
      },
      "filterBagIndication": {
        "state": 100,
        "resetFBI": false
      },
      "cycleInfo": {
        "cleaningMode": {
          "cycleTime": 150,
          "mode": "all"
        },
        "cycleStartTime": 1768750848,
        "cycleStartTimeUTC": 1768747264
      },
      "dynamicTopics": [
        "Maytronics/E3086OFG/main"
      ],
      "robotSerial": "E3086OFG2M",
      "nextCycleInfo": {
        "cleaningMode": {
          "mode": "all"
        },
        "nextCycleDuration": 150
      },
      "robotError": {
        "errorCode": 2,
        "pcbHours": 891,
        "pcbMin": 50,
        "turnOnCount": 645,
        "faultValue1": 35
      },
      "pwsError": {
        "errorCode": 255,
        "pcbHours": 65535,
        "pcbMin": 255,
        "turnOnCount": 65535,
        "holdCount": 0,
        "faultValue1": 65535,
        "faultValue2": 65535
      },
      "navMode": {
        "isSmart": false
      },
      "cleaningModes": {
        "all": 150,
        "short": 150,
        "cove": 120,
        "floor": 150,
        "water": 150,
        "ultra": 150,
        "spot": 120,
        "wall": 120,
        "tictac": 600,
        "custom": 120,
        "pickup": 5
      },
      "weeklySettings": {
        "isInRepeatMode": true,
        "triggeredBy": "none",
        "sunday": {
          "isEnabled": false,
          "time": {
            "hours": 10,
            "minutes": 0
          },
          "cleaningMode": {
            "mode": "all"
          }
        },
        "monday": {
          "isEnabled": false,
          "time": {
            "hours": 10,
            "minutes": 0
          },
          "cleaningMode": {
            "mode": "all"
          }
        },
        "tuesday": {
          "isEnabled": false,
          "time": {
            "hours": 10,
            "minutes": 0
          },
          "cleaningMode": {
            "mode": "all"
          }
        },
        "wednesday": {
          "isEnabled": false,
          "time": {
            "hours": 10,
            "minutes": 0
          },
          "cleaningMode": {
            "mode": "all"
          }
        },
        "thursday": {
          "isEnabled": false,
          "time": {
            "hours": 10,
            "minutes": 0
          },
          "cleaningMode": {
            "mode": "all"
          }
        },
        "friday": {
          "isEnabled": false,
          "time": {
            "hours": 10,
            "minutes": 0
          },
          "cleaningMode": {
            "mode": "all"
          }
        },
        "saturday": {
          "isEnabled": false,
          "time": {
            "hours": 10,
            "minutes": 0
          },
          "cleaningMode": {
            "mode": "all"
          }
        }
      },
      "delay": {
        "isEnabled": false,
        "triggeredBy": "none",
        "startTime": {
          "hours": 0,
          "minutes": 0
        },
        "cleaningMode": {
          "mode": "all"
        }
      },
      "versions": {
        "sysVersion": "2.01.00",
        "pwsVersion": {
          "pwsHwVersion": "2.00.00",
          "pwsSwVersion": "2.00.00",
          "pwsBootloaderVersion": "0.03.00"
        },
        "robotVersion": {
          "muHwVersion": "2.00.00",
          "muSwVersion": "2.00.00"
        }
      },
      "featureEn": {
        "delay": true,
        "floor": true,
        "weeklyTimer": {
          "status": true,
          "frequency": 7
        },
        "short": true,
        "pickup": true,
        "fbiLED": true
      },
      "wifi": {
        "netName": "MyNetwork"
      }
    }
  },
  "metadata": {
    "reported": {
      "LastReceiveData": {
        "timestamp": 1768747264
      }
    }
  },
  "version": 774556,
  "timestamp": 1768754987
}
"""#
}
