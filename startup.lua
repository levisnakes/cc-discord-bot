-- CC Discord Bot launcher. On boot it checks GitHub for a newer bot.lua,
-- downloads it if there is one, then runs it.
--   startup          update, then run the bot
--   startup setup    change the token / server address

local REPO = "levisnakes/cc-discord-bot"
local FILE = "bot.lua"

local function fetch(url)
  if not http then return nil end
  local ok, res = pcall(http.get, url)
  if not ok or not res then return nil end
  local body = res.readAll()
  res.close()
  return body
end

local function readFile(path)
  if not fs.exists(path) then return nil end
  local h = fs.open(path, "r")
  local s = h.readAll()
  h.close()
  return s
end

-- Room for a file of `need` bytes: old logs go first if the disk is full.
local function makeRoom(need)
  local junk = { "bot.log.old", "bot.log" }
  for _, f in ipairs(junk) do
    if fs.getFreeSpace("/") >= need + 20000 then return end
    if fs.exists(f) then fs.delete(f) print("Low on disk space - deleted " .. f) end
  end
end

local function writeFile(path, s)
  makeRoom(#s)
  local h = fs.open(path .. ".new", "w")
  h.write(s)
  h.close()
  if fs.exists(path) then fs.delete(path) end
  fs.move(path .. ".new", path)
end

term.clear()
term.setCursorPos(1, 1)
local code = readFile(FILE)
local have = code and code:match('VERSION = "([^"]+)"')
print("CC Discord Bot launcher  (installed: " .. (have and "v" .. have or "none") .. ")")

-- Ask the API for the newest commit and download from it: plain
-- raw.githubusercontent.com/.../main/ links can be up to 5 minutes stale.
local api = fetch("https://api.github.com/repos/" .. REPO .. "/commits/main")
local sha = api and api:match('"sha"%s*:%s*"(%x+)"')
local base = "https://raw.githubusercontent.com/" .. REPO .. "/" .. (sha or "main") .. "/"

-- Keep this launcher up to date too.
local me = shell.getRunningProgram()
local newMe = fetch(base .. "startup.lua")
if newMe and newMe:find("CC Discord Bot launcher", 1, true) and newMe ~= readFile(me)
    and not _G.discordBotLauncherUpdated then
  writeFile(me, newMe)
  print("Launcher updated - restarting it.")
  _G.discordBotLauncherUpdated = true  -- only once, so it can't loop
  return shell.run(me, ...)
end

local latest = fetch(base .. "version.txt")
latest = latest and latest:match("%S+")
if not latest then
  print("Couldn't reach GitHub - running the installed version.")
elseif latest == have then
  print("Up to date.")
else
  print("Downloading v" .. latest .. "...")
  local new = fetch(base .. FILE)
  -- Only replace the old file with a complete download of the right version.
  if new and new:match('VERSION = "([^"]+)"') == latest then
    writeFile(FILE, new)
    print("Updated to v" .. latest .. ".")
  else
    print("Download failed - running the installed version.")
  end
end

if not fs.exists(FILE) then
  print("No bot.lua yet. Check the internet connection and reboot.")
  return
end
print("")
shell.run(FILE, ...)
