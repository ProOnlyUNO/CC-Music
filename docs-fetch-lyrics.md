# Fetch lyrics (LRCLIB → CC pack) + in-game sort

Windows tool walks DFPWM music roots, queries the **public LRCLIB API** only (`https://lrclib.net`), writes synced `.lrc` next to each song, and builds a CC-ready `lyrics/` pack.

## Library found

| Item | Path |
|------|------|
| Music root | `C:\Users\Smoke\Desktop\CC\Music CC` |
| Layout | `Artist\Album\*.dfpwm` |
| Fetcher | `C:\Users\Smoke\Downloads\cc-lyrics\fetch_lyrics.py` |
| Roots list | `C:\Users\Smoke\Downloads\cc-lyrics\roots.txt` |
| Pack | `C:\Users\Smoke\Downloads\cc-lyrics\pack\lyrics\` |
| Report | `C:\Users\Smoke\Downloads\cc-lyrics\fetch-report.txt` |
| Misses | `C:\Users\Smoke\Downloads\cc-lyrics\pack\misses.log` |

Only DFPWM library on this machine: **Music CC** (387 tracks). Prior fetch: **328 matched**, 11 instrumental, 48 miss.

## Run fetch (Windows)

```powershell
cd C:\Users\Smoke\Downloads\cc-lyrics
python fetch_lyrics.py
```

## In-game: prefer Importer for new `.lrc` drops

CC can’t drag-drop folders — only files. After a music re-import, `.lrc` usually are **not** restored with the audio.

### New songs / new lyrics (preferred)

1. Copy Project `docs/Importer.lua` onto the main computer as `Importer.lua` (or `uploader.lua`).
2. Run `Importer`, pick artist + album.
3. Drop `.dfpwm` and/or `.lrc` onto the **computer screen** (not a monitor).
   - `.dfpwm` → `music/<Artist - Album>/` with multi-disk spill (same as before)
   - `.lrc` → matched beside the song’s `.dfpwm` (basename / normalized / `Artist - Title` / `[ti:][ar:]`; session album preferred; same-drop pairs work). Optional `/lyrics` mirror with spill. Prints clear match/miss.

No need to run `sort-music` for those new lyric drops once Importer places them.

### Bulk orphans already on the computer

Use `sort-music` only for `.lrc` already sitting on the computer/disks (flat leftovers, pack trees):

1. Copy Project `docs/sort-music.lua` (and optionally `lyrics-status.lua`) onto the main computer.
2. From Windows, select **all** `.lrc` under either:
   - `C:\Users\Smoke\Downloads\cc-lyrics\pack\lyrics\` (recursive — copy the files out flat), or
   - `C:\Users\Smoke\Desktop\CC\Music CC` (the `.lrc` sitting beside each `.dfpwm`)
3. Drop those **loose `.lrc` files** onto the **computer root** or a **disk root** (or `inbox/`).  
   Do not try to drop folders — CC ignores that.
4. Preview, then apply lyrics only (safe; no audio deletes):

```text
sort-music                         -- preview (dry-run, default — no writes; reports merges/deletes)
sort-music --apply --lyrics-only   -- place every matched .lrc beside its .dfpwm (+ root cleanup)
lyrics-status                      -- optional: count with/missing .lrc after sort
```

Full tidy (nest + SFX + lyrics + audio dupe cleanup):

```text
sort-music --apply              -- includes dupe cleanup (keeps best .dfpwm+.lrc)
sort-music --apply --safe       -- tidy without deleting audio dupes
```

### Matching (Importer and sort-music)

Importer uses the same spirit of match rules for each dropped `.lrc` (session album + same-drop preferred). `sort-music` **recursively** finds every `.lrc` under the computer and mounted disks, then matches to `.dfpwm` by:

1. Exact basename  
2. Normalized name (strip track numbers / punctuation / trailing space)  
3. LRC `[ti:]` / `[ar:]` tags when present  
4. `Artist - Title.lrc` filename form  
5. Fuzzy contain (unique / artist-tied)

It **prefers copying beside** that song’s `.dfpwm` on the song’s disk, then mirrors under `/lyrics` (spills to `diskN/lyrics` when full). Stats print: found N, matched M, missing samples with track ↔ nearest `.lrc` names.

### What `--apply` does

| Step | Action |
|------|--------|
| SFX | Creates `/sfx`, moves loose root `SFX*.dfpwm` into it |
| Music | `Artist - Album` → `Artist/Album`; `Singles - Title` → Singles album + Title; `Name 2` collisions merge into `Name`; bare tracks → `Singles/`. Audio **dupe cleanup ON** (keep best `.dfpwm`+`.lrc`, prefer Artist/Album); `--safe` / `--no-dedupe` skips deletes |
| Root | Loose computer-root `.dfpwm` + `.lrc` → disks; leftovers cleared. Keeps `*.lua` / `startup` / library dirs |
| Lyrics | Recursive `.lrc` find + match; place beside `.dfpwm`; mirror `/lyrics`; dedupe extra `.lrc`; clear consumed flat drops |

Zip files: skipped unless an `unzip` program already exists on the computer (CC has no built-in unzip).

After apply: **F5** / restart jukebox. Songs with lyrics show **`(L)`** in the song list. Play → **[LYRICS]** / **L**.

### Legacy wrappers

`lyrics-import` / `sort-lyrics` → `sort-music --apply --lyrics-only`. Prefer `sort-music`.

## Why only one song showed `(L)` after restore

Re-importing music restores `.dfpwm` only. Without re-dropping the pack’s `.lrc` files, almost nothing is beside the tracks for the jukebox to resolve. An older sorter also only scanned **root-level** orphans (not nested leftovers) and matched more strictly — so a single leftover exact-name `.lrc` could be the only hit. Re-drop **all** flat `.lrc`, then `sort-music --apply --lyrics-only`.

## Jukebox

- Song list / All Songs: compact `Song Name (L)` when a resolvable `.lrc` exists (same paths as playback).
- Loads `.lrc` from: beside `.dfpwm`, `/lyrics/Artist/Album/`, `diskN/lyrics/…`.

Replace main `jukebox.lua` (+ twin) and both side `visualizer.lua`. Restart main + side PCs (not just F5).
