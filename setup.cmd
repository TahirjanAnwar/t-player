@echo off
rem One-time setup for T-Player: makes .venv with Python 3.12, installs Qt for Python,
rem builds T-Player.exe and puts T-Player on the desktop and in the Start menu.
cd /d "%~dp0"
if not exist ".venv\Scripts\python.exe" (
  py -3.12 -m venv .venv
  if errorlevel 1 (
    echo Python 3.12 is needed: https://www.python.org/downloads/
    pause
    exit /b 1
  )
)
".venv\Scripts\python.exe" -m pip install --upgrade pip
".venv\Scripts\python.exe" -m pip install -r requirements.txt
if errorlevel 1 (
  echo Installing the packages failed - see the messages above.
  pause
  exit /b 1
)
"%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:winexe /optimize+ /win32icon:assets\t-player.ico /reference:System.Windows.Forms.dll /out:T-Player.exe launcher\TPlayerLauncher.cs
if errorlevel 1 (
  echo Building T-Player.exe failed - see the messages above.
  pause
  exit /b 1
)
rem Thumbnails for File Explorer (switched on by "tplayer.py --register"; they need FFmpeg: winget install Gyan.FFmpeg)
"%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:library /optimize+ /reference:System.Drawing.dll /out:TPlayerThumbnails.dll launcher\TPlayerThumbnails.cs
if errorlevel 1 (
  echo Building the thumbnail add-on failed - T-Player still works, but File Explorer won't show video frames.
)
set "TP_DIR=%~dp0"
powershell -NoProfile -Command "$dir = $env:TP_DIR; $shell = New-Object -ComObject WScript.Shell; foreach ($folder in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))) { $link = $shell.CreateShortcut((Join-Path $folder 'T-Player.lnk')); $link.TargetPath = (Join-Path $dir 'T-Player.exe'); $link.WorkingDirectory = $dir; $link.Description = 'T-Player video player'; $link.Save() }"
echo.
echo Setup finished. Start T-Player from the desktop or the Start menu.
echo.
choice /c YN /m "Open videos in T-Player with a double-click"
if errorlevel 2 goto end
".venv\Scripts\python.exe" tplayer.py --register
start "" ms-settings:defaultapps
echo In the Settings window: click "Video player" and choose T-Player.
:end
pause
