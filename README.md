<p align="center">
  <img src=".github/logo.png" alt="CC TOOLS" width="160" />
</p>

# CC Music

**CC:Tweaked** jukebox + side visualizers + pocket remote, with a Windows desktop helper for YouTube → MP3 download, DFPWM convert, and lyrics.

**Developer: ProOnlyUNO** · v1.0.0

## What’s included

| Piece | What it does |
|-------|----------------|
| **3-panel jukebox** | Artist → Album → Song UI on a **9×3** Advanced Monitor; shuffle, seek, volume, All Songs, **DJ** mode + SFX transitions |
| **Side visualizers** | Spectrum / waveform / particles on **4×4** monitors; **LYRICS** big-text mode |
| **Pocket remote** | Wireless library sync + tap-to-play (`pocket_mp3`) |
| **Importer / sort / delete** | Drag-drop `.dfpwm` + `.lrc`, tidy library, safe deletes |
| **CC Music Tools (Windows)** | Download YouTube playlists or Genius albums → MP3, convert → `.dfpwm`, fetch lyrics (LRCLIB), install `setup/` map |

## How to use

### 1. Windows desktop (recommended)

1. Download **`Setup.exe`** from the [latest release](https://github.com/ProOnlyUNO/CC-Music/releases/latest).
2. Run **Setup.exe** → choose install folder (default `Documents\CC-Music-Tools`) → leave **Install / ensure ffmpeg + yt-dlp** checked → **Install**.
3. Setup auto-installs ffmpeg + yt-dlp when winget/pip/choco are available and reports success/fail. Manual fallback:
   ```text
   winget install ffmpeg
   python -m pip install -U yt-dlp
   ```
4. Open the app:
   - **Download** — YouTube URL/search, or Genius album URL/search → Fetch titles → check tracks → Download (Genius auto-matches YouTube) → Send folder → Convert
   - **Convert** → **Fetch lyrics** (optional)
5. Your install folder also gets the in-game **`setup/`** script map.

Or run from source:

```text
cd desktop
python -m pip install -U yt-dlp pillow
python cc_music_desktop.py
```

#### Alternate YouTube → MP3 (browser)

If you prefer not to install yt-dlp, use this playlist downloader in a browser, save MP3s to a folder, then use **Convert** in CC Music Tools:

https://media.ytmp3.gg/tools/youtube-playlist-downloader/mkehhz

### 2. In-game computers (`setup/`)

Start with [`setup/START_HERE.txt`](setup/START_HERE.txt).

| Folder | Computer | Copy these |
|--------|----------|------------|
| [`setup/main-computer/`](setup/main-computer/) | Main music PC | `jukebox.lua`, `Importer.lua`, optional `sort-music.lua`, `delete-music.lua`, `lyrics-status.lua`, and the `sfx/` folder |
| [`setup/side-visualizer/`](setup/side-visualizer/) | Each side PC | `visualizer.lua` — left: `visualizer --side=left` · right: `--side=right` |
| [`setup/pocket-remote/`](setup/pocket-remote/) | Pocket Advanced Computer | `pocket.lua` |

**Monitors:** main **9×3** @ scale **0.5**; side viz **4×4** @ **0.5**.

**Wireless:** Ender Modem on main + pocket (+ sides for viz). Protocols: `pocket_mp3` (remote), `jukebox_viz` (visualizers).

### 3. Desktop → Minecraft flow

1. Download (optional) → Convert → Fetch lyrics in CC Music Tools  
2. Copy `.dfpwm` / `.lrc` into the game  
3. Run **Importer** and drag-drop onto the **computer screen**  
4. Restart jukebox so tracks with lyrics show `(L)`

More detail: [`INSTALL.md`](INSTALL.md).

## Title bar credit

The jukebox title bar shows **Developer: ProOnlyUNO** in red (single `colors.red` write — no offset faux-bold).

## License / credit

Developer: **ProOnlyUNO**  
Built for CC:Tweaked DFPWM libraries on Advanced Computers + monitors.
