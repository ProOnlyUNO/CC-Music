#!/usr/bin/env python3
"""
CC Music Tools — Windows desktop GUI for CC:Tweaked jukebox prep.

Developer: ProOnlyUNO

Tabs:
  Download  — YouTube playlist/album URL → select tracks → MP3 (yt-dlp)
  Convert   — MP3/WAV/… → .dfpwm (needs ffmpeg 5.1+)
  Lyrics    — LRCLIB public API → .lrc beside tracks + pack
  How to use / Commands
"""

from __future__ import annotations

import os
import queue
import subprocess
import sys
import threading
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox, ttk

import convert_core
import download_core
import lyrics_core

APP_TITLE = "CC Music Tools"
APP_VERSION = "1.2.0"
DEVELOPER = "ProOnlyUNO"


def _install_dir() -> Path:
    """Writable folder beside the exe (frozen) or this script (source)."""
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent


def _bundle_dir() -> Path:
    if getattr(sys, "frozen", False) and hasattr(sys, "_MEIPASS"):
        return Path(sys._MEIPASS)  # type: ignore[attr-defined]
    return _install_dir()


APP_DIR = _install_dir()
DEFAULT_DOWNLOAD_OUT = APP_DIR / "mp3_downloads"
DEFAULT_CONVERT_OUT = APP_DIR / "dfpwm_out"
DEFAULT_LYRICS_PACK = APP_DIR / "lyrics_pack"
YTMP3_ALT_URL = "https://media.ytmp3.gg/tools/youtube-playlist-downloader/mkehhz"

# Matrix / binary cyan — glass panels (semi-transparent look over the bg)
COLORS = {
    "bg_deep": "#050b10",
    "panel": "#0b1824",
    "panel_hi": "#123048",
    "panel_glass": "#0a1a28",
    "border": "#2a6a78",
    "border_soft": "#1a4050",
    "text": "#e6fff8",
    "text_dim": "#9fd4c4",
    "accent": "#4affe0",
    "entry_bg": "#06141e",
    "entry_fg": "#f0fffa",
    "log_bg": "#041018",
    "log_fg": "#c8ffe8",
    "scrim": (3, 12, 18),
    # RGBA glass overlays drawn onto the Matrix background
    "glass_fill": (8, 28, 40, 118),
    "glass_edge": (60, 220, 200, 70),
}


def find_asset(*names: str) -> Path | None:
    """Prefer assets beside the exe / sources, then PyInstaller bundle."""
    roots = [APP_DIR, _bundle_dir()]
    for root in roots:
        for name in names:
            cand = root / "assets" / name
            if cand.is_file():
                return cand
    return None


def apply_window_icon(root: tk.Tk | tk.Toplevel) -> None:
    """Set taskbar/title-bar icon from bundled assets (ico + png)."""
    ico = find_asset("app-icon.ico")
    png = find_asset("app-icon.png")
    if ico is not None:
        try:
            root.iconbitmap(default=str(ico))
        except tk.TclError:
            try:
                root.iconbitmap(str(ico))
            except tk.TclError:
                pass
    if png is not None:
        try:
            from PIL import Image, ImageTk

            img = Image.open(png).convert("RGBA")
            # Keep a few sizes for Windows taskbar / alt-tab
            photos: list = []
            for edge in (16, 32, 48, 64, 128, 256):
                photos.append(ImageTk.PhotoImage(img.resize((edge, edge), Image.Resampling.LANCZOS)))
            root.iconphoto(True, *photos)
            root._icon_photos = photos  # noqa: SLF001 — keep refs alive
        except Exception:  # noqa: BLE001
            pass


