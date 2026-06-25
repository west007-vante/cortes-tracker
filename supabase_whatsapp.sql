-- ============================================================
-- Painel de Cortes — Notificação WhatsApp (aviso "pedido pronto" ao bipar a Nota)
-- Aditivo: tabela + gatilho + RPC. NÃO altera/apaga dado.
-- ============================================================
create table if not exists public.notificacoes (
  id uuid primary key default gen_random_uuid(),
  pedido_id uuid references public.pedidos(id) on delete set null,
  cliente text, telefone text, mensagem text not null,
  status text not null default 'pendente', -- pendente | enviado | erro | sem_telefone
  erro text, tentativas int not null default 0,
  created_at timestamptz not null default now(), sent_at timestamptz
);
create index if not exists notif_status_idx on public.notificacoes(status, created_at);
alter table public.notificacoes enable row level security; -- sem policy anon (PII protegido)

-- Gatilho: quando nota vira true, cria a notificação. Blindado: nunca quebra o bipe.
create or replace function public.trg_nota_notif()
returns trigger language plpgsql security definer set search_path=public as $FN$
declare cl public.clientes; tel text;
begin
  if NEW.nota = true and (OLD.nota is distinct from true) then
    begin
      select * into cl from public.clientes where id = NEW.cliente_id;
      tel := nullif(regexp_replace(coalesce(cl.telefone,''), '\D', '', 'g'), '');
      insert into public.notificacoes(pedido_id, cliente, telefone, mensagem, status)
      values (NEW.id, NEW.cliente, tel,
        'Olá '||coalesce(NEW.cliente,'cliente')||E'\n\nSeu pedido '||coalesce(nullif(NEW.numero,''),NEW.codigo)||E' de corte já está finalizado e disponível para retirada.\n\nA liberação será efetuada após o envio do comprovante de pagamento.\nChave pix: 55.727.635/0001-87 GF CORTE LTDA - Banco Sicoob\n\nAgradecemos a preferência!',
        case when tel is null then 'sem_telefone' else 'pendente' end);
    exception when others then null; -- nunca bloqueia o bipe
    end;
  end if;
  return NEW;
end; $FN$;
drop trigger if exists nota_notif on public.pedidos;
create trigger nota_notif after update on public.pedidos for each row execute function public.trg_nota_notif();

-- Gerente vê o status das notificações
create or replace function public.gerente_notificacoes(p_token text)
returns json language plpgsql security definer set search_path=public as $FN$
begin
  if _gerente_id(p_token) is null then return json_build_object('ok',false,'msg','Não autorizado'); end if;
  return json_build_object('ok',true,'notificacoes',(
    select coalesce(json_agg(json_build_object('id',id,'cliente',cliente,'telefone',telefone,'status',status,'erro',erro,'created_at',created_at,'sent_at',sent_at) order by created_at desc),'[]'::json)
    from (select * from public.notificacoes order by created_at desc limit 100) t));
end; $FN$;
grant execute on function public.gerente_notificacoes(text) to anon;
