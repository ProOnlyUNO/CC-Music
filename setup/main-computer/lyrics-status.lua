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
