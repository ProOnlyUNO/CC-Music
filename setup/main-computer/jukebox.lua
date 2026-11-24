--[[
  jukebox.lua — three-panel DFPWM jukebox for CC:Tweaked
  Pixel UI (paintutils): AURORA-style now playing + library + lyrics + APPEARANCE
  Designed for 9×3 at text scale ~0.5–0.9; album art via beside .nfp
  Now playing: art, scrubber, circular transport, LRC/QUEUE/VOL (no LIKE/FOLLOW)
  Brand: ProOnlyUNO / CC Music — protocols pocket_mp3 + jukebox_viz unchanged

  Library (scanned on all attached disks + /music):
      disk/Artist/Album/*.dfpwm
      diskN/Artist/Album/*.dfpwm
      disk/music/Artist/Album/*.dfpwm
      music/Artist/Album/*.dfpwm
      music/<Artist> - <Album>/*.dfpwm   (folder name split on " - ")
      plain Album/*.dfpwm under music/ → artist "Various"
      a folder named "music" under a root is a container, not an artist
      loose *.dfpwm → artist "Singles" / album "Singles"

  Usage:
      jukebox
      jukebox --term
      jukebox --scale=0.5
      jukebox /other/root

  UI: top ARTIST entry "All Songs" lists every track (artist → album → title).
      Selecting a real artist puts synthetic "All Songs" first in ALBUM (all tracks
      by that artist), then normal albums. Global ARTIST "All Songs" unchanged.
      Header shows total used/free across attached disk/diskN mounts (refreshed ~4s).
      Title bar also shows "Developer: ProOnlyUNO" in red (single write, no offset).
      Color: rainbow now-playing text; A–Z list rows tinted by first letter.
      DJ mode (D / [DJ]): random flips from the WHOLE library (allTracks) —
      mid-song auto-cuts (CONFIG.djCutMin..djCutMax, remaining-aware) and next;
      every flip: fade out → random sfx/SFX*.dfpwm → fade in (hat playNote
      fallback). DJ off → normal album/artist queue next/prev.

  Keys: SPACE pause | N next | P/B prev | LEFT/RIGHT seek
        +/- volume | S shuffle | R repeat | M mute | D DJ | L lyrics | X stop
        TAB focus panel | UP/DOWN move | ENTER play
        PGUP/PGDN scroll | F5 rescan | Q quit

  Pocket remote: rednet protocol "pocket_mp3" (built-in listener).
  Side visualizers: rednet protocol "jukebox_viz" (energy / pseudo-spectrum + optional lyric line).
  Lyrics: .lrc beside each .dfpwm (or lyrics/Artist/Album/*.lrc / diskN/lyrics). L / [LYRICS]
  toggles big-text lyric mode on 4×4 side monitors (broadcast lyric + lyricsOn).
  Song list shows compact " (L)" when a resolvable .lrc exists for that track.
]]

local dfpwm = require("cc.audio.dfpwm")

------------------------------------------------------------------ config
local CONFIG = {
  roots = { "music", "disk", "disk/music" },
  settingsFile  = ".jukebox_settings",
  monitorScale  = 0.5,   -- 9×3 @ 0.5 ≈ 270×60 chars; use --scale=1 for denser text
  maxVolume     = 3.0,
  seekStep      = 10,
  instantVolume = true,
  pocketProto   = "pocket_mp3",
  vizProto      = "jukebox_viz",  -- side-monitor visualizers (not pocket)
  vizInterval   = 0.05,          -- ~20 Hz rednet while playing (was 0.12)
  vizIdleInterval = 0.45,        -- slower pulses when stopped / paused
  vizBands      = 16,            -- contiguous RMS buckets (pseudo-spectrum)
  vizWave       = 16,            -- leaner waveform points (viz interpolates)
  vizMetaEvery  = 1.0,           -- re-send title/artist/album at most this often
  diskSpaceInterval = 4,  -- seconds between free/used space refreshes (UI timer; non-blocking)
  djFadeOut     = 0.35,          -- volume ramp-down before DJ track swap
  djFadeIn      = 0.45,          -- volume ramp-up on the new track
  djCutMin      = 15,            -- earliest mid-song DJ auto-cut (seconds of play)
  djCutMax      = 45,            -- latest mid-song auto-cut; wait = random(min..max)
  sfxDir        = "sfx",         -- DJ transition stings (SFX*.dfpwm / "SFX *.dfpwm")
}

for i = 1, 50 do
  CONFIG.roots[#CONFIG.roots + 1] = "disk" .. i
  CONFIG.roots[#CONFIG.roots + 1] = "disk" .. i .. "/music"
end

local SAMPLE_RATE = 48000
local CHUNK       = 6000

------------------------------------------------------------------ args
local forceTerm, userRoots = false, {}
for _, a in ipairs({ ... }) do
  if a == "--term" then
    forceTerm = true
  elseif a:match("^%-%-scale=") then
    CONFIG.monitorScale = tonumber(a:match("=(.+)")) or CONFIG.monitorScale
  else
    userRoots[#userRoots + 1] = shell.resolve(a)
  end
end
if #userRoots > 0 then CONFIG.roots = userRoots end

------------------------------------------------------------------ hardware
local speakers, knownSpeakers = {}, {}

local function refreshSpeakers()
  local found, names, added = {}, {}, false
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "speaker" then
      found[#found + 1] = peripheral.wrap(name)
      names[name] = true
      if not knownSpeakers[name] then added = true end
    end
  end
  for i = #speakers, 1, -1 do speakers[i] = nil end
  for i, sp in ipairs(found) do speakers[i] = sp end
  knownSpeakers = names
  return added
end

refreshSpeakers()
print("Found " .. #speakers .. " speakers")
if #speakers == 0 then
  printError("No speaker found. Attach a speaker (or via wired modem).")
  return
end

------------------------------------------------------------------ helpers
local function now() return os.epoch("utc") / 1000 end

local function fit(s, w)
  if w <= 0 then return "" end
  if #s > w then
    if w >= 2 then return s:sub(1, w - 1) .. "~" end
    return s:sub(1, w)
  end
  return s .. string.rep(" ", w - #s)
end

local function rjust(s, w)
  if #s >= w then return s:sub(1, w) end
  return string.rep(" ", w - #s) .. s
end

local function fmt(sec)
  sec = math.max(0, math.floor(sec))
  return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

local function fmtBytes(n)
  if type(n) ~= "number" then return "?" end
  n = math.max(0, n)
  if n >= 1048576 then
    return string.format("%.1f MB", n / 1048576)
  elseif n >= 1024 then
    return string.format("%.0f KB", n / 1024)
  end
  return string.format("%d B", math.floor(n))
end

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function naturalKey(s)
  return (s:lower():gsub("%d+", function(n) return string.rep("0", 10 - #n) .. n end))
end

------------------------------------------------------------------ settings
local ACCENTS = {
  teal   = colors.lightBlue,
  azure  = colors.blue,
  amber  = colors.yellow,
  rose   = colors.red,
  violet = colors.purple,
  lime   = colors.lime,
  ice    = colors.white,
  coral  = colors.orange,
}
local ACCENT_ORDER = { "teal", "azure", "amber", "rose", "violet", "lime", "ice", "coral" }
local VIZ_MODES = { "bars", "wave", "vu", "off" }

local settings = {
  volume = 1.0, muted = false, shuffle = false, rep = "off", dj = false, lyrics = false,
  accent = "violet",
  textScale = CONFIG.monitorScale,
  animations = true,
  vizMode = "bars",
}

local function loadSettings()
  if not fs.exists(CONFIG.settingsFile) then return end
  local f = fs.open(CONFIG.settingsFile, "r")
  if not f then return end
  local d = textutils.unserialize(f.readAll() or "")
  f.close()
  if type(d) ~= "table" then return end
  if type(d.volume) == "number" then settings.volume = clamp(d.volume, 0, CONFIG.maxVolume) end
  if type(d.muted) == "boolean" then settings.muted = d.muted end
  if type(d.shuffle) == "boolean" then settings.shuffle = d.shuffle end
  if d.rep == "off" or d.rep == "all" or d.rep == "one" then settings.rep = d.rep end
  if type(d.dj) == "boolean" then settings.dj = d.dj end
  if type(d.lyrics) == "boolean" then settings.lyrics = d.lyrics end
  if type(d.accent) == "string" and ACCENTS[d.accent] then settings.accent = d.accent end
  if type(d.textScale) == "number" then settings.textScale = clamp(d.textScale, 0.5, 5) end
  if type(d.animations) == "boolean" then settings.animations = d.animations end
  if type(d.vizMode) == "string" then
    for _, m in ipairs(VIZ_MODES) do if m == d.vizMode then settings.vizMode = d.vizMode break end end
  end
end
loadSettings()
CONFIG.monitorScale = settings.textScale or CONFIG.monitorScale

------------------------------------------------------------------ library  (Artist → Album → tracks)
-- artists = { { name, albums = { { name, tracks = { path,title,album,artist,dur,key } } } } }
-- allTracks = flat list of every track (for pocket sync / All Songs)

local artists, allTracks = {}, {}

local function isAudio(name) return name:lower():match("%.dfpwm$") ~= nil end

-- "Daft Punk - Random Access Memories" → "Daft Punk", "Random Access Memories"
-- First " - " separates artist from album (rest may contain more " - ").
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
    path   = path,
    title  = title,
    album  = albumName,
    artist = artistName,
    dur    = size * 8 / SAMPLE_RATE,
    key    = naturalKey(title),
  }
end

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
    if seenPaths[path] then return end
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

  -- Artist/Album/*.dfpwm, Artist - Album/*.dfpwm, and music/ as a container
  local function scanArtistTree(root)
    for _, entry in ipairs(fs.list(root)) do
      local entryPath = fs.combine(root, entry)
      if fs.isDir(entryPath) then
        -- "music" under a root is a library container, not an artist
        if entry:lower() == "music" then
          scanArtistTree(entryPath)
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
            -- music/<Artist> - <Album>/*.dfpwm
            addAudioInDir(entryPath, parsedArtist, parsedAlbum)
          elseif hasAlbumDirs then
            -- true Artist/Album/*.dfpwm tree (album names may contain " - ")
            for _, albumName in ipairs(children) do
              local albumPath = fs.combine(entryPath, albumName)
              if fs.isDir(albumPath) then
                addAudioInDir(albumPath, entry, albumName)
              elseif isAudio(albumName) then
                addTrack(entry, "Singles", albumPath, albumName)
              end
            end
          elseif hasDirectAudio then
            -- legacy: root/Album/*.dfpwm  (folder as album under "Various")
            addAudioInDir(entryPath, "Various", entry)
          end
        end
      elseif isAudio(entry) then
        addTrack("Singles", "Singles", entryPath, entry)
      end
    end
  end

  -- Prefer mounts that exist. Walk each disk mount once (music/ is recursed);
  -- still accept explicit diskN/music roots when the parent mount is absent.
  local scanned = {}
  local function scanRoot(root)
    if scanned[root] or not (fs.exists(root) and fs.isDir(root)) then return end
    scanned[root] = true
    scanArtistTree(root)
  end
  for _, root in ipairs(CONFIG.roots) do
    local parent = root:match("^(disk%d*)/music$") or (root == "disk/music" and "disk") or nil
    if parent then
      if fs.exists(parent) and fs.isDir(parent) then
        scanRoot(parent) -- covers parent/music via container recurse
      else
        scanRoot(root)
      end
    else
      scanRoot(root)
    end
  end

  -- sort albums & tracks
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

  -- flat track list from real albums only (pocket sync + global All Songs)
  local flat = {}
  for _, ar in ipairs(artistList) do
    for _, al in ipairs(ar.albums) do
      for _, t in ipairs(al.tracks) do
        flat[#flat + 1] = t
      end
    end
  end
  table.sort(flat, function(x, y)
    local ka, kb = naturalKey(x.artist), naturalKey(y.artist)
    if ka ~= kb then return ka < kb end
    local aa, ab = naturalKey(x.album), naturalKey(y.album)
    if aa ~= ab then return aa < ab end
    if x.key ~= y.key then return x.key < y.key end
    return x.path < y.path
  end)

  -- Per-artist synthetic "All Songs" album (all tracks by that artist), then real albums
  for _, ar in ipairs(artistList) do
    local artistFlat = {}
    for _, al in ipairs(ar.albums) do
      for _, t in ipairs(al.tracks) do
        artistFlat[#artistFlat + 1] = t
      end
    end
    table.sort(artistFlat, function(x, y)
      local aa, ab = naturalKey(x.album), naturalKey(y.album)
      if aa ~= ab then return aa < ab end
      if x.key ~= y.key then return x.key < y.key end
      return x.path < y.path
    end)
    if #artistFlat > 0 then
      table.insert(ar.albums, 1, {
        name = "All Songs",
        tracks = artistFlat,
        artist = ar.name,
        virtual = true,
      })
    end
  end

  -- Synthetic top ARTIST: browse/play the entire library as one song list
  if #flat > 0 then
    local allAlbum = {
      name = "All Songs",
      tracks = flat,
      artist = "All Songs",
      virtual = true,
    }
    table.insert(artistList, 1, {
      name = "All Songs",
      albums = { allAlbum },
      virtual = true,
    })
  end

  return artistList, flat
end

local function existingMusicRoots()
  local out = {}
  for _, root in ipairs(CONFIG.roots) do
    if fs.exists(root) and fs.isDir(root) then
      out[#out + 1] = root
    end
  end
  return out
end

artists, allTracks = scan()
if #allTracks == 0 then
  local existing = existingMusicRoots()
  printError("No .dfpwm tracks found.")
  if #existing == 0 then
    print("No music mounts on this computer (music / disk / diskN).")
    print("Attach floppy drives here (or run on the music PC), then F5.")
  else
    local show, n = {}, math.min(5, #existing)
    for i = 1, n do show[i] = existing[i] end
    local extra = #existing > n and (" +" .. (#existing - n) .. " more") or ""
    print(string.format("Mounted roots: %d (%s%s) — none contain playable .dfpwm.",
      #existing, table.concat(show, ", "), extra))
    print("Layout: disk/Artist/Album/song.dfpwm  (or disk/music/... / music/...)")
    print("If sort-music --apply ran earlier, tracks may have been deleted — restore/re-import, then F5.")
  end
  return
end
do
  local nArtists = 0
  for _, a in ipairs(artists) do
    if not a.virtual then nArtists = nArtists + 1 end
  end
  print("Library: " .. nArtists .. " artists, " .. #allTracks .. " songs")
end

------------------------------------------------------------------ disk space (music floppies)
-- Totals free/used across unique disk / diskN mounts. Refreshed on the UI timer.
local diskSpace = { free = 0, used = 0, drives = 0, label = "", lastCheck = 0 }

local function refreshDiskSpace(force)
  local t = now()
  if not force and diskSpace.lastCheck > 0
      and (t - diskSpace.lastCheck) < CONFIG.diskSpaceInterval then
    return
  end
  diskSpace.lastCheck = t

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

  for _, root in ipairs(CONFIG.roots) do
    local mount = root:match("^(disk%d*)")
    if mount then consider(mount) end
  end

  diskSpace.free = totalFree
  diskSpace.used = totalUsed
  diskSpace.drives = nDrives
  if nDrives == 0 then
    diskSpace.label = "no disks"
  else
    diskSpace.label = string.format("%s used - %s free",
      fmtBytes(totalUsed), fmtBytes(totalFree))
    if nDrives > 1 then
      diskSpace.label = diskSpace.label .. string.format(" (%d disks)", nDrives)
    end
  end
end

refreshDiskSpace(true)

------------------------------------------------------------------ player state
local S = {
  queue = {}, order = {}, opos = 0,
  cur = nil, src = nil,   -- src = album table currently queued
  paused = false, running = false,
  volume = settings.volume, muted = settings.muted,
  shuffle = settings.shuffle, rep = settings.rep,
  dj = settings.dj,        -- whole-library random flips + mid-song cuts + SFX fades
  fadeMul = 1,             -- 0..1 multiplier on speaker volume (DJ crossfade)
  fadeInFrom = nil,        -- now() when fade-in started, or nil
  fadeInDur = 0,
  djCutAt = nil,           -- absolute now() when next mid-song DJ flip fires
  djCutPausedLeft = nil,   -- remaining wait seconds while paused (frozen)
  gen = 0, pos0 = 0, t0 = 0, sent = 0,
  status = "", statusUntil = 0,
  dirty = false, volDirty = nil, fails = 0, spkDirty = nil,
  syncDirty = false,   -- pocket should rebroadcast
  vizDirty = true,     -- force a viz state packet soon
  lyrics = settings.lyrics,  -- side monitors show large lyric line when on
  lyricLines = {},     -- { {t=sec, text=...}, ... } for current track
  lyricIdx = 0,        -- 1-based index of active line (0 = none)
  lyricText = "",      -- current line text broadcast to visualizers
}

-- Best-effort levels for side visualizers (CC has no real FFT).
-- Contiguous RMS buckets + overall energy + a downsampled waveform from each PCM chunk.
local vizLevels = {
  energy = 0,
  bands = {},
  wave = {},
  peak = 0,
  t = 0,
}

do
  local zb, zw = {}, {}
  for i = 1, CONFIG.vizBands do zb[i] = 0 end
  for i = 1, CONFIG.vizWave do zw[i] = 0 end
  vizLevels.bands, vizLevels.wave = zb, zw
end

local function analyzePcm(buf)
  local n = #buf
  if n < 1 then return end
  local nb = CONFIG.vizBands
  local nw = CONFIG.vizWave
  local sumSq = 0
  local bands, wave = vizLevels.bands, vizLevels.wave
  local per = math.max(1, math.floor(n / nb))

  for b = 1, nb do
    local a = (b - 1) * per + 1
    local z = (b == nb) and n or math.min(n, b * per)
    local bs, count = 0, 0
    for i = a, z do
      local s = buf[i]
      bs = bs + s * s
      count = count + 1
    end
    local rms = math.sqrt(bs / math.max(1, count)) / 128
    -- light attack / slower release so bars don't flicker between chunks
    local prev = bands[b] or 0
    local level = math.min(1, rms)
    bands[b] = (level >= prev) and level or (prev * 0.72 + level * 0.28)
    sumSq = sumSq + bs
  end

  local energy = math.min(1, math.sqrt(sumSq / n) / 128)
  local prevE = vizLevels.energy
  vizLevels.energy = (energy >= prevE) and energy or (prevE * 0.75 + energy * 0.25)
  vizLevels.peak = math.max(vizLevels.peak * 0.92, vizLevels.energy)

  for i = 1, nw do
    local idx = math.floor((i - 0.5) / nw * n) + 1
    local s = buf[math.min(n, math.max(1, idx))] / 128
    if s > 1 then s = 1 elseif s < -1 then s = -1 end
    wave[i] = s
  end
  vizLevels.t = now()
  S.vizDirty = true
end

local function decayVizLevels()
  local bands = vizLevels.bands
  for i = 1, #bands do bands[i] = bands[i] * 0.85 end
  vizLevels.energy = vizLevels.energy * 0.85
  vizLevels.peak = vizLevels.peak * 0.9
  local wave = vizLevels.wave
  for i = 1, #wave do wave[i] = wave[i] * 0.9 end
end

local function saveSettings()
  local f = fs.open(CONFIG.settingsFile, "w")
  if not f then return end
  f.write(textutils.serialize({
    volume = S.volume, muted = S.muted, shuffle = S.shuffle, rep = S.rep, dj = S.dj,
    lyrics = S.lyrics,
    accent = settings.accent,
    textScale = settings.textScale,
    animations = settings.animations,
    vizMode = settings.vizMode,
  }))
  f.close()
end

local function setStatus(msg)
  S.status = msg
  S.statusUntil = now() + 4
end

local function stopSpeakers()
  for _, sp in ipairs(speakers) do pcall(sp.stop) end
end

local function effectiveVolume()
  local v = S.muted and 0 or S.volume
  local mul = S.fadeMul
  if type(mul) == "number" and mul < 1 then
    v = v * math.max(0, mul)
  end
  return v
end

-- Update fadeMul during fade-in (chunk-granularity; CC can't re-volume buffered audio)
local function tickFadeIn()
  if not S.fadeInFrom then return end
  local dur = S.fadeInDur > 0 and S.fadeInDur or CONFIG.djFadeIn
  local t = (now() - S.fadeInFrom) / dur
  if t >= 1 then
    S.fadeMul = 1
    S.fadeInFrom = nil
  else
    S.fadeMul = math.max(0, math.min(1, t))
  end
end

local function fadeOut(dur)
  dur = dur or CONFIG.djFadeOut
  local steps = 6
  for i = steps - 1, 0, -1 do
    S.fadeMul = i / steps
    sleep(dur / steps)
  end
  S.fadeMul = 0
  stopSpeakers()
end

local function beginFadeIn(dur)
  S.fadeMul = 0
  S.fadeInFrom = now()
  S.fadeInDur = dur or CONFIG.djFadeIn
end

-- Scan sfx/ for DJ stings (SFX1.dfpwm, "SFX 2.dfpwm", …). Re-lists each flip
-- so you can drop more files without editing the program.
local function scanDjSfx()
  local dir = CONFIG.sfxDir
  local list = {}
  if not fs.exists(dir) or not fs.isDir(dir) then return list end
  for _, name in ipairs(fs.list(dir)) do
    local path = fs.combine(dir, name)
    if not fs.isDir(path) and name:lower():match("^sfx.*%.dfpwm$") then
      local ok, size = pcall(fs.getSize, path)
      if ok and type(size) == "number" and size > 0 then
        list[#list + 1] = path
      end
    end
  end
  table.sort(list)
  return list
end

-- Play one DFPWM sting on all speakers at user volume (ignores fadeMul).
-- Speakers are idle between tracks; blocks until the buffer drains.
local function playDjSfxFile(path)
  local f = fs.open(path, "rb")
  if not f then return false end
  local decoder = dfpwm.make_decoder()
  local vol = S.muted and 0 or S.volume
  local played = false
  while true do
    local chunk = f.read(CHUNK)
    if not chunk then break end
    local buf = decoder(chunk)
    local pending = {}
    for i = 1, #speakers do pending[i] = true end
    while true do
      local waiting = false
      for i, sp in ipairs(speakers) do
        if pending[i] then
          local okCall, accepted = pcall(sp.playAudio, buf, vol)
          if not okCall or accepted then
            pending[i] = nil
            played = true
          else
            waiting = true
          end
        end
      end
      if not waiting then break end
      local tid = os.startTimer(0.25)
      repeat
        local ev, id = os.pullEvent()
      until ev == "speaker_audio_empty" or (ev == "timer" and id == tid)
    end
  end
  f.close()
  if played then
    -- Let the last buffer finish before stopping / starting the next track
    local drain = os.startTimer(0.35)
    repeat
      local ev, id = os.pullEvent()
    until (ev == "timer" and id == drain) or ev == "speaker_audio_empty"
  end
  stopSpeakers()
  return played
end

-- DJ transition: random sfx/SFX*.dfpwm, else short hat playNote blip
local function djTransitionBlip()
  local files = scanDjSfx()
  if #files > 0 then
    local path = files[math.random(#files)]
    if playDjSfxFile(path) then return end
  end
  for _, sp in ipairs(speakers) do
    pcall(function() sp.playNote("hat", 0.7, 18) end)
  end
  sleep(0.07)
  stopSpeakers()
end

local function position()
  local t = S.cur
  if not t then return 0 end
  local p = S.pos0
  if S.running and not S.paused then
    p = p + math.min(now() - S.t0, S.sent)
  end
  return math.min(p, t.dur)
end

------------------------------------------------------------------ synced lyrics (.lrc beside track or under lyrics/)
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
  -- spilled pack trees: disk/lyrics, diskN/lyrics (sort-music multi-disk mirror)
  local lyricMounts = { "disk", "disk1" }
  for i = 2, 16 do lyricMounts[#lyricMounts + 1] = "disk" .. i end
  for _, m in ipairs(lyricMounts) do
    if fs.exists(m) then
      list[#list + 1] = fs.combine(m, "lyrics", artist, album, base .. ".lrc")
      list[#list + 1] = fs.combine(m, "lyrics", artist, album, title .. ".lrc")
    end
  end
  for _, root in ipairs(CONFIG.roots) do
    if path:sub(1, #root) == root then
      local rel = path:sub(#root + 2)
      if rel and rel ~= "" then
        local relLrc = rel:gsub("%.[Dd][Ff][Pp][Ww][Mm]$", ".lrc")
        list[#list + 1] = fs.combine("lyrics", relLrc)
        for _, m in ipairs(lyricMounts) do
          if fs.exists(m) then
            list[#list + 1] = fs.combine(m, "lyrics", relLrc)
          end
        end
      end
    end
  end
  return list
end

local function parseLrc(text)
  local lines = {}
  if type(text) ~= "string" or text == "" then return lines end
  for raw in text:gmatch("[^\r\n]+") do
    if not raw:match("^%s*;") then
      local stamps = {}
      for mm, ss in raw:gmatch("%[(%d+):(%d+%.?%d*)%]") do
        stamps[#stamps + 1] = tonumber(mm) * 60 + tonumber(ss)
      end
      local body = raw:gsub("%[%d+:%d+%.?%d*%]", ""):gsub("^%s+", ""):gsub("%s+$", "")
      if #stamps > 0 and body ~= "" then
        for _, t in ipairs(stamps) do
          lines[#lines + 1] = { t = t, text = body }
        end
      end
    end
  end
  table.sort(lines, function(a, b) return a.t < b.t end)
  return lines
end

local function loadLyricsFor(track)
  S.lyricLines = {}
  S.lyricIdx = 0
  S.lyricText = ""
  if not track then return end
  for _, cand in ipairs(lrcCandidates(track)) do
    if fs.exists(cand) and not fs.isDir(cand) then
      local f = fs.open(cand, "r")
      if f then
        local body = f.readAll() or ""
        f.close()
        local parsed = parseLrc(body)
        if #parsed > 0 then
          S.lyricLines = parsed
          track.hasLyrics = true
          return
        end
      end
    end
  end
  track.hasLyrics = false
end

-- Same paths as playback; cached on the track (cleared on F5 rescan via new objects).
local function trackHasLyrics(track)
  if not track then return false end
  if track.hasLyrics ~= nil then return track.hasLyrics end
  local has = false
  for _, cand in ipairs(lrcCandidates(track)) do
    if fs.exists(cand) and not fs.isDir(cand) then
      local ok, sz = pcall(fs.getSize, cand)
      if ok and type(sz) == "number" and sz > 0 then
        local f = fs.open(cand, "r")
        if f then
          local body = f.readAll() or ""
          f.close()
          -- would loadLyricsFor succeed? needs at least one timed line
          if body:find("%[%d+:%d+") and #parseLrc(body) > 0 then
            has = true
            break
          end
        end
      end
    end
  end
  track.hasLyrics = has
  return has
end

local function lyricAt(pos)
  local lines = S.lyricLines
  if not lines or #lines == 0 then return 0, "" end
  local idx = 0
  for i = 1, #lines do
    if lines[i].t <= pos then idx = i else break end
  end
  if idx == 0 then return 0, "" end
  return idx, lines[idx].text or ""
end

local function refreshLyricLine()
  if not S.lyrics or not S.cur then
    if S.lyricText ~= "" then
      S.lyricText = ""
      S.lyricIdx = 0
      S.vizDirty = true
    end
    return
  end
  local idx, text = lyricAt(position())
  if idx ~= S.lyricIdx or text ~= S.lyricText then
    S.lyricIdx = idx
    S.lyricText = text
    S.vizDirty = true
  end
end

local function toggleLyrics()
  S.lyrics = not S.lyrics
  S.dirty = true
  S.vizDirty = true
  if S.lyrics then
    refreshLyricLine()
    setStatus("Lyrics ON — side monitors show current line")
  else
    S.lyricText = ""
    setStatus("Lyrics OFF")
  end
end

local function restart(keepAudio)
  if not keepAudio then stopSpeakers() end
  S.gen = S.gen + 1
  S.sent = 0
  S.t0 = now()
  S.syncDirty = true
  os.queueEvent("jukebox_wake")
end

local function startTrack(track, sec, keepAudio)
  S.cur = track
  S.pos0 = sec or 0
  S.paused = false
  loadLyricsFor(track)
  refreshLyricLine()
  restart(keepAudio)
end

local function buildOrder(startIdx)
  local n = #S.queue
  local order = {}
  for i = 1, n do order[i] = i end
  if S.shuffle then
    for i = n, 2, -1 do
      local j = math.random(i)
      order[i], order[j] = order[j], order[i]
    end
    if startIdx then
      for i = 1, n do
        if order[i] == startIdx then
          order[1], order[i] = order[i], order[1]
          break
        end
      end
    end
  end
  S.order = order
  S.opos = 1
  if startIdx then
    for i = 1, n do
      if order[i] == startIdx then
        S.opos = i
        break
      end
    end
  end
end

-- Forward decls: play/stop arm the mid-song timer before djAdvance is defined below
local clearDjCut, scheduleDjCut, djAdvance, tickDjCut

local function playAlbum(album, startIdx)
  if not album or #album.tracks == 0 then return end
  S.src = album
  S.queue = album.tracks
  S.fails = 0
  S.fadeMul = 1
  S.fadeInFrom = nil
  buildOrder(startIdx)
  startTrack(S.queue[S.order[S.opos]], 0)
  scheduleDjCut()
end

local function playAllFrom(startIdx)
  if #allTracks == 0 then return end
  local album = artists[1] and artists[1].virtual and artists[1].albums[1]
  S.src = album or { name = "All Songs", tracks = allTracks, virtual = true, artist = "All Songs" }
  S.queue = allTracks
  S.fails = 0
  S.fadeMul = 1
  S.fadeInFrom = nil
  buildOrder(startIdx)
  startTrack(S.queue[S.order[S.opos]], 0)
  scheduleDjCut()
end

local function stopPlayback()
  S.cur = nil
  S.paused = false
  S.running = false
  S.pos0 = 0
  S.fadeMul = 1
  S.fadeInFrom = nil
  S.lyricLines = {}
  S.lyricIdx = 0
  S.lyricText = ""
  clearDjCut()
  stopSpeakers()
  S.gen = S.gen + 1
  S.syncDirty = true
  S.vizDirty = true
  decayVizLevels()
  os.queueEvent("jukebox_wake")
end

-- DJ: pick a different track index from the WHOLE library (allTracks)
local function djPickLibraryIndex()
  local n = #allTracks
  if n < 1 then return nil end
  if n == 1 then return 1 end
  local curPath = S.cur and S.cur.path
  local nextIdx
  repeat
    nextIdx = math.random(n)
  until not curPath or allTracks[nextIdx].path ~= curPath
  return nextIdx
end

-- Mid-song auto-cut: wait random(djCutMin..djCutMax), capped by remaining track
-- so short leftovers don't thrash; skip if <2 library songs or less than djCutMin left.
clearDjCut = function()
  S.djCutAt = nil
  S.djCutPausedLeft = nil
end

scheduleDjCut = function()
  clearDjCut()
  if not S.dj or not S.cur or S.paused then return end
  if #allTracks < 2 then return end
  local rem = math.max(0, (S.cur.dur or 0) - position())
  local lo = CONFIG.djCutMin
  local hi = CONFIG.djCutMax
  if type(lo) ~= "number" or type(hi) ~= "number" then return end
  if hi < lo then lo, hi = hi, lo end
  if rem < lo then return end  -- let natural end-of-track DJ handle it
  hi = math.min(hi, rem)
  if hi < lo then return end
  local wait = lo + math.random() * (hi - lo)
  S.djCutAt = now() + wait
end

-- Every DJ flip (mid-song + next/end): fade → random sfx/SFX*.dfpwm → fade-in
djAdvance = function(auto)
  local nextIdx = djPickLibraryIndex()
  if not nextIdx or not allTracks[nextIdx] then return end
  clearDjCut()
  -- Mid-track / manual: fade out current audio; end-of-track: already silent → skip fade-out
  if not auto and S.cur and not S.paused then
    fadeOut(CONFIG.djFadeOut)
  else
    S.fadeMul = 0
    stopSpeakers()
  end
  djTransitionBlip()  -- random sfx/SFX*.dfpwm (or hat playNote fallback)
  -- Promote queue to whole library so UI / order match the DJ pool
  local libAlbum = artists[1] and artists[1].virtual and artists[1].albums[1]
  S.src = libAlbum or { name = "All Songs", tracks = allTracks, virtual = true, artist = "All Songs" }
  S.queue = allTracks
  buildOrder(nextIdx)
  beginFadeIn(CONFIG.djFadeIn)
  startTrack(allTracks[nextIdx], 0, auto)
  scheduleDjCut()
  setStatus("DJ → " .. (allTracks[nextIdx].title or "?"))
end

-- UI timer (~0.5s): fire scheduled mid-song DJ flip (same fade → SFX → fade-in)
tickDjCut = function()
  if not S.dj or not S.djCutAt or not S.cur or S.paused then return end
  if now() < S.djCutAt then return end
  S.djCutAt = nil
  if #allTracks < 2 then return end
  djAdvance(false)
end

local function advance(dir, auto)
  local n = #S.order
  if n == 0 then return end
  if auto and S.rep == "one" and S.cur then
    startTrack(S.cur, 0, true)
    scheduleDjCut()
    return
  end
  -- DJ on: forward next (manual or auto) = whole-library random flip + SFX transition
  if S.dj and dir == 1 then
    if auto and S.rep == "off" and #allTracks <= 1 then
      stopPlayback()
      return
    end
    djAdvance(auto)
    return
  end
  local np = S.opos + dir
  if np > n then
    if auto and S.rep == "off" then
      stopPlayback()
      return
    end
    if S.shuffle then
      local lastIdx = S.order[S.opos]
      buildOrder(nil)
      if #S.order > 1 and S.order[1] == lastIdx then
        S.order[1], S.order[2] = S.order[2], S.order[1]
      end
    end
    np = 1
  elseif np < 1 then
    np = n
  end
  S.opos = np
  startTrack(S.queue[S.order[np]], 0, auto)
  scheduleDjCut()  -- no-op when DJ off; re-arms after prev / non-DJ next
end

local function toggleDj()
  S.dj = not S.dj
  S.dirty = true
  S.syncDirty = true
  if S.dj then
    scheduleDjCut()
    setStatus("DJ mode ON — whole-library random cuts + next")
  else
    clearDjCut()
    setStatus("DJ mode OFF")
  end
end

local function prevTrack()
  if not S.cur then return end
  if position() > 3 then
    S.pos0 = 0
    if S.paused then return end
    restart()
  else
    advance(-1, false)
  end
end

local function togglePause()
  if not S.cur then
    if #S.order > 0 then
      startTrack(S.queue[S.order[S.opos]], 0)
      scheduleDjCut()
    end
    S.syncDirty = true
    return false
  end
  if S.paused then
    S.paused = false
    restart()
    -- Resume: restore frozen mid-song wait, or arm a fresh one
    if S.dj then
      if S.djCutPausedLeft then
        S.djCutAt = now() + S.djCutPausedLeft
        S.djCutPausedLeft = nil
      else
        scheduleDjCut()
      end
    end
  else
    S.pos0 = position()
    S.paused = true
    S.running = false
    stopSpeakers()
    S.gen = S.gen + 1
    S.syncDirty = true
    S.vizDirty = true
    -- Freeze mid-song countdown while paused
    if S.djCutAt then
      S.djCutPausedLeft = math.max(0, S.djCutAt - now())
      S.djCutAt = nil
    end
    os.queueEvent("jukebox_wake")
  end
  return true
end

local function seekTo(sec)
  if not S.cur then return end
  S.pos0 = clamp(sec, 0, math.max(0, S.cur.dur - 1))
  if S.paused then return end
  restart()
end

local function setVolume(v)
  S.volume = clamp(v, 0, CONFIG.maxVolume)
  S.muted = false
  S.volDirty = now()
  S.dirty = true
  S.syncDirty = true
end

local function toggleMute()
  S.muted = not S.muted
  S.volDirty = now()
  S.dirty = true
  S.syncDirty = true
end

local function toggleShuffle()
  S.shuffle = not S.shuffle
  S.dirty = true
  S.syncDirty = true
  if #S.queue > 0 then
    buildOrder(S.order[S.opos])
  end
end

local function cycleRepeat()
  S.rep = (S.rep == "off" and "all") or (S.rep == "all" and "one") or "off"
  S.dirty = true
end

------------------------------------------------------------------ player thread
local function pushAudio(buf, gen)
  local pending = {}
  for i = 1, #speakers do pending[i] = true end
  while true do
    if S.gen ~= gen then return false end
    local waiting = false
    for i, sp in ipairs(speakers) do
      if pending[i] then
        local okCall, accepted = pcall(sp.playAudio, buf, effectiveVolume())
        if not okCall or accepted then
          pending[i] = nil
        else
          waiting = true
        end
      end
    end
    if not waiting then return true end
    local tid = os.startTimer(0.25)
    repeat
      local ev, id = os.pullEvent()
    until S.gen ~= gen or ev == "speaker_audio_empty" or (ev == "timer" and id == tid)
  end
end

local function streamCurrent()
  local track = S.cur
  local gen = S.gen
  local f = fs.open(track.path, "rb")
  if not f then
    S.fails = S.fails + 1
    setStatus("Cannot open " .. track.title)
    if S.fails > #S.order then
      stopPlayback()
    else
      advance(1, true)
    end
    return
  end
  S.fails = 0
  f.seek("set", math.floor(S.pos0 * SAMPLE_RATE / 8))
  local decoder = dfpwm.make_decoder()
  S.running = true
  S.t0 = now()
  S.sent = 0
  S.vizDirty = true

  while S.gen == gen do
    tickFadeIn()
    local chunk = f.read(CHUNK)
    if not chunk then break end
    local buf = decoder(chunk)
    -- Levels for side visualizers (cheap RMS / buckets; does not touch speakers)
    analyzePcm(buf)
    if not pushAudio(buf, gen) then
      f.close()
      return
    end
    S.sent = S.sent + #chunk * 8 / SAMPLE_RATE
  end
  f.close()
  if S.gen ~= gen then return end

  while S.gen == gen and (now() - S.t0) < S.sent - 0.3 do
    local tid = os.startTimer(0.2)
    repeat
      local ev, id = os.pullEvent()
    until S.gen ~= gen or (ev == "timer" and id == tid)
  end
  if S.gen == gen then advance(1, true) end
end

local function playerLoop()
  while true do
    if not S.cur or S.paused then
      S.running = false
      os.pullEvent("jukebox_wake")
    else
      streamCurrent()
    end
  end
end

------------------------------------------------------------------ selection / UI state
local selArtist, selAlbum, selSong = 1, 1, 1
local focus = "artists"   -- artists | albums | songs
local scroll = { artists = 0, albums = 0, songs = 0 }

local function currentArtist() return artists[selArtist] end

local function currentAlbum()
  local ar = currentArtist()
  if not ar then return nil end
  return ar.albums[selAlbum]
end

local function currentSong()
  local al = currentAlbum()
  if not al then return nil end
  return al.tracks[selSong]
end

local function selectArtist(idx)
  if not artists[idx] then return end
  selArtist = idx
  selAlbum = 1
  selSong = 1
  scroll.albums = 0
  scroll.songs = 0
end

local function selectAlbum(idx)
  local ar = currentArtist()
  if not ar or not ar.albums[idx] then return end
  selAlbum = idx
  selSong = 1
  scroll.songs = 0
end

------------------------------------------------------------------ display (paintutils pixel UI)
local mon, monName
if not forceTerm then
  local m = peripheral.find("monitor")
  if m then
    mon, monName = m, peripheral.getName(m)
    mon.setTextScale(clamp(settings.textScale or CONFIG.monitorScale, 0.5, 5))
  end
end
local T = mon or term.current()
local isColor = T.isColor and T.isColor()

local function accentColor()
  return ACCENTS[settings.accent] or colors.purple
end

-- Declare before rebuildPalette so assignments bind the local (not a global).
local P
local function rebuildPalette()
  local ac = accentColor()
  if isColor then
    P = {
      bg = colors.black, fg = colors.white, dim = colors.lightGray,
      panel = colors.gray, muted = colors.gray,
      accent = ac, accentFg = colors.black,
      hdrBg = colors.black, hdrFg = colors.white,
      selBg = ac, selFg = colors.black,
      play = ac, on = ac, off = colors.lightGray,
      barOn = ac, barOff = colors.gray,
      npBg = colors.gray, npFg = colors.white,
      navBg = colors.gray, navFg = colors.lightGray, navOn = ac,
      credit = colors.red,
    }
  else
    P = {
      bg = colors.black, fg = colors.white, dim = colors.lightGray,
      panel = colors.gray, muted = colors.gray,
      accent = colors.white, accentFg = colors.black,
      hdrBg = colors.black, hdrFg = colors.white,
      selBg = colors.white, selFg = colors.black,
      play = colors.white, on = colors.white, off = colors.lightGray,
      barOn = colors.white, barOff = colors.gray,
      npBg = colors.gray, npFg = colors.white,
      navBg = colors.gray, navFg = colors.lightGray, navOn = colors.white,
      credit = colors.white,
    }
  end
end
rebuildPalette()
-- Defensive: never draw with a nil palette (Lua scoping / reload edge cases).
if not P or not P.bg then
  P = {
    bg = colors.black, fg = colors.white, dim = colors.lightGray,
    panel = colors.gray, muted = colors.gray,
    accent = colors.white, accentFg = colors.black,
    hdrBg = colors.black, hdrFg = colors.white,
    selBg = colors.white, selFg = colors.black,
    play = colors.white, on = colors.white, off = colors.lightGray,
    barOn = colors.white, barOff = colors.gray,
    npBg = colors.gray, npFg = colors.white,
    navBg = colors.gray, navFg = colors.lightGray, navOn = colors.white,
    credit = colors.white,
  }
end

local W, H = T.getSize()
local D = window.create(T, 1, 1, W, H, true)
D.setCursorBlink(false)

-- UI navigation (friend-style bottom tabs)
local ui = {
  tab = "music",            -- home | music | library | search | playlists | lyrics | appearance
  browse = "tracks",        -- artists | albums | tracks
  search = "",
  listScroll = 0,
  lyricScroll = 0,
  animPhase = 0,
  showVol = false,          -- VOL overlay on now-playing
  showQueue = false,        -- QUEUE overlay on now-playing
}
local hits = {}
local artCache = {}

local NAV = {
  { id = "home", label = "HOME" },
  { id = "music", label = "MUSIC" },
  { id = "library", label = "LIBRARY" },
  { id = "search", label = "SEARCH" },
  { id = "playlists", label = "PLAYLISTS" },
  { id = "lyrics", label = "LYRICS" },
}

local function withTerm(fn)
  local old = term.redirect(D)
  local ok, err = pcall(fn)
  term.redirect(old)
  if not ok then error(err, 0) end
end

local function fill(x1, y1, x2, y2, col)
  if x2 < x1 or y2 < y1 then return end
  withTerm(function()
    paintutils.drawFilledBox(x1, y1, x2, y2, col or P.bg)
  end)
end

local function put(x, y, s, fg, bg)
  if fg then D.setTextColor(fg) end
  if bg then D.setBackgroundColor(bg) end
  D.setCursorPos(x, y)
  D.write(s)
end

local function putFit(x, y, s, w, fg, bg)
  put(x, y, fit(tostring(s or ""), w), fg, bg)
end

local function addHit(x1, x2, y, fn, drag, y2)
  hits[#hits + 1] = { x1 = x1, x2 = x2, y = y, y1 = y, y2 = y2 or y, fn = fn, drag = drag }
end

local function pill(x, y, w, label, on, fn)
  local bg = on and P.accent or P.panel
  local fg = on and P.accentFg or P.fg
  fill(x, y, x + w - 1, y, bg)
  putFit(x, y, " " .. label, w, fg, bg)
  if fn then addHit(x, x + w - 1, y, fn) end
end

-- Approximate filled ellipse (circular transport / scrubber knob).
local function fillEllipse(cx, cy, rx, ry, col)
  rx = math.max(1, rx)
  ry = math.max(1, ry)
  for dy = -ry, ry do
    local t = 1 - (dy * dy) / (ry * ry)
    if t >= 0 then
      local w = math.floor(rx * math.sqrt(t) + 0.5)
      fill(cx - w, cy + dy, cx + w, cy + dy, col)
    end
  end
end

local function circleBtn(cx, cy, rx, ry, label, on, fn)
  local bg = on and P.accent or P.panel
  local fg = on and P.accentFg or P.fg
  fillEllipse(cx, cy, rx, ry, bg)
  local lab = tostring(label or "")
  put(cx - math.floor(#lab / 2), cy, lab, fg, bg)
  if fn then addHit(cx - rx, cx + rx, cy - ry, fn, false, cy + ry) end
end

local function artPathFor(track)
  if not track or not track.path then return nil end
  local dir = fs.getDir(track.path)
  local base = fs.getName(track.path):gsub("%.[Dd][Ff][Pp][Ww][Mm]$", "")
  local song = fs.combine(dir, base .. ".nfp")
  if fs.exists(song) and not fs.isDir(song) then return song end
  for _, name in ipairs({ "cover.nfp", "album.nfp", "folder.nfp" }) do
    local p = fs.combine(dir, name)
    if fs.exists(p) and not fs.isDir(p) then return p end
  end
  return nil
end

local function loadArt(path)
  if not path then return nil end
  local cached = artCache[path]
  if cached ~= nil then return cached or nil end
  local ok, img = pcall(paintutils.loadImage, path)
  artCache[path] = (ok and img) or false
  return artCache[path] or nil
end

local function drawArt(x, y, track, size)
  size = size or 3
  fill(x, y, x + size - 1, y + size - 1, P.panel)
  local img = loadArt(artPathFor(track))
  if img then
    withTerm(function()
      paintutils.drawImage(img, x, y)
    end)
  else
    -- placeholder square
    put(x + math.floor(size / 2), y + math.floor(size / 2), "?", P.dim, P.panel)
  end
end

local function applyTextScale(scale)
  scale = clamp(tonumber(scale) or CONFIG.monitorScale, 0.5, 5)
  settings.textScale = math.floor(scale * 10 + 0.5) / 10
  CONFIG.monitorScale = settings.textScale
  if mon then
    mon.setTextScale(settings.textScale)
    W, H = T.getSize()
    D.reposition(1, 1, W, H)
  end
  S.dirty = true
  setStatus(string.format("Text scale %.1f", settings.textScale))
end

local function setAccent(name)
  if not ACCENTS[name] then return end
  settings.accent = name
  rebuildPalette()
  S.dirty = true
  S.vizDirty = true
  setStatus("Accent: " .. name)
end

local function setVizMode(mode)
  for _, m in ipairs(VIZ_MODES) do
    if m == mode then
      settings.vizMode = mode
      S.dirty = true
      S.vizDirty = true
      setStatus("Visualizer: " .. mode:upper())
      return
    end
  end
end

local function setTab(id)
  ui.tab = id
  ui.showVol = false
  ui.showQueue = false
  if id == "lyrics" then
    if not S.lyrics then toggleLyrics() end
  elseif id == "home" or id == "music" then
    -- now-playing (AURORA-style)
  elseif id == "library" then
    ui.browse = "tracks"
  elseif id == "playlists" then
    -- jump to library All Songs
    if artists[1] and artists[1].virtual then
      selectArtist(1)
      selectAlbum(1)
    end
    ui.browse = "tracks"
    ui.tab = "library"
  end
end

local function contentTop()
  return 3
end

local function contentBot()
  return math.max(contentTop(), H - 4)
end

local function rowH()
  return 3
end

local function visibleRows()
  return math.max(1, math.floor((contentBot() - contentTop() + 1) / rowH()))
end

local function filteredTracks()
  local al = currentAlbum()
  local tracks = al and al.tracks or {}
  local q = (ui.search or ""):lower()
  if ui.tab ~= "search" or q == "" then return tracks end
  local out = {}
  for _, t in ipairs(tracks) do
    local hay = (t.title .. " " .. t.artist .. " " .. t.album):lower()
    if hay:find(q, 1, true) then out[#out + 1] = t end
  end
  return out
end

local function drawHeader(title, right)
  fill(1, 1, W, 2, P.bg)
  putFit(2, 1, title or "", math.max(8, W - 28), P.fg, P.bg)
  local credit = "ProOnlyUNO"
  put(W - #credit, 1, credit, P.credit, P.bg)
  -- gear → appearance
  put(W - #credit - 5, 1, "CFG", P.accent, P.bg)
  addHit(W - #credit - 5, W - #credit - 3, 1, function() setTab("appearance") end)
  if right and right ~= "" then
    putFit(2, 2, right, W - 2, P.dim, P.bg)
  end
end

local function drawBottomNav()
  local y = H - 1
  fill(1, y, W, H, P.navBg)
  local n = #NAV
  local slot = math.max(6, math.floor(W / n))
  local x = 1
  for _, tab in ipairs(NAV) do
    local on = ui.tab == tab.id or (tab.id == "playlists" and ui.tab == "library" and currentAlbum() and currentAlbum().virtual)
    local fg = on and P.navOn or P.navFg
    putFit(x, y, tab.label, slot - 1, fg, P.navBg)
    addHit(x, x + slot - 2, y, function() setTab(tab.id) end)
    x = x + slot
  end
  -- gear → appearance (top-right alternative also)
  put(W - 3, y, "CFG", P.accent, P.navBg)
  addHit(W - 3, W, y, function() setTab("appearance") end)
end

local function drawMiniTransport()
  -- Compact transport for list / search / lyrics footers
  local y = H - 2
  fill(1, y, W, y, P.bg)
  local playing = S.cur and not S.paused
  local cx = math.floor(W / 2)
  pill(cx - 10, y, 5, "-10", false, function() seekTo(position() - CONFIG.seekStep) end)
  local pLab = playing and " || " or " >  "
  pill(cx - 3, y, 6, pLab, true, function()
    if not togglePause() and not S.cur then
      local al = currentAlbum()
      if al then playAlbum(al, selSong) else playAllFrom(1) end
    end
  end)
  pill(cx + 4, y, 5, "+10", false, function() seekTo(position() + CONFIG.seekStep) end)
  put(W - 11, y, "<<", P.fg, P.bg)
  put(W - 7, y, ">>", P.fg, P.bg)
  addHit(W - 11, W - 10, y, prevTrack)
  addHit(W - 7, W - 6, y, function() if S.cur then advance(1, false) end end)
end

local function drawTrackList()
  local tracks = filteredTracks()
  local rh = rowH()
  local rows = visibleRows()
  local top = contentTop()
  ui.listScroll = clamp(ui.listScroll, 0, math.max(0, #tracks - rows))
  local ar = currentArtist()
  local al = currentAlbum()
  local hdr = (al and al.name) or (ar and ar.name) or "LIBRARY"
  drawHeader(hdr:upper(), diskSpace.label ~= "" and diskSpace.label or "CC Music")

  -- breadcrumb controls
  put(2, 2, "[ARTISTS]", P.dim, P.bg)
  addHit(2, 10, 2, function() ui.browse = "artists"; ui.listScroll = 0 end)
  put(12, 2, "[ALBUMS]", P.dim, P.bg)
  addHit(12, 19, 2, function() ui.browse = "albums"; ui.listScroll = 0 end)
  put(21, 2, "[TRACKS]", P.accent, P.bg)
  addHit(21, 28, 2, function() ui.browse = "tracks"; ui.listScroll = 0 end)

  if ui.browse == "artists" then
    for r = 0, rows - 1 do
      local idx = ui.listScroll + r + 1
      local a = artists[idx]
      local y = top + r * rh
      if a then
        local sel = idx == selArtist
        local bg = sel and P.selBg or P.bg
        local fg = sel and P.selFg or P.fg
        fill(1, y, W, y + rh - 2, bg)
        putFit(3, y, a.name, W - 6, fg, bg)
        addHit(1, W, y, function()
          selectArtist(idx)
          ui.browse = "albums"
          ui.listScroll = 0
        end)
        addHit(1, W, y + 1, function()
          selectArtist(idx)
          ui.browse = "albums"
          ui.listScroll = 0
        end)
      end
    end
    return
  end

  if ui.browse == "albums" then
    local albums = ar and ar.albums or {}
    for r = 0, rows - 1 do
      local idx = ui.listScroll + r + 1
      local a = albums[idx]
      local y = top + r * rh
      if a then
        local sel = idx == selAlbum
        local bg = sel and P.selBg or P.bg
        local fg = sel and P.selFg or P.fg
        fill(1, y, W, y + rh - 2, bg)
        local sample = a.tracks and a.tracks[1]
        if sample then drawArt(2, y, sample, 2) end
        putFit(5, y, a.name, W - 8, fg, bg)
        putFit(5, y + 1, tostring(#(a.tracks or {})) .. " tracks", W - 8, sel and P.selFg or P.dim, bg)
        addHit(1, W, y, function()
          selectAlbum(idx)
          ui.browse = "tracks"
          ui.listScroll = 0
        end)
        addHit(1, W, y + 1, function()
          selectAlbum(idx)
          ui.browse = "tracks"
          ui.listScroll = 0
        end)
      end
    end
    return
  end

  -- tracks (friend album-list look)
  for r = 0, rows - 1 do
    local idx = ui.listScroll + r + 1
    local t = tracks[idx]
    local y = top + r * rh
    if t then
      local sel = (al and al.tracks[selSong] and al.tracks[selSong].path == t.path)
        or (S.cur and S.cur.path == t.path)
      local bg = sel and P.selBg or P.bg
      local fg = sel and P.selFg or P.fg
      fill(1, y, W - 1, y + rh - 2, bg)
      drawArt(2, y, t, 2)
      local titleW = math.max(8, W - 14)
      putFit(5, y, t.title, titleW, fg, bg)
      putFit(5, y + 1, t.artist or "", titleW, sel and P.selFg or P.dim, bg)
      local dur = rjust(fmt(t.dur), 5)
      put(W - 6, y, dur, sel and P.selFg or P.dim, bg)
      if trackHasLyrics(t) then
        put(W - 8, y + 1, "L", P.accent, bg)
      end
      addHit(1, W - 1, y, function()
        if ui.tab == "search" and (ui.search or "") ~= "" then
          for i, tr in ipairs(al.tracks) do
            if tr.path == t.path then selSong = i; playAlbum(al, i); return end
          end
        else
          selSong = idx
          playAlbum(al, idx)
        end
      end)
      addHit(1, W - 1, y + 1, function()
        if ui.tab == "search" and (ui.search or "") ~= "" then
          for i, tr in ipairs(al.tracks) do
            if tr.path == t.path then selSong = i; playAlbum(al, i); return end
          end
        else
          selSong = idx
          playAlbum(al, idx)
        end
      end)
    end
  end
  -- scrollbar
  if #tracks > rows then
    local th = math.max(1, math.floor(rows * rows / #tracks))
    local tp = math.floor(ui.listScroll / math.max(1, #tracks - rows) * (rows - th) + 0.5)
    for r = 0, rows - 1 do
      local y = top + r * rh
      local on = r >= tp and r < tp + th
      fill(W, y, W, y + rh - 2, on and P.accent or P.panel)
    end
  end
end

-- AURORA-style now playing (friend ref): art, scrubber, circular transport,
-- LRC / QUEUE / VOL — no LIKE, no FOLLOW. Brand ProOnlyUNO / CC Music.
local function drawNowPlaying()
  drawHeader("CC MUSIC", "Developer: ProOnlyUNO")
  local t = S.cur
  local bot = H - 3
  local artSize = clamp(math.min(14, math.floor(H / 4)), 6, 14)
  local metaX = 3 + artSize + 2
  local metaW = math.max(10, W - metaX - 1)

  if t then
    drawArt(3, 3, t, artSize)
    putFit(metaX, 3, "NOW PLAYING", metaW, P.accent, P.bg)
    putFit(metaX, 5, t.title or "?", metaW, P.fg, P.bg)
    putFit(metaX, 6, t.artist or "", metaW, P.dim, P.bg)
    putFit(metaX, 7, t.album or "", metaW, P.dim, P.bg)
    local qn = #S.queue
    local qi = S.opos or 0
    if qn > 0 then
      putFit(metaX, 8, string.format("%d / %d  .  %s", qi, qn, t.album or ""), metaW, P.dim, P.bg)
    end
  else
    fill(3, 3, 3 + artSize - 1, 3 + artSize - 1, P.panel)
    put(3 + math.floor(artSize / 2), 3 + math.floor(artSize / 2), "?", P.dim, P.panel)
    putFit(metaX, 5, "Nothing playing", metaW, P.dim, P.bg)
    putFit(metaX, 6, "Open LIBRARY to pick a track", metaW, P.dim, P.bg)
  end

  -- Scrubber
  local scrubY = math.max(3 + artSize + 1, 12)
  if scrubY > bot - 10 then scrubY = math.max(10, bot - 10) end
  local barX1, barX2 = 4, W - 3
  local pos = t and position() or 0
  local dur = t and (t.dur or 0) or 0
  put(barX1, scrubY - 1, "-10", P.accent, P.bg)
  addHit(barX1, barX1 + 2, scrubY - 1, function() seekTo(position() - CONFIG.seekStep) end)
  put(barX2 - 2, scrubY - 1, "+10", P.accent, P.bg)
  addHit(barX2 - 2, barX2, scrubY - 1, function() seekTo(position() + CONFIG.seekStep) end)
  fill(barX1, scrubY, barX2, scrubY, P.panel)
  local span = math.max(1, barX2 - barX1)
  local filled = (dur > 0) and clamp(math.floor(pos / dur * span + 0.5), 0, span) or 0
  if filled > 0 then fill(barX1, scrubY, barX1 + filled - 1, scrubY, P.accent) end
  local knobX = barX1 + filled
  fillEllipse(knobX, scrubY, 1, 1, colors.white)
  addHit(barX1, barX2, scrubY, function(x)
    if dur > 0 then seekTo((x - barX1) / span * dur) end
  end, true)
  put(barX1, scrubY + 1, fmt(pos), P.dim, P.bg)
  local durStr = fmt(dur)
  put(barX2 - #durStr + 1, scrubY + 1, durStr, P.dim, P.bg)

  -- Circular transport: shuffle | prev | play | next | repeat
  local trY = scrubY + 3
  local cx = math.floor(W / 2)
  local gap = math.max(6, math.floor(W / 14))
  circleBtn(cx - gap * 2, trY, 2, 1, S.shuffle and "SH" or "sh", S.shuffle, toggleShuffle)
  circleBtn(cx - gap, trY, 2, 1, "<<", false, prevTrack)
  local playing = S.cur and not S.paused
  circleBtn(cx, trY, 3, 2, playing and "||" or ">", true, function()
    if not togglePause() and not S.cur then
      local al = currentAlbum()
      if al then playAlbum(al, selSong) else playAllFrom(1) end
    end
  end)
  circleBtn(cx + gap, trY, 2, 1, ">>", false, function() if S.cur then advance(1, false) end end)
  local repOn = S.rep ~= "off"
  local repLab = (S.rep == "one" and "R1") or (S.rep == "all" and "RA") or "rp"
  circleBtn(cx + gap * 2, trY, 2, 1, repLab, repOn, cycleRepeat)

  -- Utility row: LRC / QUEUE / VOL  (no LIKE)
  local utilY = trY + 4
  local bw = math.max(8, math.floor((W - 8) / 3))
  local ux = math.floor((W - bw * 3 - 4) / 2)
  pill(ux, utilY, bw, " LRC", ui.tab == "lyrics", function() setTab("lyrics") end)
  pill(ux + bw + 2, utilY, bw, " QUEUE", ui.showQueue, function()
    ui.showQueue = not ui.showQueue
    ui.showVol = false
    S.dirty = true
  end)
  pill(ux + (bw + 2) * 2, utilY, bw, " VOL", ui.showVol, function()
    ui.showVol = not ui.showVol
    ui.showQueue = false
    S.dirty = true
  end)

  local infoY = utilY + 2
  local hasLrc = t and trackHasLyrics(t)
  local lrcMsg = hasLrc and "SYNCED LRC  .  TAP LRC" or "NO LYRICS  .  TAP TO VIEW"
  putFit(3, infoY, lrcMsg, W - 16, hasLrc and P.accent or P.dim, P.bg)
  put(W - 10, infoY, "LIVE PCM", P.dim, P.bg)
  addHit(3, math.min(W - 16, 3 + #lrcMsg), infoY, function() setTab("lyrics") end)

  -- Mini viz strip (pixel blocks from PCM bands)
  local vizY = infoY + 1
  if vizY < bot then
    local bands = vizLevels.bands or {}
    local n = math.max(1, #bands)
    local vw = W - 4
    for i = 1, vw do
      local bi = math.floor((i - 1) / vw * n) + 1
      local v = bands[bi] or 0
      local on = v > 0.08 or (settings.animations and ((ui.animPhase + i) % 7) == 0 and S.cur and not S.paused)
      fill(2 + i, vizY, 2 + i, vizY, on and P.accent or P.panel)
    end
  end

  -- VOL overlay
  if ui.showVol then
    local vy = math.min(bot - 1, utilY + 4)
    fill(3, vy, W - 2, vy, P.panel)
    put(3, vy, "VOL", P.fg, P.panel)
    local vx1, vx2 = 8, W - 10
    local vfill = math.floor(S.volume / CONFIG.maxVolume * (vx2 - vx1 + 1) + 0.5)
    fill(vx1, vy, vx2, vy, P.muted)
    if vfill > 0 then fill(vx1, vy, vx1 + vfill - 1, vy, P.accent) end
    addHit(vx1, vx2, vy, function(x)
      setVolume(((x - vx1) / math.max(1, vx2 - vx1)) * CONFIG.maxVolume)
    end, true)
    local pct = S.muted and "MUTE" or (math.floor(S.volume * 100 + 0.5) .. "%")
    put(W - 6, vy, fit(pct, 5), P.fg, P.panel)
  end

  -- QUEUE overlay (upcoming from current order)
  if ui.showQueue then
    local qy = math.min(bot - 1, utilY + (ui.showVol and 5 or 4))
    fill(2, qy, W - 1, math.min(H - 3, qy + 4), P.panel)
    putFit(3, qy, "QUEUE", W - 4, P.accent, P.panel)
    local shown = 0
    if #S.queue > 0 and #S.order > 0 then
      for i = 0, 3 do
        local oi = S.opos + i
        if oi > #S.order then break end
        local tr = S.queue[S.order[oi]]
        if tr then
          shown = shown + 1
          local yy = qy + shown
          if yy > H - 3 then break end
          local prefix = (i == 0) and "> " or "  "
          putFit(3, yy, prefix .. (tr.title or "?") .. "  ·  " .. (tr.artist or ""), W - 4,
            i == 0 and P.fg or P.dim, P.panel)
        end
      end
    else
      putFit(3, qy + 1, "Queue empty", W - 4, P.dim, P.panel)
    end
  end
end

local function drawHome()
  drawNowPlaying()
end

local function drawLyricsView()
  local t = S.cur
  drawHeader("LYRICS", t and (t.title .. "  ·  " .. t.artist) or "No track")
  -- Always sync-scroll to the active line (no FOLLOW badge / toggle).
  local synced = t and S.lyricLines and #S.lyricLines > 0
  if synced then
    putFit(2, 2, "SYNCED", 8, P.accent, P.bg)
  else
    putFit(2, 2, "NO LRC", 8, P.dim, P.bg)
  end

  local lines = S.lyricLines or {}
  local curIdx = S.lyricIdx or 1
  local top = contentTop()
  local bot = contentBot()
  local rows = math.max(1, bot - top + 1)
  if synced then
    ui.lyricScroll = clamp(curIdx - math.floor(rows / 2), 0, math.max(0, #lines - rows))
  end
  ui.lyricScroll = clamp(ui.lyricScroll, 0, math.max(0, #lines - rows))

  if #lines == 0 then
    put(3, top + 1, "No synced lyrics for this track.", P.dim, P.bg)
    put(3, top + 2, "Drop a matching .lrc beside the .dfpwm.", P.dim, P.bg)
  else
    for r = 0, rows - 1 do
      local idx = ui.lyricScroll + r + 1
      local line = lines[idx]
      local y = top + r
      if line then
        local active = idx == curIdx
        local bg = active and P.selBg or P.bg
        local fg = active and P.selFg or P.fg
        fill(1, y, W, y, bg)
        local text = type(line) == "table" and (line.text or "") or tostring(line)
        putFit(2, y, text, W - 2, fg, bg)
      end
    end
  end
end

local function drawAppearance()
  drawHeader("< APPEARANCE", "Palette changes apply live")
  put(2, 1, "<", P.fg, P.bg)
  addHit(1, 3, 1, function() setTab("library") end)

  put(2, 3, "ACCENT COLOUR", P.fg, P.bg)
  local x, y = 2, 5
  for i, name in ipairs(ACCENT_ORDER) do
    local on = settings.accent == name
    local col = ACCENTS[name]
    fill(x, y, x + 10, y, on and col or P.panel)
    putFit(x, y, " " .. name:upper(), 11, on and colors.black or P.fg, on and col or P.panel)
    if on then fill(x, y + 1, x + 10, y + 1, colors.white) end
    addHit(x, x + 10, y, function() setAccent(name) end)
    x = x + 13
    if x + 11 > W then
      x = 2
      y = y + 3
    end
  end

  y = y + 3
  put(2, y, "INTERFACE", P.fg, P.bg)
  y = y + 2
  put(2, y, "Text scale", P.fg, P.bg)
  put(2, y + 1, "Text scale applies to the whole interface. Use 0.1 steps.", P.dim, P.bg)
  local scaleStr = string.format("%.1f", settings.textScale or 0.5)
  put(W - 16, y, scaleStr, P.accent, P.bg)
  pill(W - 12, y, 3, "-", false, function() applyTextScale((settings.textScale or 0.5) - 0.1) end)
  pill(W - 8, y, 3, "+", false, function() applyTextScale((settings.textScale or 0.5) + 0.1) end)

  y = y + 3
  put(2, y, "Animations", P.fg, P.bg)
  pill(W - 10, y, 8, settings.animations and "ON" or "OFF", settings.animations, function()
    settings.animations = not settings.animations
    S.dirty = true
  end)

  y = y + 3
  put(2, y, "VISUALIZER (REAL PCM ANALYSIS)", P.fg, P.bg)
  put(2, y + 1, "Palette changes are applied live to this monitor.", P.dim, P.bg)
  y = y + 3
  x = 2
  for _, mode in ipairs(VIZ_MODES) do
    local on = settings.vizMode == mode
    pill(x, y, 8, mode:upper(), on, function() setVizMode(mode) end)
    x = x + 10
  end
end

local function drawSearch()
  drawHeader("SEARCH", "Type to filter current album (keyboard)")
  put(2, 3, "Query: " .. (ui.search or "") .. "_", P.fg, P.bg)
  ui.tab = "search"
  drawTrackList()
end

local function draw()
  if not P or not P.bg then rebuildPalette() end
  if not P or not P.bg then return end
  D.setVisible(false)
  hits = {}
  D.setBackgroundColor(P.bg)
  D.clear()
  if settings.animations then
    ui.animPhase = (ui.animPhase + 1) % 64
  end

  if W < 30 or H < 12 then
    put(1, 1, "Screen too small", P.fg, P.bg)
    put(1, 2, "Need larger monitor / lower --scale", P.dim, P.bg)
    D.setVisible(true)
    return
  end

  if ui.tab == "appearance" then
    drawAppearance()
  elseif ui.tab == "lyrics" then
    drawLyricsView()
    drawMiniTransport()
  elseif ui.tab == "home" or ui.tab == "music" then
    drawNowPlaying()
  elseif ui.tab == "search" then
    -- search uses track list body
    local keep = ui.search
    drawHeader("SEARCH", "Filter: " .. (keep ~= "" and keep or "(all)"))
    drawTrackList()
    drawMiniTransport()
  else
    drawTrackList()
    drawMiniTransport()
  end

  if ui.tab ~= "appearance" then
    drawBottomNav()
  end

  -- status line overwrites bottom-most nav corner briefly
  if S.status ~= "" and ui.tab ~= "appearance" then
    putFit(1, H, " " .. S.status, W, P.accent, P.navBg)
  end

  D.setVisible(true)
end

local function handleClick(x, y)
  for i = #hits, 1, -1 do
    local h = hits[i]
    local y1, y2 = h.y1 or h.y, h.y2 or h.y
    if y >= y1 and y <= y2 and x >= h.x1 and x <= h.x2 then
      h.fn(x)
      return
    end
  end
end

local function handleDrag(x, y)
  for _, h in ipairs(hits) do
    local y1, y2 = h.y1 or h.y, h.y2 or h.y
    if h.drag and y >= y1 and y <= y2 then
      h.fn(clamp(x, h.x1, h.x2))
      return
    end
  end
end

local function handleScroll(dir, x)
  if ui.tab == "lyrics" then
    ui.lyricScroll = ui.lyricScroll + dir * 2
  else
    ui.listScroll = ui.listScroll + dir * 2
  end
end

local function ensureVisibleSel()
  local rows = visibleRows()
  if selSong - 1 < ui.listScroll then
    ui.listScroll = math.max(0, selSong - 1)
  elseif selSong > ui.listScroll + rows then
    ui.listScroll = selSong - rows
  end
end

local function moveSel(delta)
  if ui.browse == "artists" then
    selectArtist(clamp(selArtist + delta, 1, #artists))
  elseif ui.browse == "albums" then
    local ar = currentArtist()
    if ar then selectAlbum(clamp(selAlbum + delta, 1, #ar.albums)) end
  else
    local al = currentAlbum()
    if al and #al.tracks > 0 then
      selSong = clamp(selSong + delta, 1, #al.tracks)
    end
  end
  ensureVisibleSel()
end

local function cycleFocus(dir)
  -- cycle bottom tabs
  local i = 1
  for k, v in ipairs(NAV) do if v.id == ui.tab then i = k break end end
  local n = NAV[((i - 1 + dir - 1) % #NAV) + 1]
  setTab(n.id)
end

local function rescan()
  artCache = {}
  artists, allTracks = scan()
  if selArtist > #artists then selArtist = 1 end
  selectArtist(selArtist)
  ui.listScroll = 0
  S.syncDirty = true
  refreshDiskSpace(true)
  local nArtists = 0
  for _, a in ipairs(artists) do
    if not a.virtual then nArtists = nArtists + 1 end
  end
  setStatus("Rescanned: " .. nArtists .. " artists, " .. #allTracks .. " songs")
end

local lastPath
local function ensurePlayingVisible()
  local p = S.cur and S.cur.path
  if p == lastPath then return end
  lastPath = p
  if not p then return end
  if S.src and S.src.virtual then
    if S.src.artist == "All Songs" then
      selArtist, selAlbum = 1, 1
    else
      for ai, ar in ipairs(artists) do
        if not ar.virtual and ar.name == S.src.artist then
          selArtist, selAlbum = ai, 1
          break
        end
      end
    end
    for ti, t in ipairs(S.src.tracks) do
      if t.path == p then
        selSong = ti
        ensureVisibleSel()
        return
      end
    end
    return
  end
  for ai, ar in ipairs(artists) do
    if not ar.virtual then
      for ali, al in ipairs(ar.albums) do
        if not al.virtual then
          for ti, t in ipairs(al.tracks) do
            if t.path == p then
              selArtist, selAlbum, selSong = ai, ali, ti
              ensureVisibleSel()
              return
            end
          end
        end
      end
    end
  end
end

local function handleKey(k)
  if k == keys.q then return true
  elseif k == keys.tab then cycleFocus(1)
  elseif k == keys.up then moveSel(-1)
  elseif k == keys.down then moveSel(1)
  elseif k == keys.enter then
    local al = currentAlbum()
    if al and al.tracks[selSong] then playAlbum(al, selSong)
    elseif al then playAlbum(al, nil) end
  elseif k == keys.space then
    if not togglePause() and not S.cur then
      local al = currentAlbum()
      if al then playAlbum(al, selSong) else playAllFrom(1) end
    end
  elseif k == keys.n then
    if S.cur then advance(1, false) end
  elseif k == keys.p or k == keys.b then prevTrack()
  elseif k == keys.left then seekTo(position() - CONFIG.seekStep)
  elseif k == keys.right then seekTo(position() + CONFIG.seekStep)
  elseif k == keys.equals or k == keys.numPadAdd then setVolume(S.volume + 0.05)
  elseif k == keys.minus or k == keys.numPadSubtract then setVolume(S.volume - 0.05)
  elseif k == keys.s then toggleShuffle()
  elseif k == keys.r then cycleRepeat()
  elseif k == keys.d then toggleDj()
  elseif k == keys.l then
    toggleLyrics()
    setTab("lyrics")
  elseif k == keys.m then toggleMute()
  elseif k == keys.x then stopPlayback()
  elseif k == keys.a then setTab("appearance")
  elseif k == keys.h then setTab("home")
  elseif k == keys.pageUp then
    ui.listScroll = ui.listScroll - (visibleRows() - 1)
  elseif k == keys.pageDown then
    ui.listScroll = ui.listScroll + (visibleRows() - 1)
  elseif k == keys.f5 then rescan()
  elseif k == keys.backspace and ui.tab == "search" then
    ui.search = (ui.search or ""):sub(1, -2)
  end
  return false
end

local function housekeeping()
  local t = now()
  if S.status ~= "" and t > S.statusUntil then S.status = "" end
  if S.volDirty and t - S.volDirty > 0.5 then
    S.volDirty = nil
    if CONFIG.instantVolume and S.cur and not S.paused then
      S.pos0 = position()
      restart()
    end
  end
  if S.spkDirty and t - S.spkDirty > 0.5 then
    S.spkDirty = nil
    if S.cur and not S.paused then
      S.pos0 = position()
      restart()
    end
  end
  if S.dirty then
    S.dirty = false
    saveSettings()
  end
  tickDjCut()
  refreshLyricLine()
  refreshDiskSpace(false)
  ensurePlayingVisible()
end

------------------------------------------------------------------ open wireless modems (shared by pocket + viz)
local function openWirelessModems()
  peripheral.find("modem", function(name, m)
    if m.isWireless and m.isWireless() then rednet.open(name) end
  end)
end

------------------------------------------------------------------ pocket rednet (protocol pocket_mp3)
-- Fixed: allTracks is the FULL flat library, not next(albums).tracks
local function pocketListener()
  openWirelessModems()

  local proto = CONFIG.pocketProto
  local lastBroadcast = 0

  local function buildSlim()
    local slim, curIdx = {}, 1
    for i, t in ipairs(allTracks) do
      slim[i] = {
        disp   = t.title,
        album  = t.album,
        artist = t.artist,
        size   = math.floor(t.dur * 6000),  -- bytes ≈ seconds * 6000
      }
      if S.cur and t.path == S.cur.path then curIdx = i end
    end
    return slim, curIdx
  end

  local function sendSync(target)
    local slim, curIdx = buildSlim()
    local pkt = {
      songs = slim,
      idx   = curIdx,
      play  = (S.cur ~= nil and not S.paused),
      shf   = S.shuffle,
      vol   = S.volume,
    }
    if target then
      rednet.send(target, pkt, proto)
    else
      rednet.broadcast(pkt, proto)
    end
    lastBroadcast = now()
    S.syncDirty = false
  end

  while true do
    local id, m = rednet.receive(proto, 0.4)
    if type(m) == "table" then
      if m.cmd == "sync" then
        sendSync(id)
      elseif m.cmd == "pick" and type(m.n) == "number" and allTracks[m.n] then
        -- Tap-to-play: queue the FULL library and start at the chosen index
        playAllFrom(m.n)
        sendSync()
      elseif m.cmd == "toggle" then
        if not togglePause() and not S.cur and allTracks[1] then
          playAllFrom(1)
        end
        sendSync()
      elseif m.cmd == "next" then
        if S.cur then advance(1, false) elseif allTracks[1] then playAllFrom(1) end
        sendSync()
      elseif m.cmd == "prev" then
        if S.cur then prevTrack() end
        sendSync()
      elseif m.cmd == "shf" then
        toggleShuffle()
        sendSync()
      elseif m.cmd == "vol" and type(m.d) == "number" then
        setVolume(S.volume + m.d)
        saveSettings()
        sendSync()
      end
    elseif S.syncDirty and (now() - lastBroadcast) > 0.3 then
      sendSync()
    end
  end
end

------------------------------------------------------------------ side visualizer rednet (protocol jukebox_viz)
-- Lean play-state + energy / band / wave hints + optional lyric line.
-- Parallel to audio — never blocks speakers.
local function vizBroadcaster()
  openWirelessModems()
  local proto = CONFIG.vizProto
  local lastSend = 0
  local lastMetaAt = 0
  local lastMetaKey = ""
  local lastLyricKey = ""

  -- Integers 0..100 (or -100..100 for wave) serialize smaller than floats.
  local function copyLevels(src, signed)
    local out = {}
    for i = 1, #src do
      local v = math.floor(src[i] * 100 + (src[i] >= 0 and 0.5 or -0.5))
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
    refreshLyricLine()
    local playing = S.cur ~= nil and not S.paused and S.running
    if not playing then decayVizLevels() end
    local t = S.cur
    local metaKey = t and (t.path or (t.artist or "") .. "\0" .. (t.album or "") .. "\0" .. (t.title or "")) or ""
    local needMeta = forceMeta or metaKey ~= lastMetaKey or (now() - lastMetaAt) >= CONFIG.vizMetaEvery
    local lyricKey = (S.lyrics and "1" or "0") .. "\0" .. (S.lyricText or "")
    local needLyric = forceMeta or lyricKey ~= lastLyricKey
    local pkt = {
      v = 1,
      play = S.cur ~= nil and not S.paused,
      paused = S.cur ~= nil and S.paused or false,
      stop = S.cur == nil,
      e = math.floor(vizLevels.energy * 100 + 0.5),
      peak = math.floor(vizLevels.peak * 100 + 0.5),
      b = copyLevels(vizLevels.bands, false),
      w = copyLevels(vizLevels.wave, true),
      lyricsOn = S.lyrics and true or false,
      vizMode = settings.vizMode or "bars",
      accent = settings.accent or "violet",
      anim = settings.animations and true or false,
      ts = now(),
    }
    if needMeta then
      pkt.title = t and t.title or ""
      pkt.artist = t and t.artist or ""
      pkt.album = t and t.album or ""
      pkt.pos = t and position() or 0
      pkt.dur = t and t.dur or 0
      lastMetaAt = now()
      lastMetaKey = metaKey
    end
    if needLyric then
      pkt.lyric = S.lyrics and (S.lyricText or "") or ""
      lastLyricKey = lyricKey
    end
    rednet.broadcast(pkt, proto)
    lastSend = now()
    S.vizDirty = false
  end

  -- Initial idle announce so side PCs can find the jukebox quickly
  sendViz(true)

  while true do
    local playing = S.cur ~= nil and not S.paused
    local interval = playing and CONFIG.vizInterval or CONFIG.vizIdleInterval
    local wait = math.max(0.02, interval - (now() - lastSend))
    local tid = os.startTimer(wait)
    -- Wake early on fresh PCM analysis / lyric change without spinning audio
    repeat
      local ev, p1 = os.pullEvent()
      if ev == "timer" and p1 == tid then break end
      if S.vizDirty and (now() - lastSend) >= math.min(interval, 0.04) then break end
    until false
    sendViz(false)
  end
end

------------------------------------------------------------------ UI loop
local function uiLoop()
  draw()
  local tick = os.startTimer(0.5)
  while true do
    local ev, p1, p2, p3 = os.pullEvent()
    local redraw = true
    if ev == "timer" then
      if p1 == tick then
        tick = os.startTimer(0.5)
        housekeeping()
      else
        redraw = false
      end
    elseif ev == "mouse_click" and not mon then
      if p1 == 1 then handleClick(p2, p3) end
    elseif ev == "monitor_touch" and mon then
      if p1 == monName then handleClick(p2, p3) end
    elseif ev == "mouse_drag" and not mon then
      handleDrag(p2, p3)
    elseif ev == "mouse_scroll" and not mon then
      handleScroll(p1, p2)
    elseif ev == "char" and ui.tab == "search" then
      if type(p1) == "string" and #p1 == 1 then
        ui.search = (ui.search or "") .. p1
      end
    elseif ev == "key" then
      if handleKey(p1) then return end
    elseif ev == "term_resize" or ev == "monitor_resize" then
      W, H = T.getSize()
      D.reposition(1, 1, W, H)
    elseif ev == "peripheral" then
      if refreshSpeakers() then S.spkDirty = now() end
      refreshDiskSpace(true)
    elseif ev == "peripheral_detach" then
      refreshSpeakers()
      refreshDiskSpace(true)
    elseif ev ~= "jukebox_wake" then
      redraw = false
    end
    if redraw then draw() end
  end
end

------------------------------------------------------------------ run
math.randomseed(os.epoch("utc"))

local ok, err = pcall(parallel.waitForAny, uiLoop, playerLoop, pocketListener, vizBroadcaster)

stopSpeakers()
saveSettings()
T.setBackgroundColor(colors.black)
T.setTextColor(colors.white)
T.clear()
T.setCursorPos(1, 1)
if not ok and err ~= "Terminated" then
  printError(err)
else
  print("Jukebox stopped.")
end
