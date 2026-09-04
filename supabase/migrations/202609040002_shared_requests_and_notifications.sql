-- Durable, low-volume notifications for mutual shared calendars.
create table if not exists public.share_notifications (
  id bigint generated always as identity primary key,
  member_id uuid not null references public.share_members(id) on delete cascade,
  sender_id uuid not null references auth.users(id) on delete cascade,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  kind text not null check(kind in ('permission_request','permission_response','shift_added','shift_edited','shift_removed')),
  title text not null,
  message text not null default '',
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  seen_at timestamptz
);
create index if not exists share_notifications_recipient_idx on public.share_notifications(recipient_id,created_at desc) where seen_at is null;
alter table public.share_notifications enable row level security;
drop policy if exists share_notifications_recipient_read on public.share_notifications;
create policy share_notifications_recipient_read on public.share_notifications for select to authenticated using(recipient_id=auth.uid());
drop policy if exists share_notifications_recipient_update on public.share_notifications;
create policy share_notifications_recipient_update on public.share_notifications for update to authenticated using(recipient_id=auth.uid()) with check(recipient_id=auth.uid());

create or replace function public.update_share_member_options(p_member_id uuid,p_show_day boolean,p_show_week boolean)
returns boolean language plpgsql security definer set search_path=public,auth as $$
declare m public.share_members; requester text;
begin
  update public.share_members set member_approved_day=case when show_day_amount is distinct from coalesce(p_show_day,false) then false else member_approved_day end,member_approved_week=case when show_week_amount is distinct from coalesce(p_show_week,false) then false else member_approved_week end,show_day_amount=coalesce(p_show_day,false),show_week_amount=coalesce(p_show_week,false)
  where id=p_member_id and owner_id=auth.uid() and status='active' returning * into m;
  if m.id is null then raise exception 'Active shared calendar not found'; end if;
  requester:=coalesce(m.owner_label,'Your connection');
  if (p_show_day or p_show_week) and m.member_user_id is not null then
    insert into public.share_notifications(member_id,sender_id,recipient_id,kind,title,message,details)
    values(m.id,auth.uid(),m.member_user_id,'permission_request',requester||' requested earnings access',concat_ws(' and ',case when p_show_day then 'daily totals' end,case when p_show_week then 'weekly totals' end),jsonb_build_object('day',p_show_day,'week',p_show_week));
  end if;
  return true;
end $$;

create or replace function public.respond_share_amount_request(p_member_id uuid,p_allow_day boolean,p_allow_week boolean)
returns boolean language plpgsql security definer set search_path=public,auth as $$
declare m public.share_members; responder text;
begin
  update public.share_members set member_approved_day=show_day_amount and coalesce(p_allow_day,false),member_approved_week=show_week_amount and coalesce(p_allow_week,false)
  where id=p_member_id and member_user_id=auth.uid() and status='active' returning * into m;
  if m.id is null then raise exception 'Shared calendar not found'; end if;
  responder:=coalesce(m.member_label,'Your connection');
  insert into public.share_notifications(member_id,sender_id,recipient_id,kind,title,message,details)
  values(m.id,auth.uid(),m.owner_id,'permission_response',responder||' updated earnings access',case when p_allow_day or p_allow_week then 'Permission choices were saved' else 'Earnings sharing was declined' end,jsonb_build_object('day',p_allow_day,'week',p_allow_week));
  return true;
end $$;

create or replace function public.create_share_shift_notification(p_member_id uuid,p_kind text,p_title text,p_message text,p_details jsonb default '{}'::jsonb)
returns boolean language plpgsql security definer set search_path=public,auth as $$
declare m public.share_members; recipient uuid;
begin
  if p_kind not in ('shift_added','shift_edited','shift_removed') then raise exception 'Invalid notification type'; end if;
  select * into m from public.share_members where id=p_member_id and status='active' and (owner_id=auth.uid() or member_user_id=auth.uid());
  if m.id is null then raise exception 'Shared calendar not found'; end if;
  recipient:=case when m.owner_id=auth.uid() then m.member_user_id else m.owner_id end;
  if recipient is null then return false; end if;
  insert into public.share_notifications(member_id,sender_id,recipient_id,kind,title,message,details) values(m.id,auth.uid(),recipient,p_kind,left(p_title,100),left(coalesce(p_message,''),240),coalesce(p_details,'{}'::jsonb));
  return true;
end $$;

create or replace function public.get_unseen_share_notifications()
returns setof public.share_notifications language sql security definer set search_path=public,auth as $$ select * from public.share_notifications where recipient_id=auth.uid() and seen_at is null order by created_at desc limit 20 $$;
create or replace function public.mark_share_notifications_seen(p_ids bigint[])
returns boolean language plpgsql security definer set search_path=public,auth as $$ begin update public.share_notifications set seen_at=now() where recipient_id=auth.uid() and id=any(p_ids);return true;end $$;

revoke all on function public.create_share_shift_notification(uuid,text,text,text,jsonb) from public,anon;
revoke all on function public.get_unseen_share_notifications() from public,anon;
revoke all on function public.mark_share_notifications_seen(bigint[]) from public,anon;
grant execute on function public.update_share_member_options(uuid,boolean,boolean) to authenticated;
grant execute on function public.respond_share_amount_request(uuid,boolean,boolean) to authenticated;
grant execute on function public.create_share_shift_notification(uuid,text,text,text,jsonb) to authenticated;
grant execute on function public.get_unseen_share_notifications() to authenticated;
grant execute on function public.mark_share_notifications_seen(bigint[]) to authenticated;
