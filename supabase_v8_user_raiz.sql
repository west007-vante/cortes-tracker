-- ============================================================
-- GF Cortes — v8: fecha o furo de autorização NA RAIZ (_user)
-- ============================================================
-- Furo: _user é "returns usuarios" (composto). Pra token inválido o select não
-- acha nada, mas a função devolve UMA linha toda nula (papel NULL). O check
-- "if not found or papel not in (...)" não barra (false OR NULL = não bloqueia),
-- então criar_pedido / set_flag / bipe aceitam token inválido.
--
-- Correção: _user vira "returns SETOF usuarios" -> token inválido = ZERO linhas
-- = "not found" passa a barrar em TODAS as funções de uma vez. Corpo idêntico
-- ao atual, só muda o tipo de retorno.
--
-- Seguro: tudo dentro de BEGIN/COMMIT. Se qualquer passo falhar (ou o teste no
-- fim detectar que o furo não fechou), faz ROLLBACK e a _user atual permanece.
-- NÃO apaga nem altera nenhum dado. Cole no SQL Editor e Run.
-- ============================================================
begin;

drop function if exists public._user(text);

create function public._user(p_token text)
  returns setof public.usuarios
  language sql
  security definer
  set search_path to 'public'
as $function$
  select u.* from public.sessoes s
  join public.usuarios u on u.id = s.user_id
  where s.token = p_token and u.status = 'ativo'
  limit 1;
$function$;

grant execute on function public._user(text) to anon;

-- rede de segurança: aborta (rollback) se token inválido ainda devolver linha
do $$
begin
  if exists (select 1 from public._user('TOKEN_INVALIDO_DE_TESTE_xyz_123')) then
    raise exception 'Abortado: _user ainda devolve linha para token invalido — nada foi aplicado';
  end if;
end $$;

commit;
