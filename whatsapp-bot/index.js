// GF Cortes — bot de aviso no WhatsApp (Baileys).
// Quando a Nota é bipada no sistema, o gatilho do banco cria uma notificação 'pendente'.
// Este bot, rodando no computador da GF Cortes, lê as pendentes e envia pelo WhatsApp.
//
// Anti-duplicação: cada notificação é "reservada" (status pendente -> enviando) de forma
// atômica antes do envio. Assim, nem ticks concorrentes nem um crash reenviam a mesma mensagem.
require('dotenv').config();
const { default: makeWASocket, useMultiFileAuthState, DisconnectReason, fetchLatestBaileysVersion } = require('@whiskeysockets/baileys');
const { createClient } = require('@supabase/supabase-js');
const qrcode = require('qrcode-terminal');
const pino = require('pino');

const SB_URL = process.env.SB_URL || 'https://ujvwpmgakthvifoynppf.supabase.co';
const SB_SECRET = process.env.SB_SECRET;
if (!SB_SECRET) { console.error('\n>> Faltou o SB_SECRET no arquivo .env (a chave secreta do Supabase). Veja o README.\n'); process.exit(1); }

const sb = createClient(SB_URL, SB_SECRET, { auth: { persistSession: false } });
const log = pino({ level: 'silent' });
let sock = null, conectado = false, processando = false, reconectando = false;

async function start() {
  const { state, saveCreds } = await useMultiFileAuthState('auth_gfcortes');
  let version;
  try { version = (await fetchLatestBaileysVersion()).version; console.log('  Usando versao do WhatsApp:', (version || []).join('.')); }
  catch (e) { console.log('  (nao consegui buscar a versao atual do WhatsApp - pode ser bloqueio de rede/firewall):', e && e.message); }
  sock = makeWASocket({ version, auth: state, logger: log, markOnlineOnConnect: false, syncFullHistory: false, browser: ['GF Cortes', 'Chrome', '1.0'] });
  sock.ev.on('creds.update', saveCreds);
  sock.ev.on('connection.update', (u) => {
    const { connection, lastDisconnect, qr } = u;
    if (qr) { console.log('\n>> Escaneie o QR abaixo com o WhatsApp da GF Cortes (numero 16 97400-2692):\n'); qrcode.generate(qr, { small: true }); }
    if (connection === 'open') { conectado = true; console.log('\nWhatsApp conectado. O bot esta rodando - DEIXE esta janela aberta.\n'); recuperarPendentes(); }
    if (connection === 'close') {
      conectado = false;
      const err = lastDisconnect && lastDisconnect.error;
      const code = err && err.output && err.output.statusCode;
      console.log('  > Conexao fechou. Codigo:', code, '| Detalhe:', (err && err.message) || String(err || ''));
      if (code === DisconnectReason.loggedOut) { console.log('Sessao encerrada. Apague a pasta "auth_gfcortes" e rode de novo pra reconectar.'); return; }
      if (reconectando) return;
      reconectando = true;
      console.log('  Reconectando em 5s...');
      setTimeout(() => { reconectando = false; start().catch(e => console.error('reconexao falhou:', e && e.message)); }, 5000);
    }
  });
}

function numeroBR(raw) {
  let n = String(raw || '').replace(/\D/g, '');
  if (!n) return null;
  if (!n.startsWith('55')) n = '55' + n;
  return n;
}

async function processarPendentes() {
  if (processando || !conectado || !sock) return;
  processando = true;
  try {
    const { data, error } = await sb.from('notificacoes').select('*').eq('status', 'pendente').order('created_at').limit(10);
    if (error) { console.error('Erro lendo o banco:', error.message); return; }
    for (const n of (data || [])) {
      if (!conectado) break; // conexao caiu no meio do lote; o resto continua pendente
      // RESERVA atomica: so quem conseguir mudar pendente->enviando processa esta linha.
      const { data: claimed, error: cErr } = await sb.from('notificacoes')
        .update({ status: 'enviando' }).eq('id', n.id).eq('status', 'pendente').select();
      if (cErr) { console.error('claim erro:', cErr.message); continue; }
      if (!claimed || !claimed.length) continue; // outra rodada/instancia ja pegou

      const num = numeroBR(n.telefone);
      if (!num) { await sb.from('notificacoes').update({ status: 'erro', erro: 'Cliente sem telefone' }).eq('id', n.id); continue; }
      try {
        const res = await sock.onWhatsApp(num);
        if (!(res && res[0] && res[0].exists)) {
          await sb.from('notificacoes').update({ status: 'erro', erro: 'Esse numero nao tem WhatsApp (' + num + ')' }).eq('id', n.id);
          console.log(n.cliente, '-> erro (numero sem WhatsApp)');
          continue;
        }
        await sock.sendMessage(res[0].jid, { text: n.mensagem });
        await sb.from('notificacoes').update({ status: 'enviado', sent_at: new Date().toISOString(), erro: null }).eq('id', n.id);
        console.log('Enviado para', n.cliente, '(' + num + ')');
      } catch (e) {
        const msg = String(e && e.message || e);
        const ehConexao = !conectado || /clos|connection|timed|timeout|lost|socket/i.test(msg);
        // Erro de CONEXAO = a mensagem NAO saiu -> volta pra pendente (reenvia depois, sem duplicar).
        // Outro erro = marca 'erro' (nao arrisca duplicar).
        await sb.from('notificacoes').update({ status: ehConexao ? 'pendente' : 'erro', erro: msg, tentativas: (n.tentativas || 0) + 1 }).eq('id', n.id);
        if (ehConexao) { console.log('Conexao caiu no envio (vai tentar de novo):', n.cliente); break; }
        console.error('Falha ao enviar para', n.cliente, '-', msg);
      }
    }
  } catch (e) {
    console.error('Erro no processamento:', e && e.message);
  } finally {
    processando = false;
  }
}

// Ao (re)conectar, recupera mensagens que ficaram presas por queda de conexao - elas nao chegaram a sair.
async function recuperarPendentes() {
  try {
    await sb.from('notificacoes').update({ status: 'pendente', erro: null }).eq('status', 'enviando');
    await sb.from('notificacoes').update({ status: 'pendente', erro: null }).eq('status', 'erro').ilike('erro', '%onnection%');
  } catch (e) { console.error('recuperar:', e && e.message); }
}

start().catch(e => console.error('start falhou:', e && e.message));
setInterval(processarPendentes, 8000);
console.log('Bot GF Cortes iniciando... aguarde o QR (primeira vez) ou a conexao.');
