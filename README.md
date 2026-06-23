# Painel de Cortes

Sistema interno de rastreio de produção de corte (confecção) por **bipe** de código de barras / QR.
Fluxo por pedido: **Risco → Enfesto → Corte** (sequência obrigatória, bipe único por etapa), espelhando a planilha do João.

## Stack
- Frontend: `index.html` (single-file, JsBarcode + QRCode + Supabase JS).
- Backend: Supabase (Postgres + Realtime). Schema em `supabase_schema.sql`.
- Bipe atômico no servidor (função `bipe`) garante sequência + bipe único mesmo com vários aparelhos.

## Segurança
- O app usa **somente a publishable key** (pública por design, protegida por RLS).
- A **secret key NUNCA** entra no frontend nem no repositório.
- RLS atual: `anon` opera (ferramenta interna). Login real = próximo passo de endurecimento.

## Setup do banco
Rode `supabase_schema.sql` uma vez no SQL Editor do projeto Supabase.
