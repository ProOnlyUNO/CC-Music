--[[
  visualizer.lua — left/right side-monitor music visualizer for CC:Tweaked
  Listens on rednet protocol "jukebox_viz" from the main jukebox.

  Tuned for 4×4 Advanced Monitors at text scale 0.5 (~120×80).
  Aurora-inspired mode looks (friend 40_canvas / 30_theme / 80_audio /
  85_player patterns) for BARS / WAVE / VU while keeping the 4×4 stage
  chrome: peak caps, filled mid-wave, dual RMS/peak VU, LIVE PCM badge,
  accent-tier palette from jukebox packet, center bloom, particles.
  Idle/paused → calm breath.

  Lyrics mode: when main toggles LYRICS (packet lyricsOn=true) and a lyric
  line is present, bump text scale (~2.5) for big karaoke-style lines on
  the 4×4, then restore viz scale. While lyricsOn but lyric string empty/nil:
  keep the fancy spectrum / particles / stage running (no “(waiting…)”
  chrome — lyric area stays empty). When a line arrives: big lyrics +
  subtle pulse/particles behind text. Audio / DJ on the main PC are unaffected.

  Now-playing title (top line): horizontal marquee when the full
  artist/title does not fit — pause at start/end, ~0.12s tick, resets on
  track change. Same marquee for the lyrics-mode header.
  While playing, title uses color FX (not rainbow) — pick with --title-fx=
  or cycle with T. Modes: pulse | bass | warmcool | breathe (default).

  Performance: ~28 FPS draw loop, parallel receive (rednet never stalls
  animation), smooth interpolation between lean int-level packets.
  Sparse writes only — no heavy per-pixel loops beyond bar/wave/bloom budgets.

  Usage:
      visualizer
      visualizer --side=left
      visualizer --side=right
      visualizer --scale=0.5
      visualizer --scale=1
      visualizer --side=left --fps=30
      visualizer --title-fx=breathe
      visualizer --title-fx=pulse|bass|warmcool|breathe

  Side: --side=left|right, or auto from computer label containing "left"/"right".
  Right side mirrors the bar / particle layout.
  Title FX: --title-fx=pulse|bass|warmcool|breathe (default breathe).
    pulse    — brightness with energy/bass
    bass     — kick hits shift accent color
    warmcool — energy maps cool↔warm palette
    breathe  — solid accent with soft breathe + gentle palette shift
  Press T while running to cycle title FX modes.

  Replace this file on each side PC and restart (startup preferred).
]]

------------------------------------------------------------------ config
local CONFIG = {
  proto        = "jukebox_viz",
  monitorScale = 0.5,
  lyricsScale  = 2.5,     -- chunky glyphs for karaoke lines on 4×4
  fps          = 0.035,   -- ~28 Hz draw loop (was ~0.07 / 14 Hz)
  side         = nil,     -- "left" | "right" | nil (auto)
  titleFx      = "breathe", -- pulse | bass | warmcool | breathe
  -- visual budgets (auto-clamped from W×H below)
  maxBars      = 28,
  maxParticles = 22,
  wavePoints   = 48,      -- drawn points (interpolated from packet w[])
}

local TITLE_FX_MODES = { "breathe", "pulse", "bass", "warmcool" }
local TITLE_FX_ALIAS = {
  pulse = "pulse",
  bass = "bass",
  ["bass-flash"] = "bass",
  bassflash = "bass",
  warmcool = "warmcool",
  ["hot/cool"] = "warmcool",
  ["hot-cool"] = "warmcool",
  warm = "warmcool",
  cool = "warmcool",
  breathe = "breathe",
  breath = "breathe",
}

local function parseTitleFx(s)
  if type(s) ~= "string" then return nil end
  local key = s:lower():gsub("^%s+", ""):gsub("%s+$", "")
  return TITLE_FX_ALIAS[key]
end

------------------------------------------------------------------ args
for _, a in ipairs({ ... }) do
  if a:match("^%-%-side=") then
    local s = a:match("=(.+)"):lower()
    if s == "left" or s == "right" then CONFIG.side = s end
  elseif a:match("^%-%-scale=") then
    CONFIG.monitorScale = tonumber(a:match("=(.+)")) or CONFIG.monitorScale
  elseif a:match("^%-%-lyrics%-scale=") then
    CONFIG.lyricsScale = tonumber(a:match("=(.+)")) or CONFIG.lyricsScale
  elseif a:match("^%-%-fps=") then
    local f = tonumber(a:match("=(.+)"))
    if f and f > 0 then CONFIG.fps = math.max(0.02, math.min(0.1, 1 / f)) end
  elseif a:match("^%-%-title%-fx=") then
    local fx = parseTitleFx(a:match("=(.+)"))
    if fx then CONFIG.titleFx = fx end
  end
end

------------------------------------------------------------------ side detect
local function detectSide()
  if CONFIG.side then return CONFIG.side end
  local label = (os.getComputerLabel() or ""):lower()
  if label:find("right", 1, true) then return "right" end
  if label:find("left", 1, true) then return "left" end
  -- fallback: odd id → left, even → right
  return (os.getComputerID() % 2 == 0) and "right" or "left"
end

local SIDE = detectSide()
local MIRROR = (SIDE == "right")

------------------------------------------------------------------ hardware
local mon, monName
do
  local best, bestArea = nil, -1
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "monitor" then
      local m = peripheral.wrap(name)
      pcall(m.setTextScale, CONFIG.monitorScale)
      local w, h = m.getSize()
      local area = w * h
      if area > bestArea then
        best, bestArea, monName = m, area, name
      end
    end
  end
  mon = best
end

if not mon then
  error("No monitor attached (need a 4×4 Advanced Monitor on this PC)", 0)
end

pcall(mon.setTextScale, CONFIG.monitorScale)

-- Appearance / mode from jukebox (jukebox_viz packet fields vizMode, accent, anim)
local VIZ_MODE = "bars"  -- bars | wave | vu | off
local VIZ_ANIM = true
local VIZ_ACCENT = "violet"  -- matches jukebox ACCENTS keys

