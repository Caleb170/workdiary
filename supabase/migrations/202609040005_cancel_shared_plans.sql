create or replace function public.cancel_shared_plan(p_plan_id uuid)
returns boolean language plpgsql security definer set search_path=public,auth as $$
declare p public.shared_plan_proposals;
begin
  update public.shared_plan_proposals
     set status='cancelled',responded_at=now()
   where id=p_plan_id and creator_id=auth.uid() and status in ('pending','accepted')
   returning * into p;
  if p.id is null then raise exception 'Plan cannot be cancelled'; end if;
  insert into public.share_notifications(member_id,sender_id,recipient_id,kind,title,message,details)
  values(p.member_id,auth.uid(),p.recipient_id,'permission_response','Plan cancelled',p.title,jsonb_build_object('proposal_id',p.id,'date',p.plan_date,'start',p.start_time,'end',p.end_time));
  return true;
end $$;

revoke all on function public.cancel_shared_plan(uuid) from public,anon;
grant execute on function public.cancel_shared_plan(uuid) to authenticated;

-- Keep rejected/cancelled proposal history briefly for notification context,
-- then remove it opportunistically whenever a user loads their plans.
create or replace function public.get_my_shared_plans()
returns setof public.shared_plan_proposals language plpgsql security definer set search_path=public,auth as $$
begin
  delete from public.shared_plan_proposals where status in ('declined','cancelled') and responded_at < now()-interval '90 days';
  return query select * from public.shared_plan_proposals where creator_id=auth.uid() or recipient_id=auth.uid() order by plan_date,start_time;
end $$;
