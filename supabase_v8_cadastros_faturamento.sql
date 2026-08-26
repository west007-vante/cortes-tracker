-- ============================================================================
-- GF CORTES — v8 (parte 2): Cadastros de clientes + Faturamento
--
-- ⚠️ LEIA ANTES DE RODAR
-- Este script é 100% ADITIVO. Ele:
--   • NÃO apaga nenhuma linha (não tem DELETE, não tem TRUNCATE)
--   • NÃO altera nenhum dado existente (não tem UPDATE)
--   • NÃO derruba nenhuma função (não tem DROP)
--   • NÃO substitui nenhuma função que já existe
-- Só adiciona 2 colunas novas (nullable / com default) e 5 funções novas.
-- Rodar duas vezes por engano é inofensivo (tudo é "if not exists" / "or replace"
-- de coisas que só este script cria).
--
-- Onde rodar: Supabase → projeto "Estação Bipe GF" → SQL Editor → Run.
-- Conta: gfcortecompras@gmail.com
--
-- Por que nenhuma função existente é tocada: o RUNBOOK-C1 provou que o corpo VIVO
-- de algumas funções (criar_pedido, editar_pedido) diverge do que está no repo.
-- Recriar por cima do repo apagaria a versão viva. Então aqui só se ADICIONA.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1) COLUNAS NOVAS
-- ----------------------------------------------------------------------------

-- faturamento do pedido, em reais. numeric porque entra em soma/média no painel.
alter table public.pedidos  add column if not exists valor numeric(12,2);

-- soft-delete de cliente: "apagar" vira "arquivar" (reversível).
-- default false => todas as linhas que já existem continuam ativas.
alter table public.clientes add column if not exists arquivado boolean not null default false;


-- ----------------------------------------------------------------------------
-- 2) FUNÇÕES NOVAS
--
-- Padrão de autorização usado aqui: (select id from public._user(tok)) is null
-- Esse é o padrão SEGURO já usado pelo listar_clientes: pega o id como escalar
-- e compara com is null. NÃO usa "select * into u ... if not found", que é o
-- furo #C1 (para token inválido a linha vem toda NULL e o IF não barra).
-- ----------------------------------------------------------------------------

-- 2.1) cadastrar cliente avulso (hoje o cliente só nasce junto com um pedido)
create or replace function public.criar_cliente(
  p_token text, p_nome text, p_cpf text, p_telefone text, p_endereco text)
returns json language plpgsql security definer set search_path=public as $$
declare pap text; novo public.clientes; nome_limpo text;
begin
  select papel into pap from public._user(p_token);
  if pap is null or pap not in ('gerente','risco') then
    return json_build_object('ok',false,'msg','Não autorizado');
  end if;

  nome_limpo := btrim(coalesce(p_nome,''));
  if nome_limpo = '' then
    return json_build_object('ok',false,'msg','Informe o nome do cliente');
  end if;

  -- não duplica: se já existe um ativo com esse nome, devolve erro claro
  if exists (select 1 from public.clientes
             where lower(nome)=lower(nome_limpo) and not arquivado) then
    return json_build_object('ok',false,'msg','Já existe um cliente com esse nome');
  end if;

  insert into public.clientes (nome, cpf_cnpj, endereco, telefone)
  values (nome_limpo, nullif(btrim(coalesce(p_cpf,'')),''),
                      nullif(btrim(coalesce(p_endereco,'')),''),
                      nullif(btrim(coalesce(p_telefone,'')),''))
  returning * into novo;

  return json_build_object('ok',true,'cliente',
    json_build_object('id',novo.id,'nome',novo.nome,'cpf_cnpj',novo.cpf_cnpj,
                      'endereco',novo.endereco,'telefone',novo.telefone,'arquivado',false));
end; $$;
grant execute on function public.criar_cliente(text,text,text,text,text) to anon;


-- 2.2) arquivar cliente (NÃO apaga: só marca arquivado=true)
create or replace function public.arquivar_cliente(p_token text, p_id uuid)
returns json language plpgsql security definer set search_path=public as $$
declare abertos int;
begin
  if public._gerente_id(p_token) is null then
    return json_build_object('ok',false,'msg','Só o gerente pode arquivar');
  end if;

  if not exists (select 1 from public.clientes where id=p_id) then
    return json_build_object('ok',false,'msg','Cliente não encontrado');
  end if;

  -- trava de segurança: cliente com pedido em aberto não some da tela
  select count(*) into abertos from public.pedidos
   where cliente_id=p_id and retirada is not true;
  if abertos > 0 then
    return json_build_object('ok',false,
      'msg','Esse cliente tem '||abertos||' pedido(s) em aberto — finalize antes de arquivar.');
  end if;

  update public.clientes set arquivado=true where id=p_id;
  return json_build_object('ok',true);
