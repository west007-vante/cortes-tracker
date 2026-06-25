# Bot de WhatsApp — GF Cortes

Avisa o cliente automaticamente no WhatsApp quando a **Nota** do pedido é bipada.
Roda no **computador da GF Cortes** (precisa ficar ligado e com internet).

## Como funciona
1. No sistema, quando alguém bipa a **Nota**, o banco cria um aviso "pendente" com a mensagem pronta e o telefone do cliente.
2. Este bot lê os avisos pendentes a cada 8 segundos e envia pelo WhatsApp da GF Cortes.
3. Marca como "enviado" (ou "erro" se o número não tiver WhatsApp).

> Se o cliente **não tiver telefone cadastrado**, o aviso fica como "sem telefone" e **não** é enviado.

## Instalação (uma vez só)
1. Instale o **Node.js** (versão LTS) em https://nodejs.org
2. Copie esta pasta `whatsapp-bot` para o computador da GF Cortes.
3. Abra o terminal (Prompt de Comando / PowerShell no Windows) dentro desta pasta e rode:
   ```
   npm install
   ```
4. Crie o arquivo de configuração: copie `.env.example` para `.env` e cole a **chave secreta** do Supabase (a `sb_secret_...` que o Pyerri tem). Essa chave fica **só neste computador**.

## Rodar
```
npm start
```
- Na **primeira vez**, vai aparecer um **QR Code** no terminal. Abra o WhatsApp do número **16 97400-2692** → Aparelhos conectados → Conectar um aparelho → escaneie o QR.
- Depois de conectado, é só **deixar a janela aberta**. Ele envia sozinho.
- Se cair, ele reconecta. Se aparecer "Sessão encerrada", apague a pasta `auth_gfcortes` e rode `npm start` de novo.

## Deixar sempre ligado (recomendado)
- O bot só envia enquanto o computador está ligado, com internet e a janela aberta.
- Pra não esquecer, deixe o computador sem desligar/hibernar, ou rode com um gerenciador (ex.: `pm2`).
