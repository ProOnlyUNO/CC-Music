#!/usr/bin/env python3
"""
CC Music Tools Setup — freestanding Windows installer (no paid license).

Copies CC_Music_Tools.exe + assets + README + setup/ (in-game script map)
into a user-chosen folder. Optional Start Menu and Desktop shortcuts.

After Install, tries to ensure ffmpeg + yt-dlp (Convert / YouTube Download)
via winget, pip, or choco when available — and reports success/fail clearly.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox, ttk

APP_NAME = "CC Music Tools"
APP_VERSION = "1.2.0"
EXE_NAME = "CC_Music_Tools.exe"
DEFAULT_DIR = Path.home() / "Documents" / "CC-Music-Tools"
PROGRAM_FILES = Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "CC-Music-Tools"


def _bundle_dir() -> Path:
    if getattr(sys, "frozen", False) and hasattr(sys, "_MEIPASS"):
        return Path(sys._MEIPASS)  # type: ignore[attr-defined]
    return Path(__file__).resolve().parent


def _setup_exe_dir() -> Path:
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent


def locate_payload() -> Path | None:
    """Find folder containing CC_Music_Tools.exe + assets (+ README)."""
    candidates: list[Path] = []
    bundled = _bundle_dir() / "payload"
    candidates.append(bundled)
    here = _setup_exe_dir()
    candidates.extend(
        [
            here,
            here / "dist",
            here.parent,
            Path(__file__).resolve().parent,
            Path(__file__).resolve().parent / "dist",
        ]
    )
    for root in candidates:
        exe = root / EXE_NAME
        assets = root / "assets"
        if exe.is_file() and assets.is_dir():
            return root
        # Package layout: dist\exe + sibling assets
        if root.name.lower() == "dist":
            parent = root.parent
            if exe.is_file() and (parent / "assets").is_dir():
                return parent
    return None


def create_shortcut(link_path: Path, target: Path, workdir: Path, description: str) -> None:
    link_path.parent.mkdir(parents=True, exist_ok=True)
    ps = f"""
