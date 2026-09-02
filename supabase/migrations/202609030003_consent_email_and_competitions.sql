-- Mutual-consent sharing, invite cooldowns and opt-in weekly competitions.
alter table public.share_members add column if not exists last_invited_at timestamptz;
alter table public.share_members add column if not exists member_approved_day boolean not null default false;
alter table public.share_members add column if not exists member_approved_week boolean not null default false;
alter table public.share_members add column if not exists owner_paused boolean not null default false;
alter table public.share_members add column if not exists member_paused boolean not null default false;
alter table public.share_challenges add column if not exists member_accepted boolean not null default false;
alter table public.share_challenges add column if not exists member_paused boolean not null default false;

create or replace function public.send_share_invite(p_member_id uuid)
returns jsonb language plpgsql security definer set search_path = public, auth, extensions as $$
declare v_member public.share_members; v_wait integer;
begin
  select * into v_member from public.share_members where id=p_member_id and owner_id=auth.uid() and status='invited' for update;
  if v_member.id is null then raise exception 'Invitation is unavailable or already accepted'; end if;
  if v_member.last_invited_at is not null and v_member.last_invited_at > now()-interval '5 minutes' then
    v_wait:=ceil(extract(epoch from (v_member.last_invited_at+interval '5 minutes'-now()))/60);
    raise exception 'Please wait % minute(s) before sending this invitation again',greatest(v_wait,1);
  end if;
  update public.share_members set last_invited_at=now(),invite_token=encode(extensions.gen_random_bytes(24),'hex') where id=v_member.id returning * into v_member;
  return jsonb_build_object('id',v_member.id,'email',v_member.invited_email,'name',v_member.display_name,'token',v_member.invite_token,'sent_at',v_member.last_invited_at);
end $$;

create or replace function public.update_share_member_options(p_member_id uuid, p_show_day boolean, p_show_week boolean)
returns boolean language plpgsql security definer set search_path = public, auth as $$
begin
  update public.share_members set
    member_approved_day=case when show_day_amount is distinct from coalesce(p_show_day,false) then false else member_approved_day end,
    member_approved_week=case when show_week_amount is distinct from coalesce(p_show_week,false) then false else member_approved_week end,
    show_day_amount=coalesce(p_show_day,false),show_week_amount=coalesce(p_show_week,false)
  where id=p_member_id and owner_id=auth.uid() and status<>'revoked';
  if not found then raise exception 'Shared person not found'; end if;
  return true;
end $$;

create or replace function public.respond_share_amount_request(p_member_id uuid, p_allow_day boolean, p_allow_week boolean)
returns boolean language plpgsql security definer set search_path = public, auth as $$
begin
  update public.share_members set
    member_approved_day=show_day_amount and coalesce(p_allow_day,false),
    member_approved_week=show_week_amount and coalesce(p_allow_week,false)
  where id=p_member_id and member_user_id=auth.uid() and status='active';
  if not found then raise exception 'Shared calendar not found'; end if;
  return true;
end $$;

create or replace function public.set_share_paused(p_member_id uuid, p_paused boolean)
returns boolean language plpgsql security definer set search_path = public, auth as $$
begin
  update public.share_members set
    owner_paused=case when owner_id=auth.uid() then coalesce(p_paused,false) else owner_paused end,
    member_paused=case when member_user_id=auth.uid() then coalesce(p_paused,false) else member_paused end
  where id=p_member_id and status='active' and (owner_id=auth.uid() or member_user_id=auth.uid());
  if not found then raise exception 'Shared calendar not found'; end if;
  return true;
end $$;

create or replace function public.leave_shared_calendar(p_member_id uuid)
returns boolean language plpgsql security definer set search_path = public, auth as $$
begin
  update public.share_members set status='revoked',member_user_id=null
  where id=p_member_id and status<>'revoked' and (owner_id=auth.uid() or member_user_id=auth.uid());
  if not found then raise exception 'Shared calendar not found'; end if;
  return true;
end $$;

drop function if exists public.get_my_shared_memberships();
create function public.get_my_shared_memberships()
returns table(id uuid, owner_id uuid, display_name text, colour text, requested_day boolean, requested_week boolean, approved_day boolean, approved_week boolean, paused boolean)
language sql security definer set search_path = public, auth as $$
  select m.id,m.owner_id,m.display_name,m.colour,m.show_day_amount,m.show_week_amount,m.member_approved_day,m.member_approved_week,(m.owner_paused or m.member_paused)
  from public.share_members m where m.member_user_id=auth.uid() and m.status='active' order by m.accepted_at;
$$;

create or replace function public.get_shared_calendar(p_member_id uuid)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare v_member public.share_members; v_result jsonb; v_can_day boolean; v_can_week boolean;
begin
  select * into v_member from public.share_members where id=p_member_id and status='active' and (owner_id=auth.uid() or member_user_id=auth.uid());
  if v_member.id is null then raise exception 'Access denied'; end if;
  if v_member.owner_paused or v_member.member_paused then
    return jsonb_build_object('member',jsonb_build_object('id',v_member.id,'name',v_member.display_name,'paused',true),'shifts','[]'::jsonb);
  end if;
  v_can_day:=v_member.show_day_amount and v_member.member_approved_day;
  v_can_week:=v_member.show_week_amount and v_member.member_approved_week;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',s.id,'date',s.date,'employer',e.name,'employer_color',e.color,'start_time',s.start_time,'end_time',s.end_time,
    'hours',coalesce((s.locked_calc->>'paidHours')::numeric,0),
    'total_pay',case when v_can_day or v_can_week then coalesce((s.locked_calc->>'totalPay')::numeric,0) else null end
  ) order by s.date,s.start_time),'[]'::jsonb) into v_result
  from public.shift_shares ss join public.shifts s on s.id=ss.shift_id left join public.employers e on e.id=s.employer_id where ss.member_id=v_member.id;
  return jsonb_build_object('member',jsonb_build_object('id',v_member.id,'name',v_member.display_name,'colour',v_member.colour,'requested_day',v_member.show_day_amount,'requested_week',v_member.show_week_amount,'approved_day',v_member.member_approved_day,'approved_week',v_member.member_approved_week,'paused',false),'shifts',v_result);
end $$;

create or replace function public.respond_share_challenge(p_challenge_id uuid, p_accept boolean)
returns boolean language plpgsql security definer set search_path = public, auth as $$
begin
  update public.share_challenges c set member_accepted=coalesce(p_accept,false),member_paused=false
  where c.id=p_challenge_id and exists(select 1 from public.share_members m where m.id=c.member_id and m.member_user_id=auth.uid() and m.status='active');
  if not found then raise exception 'Competition not found'; end if;
  return true;
end $$;

grant execute on function public.send_share_invite(uuid) to authenticated;
grant execute on function public.respond_share_amount_request(uuid,boolean,boolean) to authenticated;
grant execute on function public.set_share_paused(uuid,boolean) to authenticated;
grant execute on function public.leave_shared_calendar(uuid) to authenticated;
grant execute on function public.respond_share_challenge(uuid,boolean) to authenticated;
