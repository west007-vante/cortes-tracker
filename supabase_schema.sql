-- ============================================================
-- Painel de Cortes — schema do Supabase (projeto do João)
-- Rode isto UMA vez no SQL Editor do Supabase (ou via Management API).
-- ============================================================

-- Sequência para o código único do pedido (vai no código de barras)
create sequence if not exists cortes_codigo_seq start 1;

-- Pedidos (espelha a planilha do João — sem "qtde cortes")
create table if not exists public.pedidos (
  id          uuid primary key default gen_random_uuid(),
  codigo      text unique not null default ('CORTE-' || lpad(nextval('cortes_codigo_seq')::text, 5, '0')),
  cliente     text not null,
  numero      text,
  ref         text,
  prazo       date,
  obs         text,
  risco       boolean not null default false,
  enfesto     boolean not null default false,
  corte       boolean not null default false,
  nota        boolean not null default false,
  pagamento   boolean not null default false,
  retirada    boolean not null default false,
  created_at  timestamptz not null default now()
);

-- Eventos de bipe (registro de tempo / gargalo)
create table if not exists public.eventos (
  id         uuid primary key default gen_random_uuid(),
  pedido_id  uuid not null references public.pedidos(id) on delete cascade,
  codigo     text,
  stage      text not null check (stage in ('risco','enfesto','corte')),
  operador   text,
  station    text,
  ts         timestamptz not null default now()
);
create index if not exists eventos_pedido_idx on public.eventos(pedido_id);
create index if not exists eventos_ts_idx     on public.eventos(ts);

-- RLS (ferramenta interna: anon opera; proteção real por login = próximo passo)
alter table public.pedidos enable row level security;
alter table public.eventos enable row level security;
drop policy if exists anon_all_pedidos on public.pedidos;
drop policy if exists anon_all_eventos on public.eventos;
create policy anon_all_pedidos on public.pedidos for all to anon using (true) with check (true);
create policy anon_all_eventos on public.eventos for all to anon using (true) with check (true);

-- BIPE atômico e à prova de erro: sequência risco->enfesto->corte + bipe único, no SERVIDOR
create or replace function public.bipe(p_codigo text, p_stage text, p_operador text default null)
returns json language plpgsql security definer set search_path = public as $$
declare ped public.pedidos;
begin
  select * into ped from public.pedidos where codigo = upper(trim(p_codigo)) for update;
  if not found then
    return json_build_object('ok', false, 'msg', 'Código não encontrado: ' || p_codigo);
  end if;

  if p_stage = 'risco' then
    if ped.risco then return json_build_object('ok', false, 'msg', 'Risco já foi bipado neste pedido (' || ped.cliente || ') — bipe único'); end if;
    update public.pedidos set risco = true where id = ped.id;
  elsif p_stage = 'enfesto' then
    if not ped.risco then return json_build_object('ok', false, 'msg', 'Fora de ordem: bipe Risco antes de Enfesto (' || ped.cliente || ')'); end if;
    if ped.enfesto then return json_build_object('ok', false, 'msg', 'Enfesto já foi bipado neste pedido (' || ped.cliente || ') — bipe único'); end if;
    update public.pedidos set enfesto = true where id = ped.id;
  elsif p_stage = 'corte' then
    if not ped.enfesto then return json_build_object('ok', false, 'msg', 'Fora de ordem: bipe Enfesto antes de Corte (' || ped.cliente || ')'); end if;
    if ped.corte then return json_build_object('ok', false, 'msg', 'Corte já foi bipado neste pedido (' || ped.cliente || ') — bipe único'); end if;
    update public.pedidos set corte = true where id = ped.id;
  else
    return json_build_object('ok', false, 'msg', 'Etapa inválida: ' || p_stage);
  end if;

  insert into public.eventos(pedido_id, codigo, stage, operador, station)
  values (ped.id, ped.codigo, p_stage, nullif(trim(coalesce(p_operador,'')), ''), p_stage);

  return json_build_object('ok', true, 'msg', ped.cliente || coalesce(' · ' || nullif(ped.numero, ''), ''));
end; $$;
grant execute on function public.bipe(text, text, text) to anon;

-- Cancelar bipe (admin): zera a etapa + seguintes + flags administrativas, remove eventos
create or replace function public.cancelar_bipe(p_id uuid, p_stage text)
returns void language plpgsql security definer set search_path = public as $$
declare stages text[] := array['risco','enfesto','corte']; idx int; i int;
begin
  idx := array_position(stages, p_stage);
  if idx is null then return; end if;
  for i in idx .. array_length(stages, 1) loop
    execute format('update public.pedidos set %I = false where id = $1', stages[i]) using p_id;
    delete from public.eventos where pedido_id = p_id and stage = stages[i];
  end loop;
  update public.pedidos set nota = false, pagamento = false, retirada = false where id = p_id;
end; $$;
grant execute on function public.cancelar_bipe(uuid, text) to anon;

-- Realtime (atualiza todos os aparelhos ao vivo)
do $$ begin
  begin alter publication supabase_realtime add table public.pedidos; exception when others then null; end;
  begin alter publication supabase_realtime add table public.eventos; exception when others then null; end;
end $$;
