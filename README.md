# claude-setup

My Claude Code setup.

## statusline

`statusline/statusline-command.sh` — a two-zone-aware statusline: dir, git repo/branch,
model, a half-scale context bar, and 5-hour (S) / weekly (W) rate-limit bars with pace metrics.

Requires `bash`, `jq`, `awk`, `git`.

Install:

```sh
ln -s "$PWD/statusline/statusline-command.sh" ~/.claude/statusline-command.sh
```

Then in `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline-command.sh"
  }
}
```

Colours use the terminal's 16 ANSI slots, so they follow your colour scheme. Tunables
(thresholds, bar widths, glyphs) are at the top of the script.
