--[[
  pocket.lua — Pocket Advanced Computer remote for the DFPWM jukebox
  Protocol: pocket_mp3  (compatible with docs/jukebox.lua)

  Put this on the pocket as startup (or run it manually).
  Requires a wireless modem on the pocket.

  Tap a song in the TRACKLIST to play it immediately.
  SYNC pulls the full library from the main jukebox.
]]

local modemFound = false
peripheral.find("modem", function(name, m)
  if m.isWireless and m.isWireless() then
    rednet.open(name)
    modemFound = true
  end
end)

local proto = "pocket_mp3"
local songs = {}
local idx, scr, play, shf, vol, quit = 1, 0, false, false, 1.0, false
local statusMsg = modemFound and "Tap SYNC to load library" or "NO WIRELESS MODEM!"
local pendingPick = nil  -- index waiting for sync ack

local function fmt(s)
  s = math.max(0, math.floor(s))
  return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

local function pad(str, len)
  if len <= 0 then return "" end
  if #str > len then return str:sub(1, math.max(1, len - 1)) .. "~" end
  return str .. string.rep(" ", len - #str)
end

-- Layout helpers (shared by draw + hit testing)
local function listBounds(h)
  -- rows 7 .. (h-4) inclusive are the tracklist
  local lStart, lEnd = 7, h - 4
  local vis = math.max(1, lEnd - lStart + 1)
  return lStart, lEnd, vis
end

local function draw()
  local w, h = term.getSize()
  local lStart, lEnd, vis = listBounds(h)
  scr = math.max(0, math.min(scr, math.max(0, #songs - vis)))

  term.setBackgroundColor(colors.black)
  term.clear()

  -- Title
  term.setCursorPos(1, 1)
  term.setBackgroundColor(colors.cyan)
  term.setTextColor(colors.black)
  term.clearLine()
  local counter = (#songs > 0 and idx or 0) .. "/" .. #songs
  term.write(" \14 JUKEBOX REMOTE")
  term.setCursorPos(math.max(1, w - #counter), 1)
  term.write(counter)

  -- Now playing (rows 2-4)
  local s = songs[idx]
  for r = 2, 4 do
    term.setCursorPos(1, r)
    term.setBackgroundColor(colors.gray)
    term.clearLine()
  end

  term.setCursorPos(2, 2)
  term.setBackgroundColor(colors.gray)
  term.setTextColor(colors.yellow)
  if s then
    term.write(pad(s.disp or "?", w - 2))
  else
    term.write(pad(statusMsg, w - 2))
  end

  term.setCursorPos(2, 3)
  term.setTextColor(colors.lightGray)
  if s then
    local album = s.album or "Singles"
    local artist = s.artist
    local label = artist and (artist .. " / " .. album) or album
    local durStr = fmt((s.size or 0) / 6000)
    term.write(pad(label .. " (" .. durStr .. ")", w - 2))
  else
    term.write(pad("Ready", w - 2))
  end

  term.setCursorPos(2, 4)
  term.setTextColor(play and colors.lime or colors.orange)
  term.write(play and "\16 PLAY " or "\186 PAUSE")
  term.setTextColor(colors.white)
  term.write(" Vol ")
  local vBars = math.floor((vol / 3.0) * 8 + 0.5)
  term.setTextColor(colors.cyan)
  term.write(string.rep("\127", vBars))
  term.setTextColor(colors.lightGray)
  term.write(string.rep("-", 8 - vBars))
  if pendingPick then
    term.setTextColor(colors.yellow)
    term.write(" …")
  end

  -- Tracklist header + page arrows
  term.setCursorPos(1, 6)
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.cyan)
  term.write(" TRACKLIST  (tap a song)")
  term.setCursorPos(w - 6, 6)
  term.setBackgroundColor(colors.gray)
  term.setTextColor(colors.white)
  term.write(" \30 ")
  term.setBackgroundColor(colors.black)
  term.write(" ")
  term.setBackgroundColor(colors.gray)
  term.write(" \31 ")

  -- Songs
  for i = 1, vis do
    local k = i + scr
    term.setCursorPos(1, lStart + i - 1)
    if songs[k] then
      local isCur = (k == idx)
      term.setBackgroundColor(isCur and colors.cyan or colors.black)
      term.setTextColor(isCur and colors.black or colors.white)
      term.clearLine()
      local prefix = isCur and " \16  " or string.format("%3d ", k)
      term.write(prefix .. pad(songs[k].disp or "?", w - 5))
    else
      term.setBackgroundColor(colors.black)
      term.clearLine()
    end
  end

  -- Divider
  term.setCursorPos(1, h - 3)
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.gray)
  term.write(string.rep("\140", w))

  local function btn(x, y, label, bg, fg)
    term.setCursorPos(x, y)
    term.setBackgroundColor(bg)
    term.setTextColor(fg)
    term.write(label)
  end

  btn(2,  h - 2, " |< ", colors.gray, colors.white)
  btn(7,  h - 2, play and " || " or " \16  ", play and colors.lime or colors.cyan, colors.black)
  btn(12, h - 2, " >| ", colors.gray, colors.white)
  btn(17, h - 2, " SHF ", shf and colors.yellow or colors.gray, shf and colors.black or colors.white)

  btn(2,  h, " VOL- ", colors.gray, colors.white)
  btn(9,  h, " VOL+ ", colors.gray, colors.white)
  btn(16, h, " SYNC ", colors.blue, colors.white)
end

local function send(t)
  if modemFound then rednet.broadcast(t, proto) end
end

local function pickSong(k)
  if not songs[k] then return end
  idx = k
  play = true
  pendingPick = k
  -- Ensure the tapped row stays visible
  local _, _, vis = listBounds(select(2, term.getSize()))
  if idx <= scr then
    scr = math.max(0, idx - 1)
  elseif idx > scr + vis then
    scr = idx - vis
  end
  send({ cmd = "pick", n = k })
  statusMsg = "Playing #" .. k
end

send({ cmd = "sync" })
draw()

while not quit do
  local e, p1, p2, p3 = os.pullEvent()
  local w, h = term.getSize()
  local lStart, lEnd, vis = listBounds(h)

  if e == "mouse_click" then
    local x, y = p2, p3

    if y == 6 then
      -- page up / page down arrows
      if x >= w - 6 and x <= w - 4 then
        scr = math.max(0, scr - vis)
      elseif x >= w - 2 and x <= w then
        scr = math.min(math.max(0, #songs - vis), scr + vis)
      end

    elseif y == h - 2 then
      if x >= 2 and x <= 5 then
        send({ cmd = "prev" })
      elseif x >= 7 and x <= 10 then
        play = not play
        send({ cmd = "toggle" })
      elseif x >= 12 and x <= 15 then
        send({ cmd = "next" })
      elseif x >= 17 and x <= 21 then
        shf = not shf
        send({ cmd = "shf" })
      end

    elseif y == h then
      if x >= 2 and x <= 7 then
        vol = math.max(0.0, math.floor((vol - 0.2) * 10 + 0.5) / 10)
        send({ cmd = "vol", d = -0.2 })
      elseif x >= 9 and x <= 14 then
        vol = math.min(3.0, math.floor((vol + 0.2) * 10 + 0.5) / 10)
        send({ cmd = "vol", d = 0.2 })
      elseif x >= 16 and x <= 21 then
        statusMsg = "Syncing..."
        pendingPick = nil
        send({ cmd = "sync" })
      end

    elseif y >= lStart and y <= lEnd then
      -- Tap a track row → play that song (1-based index into full library)
      local k = (y - lStart + 1) + scr
      if songs[k] then
        pickSong(k)
      end
    end
    draw()

  elseif e == "mouse_scroll" then
    scr = math.max(0, math.min(scr + p1, math.max(0, #songs - vis)))
    draw()

  elseif e == "key" then
    if p1 == keys.space then
      play = not play
      send({ cmd = "toggle" })
    elseif p1 == keys.up then
      if #songs > 0 then
        idx = math.max(1, idx - 1)
        if idx <= scr then scr = math.max(0, idx - 1) end
      else
        scr = math.max(0, scr - 1)
      end
    elseif p1 == keys.down then
      if #songs > 0 then
        idx = math.min(#songs, idx + 1)
        if idx > scr + vis then scr = idx - vis end
      else
        scr = math.min(math.max(0, #songs - vis), scr + 1)
      end
    elseif p1 == keys.enter then
      if songs[idx] then pickSong(idx) end
    elseif p1 == keys.left then
      send({ cmd = "prev" })
    elseif p1 == keys.right then
      send({ cmd = "next" })
    elseif p1 == keys.q then
      quit = true
    end
    draw()

  elseif e == "rednet_message" and p3 == proto and type(p2) == "table" then
    if type(p2.songs) == "table" then
      songs = p2.songs
    end
    if type(p2.idx) == "number" then idx = p2.idx end
    if p2.play ~= nil then play = p2.play and true or false end
    if p2.shf ~= nil then shf = p2.shf and true or false end
    if type(p2.vol) == "number" then vol = p2.vol end
    if pendingPick and type(p2.idx) == "number" then
      -- sync ack after pick
      pendingPick = nil
    end
    if idx <= scr then
      scr = math.max(0, idx - 1)
    elseif idx > scr + vis then
      scr = idx - vis
    end
    if #songs == 0 then
      statusMsg = "Empty library — check disks"
    end
    draw()
  end
end

term.setBackgroundColor(colors.black)
term.clear()
term.setCursorPos(1, 1)
