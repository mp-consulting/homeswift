# The Assistant

Homeswift has an AI assistant, a port of [`homebridge-ai-kit`](https://github.com/mp-consulting/homebridge-ai-kit)'s
core: it explains device errors, diagnoses logs, answers questions and writes configuration blocks, on the
provider you choose, including Apple's on-device model. Plugins get it through `context.assistant`; the
command line through `homeswift ask`, `explain` and `diagnose`. Nothing is sent anywhere unless config.json
has a `HomeswiftAiKit` block (or, for the command line only, the Mac has Apple Intelligence).

## Configuration

One platform block, with the keys of `@mp-consulting/homebridge-ai-kit` so a Homebridge block works unchanged:

```json
{ "platform": "HomeswiftAiKit", "provider": "anthropic", "model": "claude-opus-5-5", "apiKey": "sk-ant-…" }
```

| Key | Default | What it does |
|---|---|---|
| `provider` | `anthropic` | `anthropic`, `openai`, `gemini`, `openai-compatible` (Ollama, LM Studio, vLLM) or `apple` |
| `model` | per provider | The model id; see the table below |
| `apiKey` | `ANTHROPIC_API_KEY`, `OPENAI_API_KEY` or `GEMINI_API_KEY` | Secret; redaction treats it as one |
| `baseUrl` | per provider | Another endpoint, or the local server for `openai-compatible` |
| `maxOutputTokens` | `2048` | Longest answer |
| `contextTokens` | per provider | The model's context window, mainly for local models, so inputs are trimmed to fit |
| `effort` | the model's | `low`, `medium`, `high`, `xhigh`, `max`: Claude `output_config.effort`, OpenAI `reasoning.effort` |
| `openaiApi` | `responses` for OpenAI, `chat` for compatible servers | Which OpenAI API to call |
| `maxRetries` | `2` | Retries of a failed request (408, 429, 5xx, network); `0` turns them off |
| `promptCaching` | `true` | Claude: cache breakpoints on the system prompt and tools; off for proxies that reject them |
| `fallbacks` | `true` on Opus 5.5, Opus 5, Sonnet 5.5 and Fable | Claude: let the API re-run a declined request on a fallback model |
| `enabled` | `true` | `false` keeps the block but turns the Assistant off |

| `provider` | Default model | Needs | Context |
|---|---|---|---|
| `anthropic` | `claude-opus-5-5` | API key | 1M (200K on Haiku 4.5) |
| `openai` | `gpt-6.1-sol` | API key | 128K, set `contextTokens` for more |
| `gemini` | `gemini-3.8-flash` | API key | 1M |
| `openai-compatible` | `llama3.1` | a local server (`http://127.0.0.1:11434/v1` by default) | 8K, set `contextTokens` |
| `apple` | the on-device model | macOS 26 or later with Apple Intelligence on | about 4K; no tool calling |

Claude models: `claude-opus-5-5` (the default), `claude-sonnet-5-5`, `claude-haiku-5-5` (the cheapest),
`claude-fable-5-1` (the most capable). Thinking is adaptive on these models and left to the model; `effort`
sets how much. The Assistant never sends `thinking` settings, prefills or forced tool choices.

`apple` is the zero-configuration option on a Mac: no key, nothing leaves the machine, and `homeswift ask`
uses it when there is no block at all. Its context is small, so long logs are trimmed harder.

## Command line

```bash
homeswift ask "why does my key light show No Response at night"
homeswift explain "Could not reach Elgato Key Light at 192.168.1.50:9123: timed out"
homeswift diagnose ~/.homeswift/homeswift.log      # or: journalctl -u homeswift | homeswift diagnose
```

The answer streams to standard output; a last line on standard error gives the model, the tokens and,
for Claude, the cost. `-U` picks the config directory as for the bridge.

## In a plugin

```swift
if let assistant = context.assistant {
    let reply = try await assistant.explain(
        error: "\(error)", context: "Polling the light at \(host)", device: ["model": .string(model), "firmware": .string(firmware)])
    logger.info("\(reply.text)")
}
```

`context.assistant` is nil without a working block, so a plugin must work without it. The requests carry
the plugin's name, the inputs are redacted and trimmed, and the `JSONValue` the device is described with
is a plain JSON value. `ask`, `explain`, `diagnose` and `generateConfiguration` each take an `onChunk`
closure to stream. `generateConfiguration(request:schema:current:)` writes a block from the plugin's
`config.schema.json`; secrets in `current` are redacted before sending and restored after.

## What goes to the provider

- **Secrets never.** Configuration values under keys such as `password`, `token`, `apiKey`, `pin` are
  replaced with `__REDACTED__` before anything is sent, and put back when the model returns a configuration.
  Free text (logs, errors, questions) has `key=value` pairs with such names and well-known key shapes
  (`sk-…`, `Bearer …`, `AIza…`, JWTs) masked.
- **Logs and device data are data.** They are wrapped in `<untrusted-data>` tags and the system prompt
  tells the model never to follow instructions found in them.
- **Inputs are trimmed** to the provider's context window, keeping the end of a log and the start of a
  changelog, with a note saying how much was cut.
- **Nothing is stored** on the provider's side where that is a choice: OpenAI requests use `store: false`.

## Library

`HomeswiftAI` is a library of its own (Foundation and swift-log only): `Provider` adapters with `chat` and
`stream`, tool definitions and calls for a later agent loop, `JSONGeneration.generate` for schema-checked
JSON with one repair, `Redaction`, `Tokens`, `Pricing` and `UsageTracker`. `AssistantService` wires them
into the features. The MCP server, which lets Claude Desktop and other clients control the bridge, is the
next step on top of it.
