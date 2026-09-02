-- Complete the compact shared-calendar API and keep all access behind RLS/auth checks.

create or replace function public.create_share_invite(p_email text, p_display_name text, p_colour text default '#5B6FE0')
returns jsonb language plpgsql security definer set search_path = public, auth, extensions as $$
declare v_count integer; v_member public.share_members;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if position('@' in lower(trim(p_email))) < 2 then raise exception 'A valid email is required'; end if;
  select count(*) into v_count from public.share_members where owner_id=auth.uid() and status <> 'revoked';
  if v_count >= 4 and not exists(select 1 from public.share_members where owner_id=auth.uid() and invited_email=lower(trim(p_email))) then
    raise exception 'Maximum of four shared calendars reached';
  end if;
  insert into public.share_members(owner_id,invited_email,display_name,colour)
  values(auth.uid(),lower(trim(p_email)),trim(p_display_name),coalesce(nullif(p_colour,''),'#5B6FE0'))
  on conflict(owner_id,invited_email) do update set
    display_name=excluded.display_name, colour=excluded.colour, status='invited',
    member_user_id=null, accepted_at=null,
    invite_token=encode(extensions.gen_random_bytes(24),'hex')
  returning * into v_member;
  return jsonb_build_object('id',v_member.id,'email',v_member.invited_email,'name',v_member.display_name,'colour',v_member.colour,'token',v_member.invite_token,'status',v_member.status);
end $$;

create or replace function public.accept_share_invite(p_token text)
returns jsonb language plpgsql security definer set search_path = public, auth, extensions as $$
declare v_email text; v_member public.share_members;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  v_email := lower(coalesce(auth.jwt()->>'email',''));
  update public.share_members set member_user_id=auth.uid(),status='active',accepted_at=now(),invite_token=encode(extensions.gen_random_bytes(24),'hex')
  where invite_token=p_token and status='invited' and lower(invited_email)=v_email returning * into v_member;
  if v_member.id is null then raise exception 'Invitation is invalid, expired, or belongs to another email'; end if;
  return jsonb_build_object('id',v_member.id,'owner_id',v_member.owner_id,'name',v_member.display_name,'status',v_member.status);
end $$;

create or replace function public.get_my_share_assignments()
returns table(member_id uuid, shift_id text) language sql security definer set search_path = public, auth as $$
  select ss.member_id, ss.shift_id from public.shift_shares ss where ss.owner_id=auth.uid() order by ss.created_at;
$$;

create or replace function public.get_my_shared_memberships()
returns table(id uuid, owner_id uuid, display_name text, colour text, show_day_amount boolean, show_week_amount boolean)
language sql security definer set search_path = public, auth as $$
  select m.id,m.owner_id,m.display_name,m.colour,m.show_day_amount,m.show_week_amount
  from public.share_members m where m.member_user_id=auth.uid() and m.status='active' order by m.accepted_at;
$$;

create or replace function public.update_share_member_options(p_member_id uuid, p_show_day boolean, p_show_week boolean)
returns boolean language plpgsql security definer set search_path = public, auth as $$
begin
  update public.share_members set show_day_amount=coalesce(p_show_day,false),show_week_amount=coalesce(p_show_week,false)
  where id=p_member_id and owner_id=auth.uid() and status<>'revoked';
  if not found then raise exception 'Shared person not found'; end if;
  return true;
end $$;

create or replace function public.revoke_share_member(p_member_id uuid)
returns boolean language plpgsql security definer set search_path = public, auth as $$
begin
  update public.share_members set status='revoked',member_user_id=null where id=p_member_id and owner_id=auth.uid() and status<>'revoked';
  if not found then raise exception 'Shared person not found'; end if;
  return true;
end $$;

create or replace function public.save_share_challenge(p_member_id uuid, p_type text, p_target numeric, p_week_start date)
returns uuid language plpgsql security definer set search_path = public, auth as $$
declare v_id uuid;
begin
  if p_type not in ('shifts','earnings') or p_target <= 0 then raise exception 'Invalid challenge'; end if;
  if not exists(select 1 from public.share_members where id=p_member_id and owner_id=auth.uid() and status<>'revoked') then raise exception 'Shared person not found'; end if;
  insert into public.share_challenges(owner_id,member_id,challenge_type,target,week_start)
  values(auth.uid(),p_member_id,p_type,p_target,p_week_start)
  on conflict(member_id,challenge_type,week_start) do update set target=excluded.target
  returning id into v_id;
  return v_id;
end $$;

grant execute on function public.get_my_share_assignments() to authenticated;
grant execute on function public.get_my_shared_memberships() to authenticated;
grant execute on function public.update_share_member_options(uuid,boolean,boolean) to authenticated;
grant execute on function public.revoke_share_member(uuid) to authenticated;
grant execute on function public.save_share_challenge(uuid,text,numeric,date) to authenticated;
