-- ============================================================
-- Painel de Cortes — v5: sessão permanente, clientes, estação Nota, campos da folha
-- ============================================================

-- ---------- 1) SESSÕES PERMANENTES (multi-dispositivo, não expira) ----------
create table if not exists public.sessoes (
  token       text primary key,
  user_id     uuid not null references public.usuarios(id) on delete cascade,
  created_at  timestamptz not null default now()
);
alter table public.sessoes enable row level security; -- sem policy p/ anon

-- ---------- 2) papel 'nota' + eventos.stage 'nota' ----------
alter table public.usuarios drop constraint if exists usuarios_papel_check;
alter table public.usuarios add constraint usuarios_papel_check check (papel in ('gerente','risco','enfesto','corte','nota'));
alter table public.eventos drop constraint if exists eventos_stage_check;
alter table public.eventos add constraint eventos_stage_check check (stage in ('risco','enfesto','corte','nota'));

-- ---------- 3) CLIENTES + novos campos do pedido ----------
create table if not exists public.clientes (
  id          uuid primary key default gen_random_uuid(),
  nome        text not null,
  cpf_cnpj    text,
  endereco    text,
  telefone    text,
  created_at  timestamptz not null default now()
);
create unique index if not exists clientes_nome_uniq on public.clientes(lower(nome));
alter table public.clientes enable row level security;
create policy anon_read_clientes on public.clientes for select to anon using (true);

alter table public.pedidos add column if not exists cliente_id   uuid references public.clientes(id);
alter table public.pedidos add column if not exists material     text;
alter table public.pedidos add column if not exists qtd_material text;
alter table public.pedidos add column if not exists ref_molde    text;
alter table public.pedidos add column if not exists grade        text;

-- ---------- 4) AUTH via sessões (permanente) ----------
create or replace function public.login(p_username text, p_senha text)
returns json language plpgsql security definer set search_path=public,extensions as $$
declare u public.usuarios; tok text;
begin
  select * into u from public.usuarios where username=lower(trim(p_username));
  if not found or u.senha_hash <> crypt(p_senha, u.senha_hash) then
    return json_build_object('ok',false,'msg','Usuário ou senha incorretos'); end if;
  if u.status='bloqueado' then return json_build_object('ok',false,'msg','Acesso bloqueado pelo gerente'); end if;
  if u.status='pendente' or u.papel is null then
    return json_build_object('ok',false,'msg','Conta aguardando o gerente liberar sua estação'); end if;
  tok := gen_random_uuid()::text || gen_random_uuid()::text;
  insert into public.sessoes(token,user_id) values (tok,u.id);
  return json_build_object('ok',true,'id',u.id,'username',u.username,'papel',u.papel,'token',tok);
end; $$;
grant execute on function public.login(text,text) to anon;

create or replace function public._user(p_token text)
returns public.usuarios language sql security definer set search_path=public as $$
  select u.* from public.sessoes s join public.usuarios u on u.id=s.user_id
  where s.token=p_token and u.status='ativo' limit 1;
$$;

create or replace function public._gerente_id(p_token text)
returns uuid language sql security definer set search_path=public as $$
  select u.id from public.sessoes s join public.usuarios u on u.id=s.user_id
  where s.token=p_token and u.papel='gerente' and u.status='ativo' limit 1;
$$;

create or replace function public.whoami(p_token text)
returns json language plpgsql security definer set search_path=public as $$
declare u public.usuarios;
begin
  select * into u from public._user(p_token);
  if not found then return json_build_object('ok',false); end if;
  return json_build_object('ok',true,'id',u.id,'username',u.username,'papel',u.papel,'status',u.status);
end; $$;
grant execute on function public.whoami(text) to anon;

create or replace function public.logout(p_token text)
returns void language sql security definer set search_path=public as $$
  delete from public.sessoes where token=p_token;
$$;
grant execute on function public.logout(text) to anon;

