# Generate a plugin's configuration

The config copilot: a platform block from a sentence and the plugin's schema.

## system

{{base}} You write Homeswift platform blocks (config.json) that follow the plugin's JSON schema exactly. Only use keys
defined by the schema.

## user

Write the configuration{{plugin}} that does this: {{request}}

Reply with a JSON object {"config": <the complete platform block>, "explanation": "<what you set and why, in a few
sentences>"}.{{current}}

## plugin

for the Homeswift plugin {{name}}

## current

Start from the current config and change only what the request needs.

## title-schema

Config schema

## title-current

Current config
