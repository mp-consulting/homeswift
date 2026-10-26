# The Assistant

Homeswift has an AI assistant, a port of [`homebridge-ai-kit`](https://github.com/mp-consulting/homebridge-ai-kit)'s
core: it explains device errors, diagnoses logs, answers questions, writes configuration blocks, writes a
daily digest and suggests rooms and names, on the provider you choose, including Apple's on-device model.
Plugins get it through `context.assistant`; the command line through `homeswift ask`, `explain`, `diagnose`,
`digest`, `organize`, `test-ai` and `usage`. Nothing is sent anywhere unless config.json
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
| `budget` | none | Limits per local day and month: `dailyTokens`, `monthlyTokens` (input plus output), `dailyUsd`, `monthlyUsd`; see below |

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

## Usage and budgets

`UsageTracker` counts requests, tokens and cost per model, per local day (`yyyy-MM-dd`) and per local month
(`yyyy-MM`), and per user within a day when the request names one. With a `UsageStore` the counts survive
restarts: `FileUsageStore` keeps them in `ai-usage.json` in the storage directory (`UsageTracker.fileName`),
written owner-only after every request, in homebridge-ai-kit's `UsageSnapshot` shape (`version`, `models`,
`days`, `months`) plus `users`; 62 days and 24 months are kept. Costs come from the token counts with the
current prices, so only Claude models are priced; the others count as free against a USD budget.

```json
{ "platform": "HomeswiftAiKit", "provider": "anthropic", "apiKey": "sk-ant-…", "budget": { "dailyTokens": 200000, "monthlyUsd": 20 } }
```

Once a limit is reached, every request (`ask`, `explain`, `diagnose`, `generateConfiguration`, a chat step, a
digest, an organiser batch) throws `BudgetExceededError` before reaching the provider, with upstream's
message: `The daily AI budget is used up: $2.04 of $2.00 today. It resets at midnight.` The error has
`period` (`day`, `month`), `unit` (`tokens`, `usd`), `used` and `limit`.

For the web UI and the MCP server:

- `AssistantService(configuration:usageStore:logger:)` sets up the block's provider with its budget and a store:
  `FileUsageStore(url: storage.appendingPathComponent(UsageTracker.fileName), write: OwnerOnlyFile.write)`
  (the library cannot import `OwnerOnlyFile`, so the caller passes it). One tracker per process: the command
  line and a running bridge each rewrite the file with their own counts, so the bridge's last save wins.
- `assistant.forUser(name)` counts the requests of the signed-in user; `withContext` keeps the user.
- `await assistant.usage.report()` is a `UsageReport`: `day`, `month`, `today`, `thisMonth`, `total`, `budget`,
  `exceeded`, `byModel`, `todayByModel`, `monthByModel`, `todayByUser`, `monthByUser`; `report.json` is the same
  as JSON (summaries with `requests`, `inputTokens`, `outputTokens`, `costUsd`, null when unknown).
- `await assistant.usage.setBudget(_:)` applies a changed block without a restart; `checkBudget()` and
  `exceededBudget()` check one.
- `SlidingWindowRateLimiter` allows `limit` requests per key in any `window` seconds, upstream's limiter:
  `SlidingWindowRateLimiter.assistant()` is Glass UI's 20 a minute per user. `consume(user)` returns `allowed`,
  `remaining` and `retryAfter` (seconds, for a 429's `Retry-After`; `SlidingWindowRateLimiter.refusal` is the
  message); a refused request is not counted. Idle keys are evicted.

## More features

- **Connection test**: `AssistantService.testConnection(block:)` sends upstream's one-word request with a block,
  saved or not, whatever its `enabled`, and returns a `ConnectionTestResult`: `ok`, `provider`, `model`,
  `latencyMs`, `reply`, or a redacted `message`; `json` has upstream's shape. It never throws and gives up after
  30 seconds. `testConnection(provider:)` does the same with a provider already made; pass `usage:` to count it.
- **Daily digest**: `assistant.dailyDigest(DailyDigestInput(...))` writes a digest of a day under 200 words,
  what needs attention first. The input is plain values: `date` (today by default), `status` (JSON),
  `logs` (lines; `DailyDigestInput.problemLines` keeps the warnings and errors, as Glass UI does), `accessories`
  (JSON, with states) and `events` (JSON: what happened to accessories). Each part is redacted, its addresses
  masked (`<IP>`, `<MAC>`) as for `explain`, wrapped in `<untrusted-data>` and trimmed. Glass UI caches a digest for 6 hours; a caller that wants that keeps it.
