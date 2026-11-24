--[[
  delete-music.lua — pick Artist → Album → Song (or whole album) and delete

  Scans the same library layout as jukebox.lua:
      disk/Artist/Album/*.dfpwm
      diskN/Artist/Album/*.dfpwm
      disk/music/…  music/…
      music/<Artist> - <Album>/*.dfpwm
      plain Album/*.dfpwm → artist "Various"
      loose *.dfpwm → Singles/Singles

  Usage:
      delete-music              -- interactive; confirm (y) required before deletes
      delete-music --dry-run    -- preview only (never deletes)
      delete-music --help

  Deletes for a song:
    • the .dfpwm
    • matching .lrc beside it
    • optional /lyrics (and diskN/lyrics) mirror for that song

  Album delete removes every track in that album (+ their .lrc mirrors),
  then prunes empty album/artist dirs (never mounts, never sfx/).

  Never touches /sfx, rom, or files outside the chosen tracks.
]]

local rawArgs = { ... }
local opts = {
  dryRun = false,
}

for _, a in ipairs(rawArgs) do
  local lower = tostring(a):lower()
  if lower == "--dry-run" or lower == "--dryrun" then
    opts.dryRun = true
  elseif lower == "--help" or lower == "-h" then
    print("delete-music [--dry-run]")
    print("  Pick Artist → Album → Song, or DELETE ALBUM.")
    print("  Real deletes always ask for y/yes. --dry-run only prints what would go.")
    print("  Removes .dfpwm + beside .lrc + optional /lyrics mirror. Never touches sfx/.")
    return
  end
end

local PROTECTED_TOP = {
  sfx = true,
  rom = true,
  ["lyrics-pack"] = true,
}

------------------------------------------------------------------ helpers
local function modeTag()
  return opts.dryRun and "[dry-run] " or ""
end

-- All floppy mounts: fs root disk/diskN (any N) + drive peripherals.
local function listFloppyMounts()
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

local ROOTS = { "music", "disk", "disk/music" }
do
  local seen = { music = true, disk = true, ["disk/music"] = true }
  for _, m in ipairs(listFloppyMounts()) do
    if not seen[m] then
      seen[m] = true
      ROOTS[#ROOTS + 1] = m
    end
    local mr = m .. "/music"
    if not seen[mr] and fs.exists(mr) and fs.isDir(mr) then
      seen[mr] = true
      ROOTS[#ROOTS + 1] = mr
    elseif not seen[mr] then
      -- Keep candidate even if empty; scan skips missing dirs.
      seen[mr] = true
      ROOTS[#ROOTS + 1] = mr
    end
  end
end

local function isAudio(name)
  return type(name) == "string" and name:lower():match("%.dfpwm$") ~= nil
end

local function naturalKey(s)
  s = tostring(s or ""):lower()
  return s:gsub("(%d+)", function(n) return string.format("%010d", tonumber(n) or 0) end)
end

local function askYes(prompt)
  write(prompt .. " ")
  local ans = read()
  if type(ans) ~= "string" then return false end
  ans = ans:lower():gsub("^%s+", ""):gsub("%s+$", "")
  return ans == "y" or ans == "yes"
end

local function fit(s, w)
  s = tostring(s or "")
  if #s <= w then return s end
  if w <= 1 then return s:sub(1, w) end
  return s:sub(1, w - 1) .. "…"
end

local function isProtectedPath(path)
  if type(path) ~= "string" or path == "" then return true end
  local low = path:lower():gsub("\\", "/")
  if low == "sfx" or low:match("^sfx/") or low:match("/sfx/") then return true end
  if low == "rom" or low:match("^rom/") then return true end
  return false
end

local function parseArtistAlbum(folderName)
  local artist, album = folderName:match("^(.-) %- (.+)$")
  if artist and album and artist ~= "" and album ~= "" then
    return artist, album
  end
  return nil, nil
end

local function makeTrack(path, file, artistName, albumName)
  local size = fs.getSize(path)
  if size <= 0 then return nil end
  local title = file:gsub("%.[Dd][Ff][Pp][Ww][Mm]$", ""):gsub("_", " ")
  return {
    path = path,
    file = file,
    title = title,
    album = albumName,
    artist = artistName,
    key = naturalKey(title),
  }
end

------------------------------------------------------------------ library scan (mirrors jukebox.lua)
local function scan()
  local artistMap, artistList = {}, {}
  local seenPaths = {}

  local function getArtist(name)
    if not artistMap[name] then
      local a = { name = name, albums = {}, albumMap = {} }
      artistMap[name] = a
      artistList[#artistList + 1] = a
    end
    return artistMap[name]
  end

  local function getAlbum(artist, albumName)
    if not artist.albumMap[albumName] then
      local al = { name = albumName, tracks = {}, artist = artist.name }
      artist.albumMap[albumName] = al
      artist.albums[#artist.albums + 1] = al
    end
    return artist.albumMap[albumName]
  end

  local function addTrack(artistName, albumName, path, file)
    if seenPaths[path] or isProtectedPath(path) then return end
    local t = makeTrack(path, file, artistName, albumName)
    if not t then return end
    seenPaths[path] = true
    local al = getAlbum(getArtist(artistName), albumName)
    al.tracks[#al.tracks + 1] = t
  end

  local function addAudioInDir(dir, artistName, albumName)
    for _, file in ipairs(fs.list(dir)) do
      local fp = fs.combine(dir, file)
      if not fs.isDir(fp) and isAudio(file) then
        addTrack(artistName, albumName, fp, file)
      end
    end
  end

  local function scanArtistTree(root)
    for _, entry in ipairs(fs.list(root)) do
      local entryPath = fs.combine(root, entry)
      local low = entry:lower()
      if fs.isDir(entryPath) then
        if PROTECTED_TOP[low] then
          -- skip sfx / rom / lyrics-pack trees
        elseif low == "music" then
          scanArtistTree(entryPath)
        elseif low == "lyrics" then
          -- lyrics mirrors are not artists
        else
          local children = fs.list(entryPath)
          local hasAlbumDirs, hasDirectAudio = false, false
          for _, child in ipairs(children) do
            local cp = fs.combine(entryPath, child)
            if fs.isDir(cp) then
              hasAlbumDirs = true
            elseif isAudio(child) then
              hasDirectAudio = true
            end
          end

          local parsedArtist, parsedAlbum = parseArtistAlbum(entry)

          if hasDirectAudio and parsedArtist then
            addAudioInDir(entryPath, parsedArtist, parsedAlbum)
          elseif hasAlbumDirs then
            for _, albumName in ipairs(children) do
              local albumPath = fs.combine(entryPath, albumName)
              if fs.isDir(albumPath) then
                if albumName:lower() ~= "sfx" then
                  addAudioInDir(albumPath, entry, albumName)
                end
              elseif isAudio(albumName) then
                addTrack(entry, "Singles", albumPath, albumName)
              end
            end
          elseif hasDirectAudio then
            addAudioInDir(entryPath, "Various", entry)
          end
        end
      elseif isAudio(entry) then
        addTrack("Singles", "Singles", entryPath, entry)
      end
    end
  end

  local scanned = {}
  local function scanRoot(root)
    if scanned[root] or not (fs.exists(root) and fs.isDir(root)) then return end
    scanned[root] = true
    scanArtistTree(root)
  end

  for _, root in ipairs(ROOTS) do
    local parent = root:match("^(disk%d*)/music$") or (root == "disk/music" and "disk") or nil
    if parent then
      if fs.exists(parent) and fs.isDir(parent) then
        scanRoot(parent)
      else
        scanRoot(root)
      end
    else
      scanRoot(root)
    end
  end

  for _, ar in ipairs(artistList) do
    for _, al in ipairs(ar.albums) do
      table.sort(al.tracks, function(x, y)
        if x.key ~= y.key then return x.key < y.key end
        return x.path < y.path
      end)
    end
    table.sort(ar.albums, function(x, y)
      local kx, ky = naturalKey(x.name), naturalKey(y.name)
      if kx ~= ky then return kx < ky end
      return x.name < y.name
    end)
    ar.albumMap = nil
  end
  table.sort(artistList, function(x, y)
    local kx, ky = naturalKey(x.name), naturalKey(y.name)
    if kx ~= ky then return kx < ky end
    return x.name < y.name
  end)

  return artistList
end

------------------------------------------------------------------ lyrics candidates (beside + /lyrics mirrors)
local function lrcCandidates(track)
  if not track or not track.path then return {} end
  local path = track.path
  local dir = fs.getDir(path)
  local base = fs.getName(path):gsub("%.[Dd][Ff][Pp][Ww][Mm]$", "")
  local artist, album, title = track.artist or "", track.album or "", track.title or base
  local list = {
    fs.combine(dir, base .. ".lrc"),
    fs.combine("lyrics", artist, album, base .. ".lrc"),
    fs.combine("lyrics", artist, album, title .. ".lrc"),
  }
  local lyricMounts = listFloppyMounts()
  for _, m in ipairs(lyricMounts) do
    list[#list + 1] = fs.combine(m, "lyrics", artist, album, base .. ".lrc")
    list[#list + 1] = fs.combine(m, "lyrics", artist, album, title .. ".lrc")
  end
  for _, root in ipairs(ROOTS) do
    if path:sub(1, #root) == root and (path:sub(#root + 1, #root + 1) == "/" or path == root) then
      local rel = path:sub(#root + 2)
      if rel and rel ~= "" then
        local relLrc = rel:gsub("%.[Dd][Ff][Pp][Ww][Mm]$", ".lrc")
        list[#list + 1] = fs.combine("lyrics", relLrc)
        for _, m in ipairs(lyricMounts) do
          list[#list + 1] = fs.combine(m, "lyrics", relLrc)
        end
      end
    end
  end
  return list
end

------------------------------------------------------------------ delete helpers
local MOUNT_NAMES = { music = true, disk = true, disk1 = true, lyrics = true }
for _, m in ipairs(listFloppyMounts()) do MOUNT_NAMES[m] = true end

local function canDeleteFile(path)
  if isProtectedPath(path) then return false, "protected (sfx/rom)" end
  if not fs.exists(path) then return false, "missing" end
  if fs.isDir(path) then return false, "is directory" end
  return true
end

local function deleteFile(path, deleted, skipped)
  local ok, why = canDeleteFile(path)
  if not ok then
    if why ~= "missing" then
      skipped[#skipped + 1] = path .. " (" .. why .. ")"
    end
    return false
  end
  if opts.dryRun then
    print(modeTag() .. "would delete  " .. path)
    deleted[#deleted + 1] = path
    return true
  end
  local okDel, err = pcall(fs.delete, path)
  if okDel and not fs.exists(path) then
    print("deleted  " .. path)
    deleted[#deleted + 1] = path
    return true
  end
  skipped[#skipped + 1] = path .. " (" .. tostring(err or "delete failed") .. ")"
  return false
end

local function isEmptyDir(path)
  if not (fs.exists(path) and fs.isDir(path)) then return false end
  local ok, entries = pcall(fs.list, path)
  return ok and type(entries) == "table" and #entries == 0
end

local function pruneEmptyUp(startPath, deleted, skipped)
  local path = startPath
  while path and path ~= "" and path ~= "/" do
    local name = fs.getName(path)
    local low = name:lower()
    if MOUNT_NAMES[low] or PROTECTED_TOP[low] or low == "music" then
      break
    end
    if not isEmptyDir(path) then break end
    if opts.dryRun then
      print(modeTag() .. "would rmdir   " .. path)
      deleted[#deleted + 1] = path .. "/"
    else
      local ok, err = pcall(fs.delete, path)
      if ok and not fs.exists(path) then
        print("rmdir    " .. path)
        deleted[#deleted + 1] = path .. "/"
      else
        skipped[#skipped + 1] = path .. "/ (" .. tostring(err or "rmdir failed") .. ")"
        break
      end
    end
    path = fs.getDir(path)
  end
end

local function collectTrackFiles(track)
  local files = {}
  local seen = {}
  local function add(p)
    if not p or p == "" or seen[p] then return end
    seen[p] = true
    files[#files + 1] = p
  end
  add(track.path)
  for _, p in ipairs(lrcCandidates(track)) do
    if fs.exists(p) and not fs.isDir(p) then
      add(p)
    elseif opts.dryRun then
      -- only list mirrors that exist; dry-run still only shows real candidates
    end
  end
  return files
end

local function deleteTracks(tracks, alsoPruneAlbumDirs)
  local deleted, skipped = {}, {}
  local dirsToPrune = {}

  for _, track in ipairs(tracks) do
    local files = collectTrackFiles(track)
    for _, path in ipairs(files) do
      deleteFile(path, deleted, skipped)
    end
    if alsoPruneAlbumDirs then
      local dir = fs.getDir(track.path)
      if dir and dir ~= "" then dirsToPrune[dir] = true end
      -- prune empty lyrics album folders for this track too
      local artist, album = track.artist or "", track.album or ""
      if artist ~= "" and album ~= "" then
        dirsToPrune[fs.combine("lyrics", artist, album)] = true
        for _, m in ipairs(listFloppyMounts()) do
          dirsToPrune[fs.combine(m, "lyrics", artist, album)] = true
        end
      end
    end
  end

  -- deepest paths first so album dir goes before artist dir
  local ordered = {}
  for d in pairs(dirsToPrune) do ordered[#ordered + 1] = d end
  table.sort(ordered, function(a, b) return #a > #b end)
  for _, d in ipairs(ordered) do
    pruneEmptyUp(d, deleted, skipped)
  end

  return deleted, skipped
end

------------------------------------------------------------------ term UI (numbered pickers)
local function clear()
  term.clear()
  term.setCursorPos(1, 1)
end

local function header(title)
  clear()
  print(title)
  if opts.dryRun then
    print("MODE: dry-run (no files will be deleted)")
  else
    print("MODE: live — confirm with y before any delete")
  end
  print(string.rep("-", math.max(20, (#title or 20))))
end

local function pickFromList(title, items, labelFn, extraLines)
  local page = 1
  local pageSize = 12
  while true do
    header(title)
    if extraLines then
      for _, line in ipairs(extraLines) do print(line) end
      print("")
    end
    local total = #items
    if total == 0 then
      print("(empty)")
      print("")
      print("b = back   q = quit")
      write("> ")
      local ans = read()
      ans = type(ans) == "string" and ans:lower():gsub("^%s+", ""):gsub("%s+$", "") or ""
      if ans == "q" then return nil, "quit" end
      return nil, "back"
    end
    local pages = math.max(1, math.ceil(total / pageSize))
    if page > pages then page = pages end
    local start = (page - 1) * pageSize + 1
    local stop = math.min(total, start + pageSize - 1)
    print(string.format("Page %d/%d  (%d items)", page, pages, total))
    print("")
    for i = start, stop do
      print(string.format("  %2d) %s", i, fit(labelFn(items[i], i), 40)))
    end
    print("")
    print("number = pick   n/p = page   b = back   q = quit")
    write("> ")
    local ans = read()
    if type(ans) ~= "string" then return nil, "quit" end
    ans = ans:lower():gsub("^%s+", ""):gsub("%s+$", "")
    if ans == "q" or ans == "quit" then
      return nil, "quit"
    elseif ans == "b" or ans == "back" then
      return nil, "back"
    elseif ans == "n" or ans == "next" then
      page = math.min(pages, page + 1)
    elseif ans == "p" or ans == "prev" then
      page = math.max(1, page - 1)
    else
      local n = tonumber(ans)
      if n and n >= 1 and n <= total then
        return items[n], nil
      end
      print("Invalid choice.")
      sleep(0.6)
    end
  end
end

------------------------------------------------------------------ main loop
local function existingRoots()
  local out, seen = {}, {}
  for _, root in ipairs(ROOTS) do
    if not seen[root] and fs.exists(root) and fs.isDir(root) then
      seen[root] = true
      out[#out + 1] = root
    end
  end
  return out
end

print(modeTag() .. "delete-music — scanning library…")
local artists = scan()
if #artists == 0 then
  printError("No .dfpwm tracks found.")
  local existing = existingRoots()
  if #existing == 0 then
    print("No music mounts (music / disk / diskN). Attach floppies and retry.")
  else
    print("Mounted: " .. table.concat(existing, ", "))
    print("Layout: disk/Artist/Album/song.dfpwm  (or disk/music/... / music/...)")
  end
  return
end

do
  local nAlbums, nTracks = 0, 0
  for _, ar in ipairs(artists) do
    nAlbums = nAlbums + #ar.albums
    for _, al in ipairs(ar.albums) do
      nTracks = nTracks + #al.tracks
    end
  end
  print(string.format("Library: %d artists, %d albums, %d songs", #artists, nAlbums, nTracks))
  sleep(0.8)
end

while true do
  local artist, aWhy = pickFromList(
    "DELETE MUSIC — pick artist",
    artists,
    function(a) return a.name .. "  (" .. #a.albums .. " albums)" end
  )
  if aWhy == "quit" or (not artist and aWhy ~= "back") then break end
  if not artist then
    -- back at top → quit
    break
  end

  while true do
    local album, bWhy = pickFromList(
      "Artist: " .. artist.name,
      artist.albums,
      function(al) return al.name .. "  (" .. #al.tracks .. " songs)" end,
      { "Pick an album, then a song — or DELETE ALBUM." }
    )
    if bWhy == "quit" then
      artists = nil
      break
    end
    if not album then break end -- back to artists

    -- Song list with DELETE ALBUM as first action
    local songItems = { { __deleteAlbum = true } }
    for _, t in ipairs(album.tracks) do
      songItems[#songItems + 1] = t
    end

    local choice, cWhy = pickFromList(
      artist.name .. " / " .. album.name,
      songItems,
      function(item, idx)
        if item.__deleteAlbum then
          return "*** DELETE ALBUM (" .. #album.tracks .. " songs) ***"
        end
        return item.title
      end,
      { "Songs:" }
    )
    if cWhy == "quit" then
      artists = nil
      break
    end
    if not choice then
      -- back to albums
    elseif choice.__deleteAlbum then
      header("CONFIRM ALBUM DELETE")
      print(string.format("Artist : %s", artist.name))
      print(string.format("Album  : %s", album.name))
      print(string.format("Tracks : %d", #album.tracks))
      print("")
      for i, t in ipairs(album.tracks) do
        if i <= 8 then
          print("  - " .. fit(t.title, 40))
        end
      end
      if #album.tracks > 8 then
        print(string.format("  … +%d more", #album.tracks - 8))
      end
      print("")
      print("Also removes beside .lrc and /lyrics mirrors for those songs.")
      print("Empty album/artist folders are pruned afterward.")
      print("")
      if opts.dryRun then
        print(modeTag() .. "preview only — no confirm needed")
        print("Press enter…")
        read()
        local deleted, skipped = deleteTracks(album.tracks, true)
        print(string.format("%sDone. would-delete=%d  skipped=%d",
          modeTag(), #deleted, #skipped))
      else
        if askYes("Type y to DELETE this entire album:") then
          local deleted, skipped = deleteTracks(album.tracks, true)
          print(string.format("Done. deleted=%d  skipped=%d", #deleted, #skipped))
          -- rescan so UI stays accurate
          artists = scan()
          -- find refreshed artist or bail to top
          local found
          for _, ar in ipairs(artists) do
            if ar.name == artist.name then found = ar break end
          end
          artist = found
          if not artist then break end
          -- refresh album list by leaving to album picker
          print("Press enter…")
          read()
          break
        else
          print("Cancelled.")
          sleep(0.7)
        end
      end
      if opts.dryRun then
        -- stay on album after dry-run preview
      end
    else
      -- single song
      local track = choice
      header("CONFIRM SONG DELETE")
      print(string.format("Artist : %s", track.artist))
      print(string.format("Album  : %s", track.album))
      print(string.format("Song   : %s", track.title))
      print(string.format("Path   : %s", track.path))
      print("")
      print("Will remove:")
      local files = collectTrackFiles(track)
      for _, p in ipairs(files) do
        print("  - " .. p)
      end
      if #files == 1 then
        print("  (no .lrc / lyrics mirror found)")
      end
      print("")
      if opts.dryRun then
        print(modeTag() .. "preview only — no confirm needed")
        print("Press enter…")
        read()
        local deleted, skipped = deleteTracks({ track }, true)
        print(string.format("%sDone. would-delete=%d  skipped=%d",
          modeTag(), #deleted, #skipped))
        print("Press enter…")
        read()
      else
        if askYes("Type y to DELETE this song:") then
          local deleted, skipped = deleteTracks({ track }, true)
          print(string.format("Done. deleted=%d  skipped=%d", #deleted, #skipped))
          artists = scan()
          local foundArtist, foundAlbum
          for _, ar in ipairs(artists) do
            if ar.name == artist.name then
              foundArtist = ar
              for _, al in ipairs(ar.albums) do
                if al.name == album.name then foundAlbum = al break end
              end
              break
            end
          end
          artist = foundArtist
          album = foundAlbum
          print("Press enter…")
          read()
          if not artist then break end
          if not album then break end
        else
          print("Cancelled.")
          sleep(0.7)
        end
      end
    end

    if not artists then break end
  end

  if not artists then break end
end

clear()
print("delete-music finished.")
if opts.dryRun then
  print("Dry-run only — nothing was deleted.")
else
  print("Restart jukebox / press F5 there to refresh the library.")
end
