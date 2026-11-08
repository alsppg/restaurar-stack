@echo off
REM Clique duplo neste arquivo para abrir a janela de selecao.
REM O -ExecutionPolicy Bypass vale so para este processo; nao altera a politica da maquina.
setlocal
set "AQUI=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%AQUI%Restaurar-Stack.ps1" %*
echo.
pause