-- ---------- 5) BIPE com estação NOTA (risco->enfesto->corte->nota) ----------
drop function if exists public.bipe(text,text,text,text);
create or replace function public.bipe(p_token text, p_codigo text, p_stage text, p_operador text default null)
returns json language plpgsql security definer set search_path=public as $$
declare u public.usuarios; ped public.pedidos; op text;
begin
  select * into u from public._user(p_token);
  if not found then return json_build_object('ok',false,'msg','Sessão inválida — entre de novo'); end if;
  if u.papel<>'gerente' and u.papel<>p_stage then
    return json_build_object('ok',false,'msg','Você só pode bipar na estação '||coalesce(u.papel,'?')); end if;
  select * into ped from public.pedidos where codigo=upper(trim(p_codigo)) for update;
  if not found then return json_build_object('ok',false,'msg','Código não encontrado: '||p_codigo); end if;
  if p_stage='risco' then
    if ped.risco then return json_build_object('ok',false,'msg','Risco já foi bipado ('||ped.cliente||') — bipe único'); end if;
    update public.pedidos set risco=true where id=ped.id;
  elsif p_stage='enfesto' then
    if not ped.risco then return json_build_object('ok',false,'msg','Fora de ordem: bipe Risco antes ('||ped.cliente||')'); end if;
    if ped.enfesto then return json_build_object('ok',false,'msg','Enfesto já foi bipado ('||ped.cliente||') — bipe único'); end if;
    update public.pedidos set enfesto=true where id=ped.id;
  elsif p_stage='corte' then
    if not ped.enfesto then return json_build_object('ok',false,'msg','Fora de ordem: bipe Enfesto antes ('||ped.cliente||')'); end if;
    if ped.corte then return json_build_object('ok',false,'msg','Corte já foi bipado ('||ped.cliente||') — bipe único'); end if;
    update public.pedidos set corte=true where id=ped.id;
  elsif p_stage='nota' then
    if not ped.corte then return json_build_object('ok',false,'msg','Fora de ordem: bipe Corte antes da Nota ('||ped.cliente||')'); end if;
    if ped.nota then return json_build_object('ok',false,'msg','Nota já foi bipada ('||ped.cliente||') — bipe único'); end if;
    update public.pedidos set nota=true where id=ped.id;
  else return json_build_object('ok',false,'msg','Etapa inválida'); end if;
  op := coalesce(nullif(trim(coalesce(p_operador,'')),''), u.username);
  insert into public.eventos(pedido_id,codigo,stage,operador,station) values (ped.id,ped.codigo,p_stage,op,p_stage);
  return json_build_object('ok',true,'msg',ped.cliente||coalesce(' · '||nullif(ped.numero,''),''));
end; $$;
grant execute on function public.bipe(text,text,text,text) to anon;

-- ---------- 6) CRIAR PEDIDO com cliente (novo ou existente) + campos da folha ----------
create or replace function public.criar_pedido(
  p_token text, p_cliente_id uuid default null, p_cliente_nome text default null,
  p_cpf text default null, p_endereco text default null, p_telefone text default null,
  p_numero text default null, p_material text default null, p_qtd_material text default null,
  p_ref_molde text default null, p_grade text default null, p_obs text default null)
returns json language plpgsql security definer set search_path=public as $$
declare u public.usuarios; cid uuid; cnome text; novo public.pedidos;
begin
  select * into u from public._user(p_token);
  if not found or u.papel not in ('gerente','risco') then return json_build_object('ok',false,'msg','Não autorizado'); end if;
  if p_cliente_id is not null then
    select id,nome into cid,cnome from public.clientes where id=p_cliente_id;
    if cid is null then return json_build_object('ok',false,'msg','Cliente não encontrado'); end if;
  else
    if length(coalesce(trim(p_cliente_nome),''))<1 then return json_build_object('ok',false,'msg','Cliente obrigatório'); end if;
    insert into public.clientes(nome,cpf_cnpj,endereco,telefone)
      values (trim(p_cliente_nome), nullif(trim(coalesce(p_cpf,'')),''), nullif(trim(coalesce(p_endereco,'')),''), nullif(trim(coalesce(p_telefone,'')),''))
      on conflict (lower(nome)) do update set
        cpf_cnpj=coalesce(nullif(trim(coalesce(excluded.cpf_cnpj,'')),''), public.clientes.cpf_cnpj),
        endereco=coalesce(nullif(trim(coalesce(excluded.endereco,'')),''), public.clientes.endereco),
        telefone=coalesce(nullif(trim(coalesce(excluded.telefone,'')),''), public.clientes.telefone)
      returning id,nome into cid,cnome;
  end if;
  insert into public.pedidos(cliente,cliente_id,numero,ref,material,qtd_material,ref_molde,grade,obs,prazo)
    values (cnome,cid,nullif(trim(coalesce(p_numero,'')),''),nullif(trim(coalesce(p_ref_molde,'')),''),
            nullif(trim(coalesce(p_material,'')),''),nullif(trim(coalesce(p_qtd_material,'')),''),
            nullif(trim(coalesce(p_ref_molde,'')),''),nullif(trim(coalesce(p_grade,'')),''),
            nullif(trim(coalesce(p_obs,'')),''),null)
    returning * into novo;
  return json_build_object('ok',true,'pedido',row_to_json(novo));
