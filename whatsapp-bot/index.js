// GF Cortes — bot de aviso no WhatsApp (Baileys).
// Quando a Nota é bipada no sistema, o gatilho do banco cria uma notificação 'pendente'.
// Este bot, rodando no computador da GF Cortes, lê as pendentes e envia pelo WhatsApp.
require('dotenv').config();
const { default: makeWASocket, useMultiFileAuthState, DisconnectReason } = require('@whiskeysockets/baileys');
const { createClient } = require('@supabase/supabase-js');
const qrcode = require('qrcode-terminal');
const pino = require('pino');

const SB_URL = process.env.SB_URL || 'https://ujvwpmgakthvifoynppf.supabase.co';
const SB_SECRET = process.env.SB_SECRET;
if (!SB_SECRET) { console.error('\n>> Faltou o SB_SECRET no arquivo .env (a chave secreta do Supabase). Veja o README.\n'); process.exit(1); }

const sb = createClient(SB_URL, SB_SECRET, { auth: { persistSession: false } });
const log = pino({ level: 'silent' });
let sock = null, conectado = false;

async function start() {
  const { state, saveCreds } = await useMultiFileAuthState('auth_gfcortes');
  sock = makeWASocket({ auth: state, logger: log, browser: ['GF Cortes', 'Chrome', '1.0'] });
  sock.ev.on('creds.update', saveCreds);
  sock.ev.on('connection.update', (u) => {
    const { connection, lastDisconnect, qr } = u;
    if (qr) { console.log('\n>> Escaneie o QR abaixo com o WhatsApp da GF Cortes (número 16 97400-2692):\n'); qrcode.generate(qr, { small: true }); }
    if (connection === 'open') { conectado = true; console.log('\nWhatsApp conectado. O bot está rodando — pode deixar essa janela aberta.\n'); }
    if (connection === 'close') {
      conectado = false;
      const code = lastDisconnect && lastDisconnect.error && lastDisconnect.error.output && lastDisconnect.error.output.statusCode;
      if (code === DisconnectReason.loggedOut) { console.log('Sessão encerrada. Apague a pasta "auth_gfcortes" e rode de novo pra reconectar.'); }
      else { console.log('Conexão caiu, reconectando...'); start(); }
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
  if (!conectado || !sock) return;
  let data, error;
  try { ({ data, error } = await sb.from('notificacoes').select('*').eq('status', 'pendente').order('created_at').limit(10)); }
  catch (e) { console.error('Erro lendo o banco:', e.message); return; }
  if (error) { console.error('Erro lendo o banco:', error.message); return; }
  for (const n of (data || [])) {
    const num = numeroBR(n.telefone);
    if (!num) { await marcar(n, 'erro', 'Cliente sem telefone'); continue; }
    try {
      const res = await sock.onWhatsApp(num);
      if (!(res && res[0] && res[0].exists)) {
        await marcar(n, 'erro', 'Esse número não tem WhatsApp (' + num + ')');
        continue;
      }
      await sock.sendMessage(res[0].jid, { text: n.mensagem });
      await sb.from('notificacoes').update({ status: 'enviado', sent_at: new Date().toISOString(), erro: null }).eq('id', n.id);
      console.log('Enviado para', n.cliente, '(' + num + ')');
    } catch (e) {
      const t = (n.tentativas || 0) + 1;
      await sb.from('notificacoes').update({ status: t >= 4 ? 'erro' : 'pendente', erro: String(e && e.message || e), tentativas: t }).eq('id', n.id);
      console.error('Falha ao enviar para', n.cliente, '-', e && e.message);
    }
  }
}
async function marcar(n, status, erro) {
  await sb.from('notificacoes').update({ status, erro, tentativas: (n.tentativas || 0) + 1 }).eq('id', n.id);
  console.log(n.cliente, '->', status, '(' + erro + ')');
}

start();
setInterval(processarPendentes, 8000);
console.log('Bot GF Cortes iniciando... aguarde o QR (primeira vez) ou a conexão.');
