import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function escapeHtml(value: unknown) {
  return String(value ?? "").replace(/[&<>'"]/g, character => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;",
  })[character] as string);
}

Deno.serve(async request => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    const authorization = request.headers.get("Authorization");
    if (!authorization) throw new Error("Please sign in again");

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const resendKey = Deno.env.get("RESEND_API_KEY");
    const fromEmail = Deno.env.get("WORKQUEST_FROM_EMAIL");
    if (!resendKey || !fromEmail) throw new Error("Invitation email service is not configured yet");

    const { memberId, appUrl, inviterName } = await request.json();
    if (!memberId || !/^https:\/\//.test(String(appUrl || ""))) throw new Error("Invalid invitation request");

    const client = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false },
    });
    const { data: invite, error: inviteError } = await client.rpc("send_share_invite", { p_member_id: memberId });
    if (inviteError) throw new Error(inviteError.message);

    const invitationUrl = `${String(appUrl).split("?")[0]}?share_invite=${encodeURIComponent(invite.token)}`;
    const recipientName = escapeHtml(invite.name);
    const senderName = escapeHtml(inviterName || "A WorkQuest user");
    const response = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${resendKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        from: fromEmail,
        to: [invite.email],
        subject: `${String(inviterName || "Someone").slice(0, 40)} invited you to WorkQuest`,
        html: `<!doctype html><html><body style="margin:0;background:#f4f5f7;font-family:Arial,sans-serif;color:#17191f"><table role="presentation" width="100%" cellspacing="0" cellpadding="0"><tr><td align="center" style="padding:32px 16px"><table role="presentation" width="100%" style="max-width:520px;background:#fff;border-radius:24px;overflow:hidden;box-shadow:0 16px 50px rgba(20,24,40,.12)"><tr><td style="height:8px;background:linear-gradient(90deg,#5b6fe0,#34d399)"></td></tr><tr><td style="padding:36px"><div style="font-size:12px;font-weight:800;letter-spacing:.18em;color:#5b6fe0">WORKQUEST</div><h1 style="margin:14px 0 12px;font-size:32px;line-height:1.1">A calendar was shared with you</h1><p style="margin:0 0 12px;font-size:16px;line-height:1.6">Hi ${recipientName},</p><p style="margin:0 0 24px;font-size:16px;line-height:1.6"><strong>${senderName}</strong> invited you to a private shared work calendar.</p><a href="${escapeHtml(invitationUrl)}" style="display:block;padding:16px 22px;background:#17191f;color:#fff;text-decoration:none;text-align:center;border-radius:14px;font-weight:800">View invitation</a><p style="margin:24px 0 0;font-size:13px;line-height:1.5;color:#687080">You control whether earnings are visible and can pause or end sharing at any time.</p></td></tr></table></td></tr></table></body></html>`,
      }),
    });
    if (!response.ok) throw new Error(`Email provider rejected the message (${response.status})`);
    return new Response(JSON.stringify({ ok: true, token: invite.token }), { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  } catch (error) {
    return new Response(JSON.stringify({ error: error instanceof Error ? error.message : "Could not send invitation" }), { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  }
});
