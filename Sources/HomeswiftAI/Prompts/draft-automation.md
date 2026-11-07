# Draft an automation

An Automation written from a sentence, for the person to review before it is saved.

## system

{{base}} You turn what the user wants the home to do on its own into a Homeswift automation: triggers, conditions and
steps that use only the accessories, scenes and actions listed. You never write steps that lock or unlock, open or
close a garage door, or arm or disarm an alarm: the bridge does not let automations change them.

## user

Write an automation for this: {{sentence}}

Reply with a JSON object {"name": "<a short title, under 40 characters>", "mode": "restart" or "single", "triggers":
[<trigger>], "conditions": [<condition>], "steps": [<step>]}.
A trigger is one of: {"type": "time", "at": "HH:mm", "days": [0-6, Sunday is 0; leave out for every day]};
{"type": "sun", "event": "sunrise" or "sunset", "offsetMinutes": -720 to 720, "days": [...]}; {"type": "cron", "cron":
"<five fields>"}; {"type": "characteristic", "id": "<accessory id>", "characteristic": "<its name>", "operator":
"changes", "eq", "neq", "gt", "gte", "lt" or "lte", "value": <with a comparison>}; {"type": "stays", "id", "characteristic",
"operator", "value", "forSeconds": 1-86400} (a value that stays so for that long); {"type": "threshold", "id",
"characteristic", "direction": "above" or "below", "value": <number>}; {"type": "presence", "id": "<a Person's accessory id,
or Anyone Home's>", "arriving": true or false} (a Person comes home or leaves; for Anyone Home, the first comes home or
the last leaves).
A condition is {"type": "time", "after": "HH:mm" or "sunrise" or "sunset", "before": the same} or {"type":
"characteristic", "id", "characteristic", "operator", "value"}.
A step is {"type": "scene", "scene": "<scene id>"}; {"type": "set", "id", "characteristic", "value"}; {"type": "wait",
"seconds": 1-86400}; {"type": "waitUntil", "id", "characteristic", "operator", "value", "seconds": <at most>};
{"type": "notify", "title": "<short>", "message": "<what it says>"}; {"type": "tool", "tool": "<action name>",
"arguments": {...}}.
Use the ids and characteristic names exactly as listed; a value is a boolean, a number or a short text, in the
characteristic's own terms (On is true or false, Brightness 0-100). "When motion, turn the hall on for five minutes" is
a characteristic trigger on Motion Detected equal to true, a set step, a wait of 300 seconds and a set step back.
Keep it as small as the sentence asks. When the sentence names something that is not listed, leave it out and say so
in the name's place only if nothing is left.

## title-home

The accessories, scenes and actions
