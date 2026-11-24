# Install — CC:Tweaked DFPWM Jukebox

Paste-ready scripts live in this folder:

- `jukebox.lua` — main computer (**paintutils pixel UI**: album list + lyrics follow + APPEARANCE; pocket listener + viz broadcaster). Album/song art via beside `.nfp`.
- `sfx/` — DJ transition stings (`SFX1.dfpwm` … `SFX4.dfpwm`); copy next to `jukebox.lua` on the main computer
- `visualizer.lua` — left/right side-monitor music visualizer (rednet listener; **not** on the main 9×3); supports **LYRICS** big-text mode
- `fetch-lyrics.md` — Windows LRCLIB fetch + Importer (new `.lrc`) / `sort-music` (bulk orphans)
- `sort-music.lua` — **one entrypoint**: music tidy (`Artist - Album` → `Artist/Album`, Singles) + root SFX → `/sfx` + recursive `.lrc` match → beside songs / `/lyrics` (multi-disk spill). Prefer for **bulk** orphans already on the computer.
- `delete-music.lua` — interactive **delete** tool: pick Artist → Album → Song, or **DELETE ALBUM**; confirm (`y`) required; removes `.dfpwm` + beside `.lrc` + optional `/lyrics` mirror; prunes empty dirs; never touches `sfx/`. Optional `--dry-run`.
- `lyrics-status.lua` — quick count of tracks with/missing beside `.lrc`
- `lyrics-import.lua` / `sort-lyrics.lua` — thin wrappers → `sort-music --lyrics-only`
- `pocket.lua` — Pocket Advanced Computer remote
- `Importer.lua` — drag-drop `.dfpwm` + `.lrc` + `.nfp` art (writes `music/<Artist - Album>/`; places matched lyrics/art beside songs)

Protocols:

| Protocol | Who | Purpose |
|----------|-----|---------|
| **`pocket_mp3`** | Main ↔ Pocket | Library sync + remote transport |
| **`jukebox_viz`** | Main → side PCs | Play state + energy / band / wave levels; optional `lyricsOn` + `lyric`; `vizMode` (bars/wave/vu/off) + accent |

Pocket and visualizers use **different** protocols on the same wireless network. Update main `jukebox.lua` when adding visualizers — older mains do not broadcast `jukebox_viz`.

## Monitor scale

| Role | Blocks | Default scale | ≈ characters |
|------|--------|---------------|--------------|
| Main jukebox UI | **9×3** | **0.5** | ~270×60 |
| Left / right visualizer | **4×4** each | **0.5** | ~120×80 |

Main: denser look `jukebox --scale=1` (~135×30); terminal only `jukebox --term`.

Side visualizers: chunkier glyphs `visualizer --scale=1` (~60×40 on 4×4). Bar count, waveform density, and particles **auto-adapt** to whatever `getSize()` reports.

## Music layout

Songs are `.dfpwm` files. Preferred tree (works on `disk`, `disk2`, … and `/music`):

```text
disk/Artist Name/Album Name/01 Song Title.dfpwm
disk/Artist Name/Album Name/01 Song Title.lrc    (optional lyrics)
disk/Artist Name/Album Name/01 Song Title.nfp    (optional song art)
disk/Artist Name/Album Name/cover.nfp            (optional album art)
disk/Artist Name/Album Name/02 Another Song.dfpwm
disk2/Other Artist/Their Album/Track.dfpwm
```

Desktop **Convert** / **Download** write `.nfp` from PNG/JPG (or embedded cover). Importer + `sort-music` keep `.nfp` beside matching `.dfpwm` under Artist/Album.

Also accepted (common dump layout) — folder name is **`Artist - Album`** (split on the first ` - `):

```text
disk/music/Daft Punk - Random Access Memories/01 Give Life Back to Music.dfpwm
music/Daft Punk - Random Access Memories/02 Get Lucky.dfpwm
```

A folder literally named **`music`** under a scanned root is a **container**, not an artist. So `disk/music/…` does not show up as artist “music” in the Artist panel.

Also scanned automatically:

