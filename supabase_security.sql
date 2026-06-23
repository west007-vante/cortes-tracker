-- ============================================================
-- Painel de Cortes — ENDURECIMENTO de segurança (roda por último)
-- Fecha: escrita aberta, bipe sem token, escalonamento, perda de $ no cancel
-- ============================================================

-- 1) anon agora SÓ LÊ (painel + realtime). Escrita só via RPC com token.
drop policy if exists anon_all_pedidos on public.pedidos;
drop policy if exists anon_all_eventos on public.eventos;
create policy anon_read_pedidos on public.pedidos for select to anon using (true);
create policy anon_read_eventos on public.eventos for select to anon using (true);

-- helper: usuário ativo a partir do token
create or replace function public._user(p_token text)
returns public.usuarios language sql security definer set search_path=public as $$
  select * from public.usuarios where token=p_token and token_exp>now() and status='ativo' limit 1;
$$;

-- 2) BIPE exige token e só deixa bipar a PRÓPRIA estação (gerente pode qualquer)
drop function if exists public.bipe(text,text,text);
create or replace function public.bipe(p_token text, p_codigo text, p_stage text, p_operador text default null)
returns json language plpgsql security definer set search_path=public as $$
declare u public.usuarios; ped public.pedidos; op text;
begin
  select * into u from public.usuarios where token=p_token and token_exp>now() and status='ativo';
  if not found then return json_build_object('ok',false,'msg','Sessão inválida — entre de novo'); end if;
  if u.papel<>'gerente' and u.papel<>p_stage then
    return json_build_object('ok',false,'msg','Você só pode bipar na estação '||coalesce(u.papel,'?')); end if;
  select * into ped from public.pedidos where codigo=upper(trim(p_codigo)) for update;
  if not found then return json_build_object('ok',false,'msg','Código não encontrado: '||p_codigo); end if;
  if p_stage='risco' then
    if ped.risco then return json_build_object('ok',false,'msg','Risco já foi bipado neste pedido ('||ped.cliente||') — bipe único'); end if;
    update public.pedidos set risco=true where id=ped.id;
  elsif p_stage='enfesto' then
    if not ped.risco then return json_build_object('ok',false,'msg','Fora de ordem: bipe Risco antes de Enfesto ('||ped.cliente||')'); end if;
    if ped.enfesto then return json_build_object('ok',false,'msg','Enfesto já foi bipado neste pedido ('||ped.cliente||') — bipe único'); end if;
    update public.pedidos set enfesto=true where id=ped.id;
  elsif p_stage='corte' then
    if not ped.enfesto then return json_build_object('ok',false,'msg','Fora de ordem: bipe Enfesto antes de Corte ('||ped.cliente||')'); end if;
    if ped.corte then return json_build_object('ok',false,'msg','Corte já foi bipado neste pedido ('||ped.cliente||') — bipe único'); end if;
    update public.pedidos set corte=true where id=ped.id;
  else return json_build_object('ok',false,'msg','Etapa inválida'); end if;
  op := coalesce(nullif(trim(coalesce(p_operador,'')),''), u.username);
  insert into public.eventos(pedido_id,codigo,stage,operador,station) values (ped.id,ped.codigo,p_stage,op,p_stage);
  return json_build_object('ok',true,'msg',ped.cliente||coalesce(' · '||nullif(ped.numero,''),''));
end; $$;
grant execute on function public.bipe(text,text,text,text) to anon;

-- 3) Criar pedido só via RPC (gerente/risco)
create or replace function public.criar_pedido(p_token text, p_cliente text, p_numero text, p_ref text, p_prazo date, p_obs text)
returns json language plpgsql security definer set search_path=public as $$
declare u public.usuarios; novo public.pedidos;
begin
  select * into u from public.usuarios where token=p_token and token_exp>now() and status='ativo';
  if not found or u.papel not in ('gerente','risco') then return json_build_object('ok',false,'msg','Não autorizado'); end if;
  if length(coalesce(trim(p_cliente),''))<1 then return json_build_object('ok',false,'msg','Cliente obrigatório'); end if;
  insert into public.pedidos(cliente,numero,ref,prazo,obs)
    values (trim(p_cliente), nullif(trim(coalesce(p_numero,'')),''), nullif(trim(coalesce(p_ref,'')),''), p_prazo, nullif(trim(coalesce(p_obs,'')),''))
    returning * into novo;
  return json_build_object('ok',true,'pedido',row_to_json(novo));
end; $$;
grant execute on function public.criar_pedido(text,text,text,text,date,text) to anon;

