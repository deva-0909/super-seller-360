@echo off
setlocal enabledelayedexpansion
rem Super Seller 360 - demo data loader. Run from the super-seller-360 folder.
rem Part 2 (the 2x files) needs migration 0089 applied first.
rem Copies each demo file to the clipboard, one at a time, in the right order.
cd /d "%~dp0"
echo.
echo  WARNING: the first file (00_reset.sql) DELETES all existing orders, vouchers,
echo  stock movements and purchases. Users, roles, products and settings are kept.
echo.
set /p OK=Type YES to continue: 
if /i not "%OK%"=="YES" exit /b
for %%F in (00_reset.sql 01_masters.sql 02_opening.sql 10_*.sql 11_*.sql 12_*.sql 13_*.sql 14_*.sql 15_*.sql 16_*.sql 17_*.sql 18_*.sql 19_*.sql 90_finish.sql 20_setup.sql 21_*.sql 22_*.sql 23_*.sql 24_*.sql 25_*.sql 26_*.sql 27_*.sql 29_finish.sql) do (
  if exist "%%F" (
    type "%%F" | clip
    echo.
    echo  Copied %%F to the clipboard.
    echo  Open a NEW query in the Supabase SQL Editor, paste, Run, wait for Success.
    pause
  )
)
echo.
echo  All demo files loaded.
