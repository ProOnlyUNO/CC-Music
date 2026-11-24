--[[
  Importer.lua - drag & drop song + lyrics + art + video sorter for CC:Tweaked

  Layout it maintains (same as the jukebox library expects):
      <disk label = artist>
          music/<Artist>/<Album>/<song>.dfpwm
          music/<Artist>/<Album>/<song>.lrc   (optional, beside audio)
          music/<Artist>/<Album>/<song>.cvid  (optional music-video pack)
          music/<Artist>/<Album>/<song>.nfp   (optional pixel art, beside audio)
          music/<Artist>/<Album>/cover.nfp    (optional album art)
      Legacy flat music/<Artist - Album>/ is still recognized when matching.

  How to use:
      1. Run  Importer   (or  uploader  if saved under that name)
      2. Type the artist (autocompletes from your existing disk labels)
         and the album (blank = Singles)
      3. Drag .dfpwm / .lrc / .cvid / .nfp / .png / .jpg onto this computer's screen
         (the computer GUI, not a monitor)
      4. Keep dropping; press N to switch artist/album, Q to quit

  .dfpwm: artist disk with album + room, else other artist disk, else blank
      claimed disk, else wait for a blank. Writes nested Artist/Album.

  .lrc: match to an existing library .dfpwm (basename / normalized /
      Artist - Title / [ti:][ar:] tags). Prefer the current artist/album
      session folder when a song of that name is there or was just
      imported in the same drop. Write beside that .dfpwm; optional
      /lyrics mirror with multi-disk spill. Clear match/miss prints.

  .cvid: same basename match as .lrc — lands beside the matching .dfpwm so
      jukebox can hand off the main monitor to the music video after ~3.5s.

  .nfp / .png / .jpg: place into matching Artist/Album.
      cover/album/folder/front/art names → album cover.* beside the album.
      Song-named art → beside the matching .dfpwm.
      If no album/track match, prompt for Artist + Album.
      Jukebox thumbs need .nfp (desktop Convert turns PNG/JPG into .nfp).

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

-- Nested music/<Artist>/<Album>/ (blank album → Singles).
local function albumParts(artist, album)
  local a = safeName(artist)
  album = trim(album or "")
  if album == "" then
    album = "Singles"
  else
    local prefix = a .. " - "
    if album:lower():sub(1, #prefix) == prefix:lower() then
      album = album:sub(#prefix + 1)
    end
    album = safeName(album)
    if album == "" then album = "Singles" end
  end
  local nested = fs.combine(a, album)
  local legacy = safeName(a .. " - " .. album)
  return a, album, nested, legacy
end

local function folderFor(artist, album)
  local _, _, nested = albumParts(artist, album)
  return nested
end

local COVER_STEMS = {
  cover = true, album = true, folder = true, front = true,
  artwork = true, art = true, thumb = true, thumbnail = true,
}

local function artExt(name)
  local lower = tostring(name or ""):lower()
  if lower:match("%.nfp$") then return ".nfp" end
  if lower:match("%.png$") then return ".png" end
  local jpg = lower:match("%.jpe?g$")
  if jpg then return jpg end
  return nil
end

local function isArtFile(name)
  return artExt(name) ~= nil
end

local function isCoverName(fileName)
  local stem = tostring(fileName or ""):gsub("%.[^.]+$", ""):lower()
  return COVER_STEMS[stem] == true
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

local function isNfp(name)
  return type(name) == "string" and name:lower():match("%.nfp$") ~= nil
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
  local base = tostring(name or "")
    :gsub("%.[Ll][Rr][Cc]$", "")
    :gsub("%.[Nn][Ff][Pp]$", "")
    :gsub("%.[Pp][Nn][Gg]$", "")
    :gsub("%.[Jj][Pp][Ee]?[Gg]$", "")
    :gsub("%.[Dd][Ff][Pp][Ww][Mm]$", "")
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
  -- Also surface nested artist folders under music/
  for _, d in ipairs(listDisks()) do
    local root = musicDir(d)
    if fs.exists(root) and fs.isDir(root) then
      for _, entry in ipairs(listDir(root)) do
        local path = fs.combine(root, entry)
        if fs.isDir(path) and not parseArtistAlbum(entry) and not seen[entry:lower()] then
          local hasAlbum = false
          for _, child in ipairs(listDir(path)) do
            if fs.isDir(fs.combine(path, child)) then hasAlbum = true; break end
          end
          if hasAlbum then
            seen[entry:lower()] = true
            list[#list + 1] = entry
          end
        end
      end
    end
  end
  table.sort(list, function(a, b) return a:lower() < b:lower() end)
  return list
end

local function knownAlbums(artist)
  local seen, list = {}, {}
  local function add(shown)
    if shown and shown ~= "" and not seen[shown:lower()] then
      seen[shown:lower()] = true
      list[#list + 1] = shown
    end
  end
  for _, d in ipairs(listDisks()) do
    local root = musicDir(d)
    if fs.isDir(root) then
      -- Nested music/<Artist>/<Album>/
      local artistPath = fs.combine(root, safeName(artist))
      if fs.exists(artistPath) and fs.isDir(artistPath) then
        for _, entry in ipairs(listDir(artistPath)) do
          if fs.isDir(fs.combine(artistPath, entry)) then add(entry) end
        end
      end
      -- Legacy music/<Artist - Album>/
      for _, entry in ipairs(listDir(root)) do
        local path = fs.combine(root, entry)
        if fs.isDir(path) then
          local prefix = artist .. " - "
          if entry:lower():sub(1, #prefix) == prefix:lower() then
            add(entry:sub(#prefix + 1))
          elseif sameLabel(d.label, artist) and norm(entry) ~= norm(artist) then
            local hasAudio = false
            for _, child in ipairs(listDir(path)) do
              if isAudio(child) then hasAudio = true; break end
            end
            if hasAudio and parseArtistAlbum(entry) then
              local _, al = parseArtistAlbum(entry)
              add(al)
            end
          end
        end
      end
    end
  end
  table.sort(list, function(a, b) return a:lower() < b:lower() end)
  return list
end

local function albumDirsOn(d, artist, album)
  local _, _, nested, legacy = albumParts(artist, album)
  local root = musicDir(d)
  return {
    fs.combine(root, nested),
    fs.combine(root, legacy),
  }
end

local function findAlbumDir(artist, album, batchPaths)
  local _, albumName = albumParts(artist, album)
  for _, d in ipairs(listDisks()) do
    for _, cand in ipairs(albumDirsOn(d, artist, album)) do
      if fs.exists(cand) and fs.isDir(cand) then
        return cand, d
      end
    end
  end
  -- Nested music/<Artist>/<Album> even if disk label differs
  for _, d in ipairs(listDisks()) do
    local root = musicDir(d)
    if fs.isDir(root) then
      for _, entry in ipairs(listDir(root)) do
        local artistPath = fs.combine(root, entry)
        if fs.isDir(artistPath) and norm(entry) == norm(artist) then
          local albumPath = fs.combine(artistPath, albumName)
          if fs.exists(albumPath) and fs.isDir(albumPath) then
            return albumPath, d
          end
        end
      end
    end
  end
  if batchPaths and batchPaths[1] and batchPaths[1].path then
    return fs.getDir(batchPaths[1].path), nil
  end
  return nil, nil
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
local function existingSongPath(artist, album, fileName)
  for _, d in ipairs(listDisks()) do
    for _, dir in ipairs(albumDirsOn(d, artist, album)) do
      local path = fs.combine(dir, fileName)
      if fs.exists(path) and not fs.isDir(path) then
        return path, d
      end
    end
  end
  return nil, nil
end

local function store(artist, album, fileName, data)
  local size = #data
  local _, albumName, nestedRel = albumParts(artist, album)

  if CONFIG.skipDuplicates then
    local existing, d = existingSongPath(artist, albumName, fileName)
    if existing then return "duplicate", d, false, existing end
  end

  local bad = {}
  while true do
    local d, fresh = pickDisk(artist, nestedRel, size, bad)
    if not d then
      d, fresh = waitForDisk(artist, nestedRel, size, fileName, bad)
      if not d then return "skipped" end
    end

    local dir = fs.combine(musicDir(d), nestedRel)
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

------------------------------------------------------------------ library index (for .lrc / art matching)
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

local function findInSessionAlbum(tracks, artist, album, keys)
  local a = norm(artist)
  local albumLow = norm(album)
  local _, albumName = albumParts(artist, album)
  local albumLeaf = norm(albumName)
  local best
  for _, t in ipairs(tracks) do
    if norm(t.artist) == a then
      local dir = fs.getDir(t.path)
      local leaf = fs.getName(dir)
      if norm(leaf) == albumLeaf or norm(leaf) == albumLow
         or norm(t.album) == albumLeaf or norm(dir):find(albumLeaf, 1, true) then
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

local function matchTrack(tracks, artist, album, lrcBase, lrcArtist, lrcTitle, batchPaths)
  local keys = songKeys(lrcTitle or lrcBase)
  for _, k in ipairs(songKeys(lrcBase)) do
    local seen = false
    for _, e in ipairs(keys) do if e == k then seen = true break end end
    if not seen then keys[#keys + 1] = k end
  end
  local _, albumName = albumParts(artist, album)

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
              album = albumName,
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
  local hit = findInSessionAlbum(tracks, artist, album, keys)
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
    local albumLow = norm(albumName)
    for _, t in ipairs(artistHits) do
      if norm(fs.getName(fs.getDir(t.path))) == albumLow or norm(t.album) == albumLow then
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
            local matched = false
            local score = 0
            if tk == sk then matched, score = true, 100
            elseif #tk >= #sk and tk:find(sk, 1, true) then matched, score = true, math.min(#tk, #sk)
            elseif #sk >= #tk and sk:find(tk, 1, true) then matched, score = true, math.min(#tk, #sk)
            end
            if matched then
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

local function storeLrc(artist, album, fileName, data, batchPaths)
  local tracks = scanLibraryTracks()
  local base = fileName:gsub("%.[Ll][Rr][Cc]$", "")
  local lrcArtist, lrcAlbum, lrcTitle = parseLrcMetaFromData(data, base)
  local hit = matchTrack(tracks, artist, album, base, lrcArtist, lrcTitle, batchPaths)

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

-- Place .cvid beside matching .dfpwm (same basename rules as lyrics).
local function storeCvid(artist, album, fileName, data, batchPaths)
  local tracks = scanLibraryTracks()
  local base = fileName:gsub("%.[Cc][Vv][Ii][Dd]$", "")
  local hit = matchTrack(tracks, artist, album, base, nil, nil, batchPaths)
  if not hit then
    return "miss", nil, base
  end
  local cvidName = hit.base .. ".cvid"
  local beside = fs.combine(fs.getDir(hit.path), cvidName)
  if fs.exists(beside) and not fs.isDir(beside) and fileSize(beside) == #data then
    return "duplicate", hit, beside
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
  return "ok", hit, beside
end

local function promptArtDestination(defaultArtist, defaultAlbum)
  say("No matching Artist/Album for this art. Enter where to put it.", colours.yellow)
  write("Artist: ")
  local artist = trim(read(nil, nil, completeFrom(knownArtists()), defaultArtist or ""))
  if artist == "" then return nil end
  local albums = knownAlbums(artist)
  if #albums > 0 then
    say("Existing albums: " .. table.concat(albums, ", "), colours.lightGrey)
  end
  write("Album (blank = Singles): ")
  local album = trim(read(nil, nil, completeFrom(albums), defaultAlbum or ""))
  return artist, album
end

local function ensureSessionAlbumDir(artist, album)
  local _, albumName, nestedRel = albumParts(artist, album)
  local albumDir, d = findAlbumDir(artist, album, nil)
  if albumDir then return albumDir, d end

  -- Create nested album on an artist (or blank) disk.
  local bad = {}
  local diskInfo = pickDisk(artist, nestedRel, CONFIG.reserve, bad)
  if not diskInfo then
    for _, cand in ipairs(listDisks()) do
      if freeSpace(cand.mount) >= CONFIG.reserve then
        if not cand.label or cand.label == "" then
          disk.setLabel(cand.name, artist)
          cand.label = artist
        end
        diskInfo = cand
        break
      end
    end
  end
  if not diskInfo then return nil, nil end
  albumDir = fs.combine(musicDir(diskInfo), nestedRel)
  if not ensureDir(albumDir) then return nil, nil end
  return albumDir, diskInfo
end

local function storeArt(artist, album, fileName, data, batchPaths)
  local ext = artExt(fileName)
  if not ext then return "error", nil, "unsupported art type" end

  local tracks = scanLibraryTracks()
  local base = fileName:gsub("%.[^.]+$", "")

  if isCoverName(fileName) then
    local albumDir = select(1, findAlbumDir(artist, album, batchPaths))
    if not albumDir then
      local a2, al2 = promptArtDestination(artist, album)
      if not a2 then return "skipped", nil, "cancelled" end
      artist, album = a2, al2
      albumDir = select(1, ensureSessionAlbumDir(artist, album))
    end
    if not albumDir then
      return "miss", nil, folderFor(artist, album)
    end
    local coverName = (ext == ".nfp") and "cover.nfp" or ("cover" .. ext)
    local beside = fs.combine(albumDir, coverName)
    if fs.exists(beside) and not fs.isDir(beside) and fileSize(beside) == #data then
      return "duplicate", nil, beside
    end
    local ok, err = writeBytes(beside, data)
    if not ok then return "error", nil, tostring(err) end
    return "ok", nil, beside
  end

  local hit = matchTrack(tracks, artist, album, base, nil, nil, batchPaths)
  if not hit then
    -- Fall back: place as album cover in session (or prompted) album.
    local albumDir = select(1, findAlbumDir(artist, album, batchPaths))
    if not albumDir then
      local a2, al2 = promptArtDestination(artist, album)
      if not a2 then return "skipped", nil, "cancelled" end
      artist, album = a2, al2
      albumDir = select(1, ensureSessionAlbumDir(artist, album))
    end
    if not albumDir then
      return "miss", nil, base
    end
    local coverName = (ext == ".nfp") and "cover.nfp" or ("cover" .. ext)
    local beside = fs.combine(albumDir, coverName)
    if fs.exists(beside) and not fs.isDir(beside) and fileSize(beside) == #data then
      return "duplicate", nil, beside
    end
    local ok, err = writeBytes(beside, data)
    if not ok then return "error", nil, tostring(err) end
    say("  (no song match — saved as album cover)", colours.lightGrey)
    return "ok", nil, beside
  end

  local artName = hit.base .. ext
  local beside = fs.combine(fs.getDir(hit.path), artName)
  if fs.exists(beside) and not fs.isDir(beside) and fileSize(beside) == #data then
    return "duplicate", hit, beside
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

  -- Seed album cover when missing (nfp only — jukebox thumbs).
  if ext == ".nfp" then
    local cover = fs.combine(fs.getDir(hit.path), "cover.nfp")
    if not fs.exists(cover) then
      writeBytes(cover, data)
    end
  end
  return "ok", hit, beside
end

------------------------------------------------------------------ dropped files
local function handleDrop(files, artist, album)
  local okList, list = pcall(function() return files.getFiles() end)
  if not okList or type(list) ~= "table" then
    say("Could not read the dropped files: " .. tostring(list), colours.red)
    return
  end

  -- Pass 1: .dfpwm (so same-drop .lrc/.cvid/.nfp can land beside them)
  local batchAudio = {} -- { base, path, name }
  local pendingLrc = {}
  local pendingCvid = {}
  local pendingArt = {}

  for _, f in ipairs(list) do
    local name = safeName(f.getName())
    local lower = name:lower()
    if lower:match("%.dfpwm$") then
      local okRead, data = pcall(f.readAll)
      if f.close then pcall(f.close) end
      if not okRead or not data or #data == 0 then
        say(name .. ": could not read file, skipped", colours.red)
      else
        local status, d, fresh, path = store(artist, album, name, data)
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
          if path then
            batchAudio[#batchAudio + 1] = {
              base = name:gsub("%.[Dd][Ff][Pp][Ww][Mm]$", ""),
              path = path,
              name = name,
            }
          else
            local existing = select(1, existingSongPath(artist, album, name))
            if existing then
              batchAudio[#batchAudio + 1] = {
                base = name:gsub("%.[Dd][Ff][Pp][Ww][Mm]$", ""),
                path = existing,
                name = name,
              }
            end
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
    elseif lower:match("%.cvid$") then
      local okRead, data = pcall(f.readAll)
      if f.close then pcall(f.close) end
      if not okRead or not data or #data == 0 then
        say(name .. ": could not read .cvid, skipped", colours.red)
      else
        pendingCvid[#pendingCvid + 1] = { name = name, data = data }
      end
    elseif isArtFile(name) then
      local okRead, data = pcall(f.readAll)
      if f.close then pcall(f.close) end
      if not okRead or not data or #data == 0 then
        say(name .. ": could not read art file, skipped", colours.red)
      else
        pendingArt[#pendingArt + 1] = { name = name, data = data }
      end
    else
      say(name .. ": not .dfpwm / .lrc / .cvid / .nfp / .png / .jpg, skipped", colours.orange)
      if f.close then pcall(f.close) end
    end
  end

  -- Pass 2: .lrc match + place
  for _, item in ipairs(pendingLrc) do
    local status, hit, detail, mirrored = storeLrc(artist, album, item.name, item.data, batchAudio)
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

  -- Pass 3: .cvid beside matching .dfpwm
  for _, item in ipairs(pendingCvid) do
    local status, hit, detail = storeCvid(artist, album, item.name, item.data, batchAudio)
    if status == "ok" then
      say(string.format("CVID: %s -> %s", item.name, detail), colours.lime)
    elseif status == "duplicate" then
      say(string.format("CVID already beside track: %s (%s)", detail, item.name), colours.lightGrey)
    elseif status == "miss" then
      say(string.format("CVID miss: %s (no .dfpwm for \"%s\")", item.name, tostring(detail)), colours.orange)
      say("  Tip: import the song first, or drop Song.dfpwm + Song.cvid together.", colours.lightGrey)
    elseif status == "full" then
      say(string.format("CVID matched %s but disk full for %s", hit and hit.base or "?", detail), colours.red)
    else
      say(string.format("CVID error: %s — %s", item.name, tostring(detail)), colours.red)
    end
  end

  -- Pass 4: .nfp / .png / .jpg into matching Artist/Album (or prompt)
  for _, item in ipairs(pendingArt) do
    local status, hit, detail = storeArt(artist, album, item.name, item.data, batchAudio)
    local kind = (artExt(item.name) or ""):upper():gsub("%.", "")
    if status == "ok" then
      say(string.format("%s art: %s -> %s", kind, item.name, detail), colours.lime)
      if artExt(item.name) ~= ".nfp" then
        say("  Tip: jukebox thumbs need .nfp — desktop Convert (PNG/JPG → cover.nfp).", colours.lightGrey)
      end
    elseif status == "duplicate" then
      say(string.format("%s already beside track: %s (%s)", kind, detail, item.name), colours.lightGrey)
    elseif status == "miss" then
      say(string.format("%s miss: %s (no Artist/Album for \"%s\")", kind, item.name, tostring(detail)), colours.orange)
      say("  Tip: import the song first, or drop cover.nfp after picking Artist/Album.", colours.lightGrey)
    elseif status == "skipped" then
      say(string.format("%s skipped: %s", kind, item.name), colours.lightGrey)
    elseif status == "full" then
      say(string.format("%s matched %s but disk full for %s", kind, hit and hit.base or "?", detail), colours.red)
    else
      say(string.format("%s error: %s — %s", kind, item.name, tostring(detail)), colours.red)
    end
  end
end

------------------------------------------------------------------ session
local function promptSession(lastArtist, lastAlbum)
  term.clear()
  term.setCursorPos(1, 1)
  say("DFPWM + LRC + Art Importer", colours.yellow)
  say("Leave artist empty to quit.\n", colours.lightGrey)

  write("Artist: ")
  local artist = trim(read(nil, nil, completeFrom(knownArtists()), lastArtist or ""))
  if artist == "" then return nil end

  local albums = knownAlbums(artist)
  if #albums > 0 then
    say("Existing albums: " .. table.concat(albums, ", "), colours.lightGrey)
  end
  write("Album (blank = Singles): ")
  local album = trim(read(nil, nil, completeFrom(albums), (artist == lastArtist) and (lastAlbum or "") or ""))
  return artist, album
end

local artist, album
while true do
  artist, album = promptSession(artist, album)
  if not artist then break end

  print()
  say("Folder: music/" .. folderFor(artist, album), colours.cyan)
  say("Drop .dfpwm / .lrc / .cvid / .nfp / .png / .jpg onto this screen now.", colours.white)
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
