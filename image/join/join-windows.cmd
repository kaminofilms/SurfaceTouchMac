@echo off
rem Joins the downloaded parts into one .img.xz and verifies SHA-256.
rem Put this file in the folder with all the .part-??? files and double-click it.
setlocal enabledelayedexpansion
cd /d "%~dp0"
set FIRST=
for %%f in (*.img.xz.part-aaa) do set FIRST=%%f
if "%FIRST%"=="" (echo No *.img.xz.part-aaa found & pause & exit /b 1)
set BASE=%FIRST:.part-aaa=%
echo Joining into %BASE% ...
copy /b "%BASE%.part-*" "%BASE%" >nul
echo Verifying...
for /f "tokens=1" %%h in (SHA256SUMS-xz.txt) do set WANT=%%h
for /f "skip=1 tokens=*" %%h in ('certutil -hashfile "%BASE%" SHA256 ^| findstr /v ":"') do (set GOT=%%h & goto :got)
:got
set GOT=%GOT: =%
if /i "%GOT%"=="%WANT%" (
  echo OK: %BASE% matches SHA256 %WANT%
  echo Now open Rufus and select this .img.xz file.
) else (
  echo MISMATCH: expected %WANT%
  echo got      %GOT%
  echo Re-download the parts.
)
pause
