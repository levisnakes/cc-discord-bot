# CC Discord Bot

Run your Discord bot from a ComputerCraft computer. It answers commands typed in your Discord server, with no other server or PC needed.

| Command | Does |
|---|---|
| `!help` | lists the commands |
| `!whoonline` | who's on the Minecraft server: from a Player Detector if there is one, otherwise via api.mcsrvstat.us (names if the server shares them, about once a minute) |
| `!say Title | text` | posts a formatted message in Discord **and** Minecraft chat (the title is optional; from Minecraft it goes to the Discord channel the bot was last used in)\| text` | posts a formatted embed (the title is optional), and deletes your command message if the bot has Manage Messages |
| `!time` | the in-game day and time |
| `!status [name]` | reports your other computers send in (see below) |
| `!ping` | checks the bot is alive |
| `!mc text` | (from Discord) sends the text into Minecraft chat as `[Discord] you: text` - needs a Chat Box |

## Advanced Peripherals

- **Chat Box** on the bot's computer: the same commands work from **Minecraft chat**. Type `!whoonline`, or `$whoonline` to keep it out of chat (the Chat Box hides `$` messages). Answers go to just the player who asked; `!say` goes to everyone.
- **Player Detector**: `!whoonline` lists the players straight from the server, instantly, no website needed (the server address is then only a fallback).

## Install

```
wget https://raw.githubusercontent.com/levisnakes/cc-discord-bot/main/startup.lua startup.lua
reboot
```

First run asks for:
1. **The bot token.** In discord.com/developers → your app → **Bot**: turn on **Message Content Intent**, then copy (or reset) the token and paste it with Ctrl+V.
2. **The Minecraft server address** for `!whoonline` (blank to skip).

They're saved in `bot.cfg`. To change them: `startup setup`.

The bot has to be invited to your Discord server with **View Channels**, **Send Messages**, **Read Message History** and **Embed Links** (and **Manage Messages** if `!say` should tidy up after itself).

**The token is a password.** Anyone who can open this computer's files (or a server admin) could use your bot. Don't give the bot more permissions than above. If the same bot also runs somewhere else, both will see every command; only one of them should answer these.

The bot is online while the computer's chunk is loaded. It reconnects by itself if the connection drops.

## Reports from other computers (`!status`)

Any computer with a wireless or ender modem can report in; the bot's computer needs one too:

```lua
peripheral.find("modem", rednet.open)
rednet.broadcast({ name = "Ship", text = "Hovering over spawn",
  fields = { Height = 120, Fuel = "80%" } }, "ccdiscord")
```

`!status` shows the latest report from every computer (green if it's from the last minute), `!status Ship` just that one.

## Settings

Put changes in `bot_settings.lua`, e.g. `PREFIX = "?"`. Everything is logged to `bot.log`.
