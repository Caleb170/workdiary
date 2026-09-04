-- Personal planner events remain private unless explicitly assigned to a shared calendar.
create table if not exists public.personal_events (
  id text primary key,
  owner_id uuid not null references auth.users(id) on delete cascade,
  event_date date not null,
  event_type text not null default 'appointment',
  title text not null check(char_length(title) between 1 and 100),
  details text not null default '',
  start_time time not null,
  end_time time not null,
  colour text not null default '#5267D9',
  show_on_calendar boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.personal_event_shares (
  owner_id uuid not null references auth.users(id) on delete cascade,
  member_id uuid not null references public.share_members(id) on delete cascade,
  event_id text not null references public.personal_events(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key(member_id,event_id)
);
create index if not exists personal_events_owner_date_idx on public.personal_events(owner_id,event_date);
alter table public.personal_events enable row level security;
alter table public.personal_event_shares enable row level security;
create policy personal_events_owner_all on public.personal_events for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid());
create policy personal_event_shares_owner_all on public.personal_event_shares for all to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid());

create or replace function public.get_my_personal_event_shares()
returns table(member_id uuid,event_id text) language sql security definer set search_path=public,auth as $$
  select s.member_id,s.event_id from public.personal_event_shares s where s.owner_id=auth.uid() order by s.created_at;
$$;
create or replace function public.assign_personal_event_share(p_member_id uuid,p_event_id text,p_shared boolean)
returns boolean language plpgsql security definer set search_path=public,auth as $$
begin
  if not exists(select 1 from public.share_members where id=p_member_id and status='active' and (owner_id=auth.uid() or member_user_id=auth.uid())) then raise exception 'Shared calendar not found'; end if;
  if not exists(select 1 from public.personal_events where id=p_event_id and owner_id=auth.uid()) then raise exception 'Personal plan not found'; end if;
  if p_shared then insert into public.personal_event_shares(owner_id,member_id,event_id) values(auth.uid(),p_member_id,p_event_id) on conflict do nothing;
  else delete from public.personal_event_shares where owner_id=auth.uid() and member_id=p_member_id and event_id=p_event_id;
  end if;
  return true;
end $$;

create or replace function public.get_shared_calendar(p_member_id uuid)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare m public.share_members; shift_result jsonb; event_result jsonb; can_day boolean; can_week boolean;
begin
  select * into m from public.share_members where id=p_member_id and status='active' and (owner_id=auth.uid() or member_user_id=auth.uid());
  if m.id is null then raise exception 'Access denied'; end if;
  if m.owner_paused or m.member_paused then return jsonb_build_object('member',to_jsonb(m),'shifts','[]'::jsonb,'personal_events','[]'::jsonb); end if;
  can_day:=m.show_day_amount and m.member_approved_day;can_week:=m.show_week_amount and m.member_approved_week;
  select coalesce(jsonb_agg(jsonb_build_object('id',s.id,'date',s.date,'employer',e.name,'employer_color',e.color,'start_time',s.start_time,'end_time',s.end_time,'hours',coalesce((s.locked_calc->>'paidHours')::numeric,0),'total_pay',case when can_day or can_week then coalesce((s.locked_calc->>'totalPay')::numeric,0) else null end) order by s.date,s.start_time),'[]'::jsonb) into shift_result from public.shift_shares ss join public.shifts s on s.id=ss.shift_id left join public.employers e on e.id=s.employer_id where ss.member_id=m.id and ss.owner_id<>auth.uid();
  select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'date',p.event_date,'type',p.event_type,'title',p.title,'details',p.details,'start_time',p.start_time,'end_time',p.end_time,'colour',p.colour) order by p.event_date,p.start_time),'[]'::jsonb) into event_result from public.personal_event_shares ps join public.personal_events p on p.id=ps.event_id where ps.member_id=m.id and ps.owner_id<>auth.uid();
  return jsonb_build_object('member',to_jsonb(m),'shifts',shift_result,'personal_events',event_result);
end $$;

revoke all on function public.get_my_personal_event_shares() from public,anon;
revoke all on function public.assign_personal_event_share(uuid,text,boolean) from public,anon;
grant execute on function public.get_my_personal_event_shares() to authenticated;
grant execute on function public.assign_personal_event_share(uuid,text,boolean) to authenticated;
grant select,insert,update,delete on public.personal_events to authenticated;
