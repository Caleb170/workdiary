-- Restrict direct application tables to signed-in users. Viewer access continues through the existing viewer-session RPC flow.
DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['achievements','employers','payslips','planned_shifts','profiles','settings','shifts','tax_entries','templates','weekly_notes']
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS owner_all ON public.%I', t);
    EXECUTE format('CREATE POLICY owner_all ON public.%I FOR ALL TO authenticated USING (owner_id = (select auth.uid())) WITH CHECK (owner_id = (select auth.uid()))', t);
  END LOOP;
END $$;

-- These credential/session tables intentionally have no public table policies;
-- access is mediated by the existing server-side functions.
REVOKE ALL ON public.account_security FROM anon, authenticated;
REVOKE ALL ON public.profile_pins FROM anon, authenticated;
REVOKE ALL ON public.profile_pin_recoveries FROM anon, authenticated;
REVOKE ALL ON public.viewer_sessions FROM anon, authenticated;

-- Never allow unauthenticated callers to invoke credential-management RPCs.
REVOKE EXECUTE ON FUNCTION public.check_account_status(text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.create_profile(text,text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.reset_admin_pin(text,text,text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.setup_admin_pin(text,text,text,text,text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.set_profile_pin(uuid,text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.update_viewer_permissions(uuid,jsonb) FROM anon;
REVOKE EXECUTE ON FUNCTION public.verify_admin_pin(text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.verify_profile_pin(uuid,text) FROM anon;

-- Keep the viewer-session/data endpoints available to the app's legacy viewer flow.
-- They are token-gated inside their SECURITY DEFINER functions.
;
