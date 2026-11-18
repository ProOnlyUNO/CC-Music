#!/usr/bin/env python3
"""
CC Music Tools Setup — freestanding Windows installer (no paid license).

Copies CC_Music_Tools.exe + assets + README + setup/ (in-game script map)
into a user-chosen folder. Optional Start Menu and Desktop shortcuts.
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


class SetupApp(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title(f"{APP_NAME} Setup")
        self.geometry("560x360")
        self.minsize(520, 340)
        self.resizable(False, False)

        self.payload = locate_payload()
        self.dest = tk.StringVar(value=str(DEFAULT_DIR))
        self.start_menu = tk.BooleanVar(value=True)
        self.desktop = tk.BooleanVar(value=True)
        self.launch_after = tk.BooleanVar(value=True)

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

        ttk.Label(pad, text=f"{APP_NAME} Setup", font=("Segoe UI Semibold", 16)).pack(anchor="w")
        ttk.Label(
            pad,
            text="Choose where to install the app. Setup copies the exe, assets, and README.",
            wraplength=520,
        ).pack(anchor="w", pady=(4, 12))

        loc = ttk.LabelFrame(pad, text="Install location", padding=10)
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

        opts = ttk.LabelFrame(pad, text="Shortcuts", padding=10)
        opts.pack(fill="x", pady=(12, 0))
        ttk.Checkbutton(opts, text="Start Menu shortcut", variable=self.start_menu).pack(anchor="w")
        ttk.Checkbutton(opts, text="Desktop shortcut", variable=self.desktop).pack(anchor="w")
        ttk.Checkbutton(opts, text="Launch CC Music Tools when finished", variable=self.launch_after).pack(
            anchor="w", pady=(4, 0)
        )

        self.status = ttk.Label(pad, text=self._status_text(), foreground="#333")
        self.status.pack(anchor="w", pady=(12, 0))

        actions = ttk.Frame(pad)
        actions.pack(fill="x", pady=(16, 0))
        ttk.Button(actions, text="Cancel", command=self.destroy).pack(side="right")
        self.btn_install = ttk.Button(actions, text="Install", command=self._install)
        self.btn_install.pack(side="right", padx=(0, 8))
        if self.payload is None:
            self.btn_install.configure(state="disabled")

    def _status_text(self) -> str:
        if self.payload is None:
            return "Payload missing."
        return f"Payload: {self.payload}"

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

        self.status.configure(text=f"Installed to {dest}")
        messagebox.showinfo(APP_NAME, f"Installed successfully to:\n{dest}")
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
