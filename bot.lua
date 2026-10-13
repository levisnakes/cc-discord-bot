-- CC Discord Bot: runs your Discord bot from a ComputerCraft computer.
--
-- The computer logs in to Discord as the bot (over a websocket), reads
-- commands typed in your server and answers them:
--   !help        what it can do
--   !whoonline   who's on the Minecraft server (through api.mcsrvstat.us)
--   !say text    posts the text as a formatted embed ("!say Title | text"
--                gives it a title)
--   !time        the in-game day and time
--   !ping        checks the bot is alive
--   !status      reports other computers send in over a modem (see README)
--   !mc text     (Discord) sends the text into Minecraft chat
-- With an Advanced Peripherals Chat Box the same commands work from
-- Minecraft chat too (!cmd, or $cmd to keep it hidden), answered in chat;
-- with a Player Detector, !whoonline lists players without any website.
--
-- First run asks for the bot token and the Minecraft server address and
-- saves them in bot.cfg. The token is a password: anyone who can read this
-- computer's files can use your bot.
--
-- Everything is written to bot.log (the run before is bot.log.old).

VERSION = "1.2.3"

-- ======================== SETTINGS ===========================
-- To keep changes over updates, put them in bot_settings.lua instead.

PREFIX = "!"                 -- what commands start with
STATUS_PROTOCOL = "ccdiscord" -- rednet protocol other computers report on
WHOONLINE_CACHE = 30         -- seconds to reuse a !whoonline answer

-- ===================== END OF SETTINGS =======================

if fs.exists("bot_settings.lua") then
  local f, err = loadfile("bot_settings.lua", nil, _ENV)
  if not f then error("bot_settings.lua: " .. err, 0) end
  f()
end

local CONFIG_FILE = "bot.cfg"
local API = "https://discord.com/api/v10"
local GATEWAY = "wss://gateway.discord.gg/?v=10&encoding=json"
-- Guild messages (512), direct messages (4096), message content (32768).
local INTENTS = 512 + 4096 + 32768
local COLORS = { blurple = 5793266, green = 5763719, red = 15548997, yellow = 16705372, grey = 9807270 }
-- Emoji go in as JSON escapes after serializing (CC strings are bytes).
local EMOJI = { ["{green}"] = "\\ud83d\\udfe2", ["{red}"] = "\\ud83d\\udd34", ["{clock}"] = "\\ud83d\\udd52",
  ["{ship}"] = "\\ud83d\\udea2", ["{pong}"] = "\\ud83c\\udfd3" }

local function now() return os.epoch("utc") / 1000 end

