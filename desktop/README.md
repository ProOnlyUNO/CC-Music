# CC Music Tools

One Windows desktop app for preparing music for a **CC:Tweaked** jukebox — plus a clear **`setup/`** folder that maps which scripts go on which computer.

**Developer: ProOnlyUNO** · v1.0.0

1. **Download** — YouTube playlist/album **or Genius album** → MP3 (yt-dlp) → auto LRCLIB lyrics → optional **Artist/Album** folders
2. **Convert** — MP3 / WAV / FLAC / … → `Artist/Album/Song.dfpwm` (+ sibling `.lrc` + `.nfp` art from cover PNG/JPG / embedded art). Same tab: **Album art → cover.nfp** for standalone PNG/JPG or folder batch (96×96 CC palette).
3. **Fetch lyrics** — public [LRCLIB](https://lrclib.net) API → `.lrc` beside tracks + a pack folder
4. **How to use** / **Commands** — friendly in-app guides

On launch the app quietly checks GitHub Release **v1.0.0** for a newer **build stamp** (not just the version tag). If `build-info.json` on the release is newer than the embedded stamp, you get **Update** / **Later**.

## Quick start (Setup.exe)

1. Double-click **`Setup.exe`**.
2. Choose where to put CC Music Tools (default: `Documents\CC-Music-Tools`).
3. Leave **Install / ensure ffmpeg + yt-dlp** checked (Convert + YouTube Download need them).
4. Optional Start Menu / Desktop shortcuts → **Install**.
5. Setup reports whether ffmpeg / yt-dlp succeeded. If either failed:
   ```text
   winget install ffmpeg
   python -m pip install -U yt-dlp
   ```
6. Open the app. Your install folder also gets **`setup/`** (in-game scripts).

Dev shortcut: double-click **`dist\CC_Music_Tools.exe`**.

## Download tab (YouTube / Genius → MP3)

1. Open **Download**.
2. **YouTube:** search songs/playlists, or paste a playlist/song URL.
   **Genius:** switch to **Genius album**, search by name, or paste `https://genius.com/albums/...`.
3. Click **Fetch titles** — checklist of tracks appears (`[→ YT]` means YouTube match on download).
4. Select the songs you want (Select all / Select none).
5. Pick an MP3 download folder → **Download selected MP3s**.
6. Genius tracks are matched on YouTube (`Artist Title`, prefer Topic / official) then downloaded.
7. Lyrics are fetched automatically (artist/title kept in tags) before clean rename.
8. When prompted, pick a library root → files land as `Artist/Album/Song.mp3` (+ `.lrc`).
9. Click **Send folder → Convert** (offered after a successful download).
10. On **Convert**, turn those MP3s into `Artist/Album/Song.dfpwm`.

Uses **yt-dlp** in-app (more reliable than browser scrapers). Keep yt-dlp updated.

### Alternate (browser only)

If you prefer not to install yt-dlp, use this playlist downloader in a browser, save MP3s to a folder, then use **Convert** in this app:

https://media.ytmp3.gg/tools/youtube-playlist-downloader/mkehhz

## In-game setup map (`setup/`)

Start with **`setup/START_HERE.txt`**.

| Folder | Computer | What to copy |
|--------|----------|--------------|
| `setup/main-computer/` | Main music PC | `jukebox.lua`, `Importer.lua`, optional `sort-music.lua`, `delete-music.lua`, `lyrics-status.lua` |
| `setup/side-visualizer/` | Each side PC | `visualizer.lua` — left: `visualizer --side=left` · right: `--side=right` |
| `setup/pocket-remote/` | Pocket Advanced Computer | **`pocket.lua`** (protocol **`pocket_mp3`**) |

**Monitors:** main **9×3** Advanced Monitor @ scale **0.5**; side viz **4×4** @ **0.5**.

**Pocket remote:** Ender Modem on pocket + main → copy `pocket.lua` → run `pocket` (or `shell.run("pocket")` in startup) → SYNC → tap a song.

## Desktop flow → Minecraft

1. **Download** (optional) → auto lyrics → organize `Artist/Album`
2. **Convert** to `.dfpwm` (keeps Artist/Album + copies `.lrc` + writes `.nfp` art)
3. **Fetch lyrics** again only if you need a library re-scan
4. Copy Artist/Album trees into the game (keep `Song.nfp` / `cover.nfp` with tracks)
5. Run **Importer** and drag-drop `.dfpwm` / `.lrc` / `.nfp` onto the **computer screen**
6. Restart jukebox — pixel UI shows art thumbs; lyrics FOLLOW; APPEARANCE for accents / viz mode

## App tabs

| Tab | Purpose |
|-----|---------|
| **Download** | YouTube or Genius album → checklist → MP3 (yt-dlp) |
| **Convert** | Folder or audio files → `.dfpwm`; PNG/JPG or album folder → `cover.nfp` |
| **Fetch lyrics** | `.dfpwm` library → `.lrc` + pack |
| **How to use** | Full friendly guide (points at `setup/`) |
| **Commands** | Short cheat sheet: startup, viz sides, `pocket.lua`, sort/delete/Importer |

## Run from source

```text
cd C:\Users\Smoke\Downloads\CC-Music-Tools
python -m pip install -U yt-dlp pillow
python cc_music_desktop.py
```

Needs **Python 3.10+** (tkinter + Pillow). Conversion / MP3 extract still need **ffmpeg**. Download tab needs **yt-dlp**.

## Build

```text
cd C:\Users\Smoke\Downloads\CC-Music-Tools
build_exe.bat
build_setup.bat
```

- `build_exe.bat` stamps `BUILD_STAMP` + writes `build-info.json`, then → `dist\CC_Music_Tools.exe`
- `build_setup.bat` → **`Setup.exe`** (embeds exe + assets + README + **setup/**)
- Refresh GitHub **v1.0.0** with both **`Setup.exe`** and **`build-info.json`** (same stamp) so in-app update checks work.

## Files in this folder

| File | Role |
|------|------|
| `Setup.exe` | Freestanding installer |
| `setup/` | In-game script map (main / side / pocket) |
| `cc_music_desktop.py` | GUI |
| `download_core.py` | YouTube playlist → MP3 (yt-dlp) |
| `setup_cc_music.py` | Installer source |
| `assets\background.jpg` | Matrix background |
| `dist\CC_Music_Tools.exe` | Built app |

## Dependencies

| Need | Required? |
|------|-----------|
| Download tab | **yt-dlp** + **ffmpeg** (for MP3 extract) |
| Convert tab (audio) | **ffmpeg 5.1+** with `dfpwm` |
| Convert tab (cover.nfp) | **Pillow** (bundled in the exe) |
| Fetch lyrics | No (internet only) |
| GUI | Python + tkinter + Pillow, or the exe |

Check ffmpeg: `ffmpeg -hide_banner -encoders | findstr dfpwm`  
Check yt-dlp: `python -m yt_dlp --version`

## Credit

Developer: **ProOnlyUNO**