| Path | Meaning |
|------|---------|
| `disk/…`, `diskN/…` | Artist/Album trees on floppies |
| `disk/music/…`, `diskN/music/…` | Same tree under a `music` container |
| `music/…` | On the computer itself |
| `…/<Artist> - <Album>/*.dfpwm` | Artist + album parsed from the folder name |
| `…/Album/*.dfpwm` (no artist, no ` - `) | Treated as artist **Various** |
| loose `*.dfpwm` | Artist/Album **Singles** |

Duplicate paths across roots are ignored once.

### Importer / uploader (new drops)

Replace any old `uploader.lua` (or earlier Importer) with `docs/Importer.lua`. Save it on the computer as **`Importer.lua`** or **`uploader.lua`** — either name works; run `Importer` or `uploader` to match the filename.

Layout: disk label = artist, new audio goes to `music/<Artist - Album>/song.dfpwm` with multi-disk spill. Blank album → folder named after the artist (singles). Drag-drop UX, disk labeling, reserve space, and skipDuplicates are unchanged.

Also accepts **`.lrc`** drops: matches to a library `.dfpwm` (basename / normalized / `Artist - Title` / tags; prefers the current artist/album session and same-drop pairs), writes beside that song, optional `/lyrics` mirror with spill, prints match/miss. Prefer Importer for new lyric drops; keep `sort-music --apply --lyrics-only` for bulk orphans already on the computer. Details: `fetch-lyrics.md`.

### Optional: one-shot sort (music + SFX + lyrics)

`sort-music.lua` is the single in-game sorter (bulk tidy / orphan lyrics / dupe cleanup):

- Music: `Artist - Album` → `Artist/Album`; loose tracks → `Singles/`; **`Singles - Title`** → `Various/Singles` + song Title (not artist=Singles)
- Collisions: folders named `Name 2` / `Name_2` / `Name (2)` merge into `Name` **only when `Name` already exists** (never renames a sole numbered album)
- SFX: create `/sfx`, move loose root `SFX*.dfpwm` into it
- **Root cleanup:** loose computer-root `.dfpwm` + `.lrc` → match/move onto disks; leftovers cleared so `ls` isn’t a dump. Never deletes `*.lua`, `startup`, or library dirs (`music`/`sfx`/`lyrics`/`disk*`)
- Lyrics: match **flat `.lrc` drops** (computer/disk root — CC can’t drop folders) or an optional pack tree; place beside `.dfpwm`; mirror `/lyrics` with multi-disk spill; **dedupe** extra `.lrc`
- Audio **dupe cleanup is OFF by default**. `--apply` alone never deletes `.dfpwm`. Pass `--dedupe` to remove **confirmed** extras only (same-size copy kept; prefer `.dfpwm`+`.lrc`; never delete a sole library copy or a protected Artist/Album track without a same-album twin). Dry-run with `--dedupe` reports would-deletes. `--safe` / `--no-dedupe` keep deletes off.

```text
sort-music                  -- preview (no writes; reports moves + merges)
sort-music --apply          -- nest + Singles + root + SFX + lyrics (albums survive)
sort-music --apply --dedupe -- also delete confirmed audio extras
sort-music --dedupe         -- dry-run that shows would-delete audio extras
```

Drop `.lrc` files onto the computer or a disk root, then `--apply`. Details: `fetch-lyrics.md`.

After apply: **F5** / restart jukebox (song list shows `(L)` when lyrics exist). DJ picks up `/sfx` on the next flip.

## Main computer

1. Place speakers next to the computer (or on a wired modem network).
2. Attach the **9×3 monitor** (and a **wireless modem** for the pocket remote **and** side visualizers).
3. Copy `jukebox.lua` onto the computer (e.g. paste into an edit buffer, or `wget` / disk copy). **Replace** `jukebox.lua` (and keep `jukebox-three-panel.lua` identical if you use that name) whenever you pick up viz / UI updates — `F5` only rescans files, it does not reload the program. Side visualizers need a main that broadcasts protocol **`jukebox_viz`**.
4. Copy the **`sfx/`** folder from this docs pack onto the computer **next to** `jukebox.lua` (same directory). On a typical install that is `/sfx/` beside `/jukebox.lua`. Keep the filenames as `SFX1.dfpwm` … `SFX4.dfpwm` (or add more matching `SFX*.dfpwm` / `SFX *.dfpwm` later — the jukebox rescans the folder on every DJ flip).
5. Insert music floppies (`disk`, `disk2`, …).
6. Run:

```text
jukebox
```

Optional startup:

```text
edit startup
```

```lua
shell.run("jukebox")
```

Controls on the monitor: tap Artist → Album → Song. Bottom strip has play/pause, skip, shuffle, repeat, seek, volume. `F5` rescans disks. `Q` quits.

**Disk space:** the title bar shows total **used · free** across attached `disk` / `diskN` mounts (e.g. `1.2 MB used · 384 KB free (3 disks)`), refreshed every **4 seconds** without pausing playback.

**Color UI:** now-playing strip uses a **cycling rainbow** on artist/album/title text; Artist / Album / Song rows are **tinted by first letter** (A–Z across the CC palette). Selected / playing rows stay high-contrast. Replace `jukebox.lua` and restart to pick UI updates up — `F5` does not reload the program.

**All Songs:** the ARTIST panel starts with a synthetic **All Songs** entry (whole library). Select a **real artist** and the ALBUM panel starts with that artist’s own **All Songs** (every track by them), then their normal albums. Library All Songs still lists `Artist · Title`; per-artist All Songs lists `Album · Title`. Playing either queues that pool so next/prev stay inside it. Pocket `pocket_mp3` sync still uses the same flat `allTracks` list (virtual rows are not double-counted).

**DJ mode:** tap **[DJ]** (or **D**) to toggle. While on, **mid-song auto-cuts** fire after a random wait (`djCutMin`…`djCutMax`, default **15–45s**, capped by remaining track so short leftovers aren’t thrashed), and **next** (N / `>>` / end-of-track) also flips — both pull a **random other song from the whole library** (`allTracks`), not just the current album/artist queue. DJ off → normal queue next/prev, no mid-song cuts. Every DJ flip (mid-song + next/end) keeps the SFX pack: fade out → **random** `sfx/SFX*.dfpwm` → fade in (empty `sfx/` → hat `playNote`). Repeat-one still re-plays the current track on auto-end before DJ runs. Replace `jukebox.lua` and **restart** to pick this up.

No separate `install_fix.lua` is needed — disk roots and the pocket listener are built into `jukebox.lua`.

## Left / right visualizers (4×4 monitors)

Main **9×3** stays jukebox-only. Each side is its **own computer** + **4×4 Advanced Monitor** + **wireless modem** on the **same** rednet network as the main.

1. Place a computer beside each side panel; attach the **4×4** monitor and a wireless modem.
2. Copy `visualizer.lua` onto that computer (paste / disk / `wget`).
3. Optional but useful: label the computer `viz-left` / `viz-right` (or any name containing `left` / `right`) so mirror side auto-detects. Or pass `--side=`:

```text
visualizer --side=left
visualizer --side=right
visualizer --side=left --fps=30
visualizer --side=left --title-fx=breathe
visualizer --title-fx=pulse|bass|warmcool|breathe
```

4. Install as startup on each side PC:

```text
edit startup
```

Left:

```lua
shell.run("visualizer", "--side=left")
```

Right:

```lua
shell.run("visualizer", "--side=right")
```

5. On the **main** computer, make sure the updated `jukebox.lua` is running (it broadcasts `jukebox_viz` ~20 Hz while playing: lean energy + 16 RMS bands + 16 wave samples; title/artist/album only when the track changes). Pocket traffic stays on `pocket_mp3` and is unaffected.

**Effects:** mixed spectrum bars (resampled to ~28 bars on 4×4@0.5), mirrored waveform through the middle, center bloom + border pulse on hits, rising particles. Idle / paused → calm breathing. Draw loop targets ~28 FPS (`--fps=24` … `30` optional). `Q` quits.

**Now-playing title:** the top line marquees horizontally when artist/title doesn’t fit (pause at start/end, ~0.12s tick, resets on track change). Same marquee on the lyrics-mode header. While playing, title color uses non-rainbow FX — default **`breathe`** (gentle palette shift + soft breathe). Pick with `--title-fx=pulse|bass|warmcool|breathe`, or press **T** on the side PC to cycle.

