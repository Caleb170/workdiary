-- WorkQuest shared calendars: compact, RLS-protected, basic-plan friendly.
create extension if not exists pgcrypto;

create table if not exists public.share_members (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  invited_email text not null,
  display_name text not null check (char_length(display_name) between 1 and 40),
  colour text not null default '#5B6FE0',
  member_user_id uuid references auth.users(id) on delete set null,
  invite_token text not null unique default encode(extensions.gen_random_bytes(24), 'hex'),
  status text not null default 'invited' check (status in ('invited','active','revoked')),
  show_day_amount boolean not null default false,
  show_week_amount boolean not null default false,
  created_at timestamptz not null default now(),
  accepted_at timestamptz,
  unique(owner_id, invited_email)
);

create table if not exists public.shift_shares (
  owner_id uuid not null references auth.users(id) on delete cascade,
  member_id uuid not null references public.share_members(id) on delete cascade,
  shift_id text not null references public.shifts(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key(member_id, shift_id)
);

create table if not exists public.share_challenges (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  member_id uuid not null references public.share_members(id) on delete cascade,
  challenge_type text not null check (challenge_type in ('shifts','earnings')),
  target numeric(12,2) not null check (target > 0),
  week_start date not null,
  created_at timestamptz not null default now(),
  unique(member_id, challenge_type, week_start)
);

create table if not exists public.share_events (
  id bigint generated always as identity primary key,
  owner_id uuid not null references auth.users(id) on delete cascade,
  member_id uuid not null references public.share_members(id) on delete cascade,
  event_type text not null check (event_type in ('shift_added','shift_edited','shift_removed','challenge_started')),
  title text not null,
  message text not null default '',
  created_at timestamptz not null default now(),
  seen_at timestamptz
);

create index if not exists share_members_owner_idx on public.share_members(owner_id);
create index if not exists share_members_user_idx on public.share_members(member_user_id) where member_user_id is not null;
create index if not exists shift_shares_owner_idx on public.shift_shares(owner_id);
create index if not exists shift_shares_shift_idx on public.shift_shares(shift_id);
create index if not exists share_challenges_member_week_idx on public.share_challenges(member_id, week_start);
create index if not exists share_events_unseen_idx on public.share_events(member_id, created_at desc) where seen_at is null;

alter table public.share_members enable row level security;
alter table public.shift_shares enable row level security;
alter table public.share_challenges enable row level security;
alter table public.share_events enable row level security;

drop policy if exists share_members_owner_all on public.share_members;
create policy share_members_owner_all on public.share_members for all to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
drop policy if exists share_members_member_read on public.share_members;
create policy share_members_member_read on public.share_members for select to authenticated
  using (member_user_id = auth.uid() and status = 'active');

drop policy if exists shift_shares_owner_all on public.shift_shares;
create policy shift_shares_owner_all on public.shift_shares for all to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
drop policy if exists shift_shares_member_read on public.shift_shares;
create policy shift_shares_member_read on public.shift_shares for select to authenticated
  using (exists (select 1 from public.share_members m where m.id = member_id and m.member_user_id = auth.uid() and m.status = 'active'));

drop policy if exists share_challenges_owner_all on public.share_challenges;
create policy share_challenges_owner_all on public.share_challenges for all to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
drop policy if exists share_challenges_member_read on public.share_challenges;
create policy share_challenges_member_read on public.share_challenges for select to authenticated
  using (exists (select 1 from public.share_members m where m.id = member_id and m.member_user_id = auth.uid() and m.status = 'active'));

drop policy if exists share_events_owner_all on public.share_events;
create policy share_events_owner_all on public.share_events for all to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
drop policy if exists share_events_member_read on public.share_events;
create policy share_events_member_read on public.share_events for select to authenticated
  using (exists (select 1 from public.share_members m where m.id = member_id and m.member_user_id = auth.uid() and m.status = 'active'));
drop policy if exists share_events_member_update on public.share_events;
create policy share_events_member_update on public.share_events for update to authenticated
  using (exists (select 1 from public.share_members m where m.id = member_id and m.member_user_id = auth.uid() and m.status = 'active'))
  with check (exists (select 1 from public.share_members m where m.id = member_id and m.member_user_id = auth.uid() and m.status = 'active'));

create or replace function public.create_share_invite(p_email text, p_display_name text, p_colour text default '#5B6FE0')
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare v_count integer; v_member public.share_members;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select count(*) into v_count from public.share_members where owner_id=auth.uid() and status <> 'revoked';
  if v_count >= 4 then raise exception 'Maximum of four shared calendars reached'; end if;
  insert into public.share_members(owner_id,invited_email,display_name,colour)
  values(auth.uid(),lower(trim(p_email)),trim(p_display_name),coalesce(nullif(p_colour,''),'#5B6FE0'))
  on conflict(owner_id,invited_email) do update set display_name=excluded.display_name,colour=excluded.colour,status='invited',invite_token=encode(gen_random_bytes(24),'hex')
  returning * into v_member;
  return jsonb_build_object('id',v_member.id,'email',v_member.invited_email,'name',v_member.display_name,'colour',v_member.colour,'token',v_member.invite_token,'status',v_member.status);
end $$;

create or replace function public.accept_share_invite(p_token text)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare v_email text; v_member public.share_members;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  v_email := lower(coalesce(auth.jwt()->>'email',''));
  update public.share_members set member_user_id=auth.uid(),status='active',accepted_at=now(),invite_token=encode(gen_random_bytes(24),'hex')
  where invite_token=p_token and status='invited' and lower(invited_email)=v_email returning * into v_member;
  if v_member.id is null then raise exception 'Invitation is invalid, expired, or belongs to another email'; end if;
  return jsonb_build_object('id',v_member.id,'owner_id',v_member.owner_id,'name',v_member.display_name,'status',v_member.status);
end $$;

create or replace function public.get_my_share_members()
returns setof public.share_members language sql security definer set search_path = public, auth as $$
  select * from public.share_members where owner_id=auth.uid() and status <> 'revoked' order by created_at;
$$;

create or replace function public.assign_shared_shift(p_member_id uuid, p_shift_id text, p_shared boolean)
returns boolean language plpgsql security definer set search_path = public, auth as $$
begin
  if not exists(select 1 from public.share_members where id=p_member_id and owner_id=auth.uid() and status<>'revoked') then raise exception 'Shared person not found'; end if;
  if not exists(select 1 from public.shifts where id=p_shift_id and owner_id=auth.uid()) then raise exception 'Shift not found'; end if;
  if p_shared then insert into public.shift_shares(owner_id,member_id,shift_id) values(auth.uid(),p_member_id,p_shift_id) on conflict do nothing;
  else delete from public.shift_shares where owner_id=auth.uid() and member_id=p_member_id and shift_id=p_shift_id;
  end if;
  return true;
end $$;

create or replace function public.get_shared_calendar(p_member_id uuid)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare v_member public.share_members; v_result jsonb;
begin
  select * into v_member from public.share_members where id=p_member_id and status='active' and (owner_id=auth.uid() or member_user_id=auth.uid());
  if v_member.id is null then raise exception 'Access denied'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',s.id,'date',s.date,'employer',e.name,'employer_color',e.color,'start_time',s.start_time,'end_time',s.end_time,
    'hours',coalesce((s.locked_calc->>'paidHours')::numeric,0),
    'total_pay',case when v_member.show_day_amount or v_member.show_week_amount then coalesce((s.locked_calc->>'totalPay')::numeric,0) else null end
  ) order by s.date,s.start_time),'[]'::jsonb) into v_result
  from public.shift_shares ss join public.shifts s on s.id=ss.shift_id left join public.employers e on e.id=s.employer_id
  where ss.member_id=v_member.id;
  return jsonb_build_object('member',jsonb_build_object('id',v_member.id,'name',v_member.display_name,'colour',v_member.colour,'show_day_amount',v_member.show_day_amount,'show_week_amount',v_member.show_week_amount),'shifts',v_result);
end $$;

grant execute on function public.create_share_invite(text,text,text) to authenticated;
grant execute on function public.accept_share_invite(text) to authenticated;
grant execute on function public.get_my_share_members() to authenticated;
grant execute on function public.assign_shared_shift(uuid,text,boolean) to authenticated;
grant execute on function public.get_shared_calendar(uuid) to authenticated;
