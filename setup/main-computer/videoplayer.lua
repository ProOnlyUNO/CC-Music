--[[----------------------------------------------------------------------------
  videoplayer.lua — standalone CVID1 + DFPWM smoke player (CC:Tweaked)

  Drag-drop Song.cvid + Song.dfpwm onto the computer screen, or:
      videoplayer Song          -- looks for Song.cvid + Song.dfpwm beside cwd
      videoplayer path/to/Song  -- stem without extension

  Plays DFPWM on attached speakers while blit-ing CVID frames to the first
  colour monitor (or the computer terminal with --term).

  For the jukebox music-video handoff (delay → overlay → NEXT/BACK stay),
  use jukebox.lua with Song.cvid beside the library .dfpwm instead.
  ----------------------------------------------------------------------------]]

local args = { ... }
local FORCE_TERM = false
local stemArg = nil
for _, a in ipairs(args) do
  if a == "--term" then FORCE_TERM = true
  elseif not a:match("^%-") then stemArg = a end
end

local function findMonitor()
  if FORCE_TERM then return term, nil end
  local names = peripheral.getNames()
  table.sort(names)
  for _, name in ipairs(names) do
    if peripheral.getType(name) == "monitor" then
      local mon = peripheral.wrap(name)
      if mon and mon.isColour and mon.isColour() then
        pcall(function() mon.setTextScale(0.5) end)
        return mon, name
      end
    end
  end
  return term, nil
end

