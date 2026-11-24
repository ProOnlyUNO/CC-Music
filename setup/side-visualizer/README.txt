SIDE visualizer computers — copy these files here
=================================================

Each side panel is its OWN computer + 4x4 Advanced Monitor + Ender Modem.
Copy visualizer.lua onto BOTH left and right side computers.

Files
-----
  visualizer.lua

Monitor
-------
  4x4 Advanced Monitor, scale 0.5
  Same wireless network as the main jukebox.

How to run
----------
  Left side:
    visualizer --side=left

  Right side:
    visualizer --side=right

  Title color FX (default breathe — soft palette shift + breathe):
    visualizer --side=left --title-fx=breathe
    visualizer --title-fx=pulse|bass|warmcool|breathe
  Press T while running to cycle title FX modes.

Auto-start (optional)
---------------------
  edit startup

  Left:
    shell.run("visualizer", "--side=left")

  Right:
    shell.run("visualizer", "--side=right")

  Optional title FX on startup:
    shell.run("visualizer", "--side=left", "--title-fx=breathe")

Notes
-----
  Main computer must be running the current jukebox.lua (it broadcasts to the viz).
  After replacing visualizer.lua, restart that side PC — F5 is not enough.
  Lyrics mode with an empty lyric line keeps the fancy viz (no “(waiting…)”).
  APPEARANCE on the main jukebox picks Bars / Wave / VU / Off (field vizMode on
  jukebox_viz). Accent + animations also ride along on the same packets.
