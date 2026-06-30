-- ============================================================
-- GF Cortes — v6 (consertos itens 1, 6, 8)
-- 100% ADITIVO E SEGURO. NÃO apaga, NÃO altera dado, NÃO dropa nada.
-- Só cria FUNÇÕES NOVAS (que ainda não existem) e ADICIONA 1 coluna nova.
-- Pode rodar quantas vezes quiser (idempotente).
-- Cole no Supabase → SQL Editor → Run.
-- ============================================================

-- ---------- ITEM 1 — gravar o PRAZO do pedido ----------
-- Hoje o criar_pedido não recebe prazo, então ele "some". Esta função grava o prazo
-- (gerente ou risco — quem lança pedido). Não mexe em mais nada do pedido.
create or replace function public.pedido_set_prazo(p_token text, p_id uuid, p_prazo date)
returns json language plpgsql security definer set search_path=public as $$
declare u public.usuarios;
begin
  select * into u from public._user(p_token);
  if not found or u.papel not in ('gerente','risco') then
    return json_build_object('ok',false,'msg','Não autorizado');
  end if;
  update public.pedidos set prazo=p_prazo where id=p_id;
  if not found then return json_build_object('ok',false,'msg','Pedido não encontrado'); end if;
  return json_build_object('ok',true);
end; $$;
grant execute on function public.pedido_set_prazo(text,uuid,date) to anon;


-- ---------- ITEM 8 — editar dados do cliente (ex: adicionar telefone) ----------
-- Só GERENTE. Atualiza nome/cpf/telefone/endereço do cliente já cadastrado.
-- Mantém o nome em dia nos pedidos daquele cliente. Não apaga nada.
create or replace function public.editar_cliente(
  p_token text, p_id uuid, p_nome text, p_cpf_cnpj text, p_telefone text, p_endereco text)
returns json language plpgsql security definer set search_path=public as $$
begin
  if public._gerente_id(p_token) is null then
    return json_build_object('ok',false,'msg','Não autorizado');
  end if;
  if length(coalesce(trim(p_nome),''))<1 then
    return json_build_object('ok',false,'msg','Nome obrigatório');
  end if;
  update public.clientes set
    nome     = trim(p_nome),
    cpf_cnpj = nullif(trim(coalesce(p_cpf_cnpj,'')),''),
    telefone = nullif(trim(coalesce(p_telefone,'')),''),
    endereco = nullif(trim(coalesce(p_endereco,'')),'')
  where id = p_id;
  if not found then return json_build_object('ok',false,'msg','Cliente não encontrado'); end if;
  -- mantém o nome desnormalizado nos pedidos consistente
  update public.pedidos set cliente = trim(p_nome) where cliente_id = p_id;
  return json_build_object('ok',true);
exception
  when unique_violation then
    return json_build_object('ok',false,'msg','Já existe um cliente com esse nome');
end; $$;
grant execute on function public.editar_cliente(text,uuid,text,text,text,text) to anon;


-- ---------- ITEM 6 — quantidade de PEÇAS por pedido ----------
-- Adiciona a coluna 'pecas' (nullable, não mexe em nenhuma linha existente).
alter table public.pedidos add column if not exists pecas int;

-- Grava as peças informadas na estação NOTA (gerente ou nota).
-- O bipe da Nota continua igual; isto só registra o número de peças.
create or replace function public.set_pecas(p_token text, p_codigo text, p_pecas int)
returns json language plpgsql security definer set search_path=public as $$
declare u public.usuarios;
begin
  select * into u from public._user(p_token);
  if not found or u.papel not in ('gerente','nota') then
    return json_build_object('ok',false,'msg','Não autorizado');
  end if;
  if p_pecas is null or p_pecas < 0 then
    return json_build_object('ok',false,'msg','Quantidade de peças inválida');
  end if;
  update public.pedidos set pecas=p_pecas where codigo=trim(p_codigo);
  if not found then return json_build_object('ok',false,'msg','Pedido não encontrado'); end if;
  return json_build_object('ok',true);
end; $$;
grant execute on function public.set_pecas(text,text,int) to anon;

-- ============================================================
-- Conferência rápida (opcional) — só LEITURA, não muda nada:
--   select 'pedido_set_prazo' f, count(*) from pg_proc where proname='pedido_set_prazo'
--   union all select 'editar_cliente', count(*) from pg_proc where proname='editar_cliente'
--   union all select 'set_pecas', count(*) from pg_proc where proname='set_pecas';
-- ============================================================
