---
name: nami-snippets
description: Create, change, list, or delete Nami dictation snippets with the nami-snippets CLI. Use when the user asks to add a snippet, save a message or text they dictate often, set up a voice shortcut or text expansion in Nami, change the snippet trigger words, make snippets work in another language, or check what a spoken command would paste.
metadata:
  version: "1"
---

# Nami snippets

Nami is the user's local dictation app. A **snippet** replaces a spoken command
with saved text. The user says a **trigger word** (default `snippet`), one of
the snippet's **phrases**, then optional **details**. Nami pastes the snippet's
**text**, with the details filling its `{{…}}` placeholders.

> Said: "free env snippet for Excel add-in, Users API"
> Snippet: phrases `free env, free environment` · text `Hey @gptqa, is there a free environment to deploy {{apps}}`
> Pasted: "Hey @gptqa, is there a free environment to deploy Excel add-in, Users API"

## How matching works

- A recording is checked only if it contains a trigger word as a whole word.
  Without one, the words are pasted as said. There can be several trigger words,
  comma-separated, e.g. one per language (`snippet, сниппет`). Empty turns
  snippets off.
- Phrases match literally, ignoring case, accents, and punctuation. "env" does
  **not** match "environment", so list each wording the user might say. The
  longest matching phrase wins. The first phrase names the snippet in the app.
- The details are the words after the phrase, minus the trigger word and leading
  words such as "for", "to", "with", or Russian "для", "про", "о". Commas,
  semicolons, "and", "plus", "&", and Russian "и" and "плюс" split them into values.
- With one placeholder, it gets every value, joined with ", ". With several,
  values fill them in order and the last takes the rest. Repeated labels (e.g.
  `{{app}}` twice) share one value. A placeholder with no value is pasted as-is.
  The label inside `{{ }}` is just a hint, e.g. `{{apps}}` or `{{name}}`.
- Snippet text is pasted exactly, without AI cleanup. Text without placeholders
  is fine, e.g. an email address.

## Several languages

Matching is word for word; nothing is translated, and any script works (English
and Russian, for example). Case is ignored and ё matches е. For each language the
user dictates in:

- add phrases in that language to the same snippet, e.g. `free env, free environment, свободное окружение`;
- add the spellings speech recognition may produce. In a Russian sentence,
  English names often come out in Cyrillic ("Эксель", "гитхаб"), so add both
  spellings when the user says such names.

Also make sure the trigger words cover each language (`nami-snippets trigger`).
Add a word to the list rather than replacing it, and ask first.

## The CLI

Run `nami-snippets`. If it isn't on PATH, run
`@NAMI_SNIPPETS@` instead. Never edit `snippets.json` by hand. The
CLI locks the file, and the running app picks up changes within a second.

```sh
nami-snippets list [--json]                         # trigger words + all snippets with IDs
nami-snippets add --phrases "a, b" --text "…"       # prints the new ID
nami-snippets update <snippet> [--phrases "…"] [--text "…"]
nami-snippets remove <snippet>
nami-snippets trigger ["<a, b>"]                    # show, or set the full list; "" turns snippets off
nami-snippets try "<what the user would say>" [--json]
```

- `<snippet>` is an ID, a unique ID prefix of 4+ characters, or any of its phrases.
- `--phrases` replaces all phrases. Give the full list, comma-separated.
- For multi-line text, or text with quotes or `$`, pass `--text -` and send it
  through a quoted heredoc:

  ```sh
  nami-snippets add --phrases "sign off, thanks note" --text - <<'EOF'
  Thanks, {{name}}!
  See you soon
  EOF
  ```
- Errors go to stderr with exit status 1, for example when a phrase is already
  used by another snippet or a reference is not found.

## Workflow

1. Run `nami-snippets list` to see the trigger words and avoid duplicates. If a
   similar snippet exists, update it instead of adding another.
2. Choose phrases. Use two or three short spoken forms the user would naturally
   say, including abbreviations and alternatives ("free env, free environment,
   request env"). Avoid phrases that are common in ordinary sentences.
3. Write the text exactly as it should be pasted. Put placeholders only where
   the user will say details.
4. Add or update the snippet, then check it with
   `nami-snippets try "<trigger word + phrase + example details>"`, using an
   **actual** trigger word from `list`. Try each language the snippet supports.
5. Tell the user what to say, e.g. "Say: *free env snippet for Excel add-in,
   Users API*", and show the text that would be pasted.

Ask before removing snippets or changing the trigger words unless the user asked
for exactly that. The trigger words affect every snippet.
