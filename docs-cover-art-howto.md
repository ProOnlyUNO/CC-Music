# Cover art how-to (Alex)

## Sing Me a Lullaby cover (done)

Source PNG: Project `media/sing-me-a-lullaby-cover.png`

Converted with desktop `nfp_core` → 96×96 `cover.nfp` (default, matches jukebox IMG), placed at:

- `C:\Users\Smoke\Desktop\CC\Music CC\$UICIDEBOY$\Sing Me a Lullaby, My Sweet Temptation\cover.nfp`
- `C:\Users\Smoke\Documents\CC-Music-Tools\dfpwm_out\$uicideboy$\Sing Me a Lullaby, My Sweet Temptation\cover.nfp`
- Project `media/sing-me-a-lullaby-cover.nfp` (copy)

Copy that album folder (or just `cover.nfp`) onto the main CC computer under the same Artist/Album path, then restart jukebox (or F5) so the thumb shows.

## Convert any PNG/JPG → cover.nfp (Windows)

### In the app (preferred)

1. Open **CC Music Tools** → **Convert**.
2. Scroll to **Album art → cover.nfp**.
3. **Browse…** → pick a PNG/JPG (or several), an album folder, or a library root (`Artist/…`).
4. Optional: check **Overwrite existing cover.nfp**.
5. Click **Convert cover art**.

Writes `Artist/Album/cover.nfp` next to the song files using the fixed pipeline: **96×96**, official CC palette, BOX resize (matches jukebox decode).

### From a shell (optional)

```powershell
cd C:\Users\Smoke\Downloads\CC-Music\desktop
python -c "from nfp_core import batch_write_cover_nfp; batch_write_cover_nfp([r'PATH\to\Artist\Album'], overwrite=True, log=print)"
```

Or a single image:

```powershell
python -c "from nfp_core import write_cover_nfp; write_cover_nfp(r'PATH\to\cover.png', overwrite=True)"
```

Keep `cover.nfp` beside the album’s `.dfpwm` files (`Artist/Album/cover.nfp`).

## Drop art in-game (Importer)

1. Copy updated `Importer.lua` onto the main computer.
2. Run `Importer` → pick Artist + Album.
3. Drop onto the **computer screen** (not a monitor):
   - `cover.nfp` / `cover.png` / `cover.jpg` → album folder as cover
   - `Song.nfp` (matching a `.dfpwm` basename) → beside that song
4. If nothing matches, Importer prompts for Artist + Album.
5. Tip: jukebox only draws `.nfp`. PNG/JPG drops are stored, but convert to `.nfp` for thumbs.
