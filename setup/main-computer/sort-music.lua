--[[
  sort-music.lua — one-shot tidy for the CC:Tweaked jukebox (ATM10)

  Does all of:
    1) Music:  Artist - Album → Artist/Album ; bare Artist/*.dfpwm → Artist/Singles
               + cross-disk audio dedupe (ON with --apply; dry-run reports only)
                 Keep best .dfpwm+.lrc pair; prefer Artist/Album path; delete extras
    2) SFX:    create /sfx ; move loose root SFX*.dfpwm into it (not audio-deduped)
    3) Lyrics: match .lrc to library tracks, place beside songs, mirror /lyrics
               (spills across disks when full). Sources:
                 • recursive: every .lrc under computer + disk + diskN
                   (flat drops, nested leftovers, pack trees)
                 • match: exact basename, normalized (track # / punct), [ti]/[ar],
                   "Artist - Title.lrc", fuzzy contain
               + remove duplicate .lrc for the same .dfpwm

  Usage:
      sort-music                  -- dry-run preview (report only; no writes)
      sort-music --apply          -- nest + Singles + SFX + lyrics + dupe cleanup
      sort-music --apply --safe   -- nest/Singles/SFX/lyrics, never delete audio
      sort-music --apply --no-dedupe  -- same as --safe for audio deletes
      sort-music --apply --lyrics-only
      sort-music --apply --no-lyrics
      sort-music --apply --no-mirror

  Drop many .lrc files onto the computer or a disk root, then:
      sort-music --apply

  Flags: --apply  --dry-run  --dedupe  --no-dedupe  --safe  --lyrics-only
         --no-lyrics  --no-music  --no-sfx  --no-mirror  --help
]]

local RESERVE = 4096 -- bytes kept free per mount (Importer-style)

local rawArgs = { ... }
local opts = {
  apply = false,
  dryRun = true,
  doMusic = true,
  doSfx = true,
  doLyrics = true,
  mirror = true,
  dedupe = true, -- default ON; dry-run still only reports. Use --safe / --no-dedupe to skip.
  pack = nil,
}

for _, a in ipairs(rawArgs) do
  local lower = tostring(a):lower()
  if lower == "--apply" then
    opts.apply = true
    opts.dryRun = false
  elseif lower == "--dry-run" or lower == "--dryrun" then
    opts.dryRun = true
    opts.apply = false
  elseif lower == "--dedupe" then
    opts.dedupe = true
  elseif lower == "--safe" or lower == "--no-dedupe" or lower == "--nodedupe" then
    opts.dedupe = false
  elseif lower == "--lyrics-only" then
    opts.doLyrics = true
    opts.doMusic = false
    opts.doSfx = false
  elseif lower == "--no-lyrics" then
    opts.doLyrics = false
  elseif lower == "--no-music" then
    opts.doMusic = false
  elseif lower == "--no-sfx" then
    opts.doSfx = false
  elseif lower == "--no-mirror" then
    opts.mirror = false
  elseif lower == "--help" or lower == "-h" then
    print("sort-music [--apply] [packDir] [--lyrics-only] [--no-lyrics] [--no-mirror]")
    print("  Dry-run by default (no writes). --apply writes.")
    print("  Music nest + Singles + SFX + lyrics + audio dupe cleanup (default).")
    print("  Dupes: keep best .dfpwm+.lrc pair; prefer Artist/Album; delete extras.")
    print("  --safe / --no-dedupe skips audio deletes. --dedupe forces them on.")
    print("  Recursively finds .lrc; matches basename/tags/fuzzy; places beside .dfpwm.")
    print("  Drop flat .lrc on computer/disk root, then: sort-music --apply --lyrics-only")
    return
  elseif not a:match("^%-") then
    if not opts.pack then opts.pack = a end
  end
end

local function modeTag()
  return opts.dryRun and "[dry-run] " or ""
end

------------------------------------------------------------------ helpers
local function ensureDir(path)
  if path == "" or path == "/" then return true end
  if fs.exists(path) then return fs.isDir(path) end
  local parent = fs.getDir(path)
  if parent and parent ~= "" and parent ~= path then
    if not ensureDir(parent) then return false end
  end
  if opts.dryRun then return true end
  local ok = pcall(fs.makeDir, path)
  return ok and fs.isDir(path)
end

local function askYes(prompt)
  write(prompt .. " ")
  local ans = read()
  if type(ans) ~= "string" then return false end
  ans = ans:lower():gsub("^%s+", ""):gsub("%s+$", "")
  return ans == "y" or ans == "yes"
end

local function isAudio(name)
  return type(name) == "string" and name:lower():match("%.dfpwm$") ~= nil
end

local function isLrc(name)
  return type(name) == "string" and name:lower():match("%.lrc$") ~= nil
end

local function isSfxName(name)
  return type(name) == "string" and name:lower():match("^sfx.*%.dfpwm$") ~= nil
end

local function norm(s)
  s = tostring(s or ""):lower():gsub("_", " "):gsub("%s+", " ")
  return s:gsub("^%s+", ""):gsub("%s+$", "")
end

-- Strip punctuation for fuzzy/contain matches (keeps letters+digits+spaces)
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
  -- "Artist - Title" / "Artist - Album - Title" → also index title-only
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

local function freeSpace(mount)
  local ok, n = pcall(fs.getFreeSpace, mount)
  return (ok and type(n) == "number") and n or 0
end

local function fileSize(path)
  local ok, n = pcall(fs.getSize, path)
  return (ok and type(n) == "number") and n or 0
end

local function listFloppyMounts()
  local mounts = {}
  if fs.exists("disk") and fs.isDir("disk") then mounts[#mounts + 1] = "disk" end
  if fs.exists("disk1") and fs.isDir("disk1") then mounts[#mounts + 1] = "disk1" end
  for i = 2, 50 do
    local m = "disk" .. i
    if fs.exists(m) and fs.isDir(m) then mounts[#mounts + 1] = m end
  end
  return mounts
end

local function mountOf(path)
  path = tostring(path or ""):gsub("^/", "")
  local m = path:match("^(disk%d*)")
  if m and (path == m or path:sub(#m + 1, #m + 1) == "/") then
    return m
  end
  return ""
end

local function uniqueName(dir, name)
  local base, ext = name:match("^(.*)(%.[^%.]+)$")
  if not base then base, ext = name, "" end
  local cand = name
  local n = 2
  while fs.exists(fs.combine(dir, cand)) do
    cand = string.format("%s_%d%s", base, n, ext)
    n = n + 1
  end
  return cand
end

local function deletePath(path)
  if opts.dryRun then return true end
  local ok, err = pcall(fs.delete, path)
  return ok, err
end

local function movePath(src, dst)
  if opts.dryRun then return true, nil, dst end
  if src == dst then return true, nil, dst end
  local parent = fs.getDir(dst)
  if parent and parent ~= "" then ensureDir(parent) end
  if fs.exists(dst) then
    local dir = fs.getDir(dst)
    dst = fs.combine(dir, uniqueName(dir, fs.getName(dst)))
  end
  local ok, err = pcall(fs.move, src, dst)
  return ok, err, dst
end

local function copyTo(src, dst)
  if opts.dryRun then return true end
  if src == dst then return true end
  local parent = fs.getDir(dst)
  if parent and parent ~= "" then
    if not ensureDir(parent) then return false, "mkdir failed" end
  end
  if fs.exists(dst) then pcall(fs.delete, dst) end
  local ok, err = pcall(fs.copy, src, dst)
  return ok, err
end

local function isOutOfSpace(err)
  if type(err) ~= "string" then return false end
  local e = err:lower()
  return e:find("space", 1, true) or e:find("full", 1, true) or e:find("not enough", 1, true)
end

local function listDir(path)
  local ok, entries = pcall(fs.list, path)
  if ok and type(entries) == "table" then return entries end
  return {}
end

------------------------------------------------------------------ 1) SFX
local function runSfx()
  print(modeTag() .. "=== SFX → /sfx ===")
  local sfxDir = "sfx"
  if not fs.exists(sfxDir) then
    print("  create /sfx")
    ensureDir(sfxDir)
  end
  local moved = 0
  for _, name in ipairs(listDir("")) do
    if isSfxName(name) and not fs.isDir(name) then
      local dst = fs.combine(sfxDir, name)
      if fs.exists(dst) then
        dst = fs.combine(sfxDir, uniqueName(sfxDir, name))
      end
      print("  move " .. name .. " → " .. dst)
      local ok, err = movePath(name, dst)
      if ok then moved = moved + 1 else printError("  ! " .. tostring(err)) end
    end
  end
  print(string.format("  SFX moved: %d", moved))
end

------------------------------------------------------------------ 2) Music tidy + dedupe
local function musicContainers()
  local roots = { "music" }
  if fs.exists("disk") then roots[#roots + 1] = "disk/music" end
  if fs.exists("disk1") then roots[#roots + 1] = "disk1/music" end
  for i = 2, 50 do
    local m = "disk" .. i
    if fs.exists(m) then roots[#roots + 1] = m .. "/music" end
  end
  local out = {}
  for _, r in ipairs(roots) do
    if fs.exists(r) and fs.isDir(r) then out[#out + 1] = r end
  end
  return out
end

-- Unique library roots for walks. Prefer mount once (scanArtistTree recurses into
-- music/) so disk + disk/music are not both scanned (that used to self-delete).
local function uniqueLibraryRoots()
  local out, seen = {}, {}
  local function add(r)
    if not r or r == "" or seen[r] then return end
    if fs.exists(r) and fs.isDir(r) then
      seen[r] = true
      out[#out + 1] = r
    end
  end
  add("music")
  if fs.exists("disk") and fs.isDir("disk") then add("disk") end
  if fs.exists("disk1") and fs.isDir("disk1") then add("disk1") end
  for i = 2, 50 do
    local m = "disk" .. i
    if fs.exists(m) and fs.isDir(m) then add(m) end
  end
  return out
end

local function isWeakArtist(name)
  local n = norm(name)
  return n == "" or n == "singles" or n == "various" or n == "unknown"
end

local function isWeakAlbum(name)
  local n = norm(name)
  return n == "" or n == "singles" or n == "unknown"
end

local function hasBesideLrc(audioPath)
  local file = fs.getName(audioPath)
  if not isAudio(file) then return false end
  local base = file:gsub("%.[Dd][Ff][Pp][Ww][Mm]$", "")
  local beside = fs.combine(fs.getDir(audioPath), base .. ".lrc")
  return fs.exists(beside) and not fs.isDir(beside)
end

-- Higher = better keeper. Prefer complete .dfpwm+.lrc pairs, then Artist/Album paths.
local function audioKeepScore(c)
  local score = 0
  if c.hasLrc then score = score + 10000 end
  if not isWeakArtist(c.artist) and not isWeakAlbum(c.album) then
    score = score + 1000 -- canonical Artist/Album
  elseif not isWeakArtist(c.artist) then
    score = score + 500 -- Artist/Singles
  end
  local dir = fs.getDir(c.path) or ""
  if dir:find("/music/", 1, true) or dir:match("^music/") or dir == "music"
      or dir:match("^disk%d*/music") then
    score = score + 100
  end
  -- Deeper structured paths beat flat disk-root drops
  local depth = 0
  for _ in dir:gmatch("[^/]+") do depth = depth + 1 end
  score = score + math.min(depth, 6) * 10
  -- Larger file as weak tiebreaker
  score = score + math.min(c.size or 0, 5000000) / 5000000
  return score
end

local function betterAudio(a, b)
  local sa, sb = audioKeepScore(a), audioKeepScore(b)
  if sa ~= sb then return sa > sb end
  if a.size ~= b.size then return a.size > b.size end
  return a.path < b.path
end

local function runMusic()
  print(modeTag() .. "=== Music tidy (Artist/Album + Singles"
    .. (opts.dedupe and " + dupe cleanup) ===" or "; audio dedupe off) ==="))
  local movedFolders, movedSingles, deduped = 0, 0, 0

  for _, root in ipairs(musicContainers()) do
    print("  root " .. root)
    for _, entry in ipairs(listDir(root)) do
      local entryPath = fs.combine(root, entry)
      if fs.isDir(entryPath) then
        local artist, album = parseArtistAlbum(entry)
        if artist then
          local destDir = fs.combine(root, artist, album)
          print("  nest  " .. entryPath .. " → " .. destDir)
          if not opts.dryRun then
            ensureDir(fs.combine(root, artist))
            ensureDir(destDir)
            for _, f in ipairs(listDir(entryPath)) do
              local src = fs.combine(entryPath, f)
              local ok, err = movePath(src, fs.combine(destDir, f))
              if not ok then printError("    ! " .. tostring(err)) end
            end
            if #listDir(entryPath) == 0 then pcall(fs.delete, entryPath) end
          end
          movedFolders = movedFolders + 1
        else
          local hasAudio = false
          for _, child in ipairs(listDir(entryPath)) do
            local cp = fs.combine(entryPath, child)
            if not fs.isDir(cp) and isAudio(child) then hasAudio = true end
          end
          if hasAudio then
            local singles = fs.combine(entryPath, "Singles")
            print("  singles " .. entryPath .. "/*.dfpwm → " .. singles)
            if not opts.dryRun then
              ensureDir(singles)
              for _, child in ipairs(listDir(entryPath)) do
                local cp = fs.combine(entryPath, child)
                if not fs.isDir(cp) and isAudio(child) then
                  local ok, err = movePath(cp, fs.combine(singles, child))
                  if ok then movedSingles = movedSingles + 1
                  else printError("    ! " .. tostring(err)) end
                end
              end
            else
              for _, child in ipairs(listDir(entryPath)) do
                local cp = fs.combine(entryPath, child)
                if not fs.isDir(cp) and isAudio(child) then
                  movedSingles = movedSingles + 1
                end
              end
            end
          end
        end
      end
    end
  end

  if not opts.dedupe then
    print("  audio dedupe skipped (--safe / --no-dedupe)")
    print(string.format(
      "  nested folders: %d  singles files: %d  audio deduped: 0",
      movedFolders, movedSingles
    ))
    return
  end

  -- Collect every .dfpwm under library roots once (seenPaths guards self-delete).
  -- Group same song across disks/spots; keep best pair / Artist/Album; delete rest.
  local candidates, seenPaths = {}, {}

  local function collectAudio(path, file, artistName, albumName)
    if seenPaths[path] or not isAudio(file) then return end
    seenPaths[path] = true
    local sk = songKeys(file)[1] or norm(file:gsub("%.[Dd][Ff][Pp][Ww][Mm]$", ""))
    if sk == "" then return end
    candidates[#candidates + 1] = {
      path = path,
      name = file,
      artist = artistName or "Singles",
      album = albumName or "Singles",
      songKey = sk,
      size = fileSize(path),
      hasLrc = hasBesideLrc(path),
    }
  end

  local function walkAlbum(dir, artistName, albumName)
    for _, file in ipairs(listDir(dir)) do
      local fp = fs.combine(dir, file)
      if not fs.isDir(fp) and isAudio(file) then
        collectAudio(fp, file, artistName, albumName)
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
            walkAlbum(entryPath, parsedArtist, parsedAlbum)
          elseif hasAlbumDirs then
            for _, albumName in ipairs(children) do
              local albumPath = fs.combine(entryPath, albumName)
              if fs.isDir(albumPath) then
                walkAlbum(albumPath, entry, albumName)
              elseif isAudio(albumName) then
                collectAudio(albumPath, albumName, entry, "Singles")
              end
            end
          elseif hasDirectAudio then
            walkAlbum(entryPath, "Various", entry)
          end
        end
      elseif isAudio(entry) then
        collectAudio(entryPath, entry, "Singles", "Singles")
      end
    end
  end

  for _, root in ipairs(uniqueLibraryRoots()) do
    scanArtistTree(root)
  end

  -- Group by song key, then split by real artist (weak artists merge into a unique match).
  local bySong = {}
  for _, c in ipairs(candidates) do
    local list = bySong[c.songKey]
    if not list then list = {} bySong[c.songKey] = list end
    list[#list + 1] = c
  end

  local function resolveGroup(group)
    if not group or #group < 2 then return end
    -- Unique paths only; skip already-removed files after earlier resolves
    local uniq, seen = {}, {}
    for _, c in ipairs(group) do
      if not seen[c.path] then
        seen[c.path] = true
        if opts.dryRun or fs.exists(c.path) then
          uniq[#uniq + 1] = c
        end
      end
    end
    if #uniq < 2 then return end

    table.sort(uniq, betterAudio)
    local keep = uniq[1]
    local why = keep.hasLrc and "pair+lrc" or "canonical"
    for i = 2, #uniq do
      local loser = uniq[i]
      if loser.path ~= keep.path then
        print(string.format(
          "  dedupe audio %s (keep %s [%s])",
          loser.path, keep.path, why
        ))
        local ok, err = deletePath(loser.path)
        if ok then
          deduped = deduped + 1
          -- Drop orphan beside-.lrc on the loser so it doesn't linger without audio
          if loser.hasLrc then
            local base = loser.name:gsub("%.[Dd][Ff][Pp][Ww][Mm]$", "")
            local beside = fs.combine(fs.getDir(loser.path), base .. ".lrc")
            local keepBeside = fs.combine(
              fs.getDir(keep.path),
              keep.name:gsub("%.[Dd][Ff][Pp][Ww][Mm]$", "") .. ".lrc"
            )
            if beside ~= keepBeside and fs.exists(beside) and not fs.isDir(beside) then
              print("  dedupe orphan-lrc " .. beside)
              deletePath(beside)
            end
          end
        else
          printError("  ! " .. tostring(err))
        end
      end
    end
  end

  for _, group in pairs(bySong) do
    if #group >= 2 then
      local byArtist, weak = {}, {}
      for _, c in ipairs(group) do
        if isWeakArtist(c.artist) then
          weak[#weak + 1] = c
        else
          local a = norm(c.artist)
          byArtist[a] = byArtist[a] or {}
          byArtist[a][#byArtist[a] + 1] = c
        end
      end
      local artistKeys = {}
      for a in pairs(byArtist) do artistKeys[#artistKeys + 1] = a end

      if #artistKeys == 0 then
        -- Only weak/flat copies of the same song key
        resolveGroup(group)
      elseif #artistKeys == 1 then
        -- Merge flat/Singles orphans into the one real artist
        local a = artistKeys[1]
        for _, c in ipairs(weak) do byArtist[a][#byArtist[a] + 1] = c end
        resolveGroup(byArtist[a])
      else
        -- Multiple real artists share a title — dedupe within each artist.
        -- Fold each flat/orphan into the strongest Artist/Album (or paired) bucket.
        for _, w in ipairs(weak) do
          local bestA, bestScore = nil, -1
          for _, a in ipairs(artistKeys) do
            for _, c in ipairs(byArtist[a]) do
              local sc = audioKeepScore(c)
              if sc > bestScore then bestScore, bestA = sc, a end
            end
          end
          if bestA and bestScore >= 1000 then
            byArtist[bestA][#byArtist[bestA] + 1] = w
          end
        end
        for _, a in ipairs(artistKeys) do
          resolveGroup(byArtist[a])
        end
      end
    end
  end

  print(string.format(
    "  nested folders: %d  singles files: %d  audio scanned: %d  audio deduped: %d",
    movedFolders, movedSingles, #candidates, deduped
  ))
end

------------------------------------------------------------------ 3) Lyrics
local function findPackSources()
  local order = { "disk/lyrics", "disk1/lyrics" }
  for i = 2, 50 do order[#order + 1] = ("disk%d/lyrics"):format(i) end
  order[#order + 1] = "lyrics-pack"
  order[#order + 1] = "lyrics"
  local out = {}
  for _, c in ipairs(order) do
    if fs.exists(c) and fs.isDir(c) then out[#out + 1] = c end
  end
  return out
end

-- Parse [ar:], [ti:], [al:] / [ar: ] tags; also "Artist - Title" filenames
local function parseLrcMeta(path, fileBase)
  local artist, album, title
  local f = fs.open(path, "r")
  if f then
    -- only need the header; stop after a few timed lines
    for _ = 1, 40 do
      local line = f.readLine()
      if not line then break end
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
    f.close()
  end

  local base = fileBase or fs.getName(path):gsub("%.[Ll][Rr][Cc]$", "")
  -- Filename patterns: Artist - Album - Title  OR  Artist - Title
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

-- Recursively find ALL .lrc under computer + mounted disks (CC lists disks under "").
-- Classifies pack-tree (lyrics/.../Artist/Album/file) vs flat/orphan drops.
local function collectAllLrcs(alreadyBeside)
  local all, orphans, packTree = {}, {}, {}
  local seen = {}
  local skipDir = {
    rom = true, bios = true, sfx = true,
  }

  local function consider(path, relParts)
    if seen[path] then return end
    seen[path] = true
    local name = fs.getName(path)
    if not isLrc(name) then return end
    local base = name:gsub("%.[Ll][Rr][Cc]$", "")
    local artist, album, title, rawBase = parseLrcMeta(path, base)
    local entry = {
      path = path,
      base = rawBase,
      artist = artist,
      album = album,
      title = title,
      beside = alreadyBeside[path] == true,
      pack = false,
    }

    -- Path-shaped pack: …/lyrics/Artist/Album/Song.lrc (or Artist/Song.lrc)
    local lyricsIdx
    for i, part in ipairs(relParts) do
      if part:lower() == "lyrics" or part:lower() == "lyrics-pack" then
        lyricsIdx = i
        break
      end
    end
    if lyricsIdx and #relParts >= lyricsIdx + 2 then
      local pathArtist = relParts[lyricsIdx + 1]
      local pathAlbum
      if #relParts >= lyricsIdx + 3 then
        pathAlbum = table.concat(relParts, "/", lyricsIdx + 2, #relParts - 1)
      else
        pathAlbum = "Singles"
      end
      entry.pack = true
      entry.pathArtist = pathArtist
      entry.pathAlbum = pathAlbum
      if not entry.artist or entry.artist == "" then entry.artist = pathArtist end
      if not entry.album or entry.album == "" then entry.album = pathAlbum end
      packTree[#packTree + 1] = entry
    else
      entry.orphan = true
      orphans[#orphans + 1] = entry
    end
    all[#all + 1] = entry
  end

  local function walk(dir, relParts, depth)
    if depth > 48 then return end
    local listing = dir == "" and "" or dir
    if dir ~= "" and not (fs.exists(dir) and fs.isDir(dir)) then return end
    for _, name in ipairs(listDir(listing)) do
      local fp = dir == "" and name or fs.combine(dir, name)
      local okDir, isDir = pcall(fs.isDir, fp)
      if okDir and isDir then
        local low = name:lower()
        if not skipDir[low] then
          local nextRel = {}
          for i = 1, #relParts do nextRel[i] = relParts[i] end
          nextRel[#nextRel + 1] = name
          walk(fp, nextRel, depth + 1)
        end
      elseif isLrc(name) then
        local fileRel = {}
        for i = 1, #relParts do fileRel[i] = relParts[i] end
        fileRel[#fileRel + 1] = name
        consider(fp, fileRel)
      end
    end
  end

  -- "" covers computer root and every mounted diskN (CC mounts appear as root dirs)
  walk("", {}, 0)
  return all, orphans, packTree
end

local function pickLyricsRoot(need, bad, preferMount)
  bad = bad or {}
  local candidates = {}

  local function consider(mount, lyricsRoot, priority)
    if bad[lyricsRoot] then return end
    if preferMount and mount == preferMount then priority = priority - 10 end
    local mpath = (mount == "" and "/") or mount
    local free = freeSpace(mpath)
    if free >= need then
      candidates[#candidates + 1] = {
        mount = mount, root = lyricsRoot, pri = priority, free = free,
      }
    end
  end

  consider("", "lyrics", 1)
  for _, m in ipairs(listFloppyMounts()) do
    local lr = fs.combine(m, "lyrics")
    if fs.exists(lr) and fs.isDir(lr) then
      consider(m, lr, 2)
    else
      consider(m, lr, 3)
    end
  end

  table.sort(candidates, function(a, b)
    if a.pri ~= b.pri then return a.pri < b.pri end
    return a.free > b.free
  end)

  for _, c in ipairs(candidates) do
    if fs.exists(c.root) and fs.isDir(c.root) then
      return c.root, c.mount
    end
    if opts.dryRun then return c.root, c.mount end
    -- Computer /lyrics: create automatically so flat-drop --apply isn't blocked on a prompt
    if c.root == "lyrics" then
      if ensureDir(c.root) then
        print("  created " .. c.root)
        return c.root, c.mount
      end
      bad[c.root] = true
    elseif askYes("Create " .. c.root .. " for lyrics spill? (y/n)") then
      if ensureDir(c.root) then
        print("  created " .. c.root)
        return c.root, c.mount
      end
      bad[c.root] = true
    else
      bad[c.root] = true
    end
  end
  return nil
end

local function copyLyricsSpilling(src, relArtistAlbumFile, preferMount)
  local need = fileSize(src) + RESERVE
  local bad = {}
  for _ = 1, 12 do
    local root, mount = pickLyricsRoot(need, bad, preferMount)
    if not root then return false, "no disk with room for lyrics", false end
    local dst = fs.combine(root, relArtistAlbumFile)
    if src == dst then return true, dst, mount ~= "" end
    local mpath = (mount == "" and "/") or mount
    if (not opts.dryRun) and freeSpace(mpath) < need then
      bad[root] = true
    else
      local ok, err = copyTo(src, dst)
      if ok then return true, dst, mount ~= "" end
      if isOutOfSpace(tostring(err or "")) then
        print("  spill: " .. root .. " full — trying next disk")
        bad[root] = true
      else
        return false, err or "copy failed", false
      end
    end
  end
  return false, "spill exhausted", false
end

local function runLyrics()
  print(modeTag() .. "=== Lyrics (recursive find + match + beside + mirror + dedupe) ===")

  -- Zip: CC has no built-in unzip — skip unless an unzip program already exists
  for _, zname in ipairs({ "lyrics.zip", "pack.zip", "lrc.zip" }) do
    if fs.exists(zname) and not fs.isDir(zname) then
      if fs.exists("unzip") or fs.exists("unzip.lua") then
        print("  found " .. zname .. " — running unzip")
        if not opts.dryRun then pcall(shell.run, "unzip", zname) end
      else
        print("  note: " .. zname .. " present but no unzip program — drop loose .lrc files instead")
      end
    end
  end

  ------------------------------------------------------------------ scan tracks
  local tracks, seenPaths = {}, {}
  local alreadyBeside = {} -- path of .lrc already next to a .dfpwm

  local function addTrack(path, file, artistName, albumName)
    if seenPaths[path] or not isAudio(file) then return end
    seenPaths[path] = true
    local base = file:gsub("%.[Dd][Ff][Pp][Ww][Mm]$", "")
    local beside = fs.combine(fs.getDir(path), base .. ".lrc")
    if fs.exists(beside) and not fs.isDir(beside) then
      alreadyBeside[beside] = true
    end
    tracks[#tracks + 1] = {
      path = path, artist = artistName, album = albumName,
      title = base:gsub("_", " "), base = base,
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

  for _, root in ipairs(uniqueLibraryRoots()) do
    scanArtistTree(root)
  end
  print(string.format("  tracks: %d", #tracks))

  ------------------------------------------------------------------ index every .lrc found recursively
  local exact, byArtistSong, bySong = {}, {}, {}
  local lrcLabel = {} -- path → display name for missing samples
  local pathToEntry = {}

  local function bagAdd(bag, key, srcPath)
    local list = bag[key]
    if not list then list = {} bag[key] = list end
    for _, p in ipairs(list) do if p == srcPath then return end end
    list[#list + 1] = srcPath
  end

  local function indexPut(artist, album, songBase, srcPath)
    local a, al = norm(artist), norm(album)
    if a == "" then a = "singles" end
    if al == "" then al = "singles" end
    exact[a] = exact[a] or {}
    exact[a][al] = exact[a][al] or {}
    byArtistSong[a] = byArtistSong[a] or {}
    for _, sk in ipairs(songKeys(songBase)) do
      if not exact[a][al][sk] then exact[a][al][sk] = srcPath end
      bagAdd(byArtistSong[a], sk, srcPath)
      bagAdd(bySong, sk, srcPath)
    end
  end

  -- Optional explicit pack dir still walked via collectAllLrcs if under computer;
  -- if opts.pack is outside normal roots, walk it too.
  if opts.pack and opts.pack ~= "" then
    if not (fs.exists(opts.pack) and fs.isDir(opts.pack)) then
      print("  pack dir missing: " .. opts.pack)
    end
  end

  local allLrcs, orphans, packTree = collectAllLrcs(alreadyBeside)
  -- Also index explicit pack path if it wasn't under the computer walk
  if opts.pack and opts.pack ~= "" and fs.exists(opts.pack) and fs.isDir(opts.pack) then
    local function walkExtra(dir, parts, depth)
      if depth > 48 then return end
      for _, name in ipairs(listDir(dir)) do
        local fp = fs.combine(dir, name)
        if fs.isDir(fp) then
          local np = {}
          for i = 1, #parts do np[i] = parts[i] end
          np[#np + 1] = name
          walkExtra(fp, np, depth + 1)
        elseif isLrc(name) then
          local base = name:gsub("%.[Ll][Rr][Cc]$", "")
          local artist, album, title = parseLrcMeta(fp, base)
          if #parts >= 2 then
            artist = artist or parts[1]
            album = album or table.concat(parts, "/", 2, #parts)
          elseif #parts == 1 then
            artist = artist or parts[1]
            album = album or "Singles"
          end
          local entry = {
            path = fp, base = base, artist = artist, album = album or "Singles",
            title = title or base, pack = #parts >= 1, orphan = #parts < 1,
          }
          allLrcs[#allLrcs + 1] = entry
          if entry.pack then packTree[#packTree + 1] = entry
          else orphans[#orphans + 1] = entry end
        end
      end
    end
    walkExtra(opts.pack, {}, 0)
  end

  print(string.format(
    "  found .lrc: %d  (pack-tree=%d orphan/flat=%d already-beside=%d)",
    #allLrcs, #packTree, #orphans, (function()
      local n = 0
      for _ in pairs(alreadyBeside) do n = n + 1 end
      return n
    end)()
  ))

  for _, e in ipairs(allLrcs) do
    pathToEntry[e.path] = e
    lrcLabel[e.path] = e.base or fs.getName(e.path)
    local songBase = e.title or e.base
    if e.pack then
      indexPut(e.pathArtist or e.artist or "Singles", e.pathAlbum or e.album or "Singles", songBase, e.path)
      -- also index filename keys in case title tag differs from file base
      for _, sk in ipairs(songKeys(e.base)) do bagAdd(bySong, sk, e.path) end
    else
      indexPut(e.artist or "Singles", e.album or "Singles", songBase, e.path)
      for _, sk in ipairs(songKeys(e.base)) do bagAdd(bySong, sk, e.path) end
      -- Artist - Title filename: index under parsed artist as well
      if e.artist and e.title and e.artist ~= e.title then
        indexPut(e.artist, e.album or "Singles", e.title, e.path)
      end
    end
  end

  if #allLrcs == 0 then
    print("No .lrc sources found anywhere under computer/disks.")
    print("Windows tip: re-drop ALL .lrc from the pack (or Music CC) as flat files")
    print("  (CC can’t drop folders), then: sort-music --apply --lyrics-only")
    if not fs.exists("lyrics") then
      if opts.dryRun then
        print("  would create /lyrics inbox")
      else
        ensureDir("lyrics")
        print("  Created /lyrics — you can also drop flat .lrc there.")
      end
    end
    return
  end

  if #tracks == 0 then
    printError("No .dfpwm library on this computer — cannot place lyrics beside songs.")
    print("Restore music (or re-import), then: sort-music --apply --lyrics-only")
    print(string.format("  (%d .lrc source(s) waiting)", #allLrcs))
    return
  end

  -- Ensure computer /lyrics exists up front so mirror writes don't stall on prompts
  if opts.mirror and not fs.exists("lyrics") then
    if opts.dryRun then
      print("  would create /lyrics")
    else
      ensureDir("lyrics")
      print("  created /lyrics")
    end
  end

  ------------------------------------------------------------------ lookup (exact → artist/song → song → fuzzy contain)
  local function pickFromList(list, artist)
    if not list or #list == 0 then return nil end
    if #list == 1 then return list[1] end
    local a = norm(artist)
    if a ~= "" then
      for _, p in ipairs(list) do
        if norm(p):find(a, 1, true) then return p end
        local e = pathToEntry[p]
        if e and e.artist and norm(e.artist) == a then return p end
        if e and e.pathArtist and norm(e.pathArtist) == a then return p end
      end
    end
    return list[1]
  end

  local function fuzzyContain(keys, artist)
    -- Prefer unique contain matches; require min length to avoid junk hits
    local scores = {} -- path → best score
    for sk, list in pairs(bySong) do
      if #sk >= 5 then
        for _, tk in ipairs(keys) do
          if #tk >= 5 then
            local hit = false
            if sk == tk then
              hit = true
            elseif #sk >= #tk and sk:find(tk, 1, true) then
              hit = true
            elseif #tk >= #sk and tk:find(sk, 1, true) then
              hit = true
            end
            if hit then
              local score = (sk == tk) and 100 or math.min(#sk, #tk)
              for _, p in ipairs(list) do
                if not scores[p] or score > scores[p] then scores[p] = score end
              end
            end
          end
        end
      end
    end
    local best, bestScore, ambiguous = nil, 0, false
    for p, sc in pairs(scores) do
      if sc > bestScore then
        best, bestScore, ambiguous = p, sc, false
      elseif sc == bestScore and p ~= best then
        -- tie: prefer artist match
        local a = norm(artist)
        local e1, e2 = pathToEntry[best], pathToEntry[p]
        local b1 = a ~= "" and e1 and (norm(e1.artist or "") == a or norm(e1.pathArtist or "") == a)
        local b2 = a ~= "" and e2 and (norm(e2.artist or "") == a or norm(e2.pathArtist or "") == a)
        if b2 and not b1 then best = p ambiguous = false
        elseif b1 and not b2 then -- keep best
        else ambiguous = true end
      end
    end
    if ambiguous and bestScore < 100 then return nil end
    return best
  end

  local function nearestLrcName(keys)
    local bestName, bestScore = nil, 0
    for sk, list in pairs(bySong) do
      if #sk >= 4 and list[1] then
        for _, tk in ipairs(keys) do
          if #tk >= 4 then
            local sc = 0
            if sk == tk then sc = 100
            elseif sk:find(tk, 1, true) or tk:find(sk, 1, true) then
              sc = math.min(#sk, #tk)
            end
            if sc > bestScore then
              bestScore = sc
              bestName = lrcLabel[list[1]] or fs.getName(list[1])
            end
          end
        end
      end
    end
    return bestName, bestScore
  end

  local function lookup(artist, album, title)
    local a, al, keys = norm(artist), norm(album), songKeys(title)
    local function fromExact(aa, alb)
      local node = exact[aa] and exact[aa][alb]
      if not node then return nil end
      for _, sk in ipairs(keys) do if node[sk] then return node[sk] end end
    end
    local hit = fromExact(a, al)
    if hit then return hit end
    hit = fromExact(a, "singles")
    if hit then return hit end
    local bag = byArtistSong[a]
    if bag then
      for _, sk in ipairs(keys) do
        local list = bag[sk]
        if list and #list >= 1 then return pickFromList(list, artist) end
      end
    end
    -- song-name only (flat drops / basename)
    for _, sk in ipairs(keys) do
      local list = bySong[sk]
      if list and #list >= 1 then return pickFromList(list, artist) end
    end
    -- fuzzy contain last
    return fuzzyContain(keys, artist)
  end

  ------------------------------------------------------------------ place (prefer beside .dfpwm on that song's disk)
  local matched, missing, copied, errors, spilled = 0, 0, 0, 0, 0
  local lrcDeduped = 0
  local missingList = {}
  local consumedSources = {} -- lrc path → true after successful place
  local usedByTrack = {} -- lrc path → track base

  print(opts.mirror and "  mirror: on (spills across disks)" or "  mirror: off")

  for _, t in ipairs(tracks) do
    local src = lookup(t.artist, t.album, t.base) or lookup(t.artist, t.album, t.title)
    if not src then
      missing = missing + 1
      if #missingList < 30 then
        local near, sc = nearestLrcName(songKeys(t.base))
        local trackName = t.artist .. " / " .. t.album .. " / " .. t.base
        if near and sc and sc >= 4 then
          missingList[#missingList + 1] = trackName .. "  ↔  nearest .lrc: " .. near
        else
          missingList[#missingList + 1] = trackName .. "  ↔  (no .lrc)"
        end
      end
    else
      matched = matched + 1
      usedByTrack[src] = t.base
      local wrote = false
      local beside = fs.combine(fs.getDir(t.path), t.base .. ".lrc")

      if src ~= beside then
        local need = fileSize(src) + RESERVE
        local m = mountOf(t.path)
        local mpath = m == "" and "/" or m
        if freeSpace(mpath) < need and not opts.dryRun then
          printError("  ! beside full on " .. (m == "" and "computer" or m) .. ": " .. beside)
          errors = errors + 1
        else
          local ok, err = copyTo(src, beside)
          if ok then
            wrote = true
            print((opts.dryRun and "  ~ " or "  + ") .. "beside " .. beside)
            consumedSources[src] = true
          else
            errors = errors + 1
            printError("  ! " .. beside .. " — " .. tostring(err))
          end
        end
      else
        consumedSources[src] = true
        wrote = true -- already in the right place
      end

      if opts.mirror then
        local rel = fs.combine(t.artist, t.album, t.base .. ".lrc")
        local ok, dstOrErr, didSpill = copyLyricsSpilling(src, rel, mountOf(t.path))
        if ok then
          wrote = true
          if didSpill then spilled = spilled + 1 end
          print((opts.dryRun and "  ~ " or "  + ") .. "lyrics " .. tostring(dstOrErr))
          consumedSources[src] = true
        else
          errors = errors + 1
          printError("  ! mirror " .. rel .. " — " .. tostring(dstOrErr))
        end
      end

      if wrote then copied = copied + 1 end
    end
  end

  -- Delete consumed orphan/flat drops after successful place (never delete beside/pack trees)
  local orphanRemoved = 0
  for _, o in ipairs(orphans) do
    if consumedSources[o.path] and fs.exists(o.path) and not alreadyBeside[o.path] then
      local dir = fs.getDir(o.path)
      local drop = (dir == "" or dir == "inbox" or dir == "drops" or dir == "lyrics-inbox"
        or dir == "lyrics" or dir:match("^disk%d*$") or dir:match("^disk%d*/lyrics$")
        or dir:match("^disk%d*/inbox$"))
      if drop then
        print("  cleanup drop " .. o.path)
        if deletePath(o.path) then orphanRemoved = orphanRemoved + 1 end
      end
    end
  end

  -- Unmatched .lrc samples (found but not used by any track; ignore mirror/beside dupes)
  local usedKeys = {}
  for _, base in pairs(usedByTrack) do
    for _, sk in ipairs(songKeys(base)) do usedKeys[sk] = true end
  end
  local unmatchedLrc, unmatchedSamples = 0, {}
  for _, e in ipairs(allLrcs) do
    if not usedByTrack[e.path] and not alreadyBeside[e.path] then
      local covered = false
      for _, sk in ipairs(songKeys(e.title or e.base)) do
        if usedKeys[sk] then covered = true break end
      end
      if not covered then
        for _, sk in ipairs(songKeys(e.base)) do
          if usedKeys[sk] then covered = true break end
        end
      end
      if not covered then
        unmatchedLrc = unmatchedLrc + 1
        if #unmatchedSamples < 20 then
          unmatchedSamples[#unmatchedSamples + 1] = (e.base or "?") .. "  (" .. e.path .. ")"
        end
      end
    end
  end

  -- Dedupe .lrc beside each track + under lyrics mirrors (same song → one file)
  local function dedupeLrcInDir(dir)
    if not (fs.exists(dir) and fs.isDir(dir)) then return 0 end
    local byKey = {}
    local n = 0
    for _, file in ipairs(listDir(dir)) do
      local fp = fs.combine(dir, file)
      if not fs.isDir(fp) and isLrc(file) then
        local key = songKeys(file)[1]
        byKey[key] = byKey[key] or {}
        byKey[key][#byKey[key] + 1] = { path = fp, size = fileSize(fp) }
      end
    end
    for _, group in pairs(byKey) do
      if #group > 1 then
        table.sort(group, function(a, b)
          if a.size ~= b.size then return a.size > b.size end
          return a.path < b.path
        end)
        for i = 2, #group do
          print("  dedupe lrc " .. group[i].path)
          if deletePath(group[i].path) then n = n + 1 end
        end
      end
    end
    return n
  end

  for _, t in ipairs(tracks) do
    lrcDeduped = lrcDeduped + dedupeLrcInDir(fs.getDir(t.path))
  end
  for _, pr in ipairs(findPackSources()) do
    for _, artist in ipairs(listDir(pr)) do
      local ap = fs.combine(pr, artist)
      if fs.isDir(ap) then
        for _, album in ipairs(listDir(ap)) do
          local alp = fs.combine(ap, album)
          if fs.isDir(alp) then
            lrcDeduped = lrcDeduped + dedupeLrcInDir(alp)
          end
        end
        lrcDeduped = lrcDeduped + dedupeLrcInDir(ap)
      end
    end
    lrcDeduped = lrcDeduped + dedupeLrcInDir(pr)
  end

  print(string.format(
    "  lyrics: found=%d matched=%d missing=%d unmatchedLrc=%d copied=%d spilled=%d lrcDeduped=%d dropsCleared=%d errors=%d",
    #allLrcs, matched, missing, unmatchedLrc, copied, spilled, lrcDeduped, orphanRemoved, errors
  ))
  if #missingList > 0 then
    print("  missing samples (track ↔ .lrc):")
    for _, line in ipairs(missingList) do print("    - " .. line) end
    if missing > #missingList then
      print(string.format("    … %d more", missing - #missingList))
    end
  end
  if #unmatchedSamples > 0 then
    print("  unmatched .lrc samples:")
    for _, line in ipairs(unmatchedSamples) do print("    - " .. line) end
    if unmatchedLrc > #unmatchedSamples then
      print(string.format("    … %d more", unmatchedLrc - #unmatchedSamples))
    end
  end
end

------------------------------------------------------------------ main
print(modeTag() .. "sort-music — music + sfx + lyrics")
if opts.dryRun then
  print("Preview only (reports moves + dupe cleanup). Re-run with --apply to write.")
elseif opts.dedupe then
  print("Audio dupe cleanup ON: keeps best .dfpwm+.lrc (prefer Artist/Album); deletes extras.")
  print("Pass --safe or --no-dedupe to skip audio deletes.")
else
  print("Audio dupe cleanup OFF (--safe / --no-dedupe). Nest/Singles/SFX/lyrics only.")
end

if opts.doSfx then runSfx() end
if opts.doMusic then runMusic() end
if opts.doLyrics then runLyrics() end

print("---")
print(modeTag() .. "Done.")
if opts.dryRun then
  print("Next: sort-music --apply")
  print("  (or sort-music --apply --safe to tidy without deleting audio dupes)")
else
  print("F5 / restart jukebox to rescan. DJ picks up /sfx on next flip.")
end