-- 4) Toggle nota/pagamento/retirada só via RPC (gerente/risco) + guarda de sequência
create or replace function public.set_flag(p_token text, p_id uuid, p_field text, p_value boolean)
returns json language plpgsql security definer set search_path=public as $$
declare u public.usuarios; ped public.pedidos;
begin
  select * into u from public.usuarios where token=p_token and token_exp>now() and status='ativo';
  if not found or u.papel not in ('gerente','risco') then return json_build_object('ok',false,'msg','Não autorizado'); end if;
  if p_field not in ('nota','pagamento','retirada') then return json_build_object('ok',false,'msg','Campo inválido'); end if;
  select * into ped from public.pedidos where id=p_id;
  if not found then return json_build_object('ok',false,'msg','Pedido não encontrado'); end if;
  if p_value and p_field in ('nota','retirada') and not ped.corte then
    return json_build_object('ok',false,'msg','Só depois do corte finalizado'); end if;
  execute format('update public.pedidos set %I=$1 where id=$2', p_field) using p_value, p_id;
  return json_build_object('ok',true);
end; $$;
grant execute on function public.set_flag(text,uuid,text,boolean) to anon;

-- 5) gerente_atribuir NÃO promove a gerente e não mexe em outro gerente
create or replace function public.gerente_atribuir(p_token text, p_user_id uuid, p_papel text, p_status text default 'ativo')
returns json language plpgsql security definer set search_path=public as $$
begin
  if _gerente_id(p_token) is null then return json_build_object('ok',false,'msg','Não autorizado'); end if;
  if p_papel is not null and p_papel not in ('risco','enfesto','corte') then
    return json_build_object('ok',false,'msg','Papel inválido (gerente não é atribuível)'); end if;
  update public.usuarios set papel=p_papel, status=coalesce(p_status,'ativo'), token=null
    where id=p_user_id and papel is distinct from 'gerente';
  return json_build_object('ok',true);
end; $$;

-- 6) cancelar_bipe PRESERVA pagamento (não some dinheiro); reseta produção + nota + retirada
create or replace function public.cancelar_bipe(p_token text, p_id uuid, p_stage text)
returns json language plpgsql security definer set search_path=public as $$
declare stages text[] := array['risco','enfesto','corte']; idx int; i int;
begin
  if _gerente_id(p_token) is null then return json_build_object('ok',false,'msg','Não autorizado'); end if;
  idx := array_position(stages,p_stage);
  if idx is null then return json_build_object('ok',false,'msg','Etapa inválida'); end if;
  for i in idx..array_length(stages,1) loop
    execute format('update public.pedidos set %I=false where id=$1', stages[i]) using p_id;
    delete from public.eventos where pedido_id=p_id and stage=stages[i];
  end loop;
  update public.pedidos set nota=false, retirada=false where id=p_id; -- pagamento NÃO é apagado
  return json_build_object('ok',true);
end; $$;

-- 7) logout invalida o token no servidor
create or replace function public.logout(p_token text)
returns void language sql security definer set search_path=public as $$
  update public.usuarios set token=null where token=p_token;
$$;
grant execute on function public.logout(text) to anon;

-- 8) whoami: revalida sessão (pega papel/status ATUAIS do servidor)
create or replace function public.whoami(p_token text)
returns json language plpgsql security definer set search_path=public as $$
declare u public.usuarios;
begin
  select * into u from public.usuarios where token=p_token and token_exp>now();
  if not found then return json_build_object('ok',false); end if;
  return json_build_object('ok',true,'id',u.id,'username',u.username,'papel',u.papel,'status',u.status);
end; $$;
grant execute on function public.whoami(text) to anon;

-- 9) criar_gerente exige CÓDIGO DE SETUP (fecha o bootstrap público first-come)
drop function if exists public.criar_gerente(text,text);
create or replace function public.criar_gerente(p_username text, p_senha text, p_setup text default null)
returns json language plpgsql security definer set search_path=public,extensions as $$
begin
  if exists(select 1 from public.usuarios where papel='gerente') then return json_build_object('ok',false,'msg','Gerente já existe'); end if;
  if coalesce(p_setup,'') <> 'GFCORTES-SETUP-2026' then return json_build_object('ok',false,'msg','Código de setup inválido'); end if;
  if length(coalesce(trim(p_username),''))<3 or length(coalesce(p_senha,''))<4 then return json_build_object('ok',false,'msg','Usuário (3+) e senha (4+) obrigatórios'); end if;
  insert into public.usuarios(username,senha_hash,papel,status) values (lower(trim(p_username)), crypt(p_senha, gen_salt('bf')), 'gerente','ativo');
  return json_build_object('ok',true);
exception when unique_violation then return json_build_object('ok',false,'msg','Esse usuário já existe');
end; $$;
grant execute on function public.criar_gerente(text,text,text) to anon;
