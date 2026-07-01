# NetRadar — Claude Code integration

Show the network radar right in your **Claude Code statusline** (bottom), next to
the context meter, and get a full "who / from where" view from the terminal.

```
CONTEXT: ●◦◦◦◦◦◦◦◦◦◦◦◦◦◦◦◦◦◦◦ 6%  ·  RADAR ◐ LAN 6 · NEW 1 · IN 2  ·  Opus 4.8 · mac
```

- `RADAR ◐` — sweep spins on each render
- `LAN n` — devices on your subnet (`arp`)
- `NEW k` — devices not in the baseline snapshot (red)
- `IN k` — inbound connections to your Mac (yellow)

## Files

| File | Role |
|------|------|
| `netradar.js` | background daemon: snapshots `arp`/`lsof` every 10s → `~/.claude/statusbar/net.json`, notifies on new LAN devices |
| `statusline-command.sh` | renders the `CONTEXT … · RADAR …` statusline (reads `net.json`) |
| `net-view.js` | `netradar` command — full table of LAN devices + external connections with reverse-DNS |
| `net-guard.sh` | manual host-level block via `pf`: `block` / `allow` / `list` (optional auto-block, off by default) |

## Install

1. Copy the files into `~/.claude/statusbar/` (create it if needed):

   ```sh
   mkdir -p ~/.claude/statusbar
   cp claude-code/netradar.js claude-code/net-view.js claude-code/net-guard.sh ~/.claude/statusbar/
   cp claude-code/statusline-command.sh ~/.claude/statusline-command.sh
   ```

2. Point Claude Code at the statusline and auto-start the daemon — add to
   `~/.claude/settings.json`:

   ```json
   {
     "statusLine": { "type": "command", "command": "bash ~/.claude/statusline-command.sh" },
     "hooks": {
       "SessionStart": [
         { "hooks": [ { "type": "command", "command": "node ~/.claude/statusbar/netradar.js start" } ] }
       ]
     }
   }
   ```

3. (Optional) add shell aliases:

   ```sh
   alias netradar='node ~/.claude/statusbar/net-view.js'          # who / from where
   alias netradarw='node ~/.claude/statusbar/net-view.js --whois' # + whois org/country
   alias netradar-block='sh ~/.claude/statusbar/net-guard.sh block'
   alias netradar-allow='sh ~/.claude/statusbar/net-guard.sh allow'
   alias netradar-blocks='sh ~/.claude/statusbar/net-guard.sh list'
   ```

Requires `node` and `jq`. Prefer the top **menu-bar app**? See the main
[README](../README.md).

## Blocking (optional)

`net-guard.sh` blocks a host at your Mac's firewall (`pf`) — it isolates *your
Mac* from that IP, it does not remove a device from the whole network (only your
router can do that). Manual is the default; auto-block of unknown inbound
connections is opt-in via `net-guard.sh setup` (installs a narrow passwordless
`pfctl` sudoers rule — review it first).
