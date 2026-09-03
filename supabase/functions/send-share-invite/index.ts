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
    const fromEmail = Deno.env.get("HOURFOLIO_FROM_EMAIL");
    if (!resendKey || !fromEmail) throw new Error("Invitation email service is not configured yet");

    const { memberId, appUrl, inviterName } = await request.json();
    if (!memberId || !/^https:\/\//.test(String(appUrl || ""))) throw new Error("Invalid invitation request");

    const client = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false },
    });
    const { data: invite, error: inviteError } = await client.rpc("send_share_invite", { p_member_id: memberId });
    if (inviteError) throw new Error(inviteError.message);

    const recipientName = escapeHtml(invite.name);
    const senderName = escapeHtml(inviterName || "A Hourfolio user");
    const invitationUrl = `https://hourfolio.site/?share_invite=${encodeURIComponent(invite.token)}&from=${encodeURIComponent(String(inviterName || "Someone").slice(0, 50))}&to=${encodeURIComponent(String(invite.name || "You").slice(0, 50))}`;
    const response = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${resendKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        from: fromEmail,
        reply_to: "help@hourfolio.site",
        to: [invite.email],
        subject: `${String(inviterName || "Someone").slice(0, 40)} shared an Hourfolio calendar with you`,
        html: `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head><body style="margin:0;background:#f3f5f4;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;color:#101722"><div style="display:none;max-height:0;overflow:hidden;opacity:0">${senderName} invited you to share shifts privately on Hourfolio.</div><table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background:#f3f5f4"><tr><td align="center" style="padding:34px 14px"><table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width:560px"><tr><td style="padding:0 4px 18px"><table role="presentation" cellspacing="0" cellpadding="0"><tr><td width="46" height="46" align="center" style="width:46px;height:46px;line-height:46px;border-radius:14px;background:#16a06d;color:#fff;font-family:Georgia,serif;font-size:26px;font-weight:800">H</td><td style="padding-left:12px"><div style="font-family:Georgia,serif;font-size:25px;font-weight:800;letter-spacing:-1px">Hourfolio</div><div style="color:#707987;font-size:10px;font-weight:800;letter-spacing:1.4px">PRIVATE BY DESIGN</div></td></tr></table></td></tr><tr><td style="overflow:hidden;border:1px solid #e1e6e3;border-radius:26px;background:#fff;box-shadow:0 20px 55px rgba(16,23,34,.12)"><div style="height:7px;background:#16a06d"></div><div style="padding:36px 32px 32px"><div style="color:#16865f;font-size:11px;font-weight:900;letter-spacing:1.7px">CALENDAR INVITATION</div><h1 style="margin:13px 0 12px;font-family:Georgia,serif;font-size:34px;line-height:1.12;letter-spacing:-1.2px">Hi ${recipientName}, you’re invited.</h1><p style="margin:0;color:#606a78;font-size:16px;line-height:1.6"><strong style="color:#101722">${senderName}</strong> would like to connect calendars with you on Hourfolio.</p><table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="margin:24px 0;background:#f3f7f5;border-radius:17px"><tr><td style="padding:17px;color:#47525e;font-size:13px;line-height:1.8">✓ See shared shifts in one clear calendar<br>✓ Earnings stay private unless you both agree<br>✓ Pause or end sharing whenever you want</td></tr></table><table role="presentation" width="100%" cellspacing="0" cellpadding="0"><tr><td align="center" style="border-radius:14px;background:#16a06d"><a href="${escapeHtml(invitationUrl)}" style="display:block;padding:17px 20px;color:#fff;text-decoration:none;font-size:16px;font-weight:850">View your invitation&nbsp;&nbsp;→</a></td></tr></table><p style="margin:20px 0 0;text-align:center;color:#8b939f;font-size:11px;line-height:1.55">New to Hourfolio? The invitation page will help you create your free account.</p></div></td></tr><tr><td align="center" style="padding:20px;color:#8b939f;font-size:11px;line-height:1.6">This invitation was intended for ${escapeHtml(invite.email)}.<br>If you weren’t expecting it, you can safely ignore this email.</td></tr></table></td></tr></table></body></html>`,
      }),
    });
    if (!response.ok) {
      const providerError = await response.text();
      console.error("Resend rejected invitation email", response.status, providerError);
      throw new Error(`Email provider rejected the message (${response.status})`);
    }
    return new Response(JSON.stringify({ ok: true, token: invite.token }), { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  } catch (error) {
    console.error("Invitation email failed", error instanceof Error ? error.message : error);
    return new Response(JSON.stringify({ error: error instanceof Error ? error.message : "Could not send invitation" }), { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  }
});
