--[[----------------------------------------------------------------------------
  CC MUSIC  ·  ProOnlyUNO jukebox for CC:Tweaked
  ----------------------------------------------------------------------------
  Single-file rebuild inspired by friend AURORA (23-module UI/architecture).
  Brand: ProOnlyUNO / CC Music.  No LIKE.  No FOLLOW (lyrics always sync).

  Library (scanned on attached disks + /music):
      disk/Artist/Album/*.dfpwm
      diskN/Artist/Album/*.dfpwm
      disk/music/Artist/Album/*.dfpwm
      music/Artist/Album/*.dfpwm
      Album covers: cover.nfp / album.nfp / matching .nfp beside tracks
      Also BMP/PPM covers (AURORA art path). Lyrics: matching .lrc/.txt
      Music video (optional): matching .cvid beside the .dfpwm
        → after ~3.5s the main monitor switches to the video; audio keeps playing.
        Right-click (or SONG) returns to the normal now-playing UI.
        NEXT/BACK in video mode stay on video when the neighbour has a .cvid.

  Protocols (unchanged):
      pocket_mp3   — pocket remote
      jukebox_viz  — side-monitor visualizers (energy / bands / wave / lyric)

  Usage:
      jukebox
      jukebox --term
      jukebox --scale=0.5
      jukebox /other/root
  ----------------------------------------------------------------------------]]


--======== 00_header.lua ========
-- Friend AURORA architecture (namespaces / locals).
local APP_NAME  = "CC MUSIC"
local APP_TAG   = "ProOnlyUNO"
local VERSION   = "3.0.0"

-- The full UI is designed to fit 30x17 cells at an absolute minimum; the
-- recommended display is a 3x3+ Advanced Monitor at text scale 0.5.
local MIN_W, MIN_H = 30, 17

-- Namespaces.  Everything else is a function or a local inside a function,
-- keeping the top-level Lua chunk well under the 200-local limit.
local Util, Store, Theme, Canvas, Icons = {}, {}, {}, {}, {}
local UI, Data, Art, Lrc, Audio, Player, Auth, Screens, App = {}, {}, {}, {}, {}, {}, {}, {}, {}
local Video, Gallery, Files, Notes, Apps = {}, {}, {}, {}, {}
local CanvasProto
local Config

local unpack = table.unpack or unpack

--======== 10_util.lua ========
------------------------------------------------------------------ utilities
-- Wall-clock seconds with millisecond resolution.  CC:T provides os.epoch.
function Util.now()
  local ok, t = pcall(os.epoch, "utc")
  if ok and type(t) == "number" then return t / 1000 end
  return os.clock and os.clock() or 0
end

function Util.clamp(v, lo, hi)
  v = tonumber(v) or lo
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

function Util.round(v)
  return math.floor((tonumber(v) or 0) + 0.5)
end

function Util.floor(v)
  return math.floor(tonumber(v) or 0)
end

function Util.trim(s)
  s = tostring(s or "")
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function Util.split(s, sep)
  local out = {}
  s = tostring(s or "")
  if sep == nil then sep = "%s+" end
  for part in s:gmatch("(.-)" .. sep) do out[#out + 1] = part end
  return out
end

function Util.splitLines(s)
  local out = {}
  s = tostring(s or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  for line in (s .. "\n"):gmatch("(.-)\n") do out[#out + 1] = line end
  return out
end

function Util.shallowCopy(t)
  local o = {}
  if type(t) == "table" then for k, v in pairs(t) do o[k] = v end end
  return o
end

function Util.indexOf(list, value)
  if type(list) ~= "table" then return nil end
  for i = 1, #list do if list[i] == value then return i end end
  return nil
end

function Util.startsWith(s, prefix)
  return tostring(s):sub(1, #prefix) == prefix
end

function Util.hash(s)
  s = tostring(s or "?")
  local h = 2166136261
  for i = 1, #s do
    h = (h * 16777619 + s:byte(i)) % 4294967291
  end
  return h
end

function Util.plural(n, one, many)
  n = tonumber(n) or 0
  return (n == 1) and (one or "") or (many or (one .. "s"))
end

function Util.fmtTime(sec)
  sec = math.max(0, math.floor(tonumber(sec) or 0))
  if sec >= 3600 then
    return string.format("%d:%02d:%02d", math.floor(sec / 3600), math.floor(sec / 60) % 60, sec % 60)
  end
  return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

function Util.fmtDuration(sec)
  sec = math.max(0, math.floor(tonumber(sec) or 0))
  local h = math.floor(sec / 3600)
  local m = math.floor(sec / 60) % 60
  if h > 0 then return string.format("%dh %02dm", h, m) end
  return string.format("%dm", m)
end

function Util.fmtSize(n)
  n = tonumber(n) or 0
  if n >= 1024 * 1024 then return string.format("%.1f MB", n / 1024 / 1024) end
  if n >= 1024 then return string.format("%d KB", math.floor(n / 1024 + 0.5)) end
  return tostring(math.floor(n)) .. " B"
end

function Util.fmtCount(n)
  n = tonumber(n) or 0
  if n >= 1000000 then return string.format("%.1fM", n / 1000000) end
  if n >= 1000 then return string.format("%.1fk", n / 1000) end
  return tostring(n)
end

------------------------------------------------------------------ text for CC
-- CC:Tweaked's terminal glyph set is one byte per cell.  User text can contain
-- arbitrary UTF-8; convert it to the CC glyph set (ASCII + Latin-1) so that
-- term.blit alignment is always exact.  Also handles common smart punctuation.
local utf8Map = {
  [0x00A0] = " ", [0x00AB] = '"', [0x00BB] = '"', [0x00B7] = ".",
  [0x2010] = "-", [0x2011] = "-", [0x2012] = "-", [0x2013] = "-",
  [0x2014] = "-", [0x2015] = "-", [0x2018] = "'", [0x2019] = "'",
  [0x201A] = "'", [0x201B] = "'", [0x201C] = '"', [0x201D] = '"',
  [0x201E] = '"', [0x2022] = "\7", [0x2026] = "...", [0x2032] = "'",
  [0x2033] = '"', [0x2039] = "<", [0x203A] = ">", [0x2044] = "/",
  [0x2190] = "\27", [0x2191] = "\24", [0x2192] = "\26", [0x2193] = "\25",
  [0x25B6] = "\16", [0x25C0] = "\17", [0x2665] = "\3", [0x266A] = "\14",
  [0x266B] = "\15", [0x00D7] = "x", [0x00F7] = "/", [0x20AC] = "EUR",
}
local latinFold = {
  ["À"] = "A", ["Á"] = "A", ["Â"] = "A", ["Ã"] = "A", ["Ä"] = "A", ["Å"] = "A",
  ["Æ"] = "AE", ["Ç"] = "C", ["È"] = "E", ["É"] = "E", ["Ê"] = "E", ["Ë"] = "E",
  ["Ì"] = "I", ["Í"] = "I", ["Î"] = "I", ["Ï"] = "I", ["Ð"] = "D", ["Ñ"] = "N",
  ["Ò"] = "O", ["Ó"] = "O", ["Ô"] = "O", ["Õ"] = "O", ["Ö"] = "O", ["Ø"] = "O",
  ["Ù"] = "U", ["Ú"] = "U", ["Û"] = "U", ["Ü"] = "U", ["Ý"] = "Y", ["Þ"] = "TH",
  ["ß"] = "ss", ["à"] = "a", ["á"] = "a", ["â"] = "a", ["ã"] = "a", ["ä"] = "a",
  ["å"] = "a", ["æ"] = "ae", ["ç"] = "c", ["è"] = "e", ["é"] = "e", ["ê"] = "e",
  ["ë"] = "e", ["ì"] = "i", ["í"] = "i", ["î"] = "i", ["ï"] = "i", ["ð"] = "d",
  ["ñ"] = "n", ["ò"] = "o", ["ó"] = "o", ["ô"] = "o", ["õ"] = "o", ["ö"] = "o",
  ["ø"] = "o", ["ù"] = "u", ["ú"] = "u", ["û"] = "u", ["ü"] = "u", ["ý"] = "y",
  ["þ"] = "th", ["ÿ"] = "y",
}

-- Decode one UTF-8 sequence; returns codepoint, nextByte or nil.
local function decodeUtf8(s, i)
  local b = s:byte(i)
  if not b then return nil end
  if b < 0x80 then return b, i + 1 end
  local extra, cp
  if b >= 0xC2 and b <= 0xDF then extra, cp = 1, b - 0xC0
  elseif b >= 0xE0 and b <= 0xEF then extra, cp = 2, b - 0xE0
  elseif b >= 0xF0 and b <= 0xF4 then extra, cp = 3, b - 0xF0
  else return nil end
  for k = 1, extra do
    local nb = s:byte(i + k)
    if not nb or nb < 0x80 or nb > 0xBF then return nil end
    cp = cp * 64 + (nb - 0x80)
  end
  return cp, i + extra + 1
end

-- Convert the UTF-8-keyed fold table into a one-byte table, matching the
-- Latin-1 output of Util.clean.
local foldBytes = {}
for k, v in pairs(latinFold) do
  local cp = decodeUtf8(k, 1)
  if cp and cp <= 0xFF then foldBytes[string.char(cp)] = v end
end

local function pushGlyph(out, cp)
  if cp == 9 then out[#out + 1] = " "
  elseif cp == 10 or cp == 13 then out[#out + 1] = " "
  elseif cp >= 32 and cp <= 126 then out[#out + 1] = string.char(cp)
  elseif utf8Map[cp] then out[#out + 1] = utf8Map[cp]
  elseif cp >= 0xA0 and cp <= 0xFF then out[#out + 1] = string.char(cp)
  else out[#out + 1] = "?" end
end

-- Convert arbitrary text into a one-byte-per-cell CC glyph string.
function Util.clean(s)
  s = tostring(s or "")
  local out, i, n = {}, 1, #s
  while i <= n do
    local b = s:byte(i)
    if b < 0x80 then
      pushGlyph(out, b); i = i + 1
    else
      local cp, ni = decodeUtf8(s, i)
      if cp then
        pushGlyph(out, cp); i = ni
      else
        -- Raw Latin-1 / CP437-ish byte.  Never let 0x80-0x9F through: those are
        -- AURORA's private sextant glyphs and would corrupt text with blocks.
        if b >= 0xA0 then out[#out + 1] = string.char(b)
        elseif b == 0x7F then out[#out + 1] = "."
        else out[#out + 1] = "?" end
        i = i + 1
      end
    end
  end
  local res = table.concat(out)
  res = res:gsub("%s+", " ")
  return (res:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Clean but keep leading/trailing spaces?  UI text always uses clean.
function Util.cleanRaw(s)
  return Util.clean(s)
end

function Util.fit(s, w)
  s = Util.clean(s)
  w = math.max(0, math.floor(w or 0))
  if w <= 0 then return "" end
  if #s <= w then return s end
  if w <= 2 then return s:sub(1, w) end
  return s:sub(1, w - 2) .. ".."
end

function Util.right(s, w)
  s = Util.clean(s)
  w = math.max(0, math.floor(w or 0))
  if #s >= w then return s:sub(1, w) end
  return string.rep(" ", w - #s) .. s
end

function Util.center(s, w)
  s = Util.clean(s)
  w = math.max(0, math.floor(w or 0))
  if #s >= w then return s:sub(1, w) end
  local left = math.floor((w - #s) / 2)
  return string.rep(" ", left) .. s .. string.rep(" ", w - #s - left)
end

function Util.wrap(s, w)
  s = Util.clean(s)
  w = math.max(1, math.floor(w or 1))
  local lines, line = {}, ""
  for word in s:gmatch("%S+") do
    if #word > w then
      if line ~= "" then lines[#lines + 1] = line; line = "" end
      local rest = word
      while #rest > w do
        lines[#lines + 1] = rest:sub(1, w)
        rest = rest:sub(w + 1)
      end
      line = rest
    elseif line == "" then
      line = word
    elseif #line + 1 + #word <= w then
      line = line .. " " .. word
    else
      lines[#lines + 1] = line
      line = word
    end
  end
  if line ~= "" or #lines == 0 then lines[#lines + 1] = line end
  return lines
end

-- Lower-case / accent-fold for natural sorting and search.
function Util.fold(s)
  s = Util.clean(s)
  local out = {}
  for i = 1, #s do
    local ch = s:sub(i, i)
    local mapped = foldBytes[ch]
    if mapped then
      out[#out + 1] = mapped
    elseif ch:byte() >= 32 then
      out[#out + 1] = ch
    end
  end
  s = table.concat(out):lower()
  s = s:gsub("[^%w]+", " ")
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function Util.naturalKey(s)
  s = Util.fold(s)
  s = s:gsub("%d+", function(n)
    local v = tostring(tonumber(n) or 0)
    return string.rep("0", math.max(0, 12 - #v)) .. v
  end)
  return s
end

function Util.tokens(s)
  local out = {}
  for word in Util.fold(s):gmatch("%S+") do out[#out + 1] = word end
  return out
end

function Util.matchesAll(haystack, tokens)
  for _, t in ipairs(tokens) do
    if not haystack:find(t, 1, true) then return false end
  end
  return true
end

------------------------------------------------------------------ colours
function Util.rgbHex(rgb)
  return string.format("%06X", (tonumber(rgb) or 0) % 0x1000000)
end

function Util.hexRgb(hex)
  if type(hex) == "number" then return hex end
  hex = tostring(hex or "000000"):gsub("#", "")
  if #hex == 3 then
    hex = hex:sub(1, 1):rep(2) .. hex:sub(2, 2):rep(2) .. hex:sub(3, 3):rep(2)
  end
  return tonumber(hex, 16) or 0
end

function Util.rgbParts(rgb)
  rgb = tonumber(rgb) or 0
  return math.floor(rgb / 65536) % 256, math.floor(rgb / 256) % 256, rgb % 256
end

function Util.packRgb(r, g, b)
  return (math.floor(Util.clamp(r, 0, 255)) * 65536
    + math.floor(Util.clamp(g, 0, 255)) * 256
    + math.floor(Util.clamp(b, 0, 255)))
end

function Util.blend(a, b, t)
  t = Util.clamp(t or 0, 0, 1)
  local ar, ag, ab = Util.rgbParts(a)
  local br, bg, bb = Util.rgbParts(b)
  return Util.packRgb(ar + (br - ar) * t, ag + (bg - ag) * t, ab + (bb - ab) * t)
end

function Util.shade(rgb, t)
  if t < 0 then return Util.blend(rgb, 0x000000, -t) end
  return Util.blend(rgb, 0xFFFFFF, t)
end

function Util.luma(rgb)
  local r, g, b = Util.rgbParts(rgb)
  return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
end

function Util.contrastOn(rgb)
  return Util.luma(rgb) > 0.55 and 0x080A0F or 0xF2F5FA
end

------------------------------------------------------------------ persistence
Store.dir = ".aurora"
Store.ready = false
Store.pending = {}
Store.due = 0

function Store.path(name)
  if Store.dir == "" then return name end
  return fs.combine(Store.dir, name)
end

function Store.ensureDir()
  if Store.ready then return true end
  local ok = pcall(function()
    if not fs.exists(Store.dir) then fs.makeDir(Store.dir) end
    if not fs.isDir(Store.dir) then error("not a directory") end
  end)
  Store.ready = ok
  return ok
end

function Store.setDir(dir)
  Store.dir = (dir and dir ~= "") and dir or ".aurora"
  Store.ready = false
  Store.pending = {}
  return Store.ensureDir()
end

local function readPath(path)
  local ok, f = pcall(fs.open, path, "rb")
  if not ok or not f then return nil end
  local ok2, data = pcall(function() return f.readAll() end)
  pcall(function() f.close() end)
  if not ok2 then return nil end
  return data or ""
end

function Store.readRaw(path)
  return readPath(path)
end

local function unserialize(data)
  if type(data) ~= "string" or data == "" then return nil end
  local ok, value = pcall(textutils.unserialize, data)
  if ok and type(value) == "table" then return value end
  return nil
end

function Store.load(name, default)
  if not Store.ensureDir() then return default, "no-data-dir" end
  local path = Store.path(name)
  local data = readPath(path)
  local t = unserialize(data)
  if t then return t, nil end
  -- A previous interrupted write may have left a valid backup.
  local bak = readPath(path .. ".bak")
  t = unserialize(bak)
  if t then return t, "backup" end
  return default, data and "corrupt" or "missing"
end

local function writeRaw(path, data)
  local ok, f = pcall(fs.open, path, "wb")
  if not ok or not f then return false end
  local wok = pcall(function() f.write(data) end)
  pcall(function() f.close() end)
  return wok
end

function Store.save(name, data)
  if not Store.ensureDir() then return false end
  local ok, ser = pcall(textutils.serialize, data)
  if not ok or type(ser) ~= "string" then return false end
  local path = Store.path(name)
  local tmp, bak = path .. ".tmp", path .. ".bak"
  if not writeRaw(tmp, ser) then return false end
  if fs.exists(bak) then pcall(fs.delete, bak) end
  if fs.exists(path) then
    local moved = pcall(fs.move, path, bak)
    if not moved then pcall(fs.delete, tmp); return false end
  end
  local moved = pcall(fs.move, tmp, path)
  if not moved then
    pcall(fs.delete, tmp)
    if fs.exists(bak) then pcall(fs.move, bak, path) end
    return false
  end
  Store.pending[name] = nil
  return true
end

function Store.saveSoon(name, data)
  Store.pending[name] = data
  Store.due = Util.now() + 0.9
end

function Store.flush(force)
  if not force and Util.now() < Store.due then return end
  for name, data in pairs(Store.pending) do
    if Store.save(name, data) then Store.pending[name] = nil end
  end
  Store.due = 0
end

function Store.exists(name)
  return Store.ensureDir() and fs.exists(Store.path(name))
end

function Store.delete(name)
  pcall(fs.delete, Store.path(name))
  pcall(fs.delete, Store.path(name) .. ".bak")
end

function Store.log(message)
  local ok, path = pcall(Store.path, "error.log")
  if not ok then return end
  local line = string.format("[%s] %s\n", os.date and os.date("%Y-%m-%d %H:%M:%S") or tostring(os.time()), tostring(message):sub(1, 800))
  pcall(function()
    local size = fs.getSize(path) or 0
    if size > 65536 then
      writeRaw(path, line)
    else
      local f = fs.open(path, "ab")
      if f then f.write(line); f.close() end
    end
  end)
end

function Store.logError(where, err)
  Store.log(where .. ": " .. tostring(err) .. "\n" .. (debug and debug.traceback and debug.traceback() or ""))
end

--======== 20_config.lua ========
------------------------------------------------------------------ configuration
Config = {}

Config.defaultRoots = {
  "music",
  "disk",
  "disk/music",
}

-- Cap for cfg.roots. Old value (40) truncated boot-expanded disk1..N pairs
-- so libraries stopped around disk19. High enough for dense drive banks.
Config.MAX_ROOTS = 256

-- Roots that older AURORA/jukebox versions added automatically.  Missing
-- entries from this list are pruned once so the settings page stays useful.
-- (Any diskN / diskN/music path is also treated as legacy via isLegacyRoot.)
Config.legacyRoots = {
  "music", "disk", "disk/music",
}

Config.accents = {
  { id = "teal",   label = "Teal",   rgb = 0x2DD4BF },
  { id = "azure",  label = "Azure",  rgb = 0x60A5FA },
  { id = "amber",  label = "Amber",  rgb = 0xF59E0B },
  { id = "rose",   label = "Rose",   rgb = 0xFB7185 },
  { id = "violet", label = "Violet", rgb = 0xA78BFA },
  { id = "lime",   label = "Lime",   rgb = 0xA3E635 },
  { id = "ice",    label = "Ice",    rgb = 0x67E8F9 },
  { id = "coral",  label = "Coral",  rgb = 0xFB923C },
}

-- Preset swatches are drawn with the theme's nearest palette slot, because a
-- canvas cell can only use one of the monitor's 16 palette entries.  The real
-- RGB is applied to the palette when the swatch is tapped.
Config.accentSlot = {
  teal = 1, azure = 11, amber = 4, rose = 14,
  violet = 10, lime = 13, ice = 5, coral = 12,
}

-- Match pre-Aurora jukebox.lua (CONFIG.maxVolume = 3.0).
-- speaker.playAudio volume 0..3 controls hear distance as well as loudness.
Config.MAX_VOLUME = 3.0

Config.defaults = {
  version = 1,
  accent = "violet",
  accentRgb = nil,
  monitorScale = 0.5,
  animations = true,
  visualizer = "bars",
  -- CC:Tweaked speaker.playAudio accepts 0..3; higher values travel farther.
  volume = 1.0,
  muted = false,
  shuffle = false,
  repeatMode = "off",
  autoLock = 5,
  albumView = "grid",
  lastTab = "albums",
  lastScreen = "home",
  recentApps = {},
  recentFiles = {},
  showLyricsPreview = true,
  -- Music-video handoff: play jukebox UI first, then switch this monitor to .cvid.
  musicVideo = true,
  videoDelaySec = 3.5,
  roots = nil,
  speakerEnabled = {},
  speakerGain = {},
}

function Config.getAccentRgb()
  local cfg = App and App.cfg
  if cfg and type(cfg.accentRgb) == "number" then
    return cfg.accentRgb % 0x1000000
  end
  local id = cfg and cfg.accent or "teal"
  for _, a in ipairs(Config.accents) do
    if a.id == id then return a.rgb end
  end
  return Config.accents[1].rgb
end

function Config.setAccentRgb(rgb, id)
  App.cfg.accentRgb = (tonumber(rgb) or 0) % 0x1000000
  if id then App.cfg.accent = id end
  -- A preset click clears the custom override unless it is the same value.
  if id then
    for _, a in ipairs(Config.accents) do
      if a.id == id and a.rgb == App.cfg.accentRgb then
        App.cfg.accentRgb = nil
        break
      end
    end
  end
  Config.saveSoon()
end

local function copyDefaults()
  local c = {}
  for k, v in pairs(Config.defaults) do
    if type(v) == "table" then
      local t = {}
      for kk, vv in pairs(v) do t[kk] = vv end
      c[k] = t
    else
      c[k] = v
    end
  end
  c.roots = {}
  for i, p in ipairs(Config.defaultRoots) do c.roots[i] = p end
  return c
end

local function validStringList(t, max)
  local out = {}
  if type(t) ~= "table" then return out end
  for _, v in ipairs(t) do
    if type(v) == "string" and v ~= "" and #v <= 240 then
      out[#out + 1] = v
      if max and #out >= max then break end
    end
  end
  return out
end

local function validate(c)
  local d = Config.defaults
  if type(c.accent) ~= "string" then c.accent = d.accent end
  local accentOk = false
  for _, a in ipairs(Config.accents) do
    if a.id == c.accent then accentOk = true; break end
  end
  if not accentOk then c.accent = d.accent end
  if type(c.accentRgb) ~= "number" then c.accentRgb = nil
  else c.accentRgb = math.floor(c.accentRgb) % 0x1000000 end
  c.monitorScale = Util.clamp(c.monitorScale, 0.5, 2.0)
  c.animations = c.animations ~= false
  if c.visualizer ~= "bars" and c.visualizer ~= "wave" and c.visualizer ~= "vu" and c.visualizer ~= "off" then
    c.visualizer = "bars"
  end
  c.volume = Util.clamp(c.volume, 0, Config.MAX_VOLUME)
  c.muted = c.muted == true
  c.shuffle = c.shuffle == true
  if c.repeatMode == nil and type(c["repeat"]) == "string" then c.repeatMode = c["repeat"] end
  c["repeat"] = nil
  if c.repeatMode ~= "off" and c.repeatMode ~= "all" and c.repeatMode ~= "one" then c.repeatMode = "off" end
  c.autoLock = Util.clamp(tonumber(c.autoLock) or 5, 0, 60)
  if c.albumView ~= "grid" and c.albumView ~= "list" then c.albumView = "grid" end
  if type(c.lastTab) ~= "string" then c.lastTab = "albums" end
  c.showLyricsPreview = c.showLyricsPreview ~= false
  c.musicVideo = c.musicVideo ~= false
  c.videoDelaySec = Util.clamp(tonumber(c.videoDelaySec) or d.videoDelaySec or 3.5, 0, 30)
  c.recentApps = validStringList(c.recentApps, 8)
  c.recentFiles = validStringList(c.recentFiles, 10)
  c.roots = validStringList(c.roots, Config.MAX_ROOTS)
  if #c.roots == 0 then
    for i, p in ipairs(Config.defaultRoots) do c.roots[i] = p end
  end
  c.speakerEnabled = type(c.speakerEnabled) == "table" and c.speakerEnabled or {}
  c.speakerGain = type(c.speakerGain) == "table" and c.speakerGain or {}
  for k, v in pairs(c.speakerGain) do
    if type(k) ~= "string" or type(v) ~= "number" then c.speakerGain[k] = nil
    else c.speakerGain[k] = Util.clamp(v, 0, 1) end
  end
  return c
end

local function readOld(name)
  if not fs.exists(name) then return nil end
  local ok, f = pcall(fs.open, name, "rb")
  if not ok or not f then return nil end
  local data = f.readAll()
  f.close()
  local ok2, t = pcall(textutils.unserialize, data or "")
  return ok2 and type(t) == "table" and t or nil
end

local function isLegacyRoot(path)
  path = tostring(path or "")
  if path:match("^disk%d*$") or path:match("^disk%d*/music$") then return true end
  for _, p in ipairs(Config.legacyRoots) do if p == path then return true end end
  return false
end

-- All attached floppy mounts: fs root dirs named disk/diskN (any N) plus
-- drive peripherals via disk.getMountPath (side/network drive names).
function Config.listFloppyMounts()
  local mounts, seen = {}, {}
  local function add(m)
    if not m or m == "" then return end
    m = tostring(m):gsub("^/", "")
    if seen[m] or not m:match("^disk%d*$") then return end
    local ok, isDir = pcall(fs.isDir, m)
    if ok and isDir then
      seen[m] = true
      mounts[#mounts + 1] = m
    end
  end
  local lok, entries = pcall(fs.list, "")
  if lok and type(entries) == "table" then
    for _, name in ipairs(entries) do
      if type(name) == "string" and name:match("^disk%d*$") then add(name) end
    end
  end
  local pok, names = pcall(peripheral.getNames)
  if pok and type(names) == "table" then
    for _, pname in ipairs(names) do
      local tok, typ = pcall(peripheral.getType, pname)
      if tok and typ == "drive" then
        local mok, mount = pcall(disk.getMountPath, pname)
        if mok and mount then add(mount) end
      end
    end
  end
  table.sort(mounts, function(a, b)
    local na = tonumber(a:match("%d+")) or (a == "disk" and 1 or 0)
    local nb = tonumber(b:match("%d+")) or (b == "disk" and 1 or 0)
    if na ~= nb then return na < nb end
    return a < b
  end)
  return mounts
end

function Config.discoverRoots()
  if not App.cfg then return end
  local present = {}
  for _, p in ipairs(App.cfg.roots) do present[p] = true end
  local added = false
  local function consider(path)
    if not path or present[path] then return end
    if #App.cfg.roots >= (Config.MAX_ROOTS or 256) then return end
    local ok, isDir = pcall(fs.isDir, path)
    if ok and isDir then
      App.cfg.roots[#App.cfg.roots + 1] = path
      present[path] = true
      added = true
    end
  end
  consider("music")
  for _, mount in ipairs(Config.listFloppyMounts()) do
    consider(mount)
    consider(fs.combine(mount, "music"))
  end
  if added then Config.saveSoon() end
end

function Config.load()
  local cfg = copyDefaults()
  local data, why = Store.load("config", nil)
  if type(data) == "table" then
    for k, v in pairs(data) do cfg[k] = v end
  elseif not data then
    -- Import the old jukebox settings once, without deleting anything.
    local old = readOld(".jukebox_settings")
    if old then
      cfg.volume = Util.clamp(tonumber(old.volume) or cfg.volume, 0, Config.MAX_VOLUME)
      cfg.muted = old.muted == true
      cfg.shuffle = old.shuffle == true
      if old.rep == "all" or old.rep == "one" or old.rep == "off" then cfg.repeatMode = old.rep end
      cfg.importedLegacy = true
    end
  end
  App.cfg = validate(cfg)
  if not App.cfg.rootsMigrated then
    local kept = {}
    local seen = {}
    for _, p in ipairs(App.cfg.roots) do
      if not seen[p] then
        seen[p] = true
        if not (isLegacyRoot(p) and p ~= "music" and not fs.isDir(p)) then
          kept[#kept + 1] = p
        end
      end
    end
    if #kept == 0 then kept[1] = "music" end
    App.cfg.roots = kept
    App.cfg.rootsMigrated = true
    Config.saveSoon()
  end
  if why == "corrupt" then
    Store.log("config was corrupt; using defaults")
    App.cfgCorrupt = true
  end
  return App.cfg
end

function Config.saveNow()
  if not App.cfg then return end
  Store.save("config", App.cfg)
end

function Config.saveSoon()
  if not App.cfg then return end
  Store.saveSoon("config", App.cfg)
end

function Config.setRoots(roots)
  App.cfg.roots = validStringList(roots, Config.MAX_ROOTS)
  if #App.cfg.roots == 0 then
    App.cfg.roots[1] = "music"
  end
  Config.saveSoon()
  if Data and Data.rescan then
    Data.rescan()
  end
end

function Config.addRoot(path)
  path = Util.trim(path)
  if path == "" then return false end
  for _, p in ipairs(App.cfg.roots) do
    if p == path then return false end
  end
  if #App.cfg.roots >= (Config.MAX_ROOTS or 256) then return false end
  App.cfg.roots[#App.cfg.roots + 1] = path
  Config.saveSoon()
  return true
end

function Config.removeRoot(path)
  for i, p in ipairs(App.cfg.roots) do
    if p == path then
      table.remove(App.cfg.roots, i)
      if #App.cfg.roots == 0 then App.cfg.roots[1] = "music" end
      Config.saveSoon()
      return true
    end
  end
  return false
end

function Config.cycleTextScale(dir)
  local cur = tonumber(App.cfg.monitorScale) or 0.5
  local v = math.floor((cur + (dir or 1) * 0.1) * 10 + 0.5) / 10
  App.cfg.monitorScale = Util.clamp(v, 0.5, 2.0)
  Config.saveSoon()
  return App.cfg.monitorScale
end


--======== 30_theme.lua ========
------------------------------------------------------------------ theme / palette
-- CC colour indices used by term.blit:
--   0 white  1 orange  2 magenta  3 lightBlue  4 yellow  5 lime  6 pink
--   7 gray   8 lightGray 9 cyan   10 purple   11 blue  12 brown 13 green
--   14 red   15 black
-- AURORA redefines these sixteen slots into a semantic dark theme.
Theme.C = {
  bg = 15, surface = 9, surface2 = 3,
  text = 0, muted = 8, dim = 7,
  accent = 1, accentDim = 2, accentLight = 5, onAccent = 15,
  danger = 14, warning = 4, pink = 6, blue = 11, violet = 10, green = 13,
  amber = 12,
}

Theme.fallback = {
  [0] = 0,   -- text -> white
  [1] = 9,   -- accent -> cyan
  [2] = 11,  -- accentDim -> blue
  [3] = 7,   -- surface2 -> gray
  [4] = 4,   -- warning -> yellow
  [5] = 3,   -- accentLight -> light blue
  [6] = 6,   -- pink -> pink
  [7] = 7,   -- dim -> gray
  [8] = 8,   -- muted -> light gray
  [9] = 7,   -- surface -> gray
  [10] = 10, -- violet -> purple
  [11] = 11, -- blue -> blue
  [12] = 1,  -- amber -> orange
  [13] = 13, -- green -> green
  [14] = 14, -- danger -> red
  [15] = 15, -- background -> black
}

Theme.rgb = {}
Theme.map = {}
Theme.custom = false
Theme.applied = false
Theme.original = nil
Theme.version = 0

function Theme.rebuild()
  local base = Config.getAccentRgb()
  local bg = 0x080A0F
  local surface = 0x141922
  local surface2 = 0x1D2430
  local text = 0xF2F5FA
  local muted = 0x9AA3B2
  local dim = 0x5B6472
  local accentDim = Util.blend(base, bg, 0.58)
  local accentLight = Util.blend(base, 0xFFFFFF, 0.34)
  local onAccent = Util.contrastOn(base)
  local r = {}
  r[0] = text
  r[1] = base
  r[2] = accentDim
  r[3] = surface2
  r[4] = 0xFBBF24
  r[5] = accentLight
  r[6] = 0xF472B6
  r[7] = dim
  r[8] = muted
  r[9] = surface
  r[10] = 0xA78BFA
  r[11] = 0x60A5FA
  r[12] = 0xF59E0B
  r[13] = 0x4ADE80
  r[14] = 0xF87171
  r[15] = bg
  Theme.rgb = r
  Theme.accent = base
  Theme.accentDim = accentDim
  Theme.accentLight = accentLight
  Theme.onAccent = onAccent
  Theme.bg = bg
  Theme.surface = surface
  Theme.version = Theme.version + 1
  if not Theme.custom then
    for i = 0, 15 do Theme.map[i] = Theme.fallback[i] or i end
  end
end

function Theme.init(termObj)
  Theme.rebuild()
  Theme.apply(termObj)
end

function Theme.apply(termObj)
  if not termObj then return end
  local setter = termObj.setPaletteColor or termObj.setPaletteColour
  local getter = termObj.getPaletteColor or termObj.getPaletteColour
  if not Theme.original then
    Theme.original = {}
    if getter then
      for i = 0, 15 do
        local ok, r, g, b = pcall(getter, 2 ^ i)
        if ok and type(r) == "number" then Theme.original[i] = { r, g, b } end
      end
    end
  end
  local ok = setter ~= nil
  if ok then
    for i = 0, 15 do
      local rgb = Theme.rgb[i]
      local good = pcall(setter, 2 ^ i, rgb)
      if not good then ok = false; break end
    end
  end
  Theme.custom = ok
  for i = 0, 15 do
    Theme.map[i] = ok and i or (Theme.fallback[i] or i)
  end
  Theme.applied = true
end

function Theme.restore(termObj)
  termObj = termObj or (App and App.term)
  if not termObj or not Theme.original then return end
  local setter = termObj.setPaletteColor or termObj.setPaletteColour
  if not setter then return end
  for i = 0, 15 do
    local c = Theme.original[i]
    if c then pcall(setter, 2 ^ i, c[1], c[2], c[3]) end
  end
  Theme.original = nil
end

function Theme.digit(i)
  return Theme.map[i] or i
end

function Theme.colorConstant(i)
  return 2 ^ Theme.digit(i)
end

function Theme.col(n)
  return Theme.rgb[n] or 0
end

function Theme.artPalette()
  local out = {}
  for i = 0, 15 do out[i] = Theme.rgb[i] or 0 end
  return out
end

function Theme.setAccent(rgb, id)
  Config.setAccentRgb(rgb, id)
  Theme.rebuild()
  Theme.apply(App.term)
  if Art and Art.clearCache then Art.clearCache() end
  if UI and UI.request then UI.request(true) end
end

function Theme.dimmed(color, amount)
  return Util.blend(color, Theme.bg, amount or 0.55)
end

--======== 40_canvas.lua ========
------------------------------------------------------------------ pixel canvas
-- A terminal cell is 6x9 game pixels.  AURORA addresses each cell as 2x3
-- sub-pixels (square 3x3 px units).  Character bytes 0x80-0x9F are sextant
-- glyphs; using fg/bg inversion covers all 64 patterns.  This gives genuine
-- pixel graphics without an extra renderer mod.

CanvasProto = {}
CanvasProto.__index = CanvasProto

function CanvasProto.new(w, h)
  local cv = setmetatable({}, CanvasProto)
  cv.w, cv.h = w, h
  cv.gen = 0
  cv.cells = w * h
  cv.ch, cv.fg, cv.bg = {}, {}, {}
  cv.pix = {}
  cv.pg = {}
  cv.lastT, cv.lastF, cv.lastB = {}, {}, {}
  cv.uc, cv.un = {}, {}
  return cv
end

function CanvasProto:begin()
  self.gen = self.gen + 1
  for y = 1, self.h do
    local row = (y - 1) * self.w
    for x = 1, self.w do
      local i = row + x
      self.ch[i] = " "
      self.fg[i] = Theme.C.text
      self.bg[i] = Theme.C.bg
      self.pg[i] = nil
    end
  end
end

function CanvasProto:idx(x, y)
  return (y - 1) * self.w + x
end

function CanvasProto:set(x, y, ch, fg, bg)
  if x < 1 or y < 1 or x > self.w or y > self.h then return end
  local i = (y - 1) * self.w + x
  self.ch[i] = ch or " "
  self.fg[i] = fg or Theme.C.text
  self.bg[i] = bg or self.bg[i] or Theme.C.bg
  self.pg[i] = nil
end

function CanvasProto:fill(x, y, w, h, color)
  w, h = math.floor(w), math.floor(h)
  if w <= 0 or h <= 0 then return end
  local x1, y1 = math.max(1, x), math.max(1, y)
  local x2, y2 = math.min(self.w, x + w - 1), math.min(self.h, y + h - 1)
  for yy = y1, y2 do
    local row = (yy - 1) * self.w
    for xx = x1, x2 do
      local i = row + xx
      self.ch[i] = " "
      self.bg[i] = color
      self.fg[i] = Theme.C.text
      self.pg[i] = nil
    end
  end
end

function CanvasProto:text(x, y, s, fg, bg)
  s = Util.clean(s)
  if y < 1 or y > self.h then return end
  for k = 1, #s do
    local xx = x + k - 1
    if xx >= 1 and xx <= self.w then
      local i = (y - 1) * self.w + xx
      self.ch[i] = s:sub(k, k)
      self.fg[i] = fg or Theme.C.text
      if bg then self.bg[i] = bg end
      self.pg[i] = nil
    end
  end
end

function CanvasProto:textFit(x, y, w, s, fg, bg)
  if w <= 0 then return end
  self:text(x, y, Util.fit(s, w), fg, bg)
end

function CanvasProto:textCenter(x, y, w, s, fg, bg)
  s = Util.clean(s)
  if #s > w then s = Util.fit(s, w) end
  self:text(x + math.floor((w - #s) / 2), y, s, fg, bg)
end

function CanvasProto:textBlock(x, y, w, s, fg, bg, maxLines)
  local lines = Util.wrap(s, math.max(1, w))
  for i = 1, math.min(#lines, maxLines or #lines) do
    self:text(x, y + i - 1, lines[i], fg, bg)
  end
  return math.min(#lines, maxLines or #lines)
end

function CanvasProto:textRight(x, y, w, s, fg, bg)
  s = Util.clean(s)
  if #s > w then s = Util.fit(s, w) end
  self:text(x + w - #s, y, s, fg, bg)
end

function CanvasProto:ensurePix(x, y)
  local i = (y - 1) * self.w + x
  if self.pg[i] ~= self.gen then
    local base = i * 6
    local bg = self.bg[i] or Theme.C.bg
    self.pg[i] = self.gen
    self.pix[base] = bg
    self.pix[base + 1] = bg
    self.pix[base + 2] = bg
    self.pix[base + 3] = bg
    self.pix[base + 4] = bg
    self.pix[base + 5] = bg
  end
  return i * 6
end

-- px, py are zero-based sub-pixel addresses.
function CanvasProto:pset(px, py, color)
  if px < 0 or py < 0 then return end
  local x = math.floor(px / 2) + 1
  local y = math.floor(py / 3) + 1
  if x > self.w or y > self.h then return end
  local base = self:ensurePix(x, y)
  self.pix[base + (py % 3) * 2 + (px % 2)] = color
end

function CanvasProto:pget(px, py)
  local x = math.floor(px / 2) + 1
  local y = math.floor(py / 3) + 1
  if x < 1 or y < 1 or x > self.w or y > self.h then return nil end
  local base = self:ensurePix(x, y)
  return self.pix[base + (py % 3) * 2 + (px % 2)]
end

function CanvasProto:pfill(px, py, pw, ph, color)
  for yy = py, py + ph - 1 do
    for xx = px, px + pw - 1 do
      self:pset(xx, yy, color)
    end
  end
end

function CanvasProto:pcircle(cx, cy, r, color)
  local x1, x2 = math.floor(cx - r), math.ceil(cx + r)
  local y1, y2 = math.floor(cy - r), math.ceil(cy + r)
  local r2 = r * r
  for yy = y1, y2 do
    for xx = x1, x2 do
      local dx, dy = xx - cx, yy - cy
      if dx * dx + dy * dy <= r2 then self:pset(xx, yy, color) end
    end
  end
end

function CanvasProto:pdisc(cx, cy, rx, ry, color)
  local x1, x2 = math.floor(cx - rx), math.ceil(cx + rx)
  local y1, y2 = math.floor(cy - ry), math.ceil(cy + ry)
  for yy = y1, y2 do
    for xx = x1, x2 do
      local dx, dy = (xx - cx) / rx, (yy - cy) / ry
      if dx * dx + dy * dy <= 1 then self:pset(xx, yy, color) end
    end
  end
end

-- Rounded rectangle in cell coordinates.  radius is in cells; corners are
-- carved in the sub-pixel layer so they genuinely curve.
function CanvasProto:roundRect(x, y, w, h, radius, color, outside)
  w, h = math.floor(w), math.floor(h)
  if w <= 0 or h <= 0 then return end
  outside = outside or Theme.C.bg
  self:fill(x, y, w, h, color)
  radius = math.min(radius or 1, math.min(w, h) / 2)
  if radius <= 0 then return end
  local rx, ry = radius * 2, radius * 3
  for yy = 0, h - 1 do
    for xx = 0, w - 1 do
      local ccx, ccy
      if xx < radius then ccx = radius * 2 - 0.5
      elseif xx >= w - radius then ccx = (w - radius) * 2 - 0.5 end
      if yy < radius then ccy = radius * 3 - 0.5
      elseif yy >= h - radius then ccy = (h - radius) * 3 - 0.5 end
      if ccx and ccy then
        local gx, gy = x + xx, y + yy
        if gx >= 1 and gx <= self.w and gy >= 1 and gy <= self.h then
          for sy = 0, 2 do
            for sx = 0, 1 do
              local px = xx * 2 + sx + 0.5
              local py = yy * 3 + sy + 0.5
              local dx, dy = (px - ccx) / rx, (py - ccy) / ry
              if dx * dx + dy * dy > 1 then
                local base = self:ensurePix(gx, gy)
                self.pix[base + sy * 2 + sx] = outside
              end
            end
          end
        end
      end
    end
  end
end

function CanvasProto:pill(x, y, w, h, color, outside)
  self:roundRect(x, y, w, h, h / 2, color, outside)
end

function CanvasProto:hline(x, y, w, color)
  self:fill(x, y, w, 1, color)
end

function CanvasProto:vline(x, y, h, color)
  self:fill(x, y, 1, h, color)
end

function CanvasProto:art(art, x, y)
  if not art or not art.data then return end
  local aw, ah = art.w, art.h
  x, y = math.floor(x), math.floor(y)
  for cy = 0, ah - 1 do
    for cx = 0, aw - 1 do
      local gx, gy = x + cx, y + cy
      if gx >= 1 and gx <= self.w and gy >= 1 and gy <= self.h then
        local p = (cy * aw + cx) * 3 + 1
        local fg = art.data:byte(p)
        local bg = art.data:byte(p + 1)
        local mask = art.data:byte(p + 2)
        local i = (gy - 1) * self.w + gx
        self.ch[i] = " "
        self.fg[i] = fg
        self.bg[i] = bg
        if mask == 0 then
          self.pg[i] = nil
        elseif mask == 63 then
          self.bg[i] = fg
          self.pg[i] = nil
        else
          local base = self:ensurePix(gx, gy)
          for k = 0, 5 do
            if mask % (2 ^ (k + 1)) >= 2 ^ k then
              self.pix[base + k] = fg
            else
              self.pix[base + k] = bg
            end
          end
        end
      end
    end
  end
end

function CanvasProto:icon(name, x, y, w, h, color, scale)
  Icons.draw(self, name, x, y, w, h, color, scale)
end

-- Quantise a cell's six sub-pixels to two colours + a sextant mask bitfield.
function CanvasProto:quantizeCell(i)
  local base = i * 6
  local pix = self.pix
  local uc, un = self.uc, self.un
  local n = 0
  for k = 0, 5 do
    local c = pix[base + k]
    local found = false
    for j = 1, n do
      if uc[j] == c then un[j] = un[j] + 1; found = true; break end
    end
    if not found then
      n = n + 1
      uc[n] = c
      un[n] = 1
    end
  end
  if n == 1 then
    return " ", uc[1], uc[1], true
  end
  local br = pix[base + 5]
  local fg, best = nil, -1
  for j = 1, n do
    if uc[j] ~= br and un[j] > best then best = un[j]; fg = uc[j] end
  end
  if not fg then return " ", br, br, true end
  local bg = br
  local mask = 0
  for k = 0, 4 do
    local c = pix[base + k]
    if c == bg then
      -- background: leave bit clear
    elseif c == fg then
      mask = mask + 2 ^ k
    else
      -- Third/fourth colour in one cell: nearest match.
      local cr, cg, cb = Util.rgbParts(Theme.col(c))
      local fr, fgr, fb = Util.rgbParts(Theme.col(fg))
      local brr, brg, brb = Util.rgbParts(Theme.col(bg))
      local df = math.abs(cr - fr) + math.abs(cg - fgr) + math.abs(cb - fb)
      local db = math.abs(cr - brr) + math.abs(cg - brg) + math.abs(cb - brb)
      if df < db then mask = mask + 2 ^ k end
    end
  end
  if mask == 0 then
    return " ", bg, bg, true
  end
  return string.char(128 + mask), fg, bg, false
end

local colorChars = { "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f" }

function CanvasProto:present(termObj, force)
  if not termObj then return false, "no terminal" end
  local w, h = self.w, self.h
  local map = Theme.map
  local useBlit = type(termObj.blit) == "function"
  if useBlit then
    if force or not self.cleared then
      pcall(function() termObj.setBackgroundColor(Theme.colorConstant(Theme.C.bg)); termObj.clear() end)
      self.lastT, self.lastF, self.lastB = {}, {}, {}
      self.cleared = true
    end
    for y = 1, h do
      local t, f, b = {}, {}, {}
      local row = (y - 1) * w
      for x = 1, w do
        local i = row + x
        local ch, fg, bg
        if self.pg[i] == self.gen then
          ch, fg, bg = self:quantizeCell(i)
        else
          ch = self.ch[i] or " "
          fg = self.fg[i] or Theme.C.text
          bg = self.bg[i] or Theme.C.bg
        end
        t[x] = ch
        f[x] = colorChars[(map[fg] or fg) + 1]
        b[x] = colorChars[(map[bg] or bg) + 1]
      end
      local ts = table.concat(t)
      local fs = table.concat(f)
      local bs = table.concat(b)
      if force or ts ~= self.lastT[y] or fs ~= self.lastF[y] or bs ~= self.lastB[y] then
        local ok = pcall(function()
          termObj.setCursorPos(1, y)
          termObj.blit(ts, fs, bs)
        end)
        if not ok then return false, "blit failed" end
        self.lastT[y], self.lastF[y], self.lastB[y] = ts, fs, bs
      end
    end
  else
    -- Very old terminal fallback: one cell at a time.  Still correct, just slow.
    pcall(function() termObj.setBackgroundColor(Theme.colorConstant(Theme.C.bg)); termObj.clear() end)
    for y = 1, h do
      for x = 1, w do
        local i = (y - 1) * w + x
        local ch, fg, bg
        if self.pg[i] == self.gen then
          ch, fg, bg = self:quantizeCell(i)
        else
          ch = self.ch[i] or " "
          fg = self.fg[i] or Theme.C.text
          bg = self.bg[i] or Theme.C.bg
        end
        pcall(function()
          termObj.setCursorPos(x, y)
          termObj.setTextColor(Theme.colorConstant(fg))
          termObj.setBackgroundColor(Theme.colorConstant(bg))
          termObj.write(ch)
        end)
      end
    end
  end
  return true
end

function CanvasProto:invalidate()
  self.lastT, self.lastF, self.lastB = {}, {}, {}
  self.cleared = false
end

------------------------------------------------------------------ pixel icons
Icons.bitmaps = {
  -- 9x9 transport
  play = {
    ".........", "..##.....", "..###....", "..####...", "..#####..",
    "..####...", "..###....", "..##.....", ".........",
  },
  pause = {
    ".........", "..##.##..", "..##.##..", "..##.##..", "..##.##..",
    "..##.##..", "..##.##..", "..##.##..", ".........",
  },
  prev = {
    ".........", ".##....#.", ".##...##.", ".##..###.", ".##.####.",
    ".##..###.", ".##...##.", ".##....#.", ".........",
  },
  next = {
    ".........", ".#....##.", ".##...##.", ".###..##.", ".####.##.",
    ".###..##.", ".##...##.", ".#....##.", ".........",
  },
  shuffle = {
    ".........", ".#....##.", "##...###.", ".##.##...", "..###....",
    ".##.##...", "###...##.", "##.....#.", ".........",
  },
  ["repeat"] = {
    ".........", "..#####..", ".#.....#.", "#.......#", "#.......#",
    "#.......#", ".#.....#.", "..####.#.", "......#..",
  },
  repeat1 = {
    ".........", "..#####..", ".#..#..#.", "#...#...#", "#...#...#",
    "#...#...#", ".#..#..#.", "..####.#.", "......#..",
  },
  heart9 = {
    ".##...##.", "####.####", "#########", "#########", ".#######.",
    "..#####..", "...###...", "....#....", ".........",
  },
  heartOutline9 = {
    ".##...##.", "#..#.#..#", "#...#...#", "#.......#", ".#.....#.",
    "..#...#..", "...#.#...", "....#....", ".........",
  },
  volume9 = {
    ".........", "..#......", ".##..#...", "###.#.#..", "###.#.#..",
    ".##..#...", "..#......", ".........", ".........",
  },
  volumeMute9 = {
    ".........", "..#...##.", ".##..#...", "###.#.#..", "###..#...",
    ".##..#...", "..#...##.", ".........", ".........",
  },
  queue9 = {
    ".........", ".#####...", "......#..", ".#####.#.", "......#..",
    ".#####...", ".........", ".........", ".........",
  },
  lyrics9 = {
    ".........", "..###....", "..#.#....", "..#.#....", "..#.#....",
    ".##.##...", ".##.##...", ".........", ".........",
  },
  search9 = {
    ".........", "..####...", ".#....#..", "#......#.", "#......#.",
    "#......#.", ".#....#..", "..####.#.", ".......##",
  },
  music9 = {
    ".........", "...####..", "...#....#", "...#....#", "...#....#",
    "..##...##", "..##...##", ".........", ".........",
  },
  disc9 = {
    "..#####..", ".#.....#.", "#..###..#", "#.#...#.#", "#.#...#.#",
    "#..###..#", ".#.....#.", "..#####..", ".........",
  },

  -- 7x7 small UI
  home = { "...#...", "..###..", ".#####.", "#######", ".#####.", ".#...#.", ".#...#." },
  library = { "##..##.", "##..##.", ".......", "##..##.", "##..##.", ".......", "......." },
  playlist = { "#####..", "....#..", "#####..", "....#..", "#####..", ".......", "......." },
  search = { ".####..", "#....#.", "#....#.", "#....#.", ".####.#", "......#", "......." },
  settings = { "..###..", ".#.#.#.", "###.###", ".#...#.", "###.###", ".#.#.#.", "..###.." },
  back = { "...#...", "..##...", ".###...", "####...", ".###...", "..##...", "...#..." },
  plus = { "...#...", "...#...", "...#...", "#######", "...#...", "...#...", "...#..." },
  check = { "......#", ".....##", "#...##.", "##.##..", ".###...", "..#....", "......." },
  trash = { ".#####.", "..#.#..", "#######", "#######", "#######", "#######", "......." },
  edit = { "....##.", "...##..", "..##...", ".##....", "##.....", ".......", "......." },
  lock = { "..###..", ".#...#.", ".#####.", ".#...#.", ".#...#.", ".#####.", "......." },
  unlock = { "..###..", ".#...#.", ".#####.", ".#.....", ".#.....", ".#.....", "......." },
  grid = { "##.##..", "##.##..", ".......", "##.##..", "##.##..", ".......", "......." },
  list = { "#####..", ".......", "#####..", ".......", "#####..", ".......", "......." },
  more = { ".......", ".......", ".#.#.#.", ".......", ".......", ".......", "......." },
  up = { "...#...", "..###..", ".#####.", ".......", ".......", ".......", "......." },
  down = { ".......", ".......", ".......", ".#####.", "..###..", "...#...", "......." },
  star = { "...#...", "..###..", "#######", ".#####.", "..###..", ".##.##.", "......." },
  info = { "..###..", ".#...#.", "#..#..#", "#..#..#", "#..#..#", ".#...#.", "..###.." },
  speaker = { "..#....", ".##..#.", "###.#.#", "###.#.#", ".##..#.", "..#....", "......." },
  folder = { "###....", "#..####", "#.....#", "#.....#", "#.....#", "#.....#", "#######" },
  file = { ".#####.", ".#...#.", ".#...#.", ".#...#.", ".#...#.", ".#####.", "......." },
  clock = { "..###..", ".#...#.", "#..#..#", "#..##.#", "#.....#", ".#...#.", "..###.." },
  close = { "#.....#", "##...##", ".#####.", "..###..", ".#####.", "##...##", "#.....#" },
  closeSmall = { "#...#", ".#.#.", "..#..", ".#.#.", "#...#" },
  refresh = { "..####.", ".#....#", "#......", "#...###", "#.....#", ".#...#.", "..###.." },
  user = { "..###..", "..###..", ".......", ".#####.", "#######", "#######", "......." },
  palette = { "..###..", ".#.#.#.", "#..#..#", "#.....#", "#..#..#", ".#.#.#.", "..###.." },
  disc = { "..###..", ".#...#.", "#..#..#", "#.###.#", "#..#..#", ".#...#.", "..###.." },
  heart = { ".##.##.", "#######", "#######", ".#####.", "..###..", "...#...", "......." },
  heartOutline = { ".##.##.", "#..#..#", "#...#.#", ".#...#.", "..#.#..", "...#...", "......." },
  music = { "..###..", "..#....", "..#....", "..#....", ".##.##.", ".##.##.", "......." },
  playSmall = { "..##...", "..###..", "..####.", "..#####", "..####.", "..###..", "..##..." },
  pauseSmall = { ".##.##.", ".##.##.", ".##.##.", ".##.##.", ".##.##.", ".##.##.", "......." },
  nextSmall = { "..#..#.", "..##.##", "..#####", "..#####", "..#####", "..##.##", "..#..#." },
  prevSmall = { ".#..#..", "##.##..", "#####..", "#####..", "#####..", "##.##..", ".#..#.." },
  badge = { ".#####.", "#.....#", "#..#..#", "#.....#", "#..#..#", "#.....#", ".#####." },
  waveform = { ".......", ".#...#.", ".#.#.#.", "###.#.#", "###.#.#", "...###.", "......." },
  -- 5x5 compact icons for small monitors
  home5 = { "..#..", ".###.", "#####", "#.#.#", "#.#.#" },
  library5 = { "##.##", "##.##", ".....", "##.##", "##.##" },
  search5 = { ".###.", "#...#", "#...#", ".###.", "....#" },
  playlist5 = { "####.", "...#.", "####.", "...#.", "####." },
  settings5 = { ".###.", "#.#.#", "##.##", "#.#.#", ".###." },
  back5 = { "..#..", ".##..", "###..", ".##..", "..#.." },
  close5 = { "#...#", ".#.#.", "..#..", ".#.#.", "#...#" },
  play5 = { "..#..", ".##..", ".###.", ".##..", "..#.." },
  pause5 = { "##.##", "##.##", "##.##", "##.##", "##.##" },
  next5 = { "..#.#", "..###", "..###", "..#.#", "....." },
  prev5 = { "#.#..", "###..", "###..", "#.#..", "....." },
  more5 = { ".....", ".....", "#.#.#", ".....", "....." },
  shuffle7 = { ".#...#.", "##..##.", ".###...", "..##...", ".###...", "##..##.", ".#...#." },
  shuffle5 = { "#...#", "##.##", ".###.", "..#..", ".###." },
  repeat5 = { ".###.", "#...#", "#...#", "#...#", ".###." },
  play3 = { "##.", "###", "##." },
  pause3 = { "#.#", "#.#", "#.#" },
  shuffle3 = { "#.#", ".#.", "#.#" },
  more3 = { "...", "###", "..." },
  music5 = { ".###.", "..#..", "..#..", ".#.#.", "#...#" },
  lyrics5 = { "..#..", ".###.", "..#..", "..###", "....." },
  video = { "#######", "#.....#", "#...#.#", "#..###.", "#...#.#", "#.....#", "#######" },
  video5 = { "#####", "#...#", "#.#.#", "#...#", "#####" },
  gallery = { "..###..", ".#...#.", "#..#..#", "#.....#", ".#...#.", "..###..", "......." },
  gallery5 = { ".###.", "#...#", "#.#.#", "#...#", ".###." },
  notes = { ".#####.", ".#...#.", ".#.#.#.", ".#...#.", ".#.#.#.", ".#####.", "......." },
  notes5 = { ".####", ".#..#", ".#..#", ".#..#", ".####" },
  minimize = { ".......", ".......", ".......", ".......", ".......", "#######", "......." },
  minimize5 = { ".....", ".....", ".....", "#####", "....." },
  up5 = { "..#..", ".###.", "#####", ".....", "....." },
  down5 = { ".....", ".....", "#####", ".###.", "..#.." },
}

function Icons.draw(cv, name, x, y, w, h, color, scale)
  local bm = Icons.bitmaps[name]
  if not bm then return false end
  scale = scale or 1
  local iw, ih = #bm[1], #bm
  local cx = (x - 1) * 2 + w
  local cy = (y - 1) * 3 + h * 1.5
  local ox = math.floor(cx - iw * scale / 2 + 0.5)
  local oy = math.floor(cy - ih * scale / 2 + 0.5)
  for yy = 1, ih do
    local line = bm[yy]
    for xx = 1, iw do
      if line:sub(xx, xx) == "#" then
        cv:pfill(ox + (xx - 1) * scale, oy + (yy - 1) * scale, scale, scale, color)
      end
    end
  end
  return true
end

function Icons.size(name)
  local bm = Icons.bitmaps[name]
  if not bm then return 0, 0 end
  return #bm[1], #bm
end

--======== 50_data.lua ========
------------------------------------------------------------------ music library
Data = {}
Data.tracks = {}
Data.albums = {}
Data.artists = {}
Data.byPath = {}
Data.byAlbum = {}
Data.byArtist = {}
Data.stats = { tracks = 0, albums = 0, artists = 0, duration = 0, missing = 0 }
Data.playlists = {}
Data.favSet = {}
Data.recentPaths = {}
Data.meta = { tracks = {}, albums = {} }
Data.cache = { version = 2, entries = {} }
Data.cacheDirty = false
Data.lastScan = 0

local SAMPLE_RATE = 48000
local DFPWM_BYTES_PER_SECOND = SAMPLE_RATE / 8

function Data.isAudio(name)
  return tostring(name):lower():match("%.dfpwm$") ~= nil
end

function Data.durationForSize(size)
  return (tonumber(size) or 0) / DFPWM_BYTES_PER_SECOND
end

function Data.fileAttrs(path)
  local ok, attr = pcall(fs.attributes, path)
  if ok and type(attr) == "table" then
    return tonumber(attr.mtime or attr.modified or attr.size) or nil, tonumber(attr.size) or nil
  end
  local ok2, size = pcall(fs.getSize, path)
  return nil, ok2 and size or nil
end

local function sortTracks(a, b)
  local at, bt = a.trackNo, b.trackNo
  if at and bt and at ~= bt then return at < bt end
  if at and not bt then return true end
  if bt and not at then return false end
  if a.key ~= b.key then return a.key < b.key end
  return a.path < b.path
end

local function parseFilename(file, path)
  local base = file:gsub("%.[Dd][Ff][Pp][Ww][Mm]$", "")
  base = Util.trim(base:gsub("_", " "))
  base = base:gsub("%s+", " ")
  local num, rest = base:match("^(%d+)%s*[%-%.%)]%s*(.+)$")
  if not num then num, rest = base:match("^(%d+)%s+(.+)$") end
  if num and rest and rest ~= "" then
    base = rest
  else
    num = nil
  end
  local artist, title = base:match("^(.-)%s+%-%s+(.+)$")
  if not title or artist == "" then
    artist, title = nil, base
  end
  title = Util.trim(title or "")
  artist = Util.trim(artist or "")
  if title == "" then title = file:gsub("%.dfpwm$", "") end
  return {
    title = Util.clean(title),
    fileArtist = artist ~= "" and Util.clean(artist) or nil,
    trackNo = num and tonumber(num) or nil,
  }
end

local function dirContainsAudio(dir, depth)
  if depth > 4 then return false end
  local ok, entries = pcall(fs.list, dir)
  if not ok or not entries then return false end
  for _, entry in ipairs(entries) do
    local p = fs.combine(dir, entry)
    if fs.isDir(p) then
      if dirContainsAudio(p, depth + 1) then return true end
    elseif Data.isAudio(entry) then
      return true
    end
  end
  return false
end

-- True only when a *child directory* contains audio.  A directory full of
-- files is an album, not an artist folder.
local function dirHasAudioChild(dir)
  local ok, entries = pcall(fs.list, dir)
  if not ok or not entries then return false end
  for _, entry in ipairs(entries) do
    local p = fs.combine(dir, entry)
    if fs.isDir(p) and dirContainsAudio(p, 0) then return true end
  end
  return false
end

local function albumKeyFor(folder, singles)
  return folder .. (singles and "\1s" or "")
end

local function applyTrackMeta(track)
  local m = Data.meta.tracks[track.path]
  if type(m) == "table" then
    if type(m.title) == "string" and m.title ~= "" then track.title = Util.clean(m.title) end
    if type(m.artist) == "string" and m.artist ~= "" then track.artist = Util.clean(m.artist) end
    if type(m.album) == "string" and m.album ~= "" then track.albumOverride = Util.clean(m.album) end
    if type(m.trackNo) == "number" then track.trackNo = math.floor(m.trackNo) end
    if type(m.art) == "string" and m.art ~= "" then track.artPath = m.art end
    if type(m.lyrics) == "string" and m.lyrics ~= "" then track.lyricsPath = m.lyrics end
  end
  track.album = track.albumOverride or track.albumName
  track.key = Util.naturalKey(track.title)
  track.searchKey = Util.fold(track.title .. " " .. track.artist .. " " .. track.album .. " " .. track.folder)
end

local function addTrackToAlbum(album, track)
  album.tracks[#album.tracks + 1] = track
  track.albumRef = album
end

function Data.scan()
  local started = Util.now()
  local oldQueuePaths = Data.lastQueuePaths
  Data.tracks, Data.albums, Data.artists = {}, {}, {}
  Data.byPath, Data.byAlbum, Data.byArtist = {}, {}, {}
  Data.stats = { tracks = 0, albums = 0, artists = 0, duration = 0, missing = 0 }

  local albumMap, seen = {}, {}
  local newCache = { version = 2, entries = {} }
  local oldCache = Data.cache and Data.cache.entries or {}

  local function addFile(path, file, albumName, folder, folderArtist, singles)
    if seen[path] then return end
    local mtime, size = Data.fileAttrs(path)
    if not size or size <= 0 then return end
    seen[path] = true
    local cache = oldCache[path]
    local parsed
    if cache and cache.size == size and (not mtime or not cache.mtime or cache.mtime == mtime) then
      parsed = { title = cache.title, fileArtist = cache.artist, trackNo = cache.trackNo }
    else
      parsed = parseFilename(file, path)
    end
    local artist = Util.clean(parsed.fileArtist or folderArtist or "Unknown Artist")
    if artist == "" then artist = "Unknown Artist" end
    local track = {
      path = path,
      file = file,
      folder = folder,
      size = size,
      mtime = mtime,
      albumName = albumName,
      artist = artist,
      trackNo = parsed.trackNo,
      title = Util.clean(parsed.title or file),
      dur = Data.durationForSize(size),
    }
    applyTrackMeta(track)

    local key = albumKeyFor(folder, singles)
    local album = albumMap[key]
    if not album then
      local am = Data.meta.albums[key]
      local aName = (type(am) == "table" and type(am.name) == "string" and am.name ~= "") and Util.clean(am.name) or albumName
      local aArtist = (type(am) == "table" and type(am.artist) == "string" and am.artist ~= "") and Util.clean(am.artist) or nil
      album = {
        key = key,
        name = aName,
        folder = folder,
        isSingles = singles or false,
        folderArtist = folderArtist,
        artistOverride = aArtist,
        artPath = (type(am) == "table" and type(am.art) == "string" and am.art ~= "") and am.art or nil,
        tracks = {},
        dur = 0,
      }
      albumMap[key] = album
      Data.albums[#Data.albums + 1] = album
      Data.byAlbum[key] = album
    end
    addTrackToAlbum(album, track)
    track.albumKey = key
    Data.tracks[#Data.tracks + 1] = track
    Data.byPath[path] = track

    newCache.entries[path] = {
      size = size, mtime = mtime, title = track.title,
      artist = track.artist, trackNo = track.trackNo,
    }
  end

  local function scanDir(dir, root, depth)
    if depth > 8 then return end
    if fs.getName(dir) == ".aurora" then return end
    local ok, entries = pcall(fs.list, dir)
    if not ok or not entries then return end
    local files, dirs = {}, {}
    for _, entry in ipairs(entries) do
      local p = fs.combine(dir, entry)
      if fs.isDir(p) then
        dirs[#dirs + 1] = entry
      elseif Data.isAudio(entry) then
        files[#files + 1] = entry
      end
    end
    table.sort(files, function(a, b) return Util.naturalKey(a) < Util.naturalKey(b) end)
    table.sort(dirs, function(a, b) return Util.naturalKey(a) < Util.naturalKey(b) end)

    if #files > 0 then
      local albumName, folderArtist, singles
      if dir == root then
        albumName, folderArtist, singles = "Singles", nil, true
      else
        local hasAudioChild = dirHasAudioChild(dir)
        local parent = fs.getDir(dir)
        local parentName = fs.getName(parent)
        if hasAudioChild then
          -- Loose tracks in an artist folder.
          albumName, folderArtist, singles = "Singles", fs.getName(dir), true
        else
          albumName = fs.getName(dir)
          singles = false
          if parent ~= root and parent ~= "" and parent ~= "/" and parent ~= "."
            and parentName ~= "music" and parentName ~= root then
            folderArtist = parentName
          end
        end
      end
      for _, file in ipairs(files) do
        addFile(fs.combine(dir, file), file, albumName, dir, folderArtist, singles)
      end
    end

    for _, sub in ipairs(dirs) do
      scanDir(fs.combine(dir, sub), root, depth + 1)
    end
  end

  for _, root in ipairs(App.cfg.roots) do
    if fs.exists(root) and fs.isDir(root) then
      local ok = pcall(scanDir, root, root, 0)
      if not ok then Store.log("scan root failed: " .. tostring(root)) end
    end
  end

  -- Album finalisation.
  local kept = {}
  for _, album in ipairs(Data.albums) do
    if #album.tracks > 0 then
      table.sort(album.tracks, sortTracks)
      album.dur = 0
      local names, count, only = {}, 0, nil
      for _, t in ipairs(album.tracks) do
        album.dur = album.dur + t.dur
        if not names[t.artist] then
          names[t.artist] = true
          count = count + 1
          only = t.artist
        end
      end
      album.trackCount = #album.tracks
      album.artist = album.artistOverride or (count <= 1 and (only or "Unknown Artist") or "Various Artists")
      album.keySort = Util.naturalKey(album.name)
      for _, t in ipairs(album.tracks) do
        if not t.albumOverride then t.album = album.name end
        t.searchKey = Util.fold(t.title .. " " .. t.artist .. " " .. t.album .. " " .. t.folder)
      end
      kept[#kept + 1] = album
    end
  end
  Data.albums = kept
  table.sort(Data.albums, function(a, b)
    if a.keySort ~= b.keySort then return a.keySort < b.keySort end
    if a.artist ~= b.artist then return Util.naturalKey(a.artist) < Util.naturalKey(b.artist) end
    return a.folder < b.folder
  end)

  table.sort(Data.tracks, function(a, b)
    local aa, ba = Util.naturalKey(a.album), Util.naturalKey(b.album)
    if aa ~= ba then return aa < ba end
    if a.artist ~= b.artist then
      local x, y = Util.naturalKey(a.artist), Util.naturalKey(b.artist)
      if x ~= y then return x < y end
    end
    return sortTracks(a, b)
  end)

  -- Artist groups.
  for _, album in ipairs(Data.albums) do
    local name = album.artist
    local ag = Data.byArtist[name]
    if not ag then
      ag = { name = name, albums = {}, tracks = 0, dur = 0, key = Util.naturalKey(name) }
      Data.byArtist[name] = ag
      Data.artists[#Data.artists + 1] = ag
    end
    ag.albums[#ag.albums + 1] = album
    ag.tracks = ag.tracks + #album.tracks
    ag.dur = ag.dur + album.dur
  end
  table.sort(Data.artists, function(a, b)
    if a.key ~= b.key then return a.key < b.key end
    return a.name < b.name
  end)
  for _, ag in ipairs(Data.artists) do
    table.sort(ag.albums, function(a, b) return a.keySort < b.keySort end)
  end

  Data.stats.tracks = #Data.tracks
  Data.stats.albums = #Data.albums
  Data.stats.artists = #Data.artists
  Data.stats.duration = 0
  for _, t in ipairs(Data.tracks) do Data.stats.duration = Data.stats.duration + t.dur end
  Data.cache = newCache
  Data.cacheDirty = true
  Data.lastScan = Util.now() - started
  if oldQueuePaths then Data.lastQueuePaths = oldQueuePaths end
  Data.saveCacheSoon()
  return Data.stats
end

function Data.saveCacheSoon()
  if not Data.cacheDirty then return end
  Store.saveSoon("library", Data.cache)
  Data.cacheDirty = false
end

function Data.saveCacheNow()
  if Data.cache then Store.save("library", Data.cache) end
  Data.cacheDirty = false
end

function Data.rescan()
  local ok, stats = pcall(Data.scan)
  if not ok then
    Store.logError("scan", stats)
    return false
  end
  if App.rebuildAfterScan then pcall(App.rebuildAfterScan) end
  if UI and UI.request then UI.request(true) end
  return true, stats
end

------------------------------------------------------------------ metadata
function Data.loadMeta()
  local m = Store.load("meta", nil)
  if type(m) == "table" then
    Data.meta.tracks = type(m.tracks) == "table" and m.tracks or {}
    Data.meta.albums = type(m.albums) == "table" and m.albums or {}
  else
    Data.meta = { tracks = {}, albums = {} }
  end
  -- Validate / sanitise on load so corrupt metadata cannot break rendering.
  for path, t in pairs(Data.meta.tracks) do
    if type(path) ~= "string" or type(t) ~= "table" then
      Data.meta.tracks[path] = nil
    else
      for _, k in ipairs({ "title", "artist", "album", "art", "lyrics" }) do
        if t[k] ~= nil and type(t[k]) ~= "string" then t[k] = nil end
      end
      if t.trackNo ~= nil and type(t.trackNo) ~= "number" then t.trackNo = nil end
    end
  end
  for key, a in pairs(Data.meta.albums) do
    if type(key) ~= "string" or type(a) ~= "table" then
      Data.meta.albums[key] = nil
    else
      for _, k in ipairs({ "name", "artist", "art" }) do
        if a[k] ~= nil and type(a[k]) ~= "string" then a[k] = nil end
      end
    end
  end
end

function Data.saveMeta()
  Store.save("meta", Data.meta)
end

function Data.setTrackMeta(path, fields)
  if type(path) ~= "string" then return end
  local t = Data.meta.tracks[path]
  if not t then t = {}; Data.meta.tracks[path] = t end
  for k, v in pairs(fields or {}) do
    if v == "" or v == nil then t[k] = nil else t[k] = v end
  end
  if next(t) == nil then Data.meta.tracks[path] = nil end
  Data.saveMeta()
end

function Data.clearTrackMeta(path)
  Data.meta.tracks[path] = nil
  Data.saveMeta()
end

function Data.setAlbumMeta(key, fields)
  if type(key) ~= "string" then return end
  local a = Data.meta.albums[key]
  if not a then a = {}; Data.meta.albums[key] = a end
  for k, v in pairs(fields or {}) do
    if v == "" or v == nil then a[k] = nil else a[k] = v end
  end
  if next(a) == nil then Data.meta.albums[key] = nil end
  Data.saveMeta()
end

function Data.clearAlbumMeta(key)
  Data.meta.albums[key] = nil
  Data.saveMeta()
end

------------------------------------------------------------------ user data
local function readLegacy(name)
  if not fs.exists(name) then return nil end
  local ok, f = pcall(fs.open, name, "rb")
  if not ok or not f then return nil end
  local data = f.readAll()
  f.close()
  local ok2, t = pcall(textutils.unserialize, data or "")
  return ok2 and type(t) == "table" and t or nil
end

local function validPathList(t, max)
  local out, seen = {}, {}
  if type(t) ~= "table" then return out end
  for _, p in ipairs(t) do
    if type(p) == "string" and p ~= "" and #p < 512 and not seen[p] then
      seen[p] = true
      out[#out + 1] = p
      if max and #out >= max then break end
    end
  end
  return out
end

function Data.loadUserData()
  -- Playlists
  Data.playlists = {}
  local pd = Store.load("playlists", nil)
  if not pd then
    pd = readLegacy(".jukebox_playlists")
  end
  if type(pd) == "table" and type(pd.playlists) == "table" then
    for _, p in ipairs(pd.playlists) do
      if type(p) == "table" and type(p.name) == "string" and p.name ~= "" then
        local pl = { name = Util.clean(p.name), tracks = validPathList(p.tracks, 5000), created = p.created }
        Data.playlists[#Data.playlists + 1] = pl
      end
    end
  end

  -- Favorites
  Data.favSet = {}
  local fd = Store.load("favorites", nil) or readLegacy(".jukebox_favorites")
  if type(fd) == "table" then
    for _, p in ipairs(validPathList(fd.paths, 5000)) do Data.favSet[p] = true end
  end

  -- Recent
  Data.recentPaths = {}
  local rd = Store.load("recent", nil) or readLegacy(".jukebox_recent")
  if type(rd) == "table" then
    Data.recentPaths = validPathList(rd.paths, 100)
  end
  Data.legacySession = Store.load("session", nil) or readLegacy(".jukebox_session")
end

function Data.savePlaylists()
  local out = {}
  for _, pl in ipairs(Data.playlists) do
    out[#out + 1] = { name = pl.name, tracks = pl.tracks, created = pl.created }
  end
  Store.save("playlists", { version = 1, playlists = out })
end

function Data.saveFavorites()
  local paths = {}
  for path in pairs(Data.favSet) do paths[#paths + 1] = path end
  table.sort(paths)
  Store.save("favorites", { version = 1, paths = paths })
end

function Data.saveRecent()
  Store.save("recent", { version = 1, paths = Data.recentPaths })
end

function Data.saveAllUser()
  Data.savePlaylists()
  Data.saveFavorites()
  Data.saveRecent()
  Data.saveMeta()
  Data.saveCacheNow()
  if App.saveSession then App.saveSession() end
end

function Data.uniquePlaylistName(name)
  name = Util.trim(Util.clean(name))
  if name == "" then name = "New Playlist" end
  if #name > 40 then name = name:sub(1, 40) end
  local used = {}
  for _, pl in ipairs(Data.playlists) do used[pl.name] = true end
  if not used[name] then return name end
  local base, n = name, 2
  while used[base .. " " .. n] do n = n + 1 end
  return base .. " " .. n
end

function Data.createPlaylist(name)
  local pl = { name = Data.uniquePlaylistName(name), tracks = {}, created = os.time and os.time() or 0 }
  Data.playlists[#Data.playlists + 1] = pl
  Data.savePlaylists()
  return pl
end

function Data.renamePlaylist(pl, name)
  if not pl then return false end
  name = Util.trim(Util.clean(name))
  if name == "" then return false end
  if #name > 40 then name = name:sub(1, 40) end
  local old = pl.name
  pl.name = old
  local newName = Data.uniquePlaylistName(name)
  pl.name = newName
  Data.savePlaylists()
  return true
end

function Data.deletePlaylist(pl)
  for i, p in ipairs(Data.playlists) do
    if p == pl then
      table.remove(Data.playlists, i)
      Data.savePlaylists()
      return true
    end
  end
  return false
end

function Data.addTrackToPlaylist(pl, track)
  if not pl or not track then return false end
  for _, p in ipairs(pl.tracks) do
    if p == track.path then return false end
  end
  pl.tracks[#pl.tracks + 1] = track.path
  Data.savePlaylists()
  return true
end

function Data.removeTrackFromPlaylist(pl, track)
  if not pl or not track then return false end
  for i, p in ipairs(pl.tracks) do
    if p == track.path then
      table.remove(pl.tracks, i)
      Data.savePlaylists()
      return true
    end
  end
  return false
end

function Data.movePlaylistTrack(pl, index, dir)
  if not pl then return false end
  local j = index + dir
  if index < 1 or index > #pl.tracks or j < 1 or j > #pl.tracks then return false end
  pl.tracks[index], pl.tracks[j] = pl.tracks[j], pl.tracks[index]
  Data.savePlaylists()
  return true
end

function Data.playlistTracks(pl)
  local out = {}
  if not pl then return out end
  for _, path in ipairs(pl.tracks) do
    local t = Data.byPath[path]
    if t then out[#out + 1] = t end
  end
  return out
end

function Data.playlistDuration(pl)
  local d = 0
  for _, t in ipairs(Data.playlistTracks(pl)) do d = d + t.dur end
  return d
end

function Data.isFavorite(track)
  return track and Data.favSet[track.path] == true or false
end

function Data.toggleFavorite(track)
  if not track then return false end
  if Data.favSet[track.path] then
    Data.favSet[track.path] = nil
    Data.saveFavorites()
    return false
  end
  Data.favSet[track.path] = true
  Data.saveFavorites()
  return true
end

function Data.addRecent(track)
  if not track then return end
  for i, p in ipairs(Data.recentPaths) do
    if p == track.path then
      table.remove(Data.recentPaths, i)
      break
    end
  end
  table.insert(Data.recentPaths, 1, track.path)
  while #Data.recentPaths > 100 do table.remove(Data.recentPaths) end
  Data.saveRecent()
end

function Data.favoriteTracks()
  local out = {}
  for _, t in ipairs(Data.tracks) do
    if Data.favSet[t.path] then out[#out + 1] = t end
  end
  return out
end

function Data.recentTracks()
  local out = {}
  for _, p in ipairs(Data.recentPaths) do
    local t = Data.byPath[p]
    if t then out[#out + 1] = t end
  end
  return out
end

------------------------------------------------------------------ search
function Data.search(query, limit)
  limit = limit or 200
  local tokens = Util.tokens(query)
  local result = { tracks = {}, albums = {}, artists = {}, tokens = tokens }
  if #tokens == 0 then return result end
  for _, t in ipairs(Data.tracks) do
    if Util.matchesAll(t.searchKey, tokens) then
      result.tracks[#result.tracks + 1] = t
      if #result.tracks >= limit then break end
    end
  end
  for _, a in ipairs(Data.albums) do
    local hay = Util.fold(a.name .. " " .. a.artist .. " " .. a.folder)
    if Util.matchesAll(hay, tokens) then
      result.albums[#result.albums + 1] = a
      if #result.albums >= 60 then break end
    end
  end
  for _, a in ipairs(Data.artists) do
    if Util.matchesAll(Util.fold(a.name), tokens) then
      result.artists[#result.artists + 1] = a
      if #result.artists >= 40 then break end
    end
  end
  return result
end

function Data.findAlbumByKey(key)
  return Data.byAlbum[key]
end

function Data.findArtist(name)
  for _, a in ipairs(Data.artists) do
    if a.name == name then return a end
  end
  return nil
end

------------------------------------------------------------------ library boot
function Data.loadAll()
  Data.loadMeta()
  local ok, err = pcall(function()
    local cached = Store.load("library", nil)
    if type(cached) == "table" and cached.version == 2 and type(cached.entries) == "table" then
      Data.cache = cached
    end
  end)
  if not ok then Data.cache = { version = 2, entries = {} } end
  Data.scan()
  Data.loadUserData()
end

------------------------------------------------------------------ playlist art helpers
function Data.playlistMosaic(pl)
  local tracks = Data.playlistTracks(pl)
  local out = {}
  for i = 1, math.min(4, #tracks) do out[i] = tracks[i] end
  return out
end

--======== 60_art.lua ========
------------------------------------------------------------------ artwork
-- Supported image formats are deliberately limited to formats that can be
-- decoded reliably in pure Lua on a CC computer:
--   * BMP  - uncompressed BI_RGB, 8/24/32 bpp, top-down or bottom-up
--   * PPM  - P6 (binary) and P3 (ASCII)
-- PNG/JPEG are not decodable without a large external library or HTTP+service.
-- Both supported formats are easy to export from any image editor.
--
-- Every image is centre-cropped square, sampled to a 96x96 indexed image in
-- the current 16-colour monitor palette, then converted per cell to two
-- colours + a 2x3 sextant mask.  The result is real pixel artwork, not ASCII.
Art = {}
Art.cache = {}
Art.images = {}
Art.cacheCap = 36
Art.imageCap = 10

local IMG = 96
local IMG_EXTS = { bmp = true, ppm = true, pnm = true }

function Art.clearCache()
  Art.cache = {}
  Art.images = {}
end

function Art.trimCache()
  local n = 0
  for k in pairs(Art.cache) do n = n + 1 end
  while n > Art.cacheCap do
    local first = next(Art.cache)
    if not first then break end
    Art.cache[first] = nil
    n = n - 1
  end
end

function Art.trimImages()
  local n = 0
  for k in pairs(Art.images) do n = n + 1 end
  while n > Art.imageCap do
    local first = next(Art.images)
    if not first then break end
    Art.images[first] = nil
    n = n - 1
  end
end

function Art.isImageFile(name)
  local ext = tostring(name):lower():match("%.([%w]+)$")
  return ext and IMG_EXTS[ext] or false
end

function Art.resolveArtPath(p, folder)
  if type(p) ~= "string" or p == "" then return nil end
  if p == "generated" then return "generated" end
  if fs.exists(p) then return p end
  if folder then
    local q = fs.combine(folder, p)
    if fs.exists(q) then return q end
  end
  -- Also allow paths relative to a configured root.
  for _, root in ipairs(App.cfg and App.cfg.roots or {}) do
    local q = fs.combine(root, p)
    if fs.exists(q) then return q end
  end
  return nil
end

function Art.listImages(folder)
  local out = {}
  if not folder or not fs.isDir(folder) then return out end
  local ok, entries = pcall(fs.list, folder)
  if not ok or not entries then return out end
  for _, entry in ipairs(entries) do
    if Art.isImageFile(entry) then out[#out + 1] = fs.combine(folder, entry) end
  end
  local covers = fs.combine(folder, "covers")
  if fs.isDir(covers) then
    local ok2, centries = pcall(fs.list, covers)
    if ok2 and centries then
      for _, entry in ipairs(centries) do
        if Art.isImageFile(entry) then out[#out + 1] = fs.combine(covers, entry) end
      end
    end
  end
  table.sort(out, function(a, b) return Util.naturalKey(fs.getName(a)) < Util.naturalKey(fs.getName(b)) end)
  return out
end

local coverNames = { "cover", "folder", "front", "album", "art", "artwork" }
function Art.autoCover(folder)
  if not folder then return nil end
  local list = Art.listImages(folder)
  if #list == 0 then return nil end
  local best
  for _, path in ipairs(list) do
    local base = fs.getName(path):lower():gsub("%.[%w]+$", "")
    for i, n in ipairs(coverNames) do
      if base == n then
        if not best or i < best.rank then best = { path = path, rank = i } end
      end
    end
  end
  if best then return best.path end
  return list[1]
end

function Art.albumSource(album)
  if not album then return nil, nil end
  local ap = album.artPath
  if ap == "generated" then return nil, "gen:album:" .. album.key end
  local resolved = Art.resolveArtPath(ap, album.folder)
  if resolved and resolved ~= "generated" then
    return resolved, resolved
  end
  local auto = Art.autoCover(album.folder)
  if auto then return auto, auto end
  return nil, "gen:album:" .. album.key
end

function Art.trackSource(track)
  if not track then return nil, nil end
  local ap = track.artPath
  if ap == "generated" then return nil, "gen:track:" .. track.path end
  local resolved = Art.resolveArtPath(ap, track.folder)
  if resolved and resolved ~= "generated" then
    return resolved, resolved
  end
  local album = track.albumRef
  if album then return Art.albumSource(album) end
  return nil, "gen:track:" .. track.path
end

local function readBinary(path, max)
  local ok, f = pcall(fs.open, path, "rb")
  if not ok or not f then return nil end
  local ok2, data = pcall(function() return f.readAll() end)
  pcall(function() f.close() end)
  if not ok2 or type(data) ~= "string" or #data == 0 then return nil end
  if max and #data > max then return nil end
  return data
end

local function nearestColor(r, g, b, pal)
  local best, bestD = 0, 1e18
  for i = 0, 15 do
    local c = pal[i]
    local cr, cg, cb = Util.rgbParts(c)
    local dr, dg, db = r - cr, g - cg, b - cb
    local d = dr * dr * 3 + dg * dg * 4 + db * db * 2
    if d < bestD then bestD = d; best = i end
  end
  return best
end
Art.nearestColor = nearestColor

function Art.rgbToIndex(rgb)
  local r, g, b = Util.rgbParts(rgb)
  return nearestColor(r, g, b, Theme.artPalette())
end

local function byteAt(s, i)
  return s:byte(i) or 0
end

local function u16le(s, i)
  return byteAt(s, i) + byteAt(s, i + 1) * 256
end

local function u32le(s, i)
  return byteAt(s, i) + byteAt(s, i + 1) * 256 + byteAt(s, i + 2) * 65536 + byteAt(s, i + 3) * 16777216
end

local function i32le(s, i)
  local v = u32le(s, i)
  if v >= 2147483648 then v = v - 4294967296 end
  return v
end

-- Decode a BMP into the 96x96 indexed target.  Returns image table or nil,err.
local function decodeBmp(data, pal)
  if #data < 54 or data:sub(1, 2) ~= "BM" then return nil, "not BMP" end
  local dataOffset = u32le(data, 11)
  local dibSize = u32le(data, 15)
  if dibSize < 40 then return nil, "BMP DIB too old" end
  local width = i32le(data, 19)
  local height = i32le(data, 23)
  local bpp = u16le(data, 29)
  local compression = u32le(data, 31)
  local colorsUsed = u32le(data, 47)
  if compression ~= 0 then return nil, "compressed BMP unsupported" end
  if bpp ~= 8 and bpp ~= 24 and bpp ~= 32 then return nil, "BMP bpp unsupported" end
  if width <= 0 or height == 0 or width > 4096 or math.abs(height) > 4096 then return nil, "BMP dimensions" end
  local topDown = height < 0
  height = math.abs(height)
  local stride = math.floor((bpp * width + 31) / 32) * 4
  if dataOffset + stride * height > #data + 1 then return nil, "BMP truncated" end

  local palette
  if bpp == 8 then
    local count = colorsUsed
    if count == 0 then count = 256 end
    palette = {}
    local p = 15 + dibSize
    for i = 0, count - 1 do
      local o = p + i * 4
      if o + 2 <= #data then
        palette[i] = { byteAt(data, o + 2), byteAt(data, o + 1), byteAt(data, o) }
      end
    end
  end

  local cw, ch = width, height
  local sx0, sy0, side
  if cw > ch then
    side = ch; sx0 = math.floor((cw - ch) / 2); sy0 = 0
  else
    side = cw; sx0 = 0; sy0 = math.floor((ch - cw) / 2)
  end

  local pix = {}
  for ty = 0, IMG - 1 do
    local sy = sy0 + math.min(side - 1, math.floor((ty + 0.5) * side / IMG))
    local rowY = topDown and sy or (height - 1 - sy)
    for tx = 0, IMG - 1 do
      local sx = sx0 + math.min(side - 1, math.floor((tx + 0.5) * side / IMG))
      local off = dataOffset + rowY * stride + math.floor(sx * bpp / 8)
      local r, g, b, a = 0, 0, 0, 255
      if bpp == 8 then
        local idx = byteAt(data, off + 1)
        local c = palette and palette[idx]
        if c then r, g, b = c[1], c[2], c[3] end
      elseif bpp == 24 then
        b, g, r = byteAt(data, off + 1), byteAt(data, off + 2), byteAt(data, off + 3)
      else
        b, g, r, a = byteAt(data, off + 1), byteAt(data, off + 2), byteAt(data, off + 3), byteAt(data, off + 4)
        -- BI_RGB 32bpp files commonly leave the fourth byte at 0.  It is not an
        -- alpha channel in that case, so treat it as opaque.
        if a == 0 then a = 255 end
      end
      if a < 255 then
        local bgR, bgG, bgB = 8, 10, 15
        local k = a / 255
        r = r * k + bgR * (1 - k)
        g = g * k + bgG * (1 - k)
        b = b * k + bgB * (1 - k)
      end
      pix[#pix + 1] = string.char(nearestColor(r, g, b, pal))
    end
  end
  return { w = IMG, h = IMG, pix = table.concat(pix), source = "bmp" }
end

-- PPM token reader
local function ppmToken(data, pos)
  while true do
    local ch = data:sub(pos, pos)
    if ch == "#" then
      local nl = data:find("\n", pos, true)
      if not nl then return nil, #data + 1 end
      pos = nl + 1
    elseif ch:match("%s") then
      pos = pos + 1
    else
      break
    end
  end
  local start = pos
  while pos <= #data and not data:sub(pos, pos):match("%s") and data:sub(pos, pos) ~= "#" do
    pos = pos + 1
  end
  return data:sub(start, pos - 1), pos
end

local function decodePpm(data, pal)
  local magic, pos = ppmToken(data, 1)
  if magic ~= "P6" and magic ~= "P3" then return nil, "not PPM" end
  local wTok, p2 = ppmToken(data, pos)
  local hTok, p3 = ppmToken(data, p2)
  local mTok, p4 = ppmToken(data, p3)
  local w, h, maxv = tonumber(wTok), tonumber(hTok), tonumber(mTok)
  if not w or not h or not maxv or w <= 0 or h <= 0 or w > 2048 or h > 2048 then return nil, "PPM dimensions" end
  if magic == "P3" and w * h > 262144 then return nil, "P3 too large" end
  local sx0, sy0, side
  if w > h then side = h; sx0 = math.floor((w - h) / 2); sy0 = 0
  else side = w; sx0 = 0; sy0 = math.floor((h - w) / 2) end

  local pix = {}
  if magic == "P6" then
    -- Exactly one whitespace character separates the header and binary data.
    local start = p4
    local ch = data:sub(start, start)
    if ch == "\r" then
      start = start + 1
      if data:sub(start, start) == "\n" then start = start + 1 end
    elseif ch:match("%s") then
      start = start + 1
    end
    local bps = maxv > 255 and 2 or 1
    if maxv > 65535 then return nil, "PPM maxval" end
    local bytesPerPixel = 3 * bps
    if start + w * h * bytesPerPixel - 1 > #data then return nil, "PPM truncated" end
    for ty = 0, IMG - 1 do
      local sy = sy0 + math.min(side - 1, math.floor((ty + 0.5) * side / IMG))
      for tx = 0, IMG - 1 do
        local sx = sx0 + math.min(side - 1, math.floor((tx + 0.5) * side / IMG))
        local off = start + (sy * w + sx) * bytesPerPixel
        local r, g, b
        if bps == 1 then
          r, g, b = byteAt(data, off), byteAt(data, off + 1), byteAt(data, off + 2)
        else
          r = byteAt(data, off) * 256 + byteAt(data, off + 1)
          g = byteAt(data, off + 2) * 256 + byteAt(data, off + 3)
          b = byteAt(data, off + 4) * 256 + byteAt(data, off + 5)
          r, g, b = r * 255 / maxv, g * 255 / maxv, b * 255 / maxv
        end
        if bps == 1 and maxv ~= 255 then
          r, g, b = r * 255 / maxv, g * 255 / maxv, b * 255 / maxv
        end
        pix[#pix + 1] = string.char(nearestColor(r, g, b, pal))
      end
    end
  else
    -- P3: sequential ASCII.  Only map pixels that fall on the 96x96 grid.
    local target = {}
    local cur = p4
    for y = 0, h - 1 do
      local ty = nil
      if y >= sy0 and y < sy0 + side then
        ty = math.min(IMG - 1, math.floor((y - sy0 + 0.5) * IMG / side))
      end
      for x = 0, w - 1 do
        local rt, p5 = ppmToken(data, cur); cur = p5
        local gt, p6 = ppmToken(data, cur); cur = p6
        local bt, p7 = ppmToken(data, cur); cur = p7
        if not rt or not gt or not bt then return nil, "P3 truncated" end
        if ty then
          local tx = nil
          if x >= sx0 and x < sx0 + side then
            tx = math.min(IMG - 1, math.floor((x - sx0 + 0.5) * IMG / side))
          end
          if tx then
            local r, g, b = tonumber(rt) or 0, tonumber(gt) or 0, tonumber(bt) or 0
            r, g, b = r * 255 / maxv, g * 255 / maxv, b * 255 / maxv
            target[ty * IMG + tx + 1] = string.char(nearestColor(r, g, b, pal))
          end
        end
      end
    end
    for i = 0, IMG * IMG - 1 do pix[i + 1] = target[i + 1] or string.char(0) end
  end
  return { w = IMG, h = IMG, pix = table.concat(pix), source = "ppm" }
end

function Art.loadImage(path)
  if type(path) ~= "string" or not fs.exists(path) then return nil, "missing" end
  local okAttr, attr = pcall(fs.attributes, path)
  local size = okAttr and type(attr) == "table" and tonumber(attr.size) or nil
  local mtime = okAttr and type(attr) == "table" and (attr.mtime or attr.modified) or nil
  local key = path .. "|" .. tostring(size) .. "|" .. tostring(mtime) .. "|" .. Theme.version
  local hit = Art.images[key]
  if hit then return hit end
  local data = readBinary(path, 8 * 1024 * 1024)
  if not data then return nil, "unreadable or too large" end
  local pal = Theme.artPalette()
  local img, err
  if data:sub(1, 2) == "BM" then
    img, err = decodeBmp(data, pal)
  elseif data:sub(1, 2) == "P6" or data:sub(1, 2) == "P3" then
    img, err = decodePpm(data, pal)
  else
    return nil, "unsupported image (use BMP or PPM)"
  end
  if not img then return nil, err end
  img.path = path
  Art.images[key] = img
  Art.trimImages()
  return img
end

local function imageFromGenerated(key, label, iconName)
  local pal = Theme.artPalette()
  local h = Util.hash(key)
  local variant = h % 3
  local accent = Theme.C.accent
  local accentLight = Theme.C.accentLight
  local accentDim = Theme.C.accentDim
  local surface = Theme.C.surface
  local surface2 = Theme.C.surface2
  local icon = iconName or ({ "music9", "disc9", "heart9", "waveform" })[(h % 4) + 1]
  local pix = {}
  local pal = Theme.artPalette()
  local function q(rgb)
    local r, g, b = Util.rgbParts(rgb)
    return nearestColor(r, g, b, pal)
  end
  local accentRgb = Theme.col(accent)
  local lightRgb = Theme.col(accentLight)
  local darkRgb = Theme.col(accentDim)
  local surfaceRgb = Theme.col(surface)
  local surface2Rgb = Theme.col(surface2)
  for y = 0, IMG - 1 do
    local v = y / (IMG - 1)
    for x = 0, IMG - 1 do
      local u = x / (IMG - 1)
      local dx, dy = u - 0.5, v - 0.5
      local d = math.sqrt(dx * dx + dy * dy)
      local rgb
      if variant == 0 then
        local ring = 0.5 + 0.5 * math.sin(d * 28 - h % 7)
        rgb = Util.blend(darkRgb, surfaceRgb, 0.35 + ring * 0.55)
        if d < 0.28 then rgb = Util.blend(rgb, accentRgb, 0.45) end
      elseif variant == 1 then
        local wave = 0.5 + 0.5 * math.sin(u * 9 + v * 4 + (h % 11) * 0.4)
        rgb = Util.blend(surface2Rgb, darkRgb, 0.2 + wave * 0.6)
        if wave > 0.78 then rgb = Util.blend(rgb, accentRgb, 0.55) end
      else
        local gx = math.floor(u * 12) + math.floor(v * 12)
        rgb = (gx % 2 == 0) and surface2Rgb or surfaceRgb
        rgb = Util.blend(rgb, accentDim, d * 0.55)
        if math.abs(u - v) < 0.04 then rgb = accentRgb end
      end
      if d > 0.42 then rgb = Util.blend(rgb, 0x000000, (d - 0.42) * 1.15) end
      local speck = (x * 17 + y * 31 + h * 13) % 100
      if speck < 6 then rgb = Util.blend(rgb, 0xFFFFFF, 0.05) end
      pix[#pix + 1] = string.char(q(rgb))
    end
  end
  local img = { w = IMG, h = IMG, pix = table.concat(pix), source = "generated" }
  -- Large soft glyph in the centre.
  local bm = Icons.bitmaps[icon]
  if bm then
    local scale = 5
    local iw = #bm[1] * scale
    local ih = #bm * scale
    local ox = math.floor((IMG - iw) / 2)
    local oy = math.floor((IMG - ih) / 2)
    local light = string.char(q(lightRgb))
    local dark = string.char(q(surfaceRgb))
    local chars = {}
    for i = 1, IMG * IMG do chars[i] = img.pix:sub(i, i) end
    for y = 1, #bm do
      for x = 1, #bm[y] do
        if bm[y]:sub(x, x) == "#" then
          for sy = 0, scale - 1 do
            for sx = 0, scale - 1 do
              local px, py = ox + (x - 1) * scale + sx, oy + (y - 1) * scale + sy
              if px >= 0 and px < IMG and py >= 0 and py < IMG then
                chars[(py) * IMG + px + 1] = light
              end
              local shx, shy = px + 2, py + 2
              if shx >= 0 and shx < IMG and shy >= 0 and shy < IMG then
                local idx = shy * IMG + shx + 1
                if chars[idx] ~= light then chars[idx] = dark end
              end
            end
          end
        end
      end
    end
    img.pix = table.concat(chars)
  end
  return img
end

function Art.generatedImage(key, label, icon)
  local ck = "gen|" .. tostring(key) .. "|" .. tostring(icon) .. "|" .. Theme.version
  local hit = Art.images[ck]
  if hit then return hit end
  local img = imageFromGenerated(key, label, icon)
  Art.images[ck] = img
  Art.trimImages()
  return img
end

local function imageForSource(path, genKey, genLabel, genIcon)
  if path then
    local img, err = Art.loadImage(path)
    if img then return img, path, nil end
    return nil, nil, err
  end
  return Art.generatedImage(genKey, genLabel, genIcon), genKey, nil
end

function Art.albumImage(album)
  if not album then return nil, nil end
  local path, srcKey = Art.albumSource(album)
  if path then
    local img, err = Art.loadImage(path)
    if img then return img, path, nil end
    local gen = Art.generatedImage("album:" .. album.key, album.name, nil)
    return gen, "gen:album:" .. album.key, err
  end
  return Art.generatedImage(srcKey or ("album:" .. album.key), album.name, album.isSingles and "music9" or nil), srcKey, nil
end

function Art.trackImage(track)
  if not track then return nil, nil end
  local path, srcKey = Art.trackSource(track)
  if path then
    local img, err = Art.loadImage(path)
    if img then return img, path, nil end
    return Art.albumImage(track.albumRef)
  end
  if srcKey and srcKey:sub(1, 10) == "gen:track:" then
    return Art.generatedImage(srcKey, track.title, "music9"), srcKey, nil
  end
  return Art.albumImage(track.albumRef)
end

-- Build a per-cell art object (3 bytes per cell: fg, bg, mask).
-- Samples from img.w × img.h so .nfp/BMP covers (decoded to IMG×IMG) scale into
-- whatever UI slot size is requested without 1:1 overflow.
function Art.buildCells(img, cw, ch)
  cw, ch = math.max(1, math.floor(cw)), math.max(1, math.floor(ch))
  local pal = Theme.artPalette()
  local pix = img.pix
  local iw = math.max(1, tonumber(img.w) or IMG)
  local ih = math.max(1, tonumber(img.h) or IMG)
  local data = {}
  local count = {}
  local colors = {}
  for cy = 0, ch - 1 do
    for cx = 0, cw - 1 do
      local vals = {}
      local n = 0
      for sy = 0, 2 do
        local py = math.min(ih - 1, math.floor(((cy * 3 + sy) + 0.5) * ih / (ch * 3)))
        for sx = 0, 1 do
          local px = math.min(iw - 1, math.floor(((cx * 2 + sx) + 0.5) * iw / (cw * 2)))
          local c = pix:byte(py * iw + px + 1) or 0
          n = n + 1
          vals[n] = c
          count[c] = (count[c] or 0) + 1
          if not colors[c] then colors[c] = true end
        end
      end
      local c1, c2, n1, n2 = nil, nil, 0, 0
      for c, cnt in pairs(count) do
        if cnt > n1 then
          c2, n2 = c1, n1
          c1, n1 = c, cnt
        elseif cnt > n2 then
          c2, n2 = c, cnt
        end
      end
      if not c2 then
        c2 = c1
      else
        -- Prefer a second colour that is visibly different; gradients otherwise
        -- collapse into a flat cell.
        local r1, g1, b1 = Util.rgbParts(pal[c1])
        local r2, g2, b2 = Util.rgbParts(pal[c2])
        local dist = math.abs(r1 - r2) + math.abs(g1 - g2) + math.abs(b1 - b2)
        if dist < 48 then
          local far, fd = c2, dist
          for c in pairs(colors) do
            if c ~= c1 then
              local r, g, b = Util.rgbParts(pal[c])
              local d = math.abs(r1 - r) + math.abs(g1 - g) + math.abs(b1 - b)
              if d > fd then far, fd = c, d end
            end
          end
          c2 = far
        end
      end
      local fg, bg = c1, c2
      if not fg then fg, bg = 0, 0 end
      if not bg then bg = fg end
      local mask = 0
      for k = 0, 5 do
        local c = vals[k + 1] or bg
        local useFg
        if c == fg then useFg = true
        elseif c == bg then useFg = false
        else
          local r, g, b = Util.rgbParts(pal[c])
          local fr, fg2, fb = Util.rgbParts(pal[fg])
          local br, bg2, bb = Util.rgbParts(pal[bg])
          local df = math.abs(r - fr) + math.abs(g - fg2) + math.abs(b - fb)
          local db = math.abs(r - br) + math.abs(g - bg2) + math.abs(b - bb)
          useFg = df < db
        end
        if useFg then mask = mask + 2 ^ k end
      end
      if mask == 63 then fg, bg, mask = fg, fg, 0 end
      data[#data + 1] = string.char(fg, bg, mask)
      for c in pairs(count) do count[c] = nil end
      for c in pairs(colors) do colors[c] = nil end
    end
  end
  return { w = cw, h = ch, data = table.concat(data) }
end

function Art.cacheKey(srcKey, cw, ch)
  return tostring(srcKey) .. "|" .. tostring(cw) .. "x" .. tostring(ch) .. "|" .. Theme.version
end

function Art.forAlbum(album, cw, ch)
  if not album then return nil end
  local img, srcKey, err = Art.albumImage(album)
  if not img then return nil end
  local key = Art.cacheKey(srcKey or ("album:" .. album.key), cw, ch)
  local hit = Art.cache[key]
  if hit then return hit end
  local art = Art.buildCells(img, cw, ch)
  Art.cache[key] = art
  Art.trimCache()
  return art
end

function Art.forTrack(track, cw, ch)
  if not track then return nil end
  local img, srcKey = Art.trackImage(track)
  if not img then return Art.forAlbum(track.albumRef, cw, ch) end
  local key = Art.cacheKey(srcKey or ("track:" .. track.path), cw, ch)
  local hit = Art.cache[key]
  if hit then return hit end
  local art = Art.buildCells(img, cw, ch)
  Art.cache[key] = art
  Art.trimCache()
  return art
end

function Art.playlistImage(pl)
  local key = "playlist:" .. (pl and pl.name or "?")
  local tracks = pl and Data.playlistTracks(pl) or {}
  if #tracks == 0 then
    return Art.generatedImage(key, pl and pl.name or "Playlist", "playlist"), key
  end
  -- Compose a 2x2 mosaic from the first four covers.
  local chars = {}
  for i = 1, IMG * IMG do chars[i] = string.char(Theme.C.surface) end
  local parts = {}
  for i = 1, math.min(4, #tracks) do
    local img = Art.trackImage(tracks[i])
    parts[i] = img
  end
  for quad = 0, 3 do
    local img = parts[quad + 1]
    local qx = quad % 2
    local qy = math.floor(quad / 2)
    if img then
      local iw = math.max(1, tonumber(img.w) or IMG)
      local ih = math.max(1, tonumber(img.h) or IMG)
      for y = 0, IMG / 2 - 1 do
        for x = 0, IMG / 2 - 1 do
          local sx = math.min(iw - 1, math.floor((x + 0.5) * iw / (IMG / 2)))
          local sy = math.min(ih - 1, math.floor((y + 0.5) * ih / (IMG / 2)))
          local c = img.pix:sub(sy * iw + sx + 1, sy * iw + sx + 1)
          local tx = qx * (IMG / 2) + x
          local ty = qy * (IMG / 2) + y
          chars[ty * IMG + tx + 1] = c
        end
      end
    end
  end
  local img = { w = IMG, h = IMG, pix = table.concat(chars), source = "mosaic" }
  return img, key
end

function Art.forPlaylist(pl, cw, ch)
  if not pl then return nil end
  local img, key = Art.playlistImage(pl)
  local ck = Art.cacheKey(key, cw, ch)
  local hit = Art.cache[ck]
  if hit then return hit end
  local art = Art.buildCells(img, cw, ch)
  Art.cache[ck] = art
  Art.trimCache()
  return art
end

function Art.invalidateAlbum(album)
  if not album then return end
  local needle = album.key
  for k in pairs(Art.cache) do
    if k:find(needle, 1, true) then Art.cache[k] = nil end
  end
  for k in pairs(Art.images) do
    if k:find(needle, 1, true) then Art.images[k] = nil end
  end
end

function Art.cacheStats()
  local n, ni = 0, 0
  for _ in pairs(Art.cache) do n = n + 1 end
  for _ in pairs(Art.images) do ni = ni + 1 end
  return n, ni
end

--======== 70_lyrics.lua ========
------------------------------------------------------------------ lyrics
-- Full .lrc parsing, including multiple timestamps per line, [offset:],
-- metadata tags and plain .txt fallback.  Synchronisation uses the audio
-- engine's PCM clock, never a separate timer.
Lrc = {}
Lrc.cache = {}
Lrc.cacheCap = 16

local function lrcCleanLine(s)
  s = Util.clean(s)
  s = s:gsub("<%d+:%d+[%.%:]%d+>", "")
  s = s:gsub("%s+", " ")
  return Util.trim(s)
end

local function parseTimestamp(mm, ss, frac)
  local m = tonumber(mm) or 0
  local s = tonumber(ss) or 0
  local f = 0
  if frac then
    if #frac == 1 then f = (tonumber(frac) or 0) / 10
    elseif #frac == 2 then f = (tonumber(frac) or 0) / 100
    else f = (tonumber(frac) or 0) / 1000 end
  end
  return m * 60 + s + f
end

function Lrc.parse(raw, path)
  raw = tostring(raw or ""):gsub("^\239\187\191", "")
  local all = Util.splitLines(raw)
  local entries, meta = {}, {}
  local plain = {}
  local offset = 0

  for _, rawLine in ipairs(all) do
    local line = rawLine:gsub("\r", "")
    -- Metadata tags.
    local metaTag, metaVal = line:match("^%s*%[([%a]+):([^%]]*)%]%s*$")
    if metaTag then
      local k = metaTag:lower()
      meta[k] = Util.clean(metaVal)
      if k == "offset" then offset = (tonumber(metaVal) or 0) / 1000 end
    end
    local hasTime = false
    local text = line
    local stamps = {}
    text = text:gsub("%[(%d+):(%d+)[%.:](%d+)%]", function(mm, ss, frac)
      hasTime = true
      stamps[#stamps + 1] = parseTimestamp(mm, ss, frac)
      return ""
    end)
    text = text:gsub("%[(%d+):(%d+)%]", function(mm, ss)
      hasTime = true
      stamps[#stamps + 1] = parseTimestamp(mm, ss, nil)
      return ""
    end)
    -- Remove any remaining metadata tag from a text line.
    text = text:gsub("%[[%a]+:[^%]]*%]", "")
    text = lrcCleanLine(text)
    if hasTime then
      for _, t in ipairs(stamps) do
        entries[#entries + 1] = { time = math.max(0, t + offset), text = text }
      end
    elseif text ~= "" then
      plain[#plain + 1] = text
    end
  end

  table.sort(entries, function(a, b)
    if a.time ~= b.time then return a.time < b.time end
    return a.text < b.text
  end)
  -- Merge identical timestamps so each timestamp has one display line.
  local merged = {}
  for _, e in ipairs(entries) do
    local last = merged[#merged]
    if last and math.abs(last.time - e.time) < 0.02 then
      if e.text ~= "" and e.text ~= last.text then
        last.text = (last.text ~= "" and (last.text .. " / ") or "") .. e.text
      end
    else
      merged[#merged + 1] = e
    end
  end

  local sync = #merged > 0
  local lines = {}
  if sync then
    for _, e in ipairs(merged) do lines[#lines + 1] = e end
  else
    for _, text in ipairs(plain) do lines[#lines + 1] = { time = nil, text = text } end
  end
  return {
    path = path,
    sync = sync,
    lines = lines,
    meta = meta,
    offset = offset,
    source = path and path:lower():match("%.lrc$") and "lrc" or "txt",
  }
end

function Lrc.loadFile(path)
  if type(path) ~= "string" or not fs.exists(path) then return nil end
  local attrs = nil
  local okA, attr = pcall(fs.attributes, path)
  if okA then attrs = attr end
  local mtime = attrs and (attrs.mtime or attrs.modified) or nil
  local size = attrs and attrs.size or nil
  local key = path .. "|" .. tostring(size) .. "|" .. tostring(mtime)
  if Lrc.cache[key] then return Lrc.cache[key] end
  local ok, f = pcall(fs.open, path, "rb")
  if not ok or not f then return nil end
  local raw = f.readAll()
  f.close()
  if type(raw) ~= "string" then return nil end
  local lyrics = Lrc.parse(raw, path)
  Lrc.cache[key] = lyrics
  local n = 0
  for k in pairs(Lrc.cache) do n = n + 1 end
  while n > Lrc.cacheCap do
    local first = next(Lrc.cache)
    if not first then break end
    Lrc.cache[first] = nil
    n = n - 1
  end
  return lyrics
end

local function baseName(path)
  local name = fs.getName(path or "")
  return name:gsub("%.[Dd][Ff][Pp][Ww][Mm]$", "")
end

function Lrc.candidates(track)
  local out = {}
  if not track then return out end
  local folder = track.folder
  local base = baseName(track.path)
  local cleanTitle = Util.clean(track.title):gsub("[/\\:*?\"<>|]", "_")
  local names = { base .. ".lrc", base .. ".LRC", base .. ".txt", base .. ".TXT", cleanTitle .. ".lrc", cleanTitle .. ".LRC", cleanTitle .. ".txt", cleanTitle .. ".TXT" }
  local dirs = { folder, fs.combine(folder, "lyrics"), fs.combine(folder, "Lyrics"), fs.combine(Store.dir or ".aurora", "lyrics") }
  for _, root in ipairs(App.cfg.roots or {}) do
    dirs[#dirs + 1] = fs.combine(root, "lyrics")
  end
  local seen = {}
  for _, dir in ipairs(dirs) do
    for _, name in ipairs(names) do
      local p = fs.combine(dir, name)
      if not seen[p] and fs.exists(p) then
        seen[p] = true
        out[#out + 1] = p
      end
    end
  end
  return out
end

function Lrc.find(track, forced)
  if not track then return nil end
  if forced and forced ~= "" then
    local p = Art.resolveArtPath(forced, track.folder)
    if p and p ~= "generated" then
      local l = Lrc.loadFile(p)
      if l then return l end
    end
  end
  for _, p in ipairs(Lrc.candidates(track)) do
    local l = Lrc.loadFile(p)
    if l and (#l.lines > 0) then return l end
  end
  return nil
end

function Lrc.currentIndex(lyrics, position, fallback)
  if not lyrics or not lyrics.sync or #lyrics.lines == 0 then return fallback end
  local lo, hi, best = 1, #lyrics.lines, 0
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if lyrics.lines[mid].time <= position + 0.01 then
      best = mid; lo = mid + 1
    else
      hi = mid - 1
    end
  end
  if best == 0 then return 1 end
  return best
end

function Lrc.nextLine(lyrics, index)
  if not lyrics then return nil end
  return lyrics.lines[index + 1]
end

-- Wrap a lyric line into display rows while preserving its timestamp.
function Lrc.displayRows(lyrics, width)
  local rows = {}
  if not lyrics then return rows end
  for i, line in ipairs(lyrics.lines) do
    local wrapped = Util.wrap(line.text, math.max(1, width))
    if #wrapped == 0 then wrapped = { "" } end
    for j, text in ipairs(wrapped) do
      rows[#rows + 1] = { index = i, text = text, time = line.time, cont = j > 1 }
    end
  end
  return rows
end

function Lrc.clearCache()
  Lrc.cache = {}
end

--======== 75_auth.lua ========
------------------------------------------------------------------ authentication
-- CC:Tweaked has no crypto library.  This is a compact, pure-Lua
-- PBKDF2-HMAC-SHA256 using the bit32 library that CC:T provides.  It is far
-- better than storing a plaintext credential, but the real security boundary
-- is filesystem access.  A 4-digit PIN has only 10,000 possibilities; a long
-- password is strongly recommended.  Salts are generated from the best
-- entropy available to a CC computer (epoch, uptime, computer id, random).
Auth = {}
Auth.file = "auth"
Auth.data = nil
Auth.root = false
Auth.rootAt = 0
Auth.iterations = 700
Auth.minPin, Auth.maxPin = 4, 8
Auth.minPassword = 6
Auth.maxSecret = 72

local U32 = 4294967296
local band, bor, bxor, bnot = bit32.band, bit32.bor, bit32.bxor, bit32.bnot
local lshift, rshift = bit32.lshift, bit32.rshift
local rrotate = function(x, n) return bor(rshift(x, n), lshift(x, 32 - n)) end
local function add32(...)
  local sum = 0
  for _, v in ipairs({ ... }) do sum = (sum + v) % U32 end
  return sum
end
local function toHex(s)
  return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end
local function fromHex(s)
  s = tostring(s or "")
  local out = {}
  for i = 1, #s, 2 do out[#out + 1] = string.char(tonumber(s:sub(i, i + 1), 16) or 0) end
  return table.concat(out)
end

local SHA256_K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

function Auth.sha256(msg)
  msg = tostring(msg or "")
  local bits = #msg * 8
  local bytes = { msg:byte(1, #msg) }
  bytes[#bytes + 1] = 0x80
  while (#bytes % 64) ~= 56 do bytes[#bytes + 1] = 0 end
  -- 64-bit length, big endian.  CC strings cannot realistically exceed 2^32.
  local hi = math.floor(bits / U32)
  local lo = bits % U32
  bytes[#bytes + 1] = math.floor(hi / 16777216) % 256
  bytes[#bytes + 1] = math.floor(hi / 65536) % 256
  bytes[#bytes + 1] = math.floor(hi / 256) % 256
  bytes[#bytes + 1] = hi % 256
  bytes[#bytes + 1] = math.floor(lo / 16777216) % 256
  bytes[#bytes + 1] = math.floor(lo / 65536) % 256
  bytes[#bytes + 1] = math.floor(lo / 256) % 256
  bytes[#bytes + 1] = lo % 256

  local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
  local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
  local w = {}

  for block = 1, #bytes, 64 do
    for i = 0, 15 do
      local o = block + i * 4
      w[i] = ((bytes[o] or 0) * 16777216 + (bytes[o + 1] or 0) * 65536 + (bytes[o + 2] or 0) * 256 + (bytes[o + 3] or 0)) % U32
    end
    for i = 16, 63 do
      local s0 = bxor(rrotate(w[i - 15], 7), bxor(rrotate(w[i - 15], 18), rshift(w[i - 15], 3)))
      local s1 = bxor(rrotate(w[i - 2], 17), bxor(rrotate(w[i - 2], 19), rshift(w[i - 2], 10)))
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % U32
    end
    local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
    for i = 0, 63 do
      local S1 = bxor(rrotate(e, 6), bxor(rrotate(e, 11), rrotate(e, 25)))
      local ch = bxor(band(e, f), band(bnot(e), g))
      local t1 = (h + S1 + ch + SHA256_K[i + 1] + w[i]) % U32
      local S0 = bxor(rrotate(a, 2), bxor(rrotate(a, 13), rrotate(a, 22)))
      local maj = bxor(band(a, b), bxor(band(a, c), band(b, c)))
      local t2 = (S0 + maj) % U32
      h, g, f, e, d, c, b, a = g, f, e, (d + t1) % U32, c, b, a, (t1 + t2) % U32
    end
    h0 = (h0 + a) % U32; h1 = (h1 + b) % U32; h2 = (h2 + c) % U32; h3 = (h3 + d) % U32
    h4 = (h4 + e) % U32; h5 = (h5 + f) % U32; h6 = (h6 + g) % U32; h7 = (h7 + h) % U32
  end

  local out = {}
  for _, v in ipairs({ h0, h1, h2, h3, h4, h5, h6, h7 }) do
    out[#out + 1] = string.char(
      math.floor(v / 16777216) % 256, math.floor(v / 65536) % 256,
      math.floor(v / 256) % 256, v % 256)
  end
  return table.concat(out)
end

function Auth.hmac(key, msg)
  key = tostring(key or "")
  if #key > 64 then key = Auth.sha256(key) end
  local ipad, opad = {}, {}
  for i = 1, 64 do
    local b = key:byte(i) or 0
    ipad[i] = string.char(bxor(b, 0x36))
    opad[i] = string.char(bxor(b, 0x5c))
  end
  local inner = Auth.sha256(table.concat(ipad) .. msg)
  return Auth.sha256(table.concat(opad) .. inner)
end

function Auth.pbkdf2(secret, salt, iterations)
  iterations = math.max(1, math.floor(iterations or Auth.iterations))
  local block = Auth.hmac(secret, salt .. "\0\0\0\1")
  local t = { block:byte(1, 32) }
  local u = block
  for _ = 2, iterations do
    u = Auth.hmac(secret, u)
    for i = 1, 32 do t[i] = bxor(t[i], u:byte(i) or 0) end
  end
  local out = {}
  for i = 1, 32 do out[i] = string.char(t[i]) end
  return table.concat(out)
end

function Auth.constantEq(a, b)
  a, b = tostring(a or ""), tostring(b or "")
  if #a ~= #b then return false end
  local d = 0
  for i = 1, #a do d = bor(d, bxor(a:byte(i), b:byte(i))) end
  return d == 0
end

function Auth.randomBytes(n)
  local out = {}
  local seed = tostring(Util.now()) .. tostring(os.clock and os.clock() or 0)
  for i = 1, n do
    local r = math.random(0, 255)
    local s = Util.hash(seed .. ":" .. tostring(r) .. ":" .. tostring(i)) % 256
    out[i] = string.char(bxor(r, s))
  end
  return table.concat(out)
end

function Auth.generateRecoveryCode()
  local alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
  local chars = {}
  for i = 1, 10 do
    local n = math.random(1, #alphabet)
    chars[i] = alphabet:sub(n, n)
  end
  local raw = table.concat(chars)
  return raw:sub(1, 5) .. "-" .. raw:sub(6, 10), raw
end

function Auth.normalizeRecovery(code)
  return Util.trim(tostring(code or "")):upper():gsub("[^A-Z0-9]", "")
end

function Auth.load()
  local data, why = Store.load(Auth.file, nil)
  if type(data) ~= "table" then
    Auth.data = nil
    Auth.configured = false
    Auth.corrupt = (why == "corrupt")
    return false
  end
  if type(data.username) ~= "string" or data.username == ""
    or type(data.salt) ~= "string" or type(data.hash) ~= "string"
    or (data.mode ~= "pin" and data.mode ~= "password") then
    Auth.data = nil
    Auth.configured = false
    Auth.corrupt = true
    return false
  end
  Auth.data = data
  Auth.configured = true
  Auth.corrupt = false
  Auth.iterations = Util.clamp(tonumber(data.iter) or 700, 100, 5000)
  return true
end

function Auth.save()
  if not Auth.data then return false end
  return Store.save(Auth.file, Auth.data)
end

function Auth.create(username, mode, secret, recoveryRaw)
  username = Util.trim(Util.clean(username))
  if username == "" then return false, "Enter a username" end
  if #username > 24 then return false, "Username is too long" end
  if mode ~= "pin" and mode ~= "password" then return false, "Choose PIN or password" end
  secret = tostring(secret or "")
  if mode == "pin" then
    if not secret:match("^%d+$") then return false, "PIN must be digits only" end
    if #secret < Auth.minPin or #secret > Auth.maxPin then return false, "PIN must be 4-8 digits" end
  else
    if #secret < Auth.minPassword then return false, "Password must be at least 6 characters" end
    if #secret > Auth.maxSecret then return false, "Password is too long" end
  end
  local salt = Auth.randomBytes(16)
  local hash = Auth.pbkdf2(secret, salt, Auth.iterations)
  local recoveryCode, recoveryNorm = Auth.generateRecoveryCode()
  if recoveryRaw then
    recoveryNorm = Auth.normalizeRecovery(recoveryRaw)
    recoveryCode = tostring(recoveryRaw)
  end
  local rSalt = Auth.randomBytes(16)
  local rHash = Auth.pbkdf2(recoveryNorm, rSalt, Auth.iterations)
  Auth.data = {
    version = 1,
    username = username,
    mode = mode,
    salt = toHex(salt),
    hash = toHex(hash),
    iter = Auth.iterations,
    recoverySalt = toHex(rSalt),
    recoveryHash = toHex(rHash),
    created = os.time and os.time() or 0,
    updated = os.time and os.time() or 0,
  }
  Auth.configured = true
  Auth.corrupt = false
  Auth.root = true
  Auth.rootAt = Util.now()
  Auth.pendingRecoveryCode = recoveryCode
  if not Auth.save() then
    Auth.data = nil
    Auth.configured = false
    Auth.root = false
    return false, "Could not write root data"
  end
  return true, nil, recoveryCode
end

function Auth.verify(secret)
  if not Auth.data then return false end
  local salt = fromHex(Auth.data.salt)
  local hash = Auth.pbkdf2(tostring(secret or ""), salt, tonumber(Auth.data.iter) or Auth.iterations)
  return Auth.constantEq(toHex(hash), Auth.data.hash)
end

function Auth.verifyRecovery(code)
  if not Auth.data or type(Auth.data.recoverySalt) ~= "string" then return false end
  local norm = Auth.normalizeRecovery(code)
  if #norm < 6 then return false end
  local salt = fromHex(Auth.data.recoverySalt)
  local hash = Auth.pbkdf2(norm, salt, tonumber(Auth.data.iter) or Auth.iterations)
  return Auth.constantEq(toHex(hash), Auth.data.recoveryHash)
end

function Auth.changeSecret(mode, secret)
  if not Auth.data then return false, "Root is not configured" end
  if mode ~= "pin" and mode ~= "password" then return false, "Choose PIN or password" end
  secret = tostring(secret or "")
  if mode == "pin" then
    if not secret:match("^%d+$") then return false, "PIN must be digits only" end
    if #secret < Auth.minPin or #secret > Auth.maxPin then return false, "PIN must be 4-8 digits" end
  else
    if #secret < Auth.minPassword then return false, "Password must be at least 6 characters" end
    if #secret > Auth.maxSecret then return false, "Password is too long" end
  end
  local salt = Auth.randomBytes(16)
  Auth.data.mode = mode
  Auth.data.salt = toHex(salt)
  Auth.data.hash = toHex(Auth.pbkdf2(secret, salt, tonumber(Auth.data.iter) or Auth.iterations))
  Auth.data.updated = os.time and os.time() or 0
  if not Auth.save() then return false, "Could not save credential" end
  return true
end

function Auth.changeUsername(username)
  if not Auth.data then return false, "Root is not configured" end
  username = Util.trim(Util.clean(username))
  if username == "" or #username > 24 then return false, "Invalid username" end
  Auth.data.username = username
  Auth.data.updated = os.time and os.time() or 0
  if not Auth.save() then return false, "Could not save username" end
  return true
end

function Auth.regenerateRecovery()
  local code, norm = Auth.generateRecoveryCode()
  local salt = Auth.randomBytes(16)
  Auth.data.recoverySalt = toHex(salt)
  Auth.data.recoveryHash = toHex(Auth.pbkdf2(norm, salt, tonumber(Auth.data.iter) or Auth.iterations))
  if not Auth.save() then return nil end
  return code
end

function Auth.login(secret)
  if Auth.verify(secret) then
    Auth.root = true
    Auth.rootAt = Util.now()
    return true
  end
  return false
end

function Auth.lock()
  Auth.root = false
  Auth.rootAt = 0
  if App and App.onLock then App.onLock() end
end

function Auth.touch()
  if Auth.root then Auth.rootAt = Util.now() end
end

function Auth.isRoot()
  if not Auth.root then return false end
  local minutes = App and App.cfg and App.cfg.autoLock or 5
  if minutes and minutes > 0 and (Util.now() - Auth.rootAt) > minutes * 60 then
    Auth.lock()
    if UI and UI.toast then UI.toast("Root session locked", "warning") end
    return false
  end
  return true
end

function Auth.username()
  return Auth.data and Auth.data.username or "root"
end

function Auth.mode()
  return Auth.data and Auth.data.mode or "pin"
end

--======== 80_audio.lua ========
------------------------------------------------------------------ audio engine
-- DFPWM -> PCM -> speaker.playAudio.  No standard "SPK" backend exists in
-- CC:Tweaked: the only standard stream is speaker.playAudio(PCM) at 48 kHz,
-- fed here by cc.audio.dfpwm.  Playback is pumped from the event loop, never
-- coupled to drawing.  The decoded PCM is also analysed for the visualiser.
Audio = {}
Audio.SR = 48000
Audio.CHUNK = 2048 -- DFPWM bytes = 16384 samples = ~0.34 s
Audio.speakers = {}
Audio.track = nil
Audio.fh = nil
Audio.decoder = nil
Audio.pending = nil
Audio.accepted = {}
Audio.queuedSamples = 0
Audio.startPos = 0
Audio.pos = 0
Audio.started = false
Audio.eof = false
Audio.paused = true
Audio.ended = false
Audio.loaded = false
Audio.reason = ""
Audio.lastTick = 0
Audio.lastPump = 0
-- speaker.playAudio volume 0..3 (Config.MAX_VOLUME); higher travels farther.
Audio.MAX_VOLUME = (Config and Config.MAX_VOLUME) or 3.0
Audio.volume = 1.0
Audio.muted = false
Audio.viz = {
  bands = { 0, 0, 0, 0, 0, 0, 0, 0 },
  target = { 0, 0, 0, 0, 0, 0, 0, 0 },
  wave = {},
  rms = 0, peak = 0, active = false, lastUpdate = 0,
}
Audio.bandFreqs = { 60, 120, 250, 500, 1000, 2000, 4000, 8000 }
Audio.bandCoef = {}

function Audio.init()
  local ok, mod = pcall(require, "cc.audio.dfpwm")
  if ok and type(mod) == "table" and type(mod.make_decoder) == "function" then
    Audio.dfpwm = mod
    Audio.loaded = true
    Audio.reason = "cc.audio.dfpwm ready"
  else
    Audio.loaded = false
    Audio.reason = "cc.audio.dfpwm unavailable (CC:Tweaked 1.100+ required)"
  end
  for _, f in ipairs(Audio.bandFreqs) do
    Audio.bandCoef[#Audio.bandCoef + 1] = 2 * math.cos(2 * math.pi * f / Audio.SR)
  end
  Audio.MAX_VOLUME = (Config and Config.MAX_VOLUME) or Audio.MAX_VOLUME or 3.0
  Audio.volume = App.cfg and App.cfg.volume or 1.0
  Audio.muted = App.cfg and App.cfg.muted or false
  Audio.scan()
  Audio.lastTick = Util.now()
end

function Audio.speakerEnabled(name)
  local cfg = App.cfg
  if not cfg then return true end
  local v = cfg.speakerEnabled[name]
  return v ~= false
end

function Audio.speakerGain(name)
  local cfg = App.cfg
  local g = cfg and cfg.speakerGain and cfg.speakerGain[name]
  return Util.clamp(tonumber(g) or 1, 0, 1)
end

function Audio.scan()
  local old = {}
  for _, sp in ipairs(Audio.speakers) do old[sp.name] = sp end
  local list = {}
  local ok, names = pcall(peripheral.getNames)
  if ok and names then
    for _, name in ipairs(names) do
      local typeOk, typ = pcall(peripheral.getType, name)
      if typeOk and typ == "speaker" then
        local wrapOk, dev = pcall(peripheral.wrap, name)
        if wrapOk and dev and type(dev.playAudio) == "function" then
          local oldSp = old[name]
          list[#list + 1] = {
            name = name,
            dev = dev,
            dead = false,
            enabled = Audio.speakerEnabled(name),
            gain = Audio.speakerGain(name),
          }
          old[name] = nil
        end
      end
    end
  end
  Audio.speakers = list
  Audio.newSpeakers = old
  if App.cfg then
    for _, sp in ipairs(list) do
      if App.cfg.speakerEnabled[sp.name] == nil then App.cfg.speakerEnabled[sp.name] = true end
      if App.cfg.speakerGain[sp.name] == nil then App.cfg.speakerGain[sp.name] = 1 end
    end
  end
  return #list
end

function Audio.liveCount()
  local n = 0
  for _, sp in ipairs(Audio.speakers) do
    if not sp.dead and sp.enabled then n = n + 1 end
  end
  return n
end

function Audio.liveSpeakers()
  local out = {}
  for _, sp in ipairs(Audio.speakers) do
    if not sp.dead and sp.enabled then out[#out + 1] = sp end
  end
  return out
end

function Audio.stopSpeakers()
  for _, sp in ipairs(Audio.speakers) do
    pcall(function() sp.dev.stop() end)
  end
end

-- speaker.stop() only sets a flag; the server clears dfpwmState on the next
-- tick. playAudio before that either sees a full buffer (returns false) or
-- queues audio that the pending stop then wipes.
--
-- NEVER sleep()/pullEvent here: nested yields inside App.tick eat the main
-- timer (and other events), which stalls Audio.tick and breaks next-song
-- advance. Wait is expressed as Audio._kickWait ticks instead.
function Audio.yieldForStop()
  -- Intentionally empty. Callers that just stopped speakers must arm
  -- Audio.armKickstart(..., true) so the next Audio.tick waits one frame.
end

function Audio.effectiveVolume()
  return Audio.muted and 0 or Util.clamp(Audio.volume, 0, Audio.MAX_VOLUME)
end

-- CC:Tweaked playAudio volume is always 0..3 (hear distance + loudness).
function Audio.playLevel(sp)
  local vol = Audio.effectiveVolume()
  local gain = Util.clamp(tonumber(sp and sp.gain) or 1, 0, 1)
  return Util.clamp(vol * gain, 0, 3)
end

function Audio.volumeFrac()
  local maxV = Audio.MAX_VOLUME
  if not maxV or maxV <= 0 then maxV = 3 end
  return Util.clamp(Audio.volume / maxV, 0, 1)
end

function Audio.volumeLabel()
  return string.format("%d%%", math.floor(Audio.volume * 100 + 0.5))
end

function Audio.closeStream()
  if Audio.fh then pcall(function() Audio.fh.close() end) end
  Audio.fh = nil
  Audio.pending = nil
  Audio.accepted = {}
  Audio.eof = false
  Audio.started = false
  Audio.queuedSamples = 0
  Audio.ended = false
end

function Audio.resetStream(sec)
  Audio.closeStream()
  if not Audio.track then return false, "no track" end
  if not Audio.loaded then return false, Audio.reason end
  local ok, f = pcall(fs.open, Audio.track.path, "rb")
  if not ok or not f then return false, "cannot open file" end
  Audio.fh = f
  Audio.decoder = Audio.dfpwm.make_decoder()
  local byte = math.floor(Util.clamp(sec or 0, 0, math.max(0, Audio.track.dur - 0.02)) * Audio.SR / 8)
  if byte > 0 then pcall(function() f.seek("set", byte) end) end
  Audio.startPos = byte * 8 / Audio.SR
  Audio.pos = Audio.startPos
  Audio.queuedSamples = 0
  Audio.started = false
  Audio.paused = true
  Audio.ended = false
  return true
end

function Audio.loadTrack(track, sec)
  Audio.track = track
  Audio.pos = Util.clamp(sec or 0, 0, track and track.dur or 0)
  return Audio.resetStream(Audio.pos)
end

-- Arm a non-blocking kickstart. Each Audio.tick pumps once until started or
-- tries are exhausted. waitOneTick=true after speaker.stop() so the server
-- can clear dfpwmState before the first playAudio.
function Audio.armKickstart(maxTries, waitOneTick)
  Audio._kickTries = maxTries or 12
  Audio._kickWait = waitOneTick and 1 or 0
  Audio._kickFail = nil
end

function Audio.clearKickstart()
  Audio._kickTries = 0
  Audio._kickWait = 0
end

-- One pump attempt for an armed kickstart. Returns "pending", "ok", or "fail".
function Audio.kickstartStep()
  if not Audio._kickTries or Audio._kickTries <= 0 then return "ok" end
  if Audio.paused or not Audio.track or not Audio.fh then
    Audio.clearKickstart()
    return "fail"
  end
  if Audio._kickWait and Audio._kickWait > 0 then
    Audio._kickWait = Audio._kickWait - 1
    return "pending"
  end
  if Audio.liveCount() == 0 then
    Audio._kickFail = "no speakers attached"
    Audio.clearKickstart()
    Audio.paused = true
    return "fail"
  end
  Audio.pump(1)
  if Audio.started then
    Audio.clearKickstart()
    Audio._kickFail = nil
    return "ok"
  end
  if Audio.eof and not Audio.pending then
    if Audio.reason and Audio.reason ~= "" and Audio.reason ~= "cc.audio.dfpwm ready" then
      Audio._kickFail = Audio.reason
    else
      Audio._kickFail = "empty or invalid audio"
    end
    Audio.clearKickstart()
    Audio.paused = true
    return "fail"
  end
  Audio._kickTries = Audio._kickTries - 1
  if Audio._kickTries <= 0 then
    Audio._kickFail = "could not start playback"
    Audio.clearKickstart()
    Audio.paused = true
    return "fail"
  end
  return "pending"
end

-- Legacy sync name: arm only (no nested sleep). Actual start happens in tick.
function Audio.kickstart(maxTries)
  Audio.armKickstart(maxTries or 12, false)
  return true
end

function Audio.playTrack(track, from, silent)
  if not track then return false, "no track" end
  if not Audio.loaded then return false, Audio.reason end
  Audio.scan()
  if Audio.liveCount() == 0 then return false, "no speakers attached" end
  Audio.track = track
  Audio.paused = true
  Audio.clearKickstart()
  Audio._pendingAdvance = false
  Audio.stopSpeakers()
  local ok, err = Audio.resetStream(from or 0)
  if not ok then return false, err end
  Audio.paused = false
  -- Defer first playAudio one tick so stop() has cleared the speaker buffer.
  -- Queue a wake event so kickstart still runs if the main timer was lost.
  Audio.armKickstart(12, true)
  os.queueEvent("speaker_audio_empty")
  Audio.viz.active = true
  return true
end

function Audio.pause()
  if not Audio.track then return end
  Audio.pos = Audio.position()
  Audio.paused = true
  Audio.clearKickstart()
  Audio.stopSpeakers()
  Audio.closeStream()
  Audio.viz.active = false
end

function Audio.resume()
  if not Audio.track then return false end
  Audio.scan()
  if Audio.liveCount() == 0 then return false, "no speakers attached" end
  Audio.clearKickstart()
  Audio.stopSpeakers()
  local ok, err = Audio.resetStream(Audio.pos)
  if not ok then return false, err end
  Audio.paused = false
  Audio.armKickstart(12, true)
  os.queueEvent("speaker_audio_empty")
  Audio.viz.active = true
  return true
end

function Audio.stop()
  Audio.pause()
  Audio.stopSpeakers()
  Audio.closeStream()
  Audio.track = nil
  Audio.pos = 0
  Audio.viz.active = false
end

function Audio.seek(sec)
  if not Audio.track then return end
  sec = Util.clamp(tonumber(sec) or 0, 0, math.max(0, Audio.track.dur - 0.05))
  local wasPlaying = not Audio.paused
  Audio.pos = sec
  if wasPlaying then
    Audio.clearKickstart()
    Audio._pendingAdvance = false
    Audio.stopSpeakers()
    local ok = Audio.resetStream(sec)
    if ok then
      Audio.paused = false
      Audio.armKickstart(8, true)
      os.queueEvent("speaker_audio_empty")
    end
  else
    Audio.closeStream()
  end
  Audio.viz.active = wasPlaying
end

function Audio.position()
  if not Audio.track then return 0 end
  return Util.clamp(Audio.pos, 0, Audio.track.dur)
end

function Audio.setVolume(v)
  Audio.volume = Util.clamp(tonumber(v) or Audio.volume, 0, Audio.MAX_VOLUME)
  if App.cfg then App.cfg.volume = Audio.volume; Config.saveSoon() end
  -- Smooth volume: do NOT stop/resync/relevel. playAudio volume is applied
  -- per chunk in Audio.pump via playLevel(); already-queued PCM keeps its
  -- old level for a fraction of a second, then new chunks use the new level.
end

function Audio.setMuted(m)
  Audio.muted = m and true or false
  if App.cfg then App.cfg.muted = Audio.muted; Config.saveSoon() end
  -- Same as setVolume: mute flag is read by playLevel() on the next pump.
  -- No stop/restart — avoids the audible stop-then-play glitch.
end

function Audio.toggleMute()
  Audio.setMuted(not Audio.muted)
end

function Audio.analyze(samples)
  local n = #samples
  if n == 0 then return end
  local sumSq, peak = 0, 0
  for i = 1, n do
    local v = samples[i] or 0
    sumSq = sumSq + v * v
    local a = v < 0 and -v or v
    if a > peak then peak = a end
  end
  local rms = math.sqrt(sumSq / n) / 128
  Audio.viz.rms = Util.clamp(rms * 3.2, 0, 1)
  Audio.viz.peak = Util.clamp(peak / 128, 0, 1)

  local window = 256
  local frames = 4
  local step = math.max(1, math.floor((n - window) / frames))
  if step < window then step = window end
  local bands = {}
  for b = 1, 8 do
    local coef = Audio.bandCoef[b]
    local energy = 0
    for fr = 0, frames - 1 do
      local off = fr * step
      if off + window > n then break end
      local s0, s1 = 0, 0
      for k = 1, window do
        local x = (samples[off + k] or 0) / 128
        local s2 = x + coef * s0 - s1
        s1 = s0
        s0 = s2
      end
      local p = s0 * s0 + s1 * s1 - coef * s0 * s1
      if p > 0 then energy = energy + p end
    end
    energy = energy / (window * window * frames)
    local v = math.log(1 + energy * 900) / 7.2
    bands[b] = Util.clamp(v, 0, 1)
  end
  Audio.viz.target = bands

  -- Waveform: 32 peak samples across the chunk.
  local wave = {}
  local seg = math.max(1, math.floor(n / 32))
  for i = 1, 32 do
    local m = 0
    local base = (i - 1) * seg + 1
    for k = 0, seg - 1 do
      local v = samples[base + k]
      if v then
        local a = v < 0 and -v or v
        if a > m then m = a end
      end
    end
    wave[i] = m / 128
  end
  Audio.viz.wave = wave
  Audio.viz.lastUpdate = Util.now()
  Audio.viz.active = true
end

function Audio.smoothViz(dt)
  local viz = Audio.viz
  local playing = (not Audio.paused) and Audio.viz.active
  for i = 1, 8 do
    local target = playing and (viz.target[i] or 0) or 0
    local cur = viz.bands[i] or 0
    if target > cur then
      cur = cur + (target - cur) * math.min(1, dt * 22)
    else
      cur = cur + (target - cur) * math.min(1, dt * 7)
    end
    viz.bands[i] = cur
  end
  if not playing then
    viz.rms = (viz.rms or 0) * 0.92
    viz.peak = (viz.peak or 0) * 0.96
    for i = 1, #viz.wave do viz.wave[i] = (viz.wave[i] or 0) * 0.9 end
  end
end

function Audio.pump(maxPushes)
  if Audio.paused or not Audio.track or not Audio.fh then return 0 end
  if not Audio.loaded then return 0 end
  local live = Audio.liveSpeakers()
  if #live == 0 then return 0 end
  local pushes = 0
  maxPushes = maxPushes or 1
  for _ = 1, maxPushes do
    if not Audio.pending then
      if Audio.eof then break end
      local chunk = Audio.fh.read(Audio.CHUNK)
      if not chunk or #chunk == 0 then
        Audio.eof = true
        break
      end
      local ok, decoded = pcall(Audio.decoder, chunk)
      if not ok or type(decoded) ~= "table" or #decoded == 0 then
        Audio.eof = true
        Audio.reason = "DFPWM decode error"
        Store.log("DFPWM decode failed on " .. tostring(Audio.track and Audio.track.path))
        break
      end
      Audio.pending = decoded
      Audio.accepted = {}
      Audio.analyze(decoded)
    end
    local all = true
    local acceptedAny = false
    for _, sp in ipairs(Audio.speakers) do
      if not sp.dead and sp.enabled then
        if Audio.accepted[sp.name] then
          acceptedAny = true
        else
          -- Broadcast same PCM chunk to every enabled speaker (wired + adjacent).
          -- playAudio volume must be a finite 0..3 (CC API), independent of UI max.
          local level = Audio.playLevel(sp)
          local ok, accepted = pcall(sp.dev.playAudio, Audio.pending, level)
          if not ok then
            sp.dead = true
            all = false
            if UI and UI.toast then UI.toast("Speaker disconnected: " .. sp.name, "danger") end
          elseif accepted then
            Audio.accepted[sp.name] = true
            acceptedAny = true
          else
            all = false
          end
        end
      end
    end
    -- Finish the chunk only when every live speaker has accepted (or died).
    -- Require at least one acceptance so a total failure cannot mark started.
    if all and acceptedAny then
      Audio.queuedSamples = Audio.queuedSamples + #Audio.pending
      Audio.pending = nil
      Audio.accepted = {}
      pushes = pushes + 1
      -- Do not snap Audio.pos to startPos here: a volume relevel clears
      -- started while keeping the open stream, and an old startPos of 0
      -- would restart the song from the beginning.
      if not Audio.started then
        Audio.started = true
      end
    else
      break
    end
  end
  Audio.lastPump = Util.now()
  return pushes
end

-- Playhead has caught the decoded buffer (normal end path).
function Audio.bufferDrained()
  if Audio.paused or not Audio.track then return false end
  if not Audio.eof or Audio.pending then return false end
  local remaining = (Audio.queuedSamples / Audio.SR) - (Audio.pos - Audio.startPos)
  return remaining <= 0.03
end

-- Mark track finished once. onEnd is deferred so callers can finish their
-- event/tick work before Player.next → playTrack runs.
function Audio.markEnded()
  if Audio.ended or Audio.paused or not Audio.track then return false end
  Audio.ended = true
  Audio._pendingAdvance = true
  -- Snap playhead to the real buffered end (may exceed declared dur).
  local bufferedEnd = Audio.startPos + (Audio.queuedSamples / Audio.SR)
  if Audio.pos < bufferedEnd then Audio.pos = bufferedEnd end
  if Audio.track.dur and Audio.track.dur > 0 and Audio.pos > Audio.track.dur then
    Audio.pos = Audio.track.dur
  end
  return true
end

function Audio.checkEnded()
  if Audio.ended or Audio.paused or not Audio.track then return false end
  if not Audio.bufferDrained() then return false end
  return Audio.markEnded()
end

-- Run deferred queue advance (end-of-track → Player.next).
function Audio.flushAdvance()
  if not Audio._pendingAdvance then return end
  Audio._pendingAdvance = false
  if Audio.onEnd then pcall(Audio.onEnd) end
end

function Audio.handleKickFailure()
  if not Audio._kickFail then return end
  local err = Audio._kickFail
  Audio._kickFail = nil
  if Player then Player.paused = true end
  if UI and UI.toast then
    UI.toast("Cannot play: " .. tostring(err), "danger")
  end
  if UI and UI.request then UI.request(true) end
end

-- speaker_audio_empty is the reliable end signal when Audio.tick has stalled
-- (legacy nested sleep ate the main timer): speakers drained, nothing left to
-- decode → advance the queue even if the playhead never caught up.
function Audio.onSpeakerEmpty()
  local kick = Audio.kickstartStep()
  if kick == "fail" then
    Audio.handleKickFailure()
    return
  end
  if kick == "pending" then return end
  if Audio.paused or not Audio.track then return end
  local pushed = Audio.pump(2)
  if Audio.eof and not Audio.pending and pushed == 0 then
    Audio.markEnded()
  else
    Audio.checkEnded()
  end
  Audio.flushAdvance()
end

function Audio.tick(dt)
  local now = Util.now()
  if not Audio.lastTick or Audio.lastTick == 0 then Audio.lastTick = now end
  dt = Util.clamp(now - Audio.lastTick, 0, 5)
  Audio.lastTick = now

  -- Drive non-blocking kickstart before normal pump/position work.
  local kick = Audio.kickstartStep()
  if kick == "fail" then
    Audio.handleKickFailure()
  end

  if not Audio.track then
    Audio.smoothViz(dt)
    return
  end
  if not Audio.paused and Audio.started then
    -- Advance playhead against buffered PCM, NOT clamped to declared dur.
    -- Clamping to track.dur left remaining > 0 forever when metadata was
    -- short/zero, so onEnd never fired and the queue sat idle after EOF.
    local available = (Audio.queuedSamples / Audio.SR) - (Audio.pos - Audio.startPos)
    if available > 0 then
      Audio.pos = Audio.pos + math.min(dt, available)
    end
  end
  -- Skip an extra pump while a kickstart wait/retry owns the stream.
  if not (Audio._kickTries and Audio._kickTries > 0) then
    Audio.pump(1)
  end
  Audio.smoothViz(dt)
  Audio.checkEnded()
  if not Audio.paused and Audio.liveCount() == 0 then
    if Audio.onNoSpeakers then pcall(Audio.onNoSpeakers) end
  end
  Audio.flushAdvance()
end

-- Volume/mute must NOT stop speakers. Kept as a no-op so older call sites
-- that still invoke relevel() cannot reintroduce stop-then-play.
function Audio.relevel()
  -- playLevel() is consulted on every playAudio; nothing else to do.
end

-- Full reopen + seek (speaker set changes, recovery). Not used for volume.
function Audio.resync()
  if Audio.paused or not Audio.track then return end
  local pos = Audio.position()
  Audio.clearKickstart()
  Audio._pendingAdvance = false
  Audio.stopSpeakers()
  local ok = Audio.resetStream(pos)
  if ok then
    Audio.paused = false
    Audio.armKickstart(8, true)
    os.queueEvent("speaker_audio_empty")
  end
end

function Audio.setSpeakerEnabled(name, enabled)
  if not App.cfg then return end
  App.cfg.speakerEnabled[name] = enabled and true or false
  Config.saveSoon()
  for _, sp in ipairs(Audio.speakers) do
    if sp.name == name then sp.enabled = enabled and true or false end
  end
  if Audio.liveCount() == 0 and not Audio.paused then
    Audio.pause()
    if Player and Player.syncPaused then Player.syncPaused() end
    if UI then UI.toast("No enabled speakers - playback paused", "warning") end
  end
end

function Audio.setSpeakerGain(name, gain)
  if not App.cfg then return end
  gain = Util.clamp(gain, 0, 1)
  App.cfg.speakerGain[name] = gain
  Config.saveSoon()
  for _, sp in ipairs(Audio.speakers) do
    if sp.name == name then sp.gain = gain end
  end
end

function Audio.testTone()
  local tone = {}
  local n = math.floor(Audio.SR * 0.16)
  for i = 0, n - 1 do
    local env = math.min(1, i / 800) * math.min(1, (n - i) / 2000)
    tone[#tone + 1] = math.floor(math.sin(2 * math.pi * 660 * i / Audio.SR) * 70 * env)
  end
  return tone
end

function Audio.testSpeaker(name)
  local tone = Audio.testTone()
  local tested = 0
  for _, sp in ipairs(Audio.speakers) do
    if (not name) or sp.name == name then
      local ok, accepted = pcall(sp.dev.playAudio, tone, 0.7)
      if ok and accepted then tested = tested + 1 end
    end
  end
  return tested
end

function Audio.speakerLabel(name)
  return tostring(name or "?")
end

function Audio.statsLine()
  local n = Audio.liveCount()
  return string.format("%d Hz · DFPWM · %d speaker%s", Audio.SR, n, n == 1 and "" or "s")
end

--======== 85_player.lua ========
------------------------------------------------------------------ player / queue
Player = {}
Player.queue = {}
Player.qorder = {}
Player.qpos = 0
Player.cur = nil
Player.curEntry = nil
Player.source = ""
Player.paused = true
Player.pos = 0
Player.uid = 0
Player.fails = 0
Player.shuffle = false
Player.repeatMode = "off"
Player.sessionDue = 0
Player.lastSessionSave = 0

function Player.nextUid()
  Player.uid = Player.uid + 1
  return Player.uid
end

function Player.mkEntry(track)
  return { track = track, uid = Player.nextUid() }
end

function Player.saveSession()
  local paths = {}
  for _, e in ipairs(Player.qorder) do
    if e and e.track then paths[#paths + 1] = e.track.path end
  end
  local data = {
    version = 2,
    queue = paths,
    qpos = Player.qpos,
    current = Player.cur and Player.cur.path or nil,
    pos = Player.position(),
    paused = true,
    shuffle = Player.shuffle,
    repeatMode = Player.repeatMode,
    source = Player.source,
  }
  Store.saveSoon("session", data)
  Player.sessionDue = Util.now() + 1.2
end

function Player.saveSessionNow()
  local paths = {}
  for _, e in ipairs(Player.qorder) do
    if e and e.track then paths[#paths + 1] = e.track.path end
  end
  Store.save("session", {
    version = 2,
    queue = paths,
    qpos = Player.qpos,
    current = Player.cur and Player.cur.path or nil,
    pos = Player.position(),
    paused = true,
    shuffle = Player.shuffle,
    repeatMode = Player.repeatMode,
    source = Player.source,
  })
end

function Player.loadSession()
  local data = Store.load("session", nil) or Data.legacySession
  Player.shuffle = App.cfg.shuffle == true
  Player.repeatMode = App.cfg.repeatMode or "off"
  Player.queue, Player.qorder = {}, {}
  Player.cur, Player.curEntry = nil, nil
  Player.qpos = 0
  Player.source = "Queue"
  if type(data) ~= "table" then
    return false
  end
  if type(data.source) == "string" then Player.source = data.source end
  local entries = {}
  if type(data.queue) == "table" then
    for _, path in ipairs(data.queue) do
      local t = Data.byPath[path]
      if t then entries[#entries + 1] = Player.mkEntry(t) end
    end
  end
  Player.queue = entries
  Player.qorder = {}
  for i, e in ipairs(entries) do Player.qorder[i] = e end
  Player.qpos = Util.clamp(tonumber(data.qpos) or 1, 1, math.max(1, #entries))

  local cur = type(data.current) == "string" and Data.byPath[data.current] or nil
  if cur then
    Player.cur = cur
    for _, e in ipairs(Player.queue) do
      if e.track == cur then Player.curEntry = e; break end
    end
    if not Player.curEntry then
      Player.curEntry = Player.mkEntry(cur)
      table.insert(Player.queue, Player.curEntry)
      table.insert(Player.qorder, Player.curEntry)
      Player.qpos = #Player.qorder
    end
    Player.pos = Util.clamp(tonumber(data.pos) or 0, 0, cur.dur)
    Audio.track = cur
    Audio.pos = Player.pos
    Audio.paused = true
    Player.paused = true
    return true
  end
  Player.paused = true
  return false
end

function Player.rebuildAfterScan()
  local curPath = Player.cur and Player.cur.path or nil
  local pos = Player.position()
  local wasPlaying = not Player.paused
  if wasPlaying then pcall(Audio.pause) end
  local orderPaths = {}
  for _, e in ipairs(Player.qorder) do
    if e.track then orderPaths[#orderPaths + 1] = e.track.path end
  end
  local oldQpos = Player.qpos

  local entries = {}
  for _, path in ipairs(orderPaths) do
    local t = Data.byPath[path]
    if t then entries[#entries + 1] = Player.mkEntry(t) end
  end
  Player.queue = {}
  for i, e in ipairs(entries) do Player.queue[i] = e end
  Player.qorder = entries
  Player.qpos = Util.clamp(oldQpos, 1, math.max(1, #entries))

  if curPath then
    local t = Data.byPath[curPath]
    if t then
      Player.cur = t
      Player.curEntry = nil
      for _, e in ipairs(Player.queue) do
        if e.track == t then Player.curEntry = e; break end
      end
      if not Player.curEntry then
        Player.curEntry = Player.mkEntry(t)
        table.insert(Player.queue, Player.curEntry)
        table.insert(Player.qorder, Player.curEntry)
        Player.qpos = #Player.qorder
      end
      Audio.track = t
      Audio.pos = Util.clamp(pos, 0, t.dur)
      Audio.paused = true
      Player.paused = true
    else
      Player.cur, Player.curEntry = nil, nil
      Audio.stop()
    end
  end
  Player.saveSession()
end

function Player.buildOrder(startEntry)
  local order = {}
  for i, e in ipairs(Player.queue) do order[i] = e end
  if Player.shuffle then
    for i = #order, 2, -1 do
      local j = math.random(i)
      order[i], order[j] = order[j], order[i]
    end
    if startEntry then
      local idx = Util.indexOf(order, startEntry)
      if idx then order[1], order[idx] = order[idx], order[1] end
    end
  end
  Player.qorder = order
  if startEntry then
    Player.qpos = Util.indexOf(order, startEntry) or 1
  else
    Player.qpos = 1
  end
end

function Player.playContext(tracks, index, label)
  if not tracks or #tracks == 0 then
    UI.toast("Nothing to play", "warning")
    return false
  end
  Player.source = label or "Queue"
  Player.queue = {}
  for _, t in ipairs(tracks) do Player.queue[#Player.queue + 1] = Player.mkEntry(t) end
  local startEntry = Player.queue[index] or Player.queue[1]
  Player.buildOrder(startEntry)
  return Player.playEntryAt(Player.qpos)
end

function Player.playShuffled(tracks, label)
  if not tracks or #tracks == 0 then
    UI.toast("Nothing to play", "warning")
    return false
  end
  Player.shuffle = true
  App.cfg.shuffle = true
  Config.saveSoon()
  Player.source = label or "Queue"
  Player.queue = {}
  for _, t in ipairs(tracks) do Player.queue[#Player.queue + 1] = Player.mkEntry(t) end
  local startEntry = Player.queue[math.random(#Player.queue)]
  Player.buildOrder(startEntry)
  return Player.playEntryAt(Player.qpos)
end

function Player.playEntryAt(pos, from)
  local entry = Player.qorder[pos]
  if not entry or not entry.track then
    Player.stop(true)
    return false
  end
  local track = entry.track
  if not fs.exists(track.path) then
    track.missing = true
    UI.toast("Missing file: " .. Util.fit(track.title, 24), "danger")
    Player.fails = Player.fails + 1
    if Player.fails < #Player.qorder then
      return Player.next(true)
    end
    Player.stop(true)
    return false
  end
  Player.qpos = pos
  Player.curEntry = entry
  Player.cur = track
  Player.fails = 0
  Audio.track = track
  Audio.pos = from or 0
  local stayVideo = Video.musicStay == true
  Video.musicStay = false
  local ok, err = Audio.playTrack(track, from or 0)
  if ok then
    Player.paused = false
    Data.addRecent(track)
    Audio.viz.active = true
    -- Arm sibling .cvid for delayed handoff (or immediate stay after NEXT/BACK).
    if Video.armForTrack then Video.armForTrack(track, { stay = stayVideo }) end
  else
    Player.paused = true
    Audio.paused = true
    Audio.pos = from or 0
    if Video.clearMusic then Video.clearMusic() end
    if err == "no speakers attached" then
      UI.toast("No speakers attached - press play after connecting one", "warning")
    else
      UI.toast("Cannot play: " .. tostring(err), "danger")
    end
  end
  Player.saveSession()
  UI.request(true)
  return ok
end

function Player.syncPaused()
  Player.paused = Audio.paused
  Audio.viz.active = not Audio.paused
end

function Player.togglePause()
  if not Player.cur then
    if #Player.qorder > 0 then
      Player.playEntryAt(Player.qpos > 0 and Player.qpos or 1)
    elseif #Data.tracks > 0 then
      Player.playContext(Data.tracks, 1, "All Songs")
    else
      UI.toast("Library is empty", "warning")
    end
    return
  end
  if Player.paused or Audio.paused then
    local ok, err = Audio.resume()
    if ok then
      Player.paused = false
      Audio.viz.active = true
    else
      Player.paused = true
      UI.toast("Cannot play: " .. tostring(err or "unknown"), "danger")
    end
  else
    Audio.pause()
    Player.paused = true
    Audio.viz.active = false
  end
  Player.saveSession()
  UI.request(true)
end

function Player.stop(silent)
  Audio.stop()
  Player.cur, Player.curEntry = nil, nil
  Player.paused = true
  Audio.paused = true
  Audio.pos = 0
  Player.pos = 0
  if Video.clearMusic then Video.clearMusic() end
  Player.saveSession()
  if not silent then UI.toast("Stopped", "info") end
  UI.request(true)
end

function Player.seek(sec)
  if not Player.cur then return end
  Audio.seek(sec)
  Audio.viz.active = not Audio.paused
  Player.saveSession()
  UI.request(true)
end

function Player.seekBy(delta)
  Player.seek(Audio.position() + (tonumber(delta) or 0))
end

function Player.next(auto)
  if #Player.qorder == 0 then
    Player.stop(true)
    return false
  end
  if auto and Player.repeatMode == "one" and Player.curEntry then
    if Video.musicActive then Video.musicStay = true end
    return Player.playEntryAt(Player.qpos)
  end
  local np = Player.qpos + 1
  if np > #Player.qorder then
    -- Only stop at true end-of-queue when auto-advancing with repeat off.
    -- Manual next wraps; repeat all/one keeps going.
    if auto and Player.repeatMode == "off" then
      Player.stop(true)
      UI.toast("End of queue", "info")
      return false
    end
    if Player.shuffle then
      local cur = Player.curEntry
      Player.buildOrder(nil)
      if #Player.qorder > 1 and cur and Player.qorder[1] == cur then
        Player.qorder[1], Player.qorder[2] = Player.qorder[2], Player.qorder[1]
      end
    end
    np = 1
  end
  -- Stay in music-video mode across tracks that also have a .cvid pack.
  if Video.musicActive then Video.musicStay = true end
  Player.qpos = np
  return Player.playEntryAt(np)
end

function Player.prev()
  if not Player.cur then return end
  if Audio.position() > 3 then
    Player.seek(0)
    if Video.musicActive and Video.syncToAudio then Video.syncToAudio(); UI.request(true) end
  else
    local np = Player.qpos - 1
    if np < 1 then np = #Player.qorder end
    if np >= 1 then
      if Video.musicActive then Video.musicStay = true end
      Player.playEntryAt(np)
    end
  end
end

function Player.toggleShuffle()
  Player.shuffle = not Player.shuffle
  App.cfg.shuffle = Player.shuffle
  Config.saveSoon()
  if Player.curEntry then
    Player.buildOrder(Player.curEntry)
  elseif #Player.queue > 0 then
    Player.buildOrder(nil)
  end
  Player.saveSession()
  UI.toast(Player.shuffle and "Shuffle on" or "Shuffle off", "info")
  UI.request(true)
end

function Player.cycleRepeat()
  if Player.repeatMode == "off" then Player.repeatMode = "all"
  elseif Player.repeatMode == "all" then Player.repeatMode = "one"
  else Player.repeatMode = "off" end
  App.cfg.repeatMode = Player.repeatMode
  Config.saveSoon()
  Player.saveSession()
  UI.toast("Repeat: " .. Player.repeatMode:upper(), "info")
  UI.request(true)
end

function Player.setVolume(v)
  Audio.setVolume(v)
  UI.request(true)
end

function Player.setMuted(m)
  Audio.setMuted(m)
  UI.request(true)
end

function Player.position()
  if Player.cur then return Audio.position() end
  return 0
end

function Player.queueAdd(track, playNext)
  if not track then return end
  local entry = Player.mkEntry(track)
  Player.queue[#Player.queue + 1] = entry
  if playNext and Player.curEntry then
    table.insert(Player.qorder, Player.qpos + 1, entry)
  else
    Player.qorder[#Player.qorder + 1] = entry
  end
  if not Player.cur then
    Player.qpos = math.max(1, Player.qpos)
    Player.playEntryAt(Player.qpos)
  end
  Player.saveSession()
  UI.toast((playNext and "Queued next: " or "Added to queue: ") .. track.title, "info")
  UI.request(true)
end

function Player.queueAddMany(tracks, playNext)
  if not tracks then return end
  for _, t in ipairs(tracks) do
    local entry = Player.mkEntry(t)
    Player.queue[#Player.queue + 1] = entry
    if playNext and Player.curEntry then
      table.insert(Player.qorder, Player.qpos + 1, entry)
    else
      Player.qorder[#Player.qorder + 1] = entry
    end
  end
  if not Player.cur and #Player.qorder > 0 then
    Player.qpos = math.max(1, Player.qpos)
    Player.playEntryAt(Player.qpos)
  end
  Player.saveSession()
  UI.request(true)
end

function Player.queueRemove(entry)
  if not entry then return end
  local qi = Util.indexOf(Player.queue, entry)
  local oi = Util.indexOf(Player.qorder, entry)
  local wasCurrent = entry == Player.curEntry
  if qi then table.remove(Player.queue, qi) end
  if oi then
    table.remove(Player.qorder, oi)
    if oi < Player.qpos then Player.qpos = Player.qpos - 1 end
  end
  if wasCurrent then
    if #Player.qorder == 0 then
      Player.stop(true)
    else
      Player.qpos = Util.clamp(Player.qpos, 1, #Player.qorder)
      Player.playEntryAt(Player.qpos)
    end
  else
    Player.qpos = Util.clamp(Player.qpos, 1, math.max(1, #Player.qorder))
  end
  Player.saveSession()
  UI.request(true)
end

function Player.moveQueue(index, dir)
  local j = index + dir
  if index < 1 or index > #Player.qorder or j < 1 or j > #Player.qorder then return false end
  Player.qorder[index], Player.qorder[j] = Player.qorder[j], Player.qorder[index]
  if Player.qpos == index then Player.qpos = j
  elseif Player.qpos == j then Player.qpos = index end
  Player.saveSession()
  UI.request(true)
  return true
end

function Player.clearQueue()
  Audio.stop()
  Player.queue, Player.qorder = {}, {}
  Player.qpos = 0
  Player.cur, Player.curEntry = nil, nil
  Player.paused = true
  Player.saveSession()
  UI.toast("Queue cleared", "info")
  UI.request(true)
end

function Player.playAll()
  if #Data.tracks == 0 then UI.toast("Library is empty", "warning"); return end
  Player.playContext(Data.tracks, 1, "All Songs")
end

function Player.shuffleAll()
  if #Data.tracks == 0 then UI.toast("Library is empty", "warning"); return end
  Player.playShuffled(Data.tracks, "Library")
end

function Player.init()
  Player.shuffle = App.cfg.shuffle == true
  Player.repeatMode = App.cfg.repeatMode or "off"
  local restored = Player.loadSession()
  Audio.onEnd = function() Player.next(true) end
  Audio.onNoSpeakers = function()
    if not Player.paused then
      Audio.pause()
      Player.paused = true
      UI.toast("Audio output lost - playback paused", "warning")
      UI.request(true)
    end
  end
  if Player.cur then
    Player.paused = true
    Audio.paused = true
  end
  return restored
end

function Player.queueNumber()
  if #Player.qorder == 0 then return "0 / 0" end
  return tostring(Player.qpos) .. " / " .. tostring(#Player.qorder)
end

--======== 86_video.lua ========
------------------------------------------------------------------ CVID video
-- Compact CVID1 container:
--   5 bytes magic, u8 version, u16 width, u16 height (cells),
--   u32 frameCount, u16 defaultDurationMs, 16 * RGB palette,
--   frameCount fixed-size frames (2 bytes per cell), duration table (u16 each).
-- Each cell is [mask 0..31][fg high nibble, bg low nibble].  The mask uses the
-- same 2x3 sextant geometry as the rest of AURORA.
Video = {}
Video.magic = "CVID1"
Video.headerSize = 64
Video.loaded = false
Video.playing = false
Video.fullscreen = false
Video.showControls = true
Video.position = 0
Video.frame = 1
Video.lastNow = nil
Video.cells = {}
Video.cacheFrame = 0
Video.files = {}
Video.error = nil

local function u16(s, i) return (s:byte(i) or 0) + (s:byte(i + 1) or 0) * 256 end
local function u32(s, i)
  return (s:byte(i) or 0) + (s:byte(i + 1) or 0) * 256 + (s:byte(i + 2) or 0) * 65536 + (s:byte(i + 3) or 0) * 16777216
end
local function rgbSlot(r, g, b)
  local best, bestD = Theme.C.text, math.huge
  for i = 0, 15 do
    local pr, pg, pb = Util.rgbParts(Theme.rgb[i] or 0)
    local d = (r - pr) ^ 2 + (g - pg) ^ 2 + (b - pb) ^ 2
    if d < bestD then bestD, best = d, i end
  end
  return best
end

function Video.close()
  Video.data = nil
  Video.loaded = false
  Video.playing = false
  Video.path = nil
  Video.cells = {}
  Video.cacheFrame = 0
  Video.position = 0
  Video.frame = 1
end

function Video.load(path)
  local data = Store.readRaw(path)
  if not data or #data < Video.headerSize then Video.error = "Cannot read video"; return false end
  -- Load cap 48 MiB (safety). Default encode is 160×45 @ 8 fps so ~3 min packs
  -- stay under the ~20 MiB CC disk limit (Escape ~141s ≈15.5 MiB).
  if #data > 48 * 1024 * 1024 then Video.error = "Video file is too large"; return false end
  if data:sub(1, 5) ~= Video.magic then Video.error = "Not a CVID1 file"; return false end
  local version = data:byte(6) or 0
  if version ~= 1 then Video.error = "Unsupported CVID version"; return false end
  local w, h = u16(data, 7), u16(data, 9)
  local frames = u32(data, 11)
  local defaultMs = u16(data, 15)
  -- Cap above wall (~270×60); default packs use 160×45 under the ~20 MiB disk budget.
  if w < 1 or h < 1 or w > 320 or h > 120 or frames < 1 or frames > 30000 then
    Video.error = "Invalid video dimensions"
    return false
  end
  local cellBytes = w * h * 2
  local durationAt = Video.headerSize + frames * cellBytes + 1
  if #data < durationAt + frames * 2 - 1 then Video.error = "Truncated CVID file"; return false end
  local palette = {}
  for i = 0, 15 do
    local o = 17 + i * 3
    palette[i] = rgbSlot(data:byte(o) or 0, data:byte(o + 1) or 0, data:byte(o + 2) or 0)
  end
  local durations, starts, total = {}, {}, 0
  for i = 1, frames do
    local ms = u16(data, durationAt + (i - 1) * 2)
    if ms <= 0 then ms = defaultMs > 0 and defaultMs or 100 end
    durations[i] = ms
    starts[i] = total
    total = total + ms
  end
  starts[frames + 1] = total
  Video.data = data
  Video.path = path
  Video.w, Video.h = w, h
  Video.frames = frames
  Video.cellBytes = cellBytes
  Video.frameSize = cellBytes
  Video.durationAt = durationAt
  Video.defaultMs = defaultMs
  Video.durations = durations
  Video.starts = starts
  Video.total = total
  Video.palette = palette
  Video.position = 0
  Video.frame = 1
  Video.cacheFrame = 0
  Video.playing = false
  Video.loaded = true
  Video.error = nil
  return true
end

function Video.frameFor(ms)
  if not Video.loaded then return 1 end
  local lo, hi = 1, Video.frames
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if (Video.starts[mid] or 0) <= ms then lo = mid else hi = mid - 1 end
  end
  return Util.clamp(lo, 1, Video.frames)
end

function Video.seek(ms)
  if not Video.loaded then return end
  Video.position = Util.clamp(ms or 0, 0, Video.total)
  Video.frame = Video.frameFor(Video.position)
  Video.cacheFrame = 0
  Video.lastNow = Video.playing and Util.now() or nil
  UI.request(true)
end

function Video.play()
  if not Video.loaded then return end
  if Video.position >= Video.total then Video.position = 0; Video.frame = 1; Video.cacheFrame = 0 end
  Video.playing = true
  Video.lastNow = Util.now()
  UI.request(true)
end

function Video.pause()
  if Video.loaded then Video.position = Util.clamp(Video.position, 0, Video.total) end
  Video.playing = false
  Video.lastNow = nil
  UI.request(true)
end

function Video.toggle()
  if Video.playing then Video.pause() else Video.play() end
end

function Video.tick(now)
  if not Video.loaded or not Video.playing then return end
  now = now or Util.now()
  if not Video.lastNow then Video.lastNow = now; return end
  local before = Video.frame
  Video.position = Video.position + (now - Video.lastNow) * 1000
  Video.lastNow = now
  if Video.position >= Video.total then
    Video.position = Video.total
    Video.frame = Video.frames
    Video.playing = false
    Video.lastNow = nil
    UI.request(true)
  else
    Video.frame = Video.frameFor(Video.position)
  end
  if Video.frame ~= before then
    Video.cacheFrame = 0
    UI.request()
  end
end

function Video.open(path)
  if not path or path == "" then return false end
  local ok = Video.load(path)
  if ok then
    Video.fullscreen = false
    Video.showControls = true
    UI.toast("Video loaded", "success")
  else
    UI.toast(Video.error or "Cannot open video", "danger")
  end
  UI.request(true)
  return ok
end

function Video.decode()
  if not Video.loaded or Video.cacheFrame == Video.frame then return end
  local cells = {}
  local base = Video.headerSize + (Video.frame - 1) * Video.frameSize
  local data = Video.data
  local n = 0
  for cy = 1, Video.h do
    for cx = 1, Video.w do
      local o = base + n * 2 + 1
      local mask = (data:byte(o) or 0) % 32
      local colors = data:byte(o + 1) or 0
      local fg = math.floor(colors / 16) % 16
      local bg = colors % 16
      n = n + 1
      cells[n] = {
        ch = string.char(128 + mask),
        fg = Video.palette[fg] or Theme.C.text,
        bg = Video.palette[bg] or Theme.C.bg,
      }
    end
  end
  Video.cells = cells
  Video.cacheFrame = Video.frame
end

function Video.draw(x, y, w, h, fill)
  if not Video.loaded or w < 1 or h < 1 then return end
  Video.decode()
  if fill or w < Video.w or h < Video.h then
    for dy = 0, h - 1 do
      local sy = math.min(Video.h, math.floor(dy * Video.h / h) + 1)
      for dx = 0, w - 1 do
        local sx = math.min(Video.w, math.floor(dx * Video.w / w) + 1)
        local c = Video.cells[(sy - 1) * Video.w + sx]
        if c then Canvas:set(x + dx, y + dy, c.ch, c.fg, c.bg) end
      end
    end
    return
  end
  local scale = math.min(math.floor(w / Video.w), math.floor(h / Video.h))
  if scale < 1 then scale = 1 end
  local dw, dh = Video.w * scale, Video.h * scale
  local ox = x + math.floor((w - dw) / 2)
  local oy = y + math.floor((h - dh) / 2)
  for cy = 1, Video.h do
    for cx = 1, Video.w do
      local c = Video.cells[(cy - 1) * Video.w + cx]
      if c then
        for sy = 0, scale - 1 do
          for sx = 0, scale - 1 do
            local px, py = ox + (cx - 1) * scale + sx, oy + (cy - 1) * scale + sy
            if px >= x and px < x + w and py >= y and py < y + h then
              Canvas:set(px, py, c.ch, c.fg, c.bg)
            end
          end
        end
      end
    end
  end
end

function Video.timeText(ms)
  return Util.fmtTime((ms or 0) / 1000)
end

function Video.scanFiles()
  local out, seen = {}, {}
  local dirs = { "videos", "Videos", fs.combine(Store.dir or ".aurora", "videos") }
  for _, root in ipairs(App.cfg.roots or {}) do
    dirs[#dirs + 1] = root
    dirs[#dirs + 1] = fs.combine(root, "videos")
  end
  local function add(p)
    if not seen[p] and fs.exists(p) and not fs.isDir(p) and p:lower():match("%.cvid$") then
      seen[p] = true
      out[#out + 1] = p
    end
  end
  local function scan(dir, depth)
    if depth > 2 then return end
    local ok, entries = pcall(fs.list, dir)
    if not ok or not entries then return end
    for _, name in ipairs(entries) do
      local p = fs.combine(dir, name)
      if fs.isDir(p) then scan(p, depth + 1) else add(p) end
    end
  end
  for _, dir in ipairs(dirs) do
    if fs.exists(dir) then
      if fs.isDir(dir) then scan(dir, 0) else add(dir) end
    end
  end
  table.sort(out)
  Video.files = out
  return out
end

function Video.ensure()
  if Video.loaded then return true end
  local files = Video.files
  if #files == 0 then files = Video.scanFiles() end
  if #files > 0 then return Video.load(files[1]) end
  return false
end

------------------------------------------------------------------ music-video handoff (CTJP-12)
-- Play the normal now-playing UI first; after videoDelaySec, switch THIS
-- monitor to the sibling .cvid while DFPWM audio keeps running.  Right-click
-- (or SONG) dismisses back to the song screen for the rest of the track.
-- NEXT/BACK keep video mode when the neighbour track also has a .cvid.
Video.musicActive = false
Video.musicArmed = false
Video.musicDismissed = false
Video.musicStay = false
Video.musicTrackPath = nil

function Video.cvidBeside(dfpwmPath)
  if type(dfpwmPath) ~= "string" or dfpwmPath == "" then return nil end
  local base = dfpwmPath:gsub("%.[Dd][Ff][Pp][Ww][Mm]$", "")
  local candidates = { base .. ".cvid", base .. ".CVID" }
  for _, p in ipairs(candidates) do
    if fs.exists(p) and not fs.isDir(p) then return p end
  end
  return nil
end

function Video.clearMusic()
  Video.musicActive = false
  Video.musicArmed = false
  Video.musicDismissed = false
  Video.musicTrackPath = nil
  Video.musicStay = false
  if Video.loaded and Video.path and tostring(Video.path):lower():match("%.cvid$") then
    -- Only close when we were driving a music-video pack (leave standalone Video app alone
    -- if the user opened a different file on the Video screen).
    if App.screen ~= "video" then Video.close() end
  end
end

function Video.syncToAudio()
  if not Video.loaded then return end
  local ms = math.floor((Audio.position() or 0) * 1000 + 0.5)
  Video.position = Util.clamp(ms, 0, Video.total or 0)
  Video.frame = Video.frameFor(Video.position)
  Video.cacheFrame = 0
  Video.playing = false
  Video.lastNow = nil
end

function Video.armForTrack(track, opts)
  opts = opts or {}
  local stay = opts.stay == true
  Video.musicDismissed = false
  Video.musicTrackPath = track and track.path or nil
  Video.musicArmed = false
  Video.musicActive = false
  if not track or not App.cfg or App.cfg.musicVideo == false then
    if App.screen ~= "video" then Video.close() end
    return false
  end
  local path = Video.cvidBeside(track.path)
  if not path then
    if App.screen ~= "video" then Video.close() end
    return false
  end
  if not Video.load(path) then
    return false
  end
  Video.musicArmed = true
  if stay then
    Video.musicActive = true
    Video.syncToAudio()
  end
  return true
end

function Video.dismissMusic()
  if not Video.musicActive then return false end
  Video.musicActive = false
  Video.musicDismissed = true
  UI.request(true)
  return true
end

function Video.musicTick()
  if not Video.musicArmed or Video.musicDismissed then return end
  if not Player.cur or Player.paused then return end
  if App.cfg and App.cfg.musicVideo == false then return end
  if Video.musicActive then
    local before = Video.frame
    Video.syncToAudio()
    if Video.frame ~= before then UI.request() end
    return
  end
  local delay = tonumber(App.cfg and App.cfg.videoDelaySec) or 3.5
  if (Audio.position() or 0) >= delay then
    Video.musicActive = true
    Video.syncToAudio()
    UI.request(true)
  end
end

--======== 87_apps.lua ========
------------------------------------------------------------------ app registry
Apps = {}
Apps.list = {
  { id = "music",     name = "Music",     short = "MUSIC",  icon = "music",   screen = "music",     color = Theme.C.accent },
  { id = "library",   name = "Library",   short = "LIB",    icon = "library", screen = "library",   color = Theme.C.blue },
  { id = "search",    name = "Search",    short = "FIND",   icon = "search",  screen = "search",    color = Theme.C.ice or Theme.C.accentLight },
  { id = "playlists", name = "Playlists", short = "LISTS",  icon = "playlist",screen = "playlists", color = Theme.C.violet },
  { id = "video",     name = "Video",     short = "VIDEO",  icon = "video",   screen = "video",     color = Theme.C.rose or Theme.C.pink },
  { id = "gallery",   name = "Gallery",   short = "GAL",    icon = "gallery", screen = "gallery",   color = Theme.C.green },
  { id = "files",     name = "Files",     short = "FILES",  icon = "folder",  screen = "files",     color = Theme.C.amber },
  { id = "notes",     name = "Notes",     short = "NOTES",  icon = "notes",   screen = "notes",     color = Theme.C.warning },
  { id = "notifications", name = "Notifications", short = "ALERTS", icon = "badge", screen = "notifications", color = Theme.C.accentLight },
  { id = "settings",  name = "Settings",  short = "SETUP",  icon = "settings",screen = "settings",  color = Theme.C.muted, protected = true },
}
Apps.byId = {}
for _, a in ipairs(Apps.list) do Apps.byId[a.id] = a end

function Apps.appForScreen(screen)
  if screen == "home" then return "home" end
  if screen == "music" or screen == "queue" or screen == "lyrics" then return "music" end
  if screen == "library" or screen == "album" or screen == "artist" then return "library" end
  if screen == "search" then return "search" end
  if screen == "playlists" or screen == "playlist" or screen == "playlistAdd" then return "playlists" end
  if screen == "video" then return "video" end
  if screen == "gallery" then return "gallery" end
  if screen == "files" then return "files" end
  if screen == "notes" or screen == "noteEdit" then return "notes" end
  if screen == "notifications" then return "notifications" end
  if screen == "settings" or (type(screen) == "string" and screen:match("^settings")) then return "settings" end
  if screen == "artwork" or screen == "artPicker" or screen == "metadata" or screen == "metaForm"
    or screen == "albumMeta" or screen == "lyricsManager" or screen == "lyricsPicker" then return "settings" end
  return nil
end

function Apps.open(id)
  local app = Apps.byId[id]
  if not app then return end
  if app.id == "settings" then
    UI.openSettings()
  elseif app.id == "lyrics" then
    if Player.cur then App.openLyrics(Player.cur) else UI.toast("Nothing playing", "warning") end
  else
    App.go(app.screen)
  end
end

function Apps.record(appId)
  if not appId or appId == "home" or not App.cfg then return end
  local list = App.cfg.recentApps or {}
  for i = #list, 1, -1 do if list[i] == appId then table.remove(list, i) end end
  table.insert(list, 1, appId)
  while #list > 6 do table.remove(list) end
  App.cfg.recentApps = list
  Config.saveSoon()
end

function Apps.recent()
  local out = {}
  for _, id in ipairs(App.cfg.recentApps or {}) do
    local app = Apps.byId[id]
    if app then out[#out + 1] = app end
  end
  return out
end

function Apps.switcher()
  local items = {}
  for _, app in ipairs(Apps.recent()) do
    items[#items + 1] = { label = app.name, sub = "Open application", icon = app.icon, value = app.id }
  end
  if #items == 0 then
    for _, app in ipairs(Apps.list) do
      if app.id ~= "settings" then items[#items + 1] = { label = app.name, icon = app.icon, value = app.id } end
    end
  else
    local hasNotifications = false
    for _, it in ipairs(items) do if it.value == "notifications" then hasNotifications = true end end
    if not hasNotifications then
      items[#items + 1] = { label = "Notifications", sub = "Recent alerts and events", icon = "badge", value = "notifications" }
    end
  end
  UI.actions("RECENT APPLICATIONS", items, function(value) if value then Apps.open(value) end end, {
    message = "Tap an application to switch to it.",
  })
end

function Apps.clockText()
  local t = os.time and os.time() or 0
  local ok, s = pcall(os.date, "%H:%M", t)
  return ok and s or "--:--"
end

function Apps.dateText()
  local t = os.time and os.time() or 0
  local ok, s = pcall(os.date, "%a %d %b", t)
  return ok and s or ""
end

--======== 90_ui_core.lua ========
------------------------------------------------------------------ UI framework
UI = {}
UI.hits = {}
UI.layer = 0
UI.keyboard = nil
UI.modal = nil
UI.toasts = {}
UI.notifications = {}
UI.feedback = nil
UI.drag = nil
UI.m = nil
UI.dirty = true
UI.force = true
UI.nextDraw = 0
UI.lastDraw = 0
UI.nextClock = 0
UI.lastTap = 0
UI.loginFailures = 0
UI.loginBlockedUntil = 0
UI.navLabels = { home = "HOME", music = "MUSIC", library = "LIBRARY", search = "SEARCH", playlists = "LISTS", lyrics = "LYRICS" }

-- Floppy used/free meter (title bar on every screen). Same logic as pre-Aurora
-- three-panel jukebox: unique disk/diskN mounts, 4s refresh, non-blocking.
UI.diskSpaceInterval = 4
UI.diskSpace = { free = 0, used = 0, drives = 0, label = "", short = "", lastCheck = 0 }

function UI.request(force)
  UI.dirty = true
  if force then UI.force = true end
end

function UI.refreshDiskSpace(force)
  local t = Util.now()
  local ds = UI.diskSpace
  if not force and ds.lastCheck > 0 and (t - ds.lastCheck) < UI.diskSpaceInterval then
    return false
  end
  ds.lastCheck = t

  local seen, totalFree, totalUsed, nDrives = {}, 0, 0, 0

  local function consider(mount)
    if not mount or seen[mount] or not fs.exists(mount) then return end
    -- Only floppy mounts (disk / disk2 / …), not the computer HDD or ROM
    if not mount:match("^disk%d*$") then return end
    seen[mount] = true

    local okFree, free = pcall(fs.getFreeSpace, mount)
    if not okFree or type(free) ~= "number" then return end
    local okCap, cap = pcall(fs.getCapacity, mount)
    local used = (okCap and type(cap) == "number") and math.max(0, cap - free) or 0

    totalFree = totalFree + free
    totalUsed = totalUsed + used
    nDrives = nDrives + 1
  end

  -- Prefer live mount scan (any diskN + drive peripherals); roots as fallback.
  if Config.listFloppyMounts then
    for _, mount in ipairs(Config.listFloppyMounts()) do
      consider(mount)
    end
  end
  local roots = (App.cfg and App.cfg.roots) or Config.defaultRoots or {}
  for _, root in ipairs(roots) do
    local mount = tostring(root):match("^(disk%d*)")
    if mount then consider(mount) end
  end

  ds.free = totalFree
  ds.used = totalUsed
  ds.drives = nDrives
  if nDrives == 0 then
    ds.label = "no disks"
    ds.short = "no disks"
  else
    -- Label matches pre-Aurora three-panel meter (ASCII "-" survives Util.clean).
    ds.label = string.format("%s used - %s free", Util.fmtSize(totalUsed), Util.fmtSize(totalFree))
    ds.short = string.format("%s/%s", Util.fmtSize(totalUsed), Util.fmtSize(totalFree))
    if nDrives > 1 then
      ds.label = ds.label .. string.format(" (%d disks)", nDrives)
      ds.short = ds.short .. string.format(" (%d)", nDrives)
    end
  end
  return true
end

function UI.toast(message, kind)
  message = Util.clean(message)
  if message == "" then return end
  local now = Util.now()
  UI.toasts[#UI.toasts + 1] = { text = message, kind = kind or "info", start = now, until_ = now + 3.4 }
  UI.notifications[#UI.notifications + 1] = { text = message, kind = kind or "info", at = now }
  while #UI.toasts > 3 do table.remove(UI.toasts, 1) end
  while #UI.notifications > 20 do table.remove(UI.notifications, 1) end
  UI.request(true)
end

function UI.hit(x, y, w, h, fn, opts)
  if w <= 0 or h <= 0 then return end
  UI.hits[#UI.hits + 1] = {
    x1 = math.floor(x), y1 = math.floor(y),
    x2 = math.floor(x + w - 1), y2 = math.floor(y + h - 1),
    fn = fn, layer = (opts and opts.layer) or UI.layer,
    cursor = opts and opts.cursor,
  }
end

function UI.feedbackAt(x, y)
  UI.feedback = { x = x, y = y, until_ = Util.now() + 0.09, screen = App.screen }
end

function UI.tap(x, y)
  Auth.touch()
  UI.feedbackAt(x, y)
  local blocking = UI.keyboard ~= nil or UI.modal ~= nil
  for i = #UI.hits, 1, -1 do
    local h = UI.hits[i]
    if (not blocking or h.layer >= 10)
      and x >= h.x1 and x <= h.x2 and y >= h.y1 and y <= h.y2 then
      local ok, err = pcall(h.fn, x, y)
      if not ok then
        Store.logError("touch", err)
        UI.toast("Touch action failed", "danger")
      end
      UI.request(true)
      return true
    end
  end
  UI.request(true)
  return false
end

function UI.metrics(showNav, showMini)
  local w, h = Canvas.w, Canvas.h
  local ui = 1.2
  local m = {}
  m.w, m.h = w, h
  m.compact = w < 40 or h < 24
  m.pad = Util.clamp(Util.round(1.35 * ui), 1, 3)
  m.gap = Util.clamp(Util.round(0.75 * ui), 1, 2)
  m.topH = h >= 24 and 3 or 2
  m.navH = showNav and (h >= 24 and 4 or 3) or 0
  m.miniH = showMini and 3 or 0
  m.contentX = m.pad + 1
  m.contentW = w - m.pad * 2
  m.bodyTop = m.topH + 1
  m.bodyBot = h - m.navH - m.miniH
  m.bodyH = math.max(1, m.bodyBot - m.bodyTop + 1)
  m.rowH = Util.clamp(Util.round(3.1 * ui), 3, 5)
  m.btnH = Util.clamp(Util.round(3.1 * ui), 3, 5)
  m.railW = 4
  m.art = {}
  return m
end

function UI.drawTopBar(m, opts)
  opts = opts or {}
  local w, h = Canvas.w, Canvas.h
  local top = m.topH
  Canvas:roundRect(1, 1, w, top, 1, Theme.C.surface, Theme.C.bg)
  local rightX = w - m.pad - 4
  local titleX = m.pad + 1
  local minimize = opts.minimize
  local home = opts.home

  UI.refreshDiskSpace(false)
  local spaceFull = (UI.diskSpace and UI.diskSpace.label) or ""
  local spaceShort = (UI.diskSpace and UI.diskSpace.short) or spaceFull
  local function spaceToast()
    local ds = UI.diskSpace
    if not ds or ds.drives == 0 then
      UI.toast("No floppy disks attached", "warning")
    else
      UI.toast(ds.label, "info")
    end
  end

  if m.compact then
    local settingsFn = opts.settings or function() UI.openSettings() end
    local left = m.pad
    if opts.back then
      Canvas:roundRect(left, 1, 4, 2, 1, Theme.C.surface2, Theme.C.surface)
      Canvas:icon("back5", left, 1, 4, 2, Theme.C.text, 1)
      UI.hit(left, 1, 4, 2, opts.back)
      left = left + 4
    end
    if home then
      Canvas:roundRect(left, 1, 4, 2, 1, Theme.C.surface2, Theme.C.surface)
      Canvas:icon("home5", left, 1, 4, 2, Theme.C.text, 1)
      UI.hit(left, 1, 4, 2, home)
      left = left + 4
    end
    if not opts.back and not home then
      Canvas:text(m.pad, 1, "CC MUSIC", Theme.C.text, Theme.C.surface)
      left = m.pad + 7
    end
    titleX = left + 1
    local recentX = rightX - (minimize and 11 or 7)
    local spaceShown = ""
    if spaceShort ~= "" and recentX - titleX > #spaceShort + 2 then
      spaceShown = spaceShort
      Canvas:textRight(titleX, 1, recentX - titleX - 1, spaceShown, Theme.C.dim, Theme.C.surface)
      UI.hit(math.max(titleX, recentX - #spaceShown - 1), 1, #spaceShown + 1, 2, spaceToast)
    end
    Canvas:roundRect(recentX, 1, 4, 2, 1, Theme.C.surface2, Theme.C.surface)
    Canvas:icon("grid", recentX, 1, 4, 2, Theme.C.muted, 1)
    UI.hit(recentX, 1, 4, 2, Apps.switcher)
    if minimize then
      local mx = rightX - 5
      Canvas:roundRect(mx, 1, 4, 2, 1, Theme.C.surface2, Theme.C.surface)
      Canvas:icon("minimize5", mx, 1, 4, 2, Theme.C.text, 1)
      UI.hit(mx, 1, 4, 2, minimize)
    end
    Canvas:roundRect(rightX, 1, 4, 2, 1, Theme.C.surface2, Theme.C.surface)
    if opts.lock then
      Canvas:icon("lock", rightX, 1, 4, 2, Theme.C.warning, 1)
      UI.hit(rightX, 1, 4, 2, opts.lock)
    else
      Canvas:icon("settings5", rightX, 1, 4, 2, Auth.isRoot() and Theme.C.accent or Theme.C.muted, 1)
      UI.hit(rightX, 1, 4, 2, settingsFn)
    end
    if opts.title and opts.title ~= "" and spaceShown == "" then
      Canvas:textFit(titleX, 1, math.max(3, rightX - (minimize and 5 or 0) - titleX - 8), opts.title, Theme.C.muted, Theme.C.surface)
    end
    return
  end

  local left = m.pad
  if opts.back then
    Canvas:roundRect(left, 1, 5, top, 1, Theme.C.surface2, Theme.C.surface)
    Canvas:icon("back", left, 1, 5, top, Theme.C.text, 1)
    UI.hit(left, 1, 5, top, opts.back)
    left = left + 6
  end
  if home then
    Canvas:roundRect(left, 1, 5, top, 1, Theme.C.surface2, Theme.C.surface)
    Canvas:icon("home", left, 1, 5, top, Theme.C.text, 1)
    UI.hit(left, 1, 5, top, home)
    left = left + 6
  end
  if not opts.back and not home then
    Canvas:icon("music", m.pad, 1, 3, top, Theme.C.accent, 1)
    Canvas:text(m.pad + 4, 2, "CC MUSIC", Theme.C.text, Theme.C.surface)
    left = m.pad + 12
  end
  titleX = left

  local mx = minimize and (rightX - 6) or nil
  -- Speaker status (informational), left of minimize/settings
  local live = Audio.liveCount()
  local spX = (minimize and (mx - 7) or (rightX - 7))

  -- Disk used/free, left of speaker (prefer full label; fall back to short)
  local spaceLabel = ""
  local spaceGap = 0
  if spaceFull ~= "" then
    local avail = math.max(0, spX - titleX - 2)
    if avail >= #spaceFull then
      spaceLabel = spaceFull
    elseif avail >= #spaceShort and spaceShort ~= "" then
      spaceLabel = spaceShort
    elseif avail >= 8 then
      spaceLabel = Util.fit(spaceShort ~= "" and spaceShort or spaceFull, avail)
    end
    if spaceLabel ~= "" then spaceGap = #spaceLabel + 2 end
  end

  local tw = math.max(4, spX - titleX - 1 - spaceGap)
  if opts.title and opts.title ~= "" then
    Canvas:textFit(titleX, 2, tw, opts.title, Theme.C.muted, Theme.C.surface)
  end

  if spaceLabel ~= "" then
    local sx = spX - #spaceLabel - 1
    Canvas:text(sx, 2, spaceLabel, Theme.C.dim, Theme.C.surface)
    UI.hit(sx, 1, #spaceLabel, top, spaceToast)
  end

  local col = live > 0 and Theme.C.accent or Theme.C.warning
  Canvas:pdisc((spX - 1) * 2 + 1, 1, 2, 2, col)
  Canvas:text(spX + 1, 2, tostring(live), live > 0 and Theme.C.muted or Theme.C.warning, Theme.C.surface)
  UI.hit(spX, 1, 6, top, function()
    UI.toast(live > 0 and (Audio.statsLine()) or "No speakers attached", live > 0 and "info" or "warning")
  end)

  if minimize then
    Canvas:roundRect(mx, 1, 5, top, 1, Theme.C.surface2, Theme.C.surface)
    Canvas:icon("minimize", mx, 1, 5, top, Theme.C.text, 1)
    UI.hit(mx, 1, 5, top, minimize)
  end

  -- Settings / lock
  local settingsFn = opts.settings
  Canvas:roundRect(rightX, 1, 5, top, 1, Theme.C.surface2, Theme.C.surface)
  if opts.lock then
    Canvas:icon("lock", rightX, 1, 5, top, Theme.C.warning, 1)
    UI.hit(rightX, 1, 5, top, opts.lock)
  else
    Canvas:icon("settings", rightX, 1, 5, top,
      Auth.isRoot() and Theme.C.accent or Theme.C.muted, 1)
    UI.hit(rightX, 1, 5, top, settingsFn or function() UI.openSettings() end)
  end

end

function UI.drawNav(m, active)
  if m.navH <= 0 then return end
  local w, h = Canvas.w, Canvas.h
  local y = h - m.navH + 1
  Canvas:roundRect(1, y, w, m.navH, 1, Theme.C.surface, Theme.C.bg)
  local compact = m.compact
  local labels = (not compact) and m.navH >= 4
  local narrow = w < 52
  local tabs = {
    { id = "home", icon = compact and "home5" or "home", label = "HOME" },
    { id = "music", icon = compact and "music5" or "music", label = "MUSIC" },
    { id = "library", icon = compact and "library5" or "library", label = narrow and "LIB" or "LIBRARY" },
    { id = "search", icon = compact and "search5" or "search", label = narrow and "FIND" or "SEARCH" },
    { id = "playlists", icon = compact and "playlist5" or "playlist", label = (w >= 55 and "PLAYLISTS" or "LISTS") },
    { id = "lyrics", icon = compact and "lyrics5" or "lyrics9", label = "LYRICS" },
  }
  local n = #tabs
  local iconH = labels and (m.navH - 1) or m.navH
  for i, tab in ipairs(tabs) do
    local x = math.floor((i - 1) * w / n) + 1
    local x2 = math.floor(i * w / n)
    local ww = math.max(1, x2 - x + 1)
    local isActive = active == tab.id
    local col = isActive and Theme.C.accent or Theme.C.dim
    local ix, iw = x, ww
    if compact and ww > 4 then
      iw = math.min(5, ww - 1)
      ix = x + math.floor((ww - iw) / 2)
    end
    Canvas:icon(tab.icon, ix, y, iw, iconH, col, 1)
    if labels then
      Canvas:textCenter(x, y + m.navH - 1, ww, tab.label, col, Theme.C.surface)
    end
    if isActive then
      local c = x + math.floor((ww - 3) / 2)
      Canvas:fill(c, y, 3, 1, Theme.C.accent)
    end
    UI.hit(x, y, ww, m.navH, function()
      if tab.id == "lyrics" then
        if Player.cur then App.openLyrics(Player.cur) else UI.toast("Nothing playing", "warning") end
      else
        App.goTab(tab.id)
      end
    end)
  end
end

function UI.drawMini(m)
  if m.miniH <= 0 or not Player.cur then return end
  local w, h = Canvas.w, Canvas.h
  local y = h - m.navH - 2
  local x = m.pad
  local ww = w - m.pad * 2
  if ww < 12 then return end
  Canvas:roundRect(x, y, ww, 3, 1, Theme.C.surface2, Theme.C.bg)
  local art = Art.forTrack(Player.cur, 4, 3)
  if art then Canvas:art(art, x + 1, y) end
  local tx = x + 6
  local btnW = 4
  local infoW = ww - 7 - btnW * 2 - 1
  Canvas:textFit(tx, y, infoW, Player.cur.title, Theme.C.text, Theme.C.surface2)
  Canvas:textFit(tx, y + 1, infoW, Player.cur.artist, Theme.C.muted, Theme.C.surface2)
  local frac = Player.cur.dur > 0 and (Player.position() / Player.cur.dur) or 0
  Canvas:fill(x + 1, y + 2, math.max(0, math.floor((ww - 2) * frac)), 1, Theme.C.accent)
  UI.hit(x, y, ww - btnW * 2, 3, function() App.go("music") end)
  local pbX = x + ww - btnW * 2
  Canvas:roundRect(pbX, y, btnW, 3, 1, Theme.C.accent, Theme.C.surface2)
  Canvas:icon(Player.paused and "playSmall" or "pauseSmall", pbX, y, btnW, 3, Theme.C.onAccent, 1)
  UI.hit(pbX, y, btnW, 3, function() Player.togglePause() end)
  Canvas:roundRect(pbX + btnW, y, btnW, 3, 1, Theme.C.surface, Theme.C.surface2)
  Canvas:icon("nextSmall", pbX + btnW, y, btnW, 3, Theme.C.text, 1)
  UI.hit(pbX + btnW, y, btnW, 3, function() Player.next(false) end)
end

-- opts: {title, subtitle, tab, back, hideNav, mini, settings, lock, rightText}
function UI.frame(opts)
  opts = opts or {}
  if opts.home == nil and opts.back and opts.hideNav then opts.home = function() App.goTab("home") end end
  if opts.minimize == nil and App.screen ~= "home" then opts.minimize = function() App.minimize() end end
  local showNav = not opts.hideNav
  local showMini = opts.mini ~= false and showNav and Player.cur ~= nil and App.screen ~= "home" and Canvas.h >= 22
  local m = UI.metrics(showNav, showMini)
  UI.m = m
  Canvas:fill(1, 1, Canvas.w, Canvas.h, Theme.C.bg)
  UI.drawTopBar(m, opts)
  if showNav then
    UI.drawNav(m, opts.tab or App.tab or "home")
    if showMini then UI.drawMini(m) end
  end
  return m
end

------------------------------------------------------------------ widgets
function UI.button(x, y, w, h, label, opts)
  opts = opts or {}
  local variant = opts.variant or "surface"
  local bg, fg
  if variant == "primary" then bg, fg = Theme.C.accent, Theme.C.onAccent
  elseif variant == "active" then bg, fg = Theme.C.accentDim, Theme.C.accentLight
  elseif variant == "danger" then bg, fg = Theme.C.danger, Theme.C.onAccent
  elseif variant == "ghost" then bg, fg = Theme.C.bg, Theme.C.text
  elseif variant == "surface2" then bg, fg = Theme.C.surface2, Theme.C.text
  else bg, fg = Theme.C.surface, Theme.C.text end
  if opts.active and variant ~= "danger" then bg, fg = Theme.C.accentDim, Theme.C.accentLight end
  local radius = opts.radius or math.min(h / 2, 2)
  if opts.outside then
    Canvas:roundRect(x, y, w, h, radius, bg, opts.outside)
  else
    Canvas:roundRect(x, y, w, h, radius, bg, Theme.C.bg)
  end
  local icon = opts.icon
  local text = Util.clean(label or "")
  if icon and text ~= "" then
    local iw = opts.iconW or 5
    Canvas:icon(icon, x + 1, y, iw, h, opts.iconColor or fg, 1)
    Canvas:textFit(x + iw + 1, y + math.floor((h - 1) / 2), math.max(1, w - iw - 1), text, fg, bg)
  elseif icon then
    Canvas:icon(icon, x, y, w, h, opts.iconColor or fg, 1)
  elseif text ~= "" then
    Canvas:textCenter(x + 1, y + math.floor((h - 1) / 2), w - 2, text, fg, bg)
  end
  if opts.fn then UI.hit(x, y, w, h, opts.fn) end
  return x + w
end

function UI.iconButton(x, y, w, h, icon, opts)
  opts = opts or {}
  return UI.button(x, y, w, h, "", {
    icon = icon, variant = opts.variant, active = opts.active,
    fn = opts.fn, radius = opts.radius, outside = opts.outside,
  })
end

function UI.chip(x, y, w, h, label, active, fn)
  local bg = active and Theme.C.accent or Theme.C.surface
  local fg = active and Theme.C.onAccent or Theme.C.muted
  Canvas:roundRect(x, y, w, h, h / 2, bg, Theme.C.bg)
  Canvas:textCenter(x, y + math.floor((h - 1) / 2), w, label, fg, bg)
  UI.hit(x, y, w, h, fn)
end

function UI.sectionTitle(x, y, w, label)
  Canvas:textFit(x, y, w, label, Theme.C.dim, Theme.C.bg)
  Canvas:fill(x, y + 1, w, 1, Theme.C.surface)
end

function UI.progressBar(x, y, w, h, frac, opts)
  opts = opts or {}
  frac = Util.clamp(frac or 0, 0, 1)
  Canvas:roundRect(x, y, w, h, h / 2, opts.bg or Theme.C.surface, Theme.C.bg)
  local fillW = math.floor(w * frac)
  if fillW > 0 then
    Canvas:roundRect(x, y, fillW, h, h / 2, opts.fg or Theme.C.accent, opts.bg or Theme.C.surface)
  end
  if opts.noThumb ~= true then
    local tx = x + math.floor(w * frac)
    tx = Util.clamp(tx, x + 1, x + w - 2)
    Canvas:pdisc((tx - 1) * 2 + 1, (y - 1) * 3 + h * 1.5, 2, 3, opts.thumb or Theme.C.text)
  end
  if opts.fn then
    UI.hit(x, y - 1, w, h + 2, function(px)
      local f = Util.clamp((px - x) / math.max(1, w - 1), 0, 1)
      opts.fn(f)
    end)
  end
end

function UI.slider(x, y, w, h, value, opts)
  opts = opts or {}
  value = Util.clamp(value or 0, 0, 1)
  UI.progressBar(x, y, w, h, value, {
    fg = opts.fg, bg = opts.bg, thumb = opts.thumb,
    fn = function(f) if opts.onChange then opts.onChange(f) end end,
  })
end

function UI.scrollRail(x, y, h, total, offset, visible, onScroll)
  if h < 3 then return end
  local compact = Canvas.w < 40
  local upIcon, downIcon = compact and "up5" or "up", compact and "down5" or "down"
  local railCol = Theme.C.surface
  Canvas:fill(x + 1, y + 2, 1, math.max(1, h - 4), railCol)
  if total > visible then
    local thumbH = Util.clamp(math.floor((h - 4) * visible / total), 2, h - 4)
    local maxOff = math.max(1, total - visible)
    local ty = y + 2 + math.floor((h - 4 - thumbH) * offset / maxOff)
    Canvas:fill(x + 1, ty, 1, thumbH, Theme.C.accent)
  end
  UI.iconButton(x, y, 3, 3, upIcon, { variant = "surface", fn = function() onScroll(-math.max(1, visible - 1)) end })
  UI.iconButton(x, y + h - 3, 3, 3, downIcon, { variant = "surface", fn = function() onScroll(math.max(1, visible - 1)) end })
  if total > visible then
    UI.hit(x + 1, y + 2, 1, h - 4, function()
      local half = y + math.floor(h / 2)
      onScroll(half >= y + h / 2 and visible - 1 or -(visible - 1))
    end)
  end
end

function UI.listRow(x, y, w, h, opts)
  opts = opts or {}
  local bg = opts.selected and Theme.C.accentDim or (opts.active and Theme.C.surface2 or Theme.C.surface)
  Canvas:roundRect(x, y, w, h, 1, bg, Theme.C.bg)
  local textX = x + 1
  if opts.art then
    Canvas:art(opts.art, x + 1, y + math.max(0, math.floor((h - opts.art.h) / 2)))
    textX = x + opts.art.w + 2
  end
  local rightW = opts.rightW or 0
  local titleW = w - (textX - x) - rightW - 1
  Canvas:textFit(textX, y + math.max(0, math.floor((h - 2) / 2)), titleW, opts.title or "", opts.titleColor or Theme.C.text, bg)
  if opts.sub and h >= 4 then
    Canvas:textFit(textX, y + math.max(0, math.floor((h - 2) / 2)) + 1, titleW, opts.sub, Theme.C.muted, bg)
  end
  if opts.right then
    Canvas:textRight(x + w - rightW - 1, y + math.max(0, math.floor((h - 1) / 2)), rightW, opts.right, Theme.C.dim, bg)
  end
  if opts.fn then UI.hit(x, y, w, h, opts.fn) end
  return bg, textX
end

function UI.badge(x, y, text, color)
  local w = #text + 2
  Canvas:roundRect(x, y, w, 1, 0, color, Theme.C.bg)
  Canvas:text(x + 1, y, text, Theme.C.bg, color)
  return w
end

function UI.emptyState(x, y, w, h, icon, title, subtitle)
  local cy = y + math.floor(h / 2) - 2
  Canvas:icon(icon, x, cy, w, 3, Theme.C.dim, 2)
  Canvas:textCenter(x, cy + 4, w, title, Theme.C.muted, Theme.C.bg)
  if subtitle then Canvas:textCenter(x, cy + 5, w, subtitle, Theme.C.dim, Theme.C.bg) end
end

------------------------------------------------------------------ overlay painting
function UI.drawToasts()
  local now = Util.now()
  local w = math.min(50, Canvas.w - 4)
  local x = math.floor((Canvas.w - w) / 2) + 1
  local bottom = Canvas.h - ((UI.m and UI.m.navH) or 0) - ((UI.m and UI.m.miniH) or 0) - 1
  local animations = not (App.cfg and App.cfg.animations == false)
  for i, t in ipairs(UI.toasts) do
    local age = now - t.start
    local slide = animations and math.min(1, age * 8) or 1
    local yy = bottom - (i - 1) * 3 - 1 + math.floor((1 - slide) * 2)
    local color = t.kind == "danger" and Theme.C.danger
      or t.kind == "warning" and Theme.C.warning
      or t.kind == "success" and Theme.C.green
      or Theme.C.accent
    Canvas:roundRect(x, yy, w, 2, 1, Theme.C.surface2, Theme.C.bg)
    Canvas:fill(x, yy, 1, 2, color)
    Canvas:textFit(x + 2, yy, w - 3, t.text, Theme.C.text, Theme.C.surface2)
  end
end

function UI.drawFeedback()
  if not UI.feedback then return end
  if Util.now() > UI.feedback.until_ or UI.feedback.screen ~= App.screen then UI.feedback = nil; return end
  local x, y = UI.feedback.x, UI.feedback.y
  if x >= 1 and y >= 1 and x <= Canvas.w and y <= Canvas.h then
    Canvas:fill(x, y, 1, 1, Theme.C.accentDim)
    Canvas:fill(math.max(1, x - 1), y, 1, 1, Theme.C.accent)
    Canvas:fill(math.min(Canvas.w, x + 1), y, 1, 1, Theme.C.accent)
  end
end

function UI.update(dt)
  local now = Util.now()
  local i = 1
  while i <= #UI.toasts do
    if now > UI.toasts[i].until_ then table.remove(UI.toasts, i) else i = i + 1 end
  end
  if UI.feedback and now > UI.feedback.until_ then UI.feedback = nil end
  if UI.keyboard then
    UI.keyboard.cursorOn = (math.floor(now * 2) % 2 == 0)
    UI.request()
  end
  if #UI.toasts > 0 or UI.feedback then UI.request() end
  if Player.cur and not Player.paused then UI.request() end
  if App.screen == "home" and now >= (UI.nextClock or 0) then
    UI.nextClock = now + 30
    UI.request()
  end
  -- Refresh disk used/free every diskSpaceInterval (non-blocking; redraw if changed)
  local prevSpace = UI.diskSpace and UI.diskSpace.label or ""
  if UI.refreshDiskSpace(false) and UI.diskSpace.label ~= prevSpace then
    UI.request()
  end
  if Auth.root and App.screen:match("^settings") then
    if not Auth.isRoot() then App.goTab("home") end
  end
end

function UI.draw()
  Canvas:begin()
  UI.hits = {}
  UI.layer = 0
  local ok, err = pcall(Screens.draw)
  if not ok then
    Store.logError("draw", err)
    Canvas:fill(1, 1, Canvas.w, Canvas.h, Theme.C.bg)
    Canvas:text(2, 2, "Something went wrong.", Theme.C.danger, Theme.C.bg)
    Canvas:text(2, 3, Util.fit(tostring(err), Canvas.w - 4), Theme.C.muted, Theme.C.bg)
  end
  UI.layer = 5
  UI.drawToasts()
  if UI.modal then
    UI.layer = 20
    local mok, merr = pcall(UI.drawModal)
    if not mok then Store.logError("modal", merr) end
  end
  if UI.keyboard then
    UI.layer = 30
    local kok, kerr = pcall(UI.drawKeyboard)
    if not kok then Store.logError("keyboard", kerr) end
  end
  UI.layer = 40
  UI.drawFeedback()
  local pok, perr = Canvas:present(App.term, UI.force)
  if not pok then
    Store.logError("present", perr)
    App.reinitDisplay()
    UI.force = true
    UI.dirty = true
    return
  end
  UI.force = false
  UI.dirty = false
  UI.lastDraw = Util.now()
end

function UI.drawNow(force)
  if force then UI.force = true end
  UI.draw()
end

function UI.wantsDraw(now)
  if UI.force then return true end
  if UI.dirty and now >= UI.nextDraw then return true end
  if Player.cur and not Player.paused and now - UI.lastDraw > 0.09 then return true end
  return false
end

--======== 91_ui_keyboard.lua ========
------------------------------------------------------------------ keyboard / dialogs
function UI.openKeyboard(opts)
  opts = opts or {}
  local mode = opts.mode or "text"
  local value = tostring(opts.value or "")
  UI.keyboard = {
    value = value,
    cursor = #value + 1,
    title = opts.title or "INPUT",
    label = opts.label or "",
    hint = opts.hint or "",
    secret = opts.secret == true,
    mode = mode,
    maxLen = opts.maxLen or (mode == "pin" and Auth.maxPin or 120),
    minLen = opts.minLen or 0,
    allowEmpty = opts.allowEmpty == true,
    onDone = opts.onDone,
    onCancel = opts.onCancel,
    onChange = opts.onChange,
    layout = "letters",
    shift = false,
    error = "",
    extra = opts.extra,
    fullscreen = opts.fullscreen == true,
    cursorOn = true,
  }
  UI.request(true)
end

function UI.closeKeyboard(callCancel)
  local kb = UI.keyboard
  UI.keyboard = nil
  if callCancel and kb and kb.onCancel then pcall(kb.onCancel) end
  UI.request(true)
end

function UI.setKeyboardError(msg)
  if UI.keyboard then
    UI.keyboard.error = Util.clean(msg or "")
    UI.request(true)
  end
end

function UI.keyboardInsert(ch)
  local kb = UI.keyboard
  if not kb or ch == "" then return end
  if #kb.value + #ch > kb.maxLen then return end
  local c = Util.clamp(kb.cursor, 1, #kb.value + 1)
  kb.value = kb.value:sub(1, c - 1) .. ch .. kb.value:sub(c)
  kb.cursor = c + #ch
  kb.error = ""
  UI.keyboardChanged()
  UI.request(true)
end

function UI.keyboardChanged()
  local kb = UI.keyboard
  if kb and kb.onChange then
    local ok, err = pcall(kb.onChange, kb.value)
    if not ok then Store.logError("keyboard change", err) end
  end
end

function UI.keyboardBackspace()
  local kb = UI.keyboard
  if not kb then return end
  local c = Util.clamp(kb.cursor, 1, #kb.value + 1)
  if c > 1 then
    kb.value = kb.value:sub(1, c - 2) .. kb.value:sub(c)
    kb.cursor = c - 1
  end
  kb.error = ""
  UI.keyboardChanged()
  UI.request(true)
end

function UI.keyboardDone()
  local kb = UI.keyboard
  if not kb then return end
  local v = kb.value
  if #v < kb.minLen then
    UI.setKeyboardError("Enter at least " .. kb.minLen .. " characters")
    return
  end
  if not kb.allowEmpty and v == "" then
    UI.setKeyboardError("A value is required")
    return
  end
  local ok, err
  if kb.onDone then
    local pok, a, b = pcall(kb.onDone, v)
    if not pok then
      Store.logError("keyboard callback", a)
      UI.setKeyboardError("Action failed")
      return
    end
    ok, err = a, b
  else
    ok = true
  end
  if ok == "keep" then
    return
  elseif ok then
    UI.closeKeyboard(false)
  else
    UI.setKeyboardError(err or "Invalid value")
  end
end

function UI.keyboardKey(token)
  local kb = UI.keyboard
  if not kb then return end
  if token == "cancel" then
    UI.closeKeyboard(true)
  elseif token == "done" then
    UI.keyboardDone()
  elseif token == "back" then
    UI.keyboardBackspace()
  elseif token == "clear" then
    kb.value = ""
    kb.cursor = 1
    kb.error = ""
    UI.keyboardChanged()
    UI.request(true)
  elseif token == "space" then
    UI.keyboardInsert(" ")
  elseif token == "shift" then
    kb.shift = not kb.shift
    UI.request(true)
  elseif token == "sym" then
    kb.layout = "symbols"
    UI.request(true)
  elseif token == "abc" then
    kb.layout = "letters"
    UI.request(true)
  elseif token == "extra" then
    local fn = kb.extra and kb.extra.fn
    UI.closeKeyboard(false)
    if fn then pcall(fn) end
  else
    local ch = token
    if kb.layout == "letters" and kb.shift and ch:match("^%a$") then ch = ch:upper() end
    UI.keyboardInsert(ch)
  end
end

function UI.keyboardRows()
  local kb = UI.keyboard
  if not kb then return {} end
  if kb.mode == "pin" then
    return {
      { { "1", "1" }, { "2", "2" }, { "3", "3" } },
      { { "4", "4" }, { "5", "5" }, { "6", "6" } },
      { { "7", "7" }, { "8", "8" }, { "9", "9" } },
      { { "clear", "CLR" }, { "0", "0" }, { "back", "DEL" } },
      { { "cancel", "ESC" }, { "done", "DONE", "primary" } },
    }
  end
  if Canvas.w < 40 or Canvas.h < 28 then
    local shift = kb.shift
    if kb.layout == "symbols" then
      return {
        { { "1", "1" }, { "2", "2" }, { "3", "3" }, { "4", "4" }, { "5", "5" }, { "6", "6" }, { "7", "7" }, { "8", "8" }, { "9", "9" }, { "0", "0" } },
        { { "-", "-" }, { "_", "_" }, { "/", "/" }, { ".", "." }, { ":", ":" }, { "?", "?" }, { "!", "!" }, { "@", "@" }, { "#", "#" }, { "%", "%" } },
        { { "(", "(" }, { ")", ")" }, { "'", "'" }, { '"', '"' }, { ";", ";" }, { ",", "," }, { "+", "+" }, { "=", "=" }, { "&", "&" }, { "*", "*" } },
        { { "abc", "ABC", "special" }, { "back", "DEL", "special" }, { "space", "SPACE", "space" }, { "cancel", "ESC", "special" }, { "done", "OK", "primary" } },
      }
    end
    return {
      { { "q", shift and "Q" or "q" }, { "w", shift and "W" or "w" }, { "e", shift and "E" or "e" }, { "r", shift and "R" or "r" }, { "t", shift and "T" or "t" }, { "y", shift and "Y" or "y" }, { "u", shift and "U" or "u" }, { "i", shift and "I" or "i" }, { "o", shift and "O" or "o" }, { "p", shift and "P" or "p" } },
      { { "a", shift and "A" or "a" }, { "s", shift and "S" or "s" }, { "d", shift and "D" or "d" }, { "f", shift and "F" or "f" }, { "g", shift and "G" or "g" }, { "h", shift and "H" or "h" }, { "j", shift and "J" or "j" }, { "k", shift and "K" or "k" }, { "l", shift and "L" or "l" } },
      { { "shift", "CAP", "special" }, { "z", shift and "Z" or "z" }, { "x", shift and "X" or "x" }, { "c", shift and "C" or "c" }, { "v", shift and "V" or "v" }, { "b", shift and "B" or "b" }, { "n", shift and "N" or "n" }, { "m", shift and "M" or "m" }, { "back", "DEL", "special" } },
      { { "sym", "?123", "special" }, { "space", "SPACE", "space" }, { "cancel", "ESC", "special" }, { "done", "OK", "primary" } },
    }
  end
  if kb.layout == "symbols" then
    if Canvas.h < 26 then
      return {
        { { "1", "1" }, { "2", "2" }, { "3", "3" }, { "4", "4" }, { "5", "5" }, { "6", "6" }, { "7", "7" }, { "8", "8" }, { "9", "9" }, { "0", "0" } },
        { { "-", "-" }, { "_", "_" }, { "/", "/" }, { ".", "." }, { ":", ":" }, { "?", "?" }, { "!", "!" }, { "@", "@" }, { "#", "#" }, { "%", "%" } },
        { { "(", "(" }, { ")", ")" }, { "'", "'" }, { '"', '"' }, { ";", ";" }, { ",", "," }, { "+", "+" }, { "=", "=" }, { "&", "&" }, { "*", "*" } },
        { { "abc", "ABC", "special" }, { "back", "DEL", "special" } },
        { { "space", "SPACE", "space" }, { "clear", "CLEAR", "special" }, { "cancel", "ESC", "special" }, { "done", "DONE", "primary" } },
      }
    end
    local symRows = {
      { { "!", "!" }, { "@", "@" }, { "#", "#" }, { "$", "$" }, { "%", "%" }, { "&", "&" }, { "*", "*" }, { "(", "(" }, { ")", ")" }, { "-", "-" } },
      { { "_", "_" }, { "=", "=" }, { "+", "+" }, { "[", "[" }, { "]", "]" }, { "{", "{" }, { "}", "}" }, { ";", ";" }, { ":", ":" }, { "'", "'" } },
      { { '"', '"' }, { ",", "," }, { ".", "." }, { "?", "?" }, { "/", "/" }, { "\\", "\\" }, { "|", "|" }, { "<", "<" }, { ">", ">" }, { "~", "~" } },
      { { "abc", "ABC", "special" }, { "`", "`" }, { "^", "^" }, { "back", "DEL", "special" } },
      { { "space", "SPACE", "space" }, { "clear", "CLEAR", "special" }, { "cancel", "ESC", "special" }, { "done", "DONE", "primary" } },
    }
    if Canvas.h >= 26 then
      table.insert(symRows, 1, { { "1", "1" }, { "2", "2" }, { "3", "3" }, { "4", "4" }, { "5", "5" }, { "6", "6" }, { "7", "7" }, { "8", "8" }, { "9", "9" }, { "0", "0" } })
    end
    return symRows
  end
  local shift = kb.shift
  local qwerty = { { "q", shift and "Q" or "q" }, { "w", shift and "W" or "w" }, { "e", shift and "E" or "e" }, { "r", shift and "R" or "r" }, { "t", shift and "T" or "t" }, { "y", shift and "Y" or "y" }, { "u", shift and "U" or "u" }, { "i", shift and "I" or "i" }, { "o", shift and "O" or "o" }, { "p", shift and "P" or "p" } }
  local home = { { "a", shift and "A" or "a" }, { "s", shift and "S" or "s" }, { "d", shift and "D" or "d" }, { "f", shift and "F" or "f" }, { "g", shift and "G" or "g" }, { "h", shift and "H" or "h" }, { "j", shift and "J" or "j" }, { "k", shift and "K" or "k" }, { "l", shift and "L" or "l" } }
  local bottom = { { "shift", shift and "SHIFT" or "shift", "special" }, { "z", shift and "Z" or "z" }, { "x", shift and "X" or "x" }, { "c", shift and "C" or "c" }, { "v", shift and "V" or "v" }, { "b", shift and "B" or "b" }, { "n", shift and "N" or "n" }, { "m", shift and "M" or "m" }, { "back", "DEL", "special" } }
  local keyrow = { { "sym", "?123", "special" }, { "space", "SPACE", "space" }, { "clear", "CLEAR", "special" }, { "cancel", "ESC", "special" }, { "done", "DONE", "primary" } }
  if Canvas.h < 26 then
    return { qwerty, home, bottom, keyrow }
  end
  return {
    { { "1", "1" }, { "2", "2" }, { "3", "3" }, { "4", "4" }, { "5", "5" }, { "6", "6" }, { "7", "7" }, { "8", "8" }, { "9", "9" }, { "0", "0" } },
    qwerty, home, bottom, keyrow,
  }
end

function UI.drawKeyboard()
  local kb = UI.keyboard
  if not kb then return end
  local w, h = Canvas.w, Canvas.h
  local m = UI.m or UI.metrics(false, false)
  local keyH = h >= 30 and 3 or (h >= 20 and 2 or 1)
  local gap = (w >= 36 and h >= 24) and 1 or 0
  local rows = UI.keyboardRows()
  local fieldH = 2
  local headerH = 2
  local errH = 1
  local extraW = kb.extra and math.min(14, math.max(9, #kb.extra.label + 2)) or 0
  local contentH = headerH + fieldH + errH + #rows * keyH + (#rows - 1) * gap + 3
  local full = kb.fullscreen or contentH > h - 2
  local panelH = full and h or (contentH + 2)
  local panelY = full and 1 or (h - panelH + 1)
  local x0 = full and 1 or m.pad
  local ww = full and w or (w - m.pad * 2)

  Canvas:roundRect(x0, panelY, ww, panelH, full and 0 or 2, Theme.C.surface2, Theme.C.bg)
  Canvas:fill(x0 + 1, panelY, ww - 2, 1, Theme.C.surface)
  local titleW = ww - 10 - (extraW > 0 and (extraW + 1) or 0)
  Canvas:textFit(x0 + 2, panelY + 1, math.max(3, titleW), kb.title, Theme.C.accent, Theme.C.surface2)
  if kb.extra then
    local ex = x0 + ww - 5 - extraW - 1
    Canvas:roundRect(ex, panelY + 1, extraW, 2, 1, Theme.C.surface, Theme.C.surface2)
    Canvas:textCenter(ex, panelY + 1, extraW, kb.extra.label, Theme.C.muted, Theme.C.surface)
    UI.hit(ex, panelY + 1, extraW, 2, function() UI.keyboardKey("extra") end, { layer = 30 })
  end
  Canvas:roundRect(x0 + ww - 5, panelY + 1, 4, 2, 1, Theme.C.surface, Theme.C.surface2)
  Canvas:icon("closeSmall", x0 + ww - 5, panelY + 1, 4, 2, Theme.C.muted, 1)
  UI.hit(x0 + ww - 5, panelY + 1, 4, 2, function() UI.closeKeyboard(true) end)

  local fy = panelY + headerH + 1
  Canvas:roundRect(x0 + 2, fy, ww - 4, fieldH + 1, 1, Theme.C.surface, Theme.C.surface2)
  local shown = kb.value
  if kb.secret then shown = string.rep("*", #shown) end
  if shown == "" and kb.hint ~= "" then
    Canvas:textFit(x0 + 3, fy + math.floor(fieldH / 2), ww - 6, kb.hint, Theme.C.dim, Theme.C.surface)
  else
    local maxShow = ww - 8
    local visible = shown
    if #visible > maxShow then visible = visible:sub(#visible - maxShow + 1) end
    Canvas:textFit(x0 + 3, fy + math.floor(fieldH / 2), ww - 6, visible, Theme.C.text, Theme.C.surface)
    if kb.cursorOn and not kb.secret then
      local cx = x0 + 3 + math.min(#shown, maxShow)
      local cy = fy + math.floor(fieldH / 2) + 1
      Canvas:fill(Util.clamp(cx, x0 + 2, x0 + ww - 3), cy, 1, 1, Theme.C.accent)
    end
  end
  local errY = fy + fieldH + 1
  if kb.error ~= "" then
    Canvas:textFit(x0 + 3, errY, ww - 6, kb.error, Theme.C.danger, Theme.C.surface2)
  elseif kb.label ~= "" then
    Canvas:textFit(x0 + 3, errY, ww - 6, kb.label, Theme.C.dim, Theme.C.surface2)
  end

  local keyY = errY + errH + 1
  local availW = ww - 4 - (full and 2 or 0)
  local keyX0 = x0 + 2
  for r, row in ipairs(rows) do
    local units = 0
    for _, k in ipairs(row) do
      local token = k[1]
      local u
      if token == "space" then u = 5
      elseif token == "shift" or token == "back" then u = 2.5
      elseif token == "cancel" then u = 2.5
      elseif token == "done" then u = 2.5
      elseif token == "sym" then u = 3
      elseif token == "abc" then u = 2
      elseif k[3] == "primary" then u = 2.5
      elseif k[3] == "special" then u = 1.8
      else u = 1 end
      k._u = u
      units = units + u
    end
    local totalGaps = (#row - 1) * gap
    local unitW = (availW - totalGaps) / units
    local xx = keyX0
    for _, k in ipairs(row) do
      local kw = math.max(1, math.floor(k._u * unitW + 0.5))
      local variant = k[3]
      local bg, fg
      if variant == "primary" then bg, fg = Theme.C.accent, Theme.C.onAccent
      elseif variant == "special" then bg, fg = Theme.C.surface, Theme.C.muted
      else bg, fg = Theme.C.surface, Theme.C.text end
      Canvas:roundRect(xx, keyY, kw, keyH, 1, bg, Theme.C.surface2)
      local label = k[2]
      if #label > kw - 1 then label = label:sub(1, math.max(1, kw - 1)) end
      Canvas:textCenter(xx, keyY + math.floor((keyH - 1) / 2), kw, label, fg, bg)
      UI.hit(xx, keyY, kw, keyH, function() UI.keyboardKey(k[1]) end, { layer = 30 })
      xx = xx + kw + gap
    end
    keyY = keyY + keyH + gap
  end

end

------------------------------------------------------------------ dialogs
function UI.closeModal()
  UI.modal = nil
  UI.request(true)
end

function UI.confirm(title, message, onYes, opts)
  opts = opts or {}
  UI.modal = {
    kind = "confirm",
    title = title or "CONFIRM",
    message = message or "",
    onYes = onYes,
    onNo = opts.onNo,
    yesLabel = opts.yesLabel or "YES",
    noLabel = opts.noLabel or "CANCEL",
    danger = opts.danger,
  }
  UI.request(true)
end

function UI.actions(title, items, onPick, opts)
  opts = opts or {}
  UI.modal = {
    kind = "actions",
    title = title or "OPTIONS",
    items = items or {},
    sel = 1,
    scroll = 0,
    onPick = onPick,
    message = opts.message,
  }
  UI.request(true)
end

function UI.volumeSheet()
  UI.modal = { kind = "volume", title = "VOLUME" }
  UI.request(true)
end

function UI.drawModal()
  local md = UI.modal
  if not md then return end
  local w, h = Canvas.w, Canvas.h
  local m = UI.m or UI.metrics(false, false)
  if md.kind == "volume" then
    local pw = math.min(44, w - 4)
    local ph = 13
    local x = math.floor((w - pw) / 2) + 1
    local y = h - ph + 1
    Canvas:roundRect(x, y, pw, ph, 2, Theme.C.surface2, Theme.C.bg)
    Canvas:fill(x + 1, y, pw - 2, 1, Theme.C.accent)
    Canvas:textFit(x + 2, y + 1, pw - 4, "VOLUME", Theme.C.text, Theme.C.surface2)
    Canvas:icon("volume9", x + 2, y + 3, 6, 3, Theme.C.accent, 1)
    local barX, barW = x + 8, pw - 12
    UI.progressBar(barX, y + 3, barW, 2, Audio.volumeFrac(), {
      fn = function(f)
        Audio.setVolume(f * Audio.MAX_VOLUME)
        Player.syncPaused()
        UI.request(true)
      end,
    })
    Canvas:textFit(barX, y + 5, barW, Audio.volumeLabel(), Theme.C.muted, Theme.C.surface2)
    local bw = math.floor((pw - 8) / 3)
    UI.button(x + 2, y + 7, bw, 3, Audio.muted and "MUTE" or "MUTE", {
      variant = Audio.muted and "active" or "surface",
      icon = Audio.muted and "volumeMute9" or "volume9",
      fn = function()
        Audio.toggleMute()
        if App.cfg then App.cfg.muted = Audio.muted; Config.saveSoon() end
        UI.request(true)
      end,
    })
    UI.button(x + 3 + bw, y + 7, bw, 3, "-10", {
      variant = "surface",
      fn = function() Audio.setVolume(Audio.volume - 0.1); UI.request(true) end,
    })
    UI.button(x + 4 + bw * 2, y + 7, bw, 3, "+10", {
      variant = "surface",
      fn = function() Audio.setVolume(Audio.volume + 0.1); UI.request(true) end,
    })
    UI.button(x + 2, y + 10, pw - 4, 2, "DONE", { variant = "surface", fn = function() UI.closeModal() end })
    return
  end
  if md.kind == "confirm" then
    local pw = math.min(40, w - 4)
    local ph = math.min(12, h - 4)
    local x = math.floor((w - pw) / 2) + 1
    local y = math.floor((h - ph) / 2) + 1
    Canvas:roundRect(x, y, pw, ph, 2, Theme.C.surface2, Theme.C.bg)
    Canvas:fill(x + 1, y, pw - 2, 1, Theme.C.danger)
    Canvas:textFit(x + 2, y + 1, pw - 4, md.title, Theme.C.text, Theme.C.surface2)
    local lines = Util.wrap(md.message, pw - 4)
    for i = 1, math.min(#lines, ph - 6) do
      Canvas:text(x + 2, y + 3 + i - 1, lines[i], Theme.C.muted, Theme.C.surface2)
    end
    local by = y + ph - 3
    local bw = math.floor((pw - 5) / 2)
    UI.button(x + 2, by, bw, 2, md.noLabel, { variant = "surface", fn = function()
      local cb = md.onNo
      UI.closeModal()
      if cb then pcall(cb) end
    end })
    UI.button(x + 3 + bw, by, bw, 2, md.yesLabel, {
      variant = md.danger and "danger" or "primary",
      fn = function()
        local cb = md.onYes
        UI.closeModal()
        if cb then pcall(cb) end
      end,
    })
  elseif md.kind == "actions" then
    local visible = math.min(#md.items, math.max(3, math.floor((h - 7) / 3)))
    local ph = math.min(h - 2, 4 + visible * 3)
    local pw = math.min(52, w - 2 * m.pad)
    local x = math.floor((w - pw) / 2) + 1
    local y = h - ph + 1
    Canvas:roundRect(x, y, pw, ph, 2, Theme.C.surface2, Theme.C.bg)
    Canvas:fill(x + 1, y, pw - 2, 1, Theme.C.accent)
    local rail = #md.items > visible
    local rowW = pw - 5 - (rail and 4 or 0)
    Canvas:textFit(x + 2, y + 1, pw - 6 - (rail and 4 or 0), md.title, Theme.C.text, Theme.C.surface2)
    if md.message then Canvas:textFit(x + 2, y + 2, pw - 6 - (rail and 4 or 0), md.message, Theme.C.dim, Theme.C.surface2) end
    md.sel = Util.clamp(md.sel or 1, 1, math.max(1, #md.items))
    if md.sel < md.scroll + 1 then md.scroll = md.sel - 1 end
    if md.sel > md.scroll + visible then md.scroll = md.sel - visible end
    md.scroll = Util.clamp(md.scroll, 0, math.max(0, #md.items - visible))
    for r = 1, visible do
      local idx = md.scroll + r
      local item = md.items[idx]
      if item then
        local ry = y + 3 + (r - 1) * 3
        local bg = idx == md.sel and Theme.C.accentDim or Theme.C.surface
        Canvas:roundRect(x + 2, ry, rowW, 3, 1, bg, Theme.C.surface2)
        if item.icon then Canvas:icon(item.icon, x + 2, ry, 4, 3, item.danger and Theme.C.danger or Theme.C.text, 1) end
        Canvas:textFit(x + 7, ry, rowW - 8, item.label or "", item.danger and Theme.C.danger or Theme.C.text, bg)
        if item.sub then Canvas:textFit(x + 7, ry + 1, rowW - 8, item.sub, Theme.C.muted, bg) end
        UI.hit(x + 2, ry, rowW, 3, function()
          local cb = md.onPick
          UI.closeModal()
          if cb then pcall(cb, item.value ~= nil and item.value or item) end
        end, { layer = 20 })
      end
    end
    if rail then
      local maxScroll = math.max(0, #md.items - visible)
      UI.button(x + pw - 5, y + 1, 3, 2, "", { icon = "up5", variant = "surface2", fn = function()
        md.scroll = Util.clamp(md.scroll - 1, 0, maxScroll); md.sel = md.scroll + 1; UI.request(true)
      end })
      UI.button(x + pw - 5, y + ph - 5, 3, 2, "", { icon = "down5", variant = "surface2", fn = function()
        md.scroll = Util.clamp(md.scroll + 1, 0, maxScroll); md.sel = md.scroll + 1; UI.request(true)
      end })
    end
    local cy = y + ph - 3
    UI.button(x + 2, cy, rowW, 2, "CLOSE", { variant = "surface", fn = function() UI.closeModal() end })
  end
end

------------------------------------------------------------------ root access
function UI.loginPrompt(callback)
  if not Auth.configured then
    UI.toast("Root setup is required", "warning")
    App.go("setup")
    return
  end
  local mode = Auth.mode()
  local compact = Canvas.w < 40
  UI.openKeyboard({
    title = compact and "ROOT" or "ROOT ACCESS",
    label = "Signed in as " .. Auth.username(),
    hint = mode == "pin" and "Enter PIN" or "Enter password",
    mode = mode,
    secret = true,
    maxLen = mode == "pin" and Auth.maxPin or Auth.maxSecret,
    minLen = mode == "pin" and Auth.minPin or Auth.minPassword,
    extra = { label = compact and "RECOVER" or "RECOVERY CODE", fn = function() UI.recoveryPrompt(callback) end },
    onDone = function(value)
      local now = Util.now()
      if now < UI.loginBlockedUntil then
        return false, string.format("Too many attempts. Wait %ds.", math.ceil(UI.loginBlockedUntil - now))
      end
      if Auth.verify(value) then
        Auth.root = true
        Auth.rootAt = Util.now()
        UI.loginFailures = 0
        UI.loginBlockedUntil = 0
        UI.toast("Root unlocked", "success")
        if callback then pcall(callback) end
        return true
      end
      UI.loginFailures = UI.loginFailures + 1
      local wait = math.min(30, 2 ^ math.min(UI.loginFailures, 5))
      UI.loginBlockedUntil = now + wait
      if UI.keyboard then UI.keyboard.value = ""; UI.keyboard.cursor = 1 end
      return false, string.format("Incorrect. Wait %ds.", wait)
    end,
    onCancel = function() end,
  })
end

function UI.recoveryPrompt(callback)
  UI.openKeyboard({
    title = "RECOVERY CODE",
    label = "Enter the recovery code shown during setup",
    hint = "XXXXX-XXXXX",
    mode = "text",
    maxLen = 20,
    minLen = 6,
    onDone = function(code)
      if not Auth.verifyRecovery(code) then
        return false, "Invalid recovery code"
      end
      local mode = Auth.mode()
      UI.openKeyboard({
        title = "SET NEW " .. (mode == "pin" and "PIN" or "PASSWORD"),
        hint = mode == "pin" and "4-8 digits" or "At least 6 characters",
        mode = mode,
        secret = true,
        maxLen = mode == "pin" and Auth.maxPin or Auth.maxSecret,
        minLen = mode == "pin" and Auth.minPin or Auth.minPassword,
        onDone = function(secret)
          local ok, err = Auth.changeSecret(mode, secret)
          if not ok then return false, err end
          Auth.root = true
          Auth.rootAt = Util.now()
          UI.toast("Root credential updated", "success")
          if callback then pcall(callback) end
          return true
        end,
      })
      return "keep"
    end,
  })
end

function UI.openSettings()
  if Auth.isRoot() then
    App.go("settings")
  else
    UI.loginPrompt(function() App.go("settings") end)
  end
end

function UI.rootGuard(fn)
  if Auth.isRoot() then
    if fn then pcall(fn) end
    return true
  end
  UI.loginPrompt(fn)
  return false
end

function UI.lockRoot()
  Auth.lock()
  UI.toast("Root locked", "info")
  if App.screen:match("^settings") or App.screen:match("art") or App.screen:match("meta") or App.screen:match("lyrics%u") then
    App.goTab("home")
  end
  UI.request(true)
end

function UI.askText(title, value, onDone, opts)
  opts = opts or {}
  UI.openKeyboard({
    title = title,
    value = value or "",
    hint = opts.hint or "",
    label = opts.label or "",
    maxLen = opts.maxLen or 80,
    minLen = opts.minLen or 1,
    allowEmpty = opts.allowEmpty,
    secret = opts.secret,
    mode = opts.mode or "text",
    onDone = onDone,
    extra = opts.extra,
  })
end

function UI.volumeSheetClose()
  if UI.modal and UI.modal.kind == "volume" then UI.closeModal() end
end

--======== 92_screens_core.lua ========
------------------------------------------------------------------ screens: core
Screens = {}
Screens.lastLyricTrack = nil

function Screens.tooSmall()
  local w, h = Canvas.w, Canvas.h
  Canvas:fill(1, 1, w, h, Theme.C.bg)
  Canvas:icon("music", 1, 2, w, 3, Theme.C.accent, 2)
  Canvas:textCenter(1, 6, w, "DISPLAY TOO SMALL", Theme.C.warning, Theme.C.bg)
  Canvas:textCenter(1, 8, w, "Need at least " .. MIN_W .. "x" .. MIN_H .. " cells", Theme.C.muted, Theme.C.bg)
  Canvas:textCenter(1, 9, w, "Current: " .. w .. "x" .. h, Theme.C.dim, Theme.C.bg)
  Canvas:textCenter(1, 11, w, "Add Advanced Monitor blocks,", Theme.C.muted, Theme.C.bg)
  Canvas:textCenter(1, 12, w, "or use a lower text scale.", Theme.C.muted, Theme.C.bg)
  if w >= 12 and h >= 15 then
    UI.button(2, h - 6, w - 4, 2, "RESET SCALE 0.5", { variant = "surface", fn = function()
      App.cfg.monitorScale = 0.5
      Config.saveNow()
      App.reinitDisplay()
      UI.request(true)
    end })
    UI.button(2, h - 3, w - 4, 2, "RESCAN DISPLAY", { variant = "primary", fn = function() App.reinitDisplay(); UI.request(true) end })
  end
end

function Screens.draw()
  if Canvas.w < MIN_W or Canvas.h < MIN_H then
    Screens.tooSmall()
    return
  end
  if App.screen == "setup" then
    Screens.setup()
  elseif App.screen == "home" then
    Screens.home()
  elseif App.screen == "music" then
    Screens.music()
  elseif App.screen == "library" then
    Screens.library()
  elseif App.screen == "album" then
    Screens.album()
  elseif App.screen == "artist" then
    Screens.artist()
  elseif App.screen == "playlists" then
    Screens.playlists()
  elseif App.screen == "playlist" then
    Screens.playlist()
  elseif App.screen == "playlistAdd" then
    Screens.playlistAdd()
  elseif App.screen == "queue" then
    Screens.queue()
  elseif App.screen == "video" then
    Screens.video()
  elseif App.screen == "gallery" then
    Screens.gallery()
  elseif App.screen == "files" then
    Screens.files()
  elseif App.screen == "notes" then
    Screens.notes()
  elseif App.screen == "noteEdit" then
    Screens.noteEdit()
  elseif App.screen == "notifications" then
    Screens.notifications()
  elseif App.screen == "search" then
    Screens.search()
  elseif App.screen == "lyrics" then
    Screens.lyrics()
  elseif App.screen == "settings" then
    Screens.settings()
  elseif App.screen == "settingsAppearance" then
    Screens.settingsAppearance()
  elseif App.screen == "settingsAudio" then
    Screens.settingsAudio()
  elseif App.screen == "settingsLibrary" then
    Screens.settingsLibrary()
  elseif App.screen == "settingsSecurity" then
    Screens.settingsSecurity()
  elseif App.screen == "settingsAbout" then
    Screens.settingsAbout()
  elseif App.screen == "artwork" then
    Screens.artwork()
  elseif App.screen == "artPicker" then
    Screens.artPicker()
  elseif App.screen == "metadata" then
    Screens.metadata()
  elseif App.screen == "metaForm" then
    Screens.metaForm()
  elseif App.screen == "albumMeta" then
    Screens.albumMeta()
  elseif App.screen == "lyricsManager" then
    Screens.lyricsManager()
  elseif App.screen == "lyricsPicker" then
    Screens.lyricsPicker()
  else
    App.screen = "home"
    Screens.home()
  end
end

function Screens.lyricsFor(track)
  if not track then return nil end
  local key = track.path .. "|" .. tostring(track.lyricsPath or "")
  if App.lyricsCache[key] ~= nil then return App.lyricsCache[key] or nil end
  local l = Lrc.find(track, track.lyricsPath)
  App.lyricsCache[key] = l or false
  return l
end

function Screens.clearLyricsCache()
  App.lyricsCache = {}
end

function Screens.lyricPreview(x, y, w, track)
  if not track then return end
  local lrc = Screens.lyricsFor(track)
  if not lrc then
    Canvas:textFit(x, y, w, "NO LYRICS  ·  TAP TO VIEW", Theme.C.dim, Theme.C.bg)
    if w > 0 then UI.hit(x, y - 1, w, 3, function() App.openLyrics(track) end) end
    return
  end
  if not lrc.sync then
    Canvas:textFit(x, y, w, "LYRICS (UNSYNCED)  ·  TAP TO VIEW", Theme.C.dim, Theme.C.bg)
    UI.hit(x, y - 1, w, 3, function() App.openLyrics(track) end)
    return
  end
  local idx = Lrc.currentIndex(lrc, Audio.position(), 1)
  local current = lrc.lines[idx]
  local nextLine = lrc.lines[idx + 1]
  if current then Canvas:textFit(x, y, w, current.text ~= "" and current.text or "♪", Theme.C.text, Theme.C.bg) end
  if nextLine then Canvas:textFit(x, y + 1, w, nextLine.text, Theme.C.dim, Theme.C.bg) end
  UI.hit(x, y - 1, w, 4, function() App.openLyrics(track) end)
end

function Screens.visualizer(x, y, w, h)
  local mode = App.cfg.visualizer or "bars"
  if mode == "off" or h <= 0 or w <= 12 then return end
  if mode == "bars" then
    local n = math.min(24, math.floor(w / 3))
    local bars = Audio.viz.bands
    for i = 1, n do
      local b = bars[math.floor((i - 1) * 8 / n) + 1] or 0
      local bh = math.max(1, math.floor(b * h + 0.5))
      local col = b > 0.66 and Theme.C.accentLight or (b > 0.33 and Theme.C.accent or Theme.C.accentDim)
      local bx = x + (i - 1) * 3
      Canvas:fill(bx, y + h - bh, 2, bh, col)
    end
    Canvas:textRight(x, y, w - 1, (Player.paused and "PAUSED" or "LIVE PCM"), Theme.C.dim, Theme.C.bg)
  elseif mode == "wave" then
    local wave = Audio.viz.wave
    if #wave == 0 then return end
    local mid = y + math.floor(h / 2)
    for i = 1, math.min(#wave, w - 1) do
      local v = wave[i] or 0
      local hh = math.max(1, math.floor(v * h / 2 + 0.5))
      local col = i % 3 == 0 and Theme.C.accentLight or Theme.C.accent
      Canvas:fill(x + i - 1, mid - hh + 1, 1, hh * 2 - 1, col)
    end
  elseif mode == "vu" then
    local labelW = 4
    local bw = w - labelW - 8
    Canvas:text(x, y, "L", Theme.C.dim, Theme.C.bg)
    Canvas:text(x, y + 1, "R", Theme.C.dim, Theme.C.bg)
    local rms = Audio.viz.rms or 0
    local peak = Audio.viz.peak or 0
    Canvas:progressBar(x + labelW, y, bw, 1, rms, { fn = nil, noThumb = true })
    Canvas:progressBar(x + labelW, y + 1, bw, 1, peak, { fn = nil, noThumb = true, fg = Theme.C.accentLight })
    Canvas:textRight(x + labelW, y, bw, "VU", Theme.C.dim, Theme.C.bg)
  end
end

function Screens.transport(x, y, w, h, compact)
  local gap = compact and 1 or 2
  local side = compact and 4 or 5
  local playW = compact and 6 or 8
  local total = side * 4 + playW + gap * 4
  if total > w then
    gap = 1
    side = math.max(3, math.floor((w - playW - 4) / 4))
    total = side * 4 + playW + 4
  end
  local start = x + math.max(0, math.floor((w - total) / 2))
  local sy = Player.shuffle and "active" or "surface"
  local ry = Player.repeatMode ~= "off" and "active" or "surface"
  local by = y
  local compactIcons = Canvas.w < 40
  UI.button(start, by, side, h, "", { icon = compactIcons and "shuffle5" or "shuffle", variant = sy == "active" and "active" or "surface2", fn = function() Player.toggleShuffle() end })
  UI.button(start + side + gap, by, side, h, "", { icon = compactIcons and "prev5" or "prev", variant = "surface2", fn = function() Player.prev() end })
  local px = start + (side + gap) * 2
  UI.button(px, by, playW, h, "", {
    icon = Player.paused and "play" or "pause",
    variant = "primary",
    fn = function() Player.togglePause() end,
  })
  local nx = px + playW + gap
  UI.button(nx, by, side, h, "", { icon = "next", variant = "surface2", fn = function() Player.next(false) end })
  UI.button(nx + side + gap, by, side, h, "", {
    icon = Player.repeatMode == "one" and "repeat1" or "repeat",
    variant = ry,
    fn = function() Player.cycleRepeat() end,
  })
end

function Screens.secondaryRow(x, y, w, h, track)
  -- LRC / QUEUE / VOL only — no LIKE (ProOnlyUNO).
  local gap = 2
  local bw = math.floor((w - gap * 2) / 3)
  if bw < 6 then
    gap = 1
    bw = math.floor((w - gap * 2) / 3)
  end
  if bw < 8 then
    UI.iconButton(x, y, bw, h, "lyrics9", { variant = "surface", fn = function() App.openLyrics(track) end })
    UI.iconButton(x + bw + gap, y, bw, h, "queue9", { variant = "surface", fn = function() App.openQueue() end })
    UI.iconButton(x + (bw + gap) * 2, y, bw, h, Audio.muted and "volumeMute9" or "volume9", { variant = "surface", fn = function() UI.volumeSheet() end })
    return
  end
  UI.button(x, y, bw, h, "LRC", {
    icon = "lyrics", variant = "surface",
    fn = function() App.openLyrics(track) end,
  })
  UI.button(x + bw + gap, y, bw, h, "QUEUE", {
    icon = "queue9", variant = "surface",
    fn = function() App.openQueue() end,
  })
  UI.button(x + (bw + gap) * 2, y, bw, h, "VOL", {
    icon = Audio.muted and "volumeMute9" or "volume9",
    variant = Audio.muted and "active" or "surface",
    fn = function() UI.volumeSheet() end,
  })
end

function Screens.quickActions()
  local track = Player.cur
  if not track then return end
  local items = {
    { label = "Play / Pause", sub = Player.paused and "Resume playback" or "Pause playback", icon = Player.paused and "play" or "pause", value = "pause" },
    { label = "Lyrics", icon = "lyrics", value = "lyrics" },
    { label = "Queue", icon = "queue9", value = "queue" },
    { label = "Volume", sub = Audio.volumeLabel(), icon = "volume9", value = "volume" },
    { label = Player.shuffle and "Shuffle: on" or "Shuffle: off", icon = "shuffle9", value = "shuffle" },
    { label = "Repeat: " .. Player.repeatMode:upper(), icon = "repeat", value = "repeat" },
    { label = "Go to album", icon = "disc", value = "album" },
    { label = "Go to artist", icon = "user", value = "artist" },
    { label = "Stop playback", icon = "close", value = "stop", danger = true },
  }
  UI.actions("NOW PLAYING", items, function(value)
    if value == "pause" then Player.togglePause()
    elseif value == "lyrics" then App.openLyrics(track)
    elseif value == "queue" then App.openQueue()
    elseif value == "volume" then UI.volumeSheet()
    elseif value == "shuffle" then Player.toggleShuffle()
    elseif value == "repeat" then Player.cycleRepeat()
    elseif value == "album" and track.albumRef then App.openAlbum(track.albumRef)
    elseif value == "artist" and track.albumRef then App.openArtist(track.albumRef.artist)
    elseif value == "stop" then Player.stop() end
  end)
end

function Screens.nowPlaying(m)
  local track = Player.cur
  if not track then
    Screens.homeIdle(m)
    return
  end
  local x, top, w, bot = m.contentX, m.bodyTop, m.contentW, m.bodyBot
  local bodyH = bot - top + 1
  local compact = w < 44 or bodyH < 20
  local artRows, artCols
  if compact then
    local minArt = bodyH < 15 and 3 or 5
    artRows = Util.clamp(math.floor(bodyH * 0.40), minArt, 9)
    artRows = math.min(artRows, math.max(3, bodyH - 9))
    artCols = Util.round(artRows * 1.5)
    artCols = math.min(artCols, math.max(5, math.floor(w * 0.36)))
    artRows = Util.round(artCols * 2 / 3)
  else
    artRows = Util.clamp(math.floor(bodyH * 0.38), 8, 13)
    artCols = Util.round(artRows * 1.5)
    if artCols > math.floor(w * 0.42) then
      artCols = math.floor(w * 0.42)
      artRows = Util.round(artCols * 2 / 3)
    end
  end
  local artX, artY = x, top
  Canvas:roundRect(artX - 1, artY - 1, artCols + 2, artRows + 2, 1, Theme.C.surface, Theme.C.bg)
  local art = Art.forTrack(track, artCols, artRows)
  if art then Canvas:art(art, artX, artY) end
  -- More button over the artwork corner (always reachable, no hover needed).
  UI.button(artX + artCols - 4, artY + artRows - 2, 5, 3, "", {
    icon = "more", variant = "surface2", radius = 1, fn = Screens.quickActions,
  })

  local infoX = artX + artCols + 2
  local infoW = x + w - infoX
  local stacked = infoW < 12
  if stacked then
    infoX = x
    infoW = w
    artY = top
  end
  local infoY = stacked and (artY + artRows + 3) or (top + 1)
  local titleW = infoW
  if not compact then
    Canvas:textFit(infoX, infoY, infoW, "NOW PLAYING", Theme.C.accent, Theme.C.bg)
    infoY = infoY + 2
  end
  Canvas:textFit(infoX, infoY, titleW, track.title, Theme.C.text, Theme.C.bg)
  Canvas:textFit(infoX, infoY + 1, titleW, track.artist, Theme.C.muted, Theme.C.bg)
  Canvas:textFit(infoX, infoY + 2, titleW, track.album, Theme.C.dim, Theme.C.bg)
  if not compact and infoW > 18 then
    Canvas:textFit(infoX, infoY + 4, infoW, Player.queueNumber() .. "  ·  " .. (Player.source or "Queue"), Theme.C.dim, Theme.C.bg)
  end
  if Art and track.missing then
    Canvas:textFit(infoX, infoY + 5, infoW, "FILE MISSING", Theme.C.danger, Theme.C.bg)
  end

  local progressY = math.max(artY + artRows + 2, infoY + (compact and 4 or 6))
  if progressY > bot - 6 then progressY = bot - 6 end
  local barX, barW = x, w
  if not compact and w >= 46 then
    UI.button(x, progressY, 5, 2, "-10", { variant = "surface", fn = function() Player.seekBy(-10) end })
    UI.button(x + w - 5, progressY, 5, 2, "+10", { variant = "surface", fn = function() Player.seekBy(10) end })
    barX, barW = x + 7, w - 14
  end
  local frac = track.dur > 0 and (Player.position() / track.dur) or 0
  UI.progressBar(barX, progressY, barW, 2, frac, { fn = function(f) Player.seek(f * track.dur) end })
  Canvas:textFit(x, progressY + 2, 8, Util.fmtTime(Player.position()), Theme.C.muted, Theme.C.bg)
  Canvas:textRight(x + w - 8, progressY + 2, 8, Util.fmtTime(track.dur), Theme.C.muted, Theme.C.bg)

  local transportY = progressY + 4
  local transportH = math.min(4, bot - transportY + 1)
  if transportH >= 3 then
    Screens.transport(x, transportY, w, transportH, compact)
  end

  local after = transportY + transportH
  if not compact and bot - after >= 4 then
    local secH = 3
    Screens.secondaryRow(x, after + 1, w, secH, track)
    after = after + 1 + secH
  end
  if bot - after >= 2 and App.cfg.showLyricsPreview then
    Screens.lyricPreview(x, after + 1, w, track)
    after = after + 3
  end
  if bot - after >= 2 and App.cfg.visualizer ~= "off" then
    Screens.visualizer(x, after + 1, w, math.min(3, bot - after))
  end
end

function Screens.recentAlbums(limit)
  local out, seen = {}, {}
  for _, t in ipairs(Data.recentTracks()) do
    local a = t.albumRef
    if a and not seen[a.key] then
      seen[a.key] = true
      out[#out + 1] = a
      if #out >= (limit or 4) then break end
    end
  end
  return out
end

function Screens.homeIdle(m)
  local x, top, w, bot = m.contentX, m.bodyTop, m.contentW, m.bodyBot
  local bodyH = bot - top + 1
  if m.compact then
    if #Data.tracks == 0 then
      Canvas:roundRect(x, top, w, bodyH, 2, Theme.C.surface, Theme.C.bg)
      Canvas:fill(x, top, 1, bodyH, Theme.C.accent)
      Canvas:textFit(x + 2, top + 1, w - 4, "NO MUSIC YET", Theme.C.text, Theme.C.surface)
      Canvas:textBlock(x + 2, top + 3, w - 4, "Put .dfpwm files in music/<Album>/<Track>.dfpwm", Theme.C.muted, Theme.C.surface, 3)
      local bw = math.floor((w - 5) / 2)
      UI.button(x + 2, top + bodyH - 4, bw, 3, "RESCAN", { variant = "primary", fn = function()
        Data.rescan(); UI.toast("Library rescanned", "success")
      end })
      UI.button(x + 4 + bw, top + bodyH - 4, bw, 3, "SETTINGS", { variant = "surface", fn = UI.openSettings })
    else
      Canvas:roundRect(x, top, w, bodyH, 2, Theme.C.surface, Theme.C.bg)
      Canvas:fill(x, top, 1, bodyH, Theme.C.accent)
      Canvas:textFit(x + 2, top + 1, w - 4, "READY WHEN YOU ARE", Theme.C.accent, Theme.C.surface)
      Canvas:textFit(x + 2, top + 2, w - 4, Data.stats.tracks .. " " .. Util.plural(Data.stats.tracks, "song") .. " · " .. Data.stats.albums .. " " .. Util.plural(Data.stats.albums, "album"), Theme.C.dim, Theme.C.surface)
      Canvas:textBlock(x + 2, top + 4, w - 4, "Your music, at your fingertips.", Theme.C.text, Theme.C.surface, 2)
      local bw = math.floor((w - 5) / 2)
      UI.button(x + 2, top + bodyH - 4, bw, 3, "SHUFFLE", { variant = "primary", fn = function() Player.shuffleAll() end })
      UI.button(x + 4 + bw, top + bodyH - 4, bw, 3, "BROWSE", { variant = "surface2", fn = function() App.goTab("library") end })
    end
    return
  end
  if #Data.tracks == 0 then
    local hh = math.min(15, bodyH)
    Canvas:roundRect(x, top, w, hh, 2, Theme.C.surface, Theme.C.bg)
    Canvas:fill(x, top, 1, hh, Theme.C.accent)
    Canvas:icon("music", x, top + 1, w, 4, Theme.C.accent, 2)
    Canvas:textCenter(x, top + 6, w, "NO MUSIC YET", Theme.C.text, Theme.C.surface)
    Canvas:textCenter(x, top + 8, w, "Put .dfpwm files in", Theme.C.muted, Theme.C.surface)
    Canvas:textCenter(x, top + 9, w, "music/<Album>/<Track>.dfpwm", Theme.C.accentLight, Theme.C.surface)
    UI.button(x + 2, top + hh - 4, math.min(14, w - 4), 2, "RESCAN", { variant = "primary", icon = "refresh", fn = function()
      Data.rescan(); UI.toast("Library rescanned", "success")
    end })
    if w > 22 then
      UI.button(x + 18, top + hh - 4, math.min(14, w - 20), 2, "SETTINGS", { variant = "surface", icon = "settings", fn = UI.openSettings })
    end
    if bodyH > hh + 2 then
      Canvas:textFit(x, top + hh + 2, w, "Then tap HOME or LIBRARY to begin.", Theme.C.dim, Theme.C.bg)
    end
    return
  end

  local heroH = math.min(14, math.max(8, math.floor(bodyH * (bodyH >= 22 and 0.45 or 0.62))))
  Canvas:roundRect(x, top, w, heroH, 2, Theme.C.surface, Theme.C.bg)
  Canvas:fill(x, top, 1, heroH, Theme.C.accent)
  Canvas:textFit(x + 2, top + 1, w - 4, "READY WHEN YOU ARE", Theme.C.accent, Theme.C.surface)
  Canvas:textFit(x + 2, top + 3, w - 4, "Your music, at your fingertips.", Theme.C.text, Theme.C.surface)
  if w >= 36 then
    Canvas:textFit(x + 2, top + 4, w - 4, "Touch a cover, or let CC MUSIC choose.", Theme.C.muted, Theme.C.surface)
  end
  local bw = math.min(18, math.floor((w - 5) / 2))
  UI.button(x + 2, top + heroH - 4, bw, 3, "SHUFFLE ALL", { variant = "primary", icon = "shuffle", fn = function() Player.shuffleAll() end })
  UI.button(x + 4 + bw, top + heroH - 4, bw, 3, "BROWSE", { variant = "surface", icon = "library", fn = function() App.goTab("library") end })
  Canvas:textRight(x, top + 1, w - 2, Data.stats.tracks .. " SONGS", Theme.C.dim, Theme.C.surface)

  local below = top + heroH + 2
  if bodyH and bot - below >= 5 then
    local stats = string.format("%d %s  ·  %d %s  ·  %s", Data.stats.albums, Util.plural(Data.stats.albums, "album"), Data.stats.artists, Util.plural(Data.stats.artists, "artist"), Util.fmtDuration(Data.stats.duration))
    Canvas:textFit(x, below, w, stats, Theme.C.dim, Theme.C.bg)
    local rec = Screens.recentAlbums(4)
    if #rec > 0 and bot - (below + 2) >= 5 then
      Canvas:textFit(x, below + 2, w, "RECENTLY PLAYED", Theme.C.dim, Theme.C.bg)
      local cardW = math.floor((w - (math.min(#rec, 4) - 1) * 2) / math.min(#rec, 4))
      if cardW >= 7 then
        for i, album in ipairs(rec) do
          local cx = x + (i - 1) * (cardW + 2)
          if cx + cardW <= x + w then
            local artRows = math.max(4, math.min(8, bot - (below + 5)))
            local artCols = Util.round(artRows * 1.5)
            if artCols > cardW then artCols = cardW; artRows = Util.round(cardW * 2 / 3) end
            local art = Art.forAlbum(album, artCols, artRows)
            if art then Canvas:art(art, cx, below + 3) end
            Canvas:textFit(cx, below + 3 + artRows, cardW, album.name, Theme.C.text, Theme.C.bg)
            UI.hit(cx, below + 3, cardW, artRows + 2, function() App.openAlbum(album) end)
          end
        end
      end
    end
  end
end

function Screens.musicVideo()
  -- Full-bleed video on the same main monitor; audio continues via Audio.*.
  local w, h = Canvas.w, Canvas.h
  local barH = 4
  Canvas:fill(1, 1, w, h, Theme.C.bg)
  if Video.loaded then
    Video.draw(1, 1, w, math.max(1, h - barH), true)
  else
    Canvas:textCenter(1, math.floor(h / 2), w, "NO VIDEO", Theme.C.text, Theme.C.bg)
  end
  Canvas:fill(1, h - barH + 1, w, barH, Theme.C.surface)
  local title = Player.cur and Player.cur.title or "VIDEO"
  Canvas:textCenter(12, h - barH + 2, math.max(8, w - 24), Util.fit(title, math.max(8, w - 24)), Theme.C.muted, Theme.C.surface)
  -- Bottom: BACK + SONG (exit video) + NEXT. Stay in video mode across packs.
  UI.button(2, h - barH + 1, 9, 3, "BACK", {
    variant = "surface",
    fn = function()
      Video.musicStay = true
      Player.prev()
    end,
  })
  UI.button(math.max(12, math.floor(w / 2) - 4), h - barH + 1, 9, 3, "SONG", {
    variant = "primary",
    fn = function() Video.dismissMusic() end,
  })
  UI.button(w - 10, h - barH + 1, 9, 3, "NEXT", {
    variant = "surface",
    fn = function()
      Video.musicStay = true
      Player.next(false)
    end,
  })
end

function Screens.music()
  if Video.musicActive and Video.loaded and Player.cur then
    Screens.musicVideo()
    return
  end
  local m = UI.frame({ title = "", tab = "music", mini = false })
  if Player.cur then
    Screens.nowPlaying(m)
  else
    Screens.homeIdle(m)
  end
end

--======== 93_screens_library.lua ========
------------------------------------------------------------------ screens: library
function Screens.trackActions(track, opts)
  opts = opts or {}
  if not track then return end
  local items = {
    { label = "Play now", icon = "play", value = "play" },
    { label = "Play next", icon = "next", value = "next" },
    { label = "Add to queue", icon = "queue9", value = "queue" },
    { label = "Add to playlist", icon = "plus", value = "playlist" },
  }
  if track.albumRef then
    items[#items + 1] = { label = "Go to album", icon = "disc", value = "album" }
    items[#items + 1] = { label = "Go to artist", icon = "user", value = "artist" }
  end
  items[#items + 1] = { label = "Show lyrics", icon = "lyrics9", value = "lyrics" }
  if opts.queueEntry then
    items[#items + 1] = { label = "Move up", icon = "up", value = "up" }
    items[#items + 1] = { label = "Move down", icon = "down", value = "down" }
    items[#items + 1] = { label = "Remove from queue", icon = "trash", value = "remove", danger = true }
  end
  if opts.playlist then
    items[#items + 1] = { label = "Remove from this playlist", icon = "trash", value = "pl_remove", danger = true }
  end
  if Auth.isRoot() then
    items[#items + 1] = { label = "Edit metadata (root)", icon = "edit", value = "meta" }
    items[#items + 1] = { label = "Set artwork (root)", icon = "palette", value = "art" }
    items[#items + 1] = { label = "Assign lyrics (root)", icon = "lyrics9", value = "lyrics_set" }
  end
  UI.actions(track.title, items, function(value)
    if value == "play" then
      if opts.context then Player.playContext(opts.context, opts.index or 1, opts.source or "Queue")
      else Player.playContext({ track }, 1, track.album or "Queue") end
    elseif value == "next" then Player.queueAdd(track, true)
    elseif value == "queue" then Player.queueAdd(track, false)
    elseif value == "playlist" then Screens.addToPlaylist(track)
    elseif value == "album" and track.albumRef then App.openAlbum(track.albumRef)
    elseif value == "artist" and track.albumRef then App.openArtist(track.albumRef.artist)
    elseif value == "lyrics" then App.openLyrics(track)
    elseif value == "up" and opts.queueEntry then Player.moveQueue(opts.index, -1)
    elseif value == "down" and opts.queueEntry then Player.moveQueue(opts.index, 1)
    elseif value == "remove" and opts.queueEntry then Player.queueRemove(opts.queueEntry)
    elseif value == "pl_remove" and opts.playlist then
      Data.removeTrackFromPlaylist(opts.playlist, track)
      UI.toast("Removed from " .. opts.playlist.name, "info")
    elseif value == "meta" then UI.rootGuard(function() App.openMetaForm(track) end)
    elseif value == "art" then UI.rootGuard(function() App.openArtPicker(track, "track") end)
    elseif value == "lyrics_set" then UI.rootGuard(function() App.openLyricsPicker(track) end)
    end
  end)
end

function Screens.addToPlaylist(track)
  if not track then return end
  local items = {}
  for _, pl in ipairs(Data.playlists) do
    items[#items + 1] = { label = pl.name, sub = #pl.tracks .. " tracks", icon = "playlist", value = pl }
  end
  items[#items + 1] = { label = "New playlist...", icon = "plus", value = "new" }
  UI.actions("ADD TO PLAYLIST", items, function(value)
    if value == "new" then
      UI.askText("NEW PLAYLIST", "", function(name)
        if Util.trim(name) == "" then return false, "Enter a name" end
        local pl = Data.createPlaylist(name)
        Data.addTrackToPlaylist(pl, track)
        UI.toast("Added to " .. pl.name, "success")
        return true
      end)
    elseif value then
      Data.addTrackToPlaylist(value, track)
      UI.toast("Added to " .. value.name, "success")
    end
  end)
end

function Screens.trackRow(x, y, w, h, track, index, opts)
  opts = opts or {}
  local sel = opts.selected
  local current = (Player.cur == track)
  local bg = sel and Theme.C.accentDim or ((current or opts.hover) and Theme.C.surface2 or Theme.C.surface)
  Canvas:roundRect(x, y, w, h, 1, bg, Theme.C.bg)
  local compact = Canvas.w < 40
  local moreW = opts.noMore and 0 or (compact and 3 or 4)
  local durW = compact and 5 or 6
  local artW = compact and 3 or 4
  local artH = compact and 2 or 3
  local thumb = Art.forTrack(track, artW, artH)
  if thumb then Canvas:art(thumb, x + 1, y + math.max(0, math.floor((h - artH) / 2))) end
  local textX = x + artW + 2
  local titleColor = current and Theme.C.accentLight or Theme.C.text
  if compact then
    local titleW = math.max(3, x + w - moreW - textX - 1)
    Canvas:textFit(textX, y + 1, titleW, track.title, titleColor, bg)
    Canvas:textFit(textX, y + 2, math.max(3, titleW - durW - 1), track.artist, Theme.C.muted, bg)
    Canvas:textRight(x + w - moreW - durW, y + 2, durW, Util.fmtTime(track.dur), Theme.C.dim, bg)
  else
    local right = x + w - moreW - durW - 1
    local titleW = math.max(3, right - textX)
    Canvas:textFit(textX, y + math.max(0, math.floor((h - 2) / 2)), titleW, track.title, titleColor, bg)
    if h >= 4 then
      Canvas:textFit(textX, y + math.max(0, math.floor((h - 2) / 2)) + 1, titleW, track.artist, Theme.C.muted, bg)
    end
    Canvas:textRight(x + w - moreW - durW, y + math.max(0, math.floor((h - 1) / 2)), durW, Util.fmtTime(track.dur), Theme.C.dim, bg)
  end
  if current then Canvas:fill(x, y, 1, h, Theme.C.accent) end
  if moreW > 0 then
    local bx = x + w - moreW
    Canvas:roundRect(bx, y + math.max(0, math.floor((h - 3) / 2)), moreW, 3, 1, Theme.C.surface, bg)
    Canvas:icon("more", bx, y, moreW, h, Theme.C.muted, 1)
    UI.hit(bx, y, moreW, h, function() Screens.trackActions(track, opts) end)
  end
  UI.hit(x, y, w - moreW, h, function()
    App.sel[opts.key or "list"] = index
    if opts.onPlay then opts.onPlay(track, index)
    elseif opts.context then Player.playContext(opts.context, index, opts.source or "Queue")
    else Player.playContext({ track }, 1, opts.source or "Queue") end
  end)
  return thumb
end

function Screens.trackList(x, y, w, h, tracks, opts)
  opts = opts or {}
  local key = opts.key or "list"
  local rowH = 4
  local total = #tracks
  local visible = math.max(1, math.floor(h / rowH))
  local scroll = App.scroll[key] or 0
  scroll = Util.clamp(scroll, 0, math.max(0, total - visible))
  App.scroll[key] = scroll
  if total == 0 then
    UI.emptyState(x, y, w, h, opts.emptyIcon or "music", opts.emptyTitle or "Nothing here", opts.emptySub)
    return
  end
  local rail = total > visible
  local listW = w - (rail and 4 or 0)
  for i = 1, visible do
    local idx = scroll + i
    local track = tracks[idx]
    if track then
      Screens.trackRow(x, y + (i - 1) * rowH, listW, rowH, track, idx, {
        key = key,
        selected = (App.sel[key] == idx),
        context = opts.context or tracks,
        source = opts.source,
        playlist = opts.playlist,
        onPlay = opts.onPlay,
      })
    end
  end
  if rail then
    UI.scrollRail(x + w - 4, y, h, total, scroll, visible, function(delta)
      App.scroll[key] = Util.clamp(scroll + delta, 0, math.max(0, total - visible))
      UI.request(true)
    end)
  end
  App.listInfo[key] = { total = total, visible = visible, offset = scroll, tracks = tracks, opts = opts }
end

function Screens.albumGrid(x, y, w, h, albums, opts)
  opts = opts or {}
  local key = opts.key or "albums"
  local total = #albums
  if total == 0 then
    UI.emptyState(x, y, w, h, "disc", opts.emptyTitle or "No albums yet", opts.emptySub)
    return
  end
  local function calc(innerW, reserveRail)
    local gap = innerW >= 44 and 2 or 1
    local cols = innerW >= 52 and 3 or (innerW >= 26 and 2 or 1)
    local cardW = math.floor((innerW - (cols - 1) * gap) / cols)
    local maxArtH = math.max(3, h - 3)
    local artH = math.min(Util.round(cardW * 2 / 3), maxArtH)
    cardW = math.min(cardW, Util.round(artH * 1.5))
    cols = math.max(1, math.floor((innerW + gap) / (cardW + gap)))
    if cols < 1 then cols = 1 end
    if cols * cardW + (cols - 1) * gap > innerW then cols = cols - 1 end
    if cols < 1 then cols = 1; cardW = innerW end
    local cardH = artH + 3
    local rows = math.ceil(total / cols)
    local visible = math.max(1, math.floor(h / (cardH + gap)))
    return cols, cardW, artH, cardH, rows, visible, gap
  end
  local cols, cardW, artH, cardH, rows, visible, gap = calc(w, false)
  local rail = rows > visible
  if rail then
    cols, cardW, artH, cardH, rows, visible, gap = calc(w - 4, true)
  end
  local scroll = Util.clamp(App.scroll[key] or 0, 0, math.max(0, rows - visible))
  App.scroll[key] = scroll
  for r = 1, visible do
    local rowIdx = scroll + r - 1
    for c = 1, cols do
      local idx = rowIdx * cols + c
      local album = albums[idx]
      if album then
        local cx = x + (c - 1) * (cardW + gap)
        local cy = y + (r - 1) * (cardH + gap)
        Canvas:roundRect(cx, cy, cardW, cardH, 1, Theme.C.surface, Theme.C.bg)
        local art = Art.forAlbum(album, cardW, artH)
        if art then Canvas:art(art, cx, cy) end
        Canvas:textFit(cx + 1, cy + artH + 1, cardW - 2, album.name, Theme.C.text, Theme.C.surface)
        Canvas:textFit(cx + 1, cy + artH + 2, cardW - 2, album.artist, Theme.C.muted, Theme.C.surface)
        UI.hit(cx, cy, cardW, cardH, function()
          App.sel[key] = idx
          App.openAlbum(album)
        end)
        -- play overlay is added after the card hit so it wins hit-testing
        Canvas:roundRect(cx + cardW - 6, cy + artH - 5, 5, 4, 2, Theme.C.accent, Theme.C.surface)
        Canvas:icon("play5", cx + cardW - 6, cy + artH - 5, 5, 4, Theme.C.onAccent, 1)
        UI.hit(cx + cardW - 6, cy + artH - 5, 5, 4, function()
          Player.playContext(album.tracks, 1, album.name)
        end)
      end
    end
  end
  if rail then
    UI.scrollRail(x + w - 4, y, h, rows, scroll, visible, function(delta)
      App.scroll[key] = Util.clamp(scroll + delta, 0, math.max(0, rows - visible))
      UI.request(true)
    end)
  end
  App.listInfo[key] = { total = rows, visible = visible, offset = scroll, albums = albums, cols = cols, opts = opts }
end

function Screens.albumList(x, y, w, h, albums, opts)
  local key = opts and opts.key or "albumList"
  local total = #albums
  local rowH = 4
  local visible = math.max(1, math.floor(h / rowH))
  local scroll = Util.clamp(App.scroll[key] or 0, 0, math.max(0, total - visible))
  App.scroll[key] = scroll
  if total == 0 then UI.emptyState(x, y, w, h, "disc", "No albums"); return end
  local rail = total > visible
  local listW = w - (rail and 4 or 0)
  for i = 1, visible do
    local album = albums[scroll + i]
    if album then
      local ry = y + (i - 1) * rowH
      Canvas:roundRect(x, ry, listW, rowH, 1, Theme.C.surface, Theme.C.bg)
      local art = Art.forAlbum(album, 4, 3)
      if art then Canvas:art(art, x + 1, ry) end
      Canvas:textFit(x + 6, ry, listW - 14, album.name, Theme.C.text, Theme.C.surface)
      Canvas:textFit(x + 6, ry + 1, listW - 14, album.artist .. "  ·  " .. album.trackCount .. " " .. Util.plural(album.trackCount, "track"), Theme.C.muted, Theme.C.surface)
      Canvas:textRight(x, ry, listW - 2, Util.fmtTime(album.dur), Theme.C.dim, Theme.C.surface)
      UI.hit(x, ry, listW, rowH, function() App.sel[key] = scroll + i; App.openAlbum(album) end)
    end
  end
  if rail then
    UI.scrollRail(x + w - 4, y, h, total, scroll, visible, function(delta)
      App.scroll[key] = Util.clamp(scroll + delta, 0, math.max(0, total - visible))
    end)
  end
end

function Screens.artistList(x, y, w, h)
  local total = #Data.artists
  local rowH = 4
  local visible = math.max(1, math.floor(h / rowH))
  local scroll = Util.clamp(App.scroll.artists or 0, 0, math.max(0, total - visible))
  App.scroll.artists = scroll
  if total == 0 then UI.emptyState(x, y, w, h, "user", "No artists yet"); return end
  local rail = total > visible
  local listW = w - (rail and 4 or 0)
  for i = 1, visible do
    local artist = Data.artists[scroll + i]
    if artist then
      local ry = y + (i - 1) * rowH
      Canvas:roundRect(x, ry, listW, rowH, 1, (App.sel.artists == scroll + i) and Theme.C.accentDim or Theme.C.surface, Theme.C.bg)
      local art = artist.albums[1] and Art.forAlbum(artist.albums[1], 4, 3)
      if art then Canvas:art(art, x + 1, ry) end
      Canvas:textFit(x + 6, ry, listW - 14, artist.name, Theme.C.text, Theme.C.surface)
      Canvas:textFit(x + 6, ry + 1, listW - 14, #artist.albums .. " " .. Util.plural(#artist.albums, "album") .. "  ·  " .. artist.tracks .. " tracks", Theme.C.muted, Theme.C.surface)
      Canvas:textRight(x, ry, listW - 2, Util.fmtTime(artist.dur), Theme.C.dim, Theme.C.surface)
      UI.hit(x, ry, listW, rowH, function()
        App.sel.artists = scroll + i
        App.openArtist(artist.name)
      end)
    end
  end
  if rail then
    UI.scrollRail(x + w - 4, y, h, total, scroll, visible, function(delta)
      App.scroll.artists = Util.clamp(scroll + delta, 0, math.max(0, total - visible))
    end)
  end
end

function Screens.library()
  local m = UI.frame({ title = "LIBRARY", tab = "library", mini = true })
  local x, top, w, bot = m.contentX, m.bodyTop, m.contentW, m.bodyBot
  local tab = App.libTab or "albums"
  local tabs = { "albums", "artists", "songs", "favorites", "recent" }
  local labels
  if w >= 56 then
    labels = { "ALBUMS", "ARTISTS", "SONGS", "FAVORITES", "RECENT" }
  elseif w >= 40 then
    labels = { "ALBUMS", "ARTISTS", "SONGS", "FAVES", "RECENT" }
  else
    labels = { "ALB", "ART", "SNG", "FAV", "REC" }
  end
  local viewW = tab == "albums" and 5 or 0
  local chipsW = w - viewW - (viewW > 0 and 1 or 0)
  local gap = w >= 48 and 1 or 0
  local cw = math.floor((chipsW - gap * 4) / 5)
  local cx = x
  for i, id in ipairs(tabs) do
    UI.chip(cx, top, cw, 3, labels[i], tab == id, function()
      App.libTab = id
      App.scroll[id] = 0
      UI.request(true)
    end)
    cx = cx + cw + gap
  end
  if viewW > 0 then
    local icon = App.cfg.albumView == "grid" and "list" or "grid"
    UI.button(x + w - 4, top, 4, 3, "", { icon = icon, variant = "surface", fn = function()
      App.cfg.albumView = App.cfg.albumView == "grid" and "list" or "grid"
      Config.saveSoon()
      UI.request(true)
    end })
  end
  local listY = top + 4
  local listH = bot - listY + 1
  if tab == "albums" then
    if App.cfg.albumView == "list" then
      Screens.albumList(x, listY, w, listH, Data.albums, { key = "albumsList" })
    else
      Screens.albumGrid(x, listY, w, listH, Data.albums, { key = "albums", emptyTitle = "No albums yet", emptySub = "Point CC MUSIC at a music folder in Settings" })
    end
  elseif tab == "artists" then
    Screens.artistList(x, listY, w, listH)
  elseif tab == "songs" then
    Screens.trackList(x, listY, w, listH, Data.tracks, {
      key = "songs", source = "All Songs", emptyTitle = "No songs yet",
      emptySub = "Add .dfpwm files under music/<Album>/",
    })
  elseif tab == "favorites" then
    Screens.trackList(x, listY, w, listH, Data.favoriteTracks(), {
      key = "favorites", source = "Favorites", emptyTitle = "No favorites yet",
      emptySub = "Tap ... on a song to add it",
    })
  elseif tab == "recent" then
    Screens.trackList(x, listY, w, listH, Data.recentTracks(), {
      key = "recent", source = "Recently Played", emptyTitle = "Nothing played yet",
    })
  end
end

function Screens.album()
  local album = App.album
  if not album then App.go("library"); return end
  local m = UI.frame({ title = "ALBUM", tab = "library", mini = true, back = function() App.back() end })
  local x, top, w, bot = m.contentX, m.bodyTop, m.contentW, m.bodyBot
  local bodyH = bot - top + 1
  if m.compact then
    local headerH = math.min(9, math.max(7, bodyH - 5))
    local artRows = math.min(7, headerH - 1)
    local artCols = Util.round(artRows * 1.5)
    if artCols > w - 12 then artCols = w - 12; artRows = Util.round(artCols * 2 / 3) end
    local art = Art.forAlbum(album, artCols, artRows)
    Canvas:roundRect(x, top, artCols + 1, artRows + 1, 1, Theme.C.surface, Theme.C.bg)
    if art then Canvas:art(art, x, top) end
    local infoX = x + artCols + 2
    local infoW = x + w - infoX
    Canvas:textFit(infoX, top, infoW, album.name, Theme.C.text, Theme.C.bg)
    Canvas:textFit(infoX, top + 1, infoW, album.artist, Theme.C.muted, Theme.C.bg)
    Canvas:textFit(infoX, top + 2, infoW, album.trackCount .. " tracks", Theme.C.dim, Theme.C.bg)
    Canvas:textFit(infoX, top + 3, infoW, Util.fmtDuration(album.dur), Theme.C.dim, Theme.C.bg)
    local bw = 4
    UI.button(infoX, top + headerH - 3, bw, 3, "", { icon = "play3", variant = "primary", radius = 1, fn = function() Player.playContext(album.tracks, 1, album.name) end })
    UI.button(infoX + 5, top + headerH - 3, bw, 3, "", { icon = "shuffle3", variant = "surface2", radius = 1, fn = function() Player.playShuffled(album.tracks, album.name) end })
    UI.button(infoX + 10, top + headerH - 3, bw, 3, "", { icon = "more3", variant = "surface2", radius = 1, fn = function() App.openAlbumActions(album) end })
    local listY = top + headerH + 1
    Screens.trackList(x, listY, w, bot - listY + 1, album.tracks, { key = "album", context = album.tracks, source = album.name })
    return
  end
  local headerH = math.min(12, math.max(7, bodyH - 4))
  local artRows = headerH - 1
  local artCols = Util.round(artRows * 1.5)
  if artCols > math.floor(w * 0.48) then
    artCols = math.floor(w * 0.48)
    artRows = Util.round(artCols * 2 / 3)
  end
  local art = Art.forAlbum(album, artCols, artRows)
  Canvas:roundRect(x, top, artCols + 1, artRows + 1, 1, Theme.C.surface, Theme.C.bg)
  if art then Canvas:art(art, x, top) end
  local infoX = x + artCols + 2
  local infoW = x + w - infoX
  Canvas:textFit(infoX, top, infoW, album.name, Theme.C.text, Theme.C.bg)
  Canvas:textFit(infoX, top + 1, infoW, album.artist, Theme.C.muted, Theme.C.bg)
  Canvas:textFit(infoX, top + 3, infoW, album.trackCount .. " " .. Util.plural(album.trackCount, "track") .. "  ·  " .. Util.fmtDuration(album.dur), Theme.C.dim, Theme.C.bg)
  local bw = math.min(15, math.floor((infoW - 2) / 2))
  UI.button(infoX, top + headerH - 4, bw, 3, "PLAY", { variant = "primary", icon = "play5", fn = function()
    Player.playContext(album.tracks, 1, album.name)
  end })
  UI.button(infoX + bw + 2, top + headerH - 4, bw, 3, "SHUFFLE", { variant = "surface", icon = "shuffle7", fn = function()
    Player.playShuffled(album.tracks, album.name)
  end })
  UI.button(x + w - 5, top, 5, 3, "", { icon = "more", variant = "surface", fn = function()
    App.openAlbumActions(album)
  end })
  local listY = top + headerH + 1
  Screens.trackList(x, listY, w, bot - listY + 1, album.tracks, {
    key = "album", context = album.tracks, source = album.name,
  })
end

function Screens.artist()
  local artist = App.artist
  if not artist then App.go("library"); return end
  local m = UI.frame({ title = "ARTIST", tab = "library", mini = true, back = function() App.back() end })
  local x, top, w, bot = m.contentX, m.bodyTop, m.contentW, m.bodyBot
  local bodyH = bot - top + 1
  if m.compact then
    local headerH = math.min(8, math.max(6, bodyH - 6))
    local artRows = math.min(6, headerH - 1)
    local artCols = Util.round(artRows * 1.5)
    local first = artist.albums[1]
    local art = first and Art.forAlbum(first, artCols, artRows) or nil
    if art then Canvas:art(art, x, top) end
    local infoX = x + artCols + 2
    local infoW = x + w - infoX
    Canvas:textFit(infoX, top, infoW, artist.name, Theme.C.text, Theme.C.bg)
    Canvas:textFit(infoX, top + 1, infoW, #artist.albums .. " albums", Theme.C.muted, Theme.C.bg)
    Canvas:textFit(infoX, top + 2, infoW, artist.tracks .. " tracks", Theme.C.dim, Theme.C.bg)
    local all = {}
    for _, a in ipairs(artist.albums) do for _, t in ipairs(a.tracks) do all[#all + 1] = t end end
    UI.button(infoX, top + headerH - 3, 4, 3, "", { icon = "play3", variant = "primary", radius = 1, fn = function() Player.playContext(all, 1, artist.name) end })
    UI.button(infoX + 5, top + headerH - 3, 4, 3, "", { icon = "shuffle3", variant = "surface2", radius = 1, fn = function() Player.playShuffled(all, artist.name) end })
    local listY = top + headerH + 1
    Screens.albumGrid(x, listY, w, bot - listY + 1, artist.albums, { key = "artistAlbums" })
    return
  end
  local headerH = math.min(10, math.max(6, math.floor(bodyH * 0.36)))
  local artRows = headerH - 1
  local artCols = Util.round(artRows * 1.5)
  local first = artist.albums[1]
  local art = first and Art.forAlbum(first, artCols, artRows) or nil
  if art then Canvas:art(art, x, top) end
  local infoX = x + artCols + 2
  local infoW = x + w - infoX
  Canvas:textFit(infoX, top, infoW, artist.name, Theme.C.text, Theme.C.bg)
  Canvas:textFit(infoX, top + 1, infoW, #artist.albums .. " albums  ·  " .. artist.tracks .. " tracks", Theme.C.muted, Theme.C.bg)
  Canvas:textFit(infoX, top + 2, infoW, Util.fmtDuration(artist.dur), Theme.C.dim, Theme.C.bg)
  local all = {}
  for _, a in ipairs(artist.albums) do for _, t in ipairs(a.tracks) do all[#all + 1] = t end end
  local bw = math.min(15, math.floor((infoW - 2) / 2))
  UI.button(infoX, top + headerH - 4, bw, 3, "PLAY", { variant = "primary", icon = "play5", fn = function()
    Player.playContext(all, 1, artist.name)
  end })
  UI.button(infoX + bw + 2, top + headerH - 4, bw, 3, "SHUFFLE", { variant = "surface", icon = "shuffle7", fn = function()
    Player.playShuffled(all, artist.name)
  end })
  local listY = top + headerH + 1
  Screens.albumGrid(x, listY, w, bot - listY + 1, artist.albums, { key = "artistAlbums" })
end

function Screens.newPlaylist()
  UI.askText("NEW PLAYLIST", "", function(name)
    if Util.trim(name) == "" then return false, "Enter a name" end
    local pl = Data.createPlaylist(name)
    UI.toast("Created " .. pl.name, "success")
    App.openPlaylist(pl)
    return true
  end)
end

function Screens.playlists()
  local m = UI.frame({ title = "PLAYLISTS", tab = "playlists", mini = true })
  local x, top, w, bot = m.contentX, m.bodyTop, m.contentW, m.bodyBot
  UI.button(x + w - 9, top, 9, 3, "NEW", { variant = "primary", icon = "plus", fn = Screens.newPlaylist })
  Canvas:textFit(x, top, w - 8, #Data.playlists .. " " .. Util.plural(#Data.playlists, "playlist"), Theme.C.dim, Theme.C.bg)
  local listY = top + 4
  local listH = bot - listY + 1
  if #Data.playlists == 0 then
    UI.emptyState(x, listY, w, listH, "playlist", "No playlists yet", "Create one to collect your favorite tracks")
    UI.button(x + math.floor((w - math.min(22, w)) / 2), bot - 3, math.min(22, w), 3, "CREATE PLAYLIST", {
      variant = "primary", icon = "plus", fn = Screens.newPlaylist,
    })
    return
  end
  Screens.playlistGrid(x, listY, w, listH)
end

function Screens.playlistGrid(x, y, w, h)
  local total = #Data.playlists
  local function calc(innerW)
    local gap = 2
    local cols = innerW >= 40 and 3 or (innerW >= 24 and 2 or 1)
    local cardW = math.floor((innerW - (cols - 1) * gap) / cols)
    local maxArtH = math.max(3, h - 2)
    local artH = math.min(Util.round(cardW * 2 / 3), maxArtH)
    cardW = math.min(cardW, Util.round(artH * 1.5))
    cols = math.max(1, math.floor((innerW + gap) / (cardW + gap)))
    if cols * cardW + (cols - 1) * gap > innerW then cols = cols - 1 end
    if cols < 1 then cols = 1; cardW = innerW end
    local cardH = artH + 2
    local rows = math.ceil(total / cols)
    local visible = math.max(1, math.floor(h / (cardH + gap)))
    return cols, cardW, artH, cardH, rows, visible, gap
  end
  local cols, cardW, artH, cardH, rows, visible, gap = calc(w)
  local rail = rows > visible
  if rail then cols, cardW, artH, cardH, rows, visible, gap = calc(w - 4) end
  local scroll = Util.clamp(App.scroll.playlists or 0, 0, math.max(0, rows - visible))
  App.scroll.playlists = scroll
  for r = 1, visible do
    for c = 1, cols do
      local idx = (scroll + r - 1) * cols + c
      local pl = Data.playlists[idx]
      if pl then
        local cx = x + (c - 1) * (cardW + gap)
        local cy = y + (r - 1) * (cardH + gap)
        Canvas:roundRect(cx, cy, cardW, cardH, 1, Theme.C.surface, Theme.C.bg)
        local art = Art.forPlaylist(pl, cardW, artH)
        if art then Canvas:art(art, cx, cy) end
        Canvas:textFit(cx + 1, cy + artH + 1, cardW - 2, pl.name, Theme.C.text, Theme.C.surface)
        UI.hit(cx, cy, cardW, cardH, function() App.openPlaylist(pl) end)
      end
    end
  end
  if rail then
    UI.scrollRail(x + w - 4, y, h, rows, scroll, visible, function(delta)
      App.scroll.playlists = Util.clamp(scroll + delta, 0, math.max(0, rows - visible))
    end)
  end
end

function Screens.playlist()
  local pl = App.playlist
  if not pl then App.go("playlists"); return end
  local m = UI.frame({ title = "PLAYLIST", tab = "playlists", mini = true, back = function() App.back() end })
  local x, top, w, bot = m.contentX, m.bodyTop, m.contentW, m.bodyBot
  local bodyH = bot - top + 1
  if m.compact then
    local headerH = math.min(9, math.max(7, bodyH - 5))
    local artRows = math.min(7, headerH - 1)
    local artCols = Util.round(artRows * 1.5)
    local art = Art.forPlaylist(pl, artCols, artRows)
    if art then Canvas:art(art, x, top) end
    local infoX = x + artCols + 2
    local infoW = x + w - infoX
    local tracks = Data.playlistTracks(pl)
    Canvas:textFit(infoX, top, infoW, pl.name, Theme.C.text, Theme.C.bg)
    Canvas:textFit(infoX, top + 1, infoW, #tracks .. " " .. Util.plural(#tracks, "track"), Theme.C.muted, Theme.C.bg)
    Canvas:textFit(infoX, top + 2, infoW, Util.fmtDuration(Data.playlistDuration(pl)), Theme.C.dim, Theme.C.bg)
    UI.button(infoX, top + headerH - 3, 4, 3, "", { icon = "play3", variant = "primary", radius = 1, fn = function()
      if #tracks > 0 then Player.playContext(tracks, 1, pl.name) else UI.toast("Playlist is empty", "warning") end
    end })
    UI.button(infoX + 5, top + headerH - 3, 4, 3, "", { icon = "shuffle3", variant = "surface2", radius = 1, fn = function()
      if #tracks > 0 then Player.playShuffled(tracks, pl.name) end
    end })
    UI.button(infoX + 10, top + headerH - 3, 4, 3, "", { icon = "more3", variant = "surface2", radius = 1, fn = function() Screens.playlistActions(pl) end })
    local listY = top + headerH + 1
    local listH = bot - listY + 1
    Screens.trackList(x, listY, w, listH, tracks, { key = "playlist", context = tracks, source = pl.name, playlist = pl,
      emptyTitle = "Playlist is empty", emptySub = "Add tracks from the library" })
    if #tracks == 0 then
      local bw = math.min(20, w)
      UI.button(x + math.floor((w - bw) / 2), listY + math.floor(listH / 2) + 3, bw, 3, "ADD SONGS", { variant = "primary", icon = "plus", fn = function() App.openPlaylistAdd(pl) end })
    end
    return
  end
  local headerH = math.min(11, math.max(7, bodyH - 4))
  local artRows = headerH - 1
  local artCols = Util.round(artRows * 1.5)
  if artCols > math.floor(w * 0.45) then artCols = math.floor(w * 0.45); artRows = Util.round(artCols * 2 / 3) end
  local art = Art.forPlaylist(pl, artCols, artRows)
  Canvas:roundRect(x, top, artCols + 1, artRows + 1, 1, Theme.C.surface, Theme.C.bg)
  if art then Canvas:art(art, x, top) end
  local infoX = x + artCols + 2
  local infoW = x + w - infoX
  local tracks = Data.playlistTracks(pl)
  Canvas:textFit(infoX, top, infoW, pl.name, Theme.C.text, Theme.C.bg)
  Canvas:textFit(infoX, top + 1, infoW, #tracks .. " " .. Util.plural(#tracks, "track") .. "  ·  " .. Util.fmtDuration(Data.playlistDuration(pl)), Theme.C.muted, Theme.C.bg)
  local bw = math.min(15, math.floor((infoW - 2) / 2))
  UI.button(infoX, top + headerH - 4, bw, 3, "PLAY", { variant = "primary", icon = "play5", fn = function()
    if #tracks > 0 then Player.playContext(tracks, 1, pl.name) else UI.toast("Playlist is empty", "warning") end
  end })
  UI.button(infoX + bw + 2, top + headerH - 4, bw, 3, "SHUFFLE", { variant = "surface", icon = "shuffle7", fn = function()
    if #tracks > 0 then Player.playShuffled(tracks, pl.name) else UI.toast("Playlist is empty", "warning") end
  end })
  UI.button(x + w - 5, top, 5, 3, "", { icon = "more", variant = "surface", fn = function() Screens.playlistActions(pl) end })
  local listY = top + headerH + 1
  local listH = bot - listY + 1
  Screens.trackList(x, listY, w, listH, tracks, {
    key = "playlist", context = tracks, source = pl.name, playlist = pl,
    emptyTitle = "Playlist is empty",
    emptySub = "Add some tracks to get started",
  })
  if #tracks == 0 then
    local bw = math.min(22, w)
    UI.button(x + math.floor((w - bw) / 2), listY + math.floor(listH / 2) + 4, bw, 3, "ADD SONGS", {
      variant = "primary", icon = "plus", fn = function() App.openPlaylistAdd(pl) end,
    })
  end
end

function Screens.playlistActions(pl)
  if not pl then return end
  UI.actions(pl.name, {
    { label = "Add songs", icon = "plus", value = "add" },
    { label = "Rename", icon = "edit", value = "rename" },
    { label = "Delete playlist", icon = "trash", value = "delete", danger = true },
  }, function(value)
    if value == "add" then App.openPlaylistAdd(pl) return end
    if value == "rename" then
      UI.askText("RENAME PLAYLIST", pl.name, function(name)
        if Util.trim(name) == "" then return false, "Enter a name" end
        Data.renamePlaylist(pl, name)
        UI.toast("Renamed", "success")
        return true
      end)
    elseif value == "delete" then
      UI.confirm("DELETE PLAYLIST", "Delete \"" .. pl.name .. "\"? This cannot be undone.", function()
        Data.deletePlaylist(pl)
        App.playlist = nil
        App.go("playlists")
        UI.toast("Playlist deleted", "info")
      end, { danger = true, yesLabel = "DELETE" })
    end
  end)
end

function Screens.playlistAdd()
  local pl = App.playlist
  if not pl then App.go("playlists"); return end
  local m = UI.frame({ title = "ADD SONGS", tab = "playlists", mini = true, back = function() App.back() end })
  local x, top, w, bot = m.contentX, m.bodyTop, m.contentW, m.bodyBot
  Canvas:textFit(x, top, w, "Add to " .. pl.name, Theme.C.muted, Theme.C.bg)
  local listY = top + 2
  local total = #Data.tracks
  local rowH = 4
  local visible = math.max(1, math.floor((bot - listY + 1) / rowH))
  local scroll = Util.clamp(App.scroll.playlistAdd or 0, 0, math.max(0, total - visible))
  App.scroll.playlistAdd = scroll
  local rail = total > visible
  local listW = w - (rail and 4 or 0)
  local inList = {}
  for _, p in ipairs(pl.tracks) do inList[p] = true end
  for i = 1, visible do
    local track = Data.tracks[scroll + i]
    if track then
      local ry = listY + (i - 1) * rowH
      Canvas:roundRect(x, ry, listW, rowH, 1, Theme.C.surface, Theme.C.bg)
      Canvas:textFit(x + 2, ry, listW - 8, track.title, Theme.C.text, Theme.C.surface)
      Canvas:textFit(x + 2, ry + 1, listW - 8, track.artist, Theme.C.muted, Theme.C.surface)
      local added = inList[track.path]
      UI.button(x + listW - 5, ry, 5, rowH, "", {
        icon = added and "check" or "plus", variant = added and "active" or "surface",
        fn = function()
          if added then
            Data.removeTrackFromPlaylist(pl, track)
            inList[track.path] = nil
          else
            Data.addTrackToPlaylist(pl, track)
            inList[track.path] = true
            UI.toast("Added " .. track.title, "success")
          end
          UI.request(true)
        end,
      })
    end
  end
  if rail then
    UI.scrollRail(x + w - 4, listY, bot - listY + 1, total, scroll, visible, function(delta)
      App.scroll.playlistAdd = Util.clamp(scroll + delta, 0, math.max(0, total - visible))
    end)
  end
end

function Screens.queue()
  local m = UI.frame({ title = (Canvas.w < 40 and "QUE" or "QUEUE"), tab = "music", mini = false, back = function() App.back() end })
  local x, top, w, bot = m.contentX, m.bodyTop, m.contentW, m.bodyBot
  Canvas:textFit(x, top, w - 14, #Player.qorder .. " items  ·  " .. Player.queueNumber(), Theme.C.dim, Theme.C.bg)
  UI.button(x + w - 12, top, 12, 3, "CLEAR", { variant = "surface", icon = "trash", fn = function()
    if #Player.qorder == 0 then return end
    UI.confirm("CLEAR QUEUE", "Remove all tracks from the queue?", function() Player.clearQueue() end, { danger = true, yesLabel = "CLEAR" })
  end })
  local listY = top + 4
  local total = #Player.qorder
  local rowH = 4
  local visible = math.max(1, math.floor((bot - listY + 1) / rowH))
  local scroll = Util.clamp(App.scroll.queue or 0, 0, math.max(0, total - visible))
  App.scroll.queue = scroll
  local rail = total > visible
  local listW = w - (rail and 4 or 0)
  if total == 0 then
    UI.emptyState(x, listY, w, bot - listY + 1, "queue9", "Queue is empty", "Add songs from the library")
    return
  end
  for i = 1, visible do
    local idx = scroll + i
    local entry = Player.qorder[idx]
    if entry and entry.track then
      local track = entry.track
      local ry = listY + (i - 1) * rowH
      local current = entry == Player.curEntry
      Canvas:roundRect(x, ry, listW, rowH, 1, current and Theme.C.accentDim or Theme.C.surface, Theme.C.bg)
      Canvas:textFit(x + 1, ry, 4, tostring(idx), current and Theme.C.accentLight or Theme.C.dim, current and Theme.C.accentDim or Theme.C.surface)
      local textW = math.max(5, listW - 16)
      Canvas:textFit(x + 5, ry, textW, track.title, current and Theme.C.accentLight or Theme.C.text, current and Theme.C.accentDim or Theme.C.surface)
      Canvas:textFit(x + 5, ry + 1, textW, track.artist, Theme.C.muted, current and Theme.C.accentDim or Theme.C.surface)
      Canvas:textRight(x + listW - 10, ry, 5, Util.fmtTime(track.dur), Theme.C.dim, current and Theme.C.accentDim or Theme.C.surface)
      UI.button(x + listW - 4, ry, 4, rowH, "", { icon = "more", variant = "surface", fn = function()
        Screens.trackActions(track, { queueEntry = entry, index = idx, key = "queue" })
      end })
      UI.hit(x, ry, listW - 4, rowH, function()
        App.sel.queue = idx
        Player.playEntryAt(idx)
      end)
    end
  end
  if rail then
    UI.scrollRail(x + w - 4, listY, bot - listY + 1, total, scroll, visible, function(delta)
      App.scroll.queue = Util.clamp(scroll + delta, 0, math.max(0, total - visible))
    end)
  end
end

--======== 94_screens_search.lua ========
------------------------------------------------------------------ screens: search / lyrics
function Screens.applySearch(query, scrollReset)
  App.search.query = Util.clean(query)
  App.search.results = Data.search(App.search.query, 160)
  if scrollReset ~= false then App.search.scroll = 0 end
  UI.request(true)
end

function Screens.openSearchKeyboard()
  if UI.keyboard then return end
  UI.openKeyboard({
    title = "SEARCH",
    value = App.search.query or "",
    hint = "Song, album or artist",
    mode = "text",
    maxLen = 60,
    allowEmpty = true,
    onChange = function(value) Screens.applySearch(value) end,
    onDone = function(value)
      Screens.applySearch(value)
      if #value >= 2 and App.addSearchHistory then App.addSearchHistory(value) end
      return true
    end,
  })
end

function Screens.searchEmpty(x, y, w, h)
  local history = App.searchHistory or {}
  if #history > 0 then
    Canvas:textFit(x, y, w, "RECENT SEARCHES", Theme.C.dim, Theme.C.bg)
    local cx, cy = x, y + 2
    for i, q in ipairs(history) do
      local label = Util.fit(q, 18)
      local bw = math.min(w, #label + 4)
      if cx + bw > x + w then cx = x; cy = cy + 4 end
      if cy + 3 <= y + h then
        UI.chip(cx, cy, bw, 3, label, false, function()
          Screens.applySearch(q)
          Screens.openSearchKeyboard()
        end)
        cx = cx + bw + 2
      end
    end
    y = cy + 5
  end
  if y + 8 < y + h then
    Canvas:textFit(x, y, w, "BROWSE", Theme.C.dim, Theme.C.bg)
    local bw = math.floor((w - 2) / 2)
    local compact = w < 40
    UI.button(x, y + 2, bw, 3, compact and "SONGS" or "ALL SONGS", { variant = "surface", icon = "music", fn = function()
      App.libTab = "songs"; App.goTab("library")
    end })
    UI.button(x + bw + 2, y + 2, bw, 3, compact and "FAVES" or "FAVORITES", { variant = "surface", icon = "heart", fn = function()
      App.libTab = "favorites"; App.goTab("library")
    end })
    UI.button(x, y + 6, bw, 3, "ALBUMS", { variant = "surface", icon = "disc", fn = function()
      App.libTab = "albums"; App.goTab("library")
    end })
    UI.button(x + bw + 2, y + 6, bw, 3, "RECENT", { variant = "surface", icon = "clock", fn = function()
      App.libTab = "recent"; App.goTab("library")
    end })
  end
end

function Screens.searchResults(x, y, w, h)
  local res = App.search.results
  local totalTracks = #res.tracks
  local entries = {}
  local top = res.tracks[1]
  if top then
    entries[#entries + 1] = { kind = "header", text = "TOP RESULT" }
    entries[#entries + 1] = { kind = "top", track = top, index = 1 }
  end
  if totalTracks > 0 then
    entries[#entries + 1] = { kind = "header", text = "SONGS  " .. totalTracks }
    for i = 1, math.min(totalTracks, 12) do
      entries[#entries + 1] = { kind = "track", track = res.tracks[i], index = i }
    end
  end
  if #res.albums > 0 then
    entries[#entries + 1] = { kind = "header", text = "ALBUMS  " .. #res.albums }
    for i = 1, math.min(#res.albums, 4) do
      entries[#entries + 1] = { kind = "album", album = res.albums[i] }
    end
  end
  if #res.artists > 0 then
    entries[#entries + 1] = { kind = "header", text = "ARTISTS  " .. #res.artists }
    for i = 1, math.min(#res.artists, 3) do
      entries[#entries + 1] = { kind = "artist", artist = res.artists[i] }
    end
  end
  if #entries == 0 then
    UI.emptyState(x, y, w, h, "search", "No results", "Try a different word")
    return
  end
  local rail = false
  local listW = w
  local scroll = math.max(1, App.search.scroll or 1)
  local function entryHeight(e)
    if e.kind == "header" then return 2
    elseif e.kind == "top" then return 6
    else return 4 end
  end
  local totalH = 0
  for _, e in ipairs(entries) do totalH = totalH + entryHeight(e) end
  if totalH > h then rail = true; listW = w - 4 end
  local yy = y
  local drawn = 0
  for i = scroll, #entries do
    local e = entries[i]
    local eh = entryHeight(e)
    if yy + eh - 1 > y + h - 1 then break end
    if e.kind == "header" then
      UI.sectionTitle(x, yy, listW, e.text)
    elseif e.kind == "top" then
      local track = e.track
      Canvas:roundRect(x, yy, listW, 6, 1, Theme.C.surface2, Theme.C.bg)
      local art = Art.forTrack(track, 8, 5)
      if art then Canvas:art(art, x + 1, yy) end
      Canvas:textFit(x + 10, yy + 1, listW - 12, track.title, Theme.C.text, Theme.C.surface2)
      Canvas:textFit(x + 10, yy + 2, listW - 12, track.artist, Theme.C.muted, Theme.C.surface2)
      Canvas:textFit(x + 10, yy + 3, listW - 12, "SONG  ·  " .. track.album, Theme.C.dim, Theme.C.surface2)
      UI.hit(x, yy, listW, 6, function()
        if App.addSearchHistory then App.addSearchHistory(App.search.query) end
        Player.playContext(res.tracks, e.index, "Search: " .. App.search.query)
      end)
    elseif e.kind == "track" then
      Screens.trackRow(x, yy, listW, 4, e.track, e.index, {
        key = "search",
        context = res.tracks,
        source = "Search: " .. App.search.query,
        onPlay = function(_, idx)
          if App.addSearchHistory then App.addSearchHistory(App.search.query) end
          Player.playContext(res.tracks, idx, "Search: " .. App.search.query)
        end,
      })
    elseif e.kind == "album" then
      local album = e.album
      Canvas:roundRect(x, yy, listW, 4, 1, Theme.C.surface, Theme.C.bg)
      local art = Art.forAlbum(album, 4, 3)
      if art then Canvas:art(art, x + 1, yy) end
      Canvas:textFit(x + 6, yy, listW - 8, album.name, Theme.C.text, Theme.C.surface)
      Canvas:textFit(x + 6, yy + 1, listW - 8, "ALBUM  ·  " .. album.artist, Theme.C.muted, Theme.C.surface)
      UI.hit(x, yy, listW, 4, function()
        if App.addSearchHistory then App.addSearchHistory(App.search.query) end
        App.openAlbum(album)
      end)
    elseif e.kind == "artist" then
      local artist = e.artist
      Canvas:roundRect(x, yy, listW, 4, 1, Theme.C.surface, Theme.C.bg)
      local art = artist.albums[1] and Art.forAlbum(artist.albums[1], 4, 3)
      if art then Canvas:art(art, x + 1, yy) end
      Canvas:textFit(x + 6, yy, listW - 8, artist.name, Theme.C.text, Theme.C.surface)
      Canvas:textFit(x + 6, yy + 1, listW - 8, "ARTIST  ·  " .. #artist.albums .. " albums", Theme.C.muted, Theme.C.surface)
      UI.hit(x, yy, listW, 4, function()
        if App.addSearchHistory then App.addSearchHistory(App.search.query) end
        App.openArtist(artist.name)
      end)
    end
    yy = yy + eh
    drawn = i
  end
  if rail then
    local visible = math.max(1, math.floor(h / 4))
    UI.scrollRail(x + w - 4, y, h, #entries, scroll - 1, visible, function(delta)
      App.search.scroll = Util.clamp((App.search.scroll or 1) + delta, 1, #entries)
      UI.request(true)
    end)
  end
end

function Screens.search()
  local m = UI.frame({ title = "SEARCH", tab = "search", mini = true })
  local x, top, w, bot = m.contentX, m.bodyTop, m.contentW, m.bodyBot
  local fieldH = 3
  Canvas:roundRect(x, top, w, fieldH, 1, Theme.C.surface, Theme.C.bg)
  Canvas:icon("search", x + 1, top, 4, fieldH, Theme.C.muted, 1)
  local q = App.search.query or ""
  if q == "" then
    Canvas:textFit(x + 5, top + 1, w - 9, "Search songs, albums, artists", Theme.C.dim, Theme.C.surface)
  else
    Canvas:textFit(x + 5, top + 1, w - 9, q, Theme.C.text, Theme.C.surface)
  end
  UI.hit(x, top, w - (q ~= "" and 4 or 0), fieldH, Screens.openSearchKeyboard)
  if q ~= "" then
    UI.button(x + w - 4, top, 4, fieldH, "", { icon = "closeSmall", variant = "surface", fn = function()
      Screens.applySearch("")
      if UI.keyboard then UI.keyboard.value = ""; UI.keyboard.cursor = 1 end
      UI.request(true)
    end })
  end
  local listY = top + fieldH + 2
  local listH = bot - listY + 1
  if q == "" then
    Screens.searchEmpty(x, listY, w, listH)
  else
    Screens.searchResults(x, listY, w, listH)
  end
end

------------------------------------------------------------------ lyrics screen
function Screens.lyricsControls(x, y, w)
  local bw = 6
  local gap = 2
  local total = bw * 3 + gap * 2
  local sx = x + math.floor((w - total) / 2)
  UI.button(sx, y, bw, 3, "-10", { variant = "surface", fn = function() Player.seekBy(-10) end })
  UI.button(sx + bw + gap, y, bw, 3, "", {
    icon = Player.paused and "play" or "pause", variant = "primary",
    fn = function() Player.togglePause() end,
  })
  UI.button(sx + (bw + gap) * 2, y, bw, 3, "+10", { variant = "surface", fn = function() Player.seekBy(10) end })
end

function Screens.lyrics()
  local track = App.lyricsTrack or Player.cur
  local isCurrent = track ~= nil and track == Player.cur
  local m = UI.frame({ title = "LYRICS", tab = "music", hideNav = true, mini = false, back = function() App.back() end })
  local x, top, w, bot = m.contentX, m.bodyTop, m.contentW, m.bodyBot
  if not track then
    UI.emptyState(x, top, w, bot - top + 1, "lyrics9", "Nothing playing", "Start a song to see its lyrics")
    return
  end
  if App.lyricTrackPath ~= track.path then
    App.lyricTrackPath = track.path
    App.lyricScroll = 0
    App.lyricFollow = true
  end
  local lrc = Screens.lyricsFor(track)
  Canvas:textFit(x, top, w - 16, track.title, Theme.C.text, Theme.C.bg)
  Canvas:textFit(x, top + 1, w - 16, track.artist, Theme.C.muted, Theme.C.bg)
  if not isCurrent then
    Canvas:roundRect(x + w - 12, top, 12, 2, 1, Theme.C.surface2, Theme.C.bg)
    Canvas:textCenter(x + w - 12, top, 12, "NOT PLAYING", Theme.C.warning, Theme.C.surface2)
  elseif lrc then
    Canvas:roundRect(x + w - 15, top, 15, 2, 1, lrc.sync and Theme.C.accentDim or Theme.C.surface, Theme.C.bg)
    Canvas:textCenter(x + w - 15, top, 15, lrc.sync and "SYNCED LRC" or "UNSYNCED TEXT",
      lrc.sync and Theme.C.accentLight or Theme.C.muted, lrc.sync and Theme.C.accentDim or Theme.C.surface)
    if lrc.sync and isCurrent then
      -- FOLLOW omitted (ProOnlyUNO): lyrics always sync-scroll

    end
  end
  if not lrc then
    UI.emptyState(x, top + 4, w, bot - top - 7, "lyrics9", "No lyrics found", "Add a matching .lrc or .txt file")
    if isCurrent then
      Screens.lyricsControls(x, bot - 3, w)
    else
      local bw = math.min(22, w)
      UI.button(x + math.floor((w - bw) / 2), bot - 3, bw, 3, "PLAY THIS TRACK", {
        variant = "primary", icon = "play5", fn = function()
          Player.playContext({ track }, 1, track.album or "Queue")
          App.lyricsTrack = track
          UI.request(true)
        end,
      })
    end
    return
  end
  local controlsH = 5
  local bodyBottom = bot - controlsH
  local lineW = w - 8
  local rows = Lrc.displayRows(lrc, lineW)
  local currentLine = (lrc.sync and isCurrent) and Lrc.currentIndex(lrc, Audio.position(), 1) or nil
  local currentRow = 1
  if lrc.sync and currentLine then
    for i, row in ipairs(rows) do
      if row.index == currentLine and not row.cont then currentRow = i; break end
    end
  end
  local visible = math.max(1, math.floor((bodyBottom - (top + 4) + 1) / 2))
  local center = math.floor(visible / 2)
  if App.lyricFollow and lrc.sync and isCurrent then
    local target = currentRow - center - 1
    target = Util.clamp(target, 0, math.max(0, #rows - visible))
    App.lyricScroll = App.lyricScroll + (target - (App.lyricScroll or 0)) * 0.35
  end
  App.lyricScroll = Util.clamp(App.lyricScroll or 0, 0, math.max(0, #rows - visible))
  local offset = math.floor((App.lyricScroll or 0) + 0.5)
  local y = top + 4
  if #rows <= visible and offset == 0 then
    y = top + 4 + math.floor((visible - #rows) / 2) * 2
  end
  for i = offset + 1, math.min(#rows, offset + visible) do
    local row = rows[i]
    local isCurrent = lrc.sync and row.index == currentLine
    local bg = isCurrent and Theme.C.accentDim or Theme.C.bg
    local fg = isCurrent and Theme.C.accentLight or (lrc.sync and (row.index < (currentLine or 0) and Theme.C.muted or Theme.C.dim) or Theme.C.muted)
    if isCurrent then
      Canvas:roundRect(x - 1, y, w + 2, 2, 1, Theme.C.accentDim, Theme.C.bg)
      Canvas:fill(x - 1, y, 1, 2, Theme.C.accent)
    end
    Canvas:textFit(x + 1, y, lineW, row.text, fg, bg)
    UI.hit(x, y, w - 5, 2, function()
      if lrc.sync and row.time then
        Player.seek(row.time + 0.02)
        App.lyricFollow = true
      end
    end)
    y = y + 2
  end
  -- scroll controls
  UI.button(x + w - 4, top + 6, 4, 3, "", { icon = "up", variant = "surface", fn = function()
    App.lyricFollow = true -- always sync
    App.lyricScroll = math.max(0, (App.lyricScroll or 0) - 3)
  end })
  UI.button(x + w - 4, bodyBottom - 3, 4, 3, "", { icon = "down", variant = "surface", fn = function()
    App.lyricFollow = true -- always sync
    App.lyricScroll = math.min(math.max(0, #rows - visible), (App.lyricScroll or 0) + 3)
  end })
  if isCurrent then
    Screens.lyricsControls(x, bot - 3, w)
  else
    local bw = math.min(22, w)
    UI.button(x + math.floor((w - bw) / 2), bot - 3, bw, 3, "PLAY THIS TRACK", {
      variant = "primary", icon = "play5", fn = function()
        Player.playContext({ track }, 1, track.album or "Queue")
        App.lyricsTrack = track
        UI.request(true)
      end,
    })
  end
  if lrc.sync and isCurrent then UI.request() end
end

--======== 95_screens_settings.lua ========
------------------------------------------------------------------ screens: settings
function Screens.leaveSettings()
  Auth.lock()
  App.goTab("home")
end

function Screens.requireRoot()
  if Auth.isRoot() then return true end
  App.goTab("home")
  UI.loginPrompt(function() App.go("settings") end)
  return false
end

-- Vertical flow with a scroll rail; entries can have arbitrary heights.
function Screens.flow(entries, x, y, w, h, key)
  local total = 0
  for _, e in ipairs(entries) do total = total + (e.h or 1) end
  local scroll = Util.clamp(App.scroll[key] or 0, 0, math.max(0, total - h))
  App.scroll[key] = scroll
  local rail = total > h
  local innerW = w - (rail and 4 or 0)
  local cy = 0
  for _, e in ipairs(entries) do
    local eh = e.h or 1
    local sy = y + cy - scroll
    if sy < y + h and sy + eh > y then
      e.draw(x, sy, innerW, eh)
    end
    cy = cy + eh
    if cy - scroll >= h then break end
  end
  if rail then
    UI.scrollRail(x + w - 4, y, h, total, scroll, h, function(delta)
      App.scroll[key] = Util.clamp(scroll + delta, 0, math.max(0, total - h))
      UI.request(true)
    end)
  end
end

function Screens.settings()
  if not Screens.requireRoot() then return end
  local m = UI.frame({ title = "SETTINGS", hideNav = true, back = Screens.leaveSettings, lock = UI.lockRoot })
  local x, top, w, bot = m.contentX, m.bodyTop, m.contentW, m.bodyBot
  Canvas:textFit(x, top, w, "ADMINISTRATION · ROOT", Theme.C.accent, Theme.C.bg)
  Canvas:textFit(x, top + 1, w, Auth.username() .. " · auto-lock " .. (App.cfg.autoLock == 0 and "never" or (App.cfg.autoLock .. " min")), Theme.C.dim, Theme.C.bg)
  local y = top + 3
  local items = {
    { title = "APPEARANCE", short = "Theme & scale", sub = "Text scale, theme, motion", icon = "palette", screen = "settingsAppearance" },
    { title = "AUDIO OUTPUT", short = "Speakers & volume", sub = "Speakers, gains, volume, DFPWM", icon = "speaker", screen = "settingsAudio" },
    { title = "LIBRARY", short = "Folders & art", sub = "Folders, rescans, artwork, metadata, lyrics", icon = "library", screen = "settingsLibrary" },
    { title = "SECURITY", short = "Root login", sub = "Root username, PIN/password, recovery", icon = "lock", screen = "settingsSecurity" },
    { title = "ABOUT & DIAGNOSTICS", short = "Diagnostics", sub = "Hardware, capabilities, version, controls", icon = "info", screen = "settingsAbout" },
    { title = "STOP CC MUSIC", short = "Save & close", sub = "Save state and shut down safely", icon = "close", action = "stop" },
  }
  local itemH = 4
  local gap = 1
  local visible = math.max(1, math.floor((bot - y + 1) / (itemH + gap)))
  local scroll = Util.clamp(App.scroll.settings or 0, 0, math.max(0, #items - visible))
  App.scroll.settings = scroll
  local rail = #items > visible
  local listW = w - (rail and 4 or 0)
  for i = 1, visible do
    local it = items[scroll + i]
    if it then
      local ry = y + (i - 1) * (itemH + gap)
      Canvas:roundRect(x, ry, listW, itemH, 1, Theme.C.surface, Theme.C.bg)
      Canvas:icon(it.icon, x, ry, 6, itemH, Theme.C.accent, 1)
      Canvas:textFit(x + 6, ry + 1, listW - 8, it.title, Theme.C.text, Theme.C.surface)
      Canvas:textFit(x + 6, ry + 2, listW - 8, m.compact and (it.short or it.sub) or it.sub, Theme.C.dim, Theme.C.surface)
      UI.hit(x, ry, listW, itemH, function()
        if it.action == "stop" then
          UI.confirm("STOP CC MUSIC", "Save the queue and settings, then close?", function()
            App.quit = true
          end, { danger = true, yesLabel = "STOP" })
        else
          App.go(it.screen)
        end
      end)
    end
  end
  if rail then
    UI.scrollRail(x + w - 4, y, bot - y + 1, #items, scroll, visible, function(delta)
      App.scroll.settings = Util.clamp(scroll + delta, 0, math.max(0, #items - visible))
    end)
  end
end

function Screens.settingsHeader(title, back)
  return UI.frame({ title = title, hideNav = true, back = back or function() App.back() end, lock = UI.lockRoot })
end

function Screens.settingsAppearance()
  if not Screens.requireRoot() then return end
  local m = Screens.settingsHeader("APPEARANCE")
  local x, top, w, bot = m.contentX, m.bodyTop, m.contentW, m.bodyBot
  local entries = {}
  entries[#entries + 1] = { h = 2, draw = function(ax, ay, aw) UI.sectionTitle(ax, ay, aw, "ACCENT COLOUR") end }
  entries[#entries + 1] = { h = 9, draw = function(ax, ay, aw)
    local cols = 4
    local gap = 1
    local cw = math.floor((aw - (cols - 1) * gap) / cols)
    for i, a in ipairs(Config.accents) do
      local col = (i - 1) % cols
      local row = math.floor((i - 1) / cols)
      local cx = ax + col * (cw + gap)
      local cy = ay + row * 4
      local slot = Config.accentSlot[a.id] or Theme.C.accent
      Canvas:roundRect(cx, cy, cw, 3, 1, slot, Theme.C.bg)
      local on = App.cfg.accent == a.id and App.cfg.accentRgb == nil
      Canvas:textCenter(cx, cy + 1, cw, a.label, (Util.luma(Theme.col(slot)) > 0.55 and Theme.C.bg or Theme.C.text), slot)
      if on then Canvas:fill(cx, cy + 3, cw, 1, Theme.C.text) end
      UI.hit(cx, cy, cw, 3, function() Theme.setAccent(a.rgb, a.id) end)
    end
  end }
  entries[#entries + 1] = { h = 2, draw = function(ax, ay, aw) UI.sectionTitle(ax, ay, aw, "INTERFACE") end }
  entries[#entries + 1] = { h = 4, draw = function(ax, ay, aw)
    Canvas:textFit(ax, ay + 1, aw - 25, "Text scale", Theme.C.text, Theme.C.bg)
    Canvas:textRight(ax + aw - 24, ay + 1, 8, string.format("%.1f", App.cfg.monitorScale), Theme.C.accent, Theme.C.bg)
    UI.button(ax + aw - 14, ay, 6, 3, "-", { variant = "surface", fn = function()
      Config.cycleTextScale(-1); App.applyMonitorScale()
    end })
    UI.button(ax + aw - 7, ay, 6, 3, "+", { variant = "surface", fn = function()
      Config.cycleTextScale(1); App.applyMonitorScale()
    end })
  end }
  entries[#entries + 1] = { h = 3, draw = function(ax, ay, aw)
    Canvas:textBlock(ax, ay, aw, "Text scale applies to the whole interface. Use 0.1 steps.", Theme.C.dim, Theme.C.bg, 2)
  end }
  entries[#entries + 1] = { h = 4, draw = function(ax, ay, aw)
    Canvas:textFit(ax, ay + 1, aw - 14, "Animations", Theme.C.text, Theme.C.bg)
    UI.button(ax + aw - 12, ay, 11, 3, App.cfg.animations and "ON" or "OFF", {
      variant = App.cfg.animations and "active" or "surface",
      fn = function() App.cfg.animations = not App.cfg.animations; Config.saveSoon(); UI.request(true) end,
    })
  end }
  entries[#entries + 1] = { h = 5, draw = function(ax, ay, aw)
    Canvas:textFit(ax, ay, aw, "VISUALIZER (REAL PCM ANALYSIS)", Theme.C.dim, Theme.C.bg)
    local modes = { "bars", "wave", "vu", "off" }
    local labels = { "BARS", "WAVE", "VU", "OFF" }
    local gap = 1
    local cw = math.floor((aw - 3 * gap) / 4)
    for i, mode in ipairs(modes) do
      UI.chip(ax + (i - 1) * (cw + gap), ay + 2, cw, 3, labels[i], App.cfg.visualizer == mode, function()
        App.cfg.visualizer = mode; Config.saveSoon(); UI.request(true)
      end)
    end
  end }
  entries[#entries + 1] = { h = 3, draw = function(ax, ay, aw)
    Canvas:textFit(ax, ay, aw, "Palette changes are applied live to this monitor.", Theme.C.dim, Theme.C.bg)
  end }
  Screens.flow(entries, x, top, w, bot - top + 1, "appearance")
end

function Screens.settingsAudio()
  if not Screens.requireRoot() then return end
  local m = Screens.settingsHeader("AUDIO OUTPUT")
  local x, top, w, bot = m.contentX, m.bodyTop, m.contentW, m.bodyBot
  local entries = {}
  entries[#entries + 1] = { h = 7, draw = function(ax, ay, aw)
    Canvas:roundRect(ax, ay, aw, 7, 1, Theme.C.surface, Theme.C.bg)
    Canvas:textFit(ax + 2, ay + 1, aw - 4, "MASTER VOLUME", Theme.C.dim, Theme.C.surface)
    Canvas:textRight(ax + 2, ay + 1, aw - 4, Audio.volumeLabel(), Theme.C.accent, Theme.C.surface)
    UI.progressBar(ax + 2, ay + 3, aw - 4, 2, Audio.volumeFrac(), {
      fn = function(f) Audio.setVolume(f * Audio.MAX_VOLUME); UI.request(true) end,
    })
    UI.button(ax + 2, ay + 5, math.min(12, aw - 4), 2, Audio.muted and "UNMUTE" or "MUTE", {
      variant = Audio.muted and "active" or "surface2", icon = "volume9",
      fn = function() Audio.toggleMute(); if App.cfg then App.cfg.muted = Audio.muted; Config.saveSoon() end; UI.request(true) end,
    })
  end }
  entries[#entries + 1] = { h = 4, draw = function(ax, ay, aw)
    UI.button(ax, ay, math.min(16, aw), 3, "RESCAN", { variant = "surface", icon = "refresh", fn = function()
      Audio.scan(); UI.toast(Audio.statsLine(), "info"); UI.request(true)
    end })
    if aw >= 40 then
      UI.button(ax + 20, ay, 14, 3, "TEST ALL", { variant = "surface", icon = "speaker", fn = function()
        local n = Audio.testSpeaker(nil); UI.toast("Test tone sent to " .. n .. " speaker(s)", n > 0 and "success" or "warning")
      end })
    end
  end }
  entries[#entries + 1] = { h = 2, draw = function(ax, ay, aw) UI.sectionTitle(ax, ay, aw, "SPEAKERS  " .. #Audio.speakers) end }
  for _, sp in ipairs(Audio.speakers) do
    entries[#entries + 1] = { h = 5, draw = function(ax, ay, aw)
      local enabled = Audio.speakerEnabled(sp.name)
      Canvas:roundRect(ax, ay, aw, 5, 1, Theme.C.surface, Theme.C.bg)
      Canvas:textFit(ax + 2, ay + 1, aw - 8, sp.name, Theme.C.text, Theme.C.surface)
      Canvas:textRight(ax + 2, ay + 1, aw - 4, string.format("%d%%", math.floor(sp.gain * 100 + 0.5)), Theme.C.muted, Theme.C.surface)
      Canvas:textFit(ax + 2, ay + 2, aw - 4, enabled and "ENABLED" or "DISABLED", enabled and Theme.C.accent or Theme.C.dim, Theme.C.surface)
      local bw = math.max(4, math.floor((aw - 8) / 4))
      UI.button(ax + 2, ay + 3, bw, 2, enabled and "ON" or "OFF", { variant = enabled and "active" or "surface2", fn = function()
        Audio.setSpeakerEnabled(sp.name, not enabled); UI.request(true)
      end })
      UI.button(ax + 3 + bw, ay + 3, bw, 2, "-", { variant = "surface2", fn = function()
        Audio.setSpeakerGain(sp.name, sp.gain - 0.1); UI.request(true)
      end })
      UI.button(ax + 4 + bw * 2, ay + 3, bw, 2, "+", { variant = "surface2", fn = function()
        Audio.setSpeakerGain(sp.name, sp.gain + 0.1); UI.request(true)
      end })
      UI.button(ax + 5 + bw * 3, ay + 3, bw, 2, "TEST", { variant = "surface2", fn = function()
        local n = Audio.testSpeaker(sp.name)
        UI.toast(n > 0 and ("Test tone sent to " .. sp.name) or "Speaker busy or unavailable", n > 0 and "info" or "warning")
      end })
    end }
  end
  if #Audio.speakers == 0 then
    entries[#entries + 1] = { h = 4, draw = function(ax, ay, aw)
      UI.emptyState(ax, ay, aw, 4, "speaker", "No speakers", "Place speakers next to the computer")
    end }
  end
  entries[#entries + 1] = { h = 5, draw = function(ax, ay, aw)
    Canvas:textFit(ax, ay, aw, "AUDIO BACKEND", Theme.C.dim, Theme.C.bg)
    Canvas:textFit(ax, ay + 1, aw, "DFPWM -> speaker.playAudio PCM @ 48 kHz", Theme.C.muted, Theme.C.bg)
    Canvas:textFit(ax, ay + 2, aw, "No standard SPK API exists in CC:Tweaked.", Theme.C.dim, Theme.C.bg)
    Canvas:textFit(ax, ay + 3, aw, "Per-speaker gain only; speakers are mono.", Theme.C.dim, Theme.C.bg)
  end }
  Screens.flow(entries, x, top, w, bot - top + 1, "audioSettings")
end

function Screens.settingsLibrary()
  if not Screens.requireRoot() then return end
  local m = Screens.settingsHeader("LIBRARY")
  local x, top, w, bot = m.contentX, m.bodyTop, m.contentW, m.bodyBot
  local entries = {}
  entries[#entries + 1] = { h = 3, draw = function(ax, ay, aw)
    Canvas:textFit(ax, ay, aw, Data.stats.tracks .. " " .. Util.plural(Data.stats.tracks, "track") .. "  ·  " .. Data.stats.albums .. " " .. Util.plural(Data.stats.albums, "album") .. "  ·  " .. Data.stats.artists .. " " .. Util.plural(Data.stats.artists, "artist"), Theme.C.muted, Theme.C.bg)
    Canvas:textFit(ax, ay + 1, aw, "Total duration " .. Util.fmtDuration(Data.stats.duration), Theme.C.dim, Theme.C.bg)
  end }
  entries[#entries + 1] = { h = 4, draw = function(ax, ay, aw)
    UI.button(ax, ay, math.min(16, aw), 3, "RESCAN", { variant = "primary", icon = "refresh", fn = function()
      Data.rescan(); UI.toast("Library rescanned", "success")
    end })
    if aw >= 34 then
      UI.button(ax + 18, ay, 20, 3, "CLEAR CACHE", { variant = "surface", icon = "trash", fn = function()
        UI.confirm("CLEAR CACHE", "Clear the cached library index? The files are not touched.", function()
          Store.delete("library"); Data.cache = { version = 2, entries = {} }; Data.rescan(); UI.toast("Cache cleared", "info")
        end)
      end })
    end
  end }
  entries[#entries + 1] = { h = 2, draw = function(ax, ay, aw) UI.sectionTitle(ax, ay, aw, "MUSIC FOLDERS") end }
  for idx, rootPath in ipairs(App.cfg.roots) do
    entries[#entries + 1] = { h = 4, draw = function(ax, ay, aw)
      Canvas:roundRect(ax, ay, aw, 4, 1, Theme.C.surface, Theme.C.bg)
      Canvas:icon("folder", ax, ay, 5, 4, Theme.C.muted, 1)
      Canvas:textFit(ax + 5, ay + 1, aw - 11, rootPath, fs.exists(rootPath) and Theme.C.text or Theme.C.danger, Theme.C.surface)
      Canvas:textFit(ax + 5, ay + 2, aw - 11, fs.isDir(rootPath) and "FOLDER READY" or "NOT FOUND", fs.isDir(rootPath) and Theme.C.dim or Theme.C.danger, Theme.C.surface)
      UI.button(ax + aw - 5, ay, 5, 4, "", { icon = "trash", iconColor = Theme.C.danger, variant = "surface", fn = function()
        UI.confirm("REMOVE FOLDER", "Remove \"" .. rootPath .. "\" from the library? Files are not deleted.", function()
          Config.removeRoot(rootPath); Data.scan(); UI.toast("Folder removed", "info")
        end, { danger = true })
      end })
    end }
  end
  entries[#entries + 1] = { h = 4, draw = function(ax, ay, aw)
    UI.button(ax, ay, math.min(20, aw), 3, "ADD FOLDER", { variant = "surface", icon = "plus", fn = function()
      UI.askText("ADD MUSIC FOLDER", "music", function(path)
        path = Util.trim(path)
        if path == "" then return false, "Enter a path" end
        if not fs.exists(path) or not fs.isDir(path) then return false, "Folder not found" end
        if not Config.addRoot(path) then return false, "Already in the library" end
        Data.rescan(); UI.toast("Added " .. path, "success")
        return true
      end, { hint = "e.g. disk/music", maxLen = 120 })
    end })
  end }
  entries[#entries + 1] = { h = 2, draw = function(ax, ay, aw) UI.sectionTitle(ax, ay, aw, "MANAGERS") end }
  entries[#entries + 1] = { h = 4, draw = function(ax, ay, aw)
    local bw = math.floor((aw - 4) / 3)
    UI.button(ax, ay, bw, 3, "ARTWORK", { variant = "surface", icon = "palette", fn = function() App.go("artwork") end })
    UI.button(ax + bw + 2, ay, bw, 3, "METADATA", { variant = "surface", icon = "edit", fn = function() App.go("metadata") end })
    UI.button(ax + (bw + 2) * 2, ay, bw, 3, "LYRICS", { variant = "surface", icon = "lyrics9", fn = function() App.go("lyricsManager") end })
  end }
  entries[#entries + 1] = { h = 4, draw = function(ax, ay, aw)
    local artN, imgN = Art.cacheStats()
    Canvas:textFit(ax, ay, aw, "Cache: " .. artN .. " art cells, " .. imgN .. " decoded images", Theme.C.dim, Theme.C.bg)
    Canvas:textFit(ax, ay + 1, aw, "Cover formats: 8/24/32-bit BMP, P6/P3 PPM", Theme.C.dim, Theme.C.bg)
    Canvas:textFit(ax, ay + 2, aw, "PNG/JPEG must be converted first.", Theme.C.dim, Theme.C.bg)
  end }
  Screens.flow(entries, x, top, w, bot - top + 1, "librarySettings")
end

function Screens.settingsSecurity()
  if not Screens.requireRoot() then return end
  local m = Screens.settingsHeader("SECURITY")
  local x, top, w, bot = m.contentX, m.bodyTop, m.contentW, m.bodyBot
  local entries = {}
  entries[#entries + 1] = { h = 4, draw = function(ax, ay, aw)
    Canvas:textFit(ax, ay, aw, "ROOT USER", Theme.C.dim, Theme.C.bg)
    Canvas:textFit(ax, ay + 1, aw, Auth.username(), Theme.C.text, Theme.C.bg)
    Canvas:textFit(ax, ay + 2, aw, "Credential: " .. (Auth.mode() == "pin" and "PIN" or "Password") .. "  ·  PBKDF2-SHA256 " .. (Auth.data and Auth.data.iter or Auth.iterations) .. " rounds", Theme.C.dim, Theme.C.bg)
  end }
  entries[#entries + 1] = { h = 4, draw = function(ax, ay, aw)
    UI.button(ax, ay, math.min(26, aw), 3, "CHANGE USERNAME", { variant = "surface", icon = "user", fn = function()
      UI.askText("ROOT USERNAME", Auth.username(), function(name)
        local ok, err = Auth.changeUsername(name)
        if not ok then return false, err end
        UI.toast("Username changed", "success")
        return true
      end, { maxLen = 24 })
    end })
  end }
  entries[#entries + 1] = { h = 4, draw = function(ax, ay, aw)
    UI.button(ax, ay, math.min(24, aw), 3, "CHANGE PIN/PASS", { variant = "surface", icon = "lock", fn = function()
      Screens.changeCredential()
    end })
  end }
  entries[#entries + 1] = { h = 4, draw = function(ax, ay, aw)
    Canvas:textFit(ax, ay + 1, aw - 16, "Auto-lock root", Theme.C.text, Theme.C.bg)
    Canvas:textRight(ax + aw - 24, ay + 1, 8, App.cfg.autoLock == 0 and "NEVER" or (App.cfg.autoLock .. " MIN"), Theme.C.accent, Theme.C.bg)
    UI.button(ax + aw - 14, ay, 6, 3, "-", { variant = "surface", fn = function()
      App.cfg.autoLock = Util.clamp(App.cfg.autoLock - 1, 0, 60); Config.saveSoon(); UI.request(true)
    end })
    UI.button(ax + aw - 7, ay, 6, 3, "+", { variant = "surface", fn = function()
      App.cfg.autoLock = Util.clamp(App.cfg.autoLock + 1, 0, 60); Config.saveSoon(); UI.request(true)
    end })
  end }
  entries[#entries + 1] = { h = 4, draw = function(ax, ay, aw)
    UI.button(ax, ay, math.min(24, aw), 3, "NEW RECOVERY CODE", { variant = "surface", icon = "refresh", fn = function()
      UI.confirm("NEW RECOVERY CODE", "Generate a new recovery code? The old code stops working.", function()
        local code = Auth.regenerateRecovery()
        if not code then UI.toast("Could not save recovery code", "danger"); return end
        UI.actions("RECOVERY CODE", { { label = code, sub = "Write this down now", icon = "check", value = "ok" } }, function() end, {
          message = "This code is shown once.",
        })
      end)
    end })
  end }
  entries[#entries + 1] = { h = 4, draw = function(ax, ay, aw)
    UI.button(ax, ay, 20, 3, "LOCK ROOT NOW", { variant = "danger", icon = "lock", fn = function() UI.lockRoot() end })
  end }
  entries[#entries + 1] = { h = 4, draw = function(ax, ay, aw)
    Canvas:textFit(ax, ay, aw, "Filesystem access is the real security boundary.", Theme.C.dim, Theme.C.bg)
    Canvas:textFit(ax, ay + 1, aw, "Use a long password for stronger protection.", Theme.C.dim, Theme.C.bg)
  end }
  Screens.flow(entries, x, top, w, bot - top + 1, "securitySettings")
end

function Screens.changeCredential()
  local mode = Auth.mode()
  UI.openKeyboard({
    title = "NEW " .. (mode == "pin" and "PIN" or "PASSWORD"),
    hint = mode == "pin" and "4-8 digits" or "At least 6 characters",
    mode = mode,
    secret = true,
    maxLen = mode == "pin" and Auth.maxPin or Auth.maxSecret,
    minLen = mode == "pin" and Auth.minPin or Auth.minPassword,
    onDone = function(first)
      UI.openKeyboard({
        title = "CONFIRM " .. (mode == "pin" and "PIN" or "PASSWORD"),
        mode = mode,
        secret = true,
        maxLen = mode == "pin" and Auth.maxPin or Auth.maxSecret,
        minLen = mode == "pin" and Auth.minPin or Auth.minPassword,
        onDone = function(second)
          if first ~= second then return false, "Values do not match" end
          local ok, err = Auth.changeSecret(mode, first)
          if not ok then return false, err end
          Auth.root = true
          Auth.rootAt = Util.now()
          UI.toast("Credential updated", "success")
          return true
        end,
      })
      return "keep"
    end,
  })
end

function Screens.settingsAbout()
  if not Screens.requireRoot() then return end
  local m = Screens.settingsHeader("ABOUT & DIAGNOSTICS")
  local x, top, w, bot = m.contentX, m.bodyTop, m.contentW, m.bodyBot
  local lines = {
    { APP_NAME .. " " .. VERSION .. "  ·  " .. APP_TAG, Theme.C.accent },
    { "Touch-first ProOnlyUNO jukebox for CC:Tweaked", Theme.C.muted },
    { "", Theme.C.bg },
    { "DISPLAY", Theme.C.dim },
    { string.format("Monitor: %s", App.monName or "computer terminal"), Theme.C.text },
    { string.format("Cells: %dx%d  ·  text scale %.1f", Canvas.w, Canvas.h, App.currentTextScale or App.cfg.monitorScale), Theme.C.text },
    { "Colour: " .. (App.color and "yes" or "no") .. "  ·  Touch: " .. (App.touch and "yes" or "no") .. "  ·  blit: " .. (type(App.term.blit) == "function" and "yes" or "no"), Theme.C.text },
    { "Theme palette: " .. (Theme.custom and "custom RGB" or "standard fallback"), Theme.C.text },
    { "", Theme.C.bg },
    { "AUDIO", Theme.C.dim },
    { Audio.statsLine(), Theme.C.text },
    { "Backend: cc.audio.dfpwm + speaker.playAudio", Theme.C.text },
    { "SPK: no standard API or format in CC:Tweaked", Theme.C.warning },
    { "Visualiser: real RMS/peak + 8-band Goertzel", Theme.C.text },
    { "", Theme.C.bg },
    { "LIBRARY", Theme.C.dim },
    { Data.stats.tracks .. " " .. Util.plural(Data.stats.tracks, "track") .. "  ·  " .. Data.stats.albums .. " " .. Util.plural(Data.stats.albums, "album") .. "  ·  " .. Data.stats.artists .. " " .. Util.plural(Data.stats.artists, "artist"), Theme.C.text },
    { "Duration " .. Util.fmtDuration(Data.stats.duration), Theme.C.text },
    { "Favorites " .. #Data.favoriteTracks() .. "  ·  Playlists " .. #Data.playlists, Theme.C.text },
    { "", Theme.C.bg },
    { "TOUCH CONTROLS", Theme.C.dim },
    { "Tap: select / play / open  ·  large targets", Theme.C.muted },
    { "Sliders: tap to set. CC monitors have no drag.", Theme.C.muted },
    { "Lists: use the rail arrows to page.", Theme.C.muted },
    { "Root settings lock when you leave this area.", Theme.C.muted },
    { "", Theme.C.bg },
    { "IMAGE FORMATS", Theme.C.dim },
    { "BMP 8/24/32-bit  ·  PPM P6/P3  ·  16-colour art", Theme.C.muted },
    { "PNG/JPEG: convert to BMP/PPM first.", Theme.C.warning },
    { "", Theme.C.bg },
    { "SECURITY", Theme.C.dim },
    { "Salted PBKDF2-HMAC-SHA256 (pure Lua).", Theme.C.muted },
    { "No CSPRNG/crypto API in CC:Tweaked.", Theme.C.warning },
  }
  local rows = {}
  for _, line in ipairs(lines) do
    local wrapped = Util.wrap(line[1], w - 1)
    if #wrapped == 0 then wrapped = { "" } end
    for _, text in ipairs(wrapped) do rows[#rows + 1] = { text, line[2] } end
  end
  local visible = bot - top + 1
  local scroll = Util.clamp(App.scroll.about or 0, 0, math.max(0, #rows - visible))
  App.scroll.about = scroll
  for i = scroll + 1, math.min(#rows, scroll + visible) do
    local line = rows[i]
    Canvas:textFit(x, top + (i - scroll - 1), w, line[1], line[2], Theme.C.bg)
  end
  if #rows > visible then
    UI.scrollRail(x + w - 4, top, visible, #rows, scroll, visible, function(delta)
      App.scroll.about = Util.clamp(scroll + delta, 0, math.max(0, #rows - visible))
    end)
  end
end

------------------------------------------------------------------ managers
function Screens.artwork()
  if not Screens.requireRoot() then return end
  local m = Screens.settingsHeader("ARTWORK")
  local x, top, w, bot = m.contentX, m.bodyTop, m.contentW, m.bodyBot
  Canvas:textFit(x, top, w, "Choose an album to assign or change its cover.", Theme.C.dim, Theme.C.bg)
  local y = top + 2
  local total = #Data.albums
  local rowH = 4
  local visible = math.max(1, math.floor((bot - y + 1) / rowH))
  local scroll = Util.clamp(App.scroll.artwork or 0, 0, math.max(0, total - visible))
  App.scroll.artwork = scroll
  local rail = total > visible
  local listW = w - (rail and 4 or 0)
  for i = 1, visible do
    local album = Data.albums[scroll + i]
    if album then
      local ry = y + (i - 1) * rowH
      Canvas:roundRect(x, ry, listW, rowH, 1, Theme.C.surface, Theme.C.bg)
      local art = Art.forAlbum(album, 4, 3)
      if art then Canvas:art(art, x + 1, ry) end
      Canvas:textFit(x + 6, ry, listW - 12, album.name, Theme.C.text, Theme.C.surface)
      Canvas:textFit(x + 6, ry + 1, listW - 12, album.artist, Theme.C.muted, Theme.C.surface)
      UI.button(x + listW - 5, ry, 5, rowH, "", { icon = "edit", iconColor = Theme.C.accent, variant = "surface", fn = function()
        App.openArtPicker(album, "album")
      end })
      UI.hit(x, ry, listW - 5, rowH, function() App.openArtPicker(album, "album") end)
    end
  end
  if rail then
    UI.scrollRail(x + w - 4, y, bot - y + 1, total, scroll, visible, function(delta)
      App.scroll.artwork = Util.clamp(scroll + delta, 0, math.max(0, total - visible))
    end)
  end
end

function Screens.artPicker()
  if not Screens.requireRoot() then return end
  local target = App.artTarget
  if not target then App.go("artwork"); return end
  local m = Screens.settingsHeader("SET ARTWORK")
  local x, top, w, bot = m.contentX, m.bodyTop, m.contentW, m.bodyBot
  local folder = target.folder
  local cw = math.min(14, math.floor(w * 0.45))
  local ch = Util.round(cw * 2 / 3)
  local art = target.kind == "album" and Art.forAlbum(target.album, cw, ch) or Art.forTrack(target.track, cw, ch)
  Canvas:roundRect(x, top, cw + 1, ch + 1, 1, Theme.C.surface, Theme.C.bg)
  if art then Canvas:art(art, x, top) end
  Canvas:textFit(x + cw + 2, top, w - cw - 2, target.name or "", Theme.C.text, Theme.C.bg)
  Canvas:textFit(x + cw + 2, top + 1, w - cw - 2, "Current cover", Theme.C.dim, Theme.C.bg)
  local listY = top + ch + 3
  local entries = {}
  entries[#entries + 1] = { label = "Generated cover", value = "generated", sub = "Deterministic art from the name" }
  local files = Art.listImages(folder)
  for _, p in ipairs(files) do
    entries[#entries + 1] = { label = fs.getName(p), value = p, sub = p }
  end
  entries[#entries + 1] = { label = "Enter image path...", value = "__path", sub = "BMP or PPM" }
  entries[#entries + 1] = { label = "Clear override", value = "__clear", sub = "Use automatic folder cover", danger = true }
  local total = #entries
  local rowH = 3
  local visible = math.max(1, math.floor((bot - listY + 1) / rowH))
  local scroll = Util.clamp(App.scroll.artPicker or 0, 0, math.max(0, total - visible))
  App.scroll.artPicker = scroll
  for i = 1, visible do
    local e = entries[scroll + i]
    if e then
      local ry = listY + (i - 1) * rowH
      Canvas:roundRect(x, ry, w, rowH, 1, Theme.C.surface, Theme.C.bg)
      Canvas:textFit(x + 2, ry, w - 4, e.label, e.danger and Theme.C.danger or Theme.C.text, Theme.C.surface)
      if e.sub and rowH >= 3 then Canvas:textFit(x + 2, ry + 1, w - 4, e.sub, Theme.C.dim, Theme.C.surface) end
      UI.hit(x, ry, w, rowH, function()
        if e.value == "__clear" then
          Screens.applyArt(target, nil)
        elseif e.value == "__path" then
          UI.askText("IMAGE PATH", "", function(path)
            path = Util.trim(path)
            local resolved = Art.resolveArtPath(path, folder)
            if not resolved or resolved == "generated" then return false, "Image not found" end
            Screens.applyArt(target, resolved)
            return true
          end, { hint = "folder/cover.bmp", maxLen = 200 })
        else
          Screens.applyArt(target, e.value)
        end
      end)
    end
  end
  if total > visible then
    UI.scrollRail(x + w - 4, listY, bot - listY + 1, total, scroll, visible, function(delta)
      App.scroll.artPicker = Util.clamp(scroll + delta, 0, math.max(0, total - visible))
    end)
  end
end

function Screens.applyArt(target, value)
  local cleared = (value == nil)
  if target.kind == "album" then
    Data.setAlbumMeta(target.album.key, { art = cleared and "" or value })
    Art.invalidateAlbum(target.album)
  else
    Data.setTrackMeta(target.track.path, { art = cleared and "" or value })
  end
  Data.rescan()
  Screens.clearLyricsCache()
  UI.toast(cleared and "Artwork override cleared" or "Artwork assigned", "success")
  if target.kind == "album" then App.openAlbum(Data.findAlbumByKey(target.album.key) or target.album)
  else App.go("metadata") end
end

function Screens.metadata()
  if not Screens.requireRoot() then return end
  local m = Screens.settingsHeader("METADATA")
  local x, top, w, bot = m.contentX, m.bodyTop, m.contentW, m.bodyBot
  Canvas:textFit(x, top, w, "Original audio files are never modified.", Theme.C.dim, Theme.C.bg)
  local y = top + 2
  local total = #Data.tracks
  local rowH = 4
  local visible = math.max(1, math.floor((bot - y + 1) / rowH))
  local scroll = Util.clamp(App.scroll.metadata or 0, 0, math.max(0, total - visible))
  App.scroll.metadata = scroll
  local rail = total > visible
  local listW = w - (rail and 4 or 0)
  for i = 1, visible do
    local track = Data.tracks[scroll + i]
    if track then
      local ry = y + (i - 1) * rowH
      Canvas:roundRect(x, ry, listW, rowH, 1, Theme.C.surface, Theme.C.bg)
      Canvas:textFit(x + 2, ry, listW - 8, track.title, Theme.C.text, Theme.C.surface)
      Canvas:textFit(x + 2, ry + 1, listW - 8, track.artist .. "  ·  " .. track.album, Theme.C.muted, Theme.C.surface)
      UI.button(x + listW - 5, ry, 5, rowH, "", { icon = "edit", iconColor = Theme.C.accent, variant = "surface", fn = function() App.openMetaForm(track) end })
      UI.hit(x, ry, listW - 5, rowH, function() App.openMetaForm(track) end)
    end
  end
  if rail then
    UI.scrollRail(x + w - 4, y, bot - y + 1, total, scroll, visible, function(delta)
      App.scroll.metadata = Util.clamp(scroll + delta, 0, math.max(0, total - visible))
    end)
  end
end

function Screens.albumMeta()
  if not Screens.requireRoot() then return end
  local d = App.albumDraft
  if not d then App.go("artwork"); return end
  local m = Screens.settingsHeader("ALBUM INFO")
  local x, top, w, bot = m.contentX, m.bodyTop, m.contentW, m.bodyBot
  Canvas:textFit(x, top, w, d.album.name, Theme.C.text, Theme.C.bg)
  Canvas:textFit(x, top + 1, w, "Album fields are metadata overrides; files are untouched.", Theme.C.dim, Theme.C.bg)
  local y = top + 3
  local function field(label, key)
    Canvas:roundRect(x, y, w, 4, 1, Theme.C.surface, Theme.C.bg)
    Canvas:textFit(x + 2, y + 1, w - 4, label, Theme.C.dim, Theme.C.surface)
    Canvas:textFit(x + 2, y + 2, w - 4, d[key] ~= "" and d[key] or "(empty)", Theme.C.text, Theme.C.surface)
    UI.hit(x, y, w, 4, function()
      UI.askText(label, d[key], function(v)
        d[key] = Util.clean(v)
        UI.request(true)
        return true
      end, { maxLen = 80, allowEmpty = true })
    end)
    y = y + 5
  end
  field("ALBUM NAME", "name")
  field("ALBUM ARTIST", "artist")
  local bw = math.floor((w - 2) / 2)
  UI.button(x, y, bw, 3, "SAVE", { variant = "primary", icon = "check", fn = function()
    Data.setAlbumMeta(d.album.key, { name = d.name, artist = d.artist })
    Data.rescan()
    Screens.clearLyricsCache()
    UI.toast("Album info saved", "success")
    App.openAlbum(Data.findAlbumByKey(d.album.key) or d.album)
  end })
  UI.button(x + bw + 2, y, bw, 3, "CANCEL", { variant = "surface", fn = function() App.back() end })
end

function Screens.metaForm()
  if not Screens.requireRoot() then return end
  local draft = App.metaDraft
  if not draft then App.go("metadata"); return end
  local m = Screens.settingsHeader("EDIT METADATA")
  local x, top, w, bot = m.contentX, m.bodyTop, m.contentW, m.bodyBot
  if m.compact then
    local entries = {}
    entries[#entries + 1] = { h = 2, draw = function(ax, ay, aw)
      Canvas:textFit(ax, ay, aw, draft.track.title, Theme.C.text, Theme.C.bg)
      Canvas:textFit(ax, ay + 1, aw, draft.track.path, Theme.C.dim, Theme.C.bg)
    end }
    local function field(label, key, mode)
      entries[#entries + 1] = { h = 3, draw = function(ax, ay, aw)
        Canvas:roundRect(ax, ay, aw, 3, 1, Theme.C.surface, Theme.C.bg)
        Canvas:textFit(ax + 1, ay, aw - 2, label, Theme.C.dim, Theme.C.surface)
        local value = tostring(draft[key] or "")
        Canvas:textFit(ax + 1, ay + 1, aw - 2, value == "" and "(empty)" or value, Theme.C.text, Theme.C.surface)
        UI.hit(ax, ay, aw, 3, function()
          UI.askText(label, value, function(v)
            draft[key] = mode == "number" and tonumber(v) or Util.clean(v)
            UI.request(true)
            return true
          end, { allowEmpty = true, maxLen = 80, mode = mode == "number" and "pin" or "text" })
        end)
      end }
    end
    field("TITLE", "title")
    field("ARTIST", "artist")
    field("ALBUM", "album")
    field("TRACK NUMBER", "trackNo", "number")
    entries[#entries + 1] = { h = 4, draw = function(ax, ay, aw)
      local bw = math.floor((aw - 2) / 2)
      UI.button(ax, ay, bw, 3, "COVER", { variant = "surface", icon = "palette", fn = function() App.openArtPicker(draft.track, "track") end })
      UI.button(ax + bw + 2, ay, bw, 3, "LYRICS", { variant = "surface", icon = "lyrics9", fn = function() App.openLyricsPicker(draft.track) end })
    end }
    entries[#entries + 1] = { h = 4, draw = function(ax, ay, aw)
      local bw = math.floor((aw - 2) / 2)
      UI.button(ax, ay, bw, 3, "SAVE", { variant = "primary", icon = "check", fn = function()
        local fields = { title = draft.title, artist = draft.artist, album = draft.album }
        if draft.trackNo and tostring(draft.trackNo) ~= "" then fields.trackNo = tonumber(draft.trackNo) end
        Data.setTrackMeta(draft.track.path, fields)
        Data.rescan(); Screens.clearLyricsCache(); UI.toast("Metadata saved", "success"); App.go("metadata")
      end })
      UI.button(ax + bw + 2, ay, bw, 3, "RESET", { variant = "surface", fn = function()
        Data.clearTrackMeta(draft.track.path); Data.rescan(); Screens.clearLyricsCache(); App.go("metadata"); UI.toast("Overrides cleared", "info")
      end })
    end }
    Screens.flow(entries, x, top, w, bot - top + 1, "metaForm")
    return
  end
  Canvas:textFit(x, top, w, draft.track.title, Theme.C.text, Theme.C.bg)
  Canvas:textFit(x, top + 1, w, draft.track.path, Theme.C.dim, Theme.C.bg)
  local y = top + 3
  local function field(label, key, value, mode)
    Canvas:roundRect(x, y, w, 4, 1, Theme.C.surface, Theme.C.bg)
    Canvas:textFit(x + 2, y + 1, w - 4, label, Theme.C.dim, Theme.C.surface)
    Canvas:textFit(x + 2, y + 2, w - 4, value == "" and "(empty)" or value, Theme.C.text, Theme.C.surface)
    UI.hit(x, y, w, 4, function()
      UI.askText(label, value, function(v)
        draft[key] = Util.clean(v)
        UI.request(true)
        return true
      end, { allowEmpty = true, maxLen = 80, mode = mode == "number" and "pin" or "text" })
    end)
    y = y + 5
  end
  field("TITLE", "title", draft.title)
  field("ARTIST", "artist", draft.artist)
  field("ALBUM", "album", draft.album)
  field("TRACK NUMBER", "trackNo", tostring(draft.trackNo or ""), "number")
  if y + 4 <= bot then
    UI.button(x, y, math.floor((w - 2) / 2), 3, "COVER", { variant = "surface", icon = "palette", fn = function()
      App.openArtPicker(draft.track, "track")
    end })
    UI.button(x + math.floor((w - 2) / 2) + 2, y, math.floor((w - 2) / 2), 3, "LYRICS", { variant = "surface", icon = "lyrics9", fn = function()
      App.openLyricsPicker(draft.track)
    end })
    y = y + 4
  end
  UI.button(x, y, math.floor((w - 2) / 2), 3, "SAVE", { variant = "primary", icon = "check", fn = function()
    local fields = { title = draft.title, artist = draft.artist, album = draft.album }
    if draft.trackNo and tostring(draft.trackNo) ~= "" then fields.trackNo = tonumber(draft.trackNo) end
    Data.setTrackMeta(draft.track.path, fields)
    Data.rescan()
    Screens.clearLyricsCache()
    UI.toast("Metadata saved", "success")
    App.go("metadata")
  end })
  UI.button(x + math.floor((w - 2) / 2) + 2, y, math.floor((w - 2) / 2), 3, "RESET", { variant = "surface", fn = function()
    Data.clearTrackMeta(draft.track.path)
    Data.rescan()
    Screens.clearLyricsCache()
    App.go("metadata")
    UI.toast("Overrides cleared", "info")
  end })
end

function Screens.lyricsManager()
  if not Screens.requireRoot() then return end
  local m = Screens.settingsHeader("LYRICS")
  local x, top, w, bot = m.contentX, m.bodyTop, m.contentW, m.bodyBot
  Canvas:textFit(x, top, w, "Auto-detect .lrc/.txt or assign a specific file.", Theme.C.dim, Theme.C.bg)
  local y = top + 2
  local total = #Data.tracks
  local rowH = 4
  local visible = math.max(1, math.floor((bot - y + 1) / rowH))
  local scroll = Util.clamp(App.scroll.lyricsManager or 0, 0, math.max(0, total - visible))
  App.scroll.lyricsManager = scroll
  local rail = total > visible
  local listW = w - (rail and 4 or 0)
  for i = 1, visible do
    local track = Data.tracks[scroll + i]
    if track then
      local ry = y + (i - 1) * rowH
      local lrc = Screens.lyricsFor(track)
      Canvas:roundRect(x, ry, listW, rowH, 1, Theme.C.surface, Theme.C.bg)
      Canvas:textFit(x + 2, ry, listW - 8, track.title, Theme.C.text, Theme.C.surface)
      Canvas:textFit(x + 2, ry + 1, listW - 8, lrc and (lrc.sync and "SYNCED" or "UNSYNCED") or "NO LYRICS", lrc and Theme.C.accent or Theme.C.dim, Theme.C.surface)
      UI.button(x + listW - 5, ry, 5, rowH, "", { icon = "lyrics9", iconColor = Theme.C.accent, variant = "surface", fn = function() App.openLyricsPicker(track) end })
      UI.hit(x, ry, listW - 5, rowH, function() App.openLyricsPicker(track) end)
    end
  end
  if rail then
    UI.scrollRail(x + w - 4, y, bot - y + 1, total, scroll, visible, function(delta)
      App.scroll.lyricsManager = Util.clamp(scroll + delta, 0, math.max(0, total - visible))
    end)
  end
end

function Screens.lyricsPicker()
  if not Screens.requireRoot() then return end
  local track = App.lyricsTarget
  if not track then App.go("lyricsManager"); return end
  local m = Screens.settingsHeader("ASSIGN LYRICS")
  local x, top, w, bot = m.contentX, m.bodyTop, m.contentW, m.bodyBot
  Canvas:textFit(x, top, w, track.title .. "  ·  " .. track.artist, Theme.C.text, Theme.C.bg)
  local current = Screens.lyricsFor(track)
  Canvas:textFit(x, top + 1, w, current and ("Current: " .. tostring(current.path)) or "No lyrics assigned", Theme.C.dim, Theme.C.bg)
  local listY = top + 3
  local entries = {}
  entries[#entries + 1] = { label = "Auto-detect", value = "__auto", sub = "Look for a matching .lrc or .txt" }
  entries[#entries + 1] = { label = "Enter file path...", value = "__path", sub = "LRC or TXT" }
  entries[#entries + 1] = { label = "Clear assignment", value = "__clear", sub = "Fall back to auto-detection", danger = true }
  local files = {}
  local seen = {}
  for _, p in ipairs(Lrc.candidates(track)) do seen[p] = true; files[#files + 1] = p end
  local ok, entries2 = pcall(fs.list, track.folder)
  if ok and entries2 then
    for _, name in ipairs(entries2) do
      local lower = name:lower()
      if (lower:match("%.lrc$") or lower:match("%.txt$")) and not seen[fs.combine(track.folder, name)] then
        files[#files + 1] = fs.combine(track.folder, name)
      end
    end
  end
  for _, p in ipairs(files) do
    entries[#entries + 1] = { label = fs.getName(p), value = p, sub = p }
  end
  local total = #entries
  local rowH = 3
  local visible = math.max(1, math.floor((bot - listY + 1) / rowH))
  local scroll = Util.clamp(App.scroll.lyricsPicker or 0, 0, math.max(0, total - visible))
  App.scroll.lyricsPicker = scroll
  for i = 1, visible do
    local e = entries[scroll + i]
    if e then
      local ry = listY + (i - 1) * rowH
      Canvas:roundRect(x, ry, w, rowH, 1, Theme.C.surface, Theme.C.bg)
      Canvas:textFit(x + 2, ry, w - 4, e.label, e.danger and Theme.C.danger or Theme.C.text, Theme.C.surface)
      if e.sub then Canvas:textFit(x + 2, ry + 1, w - 4, e.sub, Theme.C.dim, Theme.C.surface) end
      UI.hit(x, ry, w, rowH, function()
        if e.value == "__auto" then
          Data.setTrackMeta(track.path, { lyrics = "" })
          Screens.finishLyrics(track, "Auto-detection enabled")
        elseif e.value == "__clear" then
          Data.setTrackMeta(track.path, { lyrics = "" })
          Screens.finishLyrics(track, "Lyrics assignment cleared")
        elseif e.value == "__path" then
          UI.askText("LYRICS PATH", "", function(path)
            path = Util.trim(path)
            local p = Art.resolveArtPath(path, track.folder)
            if not p or p == "generated" then return false, "File not found" end
            Data.setTrackMeta(track.path, { lyrics = p })
            Screens.finishLyrics(track, "Lyrics assigned")
            return true
          end, { hint = "folder/song.lrc", maxLen = 200 })
        else
          Data.setTrackMeta(track.path, { lyrics = e.value })
          Screens.finishLyrics(track, "Lyrics assigned")
        end
      end)
    end
  end
  if total > visible then
    UI.scrollRail(x + w - 4, listY, bot - listY + 1, total, scroll, visible, function(delta)
      App.scroll.lyricsPicker = Util.clamp(scroll + delta, 0, math.max(0, total - visible))
    end)
  end
end

function Screens.finishLyrics(track, message)
  Data.rescan()
  Screens.clearLyricsCache()
  UI.toast(message, "success")
  App.openLyrics(Data.byPath[track.path] or track)
end

--======== 96_screens_apps.lua ========
------------------------------------------------------------------ home / apps
function Screens.appTile(x, y, w, h, app, compact)
  local bg = Theme.C.surface
  Canvas:roundRect(x, y, w, h, 1, bg, Theme.C.bg)
  local label = compact and (app.short or app.name) or app.name
  Canvas:icon(app.icon, x, y, w, h - 1, app.color or Theme.C.accent, 1)
  Canvas:textCenter(x, y + h - 1, w, label, Theme.C.text, bg)
  UI.hit(x, y, w, h, function() Apps.open(app.id) end)
end

function Screens.homeClock(x, y, w)
  local time, date = Apps.clockText(), Apps.dateText()
  Canvas:textRight(x, y, w, time, Theme.C.accentLight, Theme.C.bg)
  Canvas:textRight(x, y + 1, w, date, Theme.C.dim, Theme.C.bg)
end

function Screens.homeNowPlaying(x, y, w, h)
  local track = Player.cur
  Canvas:roundRect(x, y, w, h, 1, Theme.C.surface, Theme.C.bg)
  if not track then
    local compact = w < 40 or Canvas.h < 24
    Canvas:icon("music", x + 1, y, 5, h, Theme.C.dim, 1)
    if compact then
      Canvas:textFit(x + 7, y + 1, math.max(1, w - 9), "NOTHING PLAYING", Theme.C.muted, Theme.C.surface)
      if h >= 4 then Canvas:textFit(x + 7, y + 2, math.max(1, w - 9), "Tap to open Music", Theme.C.dim, Theme.C.surface) end
      UI.hit(x, y, w, h, function() Apps.open("music") end)
    else
      Canvas:textFit(x + 7, y + 1, math.max(1, w - 22), "NOTHING PLAYING", Theme.C.muted, Theme.C.surface)
      if h >= 4 then Canvas:textFit(x + 7, y + 2, math.max(1, w - 22), "Open Music to start playback", Theme.C.dim, Theme.C.surface) end
      local bw = math.min(13, math.max(8, w - 8))
      UI.button(x + w - bw - 1, y + math.max(1, h - 4), bw, 2, "MUSIC", {
        variant = "primary",
        fn = function() Apps.open("music") end,
      })
    end
    return
  end
  local artW, artH = math.min(5, h - 1), math.max(2, h - 1)
  local art = Art.forTrack(track, artW, artH)
  if art then Canvas:art(art, x + 1, y + math.floor((h - artH) / 2)) end
  local tx = x + artW + 2
  local btnW = 5
  local infoW = math.max(3, w - (tx - x) - btnW - 3)
  Canvas:textFit(tx, y, infoW, track.title, Theme.C.text, Theme.C.surface)
  Canvas:textFit(tx, y + 1, infoW, track.artist, Theme.C.muted, Theme.C.surface)
  if h >= 4 then
    local tw = math.max(3, infoW - 12)
    Canvas:textFit(tx, y + 2, tw, track.album, Theme.C.dim, Theme.C.surface)
    Canvas:textRight(tx, y + 2, infoW, Util.fmtTime(Player.position()) .. " / " .. Util.fmtTime(track.dur), Theme.C.dim, Theme.C.surface)
  end
  local frac = track.dur > 0 and (Player.position() / track.dur) or 0
  Canvas:fill(x + 1, y + h - 1, math.max(0, math.floor((w - 2) * frac)), 1, Theme.C.accent)
  UI.hit(x, y, w - btnW - 2, h, function() Apps.open("music") end)
  local pbX = x + w - btnW - 1
  UI.button(pbX, y + math.max(0, h - 3), btnW, math.min(3, h), "", {
    variant = "primary", icon = Player.paused and "play5" or "pause5",
    fn = function() Player.togglePause() end,
  })
end

function Screens.home()
  local m = UI.frame({ title = "HOME", tab = "home", mini = false })
  local x, top, w, bot = m.contentX, m.bodyTop, m.contentW, m.bodyBot
  local bodyH = bot - top + 1
  local compact = m.compact
  local cols, gap = 4, 1
  local tileW = math.floor((w - gap * (cols - 1)) / cols)
  local tileH = compact and 4 or 5
  local apps = Apps.list
  local maxApps = 8
  local appRows = math.min(2, math.ceil(math.min(#apps, maxApps) / cols))
  local y = top
  if compact then
    Canvas:textFit(x, y, w - 8, Apps.dateText(), Theme.C.dim, Theme.C.bg)
    Canvas:textRight(x, y, w, Apps.clockText(), Theme.C.accentLight, Theme.C.bg)
    y = y + 1
  else
    local hour = tonumber((os.date and os.date("%H") or "12")) or 12
    Canvas:textFit(x, y, w - 12, hour < 12 and "GOOD MORNING" or (hour < 18 and "GOOD AFTERNOON" or "GOOD EVENING"), Theme.C.accent, Theme.C.bg)
    Screens.homeClock(x, y, w)
    y = y + 3
  end
  for i = 1, math.min(#apps, appRows * cols) do
    local app = apps[i]
    local col = (i - 1) % cols
    local row = math.floor((i - 1) / cols)
    Screens.appTile(x + col * (tileW + gap), y + row * tileH, tileW, tileH, app, compact)
  end
  y = y + appRows * tileH + (compact and 0 or 1)
  local recent = Apps.recent()
  local showRecent = not compact and (bot - y) >= 8
  local showQuick = not compact and (bot - y) >= (showRecent and 13 or 8)
  local nowH = math.max(3, math.min(5, bot - y - (showRecent and 4 or 0) - (showQuick and 3 or 0)))
  if showRecent then
    Canvas:textFit(x, y, w - 14, "RECENT APPS", Theme.C.dim, Theme.C.bg)
    UI.button(x + w - 12, y, 12, 2, "SWITCH", { variant = "surface", icon = "grid", iconW = 4, fn = Apps.switcher })
    y = y + 3
    local n = math.min(4, #recent)
    if n == 0 then
      Canvas:textFit(x, y, w, "No recent applications", Theme.C.dim, Theme.C.bg)
    else
      local cw = math.floor((w - (n - 1) * 1) / n)
      for i = 1, n do
        local a = recent[i]
        local rx = x + (i - 1) * (cw + 1)
        Canvas:roundRect(rx, y, cw, 3, 1, Theme.C.surface, Theme.C.bg)
        Canvas:icon(a.icon, rx, y, 4, 3, a.color or Theme.C.accent, 1)
        Canvas:textFit(rx + 5, y + 1, cw - 6, a.short or a.name, Theme.C.text, Theme.C.surface)
        UI.hit(rx, y, cw, 3, function() Apps.open(a.id) end)
      end
    end
    y = y + 4
  end
  if bot - y >= 3 then
    local hh = math.min(nowH, bot - y + 1)
    Screens.homeNowPlaying(x, y, w, hh)
    y = y + hh + 1
  end
  if showQuick and bot - y >= 2 then
    Canvas:textFit(x, y, w, "QUICK ACCESS", Theme.C.dim, Theme.C.bg)
    y = y + 1
    local items = {
      { label = "FAVS", fn = function() App.goTab("library"); App.libTab = "favorites" end },
      { label = "RECENT", fn = function() App.goTab("library"); App.libTab = "recent" end },
      { label = "QUEUE", fn = function() App.openQueue() end },
      { label = "LYRICS", fn = function() if Player.cur then App.openLyrics(Player.cur) else UI.toast("Nothing playing", "warning") end end },
      { label = "ALERTS", fn = function() App.go("notifications") end },
    }
    local cw = math.floor((w - 4) / 5)
    for i, item in ipairs(items) do
      UI.button(x + (i - 1) * (cw + 1), y, cw, 2, item.label, { variant = "surface", fn = item.fn })
    end
  end
end

------------------------------------------------------------------ gallery
Gallery = Gallery or {}
Gallery.files = nil
Gallery.selected = nil

function Gallery.scan()
  local out, seen = {}, {}
  local dirs = { "images", "gallery", "Gallery", fs.combine(Store.dir or ".aurora", "images") }
  for _, root in ipairs(App.cfg.roots or {}) do
    dirs[#dirs + 1] = root
    dirs[#dirs + 1] = fs.combine(root, "images")
  end
  local function scan(dir, depth)
    if #out >= 120 or depth > 2 then return end
    local ok, entries = pcall(fs.list, dir)
    if not ok or not entries then return end
    for _, name in ipairs(entries) do
      local p = fs.combine(dir, name)
      if fs.isDir(p) then scan(p, depth + 1) elseif Art.isImageFile(name) then
        if not seen[p] then seen[p] = true; out[#out + 1] = p end
      end
    end
  end
  for _, dir in ipairs(dirs) do if fs.isDir(dir) then scan(dir, 0) end end
  table.sort(out, function(a, b) return Util.naturalKey(fs.getName(a)) < Util.naturalKey(fs.getName(b)) end)
  Gallery.files = out
  return out
end

function Gallery.open(path)
  Gallery.selected = path
  App.go("gallery")
  UI.request(true)
end

function Screens.gallery()
  local files = Gallery.files or Gallery.scan()
  local grid = Gallery.selected == nil
  local m = UI.frame({
    title = (Canvas.w < 40 and "GAL" or "GALLERY"), tab = "home", mini = false,
    back = function() if Gallery.selected then Gallery.selected = nil; UI.request(true) else App.back() end end,
  })
  local x, top, w, bot = m.contentX, m.bodyTop, m.contentW, m.bodyBot
  if #files == 0 then
    UI.emptyState(x, top, w, bot - top + 1, "gallery", "No images found", "Put BMP or PPM files in images/")
    UI.button(x, bot - 3, math.min(14, w), 3, "REFRESH", { variant = "primary", icon = "refresh", fn = function() Gallery.scan(); UI.request(true) end })
    return
  end
  if not grid then
    local img = Art.loadImage(Gallery.selected)
    Canvas:fill(x, top, w, bot - top + 1, Theme.C.bg)
    if img then
      local size = math.max(1, math.min(w, bot - top + 1))
      local cells = Art.buildCells(img, size, size)
      local ix = x + math.floor((w - size) / 2)
      local iy = top + math.floor((bot - top + 1 - size) / 2)
      if cells then Canvas:art(cells, ix, iy) end
    end
    UI.button(x, bot - 3, 8, 3, "", { icon = "prev", variant = "surface", fn = function()
      local i = Util.indexOf(files, Gallery.selected) or 1
      Gallery.selected = files[((i - 2) % #files) + 1]; UI.request(true)
    end })
    UI.button(x + w - 8, bot - 3, 8, 3, "", { icon = "next", variant = "surface", fn = function()
      local i = Util.indexOf(files, Gallery.selected) or 1
      Gallery.selected = files[(i % #files) + 1]; UI.request(true)
    end })
    return
  end
  local cols = w >= 48 and 4 or 3
  local gap = 1
  local cardW = math.floor((w - (cols - 1) * gap) / cols)
  local artH = math.min(math.max(4, math.floor((bot - top + 1) / 2) - 2), math.floor(cardW * 2 / 3))
  local cardH = artH + 2
  local visible = math.max(1, math.floor((bot - top + 1) / (cardH + gap)))
  local scroll = Util.clamp(App.scroll.gallery or 0, 0, math.max(0, math.ceil(#files / cols) - visible))
  App.scroll.gallery = scroll
  for r = 1, visible do
    for c = 1, cols do
      local idx = (scroll + r - 1) * cols + c
      local path = files[idx]
      if path then
        local cx = x + (c - 1) * (cardW + gap)
        local cy = top + (r - 1) * (cardH + gap)
        Canvas:roundRect(cx, cy, cardW, cardH, 1, Theme.C.surface, Theme.C.bg)
        local img = Art.loadImage(path)
        if img then
          local cells = Art.buildCells(img, cardW, artH)
          if cells then Canvas:art(cells, cx, cy) end
        end
        Canvas:textFit(cx + 1, cy + artH, cardW - 2, fs.getName(path), Theme.C.muted, Theme.C.surface)
        UI.hit(cx, cy, cardW, cardH, function() Gallery.selected = path; UI.request(true) end)
      end
    end
  end
  local rows = math.ceil(#files / cols)
  if rows > visible then UI.scrollRail(x + w - 4, top, bot - top + 1, rows, scroll, visible, function(delta)
    App.scroll.gallery = Util.clamp(scroll + delta, 0, math.max(0, rows - visible)); UI.request(true)
  end) end
  UI.button(x, bot - 3, 14, 3, "REFRESH", { variant = "surface", icon = "refresh", iconW = 4, fn = function() Gallery.files = nil; Gallery.scan(); UI.request(true) end })
end

------------------------------------------------------------------ files
Files = Files or {}
Files.cwd = nil

function Files.refresh()
  if not Files.cwd or not fs.isDir(Files.cwd) then
    Files.cwd = fs.isDir("music") and "music" or "/"
  end
  local entries = {}
  local ok, names = pcall(fs.list, Files.cwd)
  if ok and names then
    for _, name in ipairs(names) do
      local p = fs.combine(Files.cwd, name)
      local isDir = fs.isDir(p)
      local size = 0
      if not isDir then
        local sok, a = pcall(fs.attributes, p)
        if sok and type(a) == "table" then size = tonumber(a.size) or 0 end
      end
      entries[#entries + 1] = { name = name, path = p, dir = isDir, size = size }
    end
  end
  table.sort(entries, function(a, b)
    if a.dir ~= b.dir then return a.dir end
    return Util.naturalKey(a.name) < Util.naturalKey(b.name)
  end)
  Files.entries = entries
end

function Files.recordFile(path)
  if not path then return end
  local list = App.cfg.recentFiles or {}
  for i = #list, 1, -1 do if list[i] == path then table.remove(list, i) end end
  table.insert(list, 1, path)
  while #list > 10 do table.remove(list) end
  App.cfg.recentFiles = list
  Config.saveSoon()
end

function Files.openRecent()
  local items = {}
  for _, p in ipairs(App.cfg.recentFiles or {}) do
    if fs.exists(p) then items[#items + 1] = { label = fs.getName(p), sub = p, icon = "file", value = p } end
  end
  if #items == 0 then UI.actions("RECENT FILES", { { label = "No recent files", icon = "info", value = "none" } }, function() end); return end
  UI.actions("RECENT FILES", items, function(path) if path and path ~= "none" then Files.enter(path) end end)
end

function Files.enter(path)
  if fs.isDir(path) then Files.cwd = path; Files.refresh(); UI.request(true); return end
  Files.recordFile(path)
  local lower = path:lower()
  if lower:match("%.cvid$") then
    if Video.open(path) then App.go("video") end
  elseif lower:match("%.dfpwm$") then
    local track = Data.byPath and Data.byPath[path]
    if track then Player.playContext({ track }, 1, track.album or "Files") else UI.toast("Track is not in the library", "warning") end
  elseif lower:match("%.bmp$") or lower:match("%.ppm$") or lower:match("%.pnm$") then
    Gallery.selected = path; App.go("gallery")
  else
    UI.toast("No viewer for this file", "info")
  end
end

function Screens.files()
  if not Files.entries then Files.refresh() end
  local m = UI.frame({ title = (Canvas.w < 40 and "FILE" or "FILES"), tab = "home", mini = true, back = function() App.back() end })
  local x, top, w, bot = m.contentX, m.bodyTop, m.contentW, m.bodyBot
  Canvas:textFit(x, top, math.max(4, w - 21), Files.cwd or "/", Theme.C.accentLight, Theme.C.bg)
  UI.button(x + w - 19, top, 10, 2, "RECENT", { variant = "surface", fn = Files.openRecent })
  UI.button(x + w - 9, top, 9, 2, "UP", { variant = "surface", icon = "up5", iconW = 4, fn = function()
    local parent = fs.getDir(Files.cwd)
    if parent and parent ~= "" and parent ~= Files.cwd then Files.enter(parent) end
  end })
  local listY = top + 2
  local rowH = 3
  local total = #Files.entries
  local visible = math.max(1, math.floor((bot - listY + 1) / rowH))
  local scroll = Util.clamp(App.scroll.files or 0, 0, math.max(0, total - visible))
  App.scroll.files = scroll
  if total == 0 then UI.emptyState(x, listY, w, bot - listY + 1, "folder", "Empty folder"); return end
  local listW = w - (total > visible and 4 or 0)
  for i = 1, visible do
    local e = Files.entries[scroll + i]
    if e then
      local ry = listY + (i - 1) * rowH
      Canvas:roundRect(x, ry, listW, rowH, 1, Theme.C.surface, Theme.C.bg)
      Canvas:icon(e.dir and "folder" or "file", x, ry, 4, rowH, e.dir and Theme.C.amber or Theme.C.muted, 1)
      Canvas:textFit(x + 5, ry, listW - 12, e.name, Theme.C.text, Theme.C.surface)
      if not e.dir then Canvas:textRight(x, ry, listW - 2, Util.fmtSize(e.size), Theme.C.dim, Theme.C.surface) end
      UI.hit(x, ry, listW, rowH, function() Files.enter(e.path) end)
    end
  end
  if total > visible then UI.scrollRail(x + w - 4, listY, bot - listY + 1, total, scroll, visible, function(delta)
    App.scroll.files = Util.clamp(scroll + delta, 0, math.max(0, total - visible)); UI.request(true)
  end) end
end

------------------------------------------------------------------ video viewer
function Screens.videoFiles()
  local files = Video.scanFiles()
  local items = {}
  for _, p in ipairs(files) do
    items[#items + 1] = { label = fs.getName(p), sub = p, icon = "video", value = p }
  end
  if #items == 0 then
    UI.actions("VIDEO FILES", { { label = "No .cvid files found", sub = "Use tools/cvid_convert.py", icon = "info", value = "none" } }, function() end)
    return
  end
  UI.actions("OPEN VIDEO", items, function(path)
    if path and path ~= "none" then Video.open(path) end
  end, { message = "Choose a .cvid file" })
end

function Screens.videoControls(x, y, w, fullscreen)
  local total = math.max(1, Video.total or 1)
  local frac = Util.clamp((Video.position or 0) / total, 0, 1)
  UI.progressBar(x, y, w, 2, frac, { fn = function(f)
    if Video.loaded then Video.seek(f * Video.total) end
  end })
  local time = Video.loaded and (Video.timeText(Video.position) .. " / " .. Video.timeText(Video.total)) or "--:-- / --:--"
  Canvas:textFit(x, y + 2, math.max(8, w - 12), time, Theme.C.muted, Theme.C.bg)
  Canvas:textRight(x, y + 2, w, Video.loaded and ("FRAME " .. Video.frame .. "/" .. Video.frames) or "", Theme.C.dim, Theme.C.bg)
  local by = y + 3
  if w < 40 then
    local bw = math.max(4, math.floor((w - 4) / 5))
    UI.button(x, by, bw, 3, "", { icon = "prev5", variant = "surface", fn = function() if Video.loaded then Video.seek(Video.position - 5000) end end })
    UI.button(x + bw + 1, by, bw, 3, "", { icon = Video.playing and "pause5" or "play5", variant = "primary", fn = function() Video.toggle() end })
    UI.button(x + (bw + 1) * 2, by, bw, 3, "", { icon = "next5", variant = "surface", fn = function() if Video.loaded then Video.seek(Video.position + 5000) end end })
    UI.button(x + (bw + 1) * 3, by, bw, 3, "", { icon = "folder", variant = "surface", fn = Screens.videoFiles })
    if fullscreen then
      UI.button(x + (bw + 1) * 4, by, bw, 3, "", { icon = "minimize5", variant = "surface", fn = function() Video.fullscreen = false; UI.request(true) end })
    else
      UI.button(x + (bw + 1) * 4, by, bw, 3, "", { icon = "video", variant = "surface", fn = function() Video.fullscreen = true; Video.showControls = true; UI.request(true) end })
    end
  else
    local bw = 7
    UI.button(x, by, bw, 3, "", { icon = "prev5", variant = "surface", fn = function() if Video.loaded then Video.seek(Video.position - 5000) end end })
    UI.button(x + bw + 1, by, bw, 3, "", { icon = Video.playing and "pause5" or "play5", variant = "primary", fn = function() Video.toggle() end })
    UI.button(x + (bw + 1) * 2, by, bw, 3, "", { icon = "next5", variant = "surface", fn = function() if Video.loaded then Video.seek(Video.position + 5000) end end })
    UI.button(x + (bw + 1) * 3, by, 10, 3, "OPEN", { variant = "surface", icon = "folder", iconW = 4, fn = Screens.videoFiles })
    if fullscreen then
      UI.button(x + w - 12, by, 12, 3, "EXIT", { variant = "surface", icon = "minimize", iconW = 4, fn = function() Video.fullscreen = false; UI.request(true) end })
    else
      UI.button(x + w - 12, by, 12, 3, "FULL", { variant = "surface", icon = "video", iconW = 4, fn = function() Video.fullscreen = true; Video.showControls = true; UI.request(true) end })
    end
  end
end

function Screens.videoEmpty(x, y, w, h)
  Canvas:roundRect(x, y, w, h, 1, Theme.C.surface, Theme.C.bg)
  Canvas:icon("video", x, y + 1, w, 3, Theme.C.accent, 2)
  Canvas:textCenter(x, y + 4, w, "NO VIDEO LOADED", Theme.C.text, Theme.C.surface)
  Canvas:textCenter(x, y + 6, w, "Convert a video with tools/cvid_convert.py", Theme.C.muted, Theme.C.surface)
  Canvas:textCenter(x, y + 7, w, "then put the .cvid file in videos/", Theme.C.dim, Theme.C.surface)
  UI.button(x + 2, y + h - 4, math.min(16, w - 4), 3, "OPEN CVID", { variant = "primary", icon = "folder", fn = Screens.videoFiles })
end

function Screens.videoFullscreen()
  local w, h = Canvas.w, Canvas.h
  Canvas:fill(1, 1, w, h, Theme.C.bg)
  if Video.loaded then
    Canvas:fill(1, 1, w, h, Theme.C.bg)
    Video.draw(1, 1, w, h, true)
  else
    Canvas:textCenter(1, math.floor(h / 2) - 1, w, "NO VIDEO", Theme.C.text, Theme.C.bg)
    Canvas:textCenter(1, math.floor(h / 2) + 1, w, "Tap to open a file", Theme.C.dim, Theme.C.bg)
  end
  UI.hit(1, 1, w, h, function() Video.showControls = not Video.showControls; UI.request(true) end, { layer = 0 })
  if not Video.showControls then return end
  Canvas:roundRect(1, 1, w, 3, 0, Theme.C.surface, Theme.C.bg)
  UI.button(2, 1, 5, 3, "", { icon = "home", variant = "surface", fn = function() App.goTab("home") end })
  UI.button(8, 1, 5, 3, "", { icon = "back", variant = "surface", fn = function() Video.fullscreen = false; UI.request(true) end })
  Canvas:textFit(15, 2, math.max(8, w - 20), Video.path and fs.getName(Video.path) or "VIDEO", Theme.C.muted, Theme.C.surface)
  local panelH = 8
  Canvas:roundRect(1, h - panelH, w, panelH, 0, Theme.C.surface, Theme.C.bg)
  Screens.videoControls(2, h - panelH + 1, w - 3, true)
end

function Screens.video()
  if not Video.loaded and #Video.files == 0 then
    Video.scanFiles()
    if #Video.files > 0 then Video.load(Video.files[1]) end
  end
  if Video.fullscreen then Screens.videoFullscreen(); return end
  local m = UI.frame({ title = (Canvas.w < 40 and "VID" or "VIDEO"), tab = "home", mini = false, back = function() App.back() end })
  local x, top, w, bot = m.contentX, m.bodyTop, m.contentW, m.bodyBot
  if not Video.loaded then
    Screens.videoEmpty(x, top, w, bot - top + 1)
    return
  end
  Canvas:textFit(x, top, w - 10, Video.path and fs.getName(Video.path) or "VIDEO", Theme.C.text, Theme.C.bg)
  Canvas:textRight(x, top, w, Video.w .. "x" .. Video.h .. " cells", Theme.C.dim, Theme.C.bg)
  local videoY = top + 2
  local videoH = math.max(4, bot - videoY - 8)
  Canvas:fill(x, videoY, w, videoH, Theme.C.bg)
  Video.draw(x, videoY, w, videoH)
  Screens.videoControls(x, videoY + videoH + 1, w, false)
end

------------------------------------------------------------------ notes
Notes = Notes or {}
Notes.items = nil
Notes.loaded = false

function Notes.load()
  local d = Store.load("notes", { version = 1, items = {} })
  local items = {}
  if type(d) == "table" and type(d.items) == "table" then
    for _, n in ipairs(d.items) do
      if type(n) == "table" and type(n.title) == "string" then
        items[#items + 1] = { title = Util.clean(n.title), body = Util.clean(n.body or ""), updated = tonumber(n.updated) or 0 }
      end
    end
  end
  Notes.items = items
  Notes.loaded = true
end

function Notes.save()
  for i = #Notes.items, 1, -1 do
    if Notes.items[i].title == "" and Notes.items[i].body == "" then table.remove(Notes.items, i) end
  end
  Store.save("notes", { version = 1, items = Notes.items })
end

function Notes.new()
  if not Notes.loaded then Notes.load() end
  local n = { title = "Untitled note", body = "", updated = os.time and os.time() or 0 }
  table.insert(Notes.items, 1, n)
  Notes.save()
  App.noteItem = n
  App.go("noteEdit")
end

function Screens.notes()
  if not Notes.loaded then Notes.load() end
  local m = UI.frame({ title = (Canvas.w < 40 and "NOTE" or "NOTES"), tab = "home", mini = true, back = function() App.back() end })
  local x, top, w, bot = m.contentX, m.bodyTop, m.contentW, m.bodyBot
  UI.button(x + w - 12, top, 12, 3, "NEW", { variant = "primary", icon = "plus", fn = Notes.new })
  local listY = top + 4
  local total = #Notes.items
  local rowH = 4
  local visible = math.max(1, math.floor((bot - listY + 1) / rowH))
  local scroll = Util.clamp(App.scroll.notes or 0, 0, math.max(0, total - visible))
  App.scroll.notes = scroll
  if total == 0 then UI.emptyState(x, listY, w, bot - listY + 1, "notes", "No notes yet", "Tap NEW to write one"); return end
  local rail = total > visible
  local listW = w - (rail and 4 or 0)
  for i = 1, visible do
    local n = Notes.items[scroll + i]
    if n then
      local ry = listY + (i - 1) * rowH
      Canvas:roundRect(x, ry, listW, rowH, 1, Theme.C.surface, Theme.C.bg)
      Canvas:textFit(x + 3, ry, listW - 6, n.title ~= "" and n.title or "Untitled note", Theme.C.text, Theme.C.surface)
      Canvas:textFit(x + 3, ry + 1, listW - 6, n.body ~= "" and n.body or "(empty)", Theme.C.muted, Theme.C.surface)
      Canvas:textFit(x + 3, ry + 2, listW - 6, os.date and os.date("%Y-%m-%d %H:%M", n.updated or 0) or "", Theme.C.dim, Theme.C.surface)
      UI.hit(x, ry, listW, rowH, function() App.noteItem = n; App.go("noteEdit") end)
    end
  end
  if rail then UI.scrollRail(x + w - 4, listY, bot - listY + 1, total, scroll, visible, function(delta)
    App.scroll.notes = Util.clamp(scroll + delta, 0, math.max(0, total - visible)); UI.request(true)
  end) end
end

function Screens.noteEdit()
  local n = App.noteItem
  if not n then App.back(); return end
  local m = UI.frame({ title = "NOTE", tab = "home", mini = false, back = function() App.back() end })
  local x, top, w, bot = m.contentX, m.bodyTop, m.contentW, m.bodyBot
  local titleH = m.compact and 3 or 4
  local bodyH = m.compact and 4 or 5
  Canvas:roundRect(x, top, w, titleH, 1, Theme.C.surface, Theme.C.bg)
  Canvas:textFit(x + 2, top, w - 4, "TITLE", Theme.C.dim, Theme.C.surface)
  Canvas:textFit(x + 2, top + 1, w - 4, n.title ~= "" and n.title or "Untitled note", Theme.C.text, Theme.C.surface)
  UI.hit(x, top, w, titleH, function()
    UI.askText("NOTE TITLE", n.title, function(v) n.title = Util.clean(v); Notes.save(); UI.request(true); return true end, { maxLen = 64 })
  end)
  Canvas:roundRect(x, top + titleH + 1, w, bodyH, 1, Theme.C.surface, Theme.C.bg)
  Canvas:textFit(x + 2, top + titleH + 1, w - 4, "BODY", Theme.C.dim, Theme.C.surface)
  Canvas:textBlock(x + 2, top + titleH + 2, w - 4, n.body ~= "" and n.body or "(empty)", Theme.C.text, Theme.C.surface, math.max(1, bodyH - 2))
  UI.hit(x, top + titleH + 1, w, bodyH, function()
    UI.askText("NOTE BODY", n.body, function(v) n.body = Util.clean(v); Notes.save(); UI.request(true); return true end, { maxLen = 240, allowEmpty = true })
  end)
  local bw = math.floor((w - 2) / 2)
  UI.button(x, bot - 3, bw, 3, "SAVE", { variant = "primary", icon = "check", fn = function()
    n.updated = os.time and os.time() or 0; Notes.save(); UI.toast("Note saved", "success"); App.back()
  end })
  UI.button(x + bw + 2, bot - 3, w - bw - 2, 3, "DELETE", { variant = "danger", icon = "trash", fn = function()
    UI.confirm("DELETE NOTE", "Remove this note?", function()
      for i, it in ipairs(Notes.items) do if it == n then table.remove(Notes.items, i); break end end
      Notes.save(); App.back(); UI.toast("Note deleted", "info")
    end, { danger = true, yesLabel = "DELETE" })
  end })
end


------------------------------------------------------------------ notifications
function Screens.notifications()
  local m = UI.frame({ title = "NOTIFICATIONS", tab = "home", mini = true, back = function() App.back() end })
  local x, top, w, bot = m.contentX, m.bodyTop, m.contentW, m.bodyBot
  UI.button(x + w - 10, top, 10, 2, "CLEAR", { variant = "surface", fn = function()
    UI.notifications = {}; UI.request(true)
  end })
  Canvas:textFit(x, top, w - 12, #UI.notifications .. " notifications", Theme.C.dim, Theme.C.bg)
  local listY = top + 3
  local total = #UI.notifications
  if total == 0 then
    UI.emptyState(x, listY, w, bot - listY + 1, "badge", "No notifications", "App events will appear here")
    return
  end
  local rowH = 3
  local visible = math.max(1, math.floor((bot - listY + 1) / rowH))
  local scroll = Util.clamp(App.scroll.notifications or 0, 0, math.max(0, total - visible))
  App.scroll.notifications = scroll
  local rail = total > visible
  local listW = w - (rail and 4 or 0)
  for i = 1, visible do
    local n = UI.notifications[total - scroll - i + 1]
    if n then
      local ry = listY + (i - 1) * rowH
      Canvas:roundRect(x, ry, listW, rowH, 1, Theme.C.surface, Theme.C.bg)
      local col = n.kind == "danger" and Theme.C.danger or n.kind == "warning" and Theme.C.warning or n.kind == "success" and Theme.C.green or Theme.C.accent
      Canvas:fill(x, ry, 1, rowH, col)
      Canvas:textFit(x + 3, ry, listW - 5, n.text, Theme.C.text, Theme.C.surface)
      Canvas:textFit(x + 3, ry + 1, listW - 5, n.kind:upper(), Theme.C.dim, Theme.C.surface)
    end
  end
  if rail then UI.scrollRail(x + w - 4, listY, bot - listY + 1, total, scroll, visible, function(delta)
    App.scroll.notifications = Util.clamp(scroll + delta, 0, math.max(0, total - visible)); UI.request(true)
  end) end
end

--======== 96_setup.lua ========
------------------------------------------------------------------ first-run setup
function Screens.setup()
  if not App.setup then
    App.setup = {
      step = 1,
      username = "",
      mode = "pin",
      secret = "",
      confirm = "",
      recoveryCode = nil,
      error = "",
    }
  end
  local st = App.setup
  local w, h = Canvas.w, Canvas.h
  local compact = w < 40 or h < 24
  Canvas:fill(1, 1, w, h, Theme.C.bg)
  -- Ambient corner colour blocks.
  Canvas:roundRect(-6, -6, 22, 12, 4, Theme.C.surface, Theme.C.bg)
  Canvas:roundRect(w - 15, h - 8, 22, 12, 4, Theme.C.surface, Theme.C.bg)
  if compact then
    Canvas:text(2, 1, "CC MUSIC", Theme.C.text, Theme.C.bg)
    Canvas:text(2, 2, APP_TAG, Theme.C.dim, Theme.C.bg)
  else
    Canvas:icon("music", 1, 1, 4, 2, Theme.C.accent, 1)
    Canvas:text(5, 1, "CC MUSIC", Theme.C.text, Theme.C.bg)
    Canvas:text(5, 2, APP_TAG, Theme.C.dim, Theme.C.bg)
  end

  local desired = ({ 15, 18, 18, 16, 16, 18, 21 })[st.step] or 16
  local cw = math.min(50, w - 4)
  local cx = math.floor((w - cw) / 2) + 1
  local cy = math.max(4, math.floor((h - math.min(desired, h - 4)) / 2))
  local ch = math.min(desired, h - cy)
  Canvas:roundRect(cx, cy, cw, ch, 2, Theme.C.surface, Theme.C.bg)
  local ix, iw = cx + 3, cw - 6
  local yy = cy + 2

  local steps = { "WELCOME", "USERNAME", "SECURITY", "SECRET", "CONFIRM", "RECOVERY", "FINISH" }
  Canvas:textFit(ix, yy, iw, compact and string.format("SETUP %d/%d  %s", st.step, #steps, steps[st.step]) or string.format("SETUP  %d / %d  ·  %s", st.step, #steps, steps[st.step]), Theme.C.dim, Theme.C.surface)
  yy = yy + 2

  local function primary(label, fn, icon)
    UI.button(ix, cy + ch - 4, iw, 3, label, { variant = "primary", icon = icon, fn = fn })
  end
  local function field(label, value, secret)
    Canvas:textFit(ix, yy, iw, label, Theme.C.dim, Theme.C.surface)
    Canvas:roundRect(ix, yy + 1, iw, 3, 1, Theme.C.bg, Theme.C.surface)
    local shown = value
    if secret then shown = string.rep("*", #value) end
    if shown == "" then shown = "—" end
    Canvas:textFit(ix + 2, yy + 2, iw - 4, shown, Theme.C.text, Theme.C.bg)
    yy = yy + 5
  end

  if st.step == 1 then
    Canvas:textFit(ix, yy, iw, "WELCOME", Theme.C.accent, Theme.C.surface)
    yy = yy + 2
    if compact then
      yy = yy + Canvas:textBlock(ix, yy, iw, "No root owner yet. Create one to protect settings.", Theme.C.text, Theme.C.surface, 3)
      yy = yy + 1
      Canvas:textFit(ix, yy, iw, "Root is optional.", Theme.C.dim, Theme.C.surface)
    else
      yy = yy + Canvas:textBlock(ix, yy, iw, "This device has no root owner yet. Create one now. It protects system settings, themes, audio, artwork and metadata.", Theme.C.text, Theme.C.surface, 4)
      yy = yy + 1
      Canvas:textFit(ix, yy, iw, "Normal listening never needs root.", Theme.C.dim, Theme.C.surface)
    end
    primary("BEGIN SETUP", function() st.step = 2; UI.request(true) end, "lock")
  elseif st.step == 2 then
    Canvas:textFit(ix, yy, iw, "ROOT USERNAME", Theme.C.accent, Theme.C.surface)
    yy = yy + 2
    field("USERNAME", st.username, false)
    local chooseLabel = compact and (st.username == "" and "CHOOSE NAME" or "CHANGE NAME") or (st.username == "" and "CHOOSE USERNAME" or "CHANGE USERNAME")
    UI.button(ix, yy, iw, 3, chooseLabel, { variant = "surface", icon = "user", fn = function()
      UI.openKeyboard({
        title = "ROOT USERNAME",
        value = st.username,
        hint = "3-24 characters",
        maxLen = 24,
        minLen = 3,
        onDone = function(v)
          st.username = Util.trim(v)
          if st.username == "" then return false, "Enter a username" end
          st.error = ""
          return true
        end,
      })
    end })
    if st.username ~= "" then
      primary("CONTINUE", function() st.step = 3; UI.request(true) end, "nextSmall")
    end
  elseif st.step == 3 then
    Canvas:textFit(ix, yy, iw, "CREDENTIAL TYPE", Theme.C.accent, Theme.C.surface)
    yy = yy + 2
    if compact then
      local function card(label, sub, mode, icon)
        local active = st.mode == mode
        Canvas:roundRect(ix, yy, iw, 3, 1, active and Theme.C.accentDim or Theme.C.bg, Theme.C.surface)
        Canvas:icon(icon, ix, yy, 4, 3, active and Theme.C.accentLight or Theme.C.muted, 1)
        Canvas:textFit(ix + 4, yy, iw - 5, label, Theme.C.text, active and Theme.C.accentDim or Theme.C.bg)
        Canvas:textFit(ix + 4, yy + 1, iw - 5, sub, Theme.C.dim, active and Theme.C.accentDim or Theme.C.bg)
        UI.hit(ix, yy, iw, 3, function() st.mode = mode; UI.request(true) end)
        yy = yy + 3
      end
      card("PIN", "4-8 digits", "pin", "lock")
      card("PASSWORD", "6+ characters", "password", "unlock")
      Canvas:textFit(ix, yy, iw, st.mode == "pin" and "PIN is easier to guess." or "Longer is stronger.", Theme.C.dim, Theme.C.surface)
    else
      local cardH = 5
      local gap = 2
      local bw = math.floor((iw - gap) / 2)
      local function card(x, label, sub, mode, icon)
        local active = st.mode == mode
        Canvas:roundRect(x, yy, bw, cardH, 1, active and Theme.C.accentDim or Theme.C.bg, Theme.C.surface)
        Canvas:icon(icon, x, yy, 6, 3, active and Theme.C.accentLight or Theme.C.muted, 1)
        Canvas:textFit(x + 6, yy + 1, bw - 7, label, Theme.C.text, active and Theme.C.accentDim or Theme.C.bg)
        Canvas:textFit(x + 2, yy + 3, bw - 4, sub, Theme.C.dim, active and Theme.C.accentDim or Theme.C.bg)
        UI.hit(x, yy, bw, cardH, function() st.mode = mode; UI.request(true) end)
      end
      card(ix, "PIN", "Fast, 4-8 digits", "pin", "lock")
      card(ix + bw + gap, "PASSWORD", "Stronger, 6+ chars", "password", "unlock")
      yy = yy + cardH + 2
      Canvas:textFit(ix, yy, iw, st.mode == "pin" and "PIN is convenient but easier to guess." or "A longer password is recommended.", Theme.C.dim, Theme.C.surface)
    end
    primary("CONTINUE", function() st.step = 4; UI.request(true) end, "nextSmall")
  elseif st.step == 4 then
    Canvas:textFit(ix, yy, iw, "CREATE " .. (st.mode == "pin" and "PIN" or "PASSWORD"), Theme.C.accent, Theme.C.surface)
    yy = yy + 2
    field(st.mode == "pin" and "PIN" or "PASSWORD", st.secret, true)
    UI.button(ix, yy, iw, 3, st.secret == "" and ("ENTER " .. (st.mode == "pin" and "PIN" or "PASSWORD")) or "CHANGE", { variant = "surface", icon = "lock", fn = function()
      UI.openKeyboard({
        title = "CREATE " .. (st.mode == "pin" and "PIN" or "PASSWORD"),
        hint = st.mode == "pin" and "4-8 digits" or "At least 6 characters",
        mode = st.mode,
        secret = true,
        maxLen = st.mode == "pin" and Auth.maxPin or Auth.maxSecret,
        minLen = st.mode == "pin" and Auth.minPin or Auth.minPassword,
        onDone = function(v)
          st.secret = v
          st.step = 5
          UI.request(true)
          return true
        end,
      })
    end })
    if #st.secret > 0 then
      primary("CONTINUE", function() st.step = 5; UI.request(true) end, "nextSmall")
    end
  elseif st.step == 5 then
    Canvas:textFit(ix, yy, iw, "CONFIRM " .. (st.mode == "pin" and "PIN" or "PASSWORD"), Theme.C.accent, Theme.C.surface)
    yy = yy + 2
    field("RE-ENTER", st.confirm, true)
    UI.button(ix, yy, iw, 3, "RE-ENTER", { variant = "surface", icon = "lock", fn = function()
      UI.openKeyboard({
        title = "CONFIRM SECRET",
        mode = st.mode,
        secret = true,
        maxLen = st.mode == "pin" and Auth.maxPin or Auth.maxSecret,
        minLen = st.mode == "pin" and Auth.minPin or Auth.minPassword,
        onDone = function(v)
          if v ~= st.secret then
            st.error = "Values do not match"
            st.secret = ""
            st.confirm = ""
            st.step = 4
            UI.request(true)
            return true
          end
          st.confirm = v
          local ok, err, code = Auth.create(st.username, st.mode, st.secret)
          if not ok then
            st.error = err or "Could not create root"
            UI.request(true)
            return true
          end
          st.recoveryCode = code
          st.step = 6
          UI.request(true)
          return true
        end,
      })
    end })
    if st.error ~= "" then
      Canvas:textFit(ix, yy + 4, iw, st.error, Theme.C.danger, Theme.C.surface)
    end
    if st.confirm ~= "" then
      primary(compact and "CREATE ROOT" or "CREATE ROOT ACCOUNT", function()
        local ok, err, code = Auth.create(st.username, st.mode, st.secret)
        if not ok then
          st.error = err or "Could not create root"
          UI.request(true)
          return
        end
        st.recoveryCode = code
        st.step = 6
        UI.request(true)
      end, "check")
    end
  elseif st.step == 6 then
    Canvas:textFit(ix, yy, iw, "RECOVERY CODE", Theme.C.accent, Theme.C.surface)
    yy = yy + 2
    Canvas:textFit(ix, yy, iw, compact and "Write this down." or "Write this down. It is shown once.", Theme.C.muted, Theme.C.surface)
    Canvas:roundRect(ix, yy + 2, iw, 4, 1, Theme.C.bg, Theme.C.surface)
    Canvas:textCenter(ix, yy + 3, iw, st.recoveryCode or "??????????", Theme.C.accentLight, Theme.C.bg)
    yy = yy + 7
    Canvas:textFit(ix, yy, iw, "Anyone with this code can reset the root secret.", Theme.C.dim, Theme.C.surface)
    primary("I'VE SAVED IT", function() st.step = 7; UI.request(true) end, "check")
  elseif st.step == 7 then
    Canvas:textFit(ix, yy, iw, "FINISH", Theme.C.accent, Theme.C.surface)
    yy = yy + 2
    if compact then
      local cols, gap = 4, 1
      local bw = math.floor((iw - gap * (cols - 1)) / cols)
      local selected = "Teal"
      for _, a in ipairs(Config.accents) do if a.id == App.cfg.accent then selected = a.label end end
      yy = yy + 1
      Canvas:textFit(ix, yy - 1, iw, "Selected: " .. selected, Theme.C.muted, Theme.C.surface)
      for i, a in ipairs(Config.accents) do
        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        local ax = ix + col * (bw + gap)
        local ay = yy + row * 3
        local slot = Config.accentSlot[a.id] or Theme.C.accent
        Canvas:roundRect(ax, ay, bw, 3, 1, slot, Theme.C.surface)
        if App.cfg.accent == a.id and App.cfg.accentRgb == nil then Canvas:fill(ax, ay + 3, bw, 1, Theme.C.text) end
        UI.hit(ax, ay, bw, 3, function() Theme.setAccent(a.rgb, a.id) end)
      end
      primary("START", function()
        Config.saveNow(); App.setup = nil; App.screen = "home"; App.tab = "home"
        Auth.root = true; Auth.rootAt = Util.now()
        UI.toast("Welcome to CC MUSIC", "success"); UI.request(true)
      end, "playSmall")
    else
      Canvas:textFit(ix, yy, iw, "Pick an accent colour.", Theme.C.text, Theme.C.surface)
      yy = yy + 2
      local cols = iw >= 36 and 4 or 3
      local gap = 1
      local bw = math.floor((iw - gap * (cols - 1)) / cols)
      for i, a in ipairs(Config.accents) do
        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        local ax = ix + col * (bw + gap)
        local ay = yy + row * 4
        local slot = Config.accentSlot[a.id] or Theme.C.accent
        Canvas:roundRect(ax, ay, bw, 3, 1, slot, Theme.C.surface)
        Canvas:textCenter(ax, ay + 1, bw, a.label, (Util.luma(Theme.col(slot)) > 0.55 and Theme.C.bg or Theme.C.text), slot)
        if App.cfg.accent == a.id and App.cfg.accentRgb == nil then Canvas:fill(ax, ay + 3, bw, 1, Theme.C.accent) end
        UI.hit(ax, ay, bw, 3, function() Theme.setAccent(a.rgb, a.id) end)
      end
      primary("START LISTENING", function()
        Config.saveNow(); App.setup = nil; App.screen = "home"; App.tab = "home"
        Auth.root = true; Auth.rootAt = Util.now()
        UI.toast("Welcome to CC MUSIC", "success"); UI.request(true)
      end, "playSmall")
    end
  end

  if st.error ~= "" and st.step ~= 5 then
    Canvas:textFit(ix, cy + ch - 6, iw, st.error, Theme.C.danger, Theme.C.surface)
  end
  if not compact and cy + ch + 1 <= h then
    Canvas:textCenter(1, cy + ch + 1, w, "root setup · no default credentials", Theme.C.dim, Theme.C.bg)
  end
end

--======== 97_app.lua ========
------------------------------------------------------------------ application
App = {}
App.screen = "home"
App.tab = "home"
App.currentApp = "home"
App.history = {}
App.scroll = {}
App.sel = {}
App.listInfo = {}
App.search = { query = "", results = { tracks = {}, albums = {}, artists = {} }, scroll = 1 }
App.searchHistory = {}
App.lyricsCache = {}
App.lyricScroll = 0
App.lyricFollow = true
App.lyricTrackPath = nil
App.artTarget = nil
App.metaDraft = nil
App.lyricsTarget = nil
App.album = nil
App.artist = nil
App.playlist = nil
App.quit = false
App.isMonitor = false
App.touch = false
App.color = true
App.currentTextScale = 1
App.lastSessionSave = 0
App.lastTick = Util.now()

function App.isProtected(screen)
  return screen:match("^settings") ~= nil
    or screen == "artwork" or screen == "artPicker"
    or screen == "metadata" or screen == "metaForm" or screen == "albumMeta"
    or screen == "lyricsManager" or screen == "lyricsPicker"
end

function App.initDisplay()
  local cfg = App.cfg
  local best, bestName, bestScore, bestSize = nil, nil, -1, nil
  if not App.forceTerm then
    local ok, names = pcall(peripheral.getNames)
    if ok and names then
      for _, name in ipairs(names) do
        local tok, typ = pcall(peripheral.getType, name)
        if tok and typ == "monitor" then
          local wok, m = pcall(peripheral.wrap, name)
          if wok and m then
            pcall(function() m.setTextScale(cfg.monitorScale) end)
            local sok, mw, mh = pcall(m.getSize)
            if sok and mw and mh and mw > 0 and mh > 0 then
              local cok, isCol = pcall(m.isColor)
              local score = mw * mh + (cok and isCol and 1000000 or 0)
              if score > bestScore then
                best, bestName, bestScore, bestSize = m, name, score, { mw, mh }
              end
            end
          end
        end
      end
    end
  end
  local T
  if best then
    T = best
    App.mon = best
    App.monName = bestName
    App.isMonitor = true
  else
    T = term.current()
    App.mon = nil
    App.monName = nil
    App.isMonitor = false
  end
  local ok, w, h = pcall(T.getSize)
  if not ok or not w or not h or w < 1 or h < 1 then
    T = term.current()
    App.isMonitor = false
    ok, w, h = pcall(T.getSize)
  end
  if not ok or not w or not h or w < 1 or h < 1 then
    error("No usable terminal or monitor")
  end
  App.term = T
  local cok, isCol = pcall(T.isColor)
  App.color = cok and isCol or false
  App.touch = App.isMonitor and App.color
  App.currentTextScale = cfg.monitorScale
  pcall(function() T.setCursorBlink(false) end)
  Canvas = CanvasProto.new(w, h)
  App.canvas = Canvas
  Theme.apply(T)
  UI.force = true
  UI.dirty = true
  UI.m = nil
  UI.hits = {}
  if UI.toasts then UI.request(true) end
end

function App.reinitDisplay()
  local ok, err = pcall(App.initDisplay)
  if not ok then
    Store.logError("display", err)
    printError("Display error: " .. tostring(err))
  end
end

function App.applyMonitorScale()
  App.cfg.monitorScale = Util.clamp(App.cfg.monitorScale, 0.5, 2.0)
  Config.saveNow()
  App.initDisplay()
  UI.toast("Text scale " .. string.format("%.1f", App.cfg.monitorScale), "info")
  UI.request(true)
end

function App.pushHistory()
  App.history[#App.history + 1] = {
    screen = App.screen, tab = App.tab, album = App.album, artist = App.artist,
    playlist = App.playlist, scroll = App.scroll,
  }
  if #App.history > 20 then table.remove(App.history, 1) end
end

function App.go(screen, opts)
  opts = opts or {}
  local oldScreen = App.screen
  if screen == App.screen and not opts.force then return end
  if App.isProtected(screen) and not Auth.isRoot() then
    UI.loginPrompt(function() App.go(screen, { force = true }) end)
    return
  end
  if not opts.noHistory and App.screen and App.screen ~= screen then App.pushHistory() end
  if App.isProtected(App.screen) and not App.isProtected(screen) then
    Auth.lock()
  end
  App.screen = screen
  UI.toasts = {}
  if UI.feedback then UI.feedback = nil end
  if screen == "home" then App.tab = "home"
  elseif screen == "music" then App.tab = "music"
  elseif screen == "library" or screen == "album" or screen == "artist" then App.tab = "library"
  elseif screen == "search" then App.tab = "search"
  elseif screen == "playlists" or screen == "playlist" or screen == "playlistAdd" then App.tab = "playlists"
  elseif screen == "queue" or screen == "lyrics" then App.tab = "music"
  elseif screen == "video" or screen == "gallery" or screen == "files" or screen == "notes" or screen == "noteEdit" or screen == "notifications" then App.tab = "home"
  elseif screen == "settings" or screen:match("^settings") then App.tab = "home"
  end
  local appId = Apps.appForScreen(screen)
  if appId then
    App.currentApp = appId
    if appId ~= "home" then Apps.record(appId) end
  end
  if oldScreen == "video" and screen ~= "video" and Video and Video.pause then Video.pause() end
  UI.request(true)
end

function App.goTab(tab)
  if App.screen == "video" and Video and Video.pause then Video.pause() end
  if App.isProtected(App.screen) then Auth.lock() end
  App.history = {}
  App.tab = tab
  UI.toasts = {}
  if UI.feedback then UI.feedback = nil end
  if tab == "home" then App.screen = "home"
  elseif tab == "music" then App.screen = "music"
  elseif tab == "library" then App.screen = "library"
  elseif tab == "search" then App.screen = "search"
  elseif tab == "playlists" then App.screen = "playlists"
  elseif tab == "lyrics" then
    if Player.cur then App.openLyrics(Player.cur) else
      App.screen = "home"; App.tab = "home"; UI.toast("Nothing playing", "warning")
    end
  else App.screen = "home" end
  if tab ~= "search" and UI.keyboard and UI.keyboard.title == "SEARCH" then UI.closeKeyboard(false) end
  App.currentApp = tab
  if tab ~= "home" and tab ~= "lyrics" then Apps.record(tab) end
  UI.request(true)
end

function App.launch(id)
  Apps.open(id)
end

function App.minimize()
  if App.screen == "video" and Video and Video.pause then Video.pause() end
  App.go("home", { noHistory = true })
  App.tab = "home"
  App.currentApp = "home"
  UI.request(true)
end

function App.home()
  App.goTab("home")
end

function App.back()
  if Auth.isRoot() and App.isProtected(App.screen) and #App.history == 0 then
    Screens.leaveSettings()
    return
  end
  if App.isProtected(App.screen) and #App.history == 0 then
    Screens.leaveSettings()
    return
  end
  UI.toasts = {}
  local prev = table.remove(App.history)
  if prev then
    if App.screen == "video" and prev.screen ~= "video" and Video and Video.pause then Video.pause() end
    if App.isProtected(App.screen) and not App.isProtected(prev.screen) then Auth.lock() end
    App.screen = prev.screen
    App.tab = prev.tab
    App.album = prev.album
    App.artist = prev.artist
    App.playlist = prev.playlist
    App.currentApp = Apps.appForScreen(App.screen) or App.currentApp
    UI.request(true)
  else
    App.goTab(App.tab or "home")
  end
end

function App.openAlbum(album)
  if not album then return end
  App.album = album
  App.go("album")
end

function App.openArtist(name)
  local artist = Data.findArtist(name)
  if not artist then UI.toast("Artist not found", "warning"); return end
  App.artist = artist
  App.go("artist")
end

function App.openPlaylist(pl)
  if not pl then return end
  App.playlist = pl
  App.go("playlist")
end

function App.openPlaylistAdd(pl)
  if not pl then return end
  App.playlist = pl
  App.go("playlistAdd")
end

function App.openQueue()
  App.go("queue")
end

function App.openLyrics(track)
  if not track then track = Player.cur end
  if not track then UI.toast("Nothing playing", "warning"); return end
  App.lyricsTrack = track
  if App.lyricTrackPath ~= track.path then
    App.lyricTrackPath = track.path
    App.lyricScroll = 0
    App.lyricFollow = true
  end
  App.go("lyrics", { force = App.screen == "lyrics" })
end

function App.openArtPicker(target, kind)
  if not target then return end
  if kind == "album" then
    App.artTarget = { kind = "album", album = target, folder = target.folder, name = target.name }
  elseif kind == "track" then
    App.artTarget = { kind = "track", track = target, folder = target.folder, name = target.title }
  end
  App.go("artPicker")
end

function App.openMetaForm(track)
  if not track then return end
  App.metaDraft = {
    track = track,
    title = track.title,
    artist = track.artist,
    album = track.album,
    trackNo = track.trackNo,
  }
  App.go("metaForm")
end

function App.openLyricsPicker(track)
  if not track then return end
  App.lyricsTarget = track
  App.go("lyricsPicker")
end

function App.openAlbumActions(album)
  if not album then return end
  local items = {
    { label = "Play album", icon = "play", value = "play" },
    { label = "Shuffle album", icon = "shuffle", value = "shuffle" },
    { label = "Add to queue", icon = "queue9", value = "queue" },
  }
  if Auth.isRoot() then
    items[#items + 1] = { label = "Edit album info (root)", icon = "edit", value = "info" }
    items[#items + 1] = { label = "Change artwork (root)", icon = "palette", value = "art" }
    items[#items + 1] = { label = "Edit first track (root)", icon = "list", value = "meta" }
  end
  UI.actions(album.name, items, function(value)
    if value == "play" then Player.playContext(album.tracks, 1, album.name)
    elseif value == "shuffle" then Player.playShuffled(album.tracks, album.name)
    elseif value == "queue" then Player.queueAddMany(album.tracks, false); UI.toast("Album queued", "info")
    elseif value == "info" then App.openAlbumMeta(album)
    elseif value == "art" then App.openArtPicker(album, "album")
    elseif value == "meta" then
      if album.tracks[1] then App.openMetaForm(album.tracks[1]) end
    end
  end)
end

function App.openAlbumMeta(album)
  if not album then return end
  App.albumDraft = { album = album, name = album.name, artist = album.artist }
  App.go("albumMeta")
end

function App.addSearchHistory(query)
  query = Util.trim(Util.clean(query))
  if #query < 2 then return end
  for i, q in ipairs(App.searchHistory) do
    if q == query then table.remove(App.searchHistory, i); break end
  end
  table.insert(App.searchHistory, 1, query)
  while #App.searchHistory > 8 do table.remove(App.searchHistory) end
  Store.saveSoon("searches", { items = App.searchHistory })
end

function App.loadSearchHistory()
  local d = Store.load("searches", nil)
  if type(d) == "table" and type(d.items) == "table" then
    App.searchHistory = {}
    for _, q in ipairs(d.items) do
      if type(q) == "string" and #q <= 80 then App.searchHistory[#App.searchHistory + 1] = Util.clean(q) end
    end
    while #App.searchHistory > 8 do table.remove(App.searchHistory) end
  end
end

function App.rebuildAfterScan()
  Player.rebuildAfterScan()
  Art.clearCache()
  Screens.clearLyricsCache()
  if App.album then App.album = Data.findAlbumByKey(App.album.key) end
  if App.artist then App.artist = Data.findArtist(App.artist.name) end
  if App.screen == "album" and not App.album then App.goTab("library") end
  if App.screen == "artist" and not App.artist then App.goTab("library") end
  if App.search.query and App.search.query ~= "" then Screens.applySearch(App.search.query, false) end
  UI.request(true)
end

function App.onLock()
  if UI.toasts then UI.toast("Root session locked", "info") end
  if App.isProtected(App.screen) then
    App.screen = "home"
    App.tab = "home"
    App.currentApp = "home"
    App.history = {}
    UI.request(true)
  end
end

function App.activateSelection()
  local key, list
  if App.screen == "library" then
    key = App.libTab
    if key == "albums" then
      local idx = App.sel.albums
      if idx and Data.albums[idx] then App.openAlbum(Data.albums[idx]) end
      return
    elseif key == "artists" then
      local idx = App.sel.artists
      if idx and Data.artists[idx] then App.openArtist(Data.artists[idx].name) end
      return
    elseif key == "songs" then list = Data.tracks
    elseif key == "favorites" then list = Data.favoriteTracks()
    elseif key == "recent" then list = Data.recentTracks() end
    local idx = App.sel[key] or 1
    if list and list[idx] then Player.playContext(list, idx, key) end
  elseif App.screen == "album" and App.album then
    local idx = App.sel.album or 1
    if App.album.tracks[idx] then Player.playContext(App.album.tracks, idx, App.album.name) end
  elseif App.screen == "playlist" and App.playlist then
    local tr = Data.playlistTracks(App.playlist)
    local idx = App.sel.playlist or 1
    if tr[idx] then Player.playContext(tr, idx, App.playlist.name) end
  elseif App.screen == "queue" then
    local idx = App.sel.queue or Player.qpos
    if Player.qorder[idx] then Player.playEntryAt(idx) end
  elseif App.screen == "search" then
    local idx = App.sel.search or 1
    if App.search.results.tracks[idx] then Player.playContext(App.search.results.tracks, idx, "Search") end
  end
end

function App.scrollWheel(dir)
  dir = dir or 1
  local key
  if App.screen == "library" then
    key = App.libTab == "albums" and "albums" or App.libTab
    if App.libTab == "albums" and App.cfg.albumView == "list" then key = "albumsList" end
  elseif App.screen == "search" then
    App.search.scroll = math.max(1, (App.search.scroll or 1) + dir * 2)
  elseif App.screen == "queue" then key = "queue"
  elseif App.screen == "album" then key = "album"
  elseif App.screen == "playlist" then key = "playlist"
  elseif App.screen == "artist" then key = "artistAlbums"
  elseif App.screen == "playlists" then key = "playlists"
  elseif App.screen == "settings" then key = "settings"
  elseif App.screen == "settingsAppearance" then key = "appearance"
  elseif App.screen == "settingsAudio" then key = "audioSettings"
  elseif App.screen == "settingsLibrary" then key = "librarySettings"
  elseif App.screen == "settingsSecurity" then key = "securitySettings"
  elseif App.screen == "settingsAbout" then key = "about"
  elseif App.screen == "artwork" then key = "artwork"
  elseif App.screen == "metadata" then key = "metadata"
  elseif App.screen == "lyricsManager" then key = "lyricsManager"
  end
  if key then
    App.scroll[key] = math.max(0, (App.scroll[key] or 0) + dir * 2)
    UI.request(true)
  end
end

function App.handlePaste(text)
  Auth.touch()
  if UI.keyboard then
    local kb = UI.keyboard
    local t = Util.clean(text)
    if kb.mode == "pin" then t = t:gsub("%D", "") end
    if #kb.value + #t <= kb.maxLen then
      local c = Util.clamp(kb.cursor, 1, #kb.value + 1)
      kb.value = kb.value:sub(1, c - 1) .. t .. kb.value:sub(c)
      kb.cursor = c + #t
      kb.error = ""
      UI.keyboardChanged()
      UI.request(true)
    end
  end
end

function App.handleKey(key)
  Auth.touch()
  if UI.keyboard then
    local kb = UI.keyboard
    if key == keys.enter or key == keys.numPadEnter then UI.keyboardDone()
    elseif key == keys.backspace then UI.keyboardBackspace()
    elseif key == keys.escape then UI.closeKeyboard(true)
    elseif key == keys.left then kb.cursor = math.max(1, (kb.cursor or 1) - 1); UI.request(true)
    elseif key == keys.right then kb.cursor = math.min(#kb.value + 1, (kb.cursor or 1) + 1); UI.request(true)
    end
    return
  end
  if UI.modal then
    local md = UI.modal
    if key == keys.escape then UI.closeModal()
    elseif md.kind == "actions" then
      if key == keys.up then md.sel = math.max(1, (md.sel or 1) - 1); UI.request(true)
      elseif key == keys.down then md.sel = math.min(#md.items, (md.sel or 1) + 1); UI.request(true)
      elseif key == keys.enter or key == keys.numPadEnter then
        local item = md.items[md.sel]
        local cb = md.onPick
        UI.closeModal()
        if item and cb then pcall(cb, item.value ~= nil and item.value or item) end
      end
    elseif key == keys.enter or key == keys.numPadEnter then
      local cb = md.onYes
      UI.closeModal()
      if cb then pcall(cb) end
    end
    return
  end
  if App.screen == "setup" then return end
  if App.screen == "video" then
    if key == keys.space then Video.toggle()
    elseif key == keys.left then if Video.loaded then Video.seek(Video.position - 5000) end
    elseif key == keys.right then if Video.loaded then Video.seek(Video.position + 5000) end
    elseif key == keys.f then Video.fullscreen = not Video.fullscreen; Video.showControls = true; UI.request(true)
    elseif key == keys.escape then
      if Video.fullscreen then Video.fullscreen = false; UI.request(true) else App.back() end
    elseif key == keys.h then App.goTab("home") end
    return
  end
  if key == keys.space then Player.togglePause()
  elseif key == keys.n then Player.next(false)
  elseif key == keys.p or key == keys.b then Player.prev()
  elseif key == keys.left then Player.seekBy(-10)
  elseif key == keys.right then Player.seekBy(10)
  elseif key == keys.up then Player.setVolume(Audio.volume + 0.05)
  elseif key == keys.down then Player.setVolume(Audio.volume - 0.05)
  elseif key == keys.s then Player.toggleShuffle()
  elseif key == keys.r then Player.cycleRepeat()
  elseif key == keys.m then Player.setMuted(not Audio.muted)
  elseif key == keys.slash then
    App.goTab("search")
    Screens.openSearchKeyboard()
  elseif key == keys.escape then
    App.back()
  elseif key == keys.enter or key == keys.numPadEnter then
    App.activateSelection()
  elseif key == keys.tab then
    local order = { "home", "library", "search", "playlists" }
    local idx = Util.indexOf(order, App.tab) or 1
    App.goTab(order[(idx % #order) + 1])
  end
end

function App.handleEvent(ev, p1, p2, p3)
  if ev == "monitor_touch" then
    if App.isMonitor and p1 == App.monName then
      UI.tap(p2, p3)
    end
  elseif ev == "mouse_click" then
    if p1 == 1 then UI.tap(p2, p3)
    elseif p1 == 2 then
      -- Right-click during music video → normal song/jukebox screen (audio keeps playing).
      if Video.dismissMusic and Video.dismissMusic() then
        -- stayed on music tab
      else
        App.back()
      end
    end
  elseif ev == "mouse_scroll" then
    App.scrollWheel(p1)
  elseif ev == "mouse_drag" or ev == "mouse_up" then
    -- Monitor touch does not provide drag events; terminal drag is intentionally
    -- treated as a click at the latest point for slider convenience.
    if ev == "mouse_drag" and p1 == 1 then UI.tap(p2, p3) end
  elseif ev == "key" then
    App.handleKey(p1)
  elseif ev == "char" then
    Auth.touch()
    if UI.keyboard then
      local kb = UI.keyboard
      local ch = p1
      if kb.mode == "pin" and not ch:match("%d") then return end
      if #kb.value < kb.maxLen then
        local c = Util.clamp(kb.cursor, 1, #kb.value + 1)
        kb.value = kb.value:sub(1, c - 1) .. ch .. kb.value:sub(c)
        kb.cursor = c + 1
        kb.error = ""
        UI.keyboardChanged()
        UI.request(true)
      end
    end
  elseif ev == "paste" then
    App.handlePaste(p1)
  elseif ev == "term_resize" or ev == "monitor_resize" then
    App.reinitDisplay()
    UI.toast("Display resized", "info")
  elseif ev == "peripheral" or ev == "peripheral_detach" then
    Audio.scan()
    local typ = nil
    local ok, t = pcall(peripheral.getType, p1)
    if ok then typ = t end
    if typ == "monitor" or p1 == App.monName then App.reinitDisplay() end
    if typ == "drive" then
      Config.discoverRoots()
      UI.refreshDiskSpace(true)
    end
    UI.toast("Peripherals changed · " .. Audio.liveCount() .. " speakers", "info")
  elseif ev == "disk" or ev == "disk_eject" then
    Config.discoverRoots()
    UI.refreshDiskSpace(true)
    UI.request(true)
  elseif ev == "speaker_audio_empty" then
    -- Feed speakers and detect end-of-track even when Audio.tick is stalled.
    Audio.onSpeakerEmpty()
  elseif ev == "terminate" then
    App.quit = true
  end
end

function App.tick()
  Audio.tick(0)
  if Video.musicTick then Video.musicTick() end
  if App.screen == "video" and Video.tick then Video.tick(Util.now()) end
  UI.update(0)
  Store.flush()
  local now = Util.now()
  if Auth.root and App.cfg.autoLock and App.cfg.autoLock > 0 and (now - Auth.rootAt) > App.cfg.autoLock * 60 then
    Auth.lock()
  end
  if Player.cur and not Player.paused and now - App.lastSessionSave > 10 then
    App.lastSessionSave = now
    Player.saveSession()
  end
end

function App.cleanup()
  -- Persist the playback position BEFORE Audio.stop() clears the stream.
  if Player and Player.saveSessionNow then pcall(Player.saveSessionNow) end
  pcall(Audio.stop)
  if Data and Data.saveAllUser then pcall(Data.saveAllUser) end
  if Config then pcall(Config.saveNow) end
  if Store then pcall(Store.flush, true) end
  if Theme then pcall(Theme.restore, App.term) end
  if App.term then
    pcall(function()
      App.term.setBackgroundColor(Theme.colorConstant(Theme.C.bg))
      App.term.setTextColor(Theme.colorConstant(Theme.C.text))
      App.term.clear()
      App.term.setCursorPos(1, 1)
      App.term.setCursorBlink(true)
    end)
  end
end

function App.main()
  local now = Util.now()
  App.lastTick = now
  local tick = os.startTimer(0.05)
  while not App.quit do
    local ev, p1, p2, p3 = os.pullEventRaw()
    if ev == "timer" and p1 == tick then
      -- Schedule the next tick AFTER App.tick returns. Arming it first meant
      -- any nested sleep/pullEvent inside tick (legacy kickstart) could eat
      -- that timer id and permanently stall the loop — songs would finish
      -- without auto-advance.
      local ok, err = pcall(App.tick)
      if not ok then Store.logError("tick", err) end
      tick = os.startTimer(0.05)
    else
      local ok, err = pcall(App.handleEvent, ev, p1, p2, p3)
      if not ok then
        Store.logError("event " .. tostring(ev), err)
        UI.toast("An action failed: " .. Util.fit(tostring(err), 30), "danger")
      end
    end
    local t = Util.now()
    if not App.quit and UI.wantsDraw(t) then
      local ok, err = pcall(UI.draw)
      if not ok then Store.logError("draw loop", err) end
      UI.nextDraw = t + 0.07
    end
  end
end

--======== 99_boot.lua ========

------------------------------------------------------------------ ProOnlyUNO bridge
-- Disk roots, .nfp art, pocket_mp3 + jukebox_viz, brand helpers, no LIKE/FOLLOW.
local PROTO = {
  pocket = "pocket_mp3",
  viz = "jukebox_viz",
  vizInterval = 0.05,
  vizIdleInterval = 0.45,
  vizMetaEvery = 1.0,
}

local function openWirelessModems()
  peripheral.find("modem", function(_, m)
    if m.isWireless and m.isWireless() then pcall(rednet.open, _) end
  end)
end

-- Lean defaults; Config.discoverRoots() / listFloppyMounts() attach every
-- present disk/diskN (any N) and drive-peripheral mounts at boot and on insert.
do
  Config.defaultRoots = { "music", "disk", "disk/music" }
  Config.legacyRoots = { "music", "disk", "disk/music" }
end

-- Always sync-scroll lyrics (no FOLLOW toggle).
App.lyricFollow = true

-- Skip forced root-auth setup: listening never requires credentials.
local _authLoad = Auth.load
function Auth.load()
  local ok = _authLoad()
  if not Auth.configured then
    Auth.configured = true
    Auth.root = true
    Auth.rootAt = Util.now()
    Auth.data = Auth.data or { username = "ProOnlyUNO", mode = "open" }
  end
  return ok or true
end
function Auth.isRoot()
  return true
end
function Auth.lock()
  -- no-op: ProOnlyUNO jukebox stays unlocked for listening
end

-- .nfp album art (paintutils) alongside BMP/PPM.
local _isImage = Art.isImageFile
function Art.isImageFile(name)
  local ext = tostring(name):lower():match("%.([%w]+)$")
  if ext == "nfp" then return true end
  return _isImage(name)
end

-- Official CC:Tweaked default palette (sRGB), matching desktop nfp_core.CC_PALETTE.
-- .nfp hex digits index THIS palette, not Theme.rgb (which is remapped for UI).
local NFP_CC_RGB = {
  [0] = 0xF0F0F0, [1] = 0xF2B233, [2] = 0xE57FD8, [3] = 0x99B2F2,
  [4] = 0xDEDE6C, [5] = 0x7FCC19, [6] = 0xF2B2CC, [7] = 0x4C4C4C,
  [8] = 0x999999, [9] = 0x4C99B2, [10] = 0xB266E5, [11] = 0x3366CC,
  [12] = 0x7F664C, [13] = 0x57A64E, [14] = 0xCC4C4C, [15] = 0x111111,
}

local function decodeNfp(path, pal)
  pal = pal or Theme.artPalette()
  -- Parse .nfp as text (CRLF-safe). Avoid paintutils.loadImage tables for large covers.
  local okOpen, fh = pcall(fs.open, path, "r")
  if not okOpen or not fh then return nil, "missing nfp" end
  local rows, w, h = {}, 0, 0
  while true do
    local line = fh.readLine()
    if line == nil then break end
    line = tostring(line):gsub("\r", "")
    local row = {}
    for i = 1, #line do
      local n = tonumber(line:sub(i, i), 16)
      if n then row[#row + 1] = n end
    end
    if #row > 0 then
      h = h + 1
      rows[h] = row
      if #row > w then w = #row end
    end
  end
  pcall(function() fh.close() end)
  if w < 1 or h < 1 then return nil, "empty nfp" end

  -- Decode into the same IMG×IMG buffer as BMP/PPM so Art.buildCells stays sharp.
  local outSide = IMG
  local pix = {}
  local counts = {}
  for ty = 0, outSide - 1 do
    local y0 = math.floor(ty * h / outSide)
    local y1 = math.max(y0 + 1, math.floor((ty + 1) * h / outSide))
    for tx = 0, outSide - 1 do
      local x0 = math.floor(tx * w / outSide)
      local x1 = math.max(x0 + 1, math.floor((tx + 1) * w / outSide))
      local best, bestN = 15, -1
      for sy = y0, y1 - 1 do
        local row = rows[sy + 1] or {}
        for sx = x0, x1 - 1 do
          local ccIdx = row[sx + 1]
          if ccIdx == nil then ccIdx = 15 end
          local r, g, b = Util.rgbParts(NFP_CC_RGB[ccIdx] or 0x111111)
          -- Remap intended CC colour into the live Theme.artPalette indices.
          local ti = nearestColor(r, g, b, pal)
          local n = (counts[ti] or 0) + 1
          counts[ti] = n
          if n > bestN then bestN = n; best = ti end
        end
      end
      pix[#pix + 1] = string.char(best)
      for k in pairs(counts) do counts[k] = nil end
    end
  end
  return { w = outSide, h = outSide, pix = table.concat(pix), source = "nfp", path = path }
end

local _loadImage = Art.loadImage
function Art.loadImage(path)
  if type(path) == "string" and path:lower():match("%.nfp$") then
    local okAttr, attr = pcall(fs.attributes, path)
    local size = okAttr and type(attr) == "table" and tonumber(attr.size) or nil
    local mtime = okAttr and type(attr) == "table" and (attr.mtime or attr.modified) or nil
    local key = path .. "|" .. tostring(size) .. "|" .. tostring(mtime) .. "|" .. Theme.version .. "|nfp"
    local hit = Art.images[key]
    if hit then return hit end
    local img, err = decodeNfp(path, Theme.artPalette())
    if not img then return nil, err end
    Art.images[key] = img
    Art.trimImages()
    return img
  end
  return _loadImage(path)
end

-- Prefer song.nfp / cover.nfp / album.nfp next to tracks.
local _autoCover = Art.autoCover
function Art.autoCover(folder)
  if folder and fs.isDir(folder) then
    local prefer = { "cover.nfp", "album.nfp", "folder.nfp", "art.nfp" }
    for _, name in ipairs(prefer) do
      local p = fs.combine(folder, name)
      if fs.exists(p) then return p end
    end
    local ok, entries = pcall(fs.list, folder)
    if ok and entries then
      for _, entry in ipairs(entries) do
        if tostring(entry):lower():match("%.nfp$") then
          return fs.combine(folder, entry)
        end
      end
    end
  end
  return _autoCover(folder)
end

------------------------------------------------------------------ pocket_mp3
local function pocketListener()
  openWirelessModems()
  local proto = PROTO.pocket
  local lastBroadcast = 0
  local dirty = false

  local function buildSlim()
    local slim, curIdx = {}, 1
    for i, t in ipairs(Data.tracks) do
      slim[i] = {
        disp = t.title,
        album = t.album,
        artist = t.artist,
        size = math.floor((t.dur or 0) * 6000),
      }
      if Player.cur and t.path == Player.cur.path then curIdx = i end
    end
    return slim, curIdx
  end

  local function sendSync(target)
    local slim, curIdx = buildSlim()
    local pkt = {
      songs = slim,
      idx = curIdx,
      play = (Player.cur ~= nil and not Player.paused),
      shf = Player.shuffle and true or false,
      vol = Audio.volume or 0.75,
    }
    if target then rednet.send(target, pkt, proto) else rednet.broadcast(pkt, proto) end
    lastBroadcast = Util.now()
    dirty = false
  end

  while true do
    local id, m = rednet.receive(proto, 0.4)
    if type(m) == "table" then
      if m.cmd == "sync" then
        sendSync(id)
      elseif m.cmd == "pick" and type(m.n) == "number" and Data.tracks[m.n] then
        Player.playContext(Data.tracks, m.n, "Library")
        sendSync()
      elseif m.cmd == "toggle" then
        if Player.cur then
          Player.togglePause()
        elseif Data.tracks[1] then
          Player.playContext(Data.tracks, 1, "Library")
        end
        sendSync()
      elseif m.cmd == "next" then
        if Player.cur then Player.next(false)
        elseif Data.tracks[1] then Player.playContext(Data.tracks, 1, "Library") end
        sendSync()
      elseif m.cmd == "prev" then
        if Player.cur then Player.prev() end
        sendSync()
      elseif m.cmd == "shf" then
        Player.toggleShuffle()
        sendSync()
      elseif m.cmd == "vol" and type(m.d) == "number" then
        Player.setVolume((Audio.volume or 0.75) + m.d)
        sendSync()
      end
    elseif dirty and (Util.now() - lastBroadcast) > 0.3 then
      sendSync()
    end
  end
end

------------------------------------------------------------------ jukebox_viz
local function vizBroadcaster()
  openWirelessModems()
  local proto = PROTO.viz
  local lastSend, lastMetaAt = 0, 0
  local lastMetaKey, lastLyricKey = "", ""

  local function copyLevels(src, signed)
    local out = {}
    for i = 1, #(src or {}) do
      local v = math.floor((src[i] or 0) * 100 + ((src[i] or 0) >= 0 and 0.5 or -0.5))
      if signed then
        if v > 100 then v = 100 elseif v < -100 then v = -100 end
      else
        if v > 100 then v = 100 elseif v < 0 then v = 0 end
      end
      out[i] = v
    end
    return out
  end

  local function sendViz(forceMeta)
    local playing = Player.cur ~= nil and not Player.paused
    local t = Player.cur
    local metaKey = t and (t.path or "") or ""
    local needMeta = forceMeta or metaKey ~= lastMetaKey or (Util.now() - lastMetaAt) >= PROTO.vizMetaEvery
    local lyricText = ""
    if t and Screens.lyricsFor then
      local lrc = Screens.lyricsFor(t)
      if lrc and lrc.sync then
        local idx = Lrc.currentIndex(lrc, Player.position(), 1)
        local line = lrc.lines[idx]
        if line then lyricText = line.text or "" end
      end
    end
    local lyricKey = lyricText
    local needLyric = forceMeta or lyricKey ~= lastLyricKey
    local viz = Audio.viz or {}
    local pkt = {
      v = 1,
      play = playing,
      paused = t ~= nil and Player.paused or false,
      stop = t == nil,
      e = math.floor((viz.rms or 0) * 100 + 0.5),
      peak = math.floor((viz.peak or 0) * 100 + 0.5),
      b = copyLevels(viz.bands or viz.target, false),
      w = copyLevels(viz.wave, true),
      lyricsOn = lyricText ~= "",
      vizMode = (App.cfg and App.cfg.visualizer) or "bars",
      accent = (App.cfg and App.cfg.accent) or "violet",
      anim = not (App.cfg and App.cfg.animations == false),
      ts = Util.now(),
    }
    if needMeta then
      pkt.title = t and t.title or ""
      pkt.artist = t and t.artist or ""
      pkt.album = t and t.album or ""
      pkt.pos = t and Player.position() or 0
      pkt.dur = t and t.dur or 0
      lastMetaAt = Util.now()
      lastMetaKey = metaKey
    end
    if needLyric then
      pkt.lyric = lyricText
      lastLyricKey = lyricKey
    end
    rednet.broadcast(pkt, proto)
    lastSend = Util.now()
  end

  sendViz(true)
  while true do
    local playing = Player.cur ~= nil and not Player.paused
    local interval = playing and PROTO.vizInterval or PROTO.vizIdleInterval
    local wait = math.max(0.02, interval - (Util.now() - lastSend))
    local tid = os.startTimer(wait)
    repeat
      local ev, p1 = os.pullEvent()
      if ev == "timer" and p1 == tid then break end
    until false
    sendViz(false)
  end
end

local function runWithProtocols()
  parallel.waitForAny(App.main, pocketListener, vizBroadcaster)
end

------------------------------------------------------------------ boot
local function printUsage()
  print(APP_NAME .. " " .. VERSION .. " - ProOnlyUNO jukebox for CC:Tweaked")
  print("Usage: jukebox [options] [music-root ...]")
  print("  --scale=NUMBER   text scale, 0.1 steps (0.5 - 2.0)")
  print("  --data=PATH      data directory (default .aurora)")
  print("  --root=PATH      add a music root (repeatable)")
  print("  --term           ignore monitors, use the computer terminal")
  print("  --help           show this help")
  print("")
  print("Music must be DFPWM: music/<Album>/<Track>.dfpwm")
  print("Artwork: BMP (8/24/32-bit) or PPM (P6/P3) beside the album.")
  print("Lyrics:  matching .lrc or .txt file beside the track.")
end

local function splash(message, sub)
  Canvas:fill(1, 1, Canvas.w, Canvas.h, Theme.C.bg)
  Canvas:icon("music", 1, 1, 10, 3, Theme.C.accent, 2)
  Canvas:text(8, 2, "CC MUSIC", Theme.C.text, Theme.C.bg)
  Canvas:text(8, 3, APP_TAG, Theme.C.dim, Theme.C.bg)
  Canvas:textCenter(1, math.floor(Canvas.h / 2) - 1, Canvas.w, message or "PREPARING", Theme.C.accent, Theme.C.bg)
  if sub then Canvas:textCenter(1, math.floor(Canvas.h / 2) + 1, Canvas.w, sub, Theme.C.muted, Theme.C.bg) end
  Canvas:present(App.term, true)
end

local function run(argv)
  local roots = {}
  local dataDir = ".aurora"
  local monitorScale
  local forceTerm = false
  local help = false
  local i = 1
  while i <= #argv do
    local a = tostring(argv[i])
    if a == "--term" then
      forceTerm = true
    elseif a == "--help" or a == "-h" then
      help = true
    elseif a:match("^%-%-scale=") then
      monitorScale = tonumber(a:match("=(.+)"))
    elseif a:match("^%-%-data=") then
      dataDir = a:match("=(.+)")
    elseif a:match("^%-%-root=") then
      local p = a:match("=(.+)")
      if p and p ~= "" then roots[#roots + 1] = p end
    elseif a:sub(1, 2) ~= "--" then
      roots[#roots + 1] = a
    end
    i = i + 1
  end
  if help then printUsage(); return end

  App.forceTerm = forceTerm
  math.randomseed((os.epoch and os.epoch("utc") or os.time())
    + (os.getComputerID and os.getComputerID() or 0) * 7919
    + math.floor((os.clock and os.clock() or 0) * 100000))
  Store.setDir(dataDir)

  App.cfg = Config.load()
  if monitorScale then App.cfg.monitorScale = Util.clamp(monitorScale, 0.5, 2.0) end
  if #roots > 0 then App.cfg.roots = roots end
  -- Validate again after CLI overrides.
  App.cfg.monitorScale = Util.clamp(App.cfg.monitorScale, 0.5, 2.0)
  Config.discoverRoots()
  Config.saveSoon()

  Theme.rebuild()
  App.initDisplay()
  Theme.apply(App.term)

  splash("SCANNING MUSIC", "Reading your library...")
  Data.loadAll()
  Auth.load()

  Audio.init()
  Player.init()
  App.loadSearchHistory()
  UI.refreshDiskSpace(true)

  UI.force = true
  UI.dirty = true
  UI.nextDraw = 0
  App.history = {}
  App.screen = "home"
  App.tab = "home"
  App.setup = nil

  UI.draw()
  if Auth.corrupt and App.screen == "setup" then
    UI.toast("Root data was damaged - set up again", "warning")
  end
  if App.screen ~= "setup" and #Data.tracks == 0 then
    UI.toast("No .dfpwm files found. Open Settings to add a music folder.", "warning")
  end
  if not Audio.loaded then
    UI.toast(Audio.reason, "danger")
  elseif Audio.liveCount() == 0 then
    UI.toast("No speakers attached - browsing still works", "warning")
  end
  UI.request(true)
  UI.draw()

  runWithProtocols()
  App.cleanup()
  print(APP_NAME .. " stopped. · ProOnlyUNO")
end

local ok, err = pcall(run, { ... })
if not ok then
  pcall(function() Store.logError("fatal", err) end)
  pcall(App.cleanup)
  printError("CC MUSIC failed: " .. tostring(err))
end
