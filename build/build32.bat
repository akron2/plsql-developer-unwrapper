@echo off
rem ---------------------------------------------------------------------------
rem Build the 32-bit plug-in DLL for the 32-bit edition of PL/SQL Developer.
rem Requires Free Pascal with the i386-win32 target (ppc386.exe) and Python.
rem ---------------------------------------------------------------------------
setlocal
cd /d "%~dp0\.."

echo [1/2] Regenerating CHARMAP / golden includes from app\unwrap.py ...
py -3 tools\gen_charmap.py || python tools\gen_charmap.py
if errorlevel 1 (
  echo Generator failed.
  exit /b 1
)

if not exist dist mkdir dist

echo [2/2] Compiling PLSQLUnwrap32.dll ...
fpc -Pi386 -O2 -Xs -Fusrc -Fisrc -FEdist -oPLSQLUnwrap32.dll src\PlsqlUnwrap.lpr
if errorlevel 1 (
  echo Build failed.
  exit /b 1
)

echo Done: dist\PLSQLUnwrap32.dll
endlocal
