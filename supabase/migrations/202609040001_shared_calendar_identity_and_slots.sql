-- Mutual four-connection limit plus two-sided names and colours.
alter table public.share_members add column if not exists owner_label text;
alter table public.share_members add column if not exists member_label text;
alter table public.share_members add column if not exists owner_colour text not null default '#5267D9';
alter table public.share_members add column if not exists member_colour text not null default '#16A06D';

update public.share_members m set
  owner_label=coalesce(owner_label,(select p.display_name from public.profiles p where p.owner_id=m.owner_id and p.role='admin' limit 1),'Name 1'),
  member_label=coalesce(member_label,display_name,'Name 2'),
  member_colour=coalesce(nullif(member_colour,''),colour,'#16A06D');

create or replace function public.create_share_invite(p_email text, p_display_name text, p_colour text default '#16A06D')
returns jsonb language plpgsql security definer set search_path = public, auth, extensions as $$
declare v_count integer; v_member public.share_members; v_owner_name text;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if position('@' in lower(trim(p_email))) < 2 then raise exception 'A valid email is required'; end if;
  select count(*) into v_count from public.share_members where status<>'revoked' and (owner_id=auth.uid() or member_user_id=auth.uid());
  if v_count >= 4 and not exists(select 1 from public.share_members where owner_id=auth.uid() and invited_email=lower(trim(p_email)) and status<>'revoked') then raise exception 'Maximum of four shared calendars reached'; end if;
  select p.display_name into v_owner_name from public.profiles p where p.owner_id=auth.uid() and p.role='admin' limit 1;
  insert into public.share_members(owner_id,invited_email,display_name,colour,owner_label,member_label,owner_colour,member_colour)
  values(auth.uid(),lower(trim(p_email)),trim(p_display_name),coalesce(nullif(p_colour,''),'#16A06D'),coalesce(v_owner_name,'Name 1'),trim(p_display_name),'#5267D9',coalesce(nullif(p_colour,''),'#16A06D'))
  on conflict(owner_id,invited_email) do update set display_name=excluded.display_name,member_label=excluded.member_label,member_colour=excluded.member_colour,status='invited',member_user_id=null,accepted_at=null,invite_token=encode(extensions.gen_random_bytes(24),'hex')
  returning * into v_member;
  return to_jsonb(v_member)||jsonb_build_object('name',v_member.member_label,'email',v_member.invited_email,'token',v_member.invite_token);
end $$;

create or replace function public.accept_share_invite(p_token text)
returns jsonb language plpgsql security definer set search_path = public, auth, extensions as $$
declare v_email text; v_member public.share_members; v_count integer; v_member_name text;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select count(*) into v_count from public.share_members where status<>'revoked' and (owner_id=auth.uid() or member_user_id=auth.uid());
  if v_count >= 4 then raise exception 'All four shared calendar slots are already in use'; end if;
  v_email:=lower(coalesce(auth.jwt()->>'email',''));
  select p.display_name into v_member_name from public.profiles p where p.owner_id=auth.uid() and p.role='admin' limit 1;
  update public.share_members set member_user_id=auth.uid(),member_label=coalesce(v_member_name,member_label,display_name,'Name 2'),status='active',accepted_at=now(),invite_token=encode(extensions.gen_random_bytes(24),'hex')
  where invite_token=p_token and status='invited' and lower(invited_email)=v_email returning * into v_member;
  if v_member.id is null then raise exception 'Invitation is invalid, expired, or belongs to another email'; end if;
  return to_jsonb(v_member);
end $$;

drop function if exists public.get_my_shared_memberships();
create function public.get_my_shared_memberships()
returns table(id uuid, owner_id uuid, member_user_id uuid, invited_email text, owner_name text, member_name text, owner_colour text, member_colour text, requested_day boolean, requested_week boolean, approved_day boolean, approved_week boolean, paused boolean, status text)
language sql security definer set search_path = public, auth as $$
  select m.id,m.owner_id,m.member_user_id,m.invited_email,coalesce(m.owner_label,'Name 1'),coalesce(m.member_label,m.display_name,'Name 2'),m.owner_colour,m.member_colour,m.show_day_amount,m.show_week_amount,m.member_approved_day,m.member_approved_week,(m.owner_paused or m.member_paused),m.status
  from public.share_members m where m.member_user_id=auth.uid() and m.status='active' order by m.accepted_at;
