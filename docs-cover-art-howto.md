# Cover art how-to (Alex)

## Sing Me a Lullaby cover (done)

Source PNG: Project `media/sing-me-a-lullaby-cover.png`

Converted with desktop `nfp_core` → 256×256 `cover.nfp` (default), placed at:

- `C:\Users\Smoke\Desktop\CC\Music CC\$UICIDEBOY$\Sing Me a Lullaby, My Sweet Temptation\cover.nfp`
- `C:\Users\Smoke\Documents\CC-Music-Tools\dfpwm_out\$uicideboy$\Sing Me a Lullaby, My Sweet Temptation\cover.nfp`
- Project `media/sing-me-a-lullaby-cover.nfp` (copy)

Copy that album folder (or just `cover.nfp`) onto the main CC computer under the same Artist/Album path, then restart jukebox (or F5) so the thumb shows.

## Convert any PNG/JPG → cover.nfp (Windows)

1. Open **CC Music Tools** → **Convert**, or from the repo desktop folder:

```powershell
cd C:\Users\Smoke\Downloads\CC-Music-repo\desktop
python -c "from nfp_core import write_nfp; write_nfp(r'PATH\to\cover.png', r'PATH\to\Artist\Album\cover.nfp')"
```

2. Keep `cover.nfp` beside the album’s `.dfpwm` files (`Artist/Album/cover.nfp`).

## Drop art in-game (Importer)

1. Copy updated `Importer.lua` onto the main computer.
2. Run `Importer` → pick Artist + Album.
3. Drop onto the **computer screen** (not a monitor):
   - `cover.nfp` / `cover.png` / `cover.jpg` → album folder as cover
   - `Song.nfp` (matching a `.dfpwm` basename) → beside that song
4. If nothing matches, Importer prompts for Artist + Album.
5. Tip: jukebox only draws `.nfp`. PNG/JPG drops are stored, but convert to `.nfp` for thumbs.