class App(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title(APP_TITLE)
        self.minsize(720, 560)
        self.geometry("820x640")
        self.configure(bg=COLORS["bg_deep"])
        apply_window_icon(self)
        self._log_q: queue.Queue[str] = queue.Queue()
        self._busy = False
        self._cancel = False
        self._last_out: Path | None = None
        self._bg_src = None
        self._bg_photo = None
        self._bg_size: tuple[int, int] | None = None
        self._playlist_entries: list[download_core.PlaylistEntry] = []
        self._track_vars: list[tk.BooleanVar] = []
        self._playlist_title: str = ""

        self._load_background_source()
        self._build()
        self.after(100, self._drain_log)
        self.bind("<Configure>", self._on_resize)

    def _load_background_source(self) -> None:
        path = find_asset("background.jpg", "background.png")
        if path is None:
            return
        try:
            from PIL import Image

            self._bg_src = Image.open(path).convert("RGB")
        except Exception:  # noqa: BLE001
            self._bg_src = None

    def _compose_background(self, width: int, height: int):
        if self._bg_src is None or width < 40 or height < 40:
            return None
        from PIL import Image, ImageDraw, ImageEnhance, ImageFilter, ImageTk

        img = self._bg_src.resize((width, height), Image.Resampling.LANCZOS)
        # Keep the Matrix binary bright so it reads through glass panels
        img = ImageEnhance.Brightness(img).enhance(0.92)
        img = ImageEnhance.Contrast(img).enhance(1.08)
        base = img.convert("RGBA")
        overlay = Image.new("RGBA", (width, height), (0, 0, 0, 0))
        draw = ImageDraw.Draw(overlay)
        scrim = COLORS["scrim"]
        # Light scrim only — Matrix stays visible behind the UI
        top_h = max(80, int(height * 0.28))
        for y in range(top_h):
            t = y / max(1, top_h - 1)
            alpha = int(110 * (1.0 - t * 0.7))
            draw.line([(0, y), (width, y)], fill=(*scrim, alpha))
        bot0 = int(height * 0.72)
        for y in range(bot0, height):
            t = (y - bot0) / max(1, height - bot0)
            alpha = int(40 + 70 * t)
            draw.line([(0, y), (width, y)], fill=(*scrim, alpha))

        # Frosted glass panels (content shell + log strip) — translucent so binary shows through
        glass = Image.new("RGBA", (width, height), (0, 0, 0, 0))
        gdraw = ImageDraw.Draw(glass)
        mx, my = int(width * 0.03), int(height * 0.03)
        mw, mh = int(width * 0.94), int(height * 0.94)
        # Soft blur plate under the shell
        plate = Image.new("RGBA", (width, height), (0, 0, 0, 0))
        pdraw = ImageDraw.Draw(plate)
        pdraw.rounded_rectangle(
            [mx, my, mx + mw, my + mh],
            radius=18,
            fill=COLORS["glass_fill"],
            outline=COLORS["glass_edge"],
            width=2,
        )
        # Inner tab well — slightly clearer glass
        tab_top = my + int(height * 0.09)
        tab_bot = my + int(height * 0.62)
        pdraw.rounded_rectangle(
            [mx + 14, tab_top, mx + mw - 14, tab_bot],
            radius=12,
            fill=(6, 22, 34, 90),
            outline=(80, 230, 210, 55),
            width=1,
        )
        # Log strip
        log_top = my + int(height * 0.66)
        pdraw.rounded_rectangle(
            [mx + 14, log_top, mx + mw - 14, my + mh - 14],
            radius=12,
            fill=(4, 16, 26, 130),
            outline=(80, 230, 210, 45),
            width=1,
        )
        plate = plate.filter(ImageFilter.GaussianBlur(radius=0.6))
        glass = Image.alpha_composite(glass, plate)
        composed = Image.alpha_composite(Image.alpha_composite(base, overlay), glass).convert("RGB")
        return ImageTk.PhotoImage(composed)

    def _on_resize(self, event: tk.Event) -> None:
        if event.widget is not self:
            return
        w, h = max(1, event.width), max(1, event.height)
        if self._bg_size == (w, h):
            return
        self._bg_size = (w, h)
        photo = self._compose_background(w, h)
        if photo is None:
            return
        self._bg_photo = photo
        if hasattr(self, "_bg_canvas"):
            self._bg_canvas.delete("bg")
            self._bg_canvas.create_image(0, 0, anchor="nw", image=photo, tags="bg")
            self._bg_canvas.tag_lower("bg")

    # ------------------------------------------------------------------ UI
    def _apply_style(self) -> None:
        style = ttk.Style(self)
        try:
            style.theme_use("clam")
        except tk.TclError:
            pass

        # Near-deep backgrounds so canvas glass + Matrix read through the chrome
        deep = COLORS["bg_deep"]
        glass = COLORS["panel_glass"]
        bg = COLORS["panel"]
        bg2 = COLORS["panel_hi"]
        fg = COLORS["text"]
        dim = COLORS["text_dim"]
        accent = COLORS["accent"]
        entry_bg = COLORS["entry_bg"]
        border = COLORS["border"]

        style.configure(".", background=glass, foreground=fg, fieldbackground=entry_bg, bordercolor=border)
        style.configure("TFrame", background=glass)
        # Empty layouts = no opaque flat fill; Matrix/glass on the canvas shows through
        style.layout("Glass.TFrame", [])
        style.layout("Card.TFrame", [])
        style.layout("Header.TFrame", [])
        style.configure("Glass.TFrame", background=deep)
        style.configure("Card.TFrame", background=glass)
        style.configure("Header.TFrame", background=deep)
        style.configure("TLabel", background=deep, foreground=fg)
        style.configure(
            "Header.TLabel",
            background=deep,
            foreground=accent,
            font=("Segoe UI Semibold", 17),
        )
        style.configure("Subhead.TLabel", background=deep, foreground=dim, font=("Segoe UI", 9))
        style.configure("Dim.TLabel", background=deep, foreground=dim)
        style.configure("Glass.TLabel", background=deep, foreground=fg)

        style.configure(
            "TButton",
            background=bg2,
            foreground=fg,
            bordercolor=border,
            focusthickness=1,
            padding=(10, 4),
        )
        style.map(
            "TButton",
            background=[("active", "#1a4a62"), ("disabled", "#0a1822")],
            foreground=[("disabled", "#557788")],
        )
        style.configure("TCheckbutton", background=deep, foreground=fg)
        style.map(
            "TCheckbutton",
            background=[("active", deep), ("selected", deep)],
            foreground=[("active", accent), ("selected", accent)],
        )
        style.configure(
            "TEntry",
            fieldbackground=entry_bg,
            foreground=COLORS["entry_fg"],
            insertcolor=COLORS["entry_fg"],
            bordercolor=COLORS["border_soft"],
        )
        style.configure("TLabelframe", background=deep, foreground=accent, bordercolor=border)
        style.configure("TLabelframe.Label", background=deep, foreground=accent)
        style.configure("TNotebook", background=deep, borderwidth=0, tabmargins=(6, 4, 6, 0))
        # Translucent-feeling tabs — dark cyan glass, selected pops with accent text
        style.configure(
            "TNotebook.Tab",
            background="#0c3040",
            foreground=dim,
            padding=(14, 7),
            borderwidth=0,
            lightcolor=border,
            darkcolor=deep,
        )
        style.map(
            "TNotebook.Tab",
            background=[("selected", "#154858"), ("active", "#1a5568")],
            foreground=[("selected", accent), ("active", fg)],
        )

        style.configure("Horizontal.TScrollbar", background=bg2, troughcolor=deep, bordercolor=border)
        style.configure("Vertical.TScrollbar", background=bg2, troughcolor=deep, bordercolor=border)

    def _build(self) -> None:
        self._apply_style()

        self._bg_canvas = tk.Canvas(self, highlightthickness=0, bd=0, bg=COLORS["bg_deep"])
        self._bg_canvas.place(x=0, y=0, relwidth=1, relheight=1)

        # Glass shell — deep bg so frosted Matrix on the canvas reads through
        shell = ttk.Frame(self, style="Glass.TFrame", padding=0)
        shell.place(relx=0.03, rely=0.03, relwidth=0.94, relheight=0.94)

        header = ttk.Frame(shell, style="Header.TFrame", padding=(14, 12, 14, 6))
        header.pack(fill="x")
        ttk.Label(header, text=APP_TITLE, style="Header.TLabel").pack(anchor="w")
        ttk.Label(
            header,
            text=f"Download → Convert → Lyrics for your CC:Tweaked jukebox.  Developer: {DEVELOPER}  ·  v{APP_VERSION}",
            style="Subhead.TLabel",
        ).pack(anchor="w")

        nb = ttk.Notebook(shell)
        nb.pack(fill="both", expand=True, padx=14, pady=(6, 0))
        self._notebook = nb

        self.tab_download = ttk.Frame(nb, padding=10, style="Card.TFrame")
        self.tab_convert = ttk.Frame(nb, padding=10, style="Card.TFrame")
        self.tab_lyrics = ttk.Frame(nb, padding=10, style="Card.TFrame")
        self.tab_help = ttk.Frame(nb, padding=10, style="Card.TFrame")
        self.tab_commands = ttk.Frame(nb, padding=10, style="Card.TFrame")
        nb.add(self.tab_download, text="  Download  ")
        nb.add(self.tab_convert, text="  Convert  ")
        nb.add(self.tab_lyrics, text="  Fetch lyrics  ")
        nb.add(self.tab_help, text="  How to use  ")
        nb.add(self.tab_commands, text="  Commands  ")

        self._build_download(self.tab_download)
        self._build_convert(self.tab_convert)
        self._build_lyrics(self.tab_lyrics)
        self._build_help(self.tab_help)
        self._build_commands(self.tab_commands)

        bottom = ttk.Frame(shell, style="Glass.TFrame", padding=(14, 8, 14, 12))
        bottom.pack(fill="both", expand=False)

        row = ttk.Frame(bottom, style="Glass.TFrame")
        row.pack(fill="x")
        ttk.Label(row, text="Progress log", font=("Segoe UI Semibold", 10)).pack(side="left")
        self.btn_open = ttk.Button(row, text="Open output folder", command=self._open_output)
        self.btn_open.pack(side="right", padx=(6, 0))
        self.btn_cancel = ttk.Button(row, text="Cancel", command=self._request_cancel, state="disabled")
        self.btn_cancel.pack(side="right")

        log_frame = ttk.Frame(bottom, style="Glass.TFrame")
        log_frame.pack(fill="both", expand=True, pady=(6, 0))
        self.log = tk.Text(
            log_frame,
            height=11,
            wrap="word",
            font=("Consolas", 9),
            state="disabled",
            background=COLORS["log_bg"],
            foreground=COLORS["log_fg"],
            insertbackground=COLORS["log_fg"],
            relief="flat",
            highlightthickness=1,
            highlightbackground=COLORS["border"],
            highlightcolor=COLORS["accent"],
        )
        scroll = ttk.Scrollbar(log_frame, command=self.log.yview)
        self.log.configure(yscrollcommand=scroll.set)
        self.log.pack(side="left", fill="both", expand=True)
        scroll.pack(side="right", fill="y")

        self.status = ttk.Label(bottom, text="Ready", anchor="w", style="Dim.TLabel")
        self.status.pack(fill="x", pady=(6, 0))

        # Kick an initial paint once geometry is known
        self.after(50, self._refresh_background)

    def _refresh_background(self) -> None:
        self.update_idletasks()
        w, h = max(1, self.winfo_width()), max(1, self.winfo_height())
        if self._bg_size == (w, h):
            return
        self._bg_size = (w, h)
        photo = self._compose_background(w, h)
        if photo is None or not hasattr(self, "_bg_canvas"):
            return
        self._bg_photo = photo
        self._bg_canvas.delete("bg")
        self._bg_canvas.create_image(0, 0, anchor="nw", image=photo, tags="bg")
        self._bg_canvas.tag_lower("bg")

    def _build_download(self, parent: ttk.Frame) -> None:
        self.dl_url = tk.StringVar()
        self.dl_out = tk.StringVar(value=str(DEFAULT_DOWNLOAD_OUT))
        self.dl_status = tk.StringVar(value="Paste a YouTube playlist or album URL, then Fetch titles.")

        url_frame = ttk.Frame(parent, style="Card.TFrame")
        url_frame.pack(fill="x", pady=(0, 4))
        ttk.Label(url_frame, text="YouTube playlist / album URL").pack(anchor="w")
        url_row = ttk.Frame(url_frame, style="Card.TFrame")
        url_row.pack(fill="x")
        ttk.Entry(url_row, textvariable=self.dl_url).pack(side="left", fill="x", expand=True)
        ttk.Button(url_row, text="Fetch titles", command=self._start_fetch_playlist, width=12).pack(
            side="left", padx=(6, 0)
        )

        self._path_row(parent, "MP3 download folder", self.dl_out, lambda: self._pick_dir(self.dl_out))

        list_wrap = ttk.LabelFrame(parent, text="Tracks", padding=6)
        list_wrap.pack(fill="both", expand=True, pady=(8, 0))

        canvas_row = ttk.Frame(list_wrap, style="Card.TFrame")
        canvas_row.pack(fill="both", expand=True)
        self._dl_canvas = tk.Canvas(
            canvas_row,
            highlightthickness=1,
            highlightbackground=COLORS["border"],
            bg=COLORS["entry_bg"],
            height=180,
        )
        dl_scroll = ttk.Scrollbar(canvas_row, orient="vertical", command=self._dl_canvas.yview)
        self._dl_canvas.configure(yscrollcommand=dl_scroll.set)
        self._dl_canvas.pack(side="left", fill="both", expand=True)
        dl_scroll.pack(side="right", fill="y")

        self._dl_inner = ttk.Frame(self._dl_canvas, style="Card.TFrame")
        self._dl_window = self._dl_canvas.create_window((0, 0), window=self._dl_inner, anchor="nw")
        self._dl_inner.bind(
            "<Configure>",
            lambda _e: self._dl_canvas.configure(scrollregion=self._dl_canvas.bbox("all")),
        )
        self._dl_canvas.bind(
            "<Configure>",
            lambda e: self._dl_canvas.itemconfigure(self._dl_window, width=e.width),
        )

        sel_row = ttk.Frame(list_wrap, style="Card.TFrame")
        sel_row.pack(fill="x", pady=(6, 0))
        ttk.Button(sel_row, text="Select all", command=lambda: self._set_all_tracks(True), width=12).pack(
            side="left"
        )
        ttk.Button(sel_row, text="Select none", command=lambda: self._set_all_tracks(False), width=12).pack(
            side="left", padx=(6, 0)
        )
        ttk.Label(sel_row, textvariable=self.dl_status, style="Dim.TLabel").pack(side="left", padx=(12, 0))

        ttk.Label(
            parent,
            text=(
                "Uses yt-dlp (recommended). Install:  python -m pip install -U yt-dlp   "
                "· also needs ffmpeg for MP3 extract. After download, switch to Convert.\n"
                f"Alternate (browser): {YTMP3_ALT_URL}"
            ),
            wraplength=740,
            style="Dim.TLabel",
        ).pack(anchor="w", pady=(8, 0))

        actions = ttk.Frame(parent, style="Card.TFrame")
        actions.pack(fill="x", pady=(10, 0))
        ttk.Button(actions, text="Download selected MP3s", command=self._start_download).pack(side="left")
        ttk.Button(actions, text="Send folder → Convert", command=self._handoff_to_convert).pack(
            side="left", padx=(8, 0)
        )

    def _clear_track_list(self) -> None:
        for child in self._dl_inner.winfo_children():
            child.destroy()
        self._track_vars = []
        self._playlist_entries = []

    def _populate_track_list(self, entries: list[download_core.PlaylistEntry]) -> None:
        self._clear_track_list()
        self._playlist_entries = list(entries)
        for entry in entries:
            var = tk.BooleanVar(value=True)
            self._track_vars.append(var)
            label = f"{entry.index:03d}.  {entry.title}  ({download_core.format_duration(entry.duration)})"
            ttk.Checkbutton(self._dl_inner, text=label, variable=var).pack(anchor="w", pady=1)
        self.dl_status.set(f"{self._playlist_title} — {len(entries)} track(s)")
        self._dl_canvas.yview_moveto(0)

    def _set_all_tracks(self, value: bool) -> None:
        for var in self._track_vars:
            var.set(value)

    def _selected_entries(self) -> list[download_core.PlaylistEntry]:
        out: list[download_core.PlaylistEntry] = []
        for entry, var in zip(self._playlist_entries, self._track_vars):
            if var.get():
                out.append(entry)
        return out

    def _handoff_to_convert(self) -> None:
        folder = self.dl_out.get().strip()
        if not folder:
            messagebox.showerror(APP_TITLE, "Pick an MP3 download folder first.")
            return
        path = Path(folder)
        if not path.is_dir():
            messagebox.showerror(APP_TITLE, f"Folder not found:\n{folder}")
            return
        self.conv_input.set(str(path.resolve()))
        self._notebook.select(self.tab_convert)
        self.status.configure(text="Convert input set from Download folder.")
        self._append_log(f"Hand-off → Convert input: {path.resolve()}")

    def _build_convert(self, parent: ttk.Frame) -> None:
        self.conv_input = tk.StringVar()
        self.conv_out = tk.StringVar(value=str(DEFAULT_CONVERT_OUT))
        self.conv_artist = tk.StringVar()
        self.conv_title_first = tk.BooleanVar(value=False)
        self.conv_tags = tk.BooleanVar(value=False)
        self.conv_flat = tk.BooleanVar(value=False)
        self.conv_overwrite = tk.BooleanVar(value=False)
        self.conv_dry = tk.BooleanVar(value=False)
        self.conv_keep_dupes = tk.BooleanVar(value=False)

        self._path_row(parent, "Music folder or files", self.conv_input, self._pick_convert_input)
        self._path_row(parent, "Output folder", self.conv_out, lambda: self._pick_dir(self.conv_out))

        opts = ttk.LabelFrame(parent, text="Options", padding=8)
        opts.pack(fill="x", pady=(8, 0))

        artist_row = ttk.Frame(opts)
        artist_row.pack(fill="x", pady=2)
        ttk.Label(artist_row, text="Force artist folder:", width=18).pack(side="left")
        ttk.Entry(artist_row, textvariable=self.conv_artist).pack(side="left", fill="x", expand=True)

        checks = ttk.Frame(opts)
        checks.pack(fill="x", pady=(4, 0))
        for text, var in (
            ("Title - Artist filenames", self.conv_title_first),
            ("Use embedded tags (ffprobe)", self.conv_tags),
            ("Flat output (no artist folders)", self.conv_flat),
            ("Overwrite existing", self.conv_overwrite),
            ("Keep duplicates", self.conv_keep_dupes),
            ("Dry run (preview only)", self.conv_dry),
        ):
            ttk.Checkbutton(checks, text=text, variable=var).pack(anchor="w")

        ttk.Label(
            parent,
            text="Requires ffmpeg 5.1+ on PATH (winget install ffmpeg). Output is Artist/Title.dfpwm by default.",
            wraplength=740,
            style="Dim.TLabel",
        ).pack(anchor="w", pady=(8, 0))

        actions = ttk.Frame(parent)
        actions.pack(fill="x", pady=(10, 0))
        ttk.Button(actions, text="Convert to DFPWM", command=self._start_convert).pack(side="left")

    def _build_lyrics(self, parent: ttk.Frame) -> None:
        self.lyr_root = tk.StringVar()
        self.lyr_pack = tk.StringVar(value=str(DEFAULT_LYRICS_PACK))
        self.lyr_delay = tk.StringVar(value="0.55")
        self.lyr_dry = tk.BooleanVar(value=False)

        self._path_row(parent, "Music folder (.dfpwm library)", self.lyr_root, lambda: self._pick_dir(self.lyr_root))
        self._path_row(parent, "Pack output folder", self.lyr_pack, lambda: self._pick_dir(self.lyr_pack))

        opts = ttk.LabelFrame(parent, text="Options", padding=8)
        opts.pack(fill="x", pady=(8, 0))
        delay_row = ttk.Frame(opts)
        delay_row.pack(fill="x")
        ttk.Label(delay_row, text="API delay (seconds):", width=18).pack(side="left")
        ttk.Entry(delay_row, textvariable=self.lyr_delay, width=8).pack(side="left")
        ttk.Checkbutton(opts, text="Dry run (scan only)", variable=self.lyr_dry).pack(anchor="w", pady=(4, 0))

        ttk.Label(
            parent,
            text="Uses the public LRCLIB API only (https://lrclib.net). Writes .lrc next to each .dfpwm and mirrors into pack/lyrics/.",
            wraplength=740,
            style="Dim.TLabel",
        ).pack(anchor="w", pady=(8, 0))

        actions = ttk.Frame(parent)
        actions.pack(fill="x", pady=(10, 0))
        ttk.Button(actions, text="Fetch lyrics", command=self._start_lyrics).pack(side="left")

    def _info_text(self, parent: ttk.Frame) -> tk.Text:
        wrap = ttk.Frame(parent, style="Card.TFrame")
        wrap.pack(fill="both", expand=True)
        text = tk.Text(
            wrap,
            wrap="word",
            font=("Segoe UI", 10),
            height=18,
            borderwidth=0,
            background=COLORS["panel"],
            foreground=COLORS["text"],
            insertbackground=COLORS["text"],
            relief="flat",
            highlightthickness=0,
            padx=4,
            pady=2,
        )
        scroll = ttk.Scrollbar(wrap, command=text.yview)
        text.configure(yscrollcommand=scroll.set)
        text.pack(side="left", fill="both", expand=True)
        scroll.pack(side="right", fill="y")
        return text

    def _build_help(self, parent: ttk.Frame) -> None:
        text = self._info_text(parent)
        help_body = f"""How to use — CC Music Tools
Developer: {DEVELOPER}  ·  v{APP_VERSION}

Windows prep here, then drop files into your CC:Tweaked jukebox.
Open setup/ next to this app (START_HERE.txt) for which .lua goes on which computer.

1) Install the CC scripts first (in Minecraft)
   • setup/main-computer/     → jukebox.lua, Importer.lua
                                 (+ optional sort-music.lua, delete-music.lua, lyrics-status.lua)
   • setup/side-visualizer/   → visualizer.lua  (each side PC)
   • setup/pocket-remote/     → pocket.lua      (Pocket Advanced Computer remote)
   Tip: after replacing a .lua, restart the program — F5 alone does not reload code.

2) Recommended monitors
   • Main jukebox: 9×3 Advanced Monitor, scale 0.5
   • Side visualizers: 4×4 Advanced Monitor each, scale 0.5

3) Wireless pocket remote — pocket.lua
   • Ender Modem on MAIN + Pocket → copy pocket.lua → run: pocket
   • Protocol: pocket_mp3 · SYNC → tap a song

4) Desktop tools flow (this app)
   a. Download (optional) — paste a YouTube playlist/album URL → Fetch titles
      → check the tracks you want → Download selected MP3s
      → Send folder → Convert
      Needs yt-dlp:  python -m pip install -U yt-dlp
      Alternate (browser only): {YTMP3_ALT_URL}
   b. Convert — Browse your MP3/WAV/FLAC folder → Convert to DFPWM
      (needs ffmpeg 5.1+ on PATH: winget install ffmpeg)
   c. Fetch lyrics — point at the .dfpwm folder → Fetch lyrics (public LRCLIB only)
   d. Open output folder, copy the .dfpwm (+ .lrc) into Minecraft
   e. In-game: run Importer → drag-drop onto the computer screen (not a monitor)
   f. Restart jukebox (or F5) — songs with lyrics show (L)

That’s the whole loop. Use Dry run anytime for a preview with no writes.
See the Commands tab for the short in-game cheat sheet.
"""
        text.insert("1.0", help_body)
        text.configure(state="disabled")

    def _build_commands(self, parent: ttk.Frame) -> None:
        text = self._info_text(parent)
        commands_body = """Commands — quick list for in-game
Friendly cheat sheet. Scripts live in the setup/ folder next to this app —
copy from setup/main-computer, setup/side-visualizer, or setup/pocket-remote.

Auto-start jukebox (main PC)
  edit startup
  then put:
    shell.run("jukebox")
  Save, reboot — jukebox opens by itself.

Auto-start visualizers (side PCs)
  Left:   shell.run("visualizer", "--side=left")
  Right:  shell.run("visualizer", "--side=right")
  Optional:  visualizer --side=left --fps=30

Auto-start pocket remote (Pocket Advanced Computer)
  edit startup
    shell.run("pocket")
  Needs Ender Modem on pocket + main. Protocol: pocket_mp3

Run once (no startup)
  jukebox
  visualizer --side=left
  visualizer --side=right
  Importer
  pocket                 ← runs pocket.lua on the Pocket Computer

Music library helpers (main PC)
  sort-music                        preview tidy (safe, no writes)
  sort-music --apply                nest Artist/Album + Singles + SFX + lyrics
  sort-music --apply --lyrics-only  place orphan .lrc beside songs
  sort-music --apply --dedupe       also delete duplicate .dfpwm (opt-in only)
  lyrics-status                     count tracks with / without .lrc
  delete-music                      pick Artist → Album → Song (or DELETE ALBUM)
  delete-music --dry-run            preview deletes only

Importer (new songs + lyrics)
  1. Run: Importer
  2. Pick artist + album when asked
  3. Drag-drop .dfpwm / .lrc onto the computer screen
  Prefer Importer for new drops; use sort-music --apply --lyrics-only for bulk leftovers.

After changes
  Restart jukebox (or F5) so the list refreshes. Songs with lyrics show (L).
  Restart side PCs / pocket after replacing their .lua files.

You’re set — enjoy the music.
"""
        text.insert("1.0", commands_body)
        text.configure(state="disabled")

    def _path_row(self, parent, label, var, browse_cmd) -> None:
        frame = ttk.Frame(parent)
        frame.pack(fill="x", pady=3)
        ttk.Label(frame, text=label).pack(anchor="w")
        row = ttk.Frame(frame)
        row.pack(fill="x")
        ttk.Entry(row, textvariable=var).pack(side="left", fill="x", expand=True)
        ttk.Button(row, text="Browse…", command=browse_cmd, width=10).pack(side="left", padx=(6, 0))

    # -------------------------------------------------------------- pickers
    def _pick_dir(self, var: tk.StringVar) -> None:
        initial = var.get().strip() or str(Path.home() / "Downloads")
        path = filedialog.askdirectory(title="Select folder", initialdir=initial if Path(initial).exists() else None)
        if path:
            var.set(path)

    def _pick_convert_input(self) -> None:
        choice = messagebox.askyesnocancel(
            "Select input",
            "Yes = pick a folder\nNo = pick one or more files\nCancel = abort",
            icon="question",
        )
        if choice is None:
            return
        if choice:
            self._pick_dir(self.conv_input)
            return
        initial = self.conv_input.get().strip() or str(Path.home() / "Downloads")
        paths = filedialog.askopenfilenames(
            title="Select audio files",
            initialdir=initial if Path(initial).is_dir() else (str(Path(initial).parent) if initial else None),
            filetypes=[
                ("Audio", "*.mp3 *.wav *.flac *.m4a *.ogg *.opus *.aac *.webm *.wma"),
                ("All files", "*.*"),
            ],
        )
        if paths:
            # Store as | separated for multi-file
            self.conv_input.set("|".join(paths))

    # ----------------------------------------------------------------- log
    def _append_log(self, msg: str) -> None:
        self.log.configure(state="normal")
        self.log.insert("end", msg + "\n")
        self.log.see("end")
        self.log.configure(state="disabled")

    def _drain_log(self) -> None:
        try:
            while True:
                self._append_log(self._log_q.get_nowait())
        except queue.Empty:
            pass
        self.after(100, self._drain_log)

    def _ui_log(self, msg: str) -> None:
        self._log_q.put(msg)

    def _set_busy(self, busy: bool) -> None:
        self._busy = busy
        self.btn_cancel.configure(state="normal" if busy else "disabled")
        self.status.configure(text="Working…" if busy else "Ready")

    def _request_cancel(self) -> None:
        self._cancel = True
        self._ui_log("Cancel requested…")

    def _open_output(self) -> None:
        target = self._last_out
        if target is None:
            for cand in (self.dl_out.get(), self.conv_out.get(), self.lyr_pack.get()):
                p = Path(cand) if cand else None
                if p and p.exists():
                    target = p
                    break
        if target is None or not Path(target).exists():
            messagebox.showinfo(APP_TITLE, "No output folder yet. Run a job first.")
            return
        path = str(Path(target).resolve())
        if sys.platform.startswith("win"):
            os.startfile(path)  # type: ignore[attr-defined]
        else:
            subprocess.Popen(["xdg-open", path])

    # -------------------------------------------------------------- workers
    def _start_fetch_playlist(self) -> None:
        if self._busy:
            messagebox.showwarning(APP_TITLE, "A job is already running.")
            return
        url = self.dl_url.get().strip()
        if not url:
            messagebox.showerror(APP_TITLE, "Paste a YouTube playlist or album URL first.")
            return

        self._cancel = False
        self._set_busy(True)
        self._append_log("--- Download: fetch titles ---")
        self.dl_status.set("Fetching playlist…")

        def work() -> None:
            try:
                title, entries = download_core.list_playlist(url, log=self._ui_log)

                def apply() -> None:
                    self._playlist_title = title
                    self._populate_track_list(entries)
                    self._set_busy(False)

                self.after(0, apply)
            except Exception as e:  # noqa: BLE001
                self._ui_log(f"ERROR: {e}")

                def fail() -> None:
                    self.dl_status.set("Fetch failed — see log.")
                    self._set_busy(False)

                self.after(0, fail)

        threading.Thread(target=work, daemon=True).start()

    def _start_download(self) -> None:
        if self._busy:
            messagebox.showwarning(APP_TITLE, "A job is already running.")
            return
        selected = self._selected_entries()
        if not selected:
            messagebox.showerror(APP_TITLE, "Fetch titles first, then check at least one track.")
            return
        out = self.dl_out.get().strip()
        if not out:
            messagebox.showerror(APP_TITLE, "Pick an MP3 download folder.")
            return

        self._cancel = False
        self._set_busy(True)
        self._append_log("--- Download: MP3 ---")
        self._last_out = Path(out)
        self.dl_status.set(f"Downloading {len(selected)} track(s)…")

        def work() -> None:
            try:
                ok, fail, folder = download_core.download_entries(
                    selected,
                    out,
                    log=self._ui_log,
                    should_cancel=lambda: self._cancel,
                )

                def done() -> None:
                    self.dl_status.set(f"Saved {ok}, failed {fail} → {folder}")
                    self._set_busy(False)
                    if ok > 0:
                        # Offer hand-off into Convert
                        if messagebox.askyesno(
                            APP_TITLE,
                            f"Downloaded {ok} MP3(s).\n\nSend this folder to the Convert tab?",
                        ):
                            self._handoff_to_convert()

                self.after(0, done)
            except Exception as e:  # noqa: BLE001
                self._ui_log(f"ERROR: {e}")

                def fail_ui() -> None:
                    self.dl_status.set("Download failed — see log.")
                    self._set_busy(False)

                self.after(0, fail_ui)

        threading.Thread(target=work, daemon=True).start()

    def _start_convert(self) -> None:
        if self._busy:
            messagebox.showwarning(APP_TITLE, "A job is already running.")
            return
        raw = self.conv_input.get().strip()
        if not raw:
            messagebox.showerror(APP_TITLE, "Pick a music folder or files first.")
            return
        out = self.conv_out.get().strip()
        if not out:
            messagebox.showerror(APP_TITLE, "Pick an output folder.")
            return

        inputs = [p for p in raw.split("|") if p]
        for p in inputs:
            if not Path(p).exists():
                messagebox.showerror(APP_TITLE, f"Path not found:\n{p}")
                return

        self._cancel = False
        self._set_busy(True)
        self._append_log("--- Convert ---")
        self._last_out = Path(out)

        def work() -> None:
            try:
                convert_core.run_convert(
                    inputs,
                    out,
                    artist=self.conv_artist.get().strip() or None,
                    flat=self.conv_flat.get(),
                    dry_run=self.conv_dry.get(),
                    overwrite=self.conv_overwrite.get(),
                    keep_duplicates=self.conv_keep_dupes.get(),
                    title_first=self.conv_title_first.get(),
                    use_tags=self.conv_tags.get(),
                    log=self._ui_log,
                    should_cancel=lambda: self._cancel,
                )
            except Exception as e:  # noqa: BLE001
                self._ui_log(f"ERROR: {e}")
            finally:
                self.after(0, lambda: self._set_busy(False))

        threading.Thread(target=work, daemon=True).start()

    def _start_lyrics(self) -> None:
        if self._busy:
            messagebox.showwarning(APP_TITLE, "A job is already running.")
            return
        root = self.lyr_root.get().strip()
        pack = self.lyr_pack.get().strip()
        if not root:
            messagebox.showerror(APP_TITLE, "Pick a music folder that contains .dfpwm files.")
            return
        if not Path(root).is_dir():
            messagebox.showerror(APP_TITLE, f"Folder not found:\n{root}")
            return
        if not pack:
            messagebox.showerror(APP_TITLE, "Pick a pack output folder.")
            return
        try:
            delay = float(self.lyr_delay.get().strip() or "0.55")
        except ValueError:
            messagebox.showerror(APP_TITLE, "Delay must be a number (e.g. 0.55).")
            return

        self._cancel = False
        self._set_busy(True)
        self._append_log("--- Fetch lyrics ---")
        self._last_out = Path(pack)

        def work() -> None:
            try:
                lyrics_core.run_fetch(
                    [root],
                    pack_dir=pack,
                    delay=delay,
                    dry_run=self.lyr_dry.get(),
                    log=self._ui_log,
                    should_cancel=lambda: self._cancel,
                )
            except Exception as e:  # noqa: BLE001
                self._ui_log(f"ERROR: {e}")
            finally:
                self.after(0, lambda: self._set_busy(False))

        threading.Thread(target=work, daemon=True).start()


def main() -> int:
    # Ensure sibling imports work when frozen / run as script
    here = str(APP_DIR)
    if here not in sys.path:
        sys.path.insert(0, here)
    app = App()
    app.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