$$;

create or replace function public.update_share_identity(p_member_id uuid,p_name text,p_colour text)
returns boolean language plpgsql security definer set search_path = public, auth as $$
begin
  if char_length(trim(p_name)) not between 1 and 32 or p_colour !~ '^#[0-9A-Fa-f]{6}$' then raise exception 'Enter a valid name and colour'; end if;
  update public.share_members set
    owner_label=case when owner_id=auth.uid() then trim(p_name) else owner_label end,
    owner_colour=case when owner_id=auth.uid() then p_colour else owner_colour end,
    member_label=case when member_user_id=auth.uid() then trim(p_name) else member_label end,
    member_colour=case when member_user_id=auth.uid() then p_colour else member_colour end
  where id=p_member_id and status<>'revoked' and (owner_id=auth.uid() or member_user_id=auth.uid());
  if not found then raise exception 'Shared calendar not found'; end if;
  return true;
end $$;

create or replace function public.assign_shared_shift(p_member_id uuid,p_shift_id text,p_shared boolean)
returns boolean language plpgsql security definer set search_path = public, auth as $$
begin
  if not exists(select 1 from public.share_members where id=p_member_id and status='active' and (owner_id=auth.uid() or member_user_id=auth.uid())) then raise exception 'Shared calendar not found'; end if;
  if not exists(select 1 from public.shifts where id=p_shift_id and owner_id=auth.uid()) then raise exception 'Shift not found'; end if;
  if p_shared then insert into public.shift_shares(owner_id,member_id,shift_id) values(auth.uid(),p_member_id,p_shift_id) on conflict do nothing;
  else delete from public.shift_shares where owner_id=auth.uid() and member_id=p_member_id and shift_id=p_shift_id;
  end if;
  return true;
end $$;

create or replace function public.get_shared_calendar(p_member_id uuid)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare v_member public.share_members; v_result jsonb; v_can_day boolean; v_can_week boolean;
begin
  select * into v_member from public.share_members where id=p_member_id and status='active' and (owner_id=auth.uid() or member_user_id=auth.uid());
  if v_member.id is null then raise exception 'Access denied'; end if;
  if v_member.owner_paused or v_member.member_paused then return jsonb_build_object('member',to_jsonb(v_member),'shifts','[]'::jsonb); end if;
  v_can_day:=v_member.show_day_amount and v_member.member_approved_day; v_can_week:=v_member.show_week_amount and v_member.member_approved_week;
  select coalesce(jsonb_agg(jsonb_build_object('id',s.id,'date',s.date,'employer',e.name,'employer_color',e.color,'start_time',s.start_time,'end_time',s.end_time,'hours',coalesce((s.locked_calc->>'paidHours')::numeric,0),'total_pay',case when v_can_day or v_can_week then coalesce((s.locked_calc->>'totalPay')::numeric,0) else null end) order by s.date,s.start_time),'[]'::jsonb) into v_result
  from public.shift_shares ss join public.shifts s on s.id=ss.shift_id left join public.employers e on e.id=s.employer_id
  where ss.member_id=v_member.id and ss.owner_id<>auth.uid();
  return jsonb_build_object('member',to_jsonb(v_member),'shifts',v_result);
end $$;

revoke all on function public.update_share_identity(uuid,text,text) from public,anon;
grant execute on function public.create_share_invite(text,text,text) to authenticated;
grant execute on function public.accept_share_invite(text) to authenticated;
grant execute on function public.get_my_shared_memberships() to authenticated;
grant execute on function public.update_share_identity(uuid,text,text) to authenticated;
grant execute on function public.assign_shared_shift(uuid,text,boolean) to authenticated;
grant execute on function public.get_shared_calendar(uuid) to authenticated;