**Lyrics mode:** song list shows compact **`(L)`** when a track has a resolvable `.lrc`. Tap **[LYRICS]** or press **L** for big current-line text on the side 4×4s (from `.lrc` beside the song or under `/lyrics` / `diskN/lyrics`). While lyrics is on but the current line is empty, side monitors keep the fancy spectrum/particles (no “(waiting…)”); when a line arrives, big lyrics show as before. Details: `fetch-lyrics.md`.

**Speed note:** if the viz still feels laggy after replacing both sides, confirm main + both visualizers were restarted (not just `F5`). Broadcast and draw are independent of the audio coroutine.

**Update step:** put updated `visualizer.lua` on both side machines as startup, then restart both side PCs (main only if you’re also picking up a jukebox change).

## Delete songs / albums (`delete-music`)

Copy Project `docs/delete-music.lua` onto the main music computer (same machine that sees `disk` / `diskN` / `music`). Quit the jukebox first so files aren’t open for play.

```text
delete-music              -- interactive; type y to confirm each delete
delete-music --dry-run    -- preview only (prints paths, deletes nothing)
```

Flow: pick **artist** → **album** → a **song**, or the top **DELETE ALBUM** action. Confirm with `y` / `yes` (required for real deletes). Song delete removes the `.dfpwm`, matching `.lrc` beside it, and any `/lyrics` (or `diskN/lyrics`) mirror for that track. Album delete does that for every track in the album, then removes empty album/artist folders. Never touches `sfx/` or unrelated mounts. Printed lines list every path deleted (or that would be deleted in dry-run). Afterward: restart jukebox or **F5** to refresh the library.

## Run steps (scrolling title + lyric import)

1. **Visualizer marquee** — copy Project `docs/visualizer.lua` onto **both** side PCs (replace). Restart each side PC (startup preferred). Play a long title; top line should scroll with a short pause at start/end. Toggle LYRICS — header still scrolls if it doesn’t fit. Spectrum/waveform unchanged when lyrics is off.
2. **Importer `.lrc`** — copy Project `docs/Importer.lua` onto the main computer as `Importer.lua` (or `uploader.lua`). Run it, pick artist/album, drop `.dfpwm` and/or `.lrc` on the computer screen. Matched lyrics land beside the song; misses print clearly. Same-drop song+lyric pairs work.
3. **Bulk orphans only** — if many `.lrc` are already on the computer/disks: `sort-music --apply --lyrics-only` (lyrics only; no audio deletes). For full tidy: `sort-music --apply` (albums safe). Add `--dedupe` only if you want confirmed audio extras removed. Preview first with bare `sort-music` (or `sort-music --dedupe` to preview deletes).
4. Restart jukebox after placing lyrics if you want `(L)` markers without waiting for F5 rescan quirks.

## Pocket Advanced Computer

1. Attach a **wireless modem**.
2. Copy `pocket.lua` onto the pocket.
3. Either run `pocket`, or install as startup:

```text
edit startup
```

```lua
shell.run("pocket")
```

4. Tap **SYNC** to pull the full library from the main jukebox (same rednet system / range).
5. **Tap any song in the TRACKLIST** to play it. `|` `<` / play-pause / `>` `|`, **SHF**, **VOL±** still work.

## Pocket ↔ main sync (what was fixed)

The old install patch built `allTracks` with `select(2, next(albums)).tracks`, so the remote only ever saw **one album**. The new main program flattens **every** Artist/Album track into `allTracks` for sync and for `pick`.

| Pocket → main | Effect |
|---------------|--------|
| `{cmd="sync"}` | Reply with full `songs[]`, `idx`, `play`, `shf`, `vol` |
| `{cmd="pick", n=i}` | Play library index `i` (tap-to-play) |
| `{cmd="toggle"|"next"|"prev"|"shf"}` | Transport |
| `{cmd="vol", d=±0.2}` | Volume step |

Song entries: `{ disp, album, artist?, size }` (`size` ≈ duration seconds × 6000). Extra fields are ignored by older remotes.
