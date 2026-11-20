@echo off
setlocal
set "ARG=%~1"
if /I "%ARG%"=="list" goto :list
if /I "%ARG%"=="bind" goto :bind
if /I "%ARG%"=="unbind" goto :unbind
if /I "%ARG%"=="detach" goto :detach
if /I "%ARG%"=="--version" goto :version
goto :eof

:list
type "%~dp0list-output.txt"
exit /b 0

:bind
echo %* >> "%~dp0bind-log.txt"
echo bound %*
exit /b 0

:unbind
echo %* >> "%~dp0unbind-log.txt"
echo unbound %*
exit /b 0

:detach
echo %* >> "%~dp0unbind-log.txt"
echo detached %*
exit /b 0

:version
echo usbipd-win 4.3.0 (fake for tests)
exit /b 0
