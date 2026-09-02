-- Security-definer sharing functions are callable only by signed-in users.
revoke all on function public.create_share_invite(text,text,text) from public, anon;
revoke all on function public.accept_share_invite(text) from public, anon;
revoke all on function public.get_my_share_members() from public, anon;
revoke all on function public.get_my_share_assignments() from public, anon;
revoke all on function public.get_my_shared_memberships() from public, anon;
revoke all on function public.assign_shared_shift(uuid,text,boolean) from public, anon;
revoke all on function public.get_shared_calendar(uuid) from public, anon;
revoke all on function public.update_share_member_options(uuid,boolean,boolean) from public, anon;
revoke all on function public.revoke_share_member(uuid) from public, anon;
revoke all on function public.save_share_challenge(uuid,text,numeric,date) from public, anon;
revoke all on function public.send_share_invite(uuid) from public, anon;
revoke all on function public.respond_share_amount_request(uuid,boolean,boolean) from public, anon;
revoke all on function public.set_share_paused(uuid,boolean) from public, anon;
revoke all on function public.leave_shared_calendar(uuid) from public, anon;
revoke all on function public.respond_share_challenge(uuid,boolean) from public, anon;

grant execute on function public.get_my_shared_memberships() to authenticated;
