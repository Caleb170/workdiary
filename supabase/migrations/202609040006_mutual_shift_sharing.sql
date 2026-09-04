-- Make an accepted shared calendar genuinely two-way. Both people's existing
-- and future shifts attach to the same connection; get_shared_calendar still
-- returns only the other person's rows to each caller.

insert into public.shift_shares(owner_id,member_id,shift_id)
select s.owner_id,m.id,s.id
from public.share_members m
join public.shifts s on s.owner_id in (m.owner_id,m.member_user_id)
where m.status='active' and m.member_user_id is not null
on conflict do nothing;

create or replace function public.share_new_shift_with_calendars()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  insert into public.shift_shares(owner_id,member_id,shift_id)
  select new.owner_id,m.id,new.id
  from public.share_members m
  where m.status='active' and (m.owner_id=new.owner_id or m.member_user_id=new.owner_id)
  on conflict do nothing;
  return new;
end $$;

drop trigger if exists share_new_shift_with_calendars on public.shifts;
create trigger share_new_shift_with_calendars
after insert on public.shifts
for each row execute function public.share_new_shift_with_calendars();

create or replace function public.accept_share_invite(p_token text)
returns jsonb language plpgsql security definer set search_path=public,auth,extensions as $$
declare v_email text; v_member public.share_members; v_count integer; v_member_name text;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select count(*) into v_count from public.share_members where status<>'revoked' and (owner_id=auth.uid() or member_user_id=auth.uid());
  if v_count >= 4 then raise exception 'All four shared calendar slots are already in use'; end if;
  v_email:=lower(coalesce(auth.jwt()->>'email',''));
  select p.display_name into v_member_name from public.profiles p where p.owner_id=auth.uid() and p.role='admin' limit 1;
  update public.share_members
     set member_user_id=auth.uid(),member_label=coalesce(v_member_name,member_label,display_name,'Name 2'),status='active',accepted_at=now(),invite_token=encode(extensions.gen_random_bytes(24),'hex')
   where invite_token=p_token and status='invited' and lower(invited_email)=v_email
   returning * into v_member;
  if v_member.id is null then raise exception 'Invitation is invalid, expired, or belongs to another email'; end if;

  insert into public.shift_shares(owner_id,member_id,shift_id)
  select s.owner_id,v_member.id,s.id from public.shifts s where s.owner_id in (v_member.owner_id,auth.uid())
  on conflict do nothing;
  return to_jsonb(v_member);
end $$;

revoke all on function public.accept_share_invite(text) from public,anon;
grant execute on function public.accept_share_invite(text) to authenticated;
