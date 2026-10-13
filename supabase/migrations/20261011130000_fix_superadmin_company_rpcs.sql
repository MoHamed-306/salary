create or replace function public.superadmin_delete_company(
  p_session_token text,
  p_company_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public._is_superadmin(p_session_token) then
    raise exception 'unauthorized';
  end if;

  delete from public.companies where id = p_company_id;
  if not found then raise exception 'company not found'; end if;
end;
$$;

create or replace function public.superadmin_list_company_employees(
  p_session_token text,
  p_company_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public._is_superadmin(p_session_token) then
    raise exception 'unauthorized';
  end if;
  if not exists (
    select 1 from public.companies where id = p_company_id
  ) then
    raise exception 'company not found';
  end if;

  return coalesce((
    select jsonb_agg(
      jsonb_build_object('id', e.id, 'name', e.name)
      order by lower(e.name)
    )
    from public.employees e
    where e.company_id = p_company_id
  ), '[]'::jsonb);
end;
$$;

create or replace function public.superadmin_list_employee_months(
  p_session_token text,
  p_employee_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public._is_superadmin(p_session_token) then
    raise exception 'unauthorized';
  end if;
  if not exists (
    select 1 from public.employees where id = p_employee_id
  ) then
    raise exception 'employee not found';
  end if;

  return coalesce((
    select jsonb_agg(
      m.data || jsonb_build_object('year', m.year, 'month', m.month)
      order by m.year desc, m.month desc
    )
    from public.employee_months m
    where m.employee_id = p_employee_id
  ), '[]'::jsonb);
end;
$$;

create or replace function public.company_delete_employee(
  p_session_token text,
  p_employee_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid := public._session_company(p_session_token);
begin
  if v_company_id is null or public._session_role(p_session_token) <> 'manager' then
    raise exception 'unauthorized';
  end if;

  delete from public.employees
  where id = p_employee_id and company_id = v_company_id;
  if not found then raise exception 'employee not found'; end if;
end;
$$;

revoke execute on function public.superadmin_delete_company(text, uuid)
  from public;
revoke execute on function public.superadmin_list_company_employees(text, uuid)
  from public;
revoke execute on function public.superadmin_list_employee_months(text, uuid)
  from public;
revoke execute on function public.company_delete_employee(text, uuid)
  from public;
grant execute on function public.superadmin_delete_company(text, uuid)
  to anon, authenticated;
grant execute on function public.superadmin_list_company_employees(text, uuid)
  to anon, authenticated;
grant execute on function public.superadmin_list_employee_months(text, uuid)
  to anon, authenticated;
grant execute on function public.company_delete_employee(text, uuid)
  to anon, authenticated;

notify pgrst, 'reload schema';