-- Jukebox accent → CC color (Aurora theme idea: accentDim / accent / accentLight)
local ACCENT_MAP = {
  teal   = colors.lightBlue,
  azure  = colors.blue,
  amber  = colors.yellow,
  rose   = colors.red,
  violet = colors.purple,
  lime   = colors.lime,
  ice    = colors.white,
  coral  = colors.orange,
}
local ACCENT_DIM_MAP = {
  teal   = colors.blue,
  azure  = colors.gray,
  amber  = colors.orange,
  rose   = colors.magenta,
  violet = colors.magenta,
  lime   = colors.green,
  ice    = colors.lightGray,
  coral  = colors.red,
}
local ACCENT_LIGHT_MAP = {
  teal   = colors.white,
  azure  = colors.lightBlue,
  amber  = colors.white,
  rose   = colors.pink,
  violet = colors.pink,
  lime   = colors.white,
  ice    = colors.white,
  coral  = colors.yellow,
}

local W, H = mon.getSize()
local lyricsModeActive = false

local modemOk = false
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.getType(name) == "modem" then
    pcall(peripheral.call, name, "open", os.getComputerID() % 65500 + 1)
    local ok = pcall(rednet.open, name)
    if ok then modemOk = true end
  end
end
if not modemOk then
  error("No wireless modem — attach one for jukebox_viz", 0)
end

------------------------------------------------------------------ helpers
local function now()
  return os.epoch("utc") / 1000
end

-- Precomputed color ramps (avoid per-pixel palette work)
-- Cool → hot spectrum; secondary ramp for energy-shifted accents
local BAR_COLS = {
  colors.blue, colors.cyan, colors.lightBlue, colors.white,
  colors.yellow, colors.orange, colors.red, colors.magenta,
}
local BAR_COLS_HOT = {
  colors.purple, colors.magenta, colors.pink, colors.white,
  colors.yellow, colors.orange, colors.red, colors.red,
}
local BAR_GLOW = {
  colors.gray, colors.blue, colors.cyan, colors.lightBlue,
  colors.yellow, colors.orange, colors.red, colors.pink,
}
local PART_COLS = {
  colors.cyan, colors.lightBlue, colors.white, colors.yellow,
  colors.pink, colors.magenta, colors.orange,
}
local WAVE_COLS = { colors.lime, colors.green, colors.cyan, colors.lightBlue, colors.white }
local BLOOM_COLS = { colors.magenta, colors.purple, colors.pink, colors.red, colors.orange }
local STAGE_COLS = { colors.blue, colors.purple, colors.magenta, colors.cyan, colors.orange }
local BORDER_HIT = colors.orange
local BORDER_IDLE = colors.gray
local BORDER_PLAY = colors.lightGray
local BG = colors.black
local FG_DIM = colors.gray
local FG_TITLE = colors.white

-- Tasteful (non-rainbow) palettes for now-playing title FX
local TITLE_BREATHE_COLS = {
  colors.lightBlue, colors.cyan, colors.white, colors.pink, colors.magenta,
}
local TITLE_PULSE_DIM = { colors.lightGray, colors.gray, colors.lightBlue }
local TITLE_PULSE_HOT = { colors.white, colors.yellow, colors.orange }
local TITLE_BASS_BASE = colors.lightBlue
local TITLE_BASS_FLASH = { colors.orange, colors.magenta, colors.yellow, colors.pink }
local TITLE_COOL = { colors.blue, colors.cyan, colors.lightBlue, colors.white }
local TITLE_WARM = { colors.yellow, colors.orange, colors.red, colors.pink }

local TITLE_FX = {
  mode = CONFIG.titleFx,
  bassFlash = 0,   -- decay after kick
  accentIdx = 1,   -- bass-flash sticky accent
}

