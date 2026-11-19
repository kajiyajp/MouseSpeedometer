@echo off
rem 作成日：2026-11-20
rem 目的　：MouseSpeedometer.ps1 をコンソール非表示で起動する
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0MouseSpeedometer.ps1"
