# The Assistant's prompts

Every text the Assistant sends a model is in these files, one per feature. `Prompts.swift` builds the requests from
them; `Scripts/embed-assets.swift prompts` embeds them into `PromptFiles.swift`, and `PromptTests` fails when that
copy is stale. After editing a file:

    swift Scripts/embed-assets.swift prompts Sources/HomeswiftAI/Prompts Sources/HomeswiftAI/PromptFiles.swift

How a file reads:

- Each `## name` heading starts a text, named `<file>.<name>` (`diagnose-logs.system`). What comes before the first
  heading (this introduction, a file's title) is for people and is not sent.
- A paragraph's lines are joined with spaces, so wrap them as you like; a blank line is a paragraph break. A line that
  ends with two spaces keeps its line break.
- `{{name}}` is filled in by `Prompts.swift`: the user's request, a plugin's name, an optional fragment of the same
  file (which `Prompts.swift` puts after a space). Single braces are text (the JSON the model is asked for).
- Data from logs, devices and accessories goes inside `<untrusted-data>` tags, which `Prompts.swift` adds; a text never
  asks the model to follow what it finds there.