end; $$;
grant execute on function public.arquivar_cliente(text,uuid) to anon;


-- 2.3) desarquivar
create or replace function public.restaurar_cliente(p_token text, p_id uuid)
returns json language plpgsql security definer set search_path=public as $$
begin
  if public._gerente_id(p_token) is null then
    return json_build_object('ok',false,'msg','Só o gerente pode restaurar');
  end if;
  update public.clientes set arquivado=false where id=p_id;
  if not found then return json_build_object('ok',false,'msg','Cliente não encontrado'); end if;
  return json_build_object('ok',true);
end; $$;
grant execute on function public.restaurar_cliente(text,uuid) to anon;


-- 2.4) listar clientes JÁ COM o campo arquivado
-- Função NOVA (nome novo de propósito): não encosta na listar_clientes que existe,
-- que segue funcionando igual para qualquer coisa que ainda a chame.
create or replace function public.listar_clientes_v8(p_token text)
returns json language plpgsql security definer set search_path=public as $$
begin
  if (select id from public._user(p_token)) is null then
    return json_build_object('ok',false,'msg','Não autorizado');
  end if;
  return json_build_object('ok',true,'clientes',(
    select coalesce(json_agg(json_build_object(
             'id',id,'nome',nome,'cpf_cnpj',cpf_cnpj,'endereco',endereco,
             'telefone',telefone,'arquivado',arquivado) order by nome),'[]'::json)
    from public.clientes));
end; $$;
grant execute on function public.listar_clientes_v8(text) to anon;


-- 2.5) gravar o valor faturado do pedido (espelho exato do set_pecas do v7)
create or replace function public.set_valor(p_token text, p_codigo text, p_valor numeric)
returns json language plpgsql security definer set search_path=public as $$
declare pap text;
begin
  select papel into pap from public._user(p_token);
  if pap is null or pap not in ('gerente','nota') then
    return json_build_object('ok',false,'msg','Não autorizado');
  end if;
  if p_valor is null or p_valor < 0 then
    return json_build_object('ok',false,'msg','Valor faturado inválido');
  end if;
  update public.pedidos set valor=p_valor where codigo=btrim(p_codigo);
  if not found then return json_build_object('ok',false,'msg','Pedido não encontrado'); end if;
  return json_build_object('ok',true);
end; $$;
grant execute on function public.set_valor(text,text,numeric) to anon;


-- ============================================================================
-- CONFERÊNCIA (roda junto, é só leitura — deve devolver tudo "true")
-- ============================================================================
select
  (select count(*) from information_schema.columns
     where table_schema='public' and table_name='pedidos'  and column_name='valor')     = 1 as coluna_valor_ok,
  (select count(*) from information_schema.columns
     where table_schema='public' and table_name='clientes' and column_name='arquivado') = 1 as coluna_arquivado_ok,
  (select count(*) from pg_proc where proname='criar_cliente')      = 1 as criar_cliente_ok,
  (select count(*) from pg_proc where proname='arquivar_cliente')   = 1 as arquivar_ok,
  (select count(*) from pg_proc where proname='restaurar_cliente')  = 1 as restaurar_ok,
  (select count(*) from pg_proc where proname='listar_clientes_v8') = 1 as listar_v8_ok,
  (select count(*) from pg_proc where proname='set_valor')          = 1 as set_valor_ok,
  (select count(*) from public.pedidos)  as total_pedidos_intacto,
  (select count(*) from public.clientes) as total_clientes_intacto;

-- ============================================================================
-- AINDA PENDENTE (de propósito, NÃO está neste script):
--
-- A trava "sem peças E sem valor não bipa a Nota" no SERVIDOR. Ela exigiria
-- recriar a função bipe(), e o corpo VIVO dela pode divergir do repo — recriar
-- às cegas apagaria a versão que está rodando. Hoje a trava existe no frontend,
-- que resolve o uso normal pela tela.
--
-- Para fechar isso (e também o furo #C1 do set_flag/criar_pedido), rode este
-- SELECT e me mande o resultado — é só leitura, não muda nada:
--
--   select proname, pg_get_functiondef(oid)
--     from pg_proc
--    where proname in ('_user','bipe','set_flag','criar_pedido','editar_pedido');
-- ============================================================================
