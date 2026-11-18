POCKET remote — copy these files here
=====================================

Pocket Advanced Computer wireless remote for the jukebox.
Script name: pocket.lua   Protocol: pocket_mp3

Files
-----
  pocket.lua

Setup
-----
  1. Attach an Ender Modem to the Pocket Computer.
  2. Attach an Ender Modem to the MAIN jukebox computer (same wireless network).
  3. Copy pocket.lua onto the pocket.
  4. Run:  pocket
     or auto-start:
       edit startup
       shell.run("pocket")
  5. Stay in range, tap SYNC, then tap any song to play.

Controls
--------
  SYNC loads the library from the main jukebox.
  Tap a track to play. Play / pause / skip / shuffle / volume work from the pocket
  while jukebox.lua is running on the main computer.