local function cycleTitleFx()
  local cur = TITLE_FX.mode
  local idx = 1
  for i = 1, #TITLE_FX_MODES do
    if TITLE_FX_MODES[i] == cur then idx = i break end
  end
  idx = (idx % #TITLE_FX_MODES) + 1
  TITLE_FX.mode = TITLE_FX_MODES[idx]
  CONFIG.titleFx = TITLE_FX.mode
  return TITLE_FX.mode
end

-- Top-line marquee (title + artist when available)
local MARQUEE = {
  key = "",
  full = "",
  offset = 0,
  phase = "pause_start", -- pause_start | scroll | pause_end
  phaseUntil = 0,
  lastStep = 0,
}
local MARQUEE_STEP = 0.12   -- seconds between horizontal steps
local MARQUEE_PAUSE = 0.85  -- pause at start and end before moving / reset

local function clamp01(x)
  if x < 0 then return 0 elseif x > 1 then return 1 end
  return x
end

local function rampPick(ramp, t)
  local n = #ramp
  local i = math.floor(clamp01(t) * (n - 1)) + 1
  if i < 1 then i = 1 elseif i > n then i = n end
  return ramp[i]
end

local function barColor(t, hot)
  return rampPick(hot and BAR_COLS_HOT or BAR_COLS, t)
end

local function barGlowColor(t)
  return rampPick(BAR_GLOW, t)
end

local function cycleCol(ramp, phase)
  local n = #ramp
  local i = math.floor(phase % n) + 1
  return ramp[i]
end

-- Aurora-style accent tiers: dim (<0.33) / mid (<0.66) / light
local function accentBase()
  return ACCENT_MAP[VIZ_ACCENT] or colors.purple
end

local function accentDim()
  return ACCENT_DIM_MAP[VIZ_ACCENT] or colors.magenta
end

local function accentLight()
  return ACCENT_LIGHT_MAP[VIZ_ACCENT] or colors.pink
end

local function accentTier(level)
  if level > 0.66 then return accentLight() end
  if level > 0.33 then return accentBase() end
  return accentDim()
end

------------------------------------------------------------------ layout / budgets from size
local displayBands, maxParticles, waveDrawN
local barBottom, barTop, barMaxH, waveY, titleY

local function relayout()
  W, H = mon.getSize()
  displayBands = math.max(12, math.min(CONFIG.maxBars, math.floor(W * 0.24)))
  maxParticles = math.max(8, math.min(CONFIG.maxParticles, math.floor(W * H / 450)))
  waveDrawN = math.max(24, math.min(CONFIG.wavePoints, W - 4))
  barBottom = H - 2
  barTop = math.floor(H * 0.18)
  barMaxH = math.max(4, barBottom - barTop)
  waveY = math.floor(H * 0.52)
  titleY = 1
end

relayout()

------------------------------------------------------------------ state from rednet (targets) + smoothed display
local RX = {
  play = false,
  paused = false,
  stop = true,
  title = "",
  artist = "",
  album = "",
  pos = 0,
  dur = 0,
  e = 0,
  peak = 0,
  bands = {},
  wave = {},
  lyricsOn = false,
  lyric = "",
  ts = 0,
  got = false,
}

local DISP = {
  e = 0,
  peak = 0,
  bass = 0,
  bands = {},
  peaks = {},
  wave = {},
  hit = 0,
  breath = 0,
  hue = 0,       -- energy / bass driven color-cycle phase
  stage = 0,     -- stage-light sweep phase
}

do
  for i = 1, 16 do RX.bands[i] = 0 end
  for i = 1, 32 do RX.wave[i] = 0 end
  for i = 1, displayBands do
    DISP.bands[i] = 0
    DISP.peaks[i] = 0
  end
  for i = 1, waveDrawN do DISP.wave[i] = 0 end
end

-- Uniform title color for this frame (no per-char rainbow).
local function titleFxColor(playing)
  if not playing then return FG_DIM end
  local mode = TITLE_FX.mode
  local e = DISP.e
  local bass = DISP.bass
  local breath = 0.5 + 0.5 * math.sin(DISP.breath)

  if mode == "pulse" then
    local lvl = clamp01(0.25 + e * 0.55 + bass * 0.45)
    if lvl < 0.4 then
      return rampPick(TITLE_PULSE_DIM, lvl / 0.4)
    end
    return rampPick(TITLE_PULSE_HOT, (lvl - 0.4) / 0.6)

  elseif mode == "bass" then
    if TITLE_FX.bassFlash > 0.35 then
      return TITLE_BASS_FLASH[((TITLE_FX.accentIdx - 1) % #TITLE_BASS_FLASH) + 1]
    elseif TITLE_FX.bassFlash > 0.12 then
      return rampPick(
        { TITLE_BASS_BASE, TITLE_BASS_FLASH[((TITLE_FX.accentIdx - 1) % #TITLE_BASS_FLASH) + 1] },
        TITLE_FX.bassFlash
      )
    end
    local soft = 0.55 + 0.45 * breath
    return (soft > 0.7) and colors.white or TITLE_BASS_BASE

  elseif mode == "warmcool" then
    local t = clamp01(e * 0.7 + bass * 0.45)
    if t < 0.45 then
      return rampPick(TITLE_COOL, t / 0.45)
    end
    return rampPick(TITLE_WARM, (t - 0.45) / 0.55)

  else
    -- breathe (default): gentle palette shift + soft brightness breathe
    local n = #TITLE_BREATHE_COLS
    local phase = (DISP.breath * 0.35 + e * 0.4) % n
    local i0 = math.floor(phase) % n
    local frac = phase - math.floor(phase)
    -- pick nearer palette stop; dim toward gray on the soft half of the breath
    local col = TITLE_BREATHE_COLS[i0 + 1]
    if frac > 0.55 then
      col = TITLE_BREATHE_COLS[(i0 + 1) % n + 1]
    end
    if breath < 0.35 and e < 0.35 then
      return colors.lightGray
    elseif breath < 0.55 and e < 0.5 then
      return (col == colors.white) and colors.lightBlue or col
    end
    return col
  end
end

local function setLyricsMode(on)
  on = on and true or false
  if on == lyricsModeActive then return end
  lyricsModeActive = on
  pcall(mon.setTextScale, on and CONFIG.lyricsScale or CONFIG.monitorScale)
  relayout()
  if not on then
    for i = 1, displayBands do
      DISP.bands[i] = DISP.bands[i] or 0
      DISP.peaks[i] = DISP.peaks[i] or 0
    end
    for i = 1, waveDrawN do
      DISP.wave[i] = DISP.wave[i] or 0
    end
  end
end

local particles = {}

------------------------------------------------------------------ packet ingest
local function levelOf(v)
  -- accepts 0..1 float or 0..100 int from leaner broadcaster
  if type(v) ~= "number" then return 0 end
  if v > 1.5 then return math.min(1, v / 100) end
  if v < -1.5 then return math.max(-1, v / 100) end
  return v
end

local function applyPacket(m)
  if type(m) ~= "table" or m.v ~= 1 then return end
  RX.play = m.play and true or false
  RX.paused = m.paused and true or false
  RX.stop = m.stop and true or false
  if type(m.title) == "string" and m.title ~= "" then RX.title = m.title end
  if type(m.artist) == "string" then RX.artist = m.artist end
  if type(m.album) == "string" then RX.album = m.album end
  if type(m.pos) == "number" then RX.pos = m.pos end
  if type(m.dur) == "number" then RX.dur = m.dur end
  if m.lyricsOn ~= nil then RX.lyricsOn = m.lyricsOn and true or false end
  if m.vizMode then VIZ_MODE = tostring(m.vizMode):lower() end
  if m.anim ~= nil then VIZ_ANIM = not not m.anim end
  if type(m.accent) == "string" and ACCENT_MAP[m.accent] then
    VIZ_ACCENT = m.accent
  end
  if type(m.lyric) == "string" then RX.lyric = m.lyric end
  RX.e = levelOf(m.e)
  RX.peak = levelOf(m.peak)
  if type(m.b) == "table" then
    for i = 1, 16 do
      RX.bands[i] = levelOf(m.b[i] or 0)
    end
  end
  if type(m.w) == "table" and #m.w > 0 then
    local nw = #m.w
    if #RX.wave ~= nw then
      RX.wave = {}
      for i = 1, nw do RX.wave[i] = 0 end
    end
    for i = 1, nw do
      RX.wave[i] = levelOf(m.w[i] or 0)
    end
  end
  RX.ts = now()
  RX.got = true
end

-- Build the full now-playing string (prefer artist when known).
local function nowPlayingFull(prefix)
  local title = RX.title ~= "" and RX.title or nil
  local artist = (type(RX.artist) == "string" and RX.artist ~= "") and RX.artist or nil
  local body
  if title and artist then
    body = artist .. " - " .. title
  elseif title then
    body = title
  else
    body = nil
  end
  if prefix and prefix ~= "" then
    if body then return prefix .. body end
    return prefix:gsub("%s+$", "")
  end
  return body or ""
end

-- Slice a scrolling window; resets when track key changes; pauses at ends.
local function marqueeSlice(full, key, width, t)
  if type(full) ~= "string" then full = "" end
  if type(key) ~= "string" then key = full end
  if width < 1 then return "" end
  if key ~= MARQUEE.key or full ~= MARQUEE.full then
    MARQUEE.key = key
    MARQUEE.full = full
    MARQUEE.offset = 0
    MARQUEE.phase = "pause_start"
    MARQUEE.phaseUntil = t + MARQUEE_PAUSE
    MARQUEE.lastStep = t
  end
  if #full <= width then
    return full
  end
  local maxOff = #full - width
  if MARQUEE.phase == "pause_start" then
    if t >= MARQUEE.phaseUntil then
      MARQUEE.phase = "scroll"
      MARQUEE.lastStep = t
    end
  elseif MARQUEE.phase == "scroll" then
    if t - MARQUEE.lastStep >= MARQUEE_STEP then
      MARQUEE.lastStep = t
      if MARQUEE.offset >= maxOff then
        MARQUEE.offset = maxOff
        MARQUEE.phase = "pause_end"
        MARQUEE.phaseUntil = t + MARQUEE_PAUSE
      else
        MARQUEE.offset = MARQUEE.offset + 1
      end
    end
  elseif MARQUEE.phase == "pause_end" then
    if t >= MARQUEE.phaseUntil then
      MARQUEE.offset = 0
      MARQUEE.phase = "pause_start"
      MARQUEE.phaseUntil = t + MARQUEE_PAUSE
    end
  end
  if MARQUEE.offset > maxOff then MARQUEE.offset = maxOff end
  if MARQUEE.offset < 0 then MARQUEE.offset = 0 end
  return full:sub(MARQUEE.offset + 1, MARQUEE.offset + width)
end

-- Word-wrap lyric text into lines that fit the monitor width.
local function wrapText(s, width)
  local out = {}
  if type(s) ~= "string" or s == "" or width < 4 then return out end
  local words = {}
  for w in s:gmatch("%S+") do words[#words + 1] = w end
  if #words == 0 then return out end
  local line = words[1]
  for i = 2, #words do
    local trial = line .. " " .. words[i]
    if #trial <= width then
      line = trial
    else
      out[#out + 1] = line
      line = words[i]
    end
  end
  out[#out + 1] = line
  return out
end

local function srcBand(i)
  local t = (i - 0.5) / displayBands
  local idx = t * 16 + 0.5
  local a = math.floor(idx)
  local b = a + 1
  if a < 1 then a = 1 end
  if b > 16 then b = 16 end
  local f = idx - a
  return RX.bands[a] * (1 - f) + RX.bands[b] * f
end

local function srcWave(i)
  local nw = #RX.wave
  if nw < 1 then return 0 end
  local t = (i - 0.5) / waveDrawN
  local idx = t * nw + 0.5
  local a = math.floor(idx)
  local b = math.min(nw, a + 1)
  if a < 1 then a = 1 end
  local f = idx - a
  return RX.wave[a] * (1 - f) + RX.wave[b] * f
end

------------------------------------------------------------------ particles
local function spawnParticle(energy, mode)
  if #particles >= maxParticles then return end
  if energy < 0.14 and math.random() > energy * 2.2 then return end
  local x
  if mode == "lyrics" then
    -- keep away from center text column a bit
    if math.random() < 0.5 then
      x = math.random(1, math.max(1, math.floor(W * 0.22)))
    else
      x = math.random(math.max(1, math.floor(W * 0.78)), W)
    end
  else
    x = math.random(2, W - 1)
  end
  if MIRROR then x = W - x + 1 end
  local col = PART_COLS[math.random(1, #PART_COLS)]
  -- bias particle color toward energy / hue
  if energy > 0.55 and math.random() < 0.45 then
    col = cycleCol(PART_COLS, DISP.hue + energy * 3)
  end
  particles[#particles + 1] = {
    x = x,
    y = (mode == "lyrics")
      and (H - 1 - math.random(0, math.max(1, math.floor(H * 0.35 * energy))))
      or (barBottom - math.random(0, math.floor(barMaxH * energy))),
    vy = -(0.3 + energy * 0.95 + math.random() * 0.3),
    life = 0.4 + energy * 0.65 + (mode == "lyrics" and 0.15 or 0),
    col = col,
    mode = mode,
  }
end

local function updateParticles(dt, energy, playing, mode)
  local out, n = {}, 0
  for i = 1, #particles do
    local p = particles[i]
    p.life = p.life - dt
    p.y = p.y + p.vy * (dt * 28)
    p.vy = p.vy - dt * 0.15
    -- slight horizontal drift tied to breath / energy
    p.x = p.x + math.sin(DISP.breath * 2 + p.y * 0.15) * dt * (1.2 + energy)
    if p.life > 0 and p.y > 1 and p.x >= 1 and p.x <= W then
      n = n + 1
      out[n] = p
    end
  end
  particles = out
  if playing then
    local want
    if mode == "lyrics" then
      want = (energy > 0.5 and 2) or (energy > 0.25 and 1) or ((math.random() < 0.2) and 1 or 0)
    else
      want = (energy > 0.6 and 3) or (energy > 0.4 and 2) or (energy > 0.22 and 1) or 0
    end
    for _ = 1, want do spawnParticle(energy, mode) end
  end
end

local function drawParticles(yMin, yMax)
  for i = 1, #particles do
    local p = particles[i]
    local x = math.floor(p.x + 0.5)
    local y = math.floor(p.y + 0.5)
    if x >= 1 and x <= W and y >= yMin and y <= yMax then
      mon.setBackgroundColor(BG)
      mon.setTextColor(p.col)
      mon.setCursorPos(x, y)
      if p.life > 0.5 then
        mon.write("*")
      elseif p.life > 0.25 then
        mon.write("+")
      else
        mon.write(".")
      end
    end
  end
end

------------------------------------------------------------------ soft stage lights / corner flourishes
local function drawStageLights(playing, intensity)
  if intensity < 0.08 and not playing then return end
  local sweep = DISP.stage
  local n = #STAGE_COLS
  -- four corners + short edge rays
  local corners = {
    { 1, 2 }, { W, 2 }, { 1, H - 1 }, { W, H - 1 },
  }
  for ci = 1, 4 do
    local c = corners[ci]
    local phase = sweep + ci * 0.7 + DISP.bass * 2
    local col = STAGE_COLS[(math.floor(phase) % n) + 1]
    local bright = playing and (0.35 + intensity * 0.65 + 0.15 * math.sin(DISP.breath * 3 + ci)) or 0.2
    if bright > 0.35 then
      mon.setBackgroundColor(col)
    else
      mon.setBackgroundColor(colors.gray)
    end
    mon.setCursorPos(c[1], c[2])
    mon.write(" ")
  end
  -- short top/bottom accent ticks that chase with bass
  if playing and intensity > 0.2 then
    local tickN = math.min(6, math.floor(2 + intensity * 5))
    for i = 1, tickN do
      local t = (i - 1) / tickN
      local x = math.floor(2 + t * (W - 3) + math.sin(sweep + i) * 1.5) % (W - 2) + 2
      if MIRROR then x = W - x + 1 end
      mon.setBackgroundColor(cycleCol(STAGE_COLS, sweep + i + DISP.hue))
      mon.setCursorPos(x, 2)
      mon.write(" ")
      if intensity > 0.45 then
        mon.setCursorPos(x, H - 1)
        mon.write(" ")
      end
    end
  end
end

------------------------------------------------------------------ chrome frame
local function drawChrome(playing, borderCol)
  mon.setBackgroundColor(borderCol)
  -- corners always
  mon.setCursorPos(1, 1); mon.write(" ")
  mon.setCursorPos(W, 1); mon.write(" ")
  mon.setCursorPos(1, H); mon.write(" ")
  mon.setCursorPos(W, H); mon.write(" ")
  -- top/bottom edge ticks (sparse — not a full fill every frame unless hit)
  if DISP.hit > 0.2 or (playing and DISP.e > 0.4) then
    local step = (DISP.hit > 0.45) and 1 or 2
    for x = 2, W - 1, step do
      mon.setCursorPos(x, H)
      mon.write(" ")
    end
  end
  -- side rails (every other row) for subtle frame
  if playing then
    mon.setBackgroundColor((DISP.bass > 0.45) and cycleCol(STAGE_COLS, DISP.hue) or BORDER_PLAY)
    for y = 3, H - 2, 2 do
      mon.setCursorPos(1, y); mon.write(" ")
      mon.setCursorPos(W, y); mon.write(" ")
    end
  end
end

------------------------------------------------------------------ lyrics mode (big text preserved)
-- Only drawn when lyricsOn AND a real lyric line is present.
-- Empty lyric → caller keeps fancy viz (no waiting chrome / blank screen).
local function drawLyricsMode()
  setLyricsMode(true)
  mon.setBackgroundColor(BG)
  mon.setTextColor(FG_DIM)
  mon.clear()

  local text = RX.lyric
  local playing = RX.play and not RX.paused and not RX.stop
  local t = now()

  -- subtle energy backdrop BEFORE lyric glyphs (behind text)
  local pulse = 0.5 + 0.5 * math.sin(DISP.breath * (playing and 2.4 or 0.8))
  local backIntensity = playing and (0.15 + DISP.e * 0.55 + DISP.hit * 0.25) or (0.05 + pulse * 0.08)

  -- soft center pulse ring (few cells, dim — does not shrink lyric scale)
  if backIntensity > 0.12 then
    local cx, cy = math.floor(W / 2), math.floor(H / 2)
    local r = math.max(1, math.floor(1 + backIntensity * 2.5))
    local bloomCol = cycleCol(BLOOM_COLS, DISP.hue)
    mon.setBackgroundColor(BG)
    mon.setTextColor(playing and bloomCol or colors.gray)
    for dy = -r, r do
      for dx = -r, r do
        local d2 = dx * dx + dy * dy
        if d2 <= r * r and d2 >= (r - 1) * (r - 1) then
          local x, y = cx + dx, cy + dy
          if x >= 1 and x <= W and y >= 2 and y <= H then
            mon.setCursorPos(x, y)
            mon.write(".")
          end
        end
      end
    end
  end

  -- corner stage flourishes (very light)
  if playing and DISP.e > 0.2 then
    drawStageLights(true, DISP.e * 0.55)
  end

  drawParticles(2, H)

  -- Compact header at big scale — marquee when artist/title doesn't fit
  local full = nowPlayingFull("")
  if full == "" then full = "lyrics" end
  local key = (RX.artist or "") .. "\0" .. (RX.title or "")
  local header = marqueeSlice(full, key, W, t)
  local hx = (#full <= W) and math.max(1, math.floor((W - #header) / 2) + 1) or 1
  mon.setBackgroundColor(BG)
  mon.setCursorPos(hx, 1)
  mon.setTextColor(titleFxColor(playing))
  mon.write(header)

  local maxW = math.max(4, W)
  local lines = wrapText(text, maxW)
  local maxLines = math.max(1, H - 2)
  if #lines > maxLines then
    local trimmed = {}
    for i = #lines - maxLines + 1, #lines do
      trimmed[#trimmed + 1] = lines[i]
    end
    lines = trimmed
  end
  local y0 = math.max(2, math.floor((H - #lines) / 2) + 1)
  -- slight energy tint on lyric text color (still big centered glyphs)
  if playing and DISP.e > 0.55 then
    mon.setTextColor(cycleCol({ colors.white, colors.yellow, colors.white, colors.pink }, DISP.hue))
  else
    mon.setTextColor(colors.white)
  end
  mon.setBackgroundColor(BG)
  for i = 1, #lines do
    local ln = lines[i]
    if #ln > W then ln = ln:sub(1, W) end
    local x = math.max(1, math.floor((W - #ln) / 2) + 1)
    mon.setCursorPos(x, y0 + i - 1)
    mon.write(ln)
  end
end

------------------------------------------------------------------ smooth step (runs every frame)
local function smooth(dt)
  local playing = RX.play and not RX.paused and not RX.stop
  local attack = 1 - math.exp(-dt * 18)
  local release = 1 - math.exp(-dt * 7)

  local te = playing and RX.e or 0
  if te >= DISP.e then
    DISP.e = DISP.e + (te - DISP.e) * attack
  else
    DISP.e = DISP.e + (te - DISP.e) * release
  end
  local tp = playing and RX.peak or 0
  DISP.peak = DISP.peak + (tp - DISP.peak) * (1 - math.exp(-dt * 4))

  -- bass from lowest few bands
  local bassTarget = 0
  if playing then
    bassTarget = (RX.bands[1] + RX.bands[2] + RX.bands[3]) / 3
  end
  if bassTarget >= DISP.bass then
    DISP.bass = DISP.bass + (bassTarget - DISP.bass) * attack
  else
    DISP.bass = DISP.bass + (bassTarget - DISP.bass) * release
  end

  for i = 1, displayBands do
    local target = playing and srcBand(i) or 0
    local cur = DISP.bands[i]
    local a = (target >= cur) and attack or release
    cur = cur + (target - cur) * a
    DISP.bands[i] = cur
    local pk = DISP.peaks[i]
    if cur > pk then
      DISP.peaks[i] = cur
    else
      DISP.peaks[i] = pk * (1 - dt * 1.45)
    end
  end

  for i = 1, waveDrawN do
    local target = playing and srcWave(i) or 0
    local cur = DISP.wave[i]
    DISP.wave[i] = cur + (target - cur) * attack
  end

  if playing and RX.e > DISP.hit + 0.12 and RX.e > 0.42 then
    DISP.hit = math.min(1, RX.e + 0.2)
  else
    DISP.hit = DISP.hit * (1 - dt * 3.5)
  end

  -- Bass-flash title FX: sticky accent on kick / low-end hits
  if playing and (DISP.hit > 0.55 or (bassTarget > 0.62 and bassTarget > DISP.bass - 0.02)) then
    if TITLE_FX.bassFlash < 0.25 then
      TITLE_FX.accentIdx = TITLE_FX.accentIdx + 1
    end
    TITLE_FX.bassFlash = math.min(1, math.max(TITLE_FX.bassFlash, DISP.hit, bassTarget))
  else
    TITLE_FX.bassFlash = TITLE_FX.bassFlash * (1 - dt * 4.2)
  end

  DISP.breath = (DISP.breath + dt * (playing and 2.2 or 0.7)) % (math.pi * 2)
  -- color cycle speeds up with bass / energy
  local hueSpeed = playing and (0.55 + DISP.e * 1.8 + DISP.bass * 2.2) or 0.15
  DISP.hue = DISP.hue + dt * hueSpeed
  DISP.stage = DISP.stage + dt * (playing and (1.1 + DISP.bass * 2.5) or 0.25)

  -- Lyrics big-text mode only when a line is present; empty lyric keeps viz particles.
  local hasLyric = RX.lyricsOn and type(RX.lyric) == "string" and RX.lyric ~= ""
  local mode = hasLyric and "lyrics" or "viz"
  -- Respect jukebox animations flag (Aurora App.cfg.animations / packet anim)
  updateParticles(dt, DISP.e, playing and VIZ_ANIM, mode)
end

------------------------------------------------------------------ draw
-- One clear() per frame + sparse writes (bars / wave / few particles).
local function draw()
  -- lyricsOn + real line → big karaoke; lyricsOn + empty → fancy viz (no waiting chrome)
  local hasLyric = RX.lyricsOn and type(RX.lyric) == "string" and RX.lyric ~= ""
  if hasLyric then
    drawLyricsMode()
    return
  end

  setLyricsMode(false)
  mon.setBackgroundColor(BG)
  mon.setTextColor(FG_DIM)
  mon.clear()

  local playing = RX.play and not RX.paused and not RX.stop
  local idle = RX.stop or (not RX.got)
  local paused = RX.paused and not RX.stop
  local hot = (DISP.e > 0.55) or (DISP.bass > 0.5)

  local tNow = now()
  local titleW = math.max(1, W - 2)
  local prefix, body, trackKey
  if idle then
    prefix, body, trackKey = "", "jukebox - waiting", "idle"
  elseif paused then
    local np = nowPlayingFull("")
    prefix, body = "||  ", (np ~= "" and np or "paused")
    trackKey = (RX.artist or "") .. "\0" .. (RX.title or "")
  else
    local np = nowPlayingFull("")
    prefix, body = ">  ", (np ~= "" and np or "playing")
    trackKey = (RX.artist or "") .. "\0" .. (RX.title or "")
  end
  -- Fixed prefix; only the title/artist body marquees (play↔pause won't reset scroll)
  local bodyW = math.max(1, titleW - #prefix)
  local shown = prefix .. marqueeSlice(body, trackKey, bodyW, tNow)
  mon.setCursorPos(2, titleY)
  mon.setBackgroundColor(BG)
  mon.setTextColor(titleFxColor(playing))
  mon.write(shown)

  -- border / chrome
  local borderCol = BORDER_IDLE
  if DISP.hit > 0.15 then
    borderCol = BORDER_HIT
  elseif playing and DISP.e > 0.35 then
    borderCol = cycleCol(STAGE_COLS, DISP.hue)
  elseif playing then
    borderCol = BORDER_PLAY
  end
  if DISP.hit > 0.05 or playing then
    drawChrome(playing, borderCol)
  end

  -- stage lights (corners + chase ticks) — skip when jukebox animations off
  if VIZ_MODE ~= "off" and VIZ_ANIM then
    drawStageLights(playing, DISP.e)
  end

  -- center bloom (few cells, on hits / energy)
  if VIZ_MODE ~= "off" and VIZ_ANIM and playing and DISP.e > 0.22 then
    local cx, cy = math.floor(W / 2), math.floor(H / 2)
    local r = math.floor(1 + DISP.e * 3.2 + DISP.hit * 2.4 + DISP.bass * 1.2)
    local bloomCol = cycleCol(BLOOM_COLS, DISP.hue + DISP.bass)
    mon.setBackgroundColor(bloomCol)
    mon.setTextColor(colors.white)
    for dy = -r, r do
      for dx = -r, r do
        local d2 = dx * dx + dy * dy
        if d2 <= r * r then
          local x, y = cx + dx, cy + dy
          if x >= 2 and x <= W - 1 and y >= 3 and y <= H - 2 then
            mon.setCursorPos(x, y)
            if d2 <= 1 and DISP.hit > 0.35 then
              mon.write("@")
            elseif DISP.hit > 0.4 then
              mon.write("O")
            else
              mon.write(".")
            end
          end
        end
      end
    end
    -- soft outer halo ring (dimmer color)
    if r >= 2 then
      mon.setBackgroundColor(BG)
      mon.setTextColor(bloomCol)
      local r2 = r + 1
      for dy = -r2, r2 do
        for dx = -r2, r2 do
          local d2 = dx * dx + dy * dy
          if d2 > r * r and d2 <= r2 * r2 then
            local x, y = cx + dx, cy + dy
            if x >= 2 and x <= W - 1 and y >= 3 and y <= H - 2 then
              mon.setCursorPos(x, y)
              mon.write(".")
            end
          end
        end
      end
    end
  elseif idle or paused then
    local cx, cy = math.floor(W / 2), math.floor(H / 2)
    local pulse = 0.5 + 0.5 * math.sin(DISP.breath)
    local r = pulse > 0.55 and 2 or 1
    mon.setBackgroundColor(BG)
    mon.setTextColor(colors.gray)
    for dy = -r, r do
      for dx = -r, r do
        if dx * dx + dy * dy <= r * r then
          local x, y = cx + dx, cy + dy
          if x >= 1 and x <= W and y >= 2 and y <= H - 1 then
            mon.setCursorPos(x, y)
            mon.write(".")
          end
        end
      end
    end
  end

  -- MODE GATES: bars / wave / vu / off from jukebox APPEARANCE (VIZ_MODE set on packet)
  -- Aurora Screens.visualizer patterns scaled for 4×4 + peak/glow polish.

  ------------------------------------------------------------------ BARS
  -- Accent-tier spectrum (dim/mid/light) + peak caps + soft tip glow.
  if VIZ_MODE == "bars" then
    -- Aurora uses ~2-wide bars with 1-col gap; clamp density to monitor width.
    local gap = 1
    local preferW = 2
    local n = math.min(displayBands, math.max(8, math.floor((W - 4) / (preferW + gap))))
    local barW = preferW
    local used = n * barW + (n - 1) * gap
    if used > W - 4 then
      barW = 1
      used = n * barW + (n - 1) * gap
    end
    local x0 = math.floor((W - used) / 2) + 1
    local breathAmp = (idle or paused) and (0.08 + 0.06 * math.sin(DISP.breath)) or 0

    for i = 1, n do
      local bi = MIRROR and (n - i + 1) or i
      -- map display band into DISP.bands
      local src = math.floor((bi - 0.5) * displayBands / n) + 1
      if src < 1 then src = 1 elseif src > displayBands then src = displayBands end
      local level = DISP.bands[src] or 0
      if breathAmp > 0 then
        level = breathAmp * (0.5 + 0.5 * math.sin(DISP.breath + i * 0.35))
      end
      local h = math.floor(level * barMaxH + 0.5)
      if h < 0 then h = 0 elseif h > barMaxH then h = barMaxH end
      local x = x0 + (i - 1) * (barW + gap)
      local col = accentTier(level)
      -- soft energy blend toward spectrum ramp on very hot hits
      if hot and level > 0.75 then
        col = barColor(clamp01(level), true)
      end
      for dy = 0, h - 1 do
        if h > 4 and dy >= h - 2 then
          mon.setBackgroundColor(accentLight())
        elseif h > 6 and dy <= 1 then
          mon.setBackgroundColor(accentDim())
        else
          mon.setBackgroundColor(col)
        end
        mon.setCursorPos(x, barBottom - dy)
        mon.write((" "):rep(barW))
      end
      if playing and h >= 2 and h < barMaxH then
        mon.setBackgroundColor(BG)
        mon.setTextColor(accentLight())
        mon.setCursorPos(x, barBottom - h)
        mon.write(("^"):rep(barW))
      end
      local pk = DISP.peaks[src] or 0
      local ph = math.floor(pk * barMaxH + 0.5)
      if ph > h and ph >= 1 and playing then
        mon.setBackgroundColor(colors.white)
        mon.setCursorPos(x, barBottom - ph)
        mon.write((" "):rep(barW))
        if ph - 1 > h and ph - 1 >= 1 then
          mon.setBackgroundColor(BG)
          mon.setTextColor(accentBase())
          mon.setCursorPos(x, barBottom - (ph - 1))
          mon.write(("-"):rep(barW))
        end
      end
    end
  end -- bars

  ------------------------------------------------------------------ WAVE
  -- Aurora: mid-centered filled columns from PCM wave peaks (not outline tildes).
  if VIZ_MODE == "wave" then
    if playing or paused or idle then
      local amp = math.floor(barMaxH * (0.42 + DISP.e * 0.18))
      if amp < 3 then amp = 3 end
      if idle or paused then
        amp = math.max(2, math.floor(amp * 0.35 + 1.5 * math.sin(DISP.breath)))
      end
      local mid = waveY
      local n = math.min(waveDrawN, W - 4)
      for i = 1, n do
        local s = DISP.wave[i] or 0
        if idle or paused then
          s = 0.12 + 0.1 * math.sin(DISP.breath + i * 0.22)
        end
        local hh = math.max(1, math.floor(math.abs(s) * amp + 0.5))
        local x = math.floor((i - 0.5) / n * (W - 4)) + 2
        if MIRROR then x = W - x + 1 end
        local col = (i % 3 == 0) and accentLight() or accentBase()
        if math.abs(s) > 0.7 then col = accentLight() end
        local y0 = mid - hh + 1
        local hFill = hh * 2 - 1
        if y0 < 3 then
          hFill = hFill - (3 - y0)
          y0 = 3
        end
        if y0 + hFill - 1 > H - 2 then
          hFill = (H - 2) - y0 + 1
        end
        if hFill > 0 then
          mon.setBackgroundColor(col)
          for dy = 0, hFill - 1 do
            mon.setCursorPos(x, y0 + dy)
            mon.write(" ")
          end
        end
        -- bright crest tick
        if playing and math.abs(s) > 0.55 then
          mon.setBackgroundColor(BG)
          mon.setTextColor(colors.white)
          local cy = mid - hh
          if cy >= 3 and cy <= H - 2 then
            mon.setCursorPos(x, cy)
            mon.write(".")
          end
        end
      end
    end
  end -- wave

  ------------------------------------------------------------------ VU
  -- Aurora dual meters: RMS (e) + Peak, scaled for 4×4 with segment tiers + hold.
  if VIZ_MODE == "vu" then
    local meterTop = math.max(4, math.floor(H * 0.28))
    local meterH = math.max(2, math.floor(H * 0.12))
    local gapY = math.max(2, math.floor(H * 0.08))
    local labelW = 6
    local x1 = 3 + labelW
    local bw = math.max(8, W - x1 - 4)
    local rms = DISP.e
    local peak = DISP.peak
    if idle or paused then
      local pulse = 0.08 + 0.06 * math.sin(DISP.breath)
      rms, peak = pulse, pulse * 1.2
    end
    -- soft hold so peak needle doesn't collapse between packets
    if peak < DISP.peak then peak = DISP.peak end

    local function drawMeter(y, level, label, useLight)
      mon.setBackgroundColor(BG)
      mon.setTextColor(FG_DIM)
      mon.setCursorPos(3, y)
      mon.write(label)
      -- track
      mon.setBackgroundColor(colors.gray)
      for dy = 0, meterH - 1 do
        mon.setCursorPos(x1, y + dy)
        mon.write((" "):rep(bw))
      end
      local fill = math.floor(clamp01(level) * bw + 0.5)
      if fill < 0 then fill = 0 elseif fill > bw then fill = bw end
      -- segmented fill with accent tiers (Aurora progressBar feel)
      for sx = 0, fill - 1 do
        local t = (sx + 0.5) / bw
        local col
        if t > 0.85 then
          col = colors.white
        elseif t > 0.66 then
          col = useLight and accentLight() or accentBase()
        elseif t > 0.33 then
          col = accentBase()
        else
          col = accentDim()
        end
        mon.setBackgroundColor(col)
        for dy = 0, meterH - 1 do
          mon.setCursorPos(x1 + sx, y + dy)
          mon.write(" ")
        end
      end
      -- peak tick
      local px = x1 + math.max(0, math.min(bw - 1, fill))
      mon.setBackgroundColor(colors.white)
      for dy = 0, meterH - 1 do
        mon.setCursorPos(px, y + dy)
        mon.write(" ")
      end
      mon.setBackgroundColor(BG)
      mon.setTextColor(FG_DIM)
      mon.setCursorPos(x1 + bw - 2, y)
      mon.write(label == "RMS" and "VU" or "PK")
    end

    drawMeter(meterTop, rms, "RMS", false)
    drawMeter(meterTop + meterH + gapY, peak, "PEAK", true)

    -- stereo-ish side buds from low/high band halves (PCM band energy)
    local leftE, rightE, ln, rn = 0, 0, 0, 0
    local half = math.floor(displayBands / 2)
    for i = 1, half do
      leftE = leftE + (DISP.bands[i] or 0); ln = ln + 1
    end
    for i = half + 1, displayBands do
      rightE = rightE + (DISP.bands[i] or 0); rn = rn + 1
    end
    leftE = ln > 0 and (leftE / ln) or 0
    rightE = rn > 0 and (rightE / rn) or 0
    local budY = meterTop + meterH * 2 + gapY * 2 + 1
    if budY + 2 <= H - 2 then
      mon.setBackgroundColor(BG)
      mon.setTextColor(FG_DIM)
      mon.setCursorPos(3, budY)
      mon.write("L")
      mon.setCursorPos(3, budY + 2)
      mon.write("R")
      local budW = bw
      local function bud(y, level)
        local f = math.floor(clamp01(level) * budW + 0.5)
        mon.setBackgroundColor(colors.gray)
        mon.setCursorPos(x1, y)
        mon.write((" "):rep(budW))
        mon.setBackgroundColor(accentTier(level))
        if f > 0 then
          mon.setCursorPos(x1, y)
          mon.write((" "):rep(f))
        end
      end
      bud(budY, MIRROR and rightE or leftE)
      bud(budY + 2, MIRROR and leftE or rightE)
    end
  end -- vu

  -- particles
  if VIZ_MODE ~= "off" and VIZ_ANIM then
    drawParticles(2, H - 1)
  end

  -- LIVE PCM badge (Aurora Screens.visualizer) + side label
  mon.setBackgroundColor(BG)
  if playing and VIZ_MODE ~= "off" then
    mon.setTextColor(accentBase())
    local badge = "LIVE PCM"
    mon.setCursorPos(math.max(1, 2), H)
    mon.write(badge)
  elseif paused and VIZ_MODE ~= "off" then
    mon.setTextColor(FG_DIM)
    mon.setCursorPos(2, H)
    mon.write("PAUSED")
  end
  mon.setTextColor(playing and accentLight() or colors.gray)
  mon.setCursorPos(W - 5, H)
  mon.write(SIDE == "right" and " RIGHT" or "  LEFT")
end

------------------------------------------------------------------ loops
local function openModems()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      pcall(rednet.open, name)
    end
  end
end

local function receiveLoop()
  openModems()
  while true do
    local _, m = rednet.receive(CONFIG.proto, 1)
    if type(m) == "table" then applyPacket(m) end
  end
end

local function drawLoop()
  local tPrev = now()
  mon.setBackgroundColor(BG)
  mon.clear()
  while true do
    local t = now()
    local dt = t - tPrev
    if dt < 0 then dt = CONFIG.fps end
    if dt > 0.2 then dt = 0.2 end
    tPrev = t
    smooth(dt)
    draw()
    local spent = now() - t
    local wait = CONFIG.fps - spent
    if wait < 0.005 then wait = 0.005 end
    sleep(wait)
  end
end

local function inputLoop()
  while true do
    local ev, p1 = os.pullEvent()
    if ev == "key" and p1 == keys.q then
      return
    elseif ev == "key" and p1 == keys.t then
      cycleTitleFx()
    elseif ev == "monitor_resize" or ev == "term_resize" then
      relayout()
      for i = 1, displayBands do
        DISP.bands[i] = DISP.bands[i] or 0
        DISP.peaks[i] = DISP.peaks[i] or 0
      end
      for i = 1, waveDrawN do
        DISP.wave[i] = DISP.wave[i] or 0
      end
    elseif ev == "peripheral" or ev == "peripheral_detach" then
      openModems()
    end
  end
end

------------------------------------------------------------------ run
math.randomseed(os.epoch("utc"))
mon.setBackgroundColor(BG)
mon.setTextColor(FG_TITLE)
mon.clear()
mon.setCursorPos(1, 1)
mon.write("viz " .. SIDE .. " · " .. W .. "x" .. H .. " · fx:" .. TITLE_FX.mode)

local ok, err = pcall(parallel.waitForAny, receiveLoop, drawLoop, inputLoop)

mon.setBackgroundColor(BG)
mon.setTextColor(colors.white)
mon.clear()
mon.setCursorPos(1, 1)
if not ok and err ~= "Terminated" then
  printError(err)
else
  print("Visualizer stopped.")
end
