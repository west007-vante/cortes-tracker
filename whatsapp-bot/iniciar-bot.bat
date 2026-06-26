@echo off
chcp 65001 >nul
title Bot WhatsApp - GF Cortes
cd /d "%~dp0"

where node >nul 2>nul
if errorlevel 1 (
  echo.
  echo  [!] Node.js nao encontrado. Instale em https://nodejs.org ^(versao LTS^), reinicie o PC e rode de novo.
  echo.
  pause
  exit /b
)

if not exist node_modules (
  echo  Instalando dependencias pela primeira vez... pode demorar 1-2 minutos.
  call npm install
  echo.
)

if not exist .env (
  copy .env.example .env >nul
  echo.
  echo  [!] Vou abrir o arquivo .env no Bloco de Notas.
  echo      Cole a CHAVE SECRETA do Supabase no lugar do texto "cole_aqui...", salve ^(Ctrl+S^) e feche.
  echo.
  pause
  notepad .env
)

echo.
echo  Iniciando o bot... na PRIMEIRA vez aparece um QR Code aqui na tela.
echo  No celular: WhatsApp do 16 97400-2692  ^>  Aparelhos conectados  ^>  Conectar um aparelho  ^>  escaneie o QR.
echo  Depois e so DEIXAR ESTA JANELA ABERTA.
echo.
node index.js
echo.
echo  O bot parou. Se deu erro, a mensagem esta logo acima.
pause
