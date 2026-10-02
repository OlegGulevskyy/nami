# Designing Nami pages

The **Snippets** page (`Sources/NamiStudio/SnippetsView.swift`) is the reference
for new pages. Build new pages like it, and move older pages toward it when you
touch them.

## Principles

- **Show only what the user acts on.** Each control gets a short label and
  nothing else. Leave out intro paragraphs, subtitles under labels, hints under
  fields, and example placeholder text.
- **Put explanations behind one click.** Explain the page in a **How it works**
  button (`questionmark.circle`) at the top right. Clicking it opens a popover of
  about 320 pt: a bold title, three to five short sentences, and at most one
  example in `StudioStyle.green`. Don't rely on hover tooltips to explain things.
- **Lists are read-only until you choose Edit.** Rows show their content as
  plain text. Each row has pencil (`pencil`) and delete (`trash`) icons on the
  right. Clicking a row never starts editing.
- **Editing is explicit.** Edit turns that one row into fields with **Cancel**
  (Esc) and **Save** (⌘Return). Changes apply only on Save. Only one row is edited
  at a time: while a row is being edited, the other rows' icons and **Add** are
  disabled. **Add** opens an empty editor, and the item is created only on Save.
  Disable Save until the item is valid.
- **Deleting asks first.** Use a `confirmationDialog` that names the item and
  says it can't be undone.
- **Page settings save automatically.** A single field such as the trigger word
  saves as you type. List items use Edit/Save instead.

## Layout

- The content column is at most 760 pt wide and centred, inside a `ScrollView`.
  Pad it 28 pt at the sides and top and 40 pt at the bottom. Leave 32 pt between
  groups.
- The top row holds the page's own settings, with the help button pushed to the
  right by a `Spacer`.
- A group starts with `StudioSectionHeader(title:)`, a bold title followed by a
  rule.
- Rows sit directly on the page, separated by `StudioStyle.divider`. Don't wrap
  them in cards or tinted boxes. Give each row 12 pt of vertical padding.
- Put the **Add** button below the list with `.preferenceControl()` and a `plus`
  icon.

## Type and colour

Use only the `StudioStyle` colours, never raw colours. They adapt to light and
dark mode.

| Use | Style |
| --- | --- |
| Row title | 15 pt semibold, `ink` |
| Row detail | 14 pt, `quiet`, up to 3 lines |
| Control labels | 15 pt, `ink` |
| Popover text | 12 pt, `ink` |
| Icons and quiet actions (Cancel) | `quiet` |
| Primary actions, links, examples | `green` |
| Errors | 12 pt red `Label` with `exclamationmark.circle`, only when something failed |

Text fields use a plain style on `paper`, with an 8 pt rounded `line` border and
a minimum height of 32 pt. See `snippetField()`. Multi-line text uses a
`TextEditor` with the same border.

## Before you finish

- Add the page to `StudioView.Page`. The sidebar order sets its ⌘ number.
- Check it in light **and** dark mode, and in the 760 pt minimum window width.
  Render it offscreen from a temporary test with `NSHostingView` and
  `cacheDisplay`. Don't launch the app for this, and delete the test afterwards.
- Give every icon-only button a `.help` and an `.accessibilityLabel`.
