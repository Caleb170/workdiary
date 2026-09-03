-- A shared calendar is a view of the owner's shifts, never a transfer.
-- Existing and future shifts are shared by default; owners can still unshare
-- individual rows through assign_shared_shift without altering the shift.

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

  insert into public.shift_shares(owner_id,member_id,shift_id)
  select auth.uid(),v_member.id,s.id from public.shifts s where s.owner_id=auth.uid()
  on conflict do nothing;

  return jsonb_build_object('id',v_member.id,'email',v_member.invited_email,'name',v_member.display_name,'colour',v_member.colour,'token',v_member.invite_token,'status',v_member.status);
end $$;

insert into public.shift_shares(owner_id,member_id,shift_id)
select m.owner_id,m.id,s.id
from public.share_members m
join public.shifts s on s.owner_id=m.owner_id
where m.status <> 'revoked'
on conflict do nothing;

create or replace function public.share_new_shift_with_calendars()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.shift_shares(owner_id,member_id,shift_id)
  select new.owner_id,m.id,new.id
  from public.share_members m
  where m.owner_id=new.owner_id and m.status <> 'revoked'
  on conflict do nothing;
  return new;
end $$;

drop trigger if exists share_new_shift_with_calendars on public.shifts;
create trigger share_new_shift_with_calendars
after insert on public.shifts
for each row execute function public.share_new_shift_with_calendars();

grant execute on function public.create_share_invite(text,text,text) to authenticated;
