--[[
  lyrics-status.lua — quick count of tracks with/without .lrc beside them

  Usage:
      lyrics-status
]]

local function isAudio(name)
  return type(name) == "string" and name:lower():match("%.dfpwm$") ~= nil
end

local function listDir(path)
  local ok, entries = pcall(fs.list, path)
  if ok and type(entries) == "table" then return entries end
  return {}
end

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
  return mounts
end

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
  for _, m in ipairs(listFloppyMounts()) do add(m) end
  return out
end

local withLrc, without, total = 0, 0, 0
local missingSamples = {}

local function checkTrack(path, file)
  if not isAudio(file) then return end
  total = total + 1
  local base = file:gsub("%.[Dd][Ff][Pp][Ww][Mm]$", "")
  local beside = fs.combine(fs.getDir(path), base .. ".lrc")
  if fs.exists(beside) and not fs.isDir(beside) then
    withLrc = withLrc + 1
  else
    without = without + 1
    if #missingSamples < 25 then
      missingSamples[#missingSamples + 1] = path
    end
  end
end

local function walk(dir)
  if not (fs.exists(dir) and fs.isDir(dir)) then return end
  for _, name in ipairs(listDir(dir)) do
    local fp = fs.combine(dir, name)
    if fs.isDir(fp) then
      local low = name:lower()
      if low ~= "lyrics" and low ~= "lyrics-pack" and low ~= "sfx" and low ~= "rom" then
        walk(fp)
      end
    else
      checkTrack(fp, name)
    end
  end
end

print("lyrics-status — .lrc beside each .dfpwm")
for _, root in ipairs(uniqueLibraryRoots()) do
  print("  scan " .. root)
  walk(root)
end

print(string.format("  tracks=%d  with .lrc=%d  missing=%d", total, withLrc, without))
if #missingSamples > 0 then
  print("  missing samples:")
  for _, p in ipairs(missingSamples) do print("    - " .. p) end
  if without > #missingSamples then
    print(string.format("    … %d more", without - #missingSamples))
  end
end
if without > 0 then
  print("Next: drop flat .lrc files, then sort-music --apply --lyrics-only")
end
