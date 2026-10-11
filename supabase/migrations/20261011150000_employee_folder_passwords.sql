alter table public.employees
  add column if not exists password_hash text,
  add column if not exists password_ciphertext bytea;

create or replace function public.company_list_employees(p_session_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid := public._session_company(p_session_token);
begin
  if v_company_id is null then raise exception 'unauthorized'; end if;
  return coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'id', e.id,
        'name', e.name,
        'has_password', e.password_hash is not null
      )
      order by lower(e.name)
    )
    from public.employees e
    where e.company_id = v_company_id
  ), '[]'::jsonb);
end;
$$;

create or replace function public.company_employee_password_status(
  p_session_token text,
  p_employee_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid := public._session_company(p_session_token);
  v_has_password boolean;
begin
  if v_company_id is null or public._session_role(p_session_token) <> 'employee' then
    raise exception 'unauthorized';
  end if;

  select e.password_hash is not null into v_has_password
  from public.employees e
  where e.id = p_employee_id and e.company_id = v_company_id;
  if not found then raise exception 'employee not found'; end if;
  return v_has_password;
end;
$$;

create or replace function public.company_verify_employee_password(
  p_session_token text,
  p_employee_id uuid,
  p_password text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid := public._session_company(p_session_token);
  v_password_hash text;
begin
  if v_company_id is null or public._session_role(p_session_token) <> 'employee' then
    raise exception 'unauthorized';
  end if;

  select e.password_hash into v_password_hash
  from public.employees e
  where e.id = p_employee_id and e.company_id = v_company_id;
  if not found then raise exception 'employee not found'; end if;
  if v_password_hash is null then return true; end if;
  if p_password is null then return false; end if;
  return extensions.crypt(p_password, v_password_hash) = v_password_hash;
end;
$$;

create or replace function public.company_update_employee_password(
  p_session_token text,
  p_employee_id uuid,
  p_current_password text,
  p_new_password text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid := public._session_company(p_session_token);
  v_employee public.employees%rowtype;
begin
  if v_company_id is null or public._session_role(p_session_token) <> 'employee' then
    raise exception 'unauthorized';
  end if;

  select e.* into v_employee
  from public.employees e
  where e.id = p_employee_id and e.company_id = v_company_id
  for update;
  if not found then raise exception 'employee not found'; end if;

  if v_employee.password_hash is not null then
    if p_current_password is null or
       extensions.crypt(p_current_password, v_employee.password_hash)
         <> v_employee.password_hash then
      raise exception 'current employee password is incorrect';
    end if;
  elsif coalesce(p_current_password, '') <> '' then
    raise exception 'employee has no current password';
  end if;

  if coalesce(p_new_password, '') = '' then
    if v_employee.password_hash is null then
      raise exception 'employee has no password to remove';
    end if;
    update public.employees
    set password_hash = null, password_ciphertext = null
    where id = p_employee_id and company_id = v_company_id;
    return false;
  end if;

  if length(p_new_password) < 6 then
    raise exception 'employee password must be at least 6 characters';
  end if;

  update public.employees set
    password_hash = extensions.crypt(p_new_password, extensions.gen_salt('bf')),
    password_ciphertext = extensions.pgp_sym_encrypt(
      p_new_password,
      public._company_password_key()
    )
  where id = p_employee_id and company_id = v_company_id;
  return true;
end;
$$;

create or replace function public.company_get_employee_password(
  p_session_token text,
  p_employee_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid := public._session_company(p_session_token);
  v_employee public.employees%rowtype;
begin
  if v_company_id is null or public._session_role(p_session_token) <> 'manager' then
    raise exception 'unauthorized';
  end if;

  select e.* into v_employee
  from public.employees e
  where e.id = p_employee_id and e.company_id = v_company_id;
  if not found then raise exception 'employee not found'; end if;

  return jsonb_build_object(
    'has_password', v_employee.password_hash is not null,
    'password', case when v_employee.password_ciphertext is null then null
      else convert_from(
        extensions.pgp_sym_decrypt_bytea(
          v_employee.password_ciphertext,
          public._company_password_key()
        ),
        'UTF8'
      )
    end
  );
end;
$$;

revoke execute on function public.company_list_employees(text) from public;
revoke execute on function public.company_employee_password_status(text, uuid)
  from public;
revoke execute on function public.company_verify_employee_password(text, uuid, text)
  from public;
revoke execute on function public.company_update_employee_password(text, uuid, text, text)
  from public;
revoke execute on function public.company_get_employee_password(text, uuid)
  from public;
grant execute on function public.company_list_employees(text)
  to anon, authenticated;
grant execute on function public.company_employee_password_status(text, uuid)
  to anon, authenticated;
grant execute on function public.company_verify_employee_password(text, uuid, text)
  to anon, authenticated;
grant execute on function public.company_update_employee_password(text, uuid, text, text)
  to anon, authenticated;
grant execute on function public.company_get_employee_password(text, uuid)
  to anon, authenticated;

notify pgrst, 'reload schema';
