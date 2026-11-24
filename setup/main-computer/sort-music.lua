--[[
  sort-music.lua — one-shot tidy for the CC:Tweaked jukebox (ATM10)

  Does all of:
    1) Music:  Artist - Album → Artist/Album ; bare Artist/*.dfpwm → Artist/Singles
               "Singles - Title" → Album=Singles + song Title (not artist Singles)
               "Name 2" / "Name_2" / "Name (2)" merge into Name only when Name exists
               + opt-in cross-disk audio dedupe (--dedupe; dry-run reports only)
                 Keep best .dfpwm+.lrc pair; prefer Artist/Album path; delete extras
                 NEVER delete a sole library copy or a protected Artist/Album track
                 unless another same-size copy is confirmed kept
                 + prune leftover empty " 2" folders after merge
    2) SFX:    create /sfx ; move loose root SFX*.dfpwm into it (not audio-deduped)
    3) Root:   loose root .dfpwm + .lrc → match/move onto disks; clear leftovers
               Never deletes scripts (*.lua), startup, or library/system dirs
    4) Lyrics: match .lrc to library tracks, place beside songs, mirror /lyrics
               (spills across disks when full). Sources:
                 • recursive: every .lrc under computer + disk + diskN
                   (flat drops, nested leftovers, pack trees)
                 • match: exact basename, normalized (track # / punct), [ti]/[ar],
                   "Artist - Title.lrc", fuzzy contain
               + remove duplicate .lrc for the same .dfpwm

  Usage:
      sort-music                  -- dry-run preview (report only; no writes)
      sort-music --apply          -- nest + Singles + root + SFX + lyrics (NO audio deletes)
      sort-music --apply --dedupe -- also delete confirmed audio extras
      sort-music --apply --safe   -- same as --apply (audio deletes stay off)
      sort-music --apply --no-dedupe  -- alias of --safe
      sort-music --dedupe         -- dry-run that reports would-delete audio extras
      sort-music --apply --lyrics-only
      sort-music --apply --no-lyrics
      sort-music --apply --no-mirror
      sort-music --apply --no-root

  Drop many .lrc files onto the computer or a disk root, then:
      sort-music --apply

  Flags: --apply  --dry-run  --dedupe  --no-dedupe  --safe  --lyrics-only
         --no-lyrics  --no-music  --no-sfx  --no-root  --no-mirror  --help

  Why "Name 2" appears: when a move/nest target already existed, the sorter (or an
  older copy) coined a collision name instead of merging into the existing folder.
]]

local RESERVE = 4096 -- bytes kept free per mount (Importer-style)

local rawArgs = { ... }
local opts = {
  apply = false,
  dryRun = true,
  doMusic = true,
  doSfx = true,
  doLyrics = true,
  doRoot = true, -- clear loose .dfpwm/.lrc from computer root onto disks
  mirror = true,
  -- Audio deletes are OPT-IN. --apply alone must never wipe albums.
  dedupe = false,
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
    opts.doRoot = true -- still clear loose root .lrc/.dfpwm
  elseif lower == "--no-lyrics" then
    opts.doLyrics = false
  elseif lower == "--no-music" then
    opts.doMusic = false
  elseif lower == "--no-sfx" then
    opts.doSfx = false
  elseif lower == "--no-root" then
    opts.doRoot = false
  elseif lower == "--no-mirror" then
    opts.mirror = false
  elseif lower == "--help" or lower == "-h" then
    print("sort-music [--apply] [packDir] [--lyrics-only] [--no-lyrics] [--no-mirror]")
    print("  Dry-run by default (no writes). --apply writes.")
    print("  Music nest + Singles + root cleanup + SFX + lyrics.")
    print("  Collision folders (Name 2) merge into Name only when Name already exists.")
    print("  Audio deletes OFF by default. Pass --dedupe to remove confirmed extras.")
    print("  Dupes: keep best .dfpwm+.lrc; never delete sole copy or protected album track")
    print("    unless another same-size copy is kept. Prefer keep-with-lyrics.")
    print("  Root: move loose .dfpwm/.lrc onto disks; never deletes *.lua / startup.")
    print("  --safe / --no-dedupe keep audio deletes off. --dedupe opts them in.")
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

local function isNfp(name)
  return type(name) == "string" and name:lower():match("%.nfp$") ~= nil
end

local function isSfxName(name)
  return type(name) == "string" and name:lower():match("^sfx.*%.dfpwm$") ~= nil
end

-- Move Song.lrc / Song.nfp / cover.nfp alongside a relocated .dfpwm.
local function moveAudioSidecars(srcDir, stem, destDir, destAudioName)
  local destStem = tostring(destAudioName or ""):gsub("%.[Dd][Ff][Pp][Ww][Mm]$", "")
  if destStem == "" then destStem = stem end
  local srcLrc = fs.combine(srcDir, stem .. ".lrc")
  if fs.exists(srcLrc) and not fs.isDir(srcLrc) then
    movePath(srcLrc, fs.combine(destDir, destStem .. ".lrc"))
  end
  local srcNfp = fs.combine(srcDir, stem .. ".nfp")
  if fs.exists(srcNfp) and not fs.isDir(srcNfp) then
    movePath(srcNfp, fs.combine(destDir, destStem .. ".nfp"))
  end
  -- Album-level cover art travels with the album folder (mergeDirInto), but
  -- when flattening a singles-title folder keep cover.nfp if present.
  local srcCover = fs.combine(srcDir, "cover.nfp")
  local dstCover = fs.combine(destDir, "cover.nfp")
  if fs.exists(srcCover) and not fs.isDir(srcCover) and not fs.exists(dstCover) then
    movePath(srcCover, dstCover)
  end
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

-- Collision suffixes from name clashes when a destination already existed:
--   "Palaces 2", "Palaces_2", "Palaces (2)" → "Palaces"
local function stripCollisionSuffix(name)
  local s = tostring(name or "")
  local base, ext = s:match("^(.*)(%.[^%.]+)$")
  if not base then base, ext = s, "" end
  local cleaned = base
    :gsub("%s*%(%d+%)$", "")
    :gsub("_%d+$", "")
    :gsub("%s+%d+$", "")
  cleaned = cleaned:gsub("%s+$", "")
  if cleaned == "" then cleaned = base end
  return cleaned .. ext, cleaned ~= base
end

local function canonicalStem(name)
  local stem = tostring(name or ""):gsub("%.[Ll][Rr][Cc]$", ""):gsub("%.[Dd][Ff][Pp][Ww][Mm]$", "")
  local cleaned = select(1, stripCollisionSuffix(stem))
  return cleaned
end

local function stripTrackNo(name)
  local n = tostring(name or "")
  local stripped = n:gsub("^%s*%d+%s*[%.%-%)]+%s*", ""):gsub("^%s*%d+%s+", "")
  return stripped ~= "" and stripped or n
end

local function songKeys(name)
  local base = tostring(name or ""):gsub("%.[Ll][Rr][Cc]$", ""):gsub("%.[Dd][Ff][Pp][Ww][Mm]$", "")
  local canon = canonicalStem(base)
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
  add(canon)
  add(stripTrackNo(base))
  add(stripTrackNo(canon))
  add(base:gsub("%s*%b()", ""))
  add(canon:gsub("%s*%b()", ""))
  add(stripTrackNo(base:gsub("%s*%b()", "")))
  add(stripTrackNo(canon:gsub("%s*%b()", "")))
  -- "Artist - Title" / "Artist - Album - Title" → also index title-only
  local function addTitleParts(src)
    local a, b, c = src:match("^(.-) %- (.-) %- (.+)$")
    if a and b and c then
      add(c)
      add(stripTrackNo(c))
      add(canonicalStem(c))
    else
      local a2, t2 = src:match("^(.-) %- (.+)$")
      if a2 and t2 then
        add(t2)
        add(stripTrackNo(t2))
        add(canonicalStem(t2))
      end
    end
  end
  addTitleParts(base)
  if canon ~= base then addTitleParts(canon) end
  return keys
end

-- Returns artist, album, titleHint
-- "Daft Punk - Discovery" → artist, album
-- "Singles - Palaces" / "Singles - Palaces 2" → nil artist, album=Singles, titleHint=Palaces
-- (weak left side means album Singles + song title, not artist=Singles)
local function parseArtistAlbum(folderName)
  local cleaned = select(1, stripCollisionSuffix(folderName))
  local artist, album = cleaned:match("^(.-) %- (.+)$")
  if not (artist and album and artist ~= "" and album ~= "") then
    return nil, nil, nil
  end
  album = select(1, stripCollisionSuffix(album))
  local aNorm = norm(artist)
  if aNorm == "singles" or aNorm == "various" or aNorm == "unknown" then
    return nil, "Singles", album -- titleHint = album side (song name)
  end
  return artist, album, nil
end

local function isWeakArtist(name)
  local n = norm(name)
  return n == "" or n == "singles" or n == "various" or n == "unknown"
end

local function isWeakAlbum(name)
  local n = norm(name)
  return n == "" or n == "singles" or n == "unknown"
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
    -- Underscore form only for non-audio clashes; audio merges instead of "Name 2"
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

-- Forward-declared: defined with music helpers; used by movePath at runtime.
local hasBesideLrc

-- Same-content proxy for CC (no cheap hash): equal positive sizes.
local function sameAudioSize(pathA, pathB)
  local sa, sb = fileSize(pathA), fileSize(pathB)
  return sa > 0 and sb > 0 and sa == sb
end

local function movePath(src, dst)
  if opts.dryRun then return true, nil, dst end
  if src == dst then return true, nil, dst end
  local parent = fs.getDir(dst)
  if parent and parent ~= "" then ensureDir(parent) end
  if fs.exists(dst) then
    -- Audio/lyrics: prefer the copy with a beside .lrc pair; never mint "Name 2"
    -- Different sizes = different songs that collided on name → keep both.
    local dstName = fs.getName(dst)
    if isAudio(dstName) and isAudio(fs.getName(src)) then
      if sameAudioSize(src, dst) then
        local srcPair = hasBesideLrc and hasBesideLrc(src)
        local dstPair = hasBesideLrc and hasBesideLrc(dst)
        if srcPair and not dstPair then
          pcall(fs.delete, dst)
        else
          pcall(fs.delete, src)
          return true, nil, dst
        end
      else
        local dir = fs.getDir(dst)
        dst = fs.combine(dir, uniqueName(dir, dstName))
      end
    elseif isLrc(dstName) and isLrc(fs.getName(src)) then
      pcall(fs.delete, src)
      return true, nil, dst
    else
      local dir = fs.getDir(dst)
      dst = fs.combine(dir, uniqueName(dir, dstName))
    end
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

hasBesideLrc = function(audioPath)
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

-- Merge every file from srcDir into destDir; delete srcDir when empty.
-- Audio: only drop a file when the kept copy is same-size (true extra).
-- Different sizes keep both (unique name). Prefer keep-with-lyrics.
local function mergeDirInto(srcDir, destDir, label)
  if srcDir == destDir then return 0 end
  print((opts.dryRun and "  ~ merge " or "  merge ") .. srcDir .. " → " .. destDir
    .. (label and (" [" .. label .. "]") or ""))
  local moved = 0
  if opts.dryRun then
    for _, f in ipairs(listDir(srcDir)) do
      local src = fs.combine(srcDir, f)
      local dst = fs.combine(destDir, f)
      if fs.isDir(src) then
        moved = moved + 1
      elseif fs.exists(dst) and isAudio(f) and not sameAudioSize(src, dst) then
        print("  ~ keep-both (size mismatch) " .. src .. " vs " .. dst)
        moved = moved + 1
      elseif fs.exists(dst) and isAudio(f) then
        local srcPair, dstPair = hasBesideLrc(src), hasBesideLrc(dst)
        local drop = (srcPair and not dstPair) and dst or src
        print("  ~ would-delete dupe " .. drop .. " (keep pair-prefer)")
        moved = moved + 1
      else
        moved = moved + 1
      end
    end
    return moved
  end
  ensureDir(destDir)
  for _, f in ipairs(listDir(srcDir)) do
    local src = fs.combine(srcDir, f)
    local dst = fs.combine(destDir, f)
    if fs.isDir(src) then
      moved = moved + mergeDirInto(src, dst, nil)
    else
      if fs.exists(dst) then
        if isAudio(f) then
          if sameAudioSize(src, dst) then
            local srcPair = hasBesideLrc(src)
            local dstPair = hasBesideLrc(dst)
            if srcPair and not dstPair then
              -- Prefer lyrics pair: replace dest only after src is safe to move
              local tmp = fs.combine(destDir, ".merge-tmp-" .. f)
              local okMove = select(1, movePath(src, tmp))
              if okMove then
                deletePath(dst)
                local ok2 = select(1, movePath(tmp, dst))
                if ok2 then moved = moved + 1
                else
                  -- Restore: put tmp back as unique name so nothing is lost
                  movePath(tmp, fs.combine(destDir, uniqueName(destDir, f)))
                  moved = moved + 1
                end
              end
            else
              print("  delete dupe " .. src .. " (kept " .. dst .. ")")
              deletePath(src)
              moved = moved + 1
            end
          else
            -- Different song content sharing a name — keep both
            local alt = fs.combine(destDir, uniqueName(destDir, f))
            print("  keep-both " .. src .. " → " .. alt)
            local ok = select(1, movePath(src, alt))
            if ok then moved = moved + 1 end
          end
        else
          -- non-audio clash: keep dest, drop src duplicate name
          deletePath(src)
          moved = moved + 1
        end
      else
        local ok = select(1, movePath(src, dst))
        if ok then moved = moved + 1 end
      end
    end
  end
  if #listDir(srcDir) == 0 then pcall(fs.delete, srcDir) end
  return moved
end

local function pruneEmptyDirs(dir, depth)
  if depth > 24 or not (fs.exists(dir) and fs.isDir(dir)) then return 0 end
  local n = 0
  for _, name in ipairs(listDir(dir)) do
    local fp = fs.combine(dir, name)
    if fs.isDir(fp) then
      n = n + pruneEmptyDirs(fp, depth + 1)
      if #listDir(fp) == 0 then
        local _, wasCollision = stripCollisionSuffix(name)
        print((opts.dryRun and "  ~ prune " or "  prune ") .. fp
          .. (wasCollision and " (collision leftover)" or ""))
        if not opts.dryRun then pcall(fs.delete, fp) end
        n = n + 1
      end
    end
  end
  return n
end

-- Fold "Album 2" / "Album_2" sibling dirs into canonical "Album"
-- ONLY when the canonical folder already exists (or multiple collision siblings).
-- Never rename a sole "Volume 2" / "Name 2" album — it may be a real title.
local function mergeCollisionAlbums(artistDir)
  local merged = 0
  local children = listDir(artistDir)
  local byCanon = {}
  for _, name in ipairs(children) do
    local fp = fs.combine(artistDir, name)
    if fs.isDir(fp) then
      local canon = select(1, stripCollisionSuffix(name))
      byCanon[canon] = byCanon[canon] or {}
      byCanon[canon][#byCanon[canon] + 1] = { name = name, path = fp }
    end
  end
  for canon, group in pairs(byCanon) do
    if #group >= 2 then
      -- Only merge when the real canonical folder exists among siblings
      -- (or on disk). Never fold "Volume 2"+"Volume 3" into a new "Volume".
      local dest = fs.combine(artistDir, canon)
      local keep = nil
      for _, g in ipairs(group) do
        if g.name == canon then keep = g break end
      end
      if not keep and fs.exists(dest) and fs.isDir(dest) then
        keep = { name = canon, path = dest }
      end
      if keep then
        for i = 1, #group do
          if group[i].path ~= keep.path then
            merged = merged + mergeDirInto(group[i].path, keep.path, "collision")
          end
        end
      end
    elseif #group == 1 and group[1].name ~= canon then
      local dest = fs.combine(artistDir, canon)
      -- Sole collision-looking name: only merge if canon already exists.
      -- Do NOT rename sole "Album 2" → "Album" (destroys real numbered albums).
      if fs.exists(dest) and fs.isDir(dest) then
        merged = merged + mergeDirInto(group[1].path, dest, "collision")
      end
    end
  end
  return merged
end

local function runMusic()
  print(modeTag() .. "=== Music tidy (Artist/Album + Singles"
    .. (opts.dedupe and " + dupe cleanup) ===" or "; audio dedupe off) ==="))
  local movedFolders, movedSingles, deduped, collisionMerged = 0, 0, 0, 0

  for _, root in ipairs(musicContainers()) do
    print("  root " .. root)
    for _, entry in ipairs(listDir(root)) do
      local entryPath = fs.combine(root, entry)
      if fs.isDir(entryPath) then
        local artist, album, titleHint = parseArtistAlbum(entry)
        if artist then
          local destDir = fs.combine(root, artist, album)
          print("  nest  " .. entryPath .. " → " .. destDir)
          if not opts.dryRun then
            ensureDir(fs.combine(root, artist))
            mergeDirInto(entryPath, destDir, "nest")
          else
            print("  ~ nest contents of " .. entryPath)
          end
          movedFolders = movedFolders + 1
        elseif titleHint then
          -- "Singles - Title" / "Singles - Title 2" → Various/Singles (song = Title)
          local destDir = fs.combine(root, "Various", "Singles")
          print("  singles-title " .. entryPath .. " → " .. destDir
            .. " (song " .. titleHint .. ")")
          if not opts.dryRun then
            ensureDir(fs.combine(root, "Various"))
            ensureDir(destDir)
            for _, f in ipairs(listDir(entryPath)) do
              local src = fs.combine(entryPath, f)
              if not fs.isDir(src) and isAudio(f) then
                local stem = f:gsub("%.[Dd][Ff][Pp][Ww][Mm]$", "")
                local canonStem = canonicalStem(stem)
                local destName = f
                -- Prefer the folder's title when the file stem is empty/generic/collision
                if canonStem == "" or norm(canonStem) == norm(titleHint)
                    or select(2, stripCollisionSuffix(stem)) then
                  destName = titleHint .. ".dfpwm"
                end
                local ok, err = movePath(src, fs.combine(destDir, destName))
                if ok then
                  movedSingles = movedSingles + 1
                  -- Bring beside .lrc / .nfp along under the dest stem
                  moveAudioSidecars(entryPath, stem, destDir, destName)
                else
                  printError("    ! " .. tostring(err))
                end
              elseif not fs.isDir(src) and (isLrc(f) or isNfp(f)) then
                -- leftover .lrc/.nfp without audio handled below / lyrics pass
              elseif fs.isDir(src) then
                mergeDirInto(src, destDir, "singles-title")
              end
            end
            -- Move any remaining loose .lrc / .nfp using titleHint
            for _, f in ipairs(listDir(entryPath)) do
              local src = fs.combine(entryPath, f)
              if not fs.isDir(src) and isLrc(f) then
                movePath(src, fs.combine(destDir, titleHint .. ".lrc"))
              elseif not fs.isDir(src) and isNfp(f) and f:lower() ~= "cover.nfp" then
                movePath(src, fs.combine(destDir, titleHint .. ".nfp"))
              elseif not fs.isDir(src) and f:lower() == "cover.nfp" then
                local dstCover = fs.combine(destDir, "cover.nfp")
                if not fs.exists(dstCover) then movePath(src, dstCover) end
              end
            end
            if #listDir(entryPath) == 0 then pcall(fs.delete, entryPath) end
          else
            movedSingles = movedSingles + 1
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
          -- Collision-named artist folders: "Panic 2" → merge into "Panic"
          -- only when Panic already exists. Never rename a sole "Name 2" artist.
          local canonEntry = select(1, stripCollisionSuffix(entry))
          if canonEntry ~= entry then
            local destArtist = fs.combine(root, canonEntry)
            if fs.exists(destArtist) and fs.isDir(destArtist) then
              collisionMerged = collisionMerged + mergeDirInto(entryPath, destArtist, "artist-collision")
            end
          end
        end
      end
    end
    -- Merge Album 2 → Album under each artist in this root
    for _, artistName in ipairs(listDir(root)) do
      local artistPath = fs.combine(root, artistName)
      if fs.isDir(artistPath) then
        local low = artistName:lower()
        if low ~= "lyrics" and low ~= "lyrics-pack" and low ~= "sfx" and low ~= "music" then
          collisionMerged = collisionMerged + mergeCollisionAlbums(artistPath)
        elseif low == "music" then
          for _, sub in ipairs(listDir(artistPath)) do
            local sp = fs.combine(artistPath, sub)
            if fs.isDir(sp) then
              collisionMerged = collisionMerged + mergeCollisionAlbums(sp)
            end
          end
        end
      end
    end
  end

  if not opts.dedupe then
    local pruned = 0
    for _, root in ipairs(uniqueLibraryRoots()) do
      pruned = pruned + pruneEmptyDirs(root, 0)
    end
    print("  audio dedupe skipped (pass --dedupe to remove confirmed extras)")
    print(string.format(
      "  nested folders: %d  singles files: %d  collision merges: %d  pruned dirs: %d  audio deduped: 0",
      movedFolders, movedSingles, collisionMerged, pruned
    ))
    return
  end

  -- Collect every .dfpwm under library roots once (seenPaths guards self-delete).
  -- Group same song across disks/spots; keep best pair / Artist/Album; delete rest.
  -- Protected Artist/Album tracks are never deleted unless another same-album,
  -- same-size copy is the confirmed keeper.
  local candidates, seenPaths = {}, {}

  local function collectAudio(path, file, artistName, albumName)
    if seenPaths[path] or not isAudio(file) then return end
    seenPaths[path] = true
    -- Canonical key so "Palaces 2.dfpwm" groups with "Palaces.dfpwm"
    local sk = norm(canonicalStem(file))
    if sk == "" then
      sk = songKeys(file)[1] or norm(file:gsub("%.[Dd][Ff][Pp][Ww][Mm]$", ""))
    end
    if sk == "" then return end
    local albumCanon = select(1, stripCollisionSuffix(albumName or "Singles"))
    candidates[#candidates + 1] = {
      path = path,
      name = file,
      artist = artistName or "Singles",
      album = albumCanon,
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
          local parsedArtist, parsedAlbum, titleHint = parseArtistAlbum(entry)
          if hasDirectAudio and parsedArtist then
            walkAlbum(entryPath, parsedArtist, parsedAlbum)
          elseif hasDirectAudio and titleHint then
            walkAlbum(entryPath, "Various", "Singles")
          elseif hasAlbumDirs then
            local artistCanon = select(1, stripCollisionSuffix(entry))
            for _, albumName in ipairs(children) do
              local albumPath = fs.combine(entryPath, albumName)
              if fs.isDir(albumPath) then
                local albumCanon = select(1, stripCollisionSuffix(albumName))
                walkAlbum(albumPath, artistCanon, albumCanon)
              elseif isAudio(albumName) then
                collectAudio(albumPath, albumName, artistCanon, "Singles")
              end
            end
          elseif hasDirectAudio then
            walkAlbum(entryPath, "Various", select(1, stripCollisionSuffix(entry)))
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

  local function isProtectedAlbumTrack(c)
    return not isWeakArtist(c.artist) and not isWeakAlbum(c.album)
  end

  local function sameAlbum(a, b)
    return norm(a.artist) == norm(b.artist) and norm(a.album) == norm(b.album)
  end

  -- Delete only true extras: keeper confirmed, different path, same size.
  -- Protected Artist/Album tracks survive unless keeper is same artist+album.
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

    -- Keeper must remain a real on-disk copy (or dry-run stand-in)
    if not opts.dryRun and not fs.exists(keep.path) then
      print("  dedupe skip (no keeper on disk) group of " .. keep.songKey)
      return
    end

    for i = 2, #uniq do
      local loser = uniq[i]
      if loser.path == keep.path then
        -- same path — never self-delete
      elseif (loser.size or 0) <= 0 or (keep.size or 0) <= 0 or loser.size ~= keep.size then
        print(string.format(
          "  dedupe skip (not same content) %s vs keep %s",
          loser.path, keep.path
        ))
      elseif isProtectedAlbumTrack(loser) and not sameAlbum(keep, loser) then
        -- Existing album track is the only copy of that album placement — keep it
        print(string.format(
          "  dedupe skip (protected album) %s (keep %s untouched)",
          loser.path, keep.path
        ))
      else
        print(string.format(
          "  %sdedupe audio %s (keep %s [%s])",
          opts.dryRun and "~ would-delete " or "",
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
            if beside ~= keepBeside and (opts.dryRun or (fs.exists(beside) and not fs.isDir(beside))) then
              print((opts.dryRun and "  ~ would-delete orphan-lrc " or "  dedupe orphan-lrc ") .. beside)
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
        -- Fold flat/Singles orphans into the one real artist, but resolve
        -- per-album so Discovery/Intro never deletes Homework/Intro.
        local a = artistKeys[1]
        for _, c in ipairs(weak) do byArtist[a][#byArtist[a] + 1] = c end
        local byAlbum, weakAlb = {}, {}
        for _, c in ipairs(byArtist[a]) do
          if isWeakAlbum(c.album) then
            weakAlb[#weakAlb + 1] = c
          else
            local al = norm(c.album)
            byAlbum[al] = byAlbum[al] or {}
            byAlbum[al][#byAlbum[al] + 1] = c
          end
        end
        local albumKeys = {}
        for al in pairs(byAlbum) do albumKeys[#albumKeys + 1] = al end
        if #albumKeys == 0 then
          resolveGroup(byArtist[a])
        elseif #albumKeys == 1 then
          local al = albumKeys[1]
          for _, c in ipairs(weakAlb) do byAlbum[al][#byAlbum[al] + 1] = c end
          resolveGroup(byAlbum[al])
        else
          -- Multiple real albums: only fold a weak orphan into an album when
          -- a same-size match exists there; never cross-delete album tracks.
          for _, w in ipairs(weakAlb) do
            local bestAl, bestScore = nil, -1
            for _, al in ipairs(albumKeys) do
              for _, c in ipairs(byAlbum[al]) do
                if (w.size or 0) > 0 and w.size == c.size then
                  local sc = audioKeepScore(c)
                  if sc > bestScore then bestScore, bestAl = sc, al end
                end
              end
            end
            if bestAl then
              byAlbum[bestAl][#byAlbum[bestAl] + 1] = w
            end
          end
          for _, al in ipairs(albumKeys) do
            resolveGroup(byAlbum[al])
          end
        end
      else
        -- Multiple real artists share a title — dedupe within each artist.
        -- Fold each flat/orphan into a strong Artist/Album only on same-size match.
        for _, w in ipairs(weak) do
          local bestA, bestScore = nil, -1
          for _, a in ipairs(artistKeys) do
            for _, c in ipairs(byArtist[a]) do
              if (w.size or 0) > 0 and w.size == c.size then
                local sc = audioKeepScore(c)
                if sc > bestScore then bestScore, bestA = sc, a end
              end
            end
          end
          if bestA and bestScore >= 1000 then
            byArtist[bestA][#byArtist[bestA] + 1] = w
          end
        end
        for _, a in ipairs(artistKeys) do
          -- Per-album within artist
          local byAlbum, weakAlb = {}, {}
          for _, c in ipairs(byArtist[a]) do
            if isWeakAlbum(c.album) then
              weakAlb[#weakAlb + 1] = c
            else
              local al = norm(c.album)
              byAlbum[al] = byAlbum[al] or {}
              byAlbum[al][#byAlbum[al] + 1] = c
            end
          end
          local albumKeys = {}
          for al in pairs(byAlbum) do albumKeys[#albumKeys + 1] = al end
          if #albumKeys <= 1 then
            local bucket = byArtist[a]
            if #albumKeys == 1 then
              local al = albumKeys[1]
              for _, c in ipairs(weakAlb) do byAlbum[al][#byAlbum[al] + 1] = c end
              bucket = byAlbum[al]
            end
            resolveGroup(bucket)
          else
            for _, w in ipairs(weakAlb) do
              local bestAl, bestScore = nil, -1
              for _, al in ipairs(albumKeys) do
                for _, c in ipairs(byAlbum[al]) do
                  if (w.size or 0) > 0 and w.size == c.size then
                    local sc = audioKeepScore(c)
                    if sc > bestScore then bestScore, bestAl = sc, al end
                  end
                end
              end
              if bestAl then byAlbum[bestAl][#byAlbum[bestAl] + 1] = w end
            end
            for _, al in ipairs(albumKeys) do
              resolveGroup(byAlbum[al])
            end
          end
        end
      end
    end
  end

  -- Second pass: merge any remaining collision album folders, prune empties
  for _, root in ipairs(musicContainers()) do
    for _, artistName in ipairs(listDir(root)) do
      local artistPath = fs.combine(root, artistName)
      if fs.isDir(artistPath) then
        collisionMerged = collisionMerged + mergeCollisionAlbums(artistPath)
      end
    end
  end
  local pruned = 0
  for _, root in ipairs(uniqueLibraryRoots()) do
    pruned = pruned + pruneEmptyDirs(root, 0)
  end

  print(string.format(
    "  nested folders: %d  singles files: %d  collision merges: %d  pruned dirs: %d  audio scanned: %d  audio deduped: %d",
    movedFolders, movedSingles, collisionMerged, pruned, #candidates, deduped
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
          local parsedArtist, parsedAlbum, titleHint = parseArtistAlbum(entry)
          if hasDirectAudio and parsedArtist then
            addAudioInDir(entryPath, parsedArtist, parsedAlbum)
          elseif hasDirectAudio and titleHint then
            addAudioInDir(entryPath, "Various", "Singles")
          elseif hasAlbumDirs then
            local artistCanon = select(1, stripCollisionSuffix(entry))
            for _, albumName in ipairs(children) do
              local albumPath = fs.combine(entryPath, albumName)
              if fs.isDir(albumPath) then
                addAudioInDir(albumPath, artistCanon, select(1, stripCollisionSuffix(albumName)))
              elseif isAudio(albumName) then
                addTrack(albumPath, albumName, artistCanon, "Singles")
              end
            end
          elseif hasDirectAudio then
            addAudioInDir(entryPath, "Various", select(1, stripCollisionSuffix(entry)))
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

------------------------------------------------------------------ 4) Computer root cleanup
-- Keep scripts/startup/system dirs. Move loose .dfpwm/.lrc onto disks; clear leftovers.
local ROOT_KEEP_EXACT = {
  rom = true, music = true, sfx = true, lyrics = true,
  ["lyrics-pack"] = true, inbox = true, drops = true,
  ["lyrics-inbox"] = true, startup = true,
}

local function isProtectedRootEntry(name)
  local low = tostring(name or ""):lower()
  if ROOT_KEEP_EXACT[low] then return true end
  if low:match("^disk%d*$") then return true end
  if low:match("%.lua$") then return true end
  if low:match("^%.") then return true end -- .settings etc.
  if low == "wsinfo" or low == "changelog.txt" or low == "readme.txt" then return true end
  return false
end

local function pickMusicDest(needBytes, fileName)
  local need = (needBytes or 0) + RESERVE
  local candidates = {}
  local function consider(mount, musicRoot, pri)
    local mpath = mount == "" and "/" or mount
    local free = freeSpace(mpath)
    if free >= need then
      candidates[#candidates + 1] = {
        mount = mount, root = musicRoot, free = free, pri = pri,
      }
    end
  end
  for _, m in ipairs(listFloppyMounts()) do
    local mr = fs.combine(m, "music")
    if fs.exists(mr) and fs.isDir(mr) then
      consider(m, mr, 1)
    else
      consider(m, mr, 2)
    end
    -- Also allow artist trees directly on disk root
    consider(m, m, 3)
  end
  if fs.exists("music") and fs.isDir("music") then
    consider("", "music", 4)
  else
    consider("", "music", 5)
  end
  table.sort(candidates, function(a, b)
    if a.pri ~= b.pri then return a.pri < b.pri end
    return a.free > b.free
  end)
  local c = candidates[1]
  if not c then return nil end
  return fs.combine(c.root, "Various", "Singles", fileName), c.mount, c.root
end

local function runRootCleanup(phase)
  -- phase "early": move loose root .dfpwm onto disks (before music tidy/lyrics)
  -- phase "late":  sweep leftover root .dfpwm/.lrc after lyrics matching
  phase = phase or "late"
  print(modeTag() .. "=== Root cleanup (" .. phase .. ") ===")
  local movedAudio, movedLrc, deleted = 0, 0, 0

  for _, name in ipairs(listDir("")) do
    if not isProtectedRootEntry(name) then
      local path = name -- root-relative
      if not fs.isDir(path) then
        if isAudio(name) and not isSfxName(name) then
          local dest = select(1, pickMusicDest(fileSize(path), name))
          if dest then
            print((opts.dryRun and "  ~ root-audio " or "  root-audio ")
              .. path .. " → " .. dest)
            local ok, err = movePath(path, dest)
            if ok then
              movedAudio = movedAudio + 1
              -- Sibling .lrc / .nfp with same stem rides along
              local stem = name:gsub("%.[Dd][Ff][Pp][Ww][Mm]$", "")
              local sib = stem .. ".lrc"
              if fs.exists(sib) and not fs.isDir(sib) and not isProtectedRootEntry(sib) then
                local dstLrc = dest:gsub("%.[Dd][Ff][Pp][Ww][Mm]$", "") .. ".lrc"
                print((opts.dryRun and "  ~ root-lrc " or "  root-lrc ")
                  .. sib .. " → " .. dstLrc)
                if movePath(sib, dstLrc) then movedLrc = movedLrc + 1 end
              end
              local sibArt = stem .. ".nfp"
              if fs.exists(sibArt) and not fs.isDir(sibArt) and not isProtectedRootEntry(sibArt) then
                local dstNfp = dest:gsub("%.[Dd][Ff][Pp][Ww][Mm]$", "") .. ".nfp"
                print((opts.dryRun and "  ~ root-nfp " or "  root-nfp ")
                  .. sibArt .. " → " .. dstNfp)
                movePath(sibArt, dstNfp)
              end
            else
              printError("  ! " .. tostring(err))
            end
          else
            printError("  ! no disk room for root audio " .. path)
          end
        elseif isLrc(name) and phase == "late" then
          -- After lyrics pass: anything still on root is unmatched or leftover.
          -- Park under /lyrics (or disk lyrics) so ls root stays clean.
          local destName = name
          local dest = fs.combine("lyrics", destName)
          if not fs.exists("lyrics") then
            if opts.dryRun then
              print("  ~ create /lyrics")
            else
              ensureDir("lyrics")
            end
          end
          -- Prefer a floppy lyrics folder when computer is tight
          local need = fileSize(path) + RESERVE
          for _, m in ipairs(listFloppyMounts()) do
            local lr = fs.combine(m, "lyrics")
            if freeSpace(m) >= need then
              dest = fs.combine(lr, destName)
              break
            end
          end
          print((opts.dryRun and "  ~ root-lrc " or "  root-lrc ")
            .. path .. " → " .. dest)
          local ok, err = movePath(path, dest)
          if ok then movedLrc = movedLrc + 1
          else printError("  ! " .. tostring(err)) end
        end
      elseif phase == "late" then
        -- Empty collision leftover folders on root (not protected)
        local _, wasCollision = stripCollisionSuffix(name)
        if wasCollision and #listDir(path) == 0 then
          print((opts.dryRun and "  ~ prune root " or "  prune root ") .. path)
          if deletePath(path) then deleted = deleted + 1 end
        end
      end
    end
  end

  -- Late sweep: if a root .lrc/.dfpwm still exists after moves failed partially, report
  if phase == "late" and not opts.dryRun then
    for _, name in ipairs(listDir("")) do
      if not isProtectedRootEntry(name) and not fs.isDir(name) then
        if isAudio(name) or isLrc(name) then
          print("  leftover root media (could not move): " .. name)
        end
      end
    end
  end

  print(string.format(
    "  root: audio moved=%d  lrc moved=%d  pruned=%d",
    movedAudio, movedLrc, deleted
  ))
end

------------------------------------------------------------------ main
print(modeTag() .. "sort-music — music + sfx + root + lyrics")
if opts.dryRun then
  print("Preview only (reports moves + merges + would-deletes). Re-run with --apply to write.")
  if opts.dedupe then
    print("Audio dupe preview ON (--dedupe): shows confirmed extras that would be deleted.")
  else
    print("Audio deletes OFF (default). Add --dedupe to preview/remove confirmed extras.")
  end
elseif opts.dedupe then
  print("Audio dupe cleanup ON (--dedupe): keeps best .dfpwm+.lrc; deletes confirmed extras only.")
  print("Never deletes sole copies or protected Artist/Album tracks without a kept same-size twin.")
  print("Collision folders (Name 2) merge into Name only when Name exists.")
else
  print("Audio dupe cleanup OFF (default). Nest/Singles/root/SFX/lyrics only — albums survive.")
  print("Pass --dedupe to delete confirmed audio extras. --safe / --no-dedupe keep deletes off.")
end

if opts.doSfx then runSfx() end
if opts.doRoot then runRootCleanup("early") end
if opts.doMusic then runMusic() end
if opts.doLyrics then runLyrics() end
if opts.doRoot then runRootCleanup("late") end

print("---")
print(modeTag() .. "Done.")
if opts.dryRun then
  print("Next: sort-music --apply")
  print("  (albums safe; add --dedupe only if you want confirmed audio extras removed)")
else
  print("F5 / restart jukebox to rescan. DJ picks up /sfx on next flip.")
end
