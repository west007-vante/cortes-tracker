-- ============================================================
-- GF Cortes — v7 (correção de segurança + base das peças)
-- 100% ADITIVO E SEGURO. Só RECRIA o corpo de 2 funções (CREATE OR REPLACE,
-- mesma assinatura) pra fechar um furo de autorização. NÃO apaga, NÃO altera dado.
-- Cole no Supabase → SQL Editor → Run.
-- ============================================================

-- Contexto do furo: o _user(token) devolve uma linha mesmo pra token inválido
-- (com papel NULL). O check antigo "not found or papel not in (...)" NÃO barra
-- quando papel é NULL (false OR NULL = não bloqueia). A correção é tratar papel NULL.

-- ITEM 1 — grava o prazo (gerente/risco). Agora barra token sem papel.
create or replace function public.pedido_set_prazo(p_token text, p_id uuid, p_prazo date)
returns json language plpgsql security definer set search_path=public as $$
declare u public.usuarios;
begin
  select * into u from public._user(p_token);
  if not found or u.papel is null or u.papel not in ('gerente','risco') then
    return json_build_object('ok',false,'msg','Não autorizado');
  end if;
  update public.pedidos set prazo=p_prazo where id=p_id;
  if not found then return json_build_object('ok',false,'msg','Pedido não encontrado'); end if;
  return json_build_object('ok',true);
end; $$;
grant execute on function public.pedido_set_prazo(text,uuid,date) to anon;

-- ITEM 6 — grava as peças cortadas (gerente/nota). Agora barra token sem papel.
create or replace function public.set_pecas(p_token text, p_codigo text, p_pecas int)
returns json language plpgsql security definer set search_path=public as $$
declare u public.usuarios;
begin
  select * into u from public._user(p_token);
  if not found or u.papel is null or u.papel not in ('gerente','nota') then
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