local function findSpeakers()
  local list = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "speaker" then
      local sp = peripheral.wrap(name)
      if sp and type(sp.playAudio) == "function" then
        list[#list + 1] = sp
      end
    end
  end
  return list
end

local function u16(s, i) return (s:byte(i) or 0) + (s:byte(i + 1) or 0) * 256 end
local function u32(s, i)
  return (s:byte(i) or 0)
    + (s:byte(i + 1) or 0) * 256
    + (s:byte(i + 2) or 0) * 65536
    + (s:byte(i + 3) or 0) * 16777216
end

local function readAll(path)
  local f = fs.open(path, "rb")
  if not f then return nil end
  local data = f.readAll()
  f.close()
  return data
end

local function loadCvid(path)
  local data = readAll(path)
  if not data or #data < 64 then return nil, "Cannot read CVID" end
  if data:sub(1, 5) ~= "CVID1" then return nil, "Not a CVID1 file" end
  if (data:byte(6) or 0) ~= 1 then return nil, "Unsupported CVID version" end
  local w, h = u16(data, 7), u16(data, 9)
  local frames = u32(data, 11)
  local defaultMs = u16(data, 15)
  if w < 1 or h < 1 or frames < 1 then return nil, "Invalid dimensions" end
  local cellBytes = w * h * 2
  local durationAt = 64 + frames * cellBytes + 1
  if #data < durationAt + frames * 2 - 1 then return nil, "Truncated CVID" end
  local palette = {}
  for i = 0, 15 do
    local o = 17 + i * 3
    local r, g, b = data:byte(o) or 0, data:byte(o + 1) or 0, data:byte(o + 2) or 0
    -- Map pack RGB → nearest terminal palette slot.
    local best, bestD = 2 ^ i, math.huge
    if i < 16 then best = 2 ^ i end
    for bit = 0, 15 do
      local ok, pr, pg, pb = pcall(term.getPaletteColour, 2 ^ bit)
      if not ok then
        -- Monitors expose getPaletteColour too; fall back to index order.
        pr, pg, pb = r / 255, g / 255, b / 255
      end
      if type(pr) == "number" then
        local dr = (r / 255 - pr) ^ 2 + (g / 255 - pg) ^ 2 + (b / 255 - pb) ^ 2
        if dr < bestD then bestD, best = dr, 2 ^ bit end
      end
    end
    palette[i] = best
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
  return {
    data = data, w = w, h = h, frames = frames, cellBytes = cellBytes,
    durationAt = durationAt, durations = durations, starts = starts,
    total = total, palette = palette, path = path,
  }
end

local HEX = { [0]="0","1","2","3","4","5","6","7","8","9","a","b","c","d","e","f" }
local function colourToNibble(col)
  for i = 0, 15 do
    if 2 ^ i == col then return HEX[i] end
  end
  return "0"
end

local function frameFor(vid, ms)
  local lo, hi = 1, vid.frames
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if (vid.starts[mid] or 0) <= ms then lo = mid else hi = mid - 1 end
  end
  if lo < 1 then lo = 1 end
  if lo > vid.frames then lo = vid.frames end
  return lo
end

local function blitFrame(termObj, vid, frameIndex)
  local base = 64 + (frameIndex - 1) * vid.cellBytes
  local tw, th = termObj.getSize()
  local data = vid.data
  for cy = 1, math.min(vid.h, th) do
    local chars, fg, bg = {}, {}, {}
    for cx = 1, math.min(vid.w, tw) do
      local o = base + ((cy - 1) * vid.w + (cx - 1)) * 2 + 1
      local mask = (data:byte(o) or 0) % 32
      local colors = data:byte(o + 1) or 0
      local fi = math.floor(colors / 16) % 16
      local bi = colors % 16
      chars[cx] = string.char(128 + mask)
      fg[cx] = colourToNibble(vid.palette[fi] or colours.white)
      bg[cx] = colourToNibble(vid.palette[bi] or colours.black)
    end
    termObj.setCursorPos(1, cy)
    termObj.blit(table.concat(chars), table.concat(fg), table.concat(bg))
  end
end

local function resolvePack(stem)
  if not stem or stem == "" then return nil, nil end
  stem = stem:gsub("%.cvid$", ""):gsub("%.dfpwm$", "")
  local cvid = stem .. ".cvid"
  local dfpwm = stem .. ".dfpwm"
  if fs.exists(cvid) and fs.exists(dfpwm) then return cvid, dfpwm end
  -- Try basename in cwd
  local base = fs.getName(stem)
  cvid, dfpwm = base .. ".cvid", base .. ".dfpwm"
  if fs.exists(cvid) and fs.exists(dfpwm) then return cvid, dfpwm end
  return nil, nil
end

local function waitForDrop()
  print("Drop Song.cvid + Song.dfpwm onto this screen (computer GUI).")
  print("Or pass a stem: videoplayer \"Escape from BABYLON\"")
  print("Q = quit")
  local cvidPath, dfpwmPath
  while true do
    local ev, a = os.pullEvent()
    if ev == "file_transfer" then
      local ok, list = pcall(function() return a.getFiles() end)
      if ok and type(list) == "table" then
        for _, f in ipairs(list) do
          local name = f.getName()
          local lower = name:lower()
          local data = f.readAll()
          if f.close then pcall(f.close) end
          if data and #data > 0 then
            local dest = name
            local h = fs.open(dest, "wb")
            if h then h.write(data); h.close() end
            if lower:match("%.cvid$") then cvidPath = dest end
            if lower:match("%.dfpwm$") then dfpwmPath = dest end
          end
        end
      end
      if cvidPath and dfpwmPath then return cvidPath, dfpwmPath end
      print("Need both .cvid and .dfpwm (got partial drop).")
    elseif ev == "key" and a == keys.q then
      return nil, nil
    end
  end
end

------------------------------------------------------------------ main
local cvidPath, dfpwmPath
if stemArg then
  cvidPath, dfpwmPath = resolvePack(stemArg)
  if not cvidPath then
    print("Could not find " .. tostring(stemArg) .. ".cvid + .dfpwm")
    return
  end
else
  cvidPath, dfpwmPath = waitForDrop()
  if not cvidPath then print("Cancelled."); return end
end

local vid, err = loadCvid(cvidPath)
if not vid then print(err or "load failed"); return end

local okDec, dfpwmMod = pcall(require, "cc.audio.dfpwm")
if not okDec or type(dfpwmMod) ~= "table" then
  print("cc.audio.dfpwm unavailable")
  return
end
local speakers = findSpeakers()
if #speakers == 0 then
  print("No speakers attached — video-only mode.")
end

local termObj = findMonitor()
termObj.setBackgroundColour(colours.black)
termObj.clear()

local decoder = dfpwmMod.make_decoder()
local fh = fs.open(dfpwmPath, "rb")
if not fh then print("Cannot open " .. dfpwmPath); return end

local CHUNK = 2048
local SR = 48000
local startEpoch = os.epoch("utc")
local frame = 1
local eof = false
local pending = nil

local function audioPosMs()
  return os.epoch("utc") - startEpoch
end

local function feedAudio()
  if not fh or eof or #speakers == 0 then return end
  if not pending then
    local chunk = fh.read(CHUNK)
    if not chunk or #chunk == 0 then
      eof = true
      return
    end
    pending = decoder(chunk)
  end
  if pending then
    local any = false
    for _, sp in ipairs(speakers) do
      if sp.playAudio(pending) then any = true end
    end
    if any then pending = nil end
  end
end

local function paint()
  local ms = audioPosMs()
  local f = frameFor(vid, math.min(ms, vid.total))
  if f ~= frame then
    frame = f
    blitFrame(termObj, vid, frame)
  end
end

print(string.format("Playing %s  %dx%d  %d frames  (Q quit)", fs.getName(cvidPath), vid.w, vid.h, vid.frames))
blitFrame(termObj, vid, 1)
local tick = os.startTimer(0.05)
while true do
  feedAudio()
  paint()
  if eof and not pending and audioPosMs() >= vid.total then break end
  local e, p1 = os.pullEventRaw()
  if e == "timer" and p1 == tick then
    tick = os.startTimer(0.05)
  elseif e == "speaker_audio_empty" then
    feedAudio()
  elseif e == "key" and (p1 == keys.q or p1 == keys.escape) then
    break
  elseif e == "terminate" then
    break
  end
end

if fh then fh.close() end
print("Done.")
