MAIN computer — copy these files here
=====================================

Copy every .lua in this folder onto your MAIN CC computer
(the one with the jukebox speakers / music disks).

Files
-----
  jukebox.lua         Main pixel jukebox UI (required) — library / lyrics / APPEARANCE
  Importer.lua        Drag-drop .dfpwm / .lrc / .nfp onto the computer screen
  sort-music.lua      Optional — tidy library, merge Name 2 collisions, clear root
                      media, place orphan lyrics + keep .nfp art beside songs.
                      Audio deletes OFF by default.
                      Run: sort-music (preview) then sort-music --apply
                      Add --dedupe only to remove confirmed audio extras
                      Root .dfpwm/.lrc/.nfp → disks; never deletes *.lua / startup
  delete-music.lua    Optional — delete a song or whole album safely
  lyrics-status.lua   Optional — count tracks with / without lyrics

Monitor
-------
  9x3 Advanced Monitor, scale 0.5
  Also attach an Ender Modem (wireless) if you use the pocket remote
  or side visualizers.

Run
---
  jukebox
  Importer

Auto-start (optional)
---------------------
  edit startup
  then put:
    shell.run("jukebox")

After adding songs with Importer, restart jukebox (or F5) so (L) lyrics markers show.
