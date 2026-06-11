@echo off
rem ---------------------------------------------------------------------------
rem Build the 64-bit plug-in DLL for the 64-bit edition of PL/SQL Developer.
rem Requires Free Pascal with the x86_64-win64 target (ppcx64.exe) and Python.
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

echo [2/2] Compiling PLSQLUnwrap64.dll ...
fpc -Px86_64 -O2 -Xs -Fusrc -Fisrc -FEdist -oPLSQLUnwrap64.dll src\PlsqlUnwrap.lpr
if errorlevel 1 (
  echo Build failed.
  exit /b 1
)

echo Done: dist\PLSQLUnwrap64.dll
endlocal
