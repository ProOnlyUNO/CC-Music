@echo off
setlocal EnableExtensions
cd /d "%~dp0"

echo === CC Music Tools — build Setup.exe ===
where python >nul 2>&1
if errorlevel 1 (
  echo ERROR: Python not found on PATH.
  exit /b 1
)

if not exist dist\CC_Music_Tools.exe (
  echo App exe missing — building it first...
  call build_exe.bat
  if errorlevel 1 exit /b 1
)

python -c "import PyInstaller" 2>nul
if errorlevel 1 (
  echo Installing PyInstaller...
  python -m pip install --upgrade pyinstaller
  if errorlevel 1 exit /b 1
)

echo Staging payload for freestanding Setup.exe...
if exist _setup_payload rmdir /s /q _setup_payload
mkdir _setup_payload
mkdir _setup_payload\assets
copy /y dist\CC_Music_Tools.exe _setup_payload\CC_Music_Tools.exe >nul
copy /y README.md _setup_payload\README.md >nul
xcopy /e /i /y assets _setup_payload\assets >nul
if exist setup (
  xcopy /e /i /y setup _setup_payload\setup >nul
) else if exist ..\setup (
  xcopy /e /i /y ..\setup _setup_payload\setup >nul
) else (
  echo ERROR: setup\ folder missing — create it before building Setup.exe.
  exit /b 1
)

if exist build rmdir /s /q build
if exist Setup.spec del /f /q Setup.spec
if exist Setup.exe del /f /q Setup.exe

if not exist assets\app-icon.ico (
  echo Building assets\app-icon.ico from app-icon.png...
  python _make_icon.py
  if errorlevel 1 (
    echo ERROR: could not build app-icon.ico
    exit /b 1
  )
)

echo Running PyInstaller for Setup.exe (embeds payload + icon)...
python -m PyInstaller ^
  --noconfirm ^
  --clean ^
  --onefile ^
  --windowed ^
  --name Setup ^
  --icon "assets\app-icon.ico" ^
  --add-data "_setup_payload;payload" ^
  --add-data "assets\app-icon.ico;assets" ^
  --add-data "assets\app-icon.png;assets" ^
  setup_cc_music.py

if errorlevel 1 (
  echo ERROR: Setup PyInstaller failed.
  rmdir /s /q _setup_payload 2>nul
  exit /b 1
)

if exist dist\Setup.exe (
  copy /y dist\Setup.exe Setup.exe >nul
) else (
  echo ERROR: dist\Setup.exe not produced.
  exit /b 1
)

echo Cleaning build junk...
if exist build rmdir /s /q build
if exist Setup.spec del /f /q Setup.spec
if exist _setup_payload rmdir /s /q _setup_payload
if exist dist\Setup.exe del /f /q dist\Setup.exe
for %%F in (dist\*.toc dist\*.pkg dist\warn-*.txt dist\xref-*.html) do (
  if exist "%%F" del /f /q "%%F"
)

echo.
echo Done: %cd%\Setup.exe
echo Double-click Setup.exe → pick install folder → Install.
echo Default location: %%USERPROFILE%%\Documents\CC-Music-Tools
echo.
endlocal
exit /b 0
