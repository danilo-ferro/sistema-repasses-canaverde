-- =====================================================================
-- MIGRAÇÕES APLICADAS EM 23/07/2026
-- Sistema de Repasses — Canaverde & Aguiar Advogados
-- Supabase project_id: maytgfyzvoufepaerwwn
--
-- ⚠️ ESTE ARQUIVO É DOCUMENTAÇÃO / REFERÊNCIA.
--    Tudo aqui JÁ ESTÁ APLICADO no banco de produção.
--    NÃO rodar de novo sem necessidade. Se rodar, é idempotente
--    (create or replace / drop trigger if exists), mas confira antes.
--
-- Ordem: 1) trava de pagamento  2) senha (legada)  3) lista de usuários
--        4) criar/atualizar/excluir usuário
-- =====================================================================


-- =====================================================================
-- 1) TRAVA DE PAGAMENTO — somente perfil 'gestao'
--    Enforcement no BANCO (vale para tela, view ou chamada direta à API).
-- =====================================================================
create or replace function public.bloqueia_pagamento_nao_gestao()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
begin
  -- Sem usuário logado (service_role / migrações): não interfere. Proposital.
  if v_uid is null then
    return new;
  end if;

  if public.meu_perfil() = 'gestao' then
    return new;
  end if;

  -- Daqui pra baixo: usuário logado que NÃO é gestão.
  if tg_op = 'INSERT' then
    if coalesce(new.pago, false) = true
       or nullif(btrim(coalesce(new.data_pagamento, '')), '') is not null
       or nullif(btrim(coalesce(new.valor_pago, '')), '') is not null then
      raise exception 'Somente a gestao pode registrar pagamento.'
        using errcode = '42501';
    end if;

  elsif tg_op = 'UPDATE' then
    if (new.pago is distinct from old.pago)
       or (coalesce(nullif(btrim(coalesce(new.data_pagamento,'')),''),'')
           is distinct from
           coalesce(nullif(btrim(coalesce(old.data_pagamento,'')),''),''))
       or (coalesce(nullif(btrim(coalesce(new.valor_pago,'')),''),'')
           is distinct from
           coalesce(nullif(btrim(coalesce(old.valor_pago,'')),''),'')) then
      raise exception 'Somente a gestao pode alterar o status de pagamento.'
        using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_bloqueia_pagamento on public.repasses;
create trigger trg_bloqueia_pagamento
before insert or update on public.repasses
for each row execute function public.bloqueia_pagamento_nao_gestao();

-- Função de trigger não precisa ser chamável via API.
revoke all on function public.bloqueia_pagamento_nao_gestao() from public, anon, authenticated;


-- =====================================================================
-- 2) TROCA DE SENHA (LEGADA)
--    Substituída por admin_atualizar_usuario. Mantida por compatibilidade.
--    A tela NÃO usa mais esta função. Pode ser removida no futuro.
-- =====================================================================
create or replace function public.admin_definir_senha(target_email text, nova_senha text)
returns text
language plpgsql
security definer
set search_path = extensions, public, pg_temp
as $$
declare
  v_id uuid;
  v_email text := lower(btrim(coalesce(target_email, '')));
begin
  if public.meu_perfil() is distinct from 'gestao' then
    raise exception 'Apenas o perfil gestao pode alterar senhas.' using errcode = '42501';
  end if;
  if v_email = '' then
    raise exception 'Informe o e-mail do usuario.' using errcode = '22023';
  end if;
  if nova_senha is null or length(nova_senha) < 6 then
    raise exception 'A nova senha precisa ter ao menos 6 caracteres.' using errcode = '22023';
  end if;

  select id into v_id from auth.users where lower(email) = v_email;
  if v_id is null then
    raise exception 'Usuario nao encontrado: %', v_email using errcode = 'P0002';
  end if;

  update auth.users
     set encrypted_password = extensions.crypt(nova_senha, extensions.gen_salt('bf')),
         updated_at = now()
   where id = v_id;

  return 'Senha alterada com sucesso para ' || v_email;
