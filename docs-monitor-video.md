# Offline monitor music video (CTJP-12)

No in-game HTTPS. Download the video on Windows, encode locally, drag-drop into CC.

## Pack layout

Same stem beside the song (Importer-friendly):

```text
music/$uicideboy$/Sing Me a Lullaby, My Sweet Temptation/
  Escape from BABYLON.dfpwm
  Escape from BABYLON.cvid
  Escape from BABYLON.lrc   (optional)
```

`.cvid` is a **CVID1** frame pack (sextant blit cells). Audio stays on `.dfpwm`.

## Encode (Windows)

Defaults for a **9×3 Advanced Monitor @ scale 0.5** (~270×60 wall): **160×45 cells @ 8 fps** (largest 32:9 encode under the ~20 MiB CC disk limit for ~3 min tracks; jukebox fill-blits to the monitor).

### CC Music Tools (Convert tab)

1. Open **Convert** → **Music video → .cvid + .dfpwm**
2. Pick your MP4
3. Set output to the Artist/Album folder (e.g. `…\$uicideboy$\Sing Me a Lullaby, My Sweet Temptation`)
4. **Convert video pack**

### CLI

```text
cd desktop
python ../tools/cvid_convert.py path\to\clip.mp4 -o "path\to\Artist\Album" --fps 8 --cells 160x45
```

## Sync into Minecraft

1. Copy `Song.dfpwm` + `Song.cvid` onto the computer (or run **Importer** and drag both).
2. Restart **jukebox** (F5 alone does not reload code after a `.lua` replace).

## Jukebox UX

1. Play the song → normal now-playing UI on the main monitor.
2. After **~3.5s** (`videoDelaySec`), that same monitor switches to the music video.
3. **Audio keeps playing** (no second stream).
4. **Right-click** (terminal) or tap **SONG** → back to the normal song screen for the rest of this track.
5. Bottom **BACK** / **NEXT**: stay in video mode if the neighbour track also has a `.cvid`; otherwise fall back to the song UI.

Standalone smoke player: `videoplayer.lua` (drag-drop `.cvid`+`.dfpwm`, or `videoplayer "Escape from BABYLON"`).

## First smoke pack (Alex)

Encoded from the uploaded lyric video into the desktop library:

```text
C:\Users\Smoke\Desktop\CC\Music CC\$UICIDEBOY$\Sing Me a Lullaby, My Sweet Temptation\
  Escape from BABYLON.dfpwm
  Escape from BABYLON.cvid   (160×45 @ 8 fps, ~1129 frames, ~15.5 MiB)
```
