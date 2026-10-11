alter table public.companies
  add column if not exists attendance_mode text not null default 'manual';

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'companies_attendance_mode_check'
      and conrelid = 'public.companies'::regclass
  ) then
    alter table public.companies
      add constraint companies_attendance_mode_check
      check (attendance_mode in ('manual', 'required'));
  end if;
end;
$$;

create or replace function public.company_get_attendance_mode(
  p_session_token text
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid := public._session_company(p_session_token);
  v_mode text;
begin
  if v_company_id is null then raise exception 'unauthorized'; end if;
  select c.attendance_mode into v_mode
  from public.companies c
  where c.id = v_company_id;
  return v_mode;
end;
$$;

create or replace function public.company_set_attendance_mode(
  p_session_token text,
  p_mode text
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
  if p_mode is null or p_mode not in ('manual', 'required') then
    raise exception 'invalid attendance mode';
  end if;

  update public.companies
  set attendance_mode = p_mode
  where id = v_company_id;
end;
$$;

create or replace function public.company_get_today_attendance(
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
  v_local_now timestamp := timezone('Africa/Cairo', now());
  v_year integer := extract(year from v_local_now)::integer;
  v_month integer := extract(month from v_local_now)::integer;
  v_day integer := extract(day from v_local_now)::integer;
  v_data jsonb;
  v_day_data jsonb;
begin
  if v_company_id is null or public._session_role(p_session_token) <> 'employee'
     or not exists (
       select 1 from public.employees e
       where e.id = p_employee_id and e.company_id = v_company_id
     ) then
    raise exception 'unauthorized';
  end if;

  select m.data into v_data
  from public.employee_months m
  where m.company_id = v_company_id
    and m.employee_id = p_employee_id
    and m.year = v_year
    and m.month = v_month;

  v_day_data := coalesce(v_data -> 'days' -> v_day::text, '{}'::jsonb);
  return jsonb_build_object(
    'mode', (select c.attendance_mode from public.companies c where c.id = v_company_id),
    'year', v_year,
    'month', v_month,
    'day', v_day,
    'date', to_char(v_local_now, 'YYYY-MM-DD'),
    'arrival', v_day_data ->> 'arrival',
    'departure', v_day_data ->> 'departure'
  );
end;
$$;

create or replace function public.company_record_attendance_action(
  p_session_token text,
  p_employee_id uuid,
  p_action text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid := public._session_company(p_session_token);
  v_local_now timestamp := timezone('Africa/Cairo', now());
  v_year integer := extract(year from v_local_now)::integer;
  v_month integer := extract(month from v_local_now)::integer;
  v_day integer := extract(day from v_local_now)::integer;
  v_column text;
  v_time text := to_char(v_local_now, 'HH24:MI');
  v_month_data jsonb;
  v_day_data jsonb;
begin
  if v_company_id is null or public._session_role(p_session_token) <> 'employee'
     or not exists (
       select 1 from public.employees e
       where e.id = p_employee_id and e.company_id = v_company_id
     ) then
    raise exception 'unauthorized';
  end if;
  if p_action is null or p_action not in ('check_in', 'check_out') then
    raise exception 'invalid attendance action';
  end if;
  if not exists (
    select 1 from public.companies c
    where c.id = v_company_id and c.attendance_mode = 'required'
  ) then
    raise exception 'automatic attendance is not enabled';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      v_company_id::text || ':' || p_employee_id::text || ':' ||
        to_char(v_local_now, 'YYYY-MM-DD'),
      0
    )
  );

  insert into public.employee_months(company_id, employee_id, year, month, data)
  values (
    v_company_id,
    p_employee_id,
    v_year,
    v_month,
    jsonb_build_object(
      'year', v_year,
      'month', v_month,
      'vacationDays', 0,
      'workDays', 30,
      'days', '{}'::jsonb
    )
  )
  on conflict (employee_id, year, month) do nothing;

  select m.data into v_month_data
  from public.employee_months m
  where m.company_id = v_company_id
    and m.employee_id = p_employee_id
    and m.year = v_year
    and m.month = v_month
  for update;

  v_day_data := coalesce(v_month_data -> 'days' -> v_day::text, '{}'::jsonb);
  if p_action = 'check_in' then
    if coalesce(v_day_data ->> 'arrival', '') <> '' then
      raise exception 'check-in already recorded';
    end if;
    v_column := 'arrival';
  else
    if coalesce(v_day_data ->> 'arrival', '') = '' then
      raise exception 'check-in is required before check-out';
    end if;
    if coalesce(v_day_data ->> 'departure', '') <> '' then
      raise exception 'check-out already recorded';
    end if;
    v_column := 'departure';
  end if;

  v_day_data := v_day_data || jsonb_build_object(
    v_column, v_time,
    'isWorking', true
  );
  v_month_data := jsonb_set(
    v_month_data,
    array['days', v_day::text],
    v_day_data,
    true
  );
  update public.employee_months
  set data = v_month_data, updated_at = now()
  where company_id = v_company_id
    and employee_id = p_employee_id
    and year = v_year
    and month = v_month;

  return jsonb_build_object(
    'mode', 'required',
    'year', v_year,
    'month', v_month,
    'day', v_day,
    'date', to_char(v_local_now, 'YYYY-MM-DD'),
    'arrival', v_day_data ->> 'arrival',
    'departure', v_day_data ->> 'departure'
  );
end;
$$;

create or replace function public.company_save_month(
  p_session_token text,
  p_employee_id uuid,
  p_year integer,
  p_month integer,
  p_data jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid := public._session_company(p_session_token);
  v_role text := public._session_role(p_session_token);
  v_mode text;
begin
  if v_company_id is null or not exists (
    select 1 from public.employees e
    where e.id = p_employee_id and e.company_id = v_company_id
  ) then
    raise exception 'unauthorized';
  end if;
  if p_year not between 2000 and 2100 or p_month not between 1 and 12 then
    raise exception 'invalid month';
  end if;
  if v_role = 'manager' then
    insert into public.employee_months(company_id, employee_id, year, month, data)
    values (v_company_id, p_employee_id, p_year, p_month, p_data)
    on conflict (employee_id, year, month) do update
      set data = excluded.data, updated_at = now();
  elsif v_role = 'employee' then
    select c.attendance_mode into v_mode
    from public.companies c
    where c.id = v_company_id;
    if v_mode = 'required' then
      raise exception 'manual attendance editing is disabled';
    end if;

    update public.employee_months set
      data = jsonb_set(data, '{days}', coalesce(p_data -> 'days', '{}'::jsonb), true),
      updated_at = now()
    where company_id = v_company_id and employee_id = p_employee_id
      and year = p_year and month = p_month;
    if not found then
      insert into public.employee_months(company_id, employee_id, year, month, data)
      values (
        v_company_id, p_employee_id, p_year, p_month,
        jsonb_build_object(
          'year', p_year,
          'month', p_month,
          'vacationDays', 0,
          'workDays', 30,
          'days', coalesce(p_data -> 'days', '{}'::jsonb)
        )
      );
    end if;
  else
    raise exception 'unauthorized';
  end if;
end;
$$;

revoke execute on function public.company_get_attendance_mode(text) from public;
revoke execute on function public.company_set_attendance_mode(text, text) from public;
revoke execute on function public.company_get_today_attendance(text, uuid) from public;
revoke execute on function public.company_record_attendance_action(text, uuid, text)
  from public;
revoke execute on function public.company_save_month(text, uuid, integer, integer, jsonb)
  from public;
grant execute on function public.company_get_attendance_mode(text)
  to anon, authenticated;
grant execute on function public.company_set_attendance_mode(text, text)
  to anon, authenticated;
grant execute on function public.company_get_today_attendance(text, uuid)
  to anon, authenticated;
grant execute on function public.company_record_attendance_action(text, uuid, text)
  to anon, authenticated;
grant execute on function public.company_save_month(text, uuid, integer, integer, jsonb)
  to anon, authenticated;