end;
$$;

revoke all on function public.admin_definir_senha(text, text) from public, anon;
grant execute on function public.admin_definir_senha(text, text) to authenticated;


-- =====================================================================
-- 3) LISTAR USUÁRIOS — somente 'gestao'
--    Necessária porque a RLS de profiles (policy perfil_proprio)
--    deixa cada usuário ver apenas o próprio registro.
-- =====================================================================
create or replace function public.listar_usuarios()
returns table(email text, nome text, perfil text)
language sql
security definer
set search_path = public, pg_temp
as $$
  select p.email, p.nome, p.perfil
  from public.profiles p
  where public.meu_perfil() = 'gestao'
  order by p.email
$$;

revoke all on function public.listar_usuarios() from public, anon;
grant execute on function public.listar_usuarios() to authenticated;


-- =====================================================================
-- 4) CRIAR USUÁRIO — somente 'gestao'
--    Cria em auth.users + auth.identities e ajusta profiles.
--    OBS: auth.identities.email é coluna GERADA — nunca incluir no INSERT.
-- =====================================================================
create or replace function public.admin_criar_usuario(
  p_email text, p_nome text, p_senha text, p_perfil text)
returns text
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_email  text := lower(btrim(coalesce(p_email,'')));
  v_nome   text := btrim(coalesce(p_nome,''));
  v_perfil text := lower(btrim(coalesce(p_perfil,'atendimento')));
  v_id     uuid := gen_random_uuid();
begin
  if public.meu_perfil() is distinct from 'gestao' then
    raise exception 'Apenas o perfil gestao pode gerenciar usuarios.' using errcode='42501';
  end if;
  if v_email = '' or position('@' in v_email) = 0 then
    raise exception 'Informe um e-mail valido.' using errcode='22023';
  end if;
  if v_perfil not in ('gestao','atendimento') then
    raise exception 'Perfil invalido (use gestao ou atendimento).' using errcode='22023';
  end if;
  if p_senha is null or length(p_senha) < 6 then
    raise exception 'A senha precisa ter ao menos 6 caracteres.' using errcode='22023';
  end if;
  if exists (select 1 from auth.users where lower(email) = v_email) then
    raise exception 'Ja existe um usuario com este e-mail: %', v_email using errcode='23505';
  end if;

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token,
    raw_app_meta_data, raw_user_meta_data
  ) values (
    '00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated',
    v_email, extensions.crypt(p_senha, extensions.gen_salt('bf')),
    now(), now(), now(),
    '', '', '', '',
    '{"provider":"email","providers":["email"]}'::jsonb,
    jsonb_build_object('email_verified', true, 'name', v_nome)
  );

  insert into auth.identities (
    provider_id, user_id, identity_data, provider,
    last_sign_in_at, created_at, updated_at
  ) values (
    v_id::text, v_id,
    jsonb_build_object('sub', v_id::text, 'email', v_email,
                       'email_verified', false, 'phone_verified', false),
    'email', now(), now(), now()
  );

  -- o trigger handle_new_user já criou o profile; aqui ajusta nome/perfil/email
  update public.profiles
     set nome = nullif(v_nome,''), perfil = v_perfil, email = v_email
   where id = v_id;

  return 'Usuario criado: ' || v_email;
end;
$$;


-- =====================================================================
-- 5) ATUALIZAR USUÁRIO — somente 'gestao'
--    Nome + perfil sempre; senha só se p_nova_senha vier preenchida.
--    E-mail NÃO é alterável (é a chave de login).
-- =====================================================================
create or replace function public.admin_atualizar_usuario(
  p_email text, p_nome text, p_perfil text, p_nova_senha text default null)
returns text
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_email        text := lower(btrim(coalesce(p_email,'')));
  v_nome         text := btrim(coalesce(p_nome,''));
  v_perfil       text := lower(btrim(coalesce(p_perfil,'')));
  v_id           uuid;
  v_perfil_atual text;
