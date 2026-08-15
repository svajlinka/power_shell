@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "& { . '%~dp0powershell-profile.ps1'; p }"