$ws = New-Object -ComObject WScript.Shell
$s = $ws.CreateShortcut('{str(link_path).replace("'", "''")}')
$s.TargetPath = '{str(target).replace("'", "''")}'
$s.WorkingDirectory = '{str(workdir).replace("'", "''")}'
$s.Description = '{description.replace("'", "''")}'
$s.Save()
"""
    subprocess.run(
        ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", ps],
        check=True,
        capture_output=True,
        text=True,
    )


def _wh_which(name: str) -> str | None:
    return shutil.which(name) or shutil.which(f"{name}.exe")


def _run(cmd: list[str], timeout: int = 180) -> tuple[bool, str]:
    try:
        r = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            shell=False,
        )
        out = ((r.stdout or "") + ("\n" + r.stderr if r.stderr else "")).strip()
        return r.returncode == 0, out
    except (OSError, subprocess.TimeoutExpired) as e:
        return False, str(e)


def _ffmpeg_ok() -> tuple[bool, str]:
    exe = _wh_which("ffmpeg")
    if not exe:
        return False, "not found on PATH"
    ok, out = _run([exe, "-hide_banner", "-version"], timeout=30)
    first = (out.splitlines() or ["ffmpeg"])[0].strip()
    return ok, first or exe


def _ytdlp_ok() -> tuple[bool, str]:
    try:
        import yt_dlp  # type: ignore

        ver = getattr(getattr(yt_dlp, "version", None), "__version__", None) or "module"
        return True, f"yt-dlp {ver} (Python module)"
    except ImportError:
        pass
    exe = _wh_which("yt-dlp")
    if not exe:
        # python -m yt_dlp
        ok, out = _run([sys.executable, "-m", "yt_dlp", "--version"], timeout=45)
        if ok:
            ver = (out.splitlines() or ["ok"])[0].strip()
            return True, f"yt-dlp {ver} (python -m)"
        return False, "not found"
    ok, out = _run([exe, "--version"], timeout=30)
    ver = (out.splitlines() or [exe])[0].strip()
    return ok, f"yt-dlp {ver}" if ok else ver


def _try_winget_install(package_id: str) -> tuple[bool, str]:
    winget = _wh_which("winget")
    if not winget:
        return False, "winget not available"
    ok, out = _run(
        [
            winget,
            "install",
            "--id",
            package_id,
            "-e",
            "--accept-package-agreements",
            "--accept-source-agreements",
            "--disable-interactivity",
        ],
        timeout=300,
    )
    # winget exit 0 = installed / already installed
    if ok:
        return True, f"winget install {package_id}"
    # Some wingets return non-zero when already present — check again later
    return False, (out.splitlines() or [f"winget failed for {package_id}"])[-1][:200]


def _try_choco_install(package: str) -> tuple[bool, str]:
    choco = _wh_which("choco")
    if not choco:
        return False, "choco not available"
    ok, out = _run([choco, "install", package, "-y"], timeout=300)
    if ok:
        return True, f"choco install {package}"
    return False, (out.splitlines() or [f"choco failed for {package}"])[-1][:200]


def _try_pip_ytdlp() -> tuple[bool, str]:
    ok, out = _run(
        [sys.executable, "-m", "pip", "install", "--upgrade", "yt-dlp"],
        timeout=300,
    )
    if ok:
        return True, "pip install -U yt-dlp"
    # Frozen Setup.exe may ship a limited Python — try `py -m pip` launcher
    py = _wh_which("py")
    if py:
        ok2, out2 = _run([py, "-m", "pip", "install", "--upgrade", "yt-dlp"], timeout=300)
        if ok2:
            return True, "py -m pip install -U yt-dlp"
        out = out2 or out
    return False, (out.splitlines() or ["pip install yt-dlp failed"])[-1][:200]


def ensure_runtime_deps(status_cb=None) -> list[str]:
    """Install/ensure ffmpeg + yt-dlp. Returns human-readable result lines."""
    lines: list[str] = []

    def note(msg: str) -> None:
        lines.append(msg)
        if status_cb:
            status_cb(msg)

    # --- ffmpeg ---
    note("Checking ffmpeg…")
    ok, detail = _ffmpeg_ok()
    if ok:
        note(f"✓ ffmpeg: OK — {detail}")
    else:
        note("ffmpeg missing — trying winget / choco…")
        installed = False
        for label, fn in (
            ("winget Gyan.FFmpeg", lambda: _try_winget_install("Gyan.FFmpeg")),
            ("winget ffmpeg", lambda: _try_winget_install("ffmpeg")),
            ("choco ffmpeg", lambda: _try_choco_install("ffmpeg")),
        ):
            ok_i, msg_i = fn()
            if ok_i:
                note(f"  tried {label}: {msg_i}")
                installed = True
                break
            note(f"  tried {label}: {msg_i}")
        # Refresh PATH from typical install locations for this process
        extra = [
            Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "ffmpeg" / "bin",
            Path(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")) / "ffmpeg" / "bin",
            Path(os.environ.get("LOCALAPPDATA", "")) / "Microsoft" / "WinGet" / "Links",
        ]
        path_now = os.environ.get("PATH", "")
        for p in extra:
            if p.is_dir() and str(p) not in path_now:
                os.environ["PATH"] = str(p) + os.pathsep + path_now
                path_now = os.environ["PATH"]
        ok2, detail2 = _ffmpeg_ok()
        if ok2:
            note(f"✓ ffmpeg: installed — {detail2}")
        elif installed:
            note(
                "✗ ffmpeg: installer ran, but ffmpeg is not on PATH yet. "
                "Open a new terminal or reboot, then verify: ffmpeg -version"
            )
        else:
            note(
                "✗ ffmpeg: FAILED to auto-install. "
                "Install manually:  winget install ffmpeg"
            )

    # --- yt-dlp ---
    note("Checking yt-dlp…")
    ok, detail = _ytdlp_ok()
    if ok:
        note(f"✓ yt-dlp: OK — {detail}")
    else:
        note("yt-dlp missing — trying pip / winget / choco…")
        installed = False
        for label, fn in (
            ("pip", _try_pip_ytdlp),
            ("winget yt-dlp.yt-dlp", lambda: _try_winget_install("yt-dlp.yt-dlp")),
            ("choco yt-dlp", lambda: _try_choco_install("yt-dlp")),
        ):
            ok_i, msg_i = fn()
            if ok_i:
                note(f"  tried {label}: {msg_i}")
                installed = True
                break
            note(f"  tried {label}: {msg_i}")
        ok2, detail2 = _ytdlp_ok()
        if ok2:
            note(f"✓ yt-dlp: installed — {detail2}")
        elif installed:
            note(
                "✗ yt-dlp: installer ran, but yt-dlp is not visible yet. "
                "Try:  python -m pip install -U yt-dlp"
            )
        else:
            note(
                "✗ yt-dlp: FAILED to auto-install. "
                "Install manually:  python -m pip install -U yt-dlp"
            )

    return lines


def _icon_roots() -> list[Path]:
    roots = [_bundle_dir(), _setup_exe_dir(), Path(__file__).resolve().parent]
    payload = locate_payload()
    if payload is not None:
        roots.append(payload)
    return roots


def apply_window_icon(root: tk.Misc) -> None:
    """Set Setup window / taskbar icon from bundled assets."""
    ico: Path | None = None
    png: Path | None = None
    for root_dir in _icon_roots():
        cand_ico = root_dir / "assets" / "app-icon.ico"
        cand_png = root_dir / "assets" / "app-icon.png"
        if ico is None and cand_ico.is_file():
            ico = cand_ico
        if png is None and cand_png.is_file():
            png = cand_png
    if ico is not None:
        try:
            root.iconbitmap(default=str(ico))  # type: ignore[attr-defined]
        except tk.TclError:
            try:
                root.iconbitmap(str(ico))  # type: ignore[attr-defined]
            except tk.TclError:
                pass
    if png is not None:
        try:
            from PIL import Image, ImageTk

            img = Image.open(png).convert("RGBA")
            photos = [
                ImageTk.PhotoImage(img.resize((edge, edge), Image.Resampling.LANCZOS))
                for edge in (16, 32, 48, 64, 256)
            ]
            root.iconphoto(True, *photos)  # type: ignore[attr-defined]
            root._icon_photos = photos  # type: ignore[attr-defined]
        except Exception:  # noqa: BLE001
            pass


class SetupApp(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title(f"{APP_NAME} Setup  ·  v{APP_VERSION}")
        # Tall enough that Install/Cancel stay visible under DPI scaling.
        self.geometry("580x520")
        self.minsize(560, 500)
        self.resizable(True, True)
        apply_window_icon(self)

        self.payload = locate_payload()
        self.dest = tk.StringVar(value=str(DEFAULT_DIR))
        self.start_menu = tk.BooleanVar(value=True)
        self.desktop = tk.BooleanVar(value=True)
        self.launch_after = tk.BooleanVar(value=True)
        self.install_deps = tk.BooleanVar(value=True)

        self._build()
        if self.payload is None:
            messagebox.showerror(
                APP_NAME,
                "Could not find CC_Music_Tools.exe + assets.\n"
                "Keep Setup.exe next to the CC-Music-Tools package, or use a Setup build that embeds the payload.",
            )

    def _build(self) -> None:
        pad = ttk.Frame(self, padding=16)
        pad.pack(fill="both", expand=True)

        # Pin Install/Cancel at the bottom so they never clip off-screen.
        footer = ttk.Frame(pad)
        footer.pack(side="bottom", fill="x", pady=(12, 0))
        ttk.Label(footer, text="Developer: ProOnlyUNO", foreground="#555").pack(side="left")
        ttk.Button(footer, text="Cancel", command=self.destroy).pack(side="right")
        self.btn_install = ttk.Button(footer, text="Install", command=self._install)
        self.btn_install.pack(side="right", padx=(0, 8))
        if self.payload is None:
            self.btn_install.configure(state="disabled")

        self.status = ttk.Label(pad, text=self._status_text(), foreground="#333")
        self.status.pack(side="bottom", anchor="w", pady=(8, 0))

        body = ttk.Frame(pad)
        body.pack(side="top", fill="both", expand=True)

        ttk.Label(body, text=f"{APP_NAME} Setup", font=("Segoe UI Semibold", 16)).pack(anchor="w")
        ttk.Label(
            body,
            text="Choose where to install the app. Setup copies the exe, assets, README, and setup/ scripts.",
            wraplength=520,
        ).pack(anchor="w", pady=(4, 12))

        loc = ttk.LabelFrame(body, text="Install location", padding=10)
        loc.pack(fill="x")
        row = ttk.Frame(loc)
        row.pack(fill="x")
        ttk.Entry(row, textvariable=self.dest).pack(side="left", fill="x", expand=True)
        ttk.Button(row, text="Browse…", command=self._browse, width=10).pack(side="left", padx=(8, 0))

        presets = ttk.Frame(loc)
        presets.pack(fill="x", pady=(8, 0))
        ttk.Button(presets, text="Documents (default)", command=lambda: self.dest.set(str(DEFAULT_DIR))).pack(
            side="left"
        )
        ttk.Button(presets, text="Program Files", command=lambda: self.dest.set(str(PROGRAM_FILES))).pack(
            side="left", padx=(8, 0)
        )

        opts = ttk.LabelFrame(body, text="Options", padding=10)
        opts.pack(fill="x", pady=(12, 0))
        ttk.Checkbutton(opts, text="Start Menu shortcut", variable=self.start_menu).pack(anchor="w")
        ttk.Checkbutton(opts, text="Desktop shortcut", variable=self.desktop).pack(anchor="w")
        ttk.Checkbutton(
            opts,
            text="Install / ensure ffmpeg + yt-dlp (needed for Convert & YouTube Download)",
            variable=self.install_deps,
        ).pack(anchor="w", pady=(4, 0))
        ttk.Checkbutton(opts, text="Launch CC Music Tools when finished", variable=self.launch_after).pack(
            anchor="w", pady=(4, 0)
        )

    def _status_text(self) -> str:
        if self.payload is None:
            return "Installer files missing — re-download Setup.exe from the latest release."
        return "Ready to install."

    def _browse(self) -> None:
        initial = self.dest.get().strip() or str(DEFAULT_DIR)
        path = filedialog.askdirectory(
            title="Choose install folder",
            initialdir=initial if Path(initial).exists() else str(Path.home() / "Documents"),
        )
        if path:
            # If user picks a parent folder, still install into …\CC-Music-Tools when empty name isn't that
            chosen = Path(path)
            if chosen.name.lower() != "cc-music-tools":
                chosen = chosen / "CC-Music-Tools"
            self.dest.set(str(chosen))

    def _install(self) -> None:
        if self.payload is None:
            return
        dest = Path(self.dest.get().strip())
        if not dest.parts:
            messagebox.showerror(APP_NAME, "Pick an install folder.")
            return

        # Program Files often needs elevation
        try:
            dest.mkdir(parents=True, exist_ok=True)
            test = dest / ".write_test"
            test.write_text("ok", encoding="utf-8")
            test.unlink()
        except OSError as e:
            messagebox.showerror(
                APP_NAME,
                f"Cannot write to:\n{dest}\n\n{e}\n\n"
                "Try Documents, or re-run Setup as Administrator for Program Files.",
            )
            return

        self.btn_install.configure(state="disabled")
        self.status.configure(text="Installing…")
        self.update_idletasks()

        try:
            assets_src = self.payload / "assets"
            if not assets_src.is_dir():
                # dist-only payload case already normalized in locate_payload
                raise FileNotFoundError("assets folder missing in payload")

            exe_src = self.payload / EXE_NAME
            if not exe_src.is_file():
                # allow dist\CC_Music_Tools.exe when payload is package root
                alt = self.payload / "dist" / EXE_NAME
                if alt.is_file():
                    exe_src = alt
                else:
                    raise FileNotFoundError(EXE_NAME)

            exe_dst = dest / EXE_NAME
            shutil.copy2(exe_src, exe_dst)

            assets_dst = dest / "assets"
            if assets_dst.exists():
                shutil.rmtree(assets_dst)
            shutil.copytree(assets_src, assets_dst)

            readme_src = self.payload / "README.md"
            if readme_src.is_file():
                shutil.copy2(readme_src, dest / "README.md")

            setup_src = self.payload / "setup"
            if setup_src.is_dir():
                setup_dst = dest / "setup"
                if setup_dst.exists():
                    shutil.rmtree(setup_dst)
                shutil.copytree(setup_src, setup_dst)

            if self.start_menu.get():
                programs = Path(os.environ.get("APPDATA", "")) / "Microsoft" / "Windows" / "Start Menu" / "Programs"
                create_shortcut(
                    programs / f"{APP_NAME}.lnk",
                    exe_dst,
                    dest,
                    APP_NAME,
                )
            if self.desktop.get():
                desktop = Path.home() / "Desktop"
                create_shortcut(desktop / f"{APP_NAME}.lnk", exe_dst, dest, APP_NAME)

        except Exception as e:  # noqa: BLE001
            messagebox.showerror(APP_NAME, f"Install failed:\n{e}")
            self.btn_install.configure(state="normal")
            self.status.configure(text="Install failed.")
            return

        dep_lines: list[str] = []
        if self.install_deps.get():
            self.status.configure(text="Installing dependencies (ffmpeg + yt-dlp)…")
            self.update_idletasks()

            def _status(msg: str) -> None:
                # Keep UI alive during winget/pip
                short = msg if len(msg) < 90 else msg[:87] + "…"
                self.status.configure(text=short)
                self.update_idletasks()

            try:
                dep_lines = ensure_runtime_deps(status_cb=_status)
            except Exception as e:  # noqa: BLE001
                dep_lines = [f"✗ Dependency step crashed: {e}"]

        self.status.configure(text=f"Installed to {dest}")
        summary = f"Installed successfully to:\n{dest}\n"
        if dep_lines:
            summary += "\nDependencies:\n" + "\n".join(dep_lines)
            summary += (
                "\n\nConvert and YouTube Download need ffmpeg + yt-dlp. "
                "If anything failed above, install manually then restart the app."
            )
        else:
            summary += (
                "\nSkipped dependency install. For Convert / Download, install:\n"
                "  winget install ffmpeg\n"
                "  python -m pip install -U yt-dlp"
            )
        messagebox.showinfo(APP_NAME, summary)
        if self.launch_after.get():
            try:
                os.startfile(str(dest / EXE_NAME))  # type: ignore[attr-defined]
            except OSError:
                pass
        self.destroy()


def main() -> int:
    app = SetupApp()
    app.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
