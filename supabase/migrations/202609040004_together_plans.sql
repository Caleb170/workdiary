-- Compact shared plan proposals. No polling or heavy background processing required.
create table if not exists public.shared_plan_proposals (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references public.share_members(id) on delete cascade,
  creator_id uuid not null references auth.users(id) on delete cascade,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  title text not null check(char_length(title) between 1 and 100),
  plan_date date not null,
  start_time time not null,
  end_time time not null,
  location text not null default '',
  note text not null default '',
  colour text not null default '#5267D9',
  status text not null default 'pending' check(status in ('pending','accepted','declined','cancelled')),
  created_at timestamptz not null default now(),
  responded_at timestamptz
);
create index if not exists shared_plan_people_idx on public.shared_plan_proposals(creator_id,recipient_id,plan_date);
alter table public.shared_plan_proposals enable row level security;
create policy shared_plan_people_read on public.shared_plan_proposals for select to authenticated using(creator_id=auth.uid() or recipient_id=auth.uid());

create or replace function public.create_shared_plan(p_member_id uuid,p_title text,p_date date,p_start time,p_end time,p_location text default '',p_note text default '',p_colour text default '#5267D9')
returns uuid language plpgsql security definer set search_path=public,auth as $$
declare m public.share_members; recipient uuid; new_id uuid;
begin
  select * into m from public.share_members where id=p_member_id and status='active' and not(owner_paused or member_paused) and (owner_id=auth.uid() or member_user_id=auth.uid());
  if m.id is null then raise exception 'Active shared calendar not found'; end if;
  if p_end<=p_start then raise exception 'Finish time must be after start time'; end if;
  recipient:=case when m.owner_id=auth.uid() then m.member_user_id else m.owner_id end;
  insert into public.shared_plan_proposals(member_id,creator_id,recipient_id,title,plan_date,start_time,end_time,location,note,colour) values(m.id,auth.uid(),recipient,trim(p_title),p_date,p_start,p_end,left(coalesce(p_location,''),140),left(coalesce(p_note,''),500),p_colour) returning id into new_id;
  insert into public.share_notifications(member_id,sender_id,recipient_id,kind,title,message,details) values(m.id,auth.uid(),recipient,'permission_request','New plan proposed',trim(p_title)||' · '||p_date::text,jsonb_build_object('proposal_id',new_id,'date',p_date,'start',p_start,'end',p_end));
  return new_id;
end $$;
create or replace function public.get_my_shared_plans()
returns setof public.shared_plan_proposals language sql security definer set search_path=public,auth as $$ select * from public.shared_plan_proposals where creator_id=auth.uid() or recipient_id=auth.uid() order by plan_date,start_time $$;
create or replace function public.respond_shared_plan(p_plan_id uuid,p_accept boolean)
returns boolean language plpgsql security definer set search_path=public,auth as $$
declare p public.shared_plan_proposals;
begin
  update public.shared_plan_proposals set status=case when p_accept then 'accepted' else 'declined' end,responded_at=now() where id=p_plan_id and recipient_id=auth.uid() and status='pending' returning * into p;
  if p.id is null then raise exception 'Pending plan not found'; end if;
  insert into public.share_notifications(member_id,sender_id,recipient_id,kind,title,message,details) values(p.member_id,auth.uid(),p.creator_id,'permission_response',case when p_accept then 'Plan accepted' else 'Plan declined' end,p.title,jsonb_build_object('proposal_id',p.id,'date',p.plan_date,'start',p.start_time,'end',p.end_time));
  return true;
end $$;
revoke all on function public.create_shared_plan(uuid,text,date,time,time,text,text,text) from public,anon;
revoke all on function public.get_my_shared_plans() from public,anon;
revoke all on function public.respond_shared_plan(uuid,boolean) from public,anon;
grant execute on function public.create_shared_plan(uuid,text,date,time,time,text,text,text) to authenticated;
grant execute on function public.get_my_shared_plans() to authenticated;
grant execute on function public.respond_shared_plan(uuid,boolean) to authenticated;
