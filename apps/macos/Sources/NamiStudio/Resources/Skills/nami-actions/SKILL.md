---
name: nami-actions
description: Create, change, list, or delete Nami voice actions with the nami-actions CLI. Use when the user asks to do something on their Mac by voice in Nami, such as opening a link, repository, app, file, or folder, running a Shortcut or shell command, adding a voice command or action, making actions work in another language, or checking what a spoken command would run.
metadata:
  version: "1"
---

# Nami actions

Nami is the user's local dictation app. An **action** runs steps on the Mac
instead of pasting what was said. When a recording **starts with** one of the
action's **phrases**, Nami runs its **steps** in order. Nothing is pasted, copied,
or cleaned up, and history shows which action ran.

> Said: "Open Excel repo"
> Action: phrases `open Excel repo, open Excel repository` · step: open
> `https://github.com/acme/excel-addin` in `Google Chrome`
> Result: Chrome opens the repository.

## How matching works

- There is no trigger word. The recording must **begin** with a phrase. Phrases
  match literally, ignoring case, accents, and punctuation. "repo" does **not**
  match "repository", so list each wording the user might say. The longest
  matching phrase wins. The first phrase names the action in the app.
- Without a `{{…}}` placeholder in any step, the phrase must be **all** that is
  said. "Open Excel repo and check the tests" is pasted as ordinary dictation.
- With a placeholder, the words after the phrase are the **details**, minus
  leading words such as "for", "to", or "about". Every `{{…}}` gets all the
  details as one value; the label inside is just a hint, e.g. `{{query}}`.
  Leading Russian words such as "для", "про", "о" are dropped too. If
  nothing follows the phrase, the placeholder becomes empty.
- Details are URL-encoded in links and single-quoted as one word in shell
  commands, so don't add quotes around `{{…}}` in a command.
- Only live dictation runs actions, not imported or re-transcribed audio.

## Several languages

Matching is word for word; nothing is translated, and any script works (English
and Russian, for example). Case is ignored and ё matches е. For each language the
user dictates in:

- add phrases in that language to the same action, e.g. `open Excel repo, открой репозиторий Excel, открой репозиторий эксель`;
- add the spellings speech recognition may produce. In a Russian sentence,
  English names often come out in Cyrillic ("Эксель", "гитхаб"), so add both
  spellings when the user says such names.

## Steps

| Flag | Does | Notes |
| --- | --- | --- |
| `--open-url <url>` | Opens a link | No scheme means `https://`. Any scheme works, e.g. `vscode://`, `slack://`. |
| `--open-app <name>` | Opens or focuses an app | The name as in /Applications, e.g. `Google Chrome`. |
| `--open-file <path>` | Opens a file or folder | `~` is expanded. |
| `--shortcut <name>` | Runs a Shortcut | The exact name in the Shortcuts app. |
| `--command <command>` | Runs a shell command | Login `zsh`, so Homebrew tools are on PATH. `-` reads it from stdin. |
| `--with <app>` | Opens the previous link, file, or folder in this app | Only after `--open-url` or `--open-file`. |

Nami waits up to five seconds for a step to report a failure, then lets it keep
running. The first failing step stops the rest and shows its error in the app.

## The CLI

Run `nami-actions`. If it isn't on PATH, run
`@NAMI_ACTIONS@` instead. Never edit `actions.json` by hand. The
CLI locks the file, and the running app picks up changes within a second.

```sh
nami-actions list [--json]                              # all actions with IDs and steps
nami-actions add --phrases "a, b" <steps>               # prints the new ID
nami-actions update <action> [--phrases "…"] [<steps>]  # steps given replace ALL steps
nami-actions remove <action>
nami-actions try "<what the user would say>" [--json]   # shows what would run; runs nothing
```

- `<action>` is an ID, a unique ID prefix of 4+ characters, or any of its phrases.
- `--phrases` replaces all phrases. Give the full list, comma-separated.
- Steps run in the order given:

  ```sh
  nami-actions add --phrases "open Excel repo, open Excel repository" \
      --open-url https://github.com/acme/excel-addin --with "Google Chrome"
  nami-actions add --phrases "start work" \
      --open-app Slack --open-file ~/Projects/website --with "Visual Studio Code"
  nami-actions add --phrases "search GitHub" --open-url "github.com/search?q={{query}}&type=code"
  ```
- For commands with quotes, `$`, or several lines, pass `--command -` and send it
  through a quoted heredoc:

  ```sh
  nami-actions add --phrases "note, quick note" --command - <<'EOF'
  echo "$(date '+%F %R')" {{text}} >> ~/notes.md
  EOF
  ```
- Errors go to stderr with exit status 1, for example when a phrase is already
  used by another action, a reference is not found, or `try` matches nothing.

## Workflow

1. Run `nami-actions list` to avoid duplicates. If a similar action exists,
   update it instead of adding another.
2. Choose phrases: two or three short commands the user would naturally say as
   a whole sentence, with common variants ("open Excel repo, open Excel
   repository, open the Excel repo"). Avoid phrases that ordinary dictation
   often starts with, especially for actions with placeholders.
3. Choose steps. Prefer `--open-url`, `--open-app`, `--open-file`, and
   `--shortcut` over shell commands. Ask for anything you can't infer, such as
   the exact URL or which browser to use; don't guess a repository URL.
4. Add or update the action, then check it with `nami-actions try "<phrase>"`
   (plus example details if it has a placeholder), once per language.
5. Tell the user what to say, e.g. "Say: *Open Excel repo*", and what will happen.

Never run an action's steps yourself to test it unless the user asks; `try` shows
what would run without opening anything. Ask before removing actions unless the
user asked for exactly that, and before adding a shell command that deletes,
overwrites, sends, or publishes anything.