begin
  if public.meu_perfil() is distinct from 'gestao' then
    raise exception 'Apenas o perfil gestao pode gerenciar usuarios.' using errcode='42501';
  end if;
  if v_perfil not in ('gestao','atendimento') then
    raise exception 'Perfil invalido (use gestao ou atendimento).' using errcode='22023';
  end if;

  select p.id, p.perfil into v_id, v_perfil_atual
  from public.profiles p where lower(p.email) = v_email;
  if v_id is null then
    raise exception 'Usuario nao encontrado: %', v_email using errcode='P0002';
  end if;

  -- não deixar o sistema sem nenhum gestor
  if v_perfil_atual = 'gestao' and v_perfil = 'atendimento'
     and (select count(*) from public.profiles where perfil='gestao') <= 1 then
    raise exception 'Nao e possivel rebaixar o unico usuario gestao.' using errcode='42501';
  end if;

  update public.profiles
     set nome = nullif(v_nome,''), perfil = v_perfil
   where id = v_id;

  if p_nova_senha is not null and btrim(p_nova_senha) <> '' then
    if length(p_nova_senha) < 6 then
      raise exception 'A nova senha precisa ter ao menos 6 caracteres.' using errcode='22023';
    end if;
    update auth.users
       set encrypted_password = extensions.crypt(p_nova_senha, extensions.gen_salt('bf')),
           updated_at = now()
     where id = v_id;
  end if;

  return 'Usuario atualizado: ' || v_email;
end;
$$;


-- =====================================================================
-- 6) EXCLUIR USUÁRIO — somente 'gestao'
--    profiles sai por cascata (FK profiles_id_fkey ON DELETE CASCADE).
-- =====================================================================
create or replace function public.admin_excluir_usuario(p_email text)
returns text
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_email  text := lower(btrim(coalesce(p_email,'')));
  v_id     uuid;
  v_perfil text;
begin
  if public.meu_perfil() is distinct from 'gestao' then
    raise exception 'Apenas o perfil gestao pode gerenciar usuarios.' using errcode='42501';
  end if;

  select p.id, p.perfil into v_id, v_perfil
  from public.profiles p where lower(p.email) = v_email;
  if v_id is null then
    raise exception 'Usuario nao encontrado: %', v_email using errcode='P0002';
  end if;

  if v_id = auth.uid() then
    raise exception 'Voce nao pode excluir a propria conta.' using errcode='42501';
  end if;
  if v_perfil = 'gestao'
     and (select count(*) from public.profiles where perfil='gestao') <= 1 then
    raise exception 'Nao e possivel excluir o unico usuario gestao.' using errcode='42501';
  end if;

  delete from auth.identities where user_id = v_id;
  delete from auth.users where id = v_id;  -- cascata remove o profile

  return 'Usuario excluido: ' || v_email;
end;
$$;


-- =====================================================================
-- PERMISSÕES das funções de usuário
-- =====================================================================
revoke all on function public.admin_criar_usuario(text,text,text,text)     from public, anon;
revoke all on function public.admin_atualizar_usuario(text,text,text,text) from public, anon;
revoke all on function public.admin_excluir_usuario(text)                  from public, anon;
grant execute on function public.admin_criar_usuario(text,text,text,text)     to authenticated;
grant execute on function public.admin_atualizar_usuario(text,text,text,text) to authenticated;
grant execute on function public.admin_excluir_usuario(text)                  to authenticated;


-- =====================================================================
-- CONFERÊNCIA RÁPIDA (rodar isto é seguro — só lê)
-- =====================================================================
-- select p.proname, pg_get_function_identity_arguments(p.oid), p.prosecdef
-- from pg_proc p join pg_namespace n on n.oid = p.pronamespace
-- where n.nspname='public' and p.proname like 'admin\_%' or p.proname='listar_usuarios'
-- order by p.proname;
--
-- select tgname from pg_trigger
-- where tgrelid='public.repasses'::regclass and not tgisinternal order by tgname;
-- Esperado: trg_bloqueia_pagamento, trg_marca_autor, trg_registra_log
