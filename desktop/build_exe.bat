@echo off
setlocal EnableExtensions
cd /d "%~dp0"

echo === CC Music Tools — build exe ===
where python >nul 2>&1
if errorlevel 1 (
  echo ERROR: Python not found on PATH.
  exit /b 1
)

python -c "import PyInstaller" 2>nul
if errorlevel 1 (
  echo Installing PyInstaller...
  python -m pip install --upgrade pyinstaller
  if errorlevel 1 (
    echo ERROR: could not install PyInstaller.
    exit /b 1
  )
)

python -c "from PIL import Image, ImageTk" 2>nul
if errorlevel 1 (
  echo Installing Pillow...
  python -m pip install --upgrade pillow
  if errorlevel 1 (
    echo ERROR: could not install Pillow.
    exit /b 1
  )
)

if not exist assets\background.jpg if not exist assets\background.png (
  echo ERROR: assets\background.jpg ^(or .png^) missing.
  exit /b 1
)

echo Stopping running CC_Music_Tools if needed...
taskkill /F /IM CC_Music_Tools.exe >nul 2>&1

echo Cleaning previous build junk...
if exist build rmdir /s /q build
if exist dist\CC_Music_Tools.exe del /f /q dist\CC_Music_Tools.exe
if exist CC_Music_Tools.spec del /f /q CC_Music_Tools.spec

echo Running PyInstaller (one-file, windowed, with assets)...
python -m PyInstaller ^
  --noconfirm ^
  --clean ^
  --onefile ^
  --windowed ^
  --name CC_Music_Tools ^
  --add-data "assets;assets" ^
  --hidden-import convert_core ^
  --hidden-import lyrics_core ^
  --hidden-import PIL ^
  --hidden-import PIL.Image ^
  --hidden-import PIL.ImageTk ^
  --collect-submodules PIL ^
  cc_music_desktop.py

if errorlevel 1 (
  echo ERROR: PyInstaller failed.
  exit /b 1
)

echo Removing build junk (keep dist\CC_Music_Tools.exe only)...
if exist build rmdir /s /q build
if exist CC_Music_Tools.spec del /f /q CC_Music_Tools.spec
for %%F in (dist\*.toc dist\*.pkg dist\warn-*.txt dist\xref-*.html) do (
  if exist "%%F" del /f /q "%%F"
)

echo.
echo Done: %cd%\dist\CC_Music_Tools.exe
echo Double-click that exe to open the app.
echo Convert still needs ffmpeg 5.1+ on PATH:  winget install ffmpeg
echo.
endlocal
exit /b 0
