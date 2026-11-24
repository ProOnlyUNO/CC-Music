#!/usr/bin/env python3
"""
CC Music Tools — Windows desktop GUI for CC:Tweaked jukebox prep.

Developer: ProOnlyUNO

Tabs:
  Download  — YouTube search/URL or Genius album → select tracks → MP3 (yt-dlp)
  Convert   — MP3/WAV/… → .dfpwm + PNG/JPG → cover.nfp; MP4 → .cvid + .dfpwm
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

import build_info
import convert_core
import download_core
import genius_core
import lyrics_core
import nfp_core
import update_check
import video_core

APP_TITLE = "CC Music Tools"
APP_VERSION = build_info.APP_VERSION
BUILD_STAMP = build_info.BUILD_STAMP
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

# Windows transparent-color key: frames/labels using this punch through to the
# Matrix underlay window so binary rain reads across the whole app.
TRANSPARENT_KEY = "#010203"

# Matrix / binary cyan — glass chrome; KEY regions are truly see-through
COLORS = {
    "bg_deep": TRANSPARENT_KEY,  # see-through on Windows
    "panel": TRANSPARENT_KEY,
    "panel_hi": "#14384c",
    "panel_glass": TRANSPARENT_KEY,
    "border": "#3a8a96",
    "border_soft": "#1e4a58",
    "text": "#f2fffb",
    "text_dim": "#a8e0d0",
    "accent": "#5dffea",
    "accent_soft": "#2a9a88",
    # Readable scrims only on interactive fields (not full slabs)
    "entry_bg": "#071820",
    "entry_fg": "#f0fffa",
    "log_bg": TRANSPARENT_KEY,  # Matrix shows through the log too
    "log_fg": "#d2ffe8",
    "scrim": (2, 10, 14),
    # Underlay frosted plates — light so rain stays obvious
    "glass_fill": (6, 24, 36, 48),
    "glass_edge": (90, 235, 215, 110),
    "glass_well": (4, 18, 28, 36),
    "glass_log": (3, 14, 22, 42),
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
        self.configure(bg=TRANSPARENT_KEY)
        apply_window_icon(self)
        self._log_q: queue.Queue[str] = queue.Queue()
        self._busy = False
        self._cancel = False
        self._last_out: Path | None = None
        self._bg_src = None
        self._bg_photo = None
        self._bg_size: tuple[int, int] | None = None
        self._underlay: tk.Toplevel | None = None
        self._glass_ok = False
        self._playlist_entries: list[download_core.PlaylistEntry] = []
        self._track_vars: list[tk.BooleanVar] = []
        self._playlist_title: str = ""
        self._search_results: list[download_core.SearchResult] = []

        self._load_background_source()
        self._enable_glass_punchthrough()
        self._build_underlay()
        self._build()
        self.after(100, self._drain_log)
        self.bind("<Configure>", self._on_main_configure)
        self.bind("<Map>", self._on_main_map)
        self.bind("<Unmap>", self._on_main_unmap)
        self.protocol("WM_DELETE_WINDOW", self._on_close)
        # Quiet background update check — never blocks first paint.
        self.after(800, self._start_update_check)

    def _enable_glass_punchthrough(self) -> None:
        """Make TRANSPARENT_KEY pixels see through to the Matrix underlay (Windows)."""
        if sys.platform != "win32":
            self._glass_ok = False
            return
        try:
            self.wm_attributes("-transparentcolor", TRANSPARENT_KEY)
            self._glass_ok = True
        except tk.TclError:
            self._glass_ok = False

    def _build_underlay(self) -> None:
        """Borderless Matrix window kept directly under the main client area."""
        u = tk.Toplevel(self)
        u.withdraw()
        u.overrideredirect(True)
        u.configure(bg="#000000")
        try:
            u.wm_attributes("-toolwindow", True)
        except tk.TclError:
            pass
        # Never steal keyboard focus from the chrome window.
        try:
            u.wm_attributes("-disabled", False)
        except tk.TclError:
            pass
        self._bg_canvas = tk.Canvas(u, highlightthickness=0, bd=0, bg="#000000")
        self._bg_canvas.pack(fill="both", expand=True)
        self._underlay = u
        self._arm_underlay_click_guards()
        self.after(80, self._win32_pin_underlay_below)

    def _arm_underlay_click_guards(self) -> None:
        """Clicks on transparent glass hit the underlay — never let it rise above chrome."""
        if self._underlay is None:
            return

        def guard(_event: tk.Event | None = None) -> str:
            self._reassert_chrome_stack()
            return "break"

        for widget in (self._underlay, self._bg_canvas):
            for seq in (
                "<Button-1>",
                "<Button-2>",
                "<Button-3>",
                "<ButtonPress>",
                "<ButtonRelease-1>",
                "<FocusIn>",
                "<Map>",
            ):
                widget.bind(seq, guard, add="+")

    def _reassert_chrome_stack(self) -> None:
        """Keep Matrix rain decorative and below the interactive chrome."""
        if self._underlay is None:
            return
        try:
            self._underlay.lower(self)
            self.lift()
            # Restore keyboard focus to chrome without stealing from other apps mid-type
            # only when the underlay somehow became the active window.
            try:
                if self.focus_displayof() is None:
                    self.focus_force()
            except tk.TclError:
                self.focus_force()
        except tk.TclError:
            pass
        self._win32_pin_underlay_below()

    def _win32_pin_underlay_below(self) -> None:
        """Win32: pin underlay directly under main without activating it."""
        if sys.platform != "win32" or self._underlay is None:
            return
        try:
            import ctypes
            from ctypes import wintypes

            user32 = ctypes.windll.user32
            hwnd_main = wintypes.HWND(int(self.winfo_id()))
            hwnd_under = wintypes.HWND(int(self._underlay.winfo_id()))
            # Tk winfo_id is often a child; walk to top-level HWNDs.
            GA_ROOT = 2
            hwnd_main = user32.GetAncestor(hwnd_main, GA_ROOT) or hwnd_main
            hwnd_under = user32.GetAncestor(hwnd_under, GA_ROOT) or hwnd_under

            GWL_EXSTYLE = -20
            WS_EX_NOACTIVATE = 0x08000000
            WS_EX_TOOLWINDOW = 0x00000080
            style = user32.GetWindowLongW(hwnd_under, GWL_EXSTYLE)
            user32.SetWindowLongW(
                hwnd_under, GWL_EXSTYLE, style | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW
            )

            SWP_NOSIZE = 0x0001
            SWP_NOMOVE = 0x0002
            SWP_NOACTIVATE = 0x0010
            # hwndInsertAfter = main → underlay is placed behind main.
            user32.SetWindowPos(
                hwnd_under,
                hwnd_main,
                0,
                0,
                0,
                0,
                SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
            )
        except Exception:  # noqa: BLE001
            pass

    def _sync_underlay(self) -> None:
        if self._underlay is None:
            return
        try:
            if not self.winfo_viewable() or self.state() == "iconic":
                self._underlay.withdraw()
                return
        except tk.TclError:
            return
        self.update_idletasks()
        x = int(self.winfo_rootx())
        y = int(self.winfo_rooty())
        w = max(1, int(self.winfo_width()))
        h = max(1, int(self.winfo_height()))
        self._underlay.geometry(f"{w}x{h}+{x}+{y}")
        try:
            self._underlay.deiconify()
            self._underlay.lower(self)
        except tk.TclError:
            pass
        self._win32_pin_underlay_below()
        if self._bg_size != (w, h):
            self._bg_size = (w, h)
            photo = self._compose_background(w, h)
            if photo is not None:
                self._bg_photo = photo
                self._bg_canvas.delete("bg")
                self._bg_canvas.create_image(0, 0, anchor="nw", image=photo, tags="bg")
                self._bg_canvas.tag_lower("bg")

    def _on_main_configure(self, event: tk.Event) -> None:
        if event.widget is not self:
            return
        self._sync_underlay()

    def _on_main_map(self, _event: tk.Event | None = None) -> None:
        self.after(20, self._sync_underlay)
        self.after(40, self._reassert_chrome_stack)

    def _on_main_unmap(self, _event: tk.Event | None = None) -> None:
        if self._underlay is not None:
            try:
                self._underlay.withdraw()
            except tk.TclError:
                pass

    def _on_close(self) -> None:
        if self._underlay is not None:
            try:
                self._underlay.destroy()
            except tk.TclError:
                pass
            self._underlay = None
        self.destroy()

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
        # Bright Matrix rain — this is what shows through transparent chrome
        img = ImageEnhance.Brightness(img).enhance(1.18)
        img = ImageEnhance.Contrast(img).enhance(1.2)
        img = ImageEnhance.Color(img).enhance(1.15)
        base = img.convert("RGBA")
        overlay = Image.new("RGBA", (width, height), (0, 0, 0, 0))
        draw = ImageDraw.Draw(overlay)
        scrim = COLORS["scrim"]
        # Soft vignette only — keep rain visible in the content well
        top_h = max(40, int(height * 0.14))
        for y in range(top_h):
            t = y / max(1, top_h - 1)
            alpha = int(45 * (1.0 - t * 0.9))
            draw.line([(0, y), (width, y)], fill=(*scrim, alpha))
        bot0 = int(height * 0.82)
        for y in range(bot0, height):
            t = (y - bot0) / max(1, height - bot0)
            alpha = int(10 + 40 * t)
            draw.line([(0, y), (width, y)], fill=(*scrim, alpha))

        # Light frosted plates on the underlay (seen through punch-through chrome)
        mx, my = int(width * 0.028), int(height * 0.028)
        mw, mh = int(width * 0.944), int(height * 0.944)
        plate = Image.new("RGBA", (width, height), (0, 0, 0, 0))
        pdraw = ImageDraw.Draw(plate)
        pdraw.rounded_rectangle(
            [mx, my, mx + mw, my + mh],
            radius=20,
            fill=COLORS["glass_fill"],
            outline=COLORS["glass_edge"],
            width=2,
        )
        tab_top = my + int(height * 0.088)
        tab_bot = my + int(height * 0.60)
        pdraw.rounded_rectangle(
            [mx + 12, tab_top, mx + mw - 12, tab_bot],
            radius=14,
            fill=COLORS["glass_well"],
            outline=(100, 240, 220, 80),
            width=1,
        )
        log_top = my + int(height * 0.645)
        pdraw.rounded_rectangle(
            [mx + 12, log_top, mx + mw - 12, my + mh - 12],
            radius=14,
            fill=COLORS["glass_log"],
            outline=(90, 230, 210, 65),
            width=1,
        )
        blurred = plate.filter(ImageFilter.GaussianBlur(radius=1.8))
        edge = Image.new("RGBA", (width, height), (0, 0, 0, 0))
        edraw = ImageDraw.Draw(edge)
        edraw.rounded_rectangle(
            [mx, my, mx + mw, my + mh],
            radius=20,
            outline=COLORS["glass_edge"],
            width=2,
        )
        glass = Image.alpha_composite(blurred, edge)
        composed = Image.alpha_composite(Image.alpha_composite(base, overlay), glass).convert("RGB")
        return ImageTk.PhotoImage(composed)

    # ------------------------------------------------------------------ UI
    def _apply_style(self) -> None:
        style = ttk.Style(self)
        try:
            style.theme_use("clam")
        except tk.TclError:
            pass

        # KEY backgrounds punch through to the Matrix underlay (Windows)
        key = TRANSPARENT_KEY
        bg2 = COLORS["panel_hi"]
        fg = COLORS["text"]
        dim = COLORS["text_dim"]
        accent = COLORS["accent"]
        entry_bg = COLORS["entry_bg"]
        border = COLORS["border"]

        style.configure(".", background=key, foreground=fg, fieldbackground=entry_bg, bordercolor=border)
        style.configure("TFrame", background=key)
        # Empty layouts = no opaque flat fill over the Matrix underlay
        style.layout("Glass.TFrame", [])
        style.layout("Card.TFrame", [])
        style.layout("Header.TFrame", [])
        style.configure("Glass.TFrame", background=key)
        style.configure("Card.TFrame", background=key)
        style.configure("Header.TFrame", background=key)
        style.configure("TLabel", background=key, foreground=fg)
        style.configure(
            "Header.TLabel",
            background=key,
            foreground=accent,
            font=("Segoe UI Semibold", 18),
        )
        style.configure("Subhead.TLabel", background=key, foreground=dim, font=("Segoe UI", 9))
        style.configure("Dim.TLabel", background=key, foreground=dim)
        style.configure("Glass.TLabel", background=key, foreground=fg)
        style.configure("Section.TLabel", background=key, foreground=accent, font=("Segoe UI Semibold", 10))

        style.configure(
            "TButton",
            background=bg2,
            foreground=fg,
            bordercolor=border,
            focusthickness=1,
            padding=(12, 5),
            font=("Segoe UI", 9),
        )
        style.map(
            "TButton",
            background=[("active", "#1c5568"), ("disabled", "#0a1822")],
            foreground=[("disabled", "#557788")],
        )
        style.configure(
            "Accent.TButton",
            background="#176878",
            foreground=COLORS["text"],
            bordercolor=accent,
            padding=(14, 6),
            font=("Segoe UI Semibold", 9),
        )
        style.map(
            "Accent.TButton",
            background=[("active", "#1f8498"), ("disabled", "#0a1822")],
            foreground=[("disabled", "#557788")],
        )
        style.configure(
            "Tab.TButton",
            background="#0c3848",
            foreground=dim,
            bordercolor=border,
            padding=(14, 7),
            font=("Segoe UI", 9),
        )
        style.map(
            "Tab.TButton",
            background=[("active", "#1a6070")],
            foreground=[("active", fg)],
        )
        style.configure(
            "TabSelected.TButton",
            background="#176878",
            foreground=accent,
            bordercolor=accent,
            padding=(14, 7),
            font=("Segoe UI Semibold", 9),
        )
        style.map(
            "TabSelected.TButton",
            background=[("active", "#1f8498")],
            foreground=[("active", accent)],
        )
        style.configure("TCheckbutton", background=key, foreground=fg, font=("Segoe UI", 9))
        style.map(
            "TCheckbutton",
            background=[("active", key), ("selected", key)],
            foreground=[("active", accent), ("selected", accent)],
        )
        style.configure(
            "TEntry",
            fieldbackground=entry_bg,
            foreground=COLORS["entry_fg"],
            insertcolor=COLORS["entry_fg"],
            bordercolor=COLORS["border_soft"],
            padding=4,
        )
        # Labelframe: transparent fill, accent label text
        style.configure("TLabelframe", background=key, foreground=accent, bordercolor=border)
        style.configure("TLabelframe.Label", background=key, foreground=accent, font=("Segoe UI Semibold", 9))
        style.configure("TNotebook", background=key, borderwidth=0, tabmargins=(8, 6, 8, 0))
        style.configure(
            "TNotebook.Tab",
            background="#0c3848",
            foreground=dim,
            padding=(16, 8),
            borderwidth=0,
            lightcolor=border,
            darkcolor=key,
            font=("Segoe UI", 9),
        )
        style.map(
            "TNotebook.Tab",
            background=[("selected", "#176878"), ("active", "#1a6070")],
            foreground=[("selected", accent), ("active", fg)],
        )

        style.configure("Horizontal.TScrollbar", background=bg2, troughcolor=key, bordercolor=border)
        style.configure("Vertical.TScrollbar", background=bg2, troughcolor=key, bordercolor=border)
        style.configure(
            "Glass.Horizontal.TProgressbar",
            troughcolor="#06141c",
            background=accent,
            bordercolor=border,
            lightcolor=accent,
            darkcolor="#176878",
            thickness=12,
        )

    def _build(self) -> None:
        self._apply_style()

        # No in-window canvas — Matrix lives on the underlay; chrome punches through.
        shell = ttk.Frame(self, style="Glass.TFrame", padding=0)
        shell.place(relx=0.03, rely=0.03, relwidth=0.94, relheight=0.94)

        header = ttk.Frame(shell, style="Header.TFrame", padding=(16, 14, 16, 8))
        header.pack(fill="x")
        ttk.Label(header, text=APP_TITLE, style="Header.TLabel").pack(anchor="w")
        ttk.Label(
            header,
            text=(
                f"Download → lyrics → Artist/Album → Convert for your CC:Tweaked jukebox.  "
                f"Developer: {DEVELOPER}  ·  v{APP_VERSION}  ·  build {BUILD_STAMP}"
            ),
            style="Subhead.TLabel",
        ).pack(anchor="w", pady=(2, 0))

        # Custom tabs (not ttk.Notebook) — Notebook paints an opaque client that
        # hides the Matrix underlay even with transparentcolor.
        tab_bar = ttk.Frame(shell, style="Glass.TFrame", padding=(14, 4, 14, 0))
        tab_bar.pack(fill="x")
        self._tab_buttons: dict[str, ttk.Button] = {}
        self._tab_frames: dict[str, ttk.Frame] = {}
        self._active_tab = "download"
        body = ttk.Frame(shell, style="Card.TFrame", padding=(14, 6, 14, 0))
        body.pack(fill="both", expand=True)
        self._tab_body = body

        tab_specs = [
            ("download", "  Download  "),
            ("convert", "  Convert  "),
            ("lyrics", "  Fetch lyrics  "),
            ("help", "  How to use  "),
            ("commands", "  Commands  "),
        ]
        for key, label in tab_specs:
            btn = ttk.Button(
                tab_bar,
                text=label,
                style="Tab.TButton",
                command=lambda k=key: self._show_tab(k),
            )
            btn.pack(side="left", padx=(0, 4))
            self._tab_buttons[key] = btn
            frame = ttk.Frame(body, padding=10, style="Card.TFrame")
            self._tab_frames[key] = frame

        self.tab_download = self._tab_frames["download"]
        self.tab_convert = self._tab_frames["convert"]
        self.tab_lyrics = self._tab_frames["lyrics"]
        self.tab_help = self._tab_frames["help"]
        self.tab_commands = self._tab_frames["commands"]

        self._build_download(self.tab_download)
        self._build_convert(self.tab_convert)
        self._build_lyrics(self.tab_lyrics)
        self._build_help(self.tab_help)
        self._build_commands(self.tab_commands)
        self._show_tab("download")

        bottom = ttk.Frame(shell, style="Glass.TFrame", padding=(14, 8, 14, 12))
        bottom.pack(fill="both", expand=False)

        # Dual progress bars — overall job + current track / step
        prog = ttk.Frame(bottom, style="Glass.TFrame")
        prog.pack(fill="x", pady=(0, 6))
        self.prog_overall_var = tk.DoubleVar(value=0.0)
        self.prog_track_var = tk.DoubleVar(value=0.0)
        self.prog_detail = tk.StringVar(value="")
        ttk.Label(prog, text="Overall", style="Dim.TLabel", width=8).grid(row=0, column=0, sticky="w")
        self.prog_overall = ttk.Progressbar(
            prog,
            style="Glass.Horizontal.TProgressbar",
            variable=self.prog_overall_var,
            maximum=100,
            mode="determinate",
        )
        self.prog_overall.grid(row=0, column=1, sticky="ew", padx=(6, 0), pady=2)
        ttk.Label(prog, text="Current", style="Dim.TLabel", width=8).grid(row=1, column=0, sticky="w")
        self.prog_track = ttk.Progressbar(
            prog,
            style="Glass.Horizontal.TProgressbar",
            variable=self.prog_track_var,
            maximum=100,
            mode="determinate",
        )
        self.prog_track.grid(row=1, column=1, sticky="ew", padx=(6, 0), pady=2)
        ttk.Label(prog, textvariable=self.prog_detail, style="Dim.TLabel").grid(
            row=2, column=0, columnspan=2, sticky="w", pady=(2, 0)
        )
        prog.columnconfigure(1, weight=1)
        self._progress_pulse_id: str | None = None

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
            background=TRANSPARENT_KEY,
            foreground=COLORS["log_fg"],
            insertbackground=COLORS["log_fg"],
            relief="flat",
            highlightthickness=1,
            highlightbackground=COLORS["border"],
            highlightcolor=COLORS["accent"],
            selectbackground="#176878",
            selectforeground=COLORS["text"],
        )
        scroll = ttk.Scrollbar(log_frame, command=self.log.yview)
        self.log.configure(yscrollcommand=scroll.set)
        self.log.pack(side="left", fill="both", expand=True)
        scroll.pack(side="right", fill="y")

        self.status = ttk.Label(bottom, text="Ready", anchor="w", style="Dim.TLabel")
        self.status.pack(fill="x", pady=(6, 0))

        # Kick underlay sync once geometry is known
        self.after(50, self._sync_underlay)

    def _show_tab(self, key: str) -> None:
        if key not in self._tab_frames:
            return
        for name, frame in self._tab_frames.items():
            if name == key:
                frame.pack(fill="both", expand=True)
            else:
                frame.pack_forget()
        for name, btn in self._tab_buttons.items():
            btn.configure(style="TabSelected.TButton" if name == key else "Tab.TButton")
        self._active_tab = key

    def _build_download(self, parent: ttk.Frame) -> None:
        self.dl_url = tk.StringVar()
        self.dl_search = tk.StringVar()
        self.dl_source = tk.StringVar(value="youtube")
        self.dl_search_songs = tk.BooleanVar(value=True)
        self.dl_search_playlists = tk.BooleanVar(value=True)
        self.dl_out = tk.StringVar(value=str(DEFAULT_DOWNLOAD_OUT))
        self.dl_status = tk.StringVar(
            value="YouTube or Genius album → fetch titles → download (auto YouTube match)."
        )

        search_frame = ttk.Frame(parent, style="Card.TFrame")
        search_frame.pack(fill="x", pady=(0, 4))
        self._dl_search_label = ttk.Label(search_frame, text="Search YouTube (songs & playlists)")
        self._dl_search_label.pack(anchor="w")
        search_row = ttk.Frame(search_frame, style="Card.TFrame")
        search_row.pack(fill="x")
        search_entry = ttk.Entry(search_row, textvariable=self.dl_search)
        search_entry.pack(side="left", fill="x", expand=True)
        search_entry.bind("<Return>", lambda _e: self._start_download_search())
        ttk.Button(search_row, text="Search", command=self._start_download_search, width=10).pack(
            side="left", padx=(6, 0)
        )
        opts = ttk.Frame(search_frame, style="Card.TFrame")
        opts.pack(fill="x", pady=(4, 0))
        ttk.Radiobutton(
            opts,
            text="YouTube",
            value="youtube",
            variable=self.dl_source,
            command=self._on_dl_source_change,
        ).pack(side="left")
        ttk.Radiobutton(
            opts,
            text="Genius album",
            value="genius",
            variable=self.dl_source,
            command=self._on_dl_source_change,
        ).pack(side="left", padx=(10, 0))
        self._dl_yt_opts = ttk.Frame(opts, style="Card.TFrame")
        self._dl_yt_opts.pack(side="left", padx=(14, 0))
        ttk.Checkbutton(self._dl_yt_opts, text="Songs", variable=self.dl_search_songs).pack(
            side="left"
        )
        ttk.Checkbutton(
            self._dl_yt_opts, text="Playlists", variable=self.dl_search_playlists
        ).pack(side="left", padx=(10, 0))

        results_wrap = ttk.LabelFrame(parent, text="Search results — click to load", padding=6)
        results_wrap.pack(fill="x", pady=(6, 0))
        results_row = ttk.Frame(results_wrap, style="Card.TFrame")
        results_row.pack(fill="x")
        self._search_list = tk.Listbox(
            results_row,
            height=5,
            activestyle="dotbox",
            selectmode="browse",
            exportselection=False,
            bg=COLORS["entry_bg"],
            fg=COLORS["entry_fg"],
            highlightthickness=1,
            highlightbackground=COLORS["border"],
            selectbackground=COLORS["accent_soft"],
            selectforeground=COLORS["text"],
            relief="flat",
            font=("Segoe UI", 9),
        )
        search_scroll = ttk.Scrollbar(results_row, orient="vertical", command=self._search_list.yview)
        self._search_list.configure(yscrollcommand=search_scroll.set)
        self._search_list.pack(side="left", fill="x", expand=True)
        search_scroll.pack(side="right", fill="y")
        self._search_list.bind("<Double-Button-1>", self._on_search_result_activate)
        self._search_list.bind("<Return>", self._on_search_result_activate)
        use_row = ttk.Frame(results_wrap, style="Card.TFrame")
        use_row.pack(fill="x", pady=(4, 0))
        ttk.Button(
            use_row,
            text="Use selected → Fetch titles",
            command=self._on_search_result_activate,
            width=24,
        ).pack(side="left")

        url_frame = ttk.Frame(parent, style="Card.TFrame")
        url_frame.pack(fill="x", pady=(8, 4))
        self._dl_url_label = ttk.Label(
            url_frame, text="Or paste YouTube playlist / song URL (or Genius album URL)"
        )
        self._dl_url_label.pack(anchor="w")
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
            bg=TRANSPARENT_KEY,
            height=140,
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
                "Flow: YouTube URL/search, or Genius album → fetch tracklist → pick tracks → "
                "Download (Genius auto-matches YouTube Topic/official) → lyrics → Artist/Album → Convert.\n"
                f"Alternate (browser): {YTMP3_ALT_URL}"
            ),
            wraplength=740,
            style="Dim.TLabel",
        ).pack(anchor="w", pady=(8, 0))

        actions = ttk.Frame(parent, style="Card.TFrame")
        actions.pack(fill="x", pady=(10, 0))
        ttk.Button(
            actions,
            text="Download selected MP3s",
            style="Accent.TButton",
            command=self._start_download,
        ).pack(side="left")
        ttk.Button(actions, text="Send folder → Convert", command=self._handoff_to_convert).pack(
            side="left", padx=(8, 0)
        )
        self._on_dl_source_change()

    def _on_dl_source_change(self) -> None:
        genius = self.dl_source.get() == "genius"
        if genius:
            self._dl_search_label.configure(text="Search Genius albums")
            self._dl_url_label.configure(text="Or paste Genius album URL")
            self._dl_yt_opts.pack_forget()
        else:
            self._dl_search_label.configure(text="Search YouTube (songs & playlists)")
            self._dl_url_label.configure(
                text="Or paste YouTube playlist / song URL (or Genius album URL)"
            )
            self._dl_yt_opts.pack(side="left", padx=(14, 0))

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
            who = ""
            if entry.artist and entry.artist.lower() not in (entry.title or "").lower():
                who = f"  — {entry.artist}"
            needs = "  [→ YT]" if download_core.needs_youtube_match(entry) else ""
            label = (
                f"{entry.index:03d}.  {entry.title}{who}  "
                f"({download_core.format_duration(entry.duration)}){needs}"
            )
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
        self._show_tab("convert")
        self.status.configure(text="Convert input set from Download folder.")
        self._append_log(f"Hand-off → Convert input: {path.resolve()}")

    def _build_convert(self, parent: ttk.Frame) -> None:
        self.conv_input = tk.StringVar()
        self.conv_out = tk.StringVar(value=str(DEFAULT_CONVERT_OUT))
        self.conv_artist = tk.StringVar()
        self.conv_title_first = tk.BooleanVar(value=False)
        self.conv_tags = tk.BooleanVar(value=True)
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
            text=(
                "Requires ffmpeg 5.1+ on PATH. Output is Artist/Album/Song.dfpwm "
                "(tags + folder layout). Sibling .lrc files are copied beside each .dfpwm; "
                "cover PNG/JPG / embedded art become Song.nfp + cover.nfp (96×96 CC palette)."
            ),
            wraplength=740,
            style="Dim.TLabel",
        ).pack(anchor="w", pady=(8, 0))

        actions = ttk.Frame(parent)
        actions.pack(fill="x", pady=(10, 0))
        ttk.Button(
            actions,
            text="Convert to DFPWM",
            style="Accent.TButton",
            command=self._start_convert,
        ).pack(side="left")

        # --- Album art → cover.nfp (standalone, batch-friendly) ---
        art = ttk.LabelFrame(parent, text="Album art → cover.nfp", padding=8)
        art.pack(fill="x", pady=(14, 0))
        self.art_input = tk.StringVar()
        self.art_overwrite = tk.BooleanVar(value=False)
        self._path_row(art, "PNG/JPG or Artist/Album folder", self.art_input, self._pick_art_input)
        ttk.Checkbutton(
            art,
            text="Overwrite existing cover.nfp",
            variable=self.art_overwrite,
        ).pack(anchor="w", pady=(4, 0))
        ttk.Label(
            art,
            text=(
                f"Writes cover.nfp next to the album’s song files (same Artist/Album layout as "
                f"downloads). Uses the fixed decode-compatible pipeline: "
                f"{nfp_core.DEFAULT_NFP_SIZE}×{nfp_core.DEFAULT_NFP_SIZE}, official CC palette, BOX resize. "
                f"Pick one image, several images, an album folder, or a library root to batch."
            ),
            wraplength=740,
            style="Dim.TLabel",
        ).pack(anchor="w", pady=(6, 0))
        art_actions = ttk.Frame(art)
        art_actions.pack(fill="x", pady=(8, 0))
        ttk.Button(
            art_actions,
            text="Convert cover art",
            style="Accent.TButton",
            command=self._start_art_convert,
        ).pack(side="left")

        # --- Music video → Song.cvid + Song.dfpwm ---
        vid = ttk.LabelFrame(parent, text="Music video → .cvid + .dfpwm", padding=8)
        vid.pack(fill="x", pady=(14, 0))
        self.vid_input = tk.StringVar()
        self.vid_out = tk.StringVar(value=str(DEFAULT_CONVERT_OUT))
        self.vid_cells = tk.StringVar(
            value=f"{video_core.DEFAULT_CELLS_W}x{video_core.DEFAULT_CELLS_H}"
        )
        self.vid_fps = tk.StringVar(value=str(video_core.DEFAULT_FPS))
        self.vid_overwrite = tk.BooleanVar(value=False)
        self.vid_dry = tk.BooleanVar(value=False)
        self._path_row(vid, "MP4/MKV/… or folder", self.vid_input, self._pick_video_input)
        self._path_row(vid, "Output (Artist/Album folder)", self.vid_out, lambda: self._pick_dir(self.vid_out))
        opts_v = ttk.Frame(vid)
        opts_v.pack(fill="x", pady=(4, 0))
        ttk.Label(opts_v, text="Cells WxH:", width=12).pack(side="left")
        ttk.Entry(opts_v, textvariable=self.vid_cells, width=10).pack(side="left", padx=(0, 12))
        ttk.Label(opts_v, text="FPS:").pack(side="left")
        ttk.Entry(opts_v, textvariable=self.vid_fps, width=6).pack(side="left", padx=(4, 12))
        ttk.Checkbutton(opts_v, text="Overwrite", variable=self.vid_overwrite).pack(side="left")
        ttk.Checkbutton(opts_v, text="Dry run", variable=self.vid_dry).pack(side="left", padx=(8, 0))
        ttk.Label(
            vid,
            text=(
                f"Offline encode for CC monitors (default {video_core.DEFAULT_CELLS_W}×"
                f"{video_core.DEFAULT_CELLS_H} @ {video_core.DEFAULT_FPS} fps). Writes Song.cvid + "
                "Song.dfpwm with the same stem — drop both via Importer beside the album. "
                "Jukebox plays the song UI first, then switches this monitor to the video after ~3.5s."
            ),
            wraplength=740,
            style="Dim.TLabel",
        ).pack(anchor="w", pady=(6, 0))
        vid_actions = ttk.Frame(vid)
        vid_actions.pack(fill="x", pady=(8, 0))
        ttk.Button(
            vid_actions,
            text="Convert video pack",
            style="Accent.TButton",
            command=self._start_video_convert,
        ).pack(side="left")

    def _pick_video_input(self) -> None:
        paths = filedialog.askopenfilenames(
            title="Select video file(s)",
            filetypes=[
                ("Video", "*.mp4 *.mkv *.webm *.mov *.avi *.m4v"),
                ("All files", "*.*"),
            ],
        )
        if paths:
            self.vid_input.set("|".join(paths))
            return
        folder = filedialog.askdirectory(title="Or select a folder of videos")
        if folder:
            self.vid_input.set(folder)

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
            background=TRANSPARENT_KEY,
            foreground=COLORS["text"],
            insertbackground=COLORS["text"],
            relief="flat",
            highlightthickness=0,
            padx=6,
            pady=4,
            selectbackground="#176878",
            selectforeground=COLORS["text"],
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
   a. Download (optional) — YouTube search/URL, or Genius album search/URL
      → Fetch titles → check tracks → Download (Genius auto-matches YouTube)
      → lyrics auto-fetch (LRCLIB) while artist/title are still known
      → prompt for library root → organize Artist/Album/Song.mp3 (+ .lrc)
      → Send folder → Convert
      Needs yt-dlp:  python -m pip install -U yt-dlp
      Alternate (browser only): {YTMP3_ALT_URL}
   b. Convert — Browse the Artist/Album folder → Convert to DFPWM
      Output: Artist/Album/Song.dfpwm (+ copies sibling .lrc + .nfp art)
      (needs ffmpeg 5.1+ on PATH: winget install ffmpeg)
   b2. Album art — on the same Convert tab, pick PNG/JPG or an Artist/Album
      (or library) folder → Convert cover art → writes cover.nfp (96×96)
      next to the songs. Batch-friendly; overwrite optional.
   b3. Music video — Convert tab → pick MP4 → Convert video pack
      → Song.cvid + Song.dfpwm (same stem). Put beside the song in
      Artist/Album/. Jukebox shows the song UI ~3.5s, then switches that
      monitor to the video (audio continuous). Right-click / SONG exits;
      NEXT/BACK stay in video mode when the neighbour has a .cvid.
      CLI: python tools/cvid_convert.py clip.mp4 -o out/Artist/Album
   c. Fetch lyrics — still available for libraries that need a re-scan
   d. Open output folder, copy Artist/Album trees into Minecraft
   e. In-game: run Importer → drag-drop onto the computer screen (not a monitor)
   f. Restart jukebox (or F5) — songs with lyrics show (L); cover.nfp shows thumbs

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
  sort-music                        preview tidy + merges/deletes (no writes)
  sort-music --apply                nest + root + SFX + lyrics (no audio deletes)
  sort-music --apply --dedupe       also delete confirmed audio extras only
  sort-music --apply --lyrics-only  place orphan .lrc beside songs (+ root cleanup)
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

    def _pick_art_input(self) -> None:
        choice = messagebox.askyesnocancel(
            "Select album art",
            "Yes = pick an Artist/Album (or library) folder\n"
            "No = pick one or more PNG/JPG images\n"
            "Cancel = abort",
            icon="question",
        )
        if choice is None:
            return
        if choice:
            self._pick_dir(self.art_input)
            return
        initial = self.art_input.get().strip() or str(Path.home() / "Downloads")
        paths = filedialog.askopenfilenames(
            title="Select cover images",
            initialdir=initial if Path(initial).is_dir() else (str(Path(initial).parent) if initial else None),
            filetypes=[
                ("Images", "*.png *.jpg *.jpeg *.webp *.bmp *.gif"),
                ("All files", "*.*"),
            ],
        )
        if paths:
            self.art_input.set("|".join(paths))

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

    def _stop_progress_pulse(self) -> None:
        if self._progress_pulse_id is not None:
            try:
                self.after_cancel(self._progress_pulse_id)
            except Exception:  # noqa: BLE001
                pass
            self._progress_pulse_id = None

    def _reset_progress(self) -> None:
        self._stop_progress_pulse()
        for bar in (self.prog_overall, self.prog_track):
            bar.stop()
            bar.configure(mode="determinate")
        self.prog_overall_var.set(0)
        self.prog_track_var.set(0)
        self.prog_detail.set("")

    def _set_progress(
        self,
        phase: str,
        frac: float | None,
        detail: str,
    ) -> None:
        """Update progress bars from a worker thread (marshalled to UI)."""

        def apply() -> None:
            self.prog_detail.set(detail)
            # Overall bar
            if phase in ("overall", "fetch", "search", "organize", "convert", "art", "lyrics_batch"):
                if frac is None:
                    if str(self.prog_overall["mode"]) != "indeterminate":
                        self.prog_overall.configure(mode="indeterminate")
                        self.prog_overall.start(12)
                else:
                    if str(self.prog_overall["mode"]) != "determinate":
                        self.prog_overall.stop()
                        self.prog_overall.configure(mode="determinate")
                    self.prog_overall_var.set(max(0.0, min(100.0, frac * 100.0)))
            # Current / track bar
            if phase in ("track", "lyrics", "fetch", "search"):
                if frac is None:
                    if str(self.prog_track["mode"]) != "indeterminate":
                        self.prog_track.configure(mode="indeterminate")
                        self.prog_track.start(10)
                else:
                    if str(self.prog_track["mode"]) != "determinate":
                        self.prog_track.stop()
                        self.prog_track.configure(mode="determinate")
                    self.prog_track_var.set(max(0.0, min(100.0, frac * 100.0)))
            elif phase in ("organize", "convert", "art", "lyrics_batch", "overall"):
                # Mirror overall into current when there's no separate track metric
                if phase != "overall" and frac is not None:
                    if str(self.prog_track["mode"]) != "determinate":
                        self.prog_track.stop()
                        self.prog_track.configure(mode="determinate")
                    self.prog_track_var.set(max(0.0, min(100.0, frac * 100.0)))
            short = detail if len(detail) < 90 else detail[:87] + "…"
            self.status.configure(text=short)

        self.after(0, apply)

    def _ui_progress(self, phase: str, frac: float | None, detail: str) -> None:
        self._set_progress(phase, frac, detail)

    def _set_busy(self, busy: bool) -> None:
        self._busy = busy
        self.btn_cancel.configure(state="normal" if busy else "disabled")
        if busy:
            self.status.configure(text="Working…")
        else:
            self._reset_progress()
            self.status.configure(text="Ready")

    def _request_cancel(self) -> None:
        self._cancel = True
        self._ui_log("Cancel requested…")
        self.prog_detail.set("Cancel requested…")

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
    def _populate_search_results(self, results: list[download_core.SearchResult]) -> None:
        self._search_results = list(results)
        self._search_list.delete(0, "end")
        for r in results:
            if r.kind == "playlist":
                kind = "Playlist"
            elif r.kind == "album":
                kind = "Album"
            else:
                kind = "Song"
            dur = (
                f"  ({download_core.format_duration(r.duration)})"
                if r.kind == "song" and r.duration
                else ""
            )
            who = f"  — {r.uploader or r.channel}" if (r.uploader or r.channel) else ""
            self._search_list.insert("end", f"[{kind}]  {r.title}{who}{dur}")

    def _selected_search_result(self) -> download_core.SearchResult | None:
        sel = self._search_list.curselection()
        if not sel:
            return None
        idx = int(sel[0])
        if idx < 0 or idx >= len(self._search_results):
            return None
        return self._search_results[idx]

    def _apply_search_result(self, result: download_core.SearchResult) -> None:
        self.dl_url.set(result.url)
        if result.kind == "album" or genius_core.is_genius_album_url(result.url):
            self.dl_source.set("genius")
            self._on_dl_source_change()
            kind = "genius album"
        else:
            kind = "playlist" if result.kind == "playlist" else "song"
        self.dl_status.set(f"Loaded {kind} URL — fetching titles…")
        self._start_fetch_playlist()

    def _on_search_result_activate(self, _event: tk.Event | None = None) -> None:
        result = self._selected_search_result()
        if result is None:
            messagebox.showinfo(APP_TITLE, "Select a search result first.")
            return
        self._apply_search_result(result)

    def _start_download_search(self) -> None:
        if self.dl_source.get() == "genius":
            self._start_genius_search()
        else:
            self._start_youtube_search()

    def _start_youtube_search(self) -> None:
        if self._busy:
            messagebox.showwarning(APP_TITLE, "A job is already running.")
            return
        query = self.dl_search.get().strip()
        if not query:
            messagebox.showerror(APP_TITLE, "Type a song or playlist name to search.")
            return
        include_songs = bool(self.dl_search_songs.get())
        include_playlists = bool(self.dl_search_playlists.get())
        if not include_songs and not include_playlists:
            messagebox.showerror(APP_TITLE, "Enable Songs and/or Playlists to search.")
            return

        self._cancel = False
        self._set_busy(True)
        self._append_log("--- Download: YouTube search ---")
        self.dl_status.set(f"Searching YouTube for “{query}”…")
        self._ui_progress("search", None, f"Searching YouTube for “{query}”…")

        def work() -> None:
            try:
                results = download_core.search_youtube(
                    query,
                    limit=8,
                    include_songs=include_songs,
                    include_playlists=include_playlists,
                    log=self._ui_log,
                    progress=self._ui_progress,
                )

                def apply() -> None:
                    self._populate_search_results(results)
                    self.dl_status.set(
                        f"{len(results)} search result(s) — click one, then Fetch titles."
                    )
                    self._ui_progress("search", 1.0, f"Found {len(results)} result(s)")
                    self._set_busy(False)

                self.after(0, apply)
            except Exception as e:  # noqa: BLE001
                self._ui_log(f"ERROR: {e}")

                def fail() -> None:
                    self.dl_status.set("Search failed — see log.")
                    self._set_busy(False)

                self.after(0, fail)

        threading.Thread(target=work, daemon=True).start()

    def _start_genius_search(self) -> None:
        if self._busy:
            messagebox.showwarning(APP_TITLE, "A job is already running.")
            return
        query = self.dl_search.get().strip()
        if not query:
            messagebox.showerror(APP_TITLE, "Type an album or artist name to search Genius.")
            return

        self._cancel = False
        self._set_busy(True)
        self._append_log("--- Download: Genius album search ---")
        self.dl_status.set(f"Searching Genius for “{query}”…")
        self._ui_progress("genius", None, f"Searching Genius for “{query}”…")

        def work() -> None:
            try:
                hits = genius_core.search_albums(
                    query,
                    limit=8,
                    log=self._ui_log,
                    progress=self._ui_progress,
                )
                results = [
                    download_core.SearchResult(
                        kind="album",
                        title=h.full_title or f"{h.name} by {h.artist}",
                        url=h.url,
                        id=h.id,
                        uploader=h.artist,
                        channel=h.artist,
                    )
                    for h in hits
                ]

                def apply() -> None:
                    self._populate_search_results(results)
                    self.dl_status.set(
                        f"{len(results)} Genius album(s) — click one, then Fetch titles."
                    )
                    self._ui_progress("genius", 1.0, f"Found {len(results)} album(s)")
                    self._set_busy(False)

                self.after(0, apply)
            except Exception as e:  # noqa: BLE001
                self._ui_log(f"ERROR: {e}")

                def fail() -> None:
                    self.dl_status.set("Genius search failed — see log.")
                    self._set_busy(False)

                self.after(0, fail)

        threading.Thread(target=work, daemon=True).start()

    def _start_fetch_playlist(self) -> None:
        if self._busy:
            messagebox.showwarning(APP_TITLE, "A job is already running.")
            return
        url = self.dl_url.get().strip()
        if not url:
            messagebox.showerror(
                APP_TITLE,
                "Search and select a result, or paste a YouTube / Genius album URL first.",
            )
            return

        if genius_core.is_genius_url(url) and not genius_core.is_genius_album_url(url):
            messagebox.showerror(
                APP_TITLE,
                "That Genius link is not an album URL.\n"
                "Use https://genius.com/albums/Artist/Album-name",
            )
            return

        self._cancel = False
        self._set_busy(True)
        use_genius = genius_core.is_genius_album_url(url)
        if use_genius:
            self._append_log("--- Download: Genius album tracklist ---")
            self.dl_status.set("Fetching Genius album…")
            self._ui_progress("genius", None, "Fetching Genius album tracklist…")
        else:
            self._append_log("--- Download: fetch titles ---")
            self.dl_status.set("Fetching playlist…")
            self._ui_progress("fetch", None, "Fetching playlist titles…")

        def work() -> None:
            try:
                if use_genius:
                    album = genius_core.fetch_album(
                        url, log=self._ui_log, progress=self._ui_progress
                    )
                    title, entries = download_core.entries_from_genius_album(album)
                else:
                    title, entries = download_core.list_playlist(
                        url, log=self._ui_log, progress=self._ui_progress
                    )

                def apply() -> None:
                    self._playlist_title = title
                    self._populate_track_list(entries)
                    phase = "genius" if use_genius else "fetch"
                    self._ui_progress(
                        phase, 1.0, f"Loaded {len(entries)} track(s) — {title}"
                    )
                    self._set_busy(False)

                self.after(0, apply)
            except Exception as e:  # noqa: BLE001
                self._ui_log(f"ERROR: {e}")

                def fail() -> None:
                    self.dl_status.set("Fetch failed — see log.")
                    self._set_busy(False)

                self.after(0, fail)

        threading.Thread(target=work, daemon=True).start()

    def _prompt_organize_root(self) -> Path | None:
        """Ask for Artist/Album library root after a successful download."""
        if not messagebox.askyesno(
            APP_TITLE,
            "Organize downloads into Artist/Album folders?\n\n"
            "You'll pick a library root, then files land as:\n"
            "  Artist / Album / Song.mp3  (+ .lrc beside it)",
        ):
            return None
        initial = self.dl_out.get().strip() or str(Path.home() / "Music")
        chosen = filedialog.askdirectory(
            title="Library root for Artist/Album folders",
            initialdir=initial if Path(initial).is_dir() else str(Path.home()),
        )
        if not chosen:
            return None
        return Path(chosen)

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
        self._append_log("--- Download: MP3 + lyrics ---")
        self._last_out = Path(out)
        self.dl_status.set(f"Downloading {len(selected)} track(s)…")
        self._ui_progress("overall", 0.0, f"Starting download — {len(selected)} track(s)")
        playlist_title = self._playlist_title

        def work() -> None:
            try:
                to_download = list(selected)
                need_match = [e for e in to_download if download_core.needs_youtube_match(e)]
                if need_match:
                    self._ui_log(
                        f"Resolving {len(need_match)} Genius/other track(s) → YouTube…"
                    )
                    self._ui_progress(
                        "match",
                        0.0,
                        f"Matching {len(need_match)} track(s) on YouTube…",
                    )
                    to_download = download_core.resolve_youtube_for_entries(
                        to_download,
                        log=self._ui_log,
                        progress=self._ui_progress,
                        should_cancel=lambda: self._cancel,
                    )
                    unresolved = [
                        e for e in to_download if download_core.needs_youtube_match(e)
                    ]
                    if unresolved:
                        names = ", ".join(
                            (e.track_title or e.title) for e in unresolved[:5]
                        )
                        more = "" if len(unresolved) <= 5 else f" (+{len(unresolved) - 5} more)"
                        raise RuntimeError(
                            f"Could not match {len(unresolved)} track(s) on YouTube: "
                            f"{names}{more}"
                        )

                ok, fail, folder, tracks = download_core.download_entries(
                    to_download,
                    out,
                    playlist_title=playlist_title,
                    fetch_lyrics=True,
                    log=self._ui_log,
                    progress=self._ui_progress,
                    should_cancel=lambda: self._cancel,
                )

                def after_download() -> None:
                    self.dl_status.set(f"Saved {ok}, failed {fail} → {folder}")
                    final_folder = folder
                    if ok > 0 and tracks:
                        lib = self._prompt_organize_root()
                        if lib is not None:
                            self._append_log("--- Organize: Artist/Album ---")
                            self._ui_progress(
                                "organize", 0.0, "Organizing into Artist/Album…"
                            )
                            # Keep busy while organize runs on a worker
                            def org_work() -> None:
                                try:
                                    dest = download_core.organize_tracks(
                                        tracks,
                                        lib,
                                        log=self._ui_log,
                                        progress=self._ui_progress,
                                    )

                                    def org_done() -> None:
                                        nonlocal final_folder
                                        final_folder = dest
                                        self.dl_out.set(str(final_folder))
                                        self._last_out = final_folder
                                        self.dl_status.set(
                                            f"Organized {ok} track(s) → {final_folder}"
                                        )
                                        self._finish_download_handoff(
                                            ok, final_folder
                                        )

                                    self.after(0, org_done)
                                except Exception as e:  # noqa: BLE001
                                    self._ui_log(f"ERROR organizing: {e}")

                                    def org_fail() -> None:
                                        messagebox.showerror(
                                            APP_TITLE,
                                            f"Could not organize into Artist/Album:\n{e}",
                                        )
                                        self._finish_download_handoff(ok, final_folder)

                                    self.after(0, org_fail)

                            threading.Thread(target=org_work, daemon=True).start()
                            return
                        self._finish_download_handoff(ok, final_folder)
                        return
                    self._set_busy(False)

                self.after(0, after_download)
            except Exception as e:  # noqa: BLE001
                self._ui_log(f"ERROR: {e}")

                def fail_ui() -> None:
                    self.dl_status.set("Download failed — see log.")
                    self._set_busy(False)

                self.after(0, fail_ui)

        threading.Thread(target=work, daemon=True).start()

    def _finish_download_handoff(self, ok: int, final_folder: Path) -> None:
        self._ui_progress("overall", 1.0, f"Ready — {ok} track(s) in {final_folder.name}")
        self._set_busy(False)
        if ok <= 0:
            return
        if messagebox.askyesno(
            APP_TITLE,
            f"Downloaded {ok} MP3(s) with lyrics where matched.\n\n"
            f"Folder:\n{final_folder}\n\n"
            "Send this folder to the Convert tab?",
        ):
            self.dl_out.set(str(final_folder))
            self._ui_progress("overall", 1.0, "Handed off → Convert tab")
            self._handoff_to_convert()

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
        self._ui_progress("convert", 0.0, "Starting convert…")

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
                    progress=self._ui_progress,
                    should_cancel=lambda: self._cancel,
                )
            except Exception as e:  # noqa: BLE001
                self._ui_log(f"ERROR: {e}")
            finally:
                self.after(0, lambda: self._set_busy(False))

        threading.Thread(target=work, daemon=True).start()

    def _start_art_convert(self) -> None:
        if self._busy:
            messagebox.showwarning(APP_TITLE, "A job is already running.")
            return
        raw = self.art_input.get().strip()
        if not raw:
            messagebox.showerror(
                APP_TITLE,
                "Pick a PNG/JPG (or several), an album folder, or a library root first.",
            )
            return
        inputs = [p for p in raw.split("|") if p]
        for p in inputs:
            if not Path(p).exists():
                messagebox.showerror(APP_TITLE, f"Path not found:\n{p}")
                return

        self._cancel = False
        self._set_busy(True)
        self._append_log("--- Album art → cover.nfp ---")
        first = Path(inputs[0])
        self._last_out = first if first.is_dir() else first.parent
        self._ui_progress("art", 0.0, "Converting cover art…")

        overwrite = self.art_overwrite.get()

        def work() -> None:
            try:
                summary = nfp_core.batch_write_cover_nfp(
                    inputs,
                    size=nfp_core.DEFAULT_NFP_SIZE,
                    overwrite=overwrite,
                    log=self._ui_log,
                )
                done = summary.get("done", 0)
                self._ui_progress(
                    "art",
                    1.0,
                    f"Cover art done — wrote {done}, skipped {summary.get('skipped', 0)}",
                )
                if done and summary.get("paths"):
                    last = Path(summary["paths"][-1])
                    self.after(0, lambda: setattr(self, "_last_out", last.parent))
            except Exception as e:  # noqa: BLE001
                self._ui_log(f"ERROR: {e}")
            finally:
                self.after(0, lambda: self._set_busy(False))

        threading.Thread(target=work, daemon=True).start()

    def _start_video_convert(self) -> None:
        if self._busy:
            messagebox.showwarning(APP_TITLE, "A job is already running.")
            return
        raw = self.vid_input.get().strip()
        if not raw:
            messagebox.showerror(APP_TITLE, "Pick an MP4/MKV (or folder) first.")
            return
        out = self.vid_out.get().strip()
        if not out:
            messagebox.showerror(APP_TITLE, "Pick an output Artist/Album folder.")
            return
        inputs = [p for p in raw.split("|") if p]
        for p in inputs:
            if not Path(p).exists():
                messagebox.showerror(APP_TITLE, f"Path not found:\n{p}")
                return
        try:
            w_s, h_s = self.vid_cells.get().strip().lower().split("x", 1)
            cells_w, cells_h = int(w_s), int(h_s)
            fps = float(self.vid_fps.get().strip() or video_core.DEFAULT_FPS)
        except ValueError:
            messagebox.showerror(APP_TITLE, "Cells must look like 160x45 and FPS must be a number.")
            return

        self._cancel = False
        self._set_busy(True)
        self._append_log("--- Music video → .cvid + .dfpwm ---")
        self._last_out = Path(out)
        self._ui_progress("video", 0.0, "Starting video convert…")

        def work() -> None:
            try:
                video_core.run_video_convert(
                    inputs,
                    out,
                    cells_w=cells_w,
                    cells_h=cells_h,
                    fps=fps,
                    overwrite=self.vid_overwrite.get(),
                    dry_run=self.vid_dry.get(),
                    log=self._ui_log,
                    progress=self._ui_progress,
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
        self._ui_progress("lyrics_batch", 0.0, "Starting lyrics fetch…")

        def work() -> None:
            try:
                lyrics_core.run_fetch(
                    [root],
                    pack_dir=pack,
                    delay=delay,
                    dry_run=self.lyr_dry.get(),
                    log=self._ui_log,
                    progress=self._ui_progress,
                    should_cancel=lambda: self._cancel,
                )
            except Exception as e:  # noqa: BLE001
                self._ui_log(f"ERROR: {e}")
            finally:
                self.after(0, lambda: self._set_busy(False))

        threading.Thread(target=work, daemon=True).start()

    # -------------------------------------------------------------- updates
    def _start_update_check(self) -> None:
        def work() -> None:
            try:
                info = update_check.check_for_update(
                    app_dir=APP_DIR,
                    log=None,  # keep quiet unless we prompt
                )
            except Exception:  # noqa: BLE001
                return
            if info is None:
                return
            self.after(0, lambda: self._offer_update(info))

        threading.Thread(target=work, daemon=True).start()

    def _ask_update_dialog(self, info: update_check.UpdateInfo) -> bool | None:
        """Return True=Update, False=Later, None=closed."""
        result: dict[str, bool | None] = {"value": None}
        dlg = tk.Toplevel(self)
        dlg.title(APP_TITLE)
        dlg.transient(self)
        # Solid dialog chrome (not transparent key) so the prompt stays readable
        dlg.configure(bg="#0a1620")
        dlg.resizable(False, False)
        apply_window_icon(dlg)
        frame = ttk.Frame(dlg, padding=16)
        frame.pack(fill="both", expand=True)
        ttk.Label(frame, text="Update available", style="Header.TLabel").pack(anchor="w")
        ttk.Label(
            frame,
            text=(
                f"Installed:  v{APP_VERSION}  (build {info.local_build})\n"
                f"Available:  {info.release_tag}  (build {info.remote_build})\n\n"
                "Update downloads Setup.exe and runs the installer.\n"
                "Later skips this build until a newer one appears."
            ),
            style="Glass.TLabel",
            justify="left",
        ).pack(anchor="w", pady=(10, 14))
        btns = ttk.Frame(frame)
        btns.pack(fill="x")

        def choose(update: bool) -> None:
            result["value"] = update
            dlg.destroy()

        ttk.Button(btns, text="Later", command=lambda: choose(False)).pack(side="right")
        ttk.Button(
            btns, text="Update", style="Accent.TButton", command=lambda: choose(True)
        ).pack(side="right", padx=(0, 8))
        dlg.protocol("WM_DELETE_WINDOW", dlg.destroy)
        dlg.grab_set()
        dlg.wait_window()
        return result["value"]

    def _offer_update(self, info: update_check.UpdateInfo) -> None:
        choice = self._ask_update_dialog(info)
        if choice is None:
            return
        if choice:
            self._append_log(
                f"--- Update: {info.local_build} → {info.remote_build} ---"
            )
            self.status.configure(text="Downloading update…")

            def work() -> None:
                ok = update_check.download_and_run_update(
                    info, log=self._ui_log
                )

                def done() -> None:
                    if ok:
                        self.status.configure(
                            text="Installer started — finish Setup, then reopen the app."
                        )
                        if messagebox.askyesno(
                            APP_TITLE,
                            "Setup.exe is running.\n\n"
                            "Close CC Music Tools now so the installer can replace files?",
                        ):
                            self.destroy()
                    else:
                        self.status.configure(
                            text="Update download failed — opened release page."
                        )

                self.after(0, done)

            threading.Thread(target=work, daemon=True).start()
        else:
            update_check.save_skipped_build(APP_DIR, info.remote_build)
            self.status.configure(text=f"Update skipped (build {info.remote_build}).")


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
