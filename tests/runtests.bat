@echo off
rem ---------------------------------------------------------------------------
rem Compile and run the native core tests (mirror of tests/test_unwrap.py).
rem Requires Free Pascal (any target) and Python.
rem ---------------------------------------------------------------------------
setlocal
cd /d "%~dp0\.."

echo Regenerating includes ...
py -3 tools\gen_charmap.py || python tools\gen_charmap.py
if errorlevel 1 exit /b 1

if not exist tests\build mkdir tests\build

echo Compiling TestUnwrap ...
fpc -O2 -Fusrc -Fisrc -FEtests\build -otests\build\TestUnwrap.exe tests\TestUnwrap.lpr
if errorlevel 1 (
  echo Build failed.
  exit /b 1
)

echo.
tests\build\TestUnwrap.exe
endlocal
