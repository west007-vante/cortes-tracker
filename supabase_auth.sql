-- ============================================================
-- Painel de Cortes — Autenticação, papéis e operações do gerente
-- (roda DEPOIS de supabase_schema.sql)
-- ============================================================
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.usuarios (
  id          uuid primary key default gen_random_uuid(),
  username    text unique not null,
  senha_hash  text not null,
  papel       text check (papel in ('gerente','risco','enfesto','corte')), -- null = ainda sem estação
  status      text not null default 'pendente' check (status in ('pendente','ativo','bloqueado')),
  token       text,
  token_exp   timestamptz,
  created_at  timestamptz not null default now()
);
-- RLS sem policy p/ anon: ninguém lê a tabela direto (protege os hashes). Tudo via RPC.
alter table public.usuarios enable row level security;

-- Existe gerente? (controla o setup inicial)
create or replace function public.gerente_existe()
returns boolean language sql security definer set search_path=public as $$
  select exists(select 1 from usuarios where papel='gerente');
$$;
grant execute on function public.gerente_existe() to anon;

-- Bootstrap do gerente (só funciona se ainda não houver gerente)
create or replace function public.criar_gerente(p_username text, p_senha text)
returns json language plpgsql security definer set search_path=public,extensions as $$
begin
  if exists(select 1 from usuarios where papel='gerente') then
    return json_build_object('ok',false,'msg','Gerente já existe'); end if;
  if length(coalesce(trim(p_username),''))<3 or length(coalesce(p_senha,''))<4 then
    return json_build_object('ok',false,'msg','Usuário (3+) e senha (4+) obrigatórios'); end if;
  insert into usuarios(username,senha_hash,papel,status)
    values (lower(trim(p_username)), crypt(p_senha, gen_salt('bf')), 'gerente','ativo');
  return json_build_object('ok',true);
exception when unique_violation then return json_build_object('ok',false,'msg','Esse usuário já existe');
end; $$;
grant execute on function public.criar_gerente(text,text) to anon;

-- Cadastro: cria usuário PENDENTE (gerente libera depois)
create or replace function public.signup(p_username text, p_senha text)
returns json language plpgsql security definer set search_path=public,extensions as $$
begin
  if length(coalesce(trim(p_username),''))<3 or length(coalesce(p_senha,''))<4 then
    return json_build_object('ok',false,'msg','Usuário (3+) e senha (4+) obrigatórios'); end if;
  insert into usuarios(username,senha_hash,status)
    values (lower(trim(p_username)), crypt(p_senha, gen_salt('bf')), 'pendente');
  return json_build_object('ok',true,'msg','Conta criada. Aguarde o gerente liberar seu acesso.');
exception when unique_violation then return json_build_object('ok',false,'msg','Esse usuário já existe');
end; $$;
grant execute on function public.signup(text,text) to anon;

-- Login: valida e devolve papel + token de sessão
create or replace function public.login(p_username text, p_senha text)
returns json language plpgsql security definer set search_path=public,extensions as $$
declare u usuarios; tok text;
begin
  select * into u from usuarios where username=lower(trim(p_username));
  if not found or u.senha_hash <> crypt(p_senha, u.senha_hash) then
    return json_build_object('ok',false,'msg','Usuário ou senha incorretos'); end if;
  if u.status='bloqueado' then return json_build_object('ok',false,'msg','Acesso bloqueado pelo gerente'); end if;
  if u.status='pendente' or u.papel is null then
    return json_build_object('ok',false,'msg','Conta aguardando o gerente liberar sua estação'); end if;
  tok := gen_random_uuid()::text;
  update usuarios set token=tok, token_exp=now()+interval '16 hours' where id=u.id;
  return json_build_object('ok',true,'id',u.id,'username',u.username,'papel',u.papel,'token',tok);
end; $$;
grant execute on function public.login(text,text) to anon;

-- Helper interno: id do gerente válido a partir do token
create or replace function public._gerente_id(p_token text)
returns uuid language sql security definer set search_path=public as $$
  select id from usuarios where token=p_token and token_exp>now() and papel='gerente' and status='ativo';
$$;

-- Gerente: lista usuários (pra liberar/atribuir estação)
create or replace function public.gerente_usuarios(p_token text)
returns json language plpgsql security definer set search_path=public as $$
begin
  if _gerente_id(p_token) is null then return json_build_object('ok',false,'msg','Não autorizado'); end if;
  return json_build_object('ok',true,'usuarios',(
    select coalesce(json_agg(json_build_object('id',id,'username',username,'papel',papel,'status',status,'created_at',created_at) order by created_at desc),'[]'::json)
    from usuarios));
end; $$;
grant execute on function public.gerente_usuarios(text) to anon;

-- Gerente: atribui estação/papel e ativa
create or replace function public.gerente_atribuir(p_token text, p_user_id uuid, p_papel text, p_status text default 'ativo')
returns json language plpgsql security definer set search_path=public as $$
begin
  if _gerente_id(p_token) is null then return json_build_object('ok',false,'msg','Não autorizado'); end if;
  if p_papel is not null and p_papel not in ('gerente','risco','enfesto','corte') then
    return json_build_object('ok',false,'msg','Papel inválido'); end if;
  update usuarios set papel=p_papel, status=coalesce(p_status,'ativo'), token=null where id=p_user_id;
  return json_build_object('ok',true);
end; $$;
grant execute on function public.gerente_atribuir(text,uuid,text,text) to anon;

-- Gerente: exclui usuário (menos outro gerente)
create or replace function public.gerente_excluir_usuario(p_token text, p_user_id uuid)
returns json language plpgsql security definer set search_path=public as $$
begin
  if _gerente_id(p_token) is null then return json_build_object('ok',false,'msg','Não autorizado'); end if;
  delete from usuarios where id=p_user_id and papel is distinct from 'gerente';
  return json_build_object('ok',true);
end; $$;
grant execute on function public.gerente_excluir_usuario(text,uuid) to anon;

-- Gerente: exclui pedido (o "código de segurança" do João = login do gerente)
create or replace function public.excluir_pedido(p_token text, p_id uuid)
returns json language plpgsql security definer set search_path=public as $$
begin
  if _gerente_id(p_token) is null then return json_build_object('ok',false,'msg','Não autorizado'); end if;
  delete from pedidos where id=p_id;
  return json_build_object('ok',true);
end; $$;
grant execute on function public.excluir_pedido(text,uuid) to anon;

-- Cancelar bipe agora exige token de gerente (substitui a versão aberta)
drop function if exists public.cancelar_bipe(uuid, text);
create or replace function public.cancelar_bipe(p_token text, p_id uuid, p_stage text)
returns json language plpgsql security definer set search_path=public as $$
declare stages text[] := array['risco','enfesto','corte']; idx int; i int;
begin
  if _gerente_id(p_token) is null then return json_build_object('ok',false,'msg','Não autorizado'); end if;
  idx := array_position(stages, p_stage);
  if idx is null then return json_build_object('ok',false,'msg','Etapa inválida'); end if;
  for i in idx .. array_length(stages,1) loop
    execute format('update pedidos set %I=false where id=$1', stages[i]) using p_id;
    delete from eventos where pedido_id=p_id and stage=stages[i];
  end loop;
  update pedidos set nota=false, pagamento=false, retirada=false where id=p_id;
  return json_build_object('ok',true);
end; $$;
grant execute on function public.cancelar_bipe(text,uuid,text) to anon;
