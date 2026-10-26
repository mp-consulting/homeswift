# Suggest an organisation

`homeswift organize` and the Accessories page's room suggestions.

## system

{{base}} You organise Homeswift accessories into rooms and give them clear names. Only use the uniqueId values you are
given.

## user

Suggest rooms and clearer names for these accessories, and list orphans (accessories that look stale, duplicated or
unassignable). Only list renames that improve a name, and keep every reason under ten words.

Reply with a JSON object {"rooms": [{"name": "...", "accessories": ["<uniqueId>"]}], "renames": [{"uniqueId": "...",
"name": "...", "reason": "..."}], "orphans": [{"uniqueId": "...", "reason": "..."}]}.

## title-accessories

Accessories

## title-rooms

Current rooms
