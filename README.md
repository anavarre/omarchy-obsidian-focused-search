# Omarchy Shell Plugin for Obsidian Search

A beautiful [Obsidian](https://obsidian.md/) vault search menu. Type to filter notes with fuzzy ranking, open one with Enter, or create a new note when nothing matches. Search spans every vault you have; `@vault` narrows it to one, `#tag` to the notes carrying that tag and `:property` to the notes whose frontmatter matches.

![Obsidian Search preview](preview.png)

## Features

- Fuzzy search across every vault, ranked by relevance
- `@vault` to focus the search on a single vault
- `#tag` to filter by one or several tags, within the focused vault or across all of them
- `:property=value` to filter on YAML frontmatter, with a picker that lists the keys and values actually in use
- Daily notes included, resolved from your daily-notes settings
- Today's daily note pinned on top, opened or created with one Enter
- Support for bases and canvas files as well
- Create a missing note directly from the menu
- Open notes in Obsidian, omawrite, Neovim, or any command you configure

## Requirements

- Omarchy quattro
- Obsidian
- `fd`, `jq`, and `python3` (preinstalled on Omarchy)

## Install

```bash
omarchy plugin add https://github.com/anavarre/omarchy-obsidian-focused-search.git --enable
```

## Usage

Bind the menu to a key (`~/.config/hypr/bindings.lua`):

```lua
o.bind("SUPER", "O", "exec, omarchy-shell shell summon anavarre.obsidian-focused-search")
```

Type to filter, Enter opens the selected note, Escape closes. A query that matches nothing creates `query.md` in the vault root. With an empty query the first rows are today's daily note for each vault, opened via Obsidian's `obsidian://daily` URI (it creates the note when missing). Typing `daily` or `today` keeps those rows pinned on top.

Shortcuts: Up/Down, Ctrl+K/Ctrl+J, or Ctrl+P/Ctrl+N to move, PageUp/PageDown to jump, Enter to open with the configured opener. Alt+O to force-open the selected note in Obsidian, Alt+W to open it in omawrite, Alt+N to open it in Neovim.

## Focusing on one vault

By default every vault in your Obsidian config is searched at once, and each result shows which vault it came from. To search inside a single vault, start the query with `@`:

- `@` alone lists your vaults with their note counts. Enter picks the highlighted one.
- `@wo` filters that list — matching ignores case and punctuation, so `@my-kb`, `@MyKB` and `@mykb` all find the `My KB` vault.
- Confirming a vault leaves `@Work ` in the query. Everything you type after the space searches only that vault, and the vault name shows on the right of the search line.
- `@Work meeting` goes straight there in one go, without stepping through the picker.

While a vault is focused, the daily-note pin, the create-new-note row, and every result belong to that vault.

Because a leading `@` always opens the picker, a note search cannot itself start with `@`; put the term second (for example `notes @home`) or focus a vault first.

## Filtering by tag

`#` works the same way, anywhere in the query. Tags come from each note's YAML frontmatter and from the inline `#tags` in its body (fenced code blocks are ignored).

- `#` alone lists the tags present in what the query already selected, most used first. Enter picks the highlighted one.
- `#boo` filters that list; confirming leaves `#books ` in the query.
- Several tags stack and all must match: `#books #shortlist` shows only notes carrying both. The tag picker always lists the tags still available inside the current selection, so tags can be stacked by drilling down.
- A parent tag matches its children, so `#work` also finds notes tagged `#work/hiring`.
- Tags combine with a vault and with free text: `@Read #books empowered`.

The active vault and tags are shown on the right of the search line. Because a tag filter is a claim about notes that already exist, the daily-note pin and the create-new-note row step aside while one is active.

## Filtering by property

`:` filters on the YAML frontmatter properties of a note - `author`, `type`, `source`, whatever your vault uses. A key with a list value contributes one entry per item, and `tags` stays with `#` rather than showing up here.

- `:` alone lists the property keys present in what the query already selected, most used first.
- `:au` filters that list; confirming leaves `:author=` in the query, which immediately lists every author in the selection with its note count. So `:author` answers "which authors do I have?" without knowing any of them upfront.
- Picking a value quotes it when it contains spaces: `:author="Marty Cagan"`. Values match case-insensitively as substrings, so `:author=cagan` works too.
- A bare `:author ` with no `=` keeps every note that has the property at all.
- Properties stack with each other, with tags, with a vault and with free text: `@Read #articles :type=article :author="Marty Cagan" vision`.

The picker always counts within the current selection, so `@Read :author=` lists Read's authors with Read's counts. Like tags, an active property filter makes the daily-note pin and the create-new-note row step aside.

Escape peels one layer at a time: the token being typed, then the free text, then each `:property`, then each `#tag`, then the `@vault` scope, then the menu.

## Where notes open

Regular notes open in your configured opener (Obsidian by default). Everything else always opens in Obsidian:

- Today's daily note and daily-note files
- Canvas files
- Bases
- Templates

So Alt+W and Alt+N only change anything for regular notes. Creating a missing note also follows the opener: Obsidian creates it for you by default, while an external opener gets an empty file created first and then opened in that app.

## Configuration

Vaults are auto-detected from `~/.config/obsidian/obsidian.json` by default — all of them, most recently used first. Daily notes are shown by default: the plugin reads the daily folder from `.obsidian/daily-notes.json` (or the periodic-notes plugin when it manages daily notes), and only hides that exact folder when you opt out. The today's-note pin needs the daily-notes (or periodic-notes daily) plugin enabled in the vault; it opens via `obsidian://daily`, so no filename or folder setup is needed for it.

Override settings in `~/.config/omarchy/obsidian-focused-search.json` (watched live, so edits apply instantly and re-list the vault):

```json
{
  "vaultPaths": ["/path/to/first/vault", "/path/to/second/vault"],
  "showDailyNotes": true,
  "showTemplates": false,
  "opener": "obsidian"
}
```

- `vaultPaths`: the vaults to search, in order. The first one is the default target for new notes. Defaults to every vault in the Obsidian config. `vaultPath` (a single directory) is still accepted as a one-vault shorthand.
- `showDailyNotes`: show daily notes in results. Default `true`. Today's-note pin is always shown regardless.
- `showTemplates`: also list files under the templates folder. Default `false`.
- `opener`: how notes open with Enter. Default `"obsidian"`. Use `"omawrite"` to edit in omawrite, `"neovim"` (or `"nvim"`) to edit in Neovim inside a terminal, or any other command that takes a file path (for example `"code"` or `"xdg-open"`).

## Uninstall

```bash
omarchy plugin remove anavarre.obsidian-focused-search
```

## Credits

Project forked from (omarchy-obsidian-search)[https://github.com/BibekBhusal0/omarchy-obsidian-search] by Bibek Bhusal and adapted to my needs so I can implement advanced filtering.

Fuzzy matching uses [`FuzzySearch.js`](FuzzySearch.js), adapted from [omarchy-raindrop-bookmarks](https://github.com/treramey/omarchy-raindrop-bookmarks) by Trevor Ramey, licensed under the MIT License.

This plugin is licensed under the [MIT License](LICENSE).