- **Organiser**: `assistant.suggestOrganization(accessories:rooms:onProgress:)` takes accessories as JSON
  objects with a `uniqueId` (or `id`), name, category, services, and returns an `OrganizationSuggestion`:
  `rooms` (name, accessory ids), `renames` (id, name, reason) and `orphans` (id, reason), plus `json` in
  upstream's shape. The ids reach the model as aliases (`a1`, `a2`…), so long ids and MAC addresses in them
  stay home, and ids the model invents are dropped. Each reply is schema-checked JSON with one repair; large
  homes go in batches sized to `maxOutputTokens`, three at a time, with `onProgress(done, total)`.
- **Moods**: `assistant.designMood(_:lights:)` turns a description ("a rainy afternoon") into a mood for the
  lights: steps of colours, how long each holds, whether it loops and puts the lights back
  (`AssistantService.moodSchema`, schema-checked with one repair). It learns how many lights there are and which
  take colours or only whites, never their names or rooms. Homeswift plays it as it plays the collection's
  (docs/mcp.md, "Moods").
- homebridge-ai-kit's `assessPluginUpdate` (the risk of a plugin update, from its changelog) is not ported:
  Homeswift's plugins are compiled into the binary and have no updates of their own.

## Command line

```bash
homeswift ask "why does my key light show No Response at night"
homeswift explain "Could not reach Elgato Key Light at 192.168.1.50:9123: timed out"
homeswift diagnose ~/.homeswift/homeswift.log      # or: journalctl -u homeswift | homeswift diagnose
```

```bash
homeswift digest                 # the last day: the log's warnings and errors, the accessories; --hours 48
homeswift organize               # rooms and names for the accessories the bridge last cached; --json
homeswift test-ai                # checks the block's provider, key and model: "OK: anthropic claude-opus-5-5 answered in 640 ms: OK"
homeswift usage                  # today and this month, by model, with the budgets; --json
```

The answer streams to standard output; a last line on standard error gives the model, the tokens and,
for Claude, the cost. `-U` picks the config directory as for the bridge. The commands count in
`ai-usage.json` and stop at the block's budget. `digest` reads the log on disk (`logs/`) and `organize` the
accessory cache (`accessories/`), so they work while the bridge runs, or after it ran once; they do not
start plugins.

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

## In the web UI's chat

`AssistantService.converse(history:tools:vault:)` runs a turn with tools: the model answers or calls tools,
their results go back to it, until it answers or 16 model calls were made. The web UI's chat gives it the
MCP server's tools through `ChatToolbox`, an MCP session inside the process that acts as the signed-in user:
scopes, schema checks, confirmations and the audit log are the MCP server's. A destructive tool runs a dry
run first; its answer goes on the page's confirmation card, and the user's choice answers the session's
elicitation. `docs/ui.md` describes the chat.

The web UI's requests (the chat, explain, ask, Log Doctor, the digest, room suggestions, the config copilot)
carry the page's language as `Accept-Language`; for French, Spanish or Portuguese the Assistant is told to
answer in it (`Prompts.answerLanguage`, `AssistantService.speaking`), and the day's digest is kept per language.
The command line and the MCP server leave the language to the model.

## What goes to the provider

- **Secrets never.** Configuration values under keys such as `password`, `token`, `apiKey`, `pin` are
  replaced with `__REDACTED__` before anything is sent, and put back when the model returns a configuration.
  Free text (logs, errors, questions) has `key=value` pairs with such names and well-known key shapes
  (`sk-…`, `Bearer …`, `AIza…`, JWTs) masked.
- **Logs and device data are data.** They are wrapped in `<untrusted-data>` tags and the system prompt
  tells the model never to follow instructions found in them.
- **Every prompt is readable.** The words sent to a model are Markdown files in
  [`Sources/HomeswiftAI/Prompts/`](../Sources/HomeswiftAI/Prompts), one per feature (logs, the config copilot, moods,
  the digest, the chat…); its README says how a file reads. Edit one, then run
  `swift Scripts/embed-assets.swift prompts Sources/HomeswiftAI/Prompts Sources/HomeswiftAI/PromptFiles.swift`.
- **Inputs are trimmed** to the provider's context window, keeping the end of a log and the start of a
  changelog, with a note saying how much was cut.
- **Secrets a tool returns become handles.** Each MCP session (the chat's too) has a `SecretVault`: a
  secret in a tool's answer (a TV's password after pairing) reaches the model as `__SECRET_1__`, and that
  handle in a later tool's arguments becomes the secret again, so the model can put it in config.json
  without seeing it.
- **Nothing is stored** on the provider's side where that is a choice: OpenAI requests use `store: false`.

## Library

`HomeswiftAI` is a library of its own (Foundation and swift-log only): `Provider` adapters with `chat` and
`stream`, tool definitions and calls, `AssistantService.converse` for a turn with tools, `SecretVault`,
`JSONGeneration.generate` for schema-checked JSON with one repair, `Redaction`, `Tokens`, `Pricing`,
`UsageTracker` with `UsageStore` and `UsageBudget`, and `SlidingWindowRateLimiter`. `AssistantService` wires them into the features.