-- ---------- log ----------
local LOG_FILE, LOG_LIMIT = "bot.log", 100000
local logFile, logBytes, logFull = nil, 0, false
local logLines = {}           -- the last few, for the screen
local function log(fmt, ...)
  local line = string.format(fmt, ...)
  logLines[#logLines + 1] = textutils.formatTime(os.time(), true) .. " " .. line
  if #logLines > 8 then table.remove(logLines, 1) end
  os.queueEvent("bot_redraw")
  if not logFile or logFull then return end
  local full = os.date("%H:%M:%S ") .. line
  logBytes = logBytes + #full + 1
  if logBytes > LOG_LIMIT then
    logFull = true
    full = "log full, stopped writing"
  end
  -- A full disk must never stop the program.
  if not pcall(function() logFile.writeLine(full) logFile.flush() end) then logFile = nil end
end

-- ---------- setup ----------

local cfg = {}
local function saveConfig()
  local h = fs.open(CONFIG_FILE, "w")
  h.write(textutils.serialize(cfg))
  h.close()
end
local function loadConfig()
  if fs.exists(CONFIG_FILE) then
    local h = fs.open(CONFIG_FILE, "r")
    local saved = textutils.unserialize(h.readAll() or "")
    h.close()
    if type(saved) == "table" then cfg = saved end
  end
end

local function setup()
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
  print("CC Discord Bot setup")
  print("")
  print("1. discord.com/developers -> your app -> Bot.")
  print("2. Turn ON 'Message Content Intent'.")
  print("3. Reset/copy the token and paste it here")
  print("   (Ctrl+V). It isn't shown.")
  print("")
  local token
  repeat
    write("Bot token: ")
    token = (read("*") or ""):gsub("%s", ""):gsub("^Bot", "")
  until #token > 20
  print("")
  print("Minecraft server address for !whoonline")
  print("(like play.example.com, blank to skip):")
  write("> ")
  local addr = (read() or ""):gsub("%s", "")
  cfg.token = token
  cfg.server = addr ~= "" and addr or nil
  saveConfig()
  print("")
  print("Saved in bot.cfg. To change it later: bot setup")
  sleep(1.5)
end

-- ---------- Discord REST ----------

local function headers(json)
  local h = {
    Authorization = "Bot " .. cfg.token,
    ["User-Agent"] = "DiscordBot (https://github.com/levisnakes/cc-discord-bot, " .. VERSION .. ")",
  }
  if json then h["Content-Type"] = "application/json" end
  return h
end

local function toJSON(payload)
  local s = textutils.serializeJSON(payload)
  for k, v in pairs(EMOJI) do
    local pat = k:gsub("%p", "%%%0")
    s = s:gsub(pat, v)
  end
  return s
end

-- POST with one retry on a rate limit. Returns true when it went through.
local function post(path, payload)
  local body = toJSON(payload)
  for _ = 1, 3 do
    local res, err, bad = http.post(API .. path, body, headers(true))
    if res then res.close() return true end
    local code = bad and bad.getResponseCode()
    local text = bad and bad.readAll() or ""
    if bad then bad.close() end
    if code == 429 then
      local j = textutils.unserializeJSON(text)
      local wait = (j and tonumber(j.retry_after)) or 1
      log("rate limited, waiting %.1f s", wait)
      sleep(wait + 0.1)
    else
      log("POST %s failed: %s %s", path, tostring(code or err), text:sub(1, 150))
      return false
    end
  end
  return false
end

local NO_PINGS = { parse = textutils.empty_json_array or {} }

-- Reply to a message with plain text and/or an embed.
local function reply(msg, content, embed)
  return post("/channels/" .. msg.channel_id .. "/messages", {
    content = content,
    embeds = embed and { embed } or nil,
    message_reference = { message_id = msg.id, fail_if_not_exists = false },
    allowed_mentions = NO_PINGS,
  })
end

-- ---------- what other computers report ----------

local reports = {}   -- name -> { text = , fields = , at = , from = }

local function netLoop()
  while true do
    local _, from, msg, proto = os.pullEvent("rednet_message")
    if proto == STATUS_PROTOCOL and type(msg) == "table" and type(msg.name) == "string" then
      local fields = {}
      if type(msg.fields) == "table" then
        for k, v in pairs(msg.fields) do
          if #fields < 20 then fields[#fields + 1] = { name = tostring(k):sub(1, 256), value = tostring(v):sub(1, 1024), inline = true } end
        end
        table.sort(fields, function(a, b) return a.name < b.name end)
      end
      reports[msg.name:sub(1, 64)] = { text = msg.text and tostring(msg.text):sub(1, 2000) or nil, fields = fields,
        at = now(), from = from }
    end
  end
end

local function ago(t)
  local s = math.floor(now() - t)
  if s < 60 then return s .. "s ago" end
  if s < 3600 then return math.floor(s / 60) .. "m ago" end
  return math.floor(s / 3600) .. "h ago"
end

-- ---------- Minecraft side (Advanced Peripherals) ----------

local gateway = { state = "starting", user = nil, ping = nil }

local chatBox = peripheral.find("chat_box") or peripheral.find("chatBox")
local detector = peripheral.find("player_detector") or peripheral.find("playerDetector")

-- Emoji placeholders don't belong in Minecraft chat, and neither does
-- Discord markdown.
local function plain(s)
  s = tostring(s or ""):gsub("{%a+}%s*", "")
  return (s:gsub("[`*]", ""))
end

-- One Chat Box call, retried while it says "too often" (it refuses
-- messages sent too quickly). Returns true, or false and why.
local function chatCall(method, ...)
  for _ = 1, 8 do
    local ok, res, err = pcall(chatBox[method], ...)
    if ok and res then return true end
    local why = tostring(ok and err or res)
    if not why:lower():find("too often") and not why:lower():find("cooldown") then return false, why end
    sleep(0.5)
  end
  return false, "chat box busy"
end

-- Formatted messages, falling back step by step (fewer extras, then plain
-- text) if this Chat Box version won't take them, so something always arrives.
local mcText
local function chatSend(method, json, a, b, c, d)
  if not chatBox then return false end
  local toPlayer = method == "sendFormattedMessageToPlayer"
  local args = toPlayer and { json, a, b, c, d } or { json, a, b, c }
  local ok, why = chatCall(method, table.unpack(args))
  if ok then return true end
  log("chat box %s failed: %s", method, why)
  -- Just the message (and player).
  ok, why = chatCall(method, json, toPlayer and a or nil)
  if ok then return true end
  log("  plain %s failed too: %s", method, why)
  -- Plain text.
  local text = ""
  local parts = textutils.unserializeJSON(json)
  for _, p in ipairs(type(parts) == "table" and parts or {}) do text = text .. tostring(p.text or "") end
  text = text:gsub("\n", " - "):gsub("^ %- ", "")
  if toPlayer then ok, why = chatCall("sendMessageToPlayer", text, a)
  else ok, why = chatCall("sendMessage", text) end
  if not ok then log("  sendMessage failed too: %s", why) end
  return ok
end

local function hex(c) return string.format("#%06X", c or COLORS.blurple) end

-- A card (title, description, fields, footer, content, color) as chat text.
function mcText(card)
  local parts = {}
  if card.title then parts[#parts + 1] = { text = plain(card.title), color = hex(card.color), bold = true } end
  if card.description then
    parts[#parts + 1] = { text = (card.title and "\n" or "") .. plain(card.description), color = "white", bold = false }
  end
  for _, f in ipairs(card.fields or {}) do
    parts[#parts + 1] = { text = "\n" .. plain(f.name) .. ": ", color = "gray", bold = false }
    parts[#parts + 1] = { text = plain(f.value), color = "white", bold = false }
  end
  if card.content then parts[#parts + 1] = { text = plain(card.content), color = "white" } end
  if card.footer and card.footerInGame then
    parts[#parts + 1] = { text = "\n" .. plain(card.footer), color = "gray", bold = false, italic = true }
  end
  if #parts == 0 then parts[1] = { text = "" } end
  return textutils.serializeJSON(parts)
end

local function botName() return gateway.user or "Bot" end

-- ---------- commands ----------
-- A command gets a ctx and answers with ctx.reply(card), where a card is
-- { title, description, color, fields = { {name, value} }, footer, content }.
-- From Discord it becomes an embed; from Minecraft, a chat message to the
-- player who asked.

local stats = { commands = 0, lastCommand = nil }
local whoCache = nil

local function discordCtx(msg)
  return {
    from = "discord",
    who = msg.author and (msg.author.global_name or msg.author.username) or "someone",
    reply = function(card)
      local embed = nil
      if card.title or card.description or card.fields then
        embed = { title = card.title, description = card.description, color = card.color,
          fields = card.fields and #card.fields > 0 and card.fields or nil,
          footer = card.footer and { text = card.footer } or nil }
      end
      return post("/channels/" .. msg.channel_id .. "/messages", {
        content = card.content, embeds = embed and { embed } or nil,
        message_reference = { message_id = msg.id, fail_if_not_exists = false },
        allowed_mentions = NO_PINGS,
      })
    end,
    -- Everyone in the channel (for !say).
    announce = function(card)
      return post("/channels/" .. msg.channel_id .. "/messages", {
        embeds = { { title = card.title, description = card.description, color = card.color,
          footer = card.footer and { text = card.footer } or nil } },
        allowed_mentions = NO_PINGS,
      })
    end,
    cleanup = function()
      -- Tidy up the command message (needs Manage Messages; fine if it can't).
      pcall(http.request, { url = API .. "/channels/" .. msg.channel_id .. "/messages/" .. msg.id,
        method = "DELETE", headers = headers(false) })
    end,
  }
end

local function minecraftCtx(player)
  return {
    from = "minecraft",
    who = player,
    reply = function(card)
      return chatSend("sendFormattedMessageToPlayer", mcText(card), player, botName(), "[]", "&9")
    end,
    announce = function(card)
      return chatSend("sendFormattedMessage", mcText(card), botName(), "[]", "&9")
    end,
    cleanup = function() end,
  }
end

local COMMANDS = {}
local ORDER = { "help", "whoonline", "say", "mc", "time", "status", "ping" }

COMMANDS.help = { usage = "help", desc = "this list", run = function(ctx)
  local lines = {}
  for _, name in ipairs(ORDER) do
    local c = COMMANDS[name]
    if not (c.discordOnly and ctx.from ~= "discord") then
      lines[#lines + 1] = "`" .. PREFIX .. c.usage .. "` - " .. c.desc
    end
  end
  if ctx.from == "minecraft" then lines[#lines + 1] = "Start with $ instead of " .. PREFIX .. " to keep it out of chat." end
  ctx.reply({ title = "Commands", description = table.concat(lines, "\n"), color = COLORS.blurple,
    footer = "Running on ComputerCraft computer #" .. os.getComputerID() })
end }

COMMANDS.ping = { usage = "ping", desc = "is the bot alive?", run = function(ctx)
  ctx.reply({ content = "{pong} Pong!" .. (gateway.ping and string.format(" Heartbeat %d ms.", gateway.ping) or "")
    .. " Computer #" .. os.getComputerID() .. "." })
end }

COMMANDS.time = { usage = "time", desc = "in-game day and time", run = function(ctx)
  ctx.reply({ title = "{clock} Day " .. os.day("ingame") .. ", " .. textutils.formatTime(os.time("ingame"), false),
    color = COLORS.yellow })
end }

-- Online players: the Player Detector if there is one, else the public
-- server-status site. Returns names, count, max (max may be nil) or nil, why.
local function onlinePlayers()
  if detector then
    local ok, list = pcall(detector.getOnlinePlayers)
    if ok and type(list) == "table" then
      local names = {}
      for _, n in ipairs(list) do names[#names + 1] = tostring(n) end
      return names, #names, nil, "player detector"
    end
    log("player detector failed: %s", tostring(list))
  end
  if not cfg.server then return nil, "No Player Detector and no server address (run `startup setup`)." end
  local data = whoCache and now() - whoCache.at < WHOONLINE_CACHE and whoCache.data
  if not data then
    local res, err = http.get("https://api.mcsrvstat.us/3/" .. textutils.urlEncode(cfg.server))
    if not res then return nil, "Couldn't reach the server-status site: " .. tostring(err) end
    data = textutils.unserializeJSON(res.readAll() or "")
    res.close()
    if type(data) ~= "table" then return nil, "The server-status site sent something odd." end
    whoCache = { at = now(), data = data }
  end
  if not data.online then return nil, (cfg.server .. " is offline"), true end
  local p = data.players or {}
  local names = {}
  for _, pl in ipairs(p.list or {}) do names[#names + 1] = pl.name end
  return names, p.online or #names, p.max, cfg.server .. " - updates about once a minute"
end

COMMANDS.whoonline = { usage = "whoonline", desc = "who's on the Minecraft server", run = function(ctx)
  local names, count, max, source = onlinePlayers()
  if not names then
    ctx.reply(max and { title = "{red} " .. count, color = COLORS.red } or { content = count })
    return
  end
  table.sort(names, function(a, b) return a:lower() < b:lower() end)
  local desc
  if #names > 0 then desc = table.concat(names, "\n")
  elseif count > 0 then desc = "*(the server doesn't share player names)*"
  else desc = "Nobody right now." end
  ctx.reply({
    title = max and string.format("{green} %d / %d online", count, max) or string.format("{green} %d online", count),
    description = desc:sub(1, 4000), color = COLORS.green, footer = source,
  })
end }

COMMANDS.say = { usage = "say [Title |] text", desc = "post a formatted message", run = function(ctx, rest)
  if rest == "" then ctx.reply({ content = "Usage: " .. PREFIX .. "say Title | your message" }) return end
  local title, text = rest:match("^(.-)%s*|%s*(.+)$")
  if not title then title, text = nil, rest end
  local card = { title = title and title:sub(1, 256) or nil, description = text:sub(1, 4000), color = COLORS.blurple,
    footer = "from " .. tostring(ctx.who):sub(1, 64), footerInGame = true }
  ctx.announce(card)
  -- And the other side: Minecraft chat from Discord, the last-used Discord
  -- channel from Minecraft.
  if ctx.from == "discord" then
    if chatBox then chatSend("sendFormattedMessage", mcText(card), botName(), "[]", "&9") end
  elseif cfg.channel then
    post("/channels/" .. cfg.channel .. "/messages", { embeds = { { title = card.title, description = card.description,
      color = card.color, footer = { text = card.footer .. " (in Minecraft)" } } }, allowed_mentions = NO_PINGS })
  end
  ctx.cleanup()
end }

COMMANDS.mc = { usage = "mc text", desc = "send a message into Minecraft chat", discordOnly = true, run = function(ctx, rest)
  if ctx.from ~= "discord" then return end
  if not chatBox then ctx.reply({ content = "No Chat Box on the bot's computer." }) return end
  if rest == "" then ctx.reply({ content = "Usage: " .. PREFIX .. "mc your message" }) return end
  local json = textutils.serializeJSON({
    { text = plain(ctx.who):sub(1, 32) .. ": ", color = "#5865F2", bold = true },
    { text = plain(rest):sub(1, 256), color = "white", bold = false },
  })
  if chatSend("sendFormattedMessage", json, "Discord", "[]", "&9") then
    ctx.reply({ content = "Sent to Minecraft chat." })
  else
    ctx.reply({ content = "The Chat Box didn't take it - try again in a second." })
  end
end }

COMMANDS.status = { usage = "status [name]", desc = "what your computers report", run = function(ctx, rest)
  local names = {}
  for name in pairs(reports) do
    if rest == "" or name:lower() == rest:lower() then names[#names + 1] = name end
  end
  table.sort(names)
  if #names == 0 then
    ctx.reply({ content = rest == "" and "No computer has reported in yet." or ("Nothing from " .. rest .. ".") })
    return
  end
  for i, name in ipairs(names) do
    if i > 5 then break end
    local r = reports[name]
    ctx.reply({ title = "{ship} " .. name, description = r.text, fields = r.fields,
      color = now() - r.at < 60 and COLORS.green or COLORS.grey,
      footer = "computer #" .. r.from .. "  -  " .. ago(r.at) })
  end
end }

-- Commands queue up here so the gateway keeps reading while one runs.
-- Each item: { ctx = , text = } with the prefix already taken off.
local queue = {}
local function runCommand(item)
  local name, rest = item.text:match("^(%S+)%s*(.-)%s*$")
  local c = name and COMMANDS[name:lower()]
  if not c then return end
  stats.commands = stats.commands + 1
  stats.lastCommand = PREFIX .. name:lower()
  log("%s%s from %s (%s)", PREFIX, name:lower(), tostring(item.ctx.who), item.ctx.from)
  local ok, err = pcall(c.run, item.ctx, rest or "")
  if not ok then
    log("%s failed: %s", name, tostring(err))
    pcall(item.ctx.reply, { content = "Something went wrong running that." })
  end
end

local function workLoop()
  while true do
    while #queue > 0 do runCommand(table.remove(queue, 1)) end
    os.pullEvent("bot_command")
  end
end

local function queueDiscord(m)
  -- Remember where commands come from: Minecraft's !say posts there too.
  if m.channel_id and m.guild_id and cfg.channel ~= m.channel_id then
    cfg.channel = m.channel_id
    saveConfig()
  end
  queue[#queue + 1] = { ctx = discordCtx(m), text = m.content:sub(#PREFIX + 1) }
  os.queueEvent("bot_command")
end

-- Minecraft chat: "!cmd" (seen by everyone) or "$cmd" (the Chat Box hides
-- those from chat).
local function chatLoop()
  while true do
    local _, player, message = os.pullEvent("chat")
    if type(player) == "string" and type(message) == "string" then
      local text = nil
      if message:sub(1, #PREFIX) == PREFIX then text = message:sub(#PREFIX + 1)
      elseif message:sub(1, 1) == "$" then text = message:sub(2) end
      if text and chatBox then
        queue[#queue + 1] = { ctx = minecraftCtx(player), text = text }
        os.queueEvent("bot_command")
      end
    end
  end
end

-- ---------- gateway ----------

local ws = nil
local seq = nil
local acked = true
local beatSent = nil
local fatal = nil     -- a reason to stop reconnecting

local FATAL = {
  [4004] = "Discord rejected the token. Run 'bot setup' and paste the current one.",
  [4013] = "Invalid intents.",
  [4014] = "Turn ON 'Message Content Intent' (Developer Portal -> Bot), then reboot.",
}

local function sendRaw(s)
  if ws then pcall(ws.send, s) end
end

local function heartbeat()
  acked = false
  beatSent = now()
  sendRaw('{"op":1,"d":' .. (seq and string.format("%d", seq) or "null") .. '}')
end

local function heartbeatLoop(interval)
  sleep(interval * math.random())
  while true do
    if not acked then
      log("no heartbeat reply - reconnecting")
      return
    end
    heartbeat()
    sleep(interval)
  end
end

local function receiveLoop()
  while true do
    local ev, url, a, b = os.pullEvent()
    if ev == "websocket_closed" and url == GATEWAY then
      log("disconnected: %s %s", tostring(b or ""), tostring(a or ""))
      if b and FATAL[b] then fatal = FATAL[b] end
      return
    elseif ev == "websocket_message" and url == GATEWAY then
      local p = textutils.unserializeJSON(a)
      if type(p) == "table" then
        if p.s then seq = p.s end
        if p.op == 0 then
          if p.t == "READY" then
            gateway.user = p.d.user and p.d.user.username
            gateway.state = "online"
            log("online as %s", tostring(gateway.user))
          elseif p.t == "MESSAGE_CREATE" then
            local m = p.d
            if type(m.content) == "string" and m.content:sub(1, #PREFIX) == PREFIX
                and not (m.author and m.author.bot) then
              queueDiscord(m)
            end
          end
        elseif p.op == 1 then
          heartbeat()
        elseif p.op == 11 then
          acked = true
          if beatSent then gateway.ping = math.floor((now() - beatSent) * 1000 + 0.5) end
        elseif p.op == 7 then
          log("Discord asked for a reconnect")
          return
        elseif p.op == 9 then
          log("session invalid - logging in again")
          sleep(2)
          return
        end
      end
    end
  end
end

local function connectOnce()
  gateway.state = "connecting"
  os.queueEvent("bot_redraw")
  local w, err = http.websocket(GATEWAY)
  if not w then
    log("can't connect: %s", tostring(err))
    return
  end
  ws, seq, acked = w, nil, true
  -- Hello first: it says how often to heartbeat.
  local interval = nil
  local timer = os.startTimer(15)
  while not interval do
    local ev, url, a = os.pullEvent()
    if ev == "websocket_message" and url == GATEWAY then
      local p = textutils.unserializeJSON(a)
      if type(p) == "table" and p.op == 10 then interval = p.d.heartbeat_interval / 1000 end
    elseif ev == "timer" and url == timer then
      log("no hello from Discord")
      pcall(w.close)
      ws = nil
      return
    elseif ev == "websocket_closed" and url == GATEWAY then
      ws = nil
      return
    end
  end
  os.cancelTimer(timer)
  sendRaw(textutils.serializeJSON({ op = 2, d = {
    token = cfg.token, intents = INTENTS,
    properties = { os = "computercraft", browser = "cc-discord-bot", device = "cc-discord-bot" },
  } }))
  gateway.state = "logging in"
  parallel.waitForAny(function() heartbeatLoop(interval) end, receiveLoop)
  pcall(w.close)
  ws = nil
end

local function gatewayLoop()
  local wait = 2
  while true do
    local started = now()
    connectOnce()
    gateway.state = "offline"
    if fatal then
      log(fatal)
      return
    end
    -- Back off if it keeps dropping straight away.
    if now() - started > 60 then wait = 2 else wait = math.min(wait * 2, 60) end
    log("reconnecting in %d s", wait)
    sleep(wait)
  end
end

-- ---------- screen ----------

local function draw()
  local W = term.getSize()
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  local col = gateway.state == "online" and colors.green or (fatal and colors.red or colors.orange)
  if term.isColor() then term.setBackgroundColor(colors.blue) end
  local title = " CC Discord Bot v" .. VERSION
  local badge = " " .. (fatal and "STOPPED" or gateway.state:upper()) .. " "
  term.write(title .. string.rep(" ", math.max(1, W - #title - #badge)))
  if term.isColor() then term.setBackgroundColor(col) end
  term.write(badge)
  term.setBackgroundColor(colors.black)
  term.setCursorPos(1, 3)
  print(" Bot      " .. (gateway.user or "-"))
  print(" Server   " .. (cfg.server or "(none - !whoonline off)"))
  print(" Commands " .. stats.commands .. (stats.lastCommand and ("  last: " .. stats.lastCommand) or ""))
  print(" Ping     " .. (gateway.ping and (gateway.ping .. " ms") or "-"))
  local n = 0
  for _ in pairs(reports) do n = n + 1 end
  print(" Reports  " .. n .. " computer" .. (n == 1 and "" or "s"))
  print(" Chat Box " .. (chatBox and "yes" or "no") .. "   Player Detector " .. (detector and "yes" or "no"))
  if fatal then
    print("")
    if term.isColor() then term.setTextColor(colors.red) end
    print(fatal)
    term.setTextColor(colors.white)
  end
  print("")
  if term.isColor() then term.setTextColor(colors.lightGray) end
  for _, l in ipairs(logLines) do print(" " .. l:sub(1, W - 2)) end
  term.setTextColor(colors.white)
end

local function screenLoop()
  local timer = os.startTimer(0)
  while true do
    local ev, a = os.pullEvent()
    if ev == "bot_redraw" or (ev == "timer" and a == timer) then
      draw()
      if ev == "timer" then timer = os.startTimer(5) end
    end
  end
end

-- ---------- start ----------

local args = { ... }
loadConfig()
if args[1] == "setup" or not cfg.token then setup() end
if not http or not http.websocket then
  printError("This computer can't use http/websockets (server config).")
  return
end

if fs.exists(LOG_FILE) then
  if fs.exists(LOG_FILE .. ".old") then fs.delete(LOG_FILE .. ".old") end
  fs.move(LOG_FILE, LOG_FILE .. ".old")
end
logFile = fs.open(LOG_FILE, "w")
math.randomseed(os.epoch("utc"))
log("CC Discord Bot v%s on computer #%d", VERSION, os.getComputerID())
local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
if modem then rednet.open(peripheral.getName(modem)) log("listening for reports on %s", peripheral.getName(modem))
else log("no wireless modem: !status only works with one") end

local ok, err = xpcall(function()
  parallel.waitForAny(function() gatewayLoop() while true do os.pullEvent("never") end end,
    workLoop, netLoop, screenLoop, chatLoop)
end, debug.traceback)
log("stopped: %s", ok and "ok" or tostring(err))
if ws then pcall(ws.close) end
if logFile then logFile.close() end
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
if not ok and not tostring(err):find("Terminated") then
  printError("Stopped: " .. tostring(err):match("^[^\n]*"))
  print("Details are in bot.log.")
end