end; $$;
grant execute on function public.criar_pedido(text,uuid,text,text,text,text,text,text,text,text,text,text) to anon;

-- ---------- 7) listar clientes (autocomplete) ----------
create or replace function public.listar_clientes(p_token text)
returns json language plpgsql security definer set search_path=public as $$
begin
  if (select id from public._user(p_token)) is null then return json_build_object('ok',false); end if;
  return json_build_object('ok',true,'clientes',(
    select coalesce(json_agg(json_build_object('id',id,'nome',nome,'cpf_cnpj',cpf_cnpj,'endereco',endereco,'telefone',telefone) order by nome),'[]'::json)
    from public.clientes));
end; $$;
grant execute on function public.listar_clientes(text) to anon;

-- ---------- 8) set_flag: SÓ pagamento/retirada (nota virou bipe); retirada exige nota ----------
create or replace function public.set_flag(p_token text, p_id uuid, p_field text, p_value boolean)
returns json language plpgsql security definer set search_path=public as $$
declare u public.usuarios; ped public.pedidos;
begin
  select * into u from public._user(p_token);
  if not found or u.papel not in ('gerente','risco') then return json_build_object('ok',false,'msg','Não autorizado'); end if;
  if p_field not in ('pagamento','retirada') then return json_build_object('ok',false,'msg','Campo inválido'); end if;
  select * into ped from public.pedidos where id=p_id;
  if not found then return json_build_object('ok',false,'msg','Pedido não encontrado'); end if;
  if p_value and p_field='retirada' and not ped.nota then
    return json_build_object('ok',false,'msg','Só depois da Nota'); end if;
  execute format('update public.pedidos set %I=$1 where id=$2', p_field) using p_value, p_id;
  return json_build_object('ok',true);
end; $$;
grant execute on function public.set_flag(text,uuid,text,boolean) to anon;

-- ---------- 9) gerente_atribuir aceita 'nota'; cancelar_bipe com 4 etapas ----------
create or replace function public.gerente_atribuir(p_token text, p_user_id uuid, p_papel text, p_status text default 'ativo')
returns json language plpgsql security definer set search_path=public as $$
begin
  if _gerente_id(p_token) is null then return json_build_object('ok',false,'msg','Não autorizado'); end if;
  if p_papel is not null and p_papel not in ('risco','enfesto','corte','nota') then
    return json_build_object('ok',false,'msg','Papel inválido'); end if;
  update public.usuarios set papel=p_papel, status=coalesce(p_status,'ativo') where id=p_user_id and papel is distinct from 'gerente';
  return json_build_object('ok',true);
end; $$;

create or replace function public.cancelar_bipe(p_token text, p_id uuid, p_stage text)
returns json language plpgsql security definer set search_path=public as $$
declare stages text[] := array['risco','enfesto','corte','nota']; idx int; i int;
begin
  if _gerente_id(p_token) is null then return json_build_object('ok',false,'msg','Não autorizado'); end if;
  idx := array_position(stages,p_stage);
  if idx is null then return json_build_object('ok',false,'msg','Etapa inválida'); end if;
  for i in idx .. array_length(stages,1) loop
    execute format('update public.pedidos set %I=false where id=$1', stages[i]) using p_id;
    delete from public.eventos where pedido_id=p_id and stage=stages[i];
  end loop;
  update public.pedidos set retirada=false where id=p_id; -- pagamento preservado
  return json_build_object('ok',true);
end; $$;
grant execute on function public.cancelar_bipe(text,uuid,text) to anon;
