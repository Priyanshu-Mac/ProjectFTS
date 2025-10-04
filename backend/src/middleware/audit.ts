import { addAuditLog } from '../db/index';

type Action = 'Read'|'Write'|'Delete';

// Redact common secrets/headers and large payloads
function sanitize(obj: any) {
  try {
    const clone = JSON.parse(JSON.stringify(obj ?? null));
    if (clone && typeof clone === 'object') {
      for (const k of Object.keys(clone)) {
        if (/password|token|secret|authorization/i.test(k)) {
          clone[k] = '[REDACTED]';
        } else if (typeof clone[k] === 'string' && clone[k].length > 2000) {
          clone[k] = clone[k].slice(0, 2000) + '…';
        }
      }
    }
    return clone;
  } catch {
    return null;
  }
}

export async function logAudit(params: { req?: any; fileId?: number | null; userId?: number | null; action: Action; details?: any }) {
  const userId = params.userId ?? params.req?.user?.id ?? null;
  const fileId = params.fileId ?? null;
  const details = sanitize({
    ...params.details,
    method: params.req?.method,
    path: params.req?.originalUrl || params.req?.url,
    ip: params.req?.ip,
  });
  try { await addAuditLog({ file_id: fileId, user_id: userId, action_type: params.action, action_details: details }); } catch {}
}
