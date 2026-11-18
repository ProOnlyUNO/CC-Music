--[[
  Importer.lua - drag & drop song + lyrics sorter for CC:Tweaked

  Layout it maintains (same as Alex's library / jukebox expects):
      <disk label = artist>
          music/<Artist - Album>/<song>.dfpwm
          music/<Artist - Album>/<song>.lrc   (optional, beside audio)

  How to use:
      1. Run  Importer   (or  uploader  if saved under that name)
      2. Type the artist (autocompletes from your existing disk labels)
         and the album (blank = songs go in a folder named after the artist)
      3. Drag .dfpwm and/or .lrc files onto this computer's screen
         (the computer GUI, not a monitor)
      4. Keep dropping; press N to switch artist/album, Q to quit

  .dfpwm: same as before — artist disk with album + room, else other artist
      disk, else blank claimed disk, else wait for a blank.

  .lrc: match to an existing library .dfpwm (basename / normalized /
      Artist - Title / [ti:][ar:] tags). Prefer the current artist/album
      session folder when a song of that name is there or was just
      imported in the same drop. Write beside that .dfpwm; optional
      /lyrics mirror with multi-disk spill. Clear match/miss prints.

  For bulk orphan .lrc already on the computer, keep using:
      sort-music --apply --lyrics-only
]]

local CONFIG = {
  folder         = "music",  -- folder on each disk that holds the albums
  reserve        = 4096,     -- bytes to keep free on every disk
  skipDuplicates = true,     -- skip a song if the same file name is already in that album
  mirrorLyrics   = true,     -- also copy matched .lrc under /lyrics (spill across disks)
}

------------------------------------------------------------------ helpers
local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function safeName(s)
  s = s:gsub("[/\\]", "-"):gsub("%c", "")
  return trim(s)
end

local function fmtSize(n)
  if n >= 1048576 then return string.format("%.2f MB", n / 1048576) end
  return string.format("%.1f KB", n / 1024)
end

local function say(text, colour)
  local old = term.getTextColour()
  if term.isColour() and colour then term.setTextColour(colour) end
  print(text)
  term.setTextColour(old)
end

local function completeFrom(list)
  return function(partial)
    local out = {}
    local p = partial:lower()
    for _, s in ipairs(list) do
      if #s > #partial and s:lower():sub(1, #p) == p then
        out[#out + 1] = s:sub(#partial + 1)
      end
    end
    return out
  end
end

local function sameLabel(label, artist)
  if not label or label == "" then return false end
  local l, a = label:lower(), artist:lower()
  return l == a or l == a:sub(1, 32)
end

local function folderFor(artist, album)
  album = trim(album or "")
  local name
  if album == "" then
    name = artist
  elseif album:lower():sub(1, #artist + 3) == (artist .. " - "):lower() then
    name = album
  else
    name = artist .. " - " .. album
  end
  return safeName(name)
end

local function musicDir(d) return fs.combine(d.mount, CONFIG.folder) end

local function listDir(path)
  local ok, entries = pcall(fs.list, path)
  if ok and type(entries) == "table" then return entries end
  return {}
end

local function freeSpace(mount)
  local ok, n = pcall(fs.getFreeSpace, mount)
  return (ok and type(n) == "number") and n or 0
end

local function fileSize(path)
  local ok, n = pcall(fs.getSize, path)
  return (ok and type(n) == "number") and n or 0
end

local function isAudio(name)
  return type(name) == "string" and name:lower():match("%.dfpwm$") ~= nil
end

local function isLrc(name)
  return type(name) == "string" and name:lower():match("%.lrc$") ~= nil
end

local function norm(s)
  s = tostring(s or ""):lower():gsub("_", " "):gsub("%s+", " ")
  return s:gsub("^%s+", ""):gsub("%s+$", "")
end

local function loose(s)
  s = norm(s):gsub("[^%w%s]", " "):gsub("%s+", " ")
  return s:gsub("^%s+", ""):gsub("%s+$", "")
end

local function stripTrackNo(name)
  local n = tostring(name or "")
  local stripped = n:gsub("^%s*%d+%s*[%.%-%)]+%s*", ""):gsub("^%s*%d+%s+", "")
  return stripped ~= "" and stripped or n
end

local function songKeys(name)
  local base = tostring(name or ""):gsub("%.[Ll][Rr][Cc]$", ""):gsub("%.[Dd][Ff][Pp][Ww][Mm]$", "")
  local keys, seen = {}, {}
  local function add(v)
    local k = norm(v)
    if k ~= "" and not seen[k] then
      seen[k] = true
      keys[#keys + 1] = k
    end
    local lk = loose(v)
    if lk ~= "" and not seen[lk] then
      seen[lk] = true
      keys[#keys + 1] = lk
    end
  end
  add(base)
  add(stripTrackNo(base))
  add(base:gsub("%s*%b()", ""))
  add(stripTrackNo(base:gsub("%s*%b()", "")))
  local a, b, c = base:match("^(.-) %- (.-) %- (.+)$")
  if a and b and c then
    add(c)
    add(stripTrackNo(c))
  else
    local a2, t2 = base:match("^(.-) %- (.+)$")
    if a2 and t2 then
      add(t2)
      add(stripTrackNo(t2))
    end
  end
  return keys
end

local function parseArtistAlbum(folderName)
  local artist, album = folderName:match("^(.-) %- (.+)$")
  if artist and album and artist ~= "" and album ~= "" then
    return artist, album
  end
  return nil, nil
end

------------------------------------------------------------------ drives
local function listDisks()
  local out = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "drive" and disk.isPresent(name) and disk.hasData(name) then
      local mount = disk.getMountPath(name)
      if mount and fs.exists(mount) then
        out[#out + 1] = { name = name, mount = mount, label = disk.getLabel(name) }
      end
    end
  end
  table.sort(out, function(a, b)
    return (tonumber(a.mount:match("%d+")) or 1) < (tonumber(b.mount:match("%d+")) or 1)
  end)
  return out
end

local function isBlank(d)
  if d.label and d.label ~= "" then return false end
  local items = fs.list(d.mount)
  if #items == 0 then return true end
  if #items == 1 and items[1] == CONFIG.folder
     and fs.isDir(musicDir(d)) and #fs.list(musicDir(d)) == 0 then
    return true
  end
  return false
end

local function knownArtists()
  local seen, list = {}, {}
  for _, d in ipairs(listDisks()) do
    if d.label and d.label ~= "" and not seen[d.label:lower()] then
      seen[d.label:lower()] = true
      list[#list + 1] = d.label
    end
  end
  table.sort(list, function(a, b) return a:lower() < b:lower() end)
  return list
end

local function knownAlbums(artist)
  local seen, list = {}, {}
  for _, d in ipairs(listDisks()) do
    if sameLabel(d.label, artist) and fs.isDir(musicDir(d)) then
      for _, entry in ipairs(fs.list(musicDir(d))) do
        if fs.isDir(fs.combine(musicDir(d), entry)) then
          local shown = entry
          local prefix = artist .. " - "
          if shown:lower():sub(1, #prefix) == prefix:lower() then shown = shown:sub(#prefix + 1) end
          if not seen[shown:lower()] then
            seen[shown:lower()] = true
            list[#list + 1] = shown
          end
        end
      end
    end
  end
  table.sort(list, function(a, b) return a:lower() < b:lower() end)
  return list
end

-- bad = set of mount paths that already failed for this file
local function pickDisk(artist, folderName, size, bad)
  local mine, blanks = {}, {}
  for _, d in ipairs(listDisks()) do
    if not bad[d.mount] then
      if sameLabel(d.label, artist) then
        mine[#mine + 1] = d
      elseif isBlank(d) then
        blanks[#blanks + 1] = d
      end
    end
  end
  local need = size + CONFIG.reserve

  -- 1. this artist's disk that already holds this album and has room
  for _, d in ipairs(mine) do
    if fs.isDir(fs.combine(musicDir(d), folderName)) and fs.getFreeSpace(d.mount) >= need then
      return d, false
    end
  end
  -- 2. any other disk of this artist with room
  for _, d in ipairs(mine) do
    if fs.getFreeSpace(d.mount) >= need then return d, false end
  end
  -- 3. a blank disk: claim it for this artist
  for _, d in ipairs(blanks) do
    if fs.getFreeSpace(d.mount) >= need then
      disk.setLabel(d.name, artist)
      d.label = artist
      return d, true
    end
  end
  return nil
end

local function waitForDisk(artist, folderName, size, fileName, bad)
  while true do
    say(fileName .. ": no disk with room (" .. fmtSize(size) .. " needed).", colours.orange)
    say("Put a blank disk in an empty drive, then press Enter. S = skip this song.", colours.yellow)
    local k
    repeat
      local _, key = os.pullEvent("key")
      k = key
    until k == keys.enter or k == keys.s
    if k == keys.s then return nil end
    sleep(0.3) -- let the new disk mount
    local d, fresh = pickDisk(artist, folderName, size, bad)
    if d then return d, fresh end
  end
end

------------------------------------------------------------------ storing a song
local function store(artist, folderName, fileName, data)
  local size = #data

  if CONFIG.skipDuplicates then
    for _, d in ipairs(listDisks()) do
      if sameLabel(d.label, artist)
         and fs.exists(fs.combine(fs.combine(musicDir(d), folderName), fileName)) then
        return "duplicate", d
      end
    end
  end

  local bad = {}
  while true do
    local d, fresh = pickDisk(artist, folderName, size, bad)
    if not d then
      d, fresh = waitForDisk(artist, folderName, size, fileName, bad)
      if not d then return "skipped" end
    end

    local dir = fs.combine(musicDir(d), folderName)
    local path = fs.combine(dir, fileName)
    local ok = pcall(function()
      fs.makeDir(dir)
      local h = fs.open(path, "wb")
      if not h then error("cannot open file") end
      h.write(data)
      h.close()
    end)
    if ok and fs.exists(path) and fs.getSize(path) == size then
      return "ok", d, fresh, path
    end
    pcall(fs.delete, path)
    bad[d.mount] = true   -- try another disk for this song
  end
end

------------------------------------------------------------------ library index (for .lrc matching)
local function parseLrcMetaFromData(data, fileBase)
  local artist, album, title
  if type(data) == "string" then
    local n = 0
    for line in data:gmatch("[^\r\n]+") do
      n = n + 1
      if n > 40 then break end
      local tag, val = line:match("^%[([%a]+):%s*(.-)%s*%]$")
      if tag and val and val ~= "" then
        local t = tag:lower()
        if t == "ar" or t == "artist" then artist = val
        elseif t == "al" or t == "album" then album = val
        elseif t == "ti" or t == "title" then title = val
        end
      elseif line:match("^%[%d+:") then
        break
      end
    end
  end
  local base = fileBase or ""
  if not artist then
    local a, b, c = base:match("^(.-) %- (.-) %- (.+)$")
    if a and b and c then
      artist, album, title = a, b, c
    else
      local a2, t2 = base:match("^(.-) %- (.+)$")
      if a2 and t2 then artist, title = a2, t2 end
    end
  end
  if not title or title == "" then title = base end
  return artist, album, title, base
end

local function scanLibraryTracks()
  local tracks, seen = {}, {}

  local function addTrack(path, file, artistName, albumName)
    if seen[path] or not isAudio(file) then return end
    seen[path] = true
    local base = file:gsub("%.[Dd][Ff][Pp][Ww][Mm]$", "")
    tracks[#tracks + 1] = {
      path = path,
      artist = artistName,
      album = albumName,
      base = base,
      keys = songKeys(base),
    }
  end

  local function addAudioInDir(dir, artistName, albumName)
    if not (fs.exists(dir) and fs.isDir(dir)) then return end
    for _, file in ipairs(listDir(dir)) do
      local fp = fs.combine(dir, file)
      if not fs.isDir(fp) and isAudio(file) then
        addTrack(fp, file, artistName, albumName)
      end
    end
  end

  local function scanArtistTree(root)
    if not (fs.exists(root) and fs.isDir(root)) then return end
    for _, entry in ipairs(listDir(root)) do
      local entryPath = fs.combine(root, entry)
      if fs.isDir(entryPath) then
        local el = entry:lower()
        if el == "music" then
          scanArtistTree(entryPath)
        elseif el ~= "lyrics" and el ~= "lyrics-pack" and el ~= "sfx" then
          local children = listDir(entryPath)
          local hasAlbumDirs, hasDirectAudio = false, false
          for _, child in ipairs(children) do
            local cp = fs.combine(entryPath, child)
            if fs.isDir(cp) then hasAlbumDirs = true
            elseif isAudio(child) then hasDirectAudio = true end
          end
          local parsedArtist, parsedAlbum = parseArtistAlbum(entry)
          if hasDirectAudio and parsedArtist then
            -- legacy: music/<Artist - Album>/*.dfpwm
            addAudioInDir(entryPath, parsedArtist, parsedAlbum)
          elseif hasAlbumDirs then
            for _, albumName in ipairs(children) do
              local albumPath = fs.combine(entryPath, albumName)
              if fs.isDir(albumPath) then
                addAudioInDir(albumPath, entry, albumName)
              elseif isAudio(albumName) then
                addTrack(albumPath, albumName, entry, "Singles")
              end
            end
          elseif hasDirectAudio then
            addAudioInDir(entryPath, "Various", entry)
          end
        end
      elseif isAudio(entry) then
        addTrack(entryPath, entry, "Singles", "Singles")
      end
    end
  end

  if fs.exists("music") and fs.isDir("music") then scanArtistTree("music") end
  for _, d in ipairs(listDisks()) do
    scanArtistTree(d.mount)
  end
  return tracks
end

local function findInSessionAlbum(tracks, artist, folderName, keys)
  local a = norm(artist)
  local folderLow = norm(folderName)
  local best
  for _, t in ipairs(tracks) do
    if norm(t.artist) == a then
      local dir = fs.getDir(t.path)
      local leaf = fs.getName(dir)
      if norm(leaf) == folderLow or norm(dir):find(folderLow, 1, true) then
        for _, tk in ipairs(t.keys) do
          for _, sk in ipairs(keys) do
            if tk == sk then return t end
          end
        end
      end
    end
  end
  return best
end

local function matchTrack(tracks, artist, folderName, lrcBase, lrcArtist, lrcTitle, batchPaths)
  local keys = songKeys(lrcTitle or lrcBase)
  for _, k in ipairs(songKeys(lrcBase)) do
    local seen = false
    for _, e in ipairs(keys) do if e == k then seen = true break end end
    if not seen then keys[#keys + 1] = k end
  end

  -- 0) same-drop .dfpwm basenames (just imported / about to land)
  if batchPaths then
    for _, bp in ipairs(batchPaths) do
      local bkeys = songKeys(bp.base)
      for _, tk in ipairs(bkeys) do
        for _, sk in ipairs(keys) do
          if tk == sk then
            return {
              path = bp.path,
              artist = artist,
              album = folderName,
              base = bp.base,
              keys = bkeys,
              how = "same-drop",
            }
          end
        end
      end
    end
  end

  -- 1) current session album folder
  local hit = findInSessionAlbum(tracks, artist, folderName, keys)
  if hit then hit.how = "session-album"; return hit end

  -- 2) same artist + key
  local artistHits = {}
  local a = norm(artist)
  local la = lrcArtist and norm(lrcArtist) or ""
  for _, t in ipairs(tracks) do
    local ta = norm(t.artist)
    if ta == a or (la ~= "" and ta == la) then
      local matched = false
      for _, tk in ipairs(t.keys) do
        if matched then break end
        for _, sk in ipairs(keys) do
          if tk == sk then
            artistHits[#artistHits + 1] = t
            matched = true
            break
          end
        end
      end
    end
  end
  if #artistHits == 1 then
    artistHits[1].how = "artist+name"
    return artistHits[1]
  elseif #artistHits > 1 then
    -- prefer session folder name among ties
    local folderLow = norm(folderName)
    for _, t in ipairs(artistHits) do
      if norm(fs.getName(fs.getDir(t.path))) == folderLow then
        t.how = "artist+name (album)"
        return t
      end
    end
    artistHits[1].how = "artist+name (first)"
    return artistHits[1]
  end

  -- 3) basename / normalized / title-only across library
  local songHits = {}
  for _, t in ipairs(tracks) do
    local matched = false
    for _, tk in ipairs(t.keys) do
      if matched then break end
      for _, sk in ipairs(keys) do
        if tk == sk then
          songHits[#songHits + 1] = t
          matched = true
          break
        end
      end
    end
  end
  if #songHits == 1 then
    songHits[1].how = "basename"
    return songHits[1]
  elseif #songHits > 1 then
    for _, t in ipairs(songHits) do
      if norm(t.artist) == a or (la ~= "" and norm(t.artist) == la) then
        t.how = "basename (artist-tied)"
        return t
      end
    end
    songHits[1].how = "basename (ambiguous→first)"
    return songHits[1]
  end

  -- 4) fuzzy contain (unique, min length 5)
  local scores = {}
  for _, t in ipairs(tracks) do
    for _, tk in ipairs(t.keys) do
      if #tk >= 5 then
        for _, sk in ipairs(keys) do
          if #sk >= 5 then
            local hit = false
            local score = 0
            if tk == sk then hit, score = true, 100
            elseif #tk >= #sk and tk:find(sk, 1, true) then hit, score = true, math.min(#tk, #sk)
            elseif #sk >= #tk and sk:find(tk, 1, true) then hit, score = true, math.min(#tk, #sk)
            end
            if hit then
              if not scores[t] or score > scores[t] then scores[t] = score end
            end
          end
        end
      end
    end
  end
  local best, bestScore, ties = nil, 0, 0
  for t, sc in pairs(scores) do
    if sc > bestScore then
      best, bestScore, ties = t, sc, 1
    elseif sc == bestScore then
      ties = ties + 1
      if a ~= "" and norm(t.artist) == a and norm(best.artist) ~= a then
        best = t
      end
    end
  end
  if best and (ties == 1 or bestScore >= 100 or (a ~= "" and norm(best.artist) == a)) then
    best.how = "fuzzy"
    return best
  end
  return nil
end

local function mountOf(path)
  path = tostring(path or ""):gsub("^/", "")
  local m = path:match("^(disk%d*)")
  if m and (path == m or path:sub(#m + 1, #m + 1) == "/") then
    return m
  end
  return ""
end

local function ensureDir(path)
  if path == "" or path == "/" then return true end
  if fs.exists(path) then return fs.isDir(path) end
  local parent = fs.getDir(path)
  if parent and parent ~= "" and parent ~= path then
    if not ensureDir(parent) then return false end
  end
  local ok = pcall(fs.makeDir, path)
  return ok and fs.isDir(path)
end

local function writeBytes(path, data)
  local parent = fs.getDir(path)
  if parent and parent ~= "" then
    if not ensureDir(parent) then return false, "mkdir failed" end
  end
  local ok, err = pcall(function()
    local h = fs.open(path, "wb")
    if not h then error("cannot open") end
    h.write(data)
    h.close()
  end)
  if not ok then return false, err end
  if not fs.exists(path) or fs.getSize(path) ~= #data then
    pcall(fs.delete, path)
    return false, "write verify failed"
  end
  return true
end

local function mirrorLrc(data, track, lrcFileName)
  if not CONFIG.mirrorLyrics then return nil end
  local rel = fs.combine(track.artist or "Singles", track.album or "Singles", lrcFileName)
  local prefer = mountOf(track.path)
  local need = #data + CONFIG.reserve
  local order = {}
  if prefer ~= "" then order[#order + 1] = fs.combine(prefer, "lyrics") end
  order[#order + 1] = "lyrics"
  for _, d in ipairs(listDisks()) do
    local lr = fs.combine(d.mount, "lyrics")
    local already = false
    for _, o in ipairs(order) do if o == lr then already = true break end end
    if not already then order[#order + 1] = lr end
  end
  for _, root in ipairs(order) do
    local mount = mountOf(root)
    local mpath = mount == "" and "/" or mount
    if freeSpace(mpath) >= need then
      local dst = fs.combine(root, rel)
      local ok, err = writeBytes(dst, data)
      if ok then return dst end
      if type(err) == "string" and err:lower():find("space", 1, true) then
        -- try next
      else
        return nil, err
      end
    end
  end
  return nil, "no room for lyrics mirror"
end

local function storeLrc(artist, folderName, fileName, data, batchPaths)
  local tracks = scanLibraryTracks()
  -- Include same-batch paths that may not be visible yet if scan raced; batchPaths wins in match
  local base = fileName:gsub("%.[Ll][Rr][Cc]$", "")
  local lrcArtist, lrcAlbum, lrcTitle = parseLrcMetaFromData(data, base)
  local hit = matchTrack(tracks, artist, folderName, base, lrcArtist, lrcTitle, batchPaths)

  if not hit then
    local hint = lrcTitle or base
    if lrcArtist then hint = lrcArtist .. " - " .. hint end
    return "miss", nil, hint
  end

  local lrcName = hit.base .. ".lrc"
  local beside = fs.combine(fs.getDir(hit.path), lrcName)
  if fs.exists(beside) and not fs.isDir(beside) then
    if fileSize(beside) == #data then
      local mirrored = select(1, mirrorLrc(data, hit, lrcName))
      return "duplicate", hit, beside, mirrored
    end
  end

  local need = #data + CONFIG.reserve
  local m = mountOf(hit.path)
  local mpath = m == "" and "/" or m
  if freeSpace(mpath) < need then
    return "full", hit, beside
  end

  local ok, err = writeBytes(beside, data)
  if not ok then
    return "error", hit, tostring(err)
  end
  local mirrored = select(1, mirrorLrc(data, hit, lrcName))
  return "ok", hit, beside, mirrored
end

------------------------------------------------------------------ dropped files
local function handleDrop(files, artist, album)
  local folderName = folderFor(artist, album)
  local okList, list = pcall(function() return files.getFiles() end)
  if not okList or type(list) ~= "table" then
    say("Could not read the dropped files: " .. tostring(list), colours.red)
    return
  end

  -- Pass 1: .dfpwm (so same-drop .lrc can land beside them)
  local batchAudio = {} -- { base, path, name }
  local pendingLrc = {}

  for _, f in ipairs(list) do
    local name = safeName(f.getName())
    local lower = name:lower()
    if lower:match("%.dfpwm$") then
      local okRead, data = pcall(f.readAll)
      if f.close then pcall(f.close) end
      if not okRead or not data or #data == 0 then
        say(name .. ": could not read file, skipped", colours.red)
      else
        local status, d, fresh, path = store(artist, folderName, name, data)
        if status == "ok" then
          say(string.format("%s -> %s (%s)%s, %s free", name, d.mount, d.label,
            fresh and " [new disk]" or "", fmtSize(fs.getFreeSpace(d.mount))), colours.lime)
          batchAudio[#batchAudio + 1] = {
            base = name:gsub("%.[Dd][Ff][Pp][Ww][Mm]$", ""),
            path = path,
            name = name,
          }
        elseif status == "duplicate" then
          say(name .. ": already on " .. d.mount .. ", skipped", colours.lightGrey)
          -- Still usable as an .lrc target in this album
          local existing = fs.combine(fs.combine(musicDir(d), folderName), name)
          if fs.exists(existing) then
            batchAudio[#batchAudio + 1] = {
              base = name:gsub("%.[Dd][Ff][Pp][Ww][Mm]$", ""),
              path = existing,
              name = name,
            }
          end
        else
          say(name .. ": skipped", colours.orange)
        end
      end
    elseif lower:match("%.lrc$") then
      local okRead, data = pcall(f.readAll)
      if f.close then pcall(f.close) end
      if not okRead or not data or #data == 0 then
        say(name .. ": could not read .lrc, skipped", colours.red)
      else
        pendingLrc[#pendingLrc + 1] = { name = name, data = data }
      end
    else
      say(name .. ": not .dfpwm or .lrc, skipped", colours.orange)
      if f.close then pcall(f.close) end
    end
  end

  -- Pass 2: .lrc match + place
  for _, item in ipairs(pendingLrc) do
    local status, hit, detail, mirrored = storeLrc(artist, folderName, item.name, item.data, batchAudio)
    if status == "ok" then
      local how = hit and hit.how or "?"
      say(string.format("LRC match [%s]: %s -> %s", how, item.name, detail), colours.lime)
      if mirrored then
        say("  mirrored " .. mirrored, colours.lightGrey)
      end
    elseif status == "duplicate" then
      say(string.format("LRC already beside track: %s (%s)", detail, item.name), colours.lightGrey)
      if mirrored then
        say("  mirrored " .. mirrored, colours.lightGrey)
      end
    elseif status == "miss" then
      say(string.format("LRC miss: %s (no .dfpwm for \"%s\")", item.name, tostring(detail)), colours.orange)
      say("  Tip: import the song first, or run sort-music --apply --lyrics-only for bulk orphans.", colours.lightGrey)
    elseif status == "full" then
      say(string.format("LRC matched %s but disk full for %s", hit and hit.base or "?", detail), colours.red)
    else
      say(string.format("LRC error: %s — %s", item.name, tostring(detail)), colours.red)
    end
  end
end

------------------------------------------------------------------ session
local function promptSession(lastArtist, lastAlbum)
  term.clear()
  term.setCursorPos(1, 1)
  say("DFPWM + LRC Importer", colours.yellow)
  say("Leave artist empty to quit.\n", colours.lightGrey)

  write("Artist: ")
  local artist = trim(read(nil, nil, completeFrom(knownArtists()), lastArtist or ""))
  if artist == "" then return nil end

  local albums = knownAlbums(artist)
  if #albums > 0 then
    say("Existing albums: " .. table.concat(albums, ", "), colours.lightGrey)
  end
  write("Album (blank = singles): ")
  local album = trim(read(nil, nil, completeFrom(albums), (artist == lastArtist) and (lastAlbum or "") or ""))
  return artist, album
end

local artist, album
while true do
  artist, album = promptSession(artist, album)
  if not artist then break end

  print()
  say("Folder: music/" .. folderFor(artist, album), colours.cyan)
  say("Drop .dfpwm and/or .lrc files onto this screen now.", colours.white)
  say("N = new artist/album   Q = quit\n", colours.lightGrey)

  local quit = false
  while true do
    local ev, a = os.pullEvent()
    if ev == "file_transfer" then
      handleDrop(a, artist, album)
    elseif ev == "key" then
      if a == keys.n then break
      elseif a == keys.q then quit = true; break end
    end
  end
  if quit then break end
end

term.clear()
term.setCursorPos(1, 1)
print("Importer stopped.")
