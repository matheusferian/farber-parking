// SmsStore / WebhookStore backed by the service-role Supabase client. Every
// write is one of the SECURITY DEFINER functions from the migration; this
// file never builds SQL or writes tables directly.

// deno-lint-ignore-file no-explicit-any
import type { ClaimArgs, ClaimRow, Passenger, ResultArgs, SmsStore } from './service.ts';
import type { Keyword, WebhookStore } from './webhooks.ts';

type Rpc = { rpc(fn: string, args: Record<string, unknown>): PromiseLike<{ data: any; error: any }>; from(t: string): any };

async function call<T>(db: Rpc, fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await db.rpc(fn, args);
  if (error) throw new Error(`${fn} failed (${error.code || 'db'})`); // no row data in the message
  return data as T;
}

export function supabaseSmsStore(db: Rpc): SmsStore & WebhookStore {
  return {
    async getPassenger(id: number): Promise<Passenger | null> {
      const { data, error } = await db.from('passengers').select('id,name,phone,ticket,ret,car,status,return_operator,delivery_at_customs,customs_exception_requested_at,delivery_type,customs_welcome_sent,tip_received').eq('id', id).maybeSingle();
      if (error) throw new Error(`passenger lookup failed (${error.code || 'db'})`);
      return data;
    },
    async claim(a: ClaimArgs): Promise<ClaimRow> {
      const rows = await call<ClaimRow[]>(db, 'airvalet_sms_claim', {
        p_idempotency_key: a.idempotencyKey, p_passenger_id: a.passengerId, p_ticket: a.ticket,
        p_phone_e164: a.phoneE164, p_message_type: a.messageType, p_template_key: a.templateKey,
        p_template_version: a.templateVersion, p_body: a.body, p_segments: a.segments,
        p_provider: a.provider, p_sent_by: a.sentBy, p_sent_by_name: a.sentByName,
        p_device_key_hash: a.deviceKeyHash && /^[0-9a-f]{64}$/.test(a.deviceKeyHash) ? '\\x' + a.deviceKeyHash : null,
      });
      return rows[0];
    },
    markResult(a: ResultArgs): Promise<string> {
      return call<string>(db, 'airvalet_sms_mark_result', {
        p_message_id: a.messageId, p_status: a.status, p_provider_message_sid: a.sid,
        p_messaging_service_sid: a.messagingServiceSid, p_error_code: a.errorCode,
        p_error_message: a.errorMessage, p_attempts: a.attempts,
      });
    },
    async markOptedOut(phoneE164: string, source: string): Promise<void> {
      await call(db, 'airvalet_sms_mark_opted_out', { p_phone_e164: phoneE164, p_source: source });
    },
    async reconcile(): Promise<number> {
      return call<number>(db, 'airvalet_sms_reconcile', { p_minutes: 10 });
    },
    mintPassLink(passengerId: number): Promise<string | null> {
      return call<string | null>(db, 'airvalet_pass_mint', { p_passenger_id: passengerId });
    },
    applyStatus(sid, status, errorCode, errorMessage, messageId): Promise<string> {
      return call<string>(db, 'airvalet_sms_apply_status', {
        p_provider_message_sid: sid, p_status: status, p_error_code: errorCode, p_error_message: errorMessage,
        p_message_id: messageId,
      });
    },
    async recordInbound(sid, fromE164, body, messagingServiceSid, keyword: Keyword | null) {
      const rows = await call<any[]>(db, 'airvalet_sms_record_inbound', {
        p_provider_message_sid: sid, p_from_e164: fromE164, p_body: body,
        p_messaging_service_sid: messagingServiceSid, p_keyword: keyword,
      });
      return rows[0];
    },
  };
}
