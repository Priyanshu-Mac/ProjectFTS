import { Router } from 'express';
import { FileCreateSchema, FileListQuery, FileListQueryType } from '../schemas/file';
import { createFile, listFiles, getFile, addEvent, computeSlaStatus, generateFileNo, refreshFileSla, getUserById, listEvents, setFileShareToken, getOrCreateShareToken, findFileIdByToken, getShareToken } from '../db/index';
import { EchoSchema } from '../schemas/echo';
import { requireAuth } from '../middleware/auth';
import jwt from 'jsonwebtoken';
import { findUserByUsername } from '../db/index';
import { logAudit } from '../middleware/audit';

const router = Router();

// Require authentication for creating files so created_by is reliably set
router.post('/', requireAuth as any, async (req, res) => {
  const parsed = FileCreateSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: parsed.error.format() });
  const payload = parsed.data;
  // created_by is set from authenticated user when available
  // since requireAuth runs, req.user should be present; fall back to null defensively
  const createdBy = (req as any).user?.id ?? null;

  // With schema refine, forward_to_officer_id is enforced unless save_as_draft=true.
  // Create file record. If save_as_draft is true, don't start SLA or create initial event
  const rec = await createFile({
    subject: payload.subject,
    notesheet_title: payload.notesheet_title,
    owning_office_id: payload.owning_office_id,
    category_id: payload.category_id,
    sla_policy_id: (payload as any).sla_policy_id,
    priority: (payload as any).priority,
    confidentiality: (payload as any).confidentiality,
    date_initiated: payload.date_initiated,
    date_received_accounts: payload.date_received_accounts,
    current_holder_user_id: payload.save_as_draft ? null : payload.forward_to_officer_id,
    created_by: createdBy,
    // attachments removed
    // Drafts should not start SLA and should not create initial movement
    status: payload.save_as_draft ? 'Draft' : 'WithOfficer',
  });

  // create initial event only if not a draft
  if (!payload.save_as_draft) {
    // record the creator as the from_user for the initial forward event
    await addEvent(rec.id, { from_user_id: createdBy ?? null, to_user_id: payload.forward_to_officer_id, action_type: 'Forward', remarks: payload.remarks });
  }

  // quick checklist
  const checklist = {
    initiation_date_present: !!payload.date_initiated,
    has_attachments: false,
    priority_set: !!(payload as any).priority,
  };

  // duplicate finder: naive search for similar subjects in last 30 days
  const thirtyDaysAgo = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString();
  const dupList = await listFiles({ q: payload.subject, date_from: thirtyDaysAgo, limit: 10 });

  try { await logAudit({ req, userId: createdBy, fileId: rec.id, action: 'Write', details: { route: 'POST /files', payload } }); } catch {}
  res.status(201).json({ file: rec, checklist, duplicates: dupList.results });
});

// Update a Draft file: allow the creator to edit and set forward_to_officer_id later, then submit to start movement and SLA
router.put('/:id', requireAuth as any, async (req, res) => {
  const raw = (req.params as any).id;
  const id = Number(raw);
  if (!raw || Number.isNaN(id)) return res.status(400).json({ error: 'invalid id' });

  const f = await getFile(id);
  if (!f) return res.status(404).json({ error: 'not found' });

  const userId = Number((req as any).user?.id || 0);
  const isCreator = userId && Number(f.created_by ?? 0) === userId;
  if (!isCreator) return res.status(403).json({ error: 'only creator can edit draft' });
  if (String(f.status).toLowerCase() !== 'draft') return res.status(400).json({ error: 'only drafts can be edited' });

  // Accept partial fields for editing draft; basic whitelist
  const body = req.body || {};
  const next: any = {};
  // Only include columns that actually exist in files table; exclude priority and forward_to_officer_id
  const allowed = ['subject','notesheet_title','owning_office_id','category_id','confidentiality','date_initiated','date_received_accounts','sla_policy_id'];
  for (const k of allowed) if (k in body) next[k] = body[k];

  // If the user provided forward_to_officer_id and wants to submit, we can optionally move out of Draft
  const submit = String(body.submit || '').toLowerCase() === 'true';

  // Build dynamic SQL for updates
  const sets: string[] = [];
  const vals: any[] = [];
  let idx = 1;
  for (const [k, v] of Object.entries(next)) {
    sets.push(`${k} = $${idx++}`);
    vals.push(v);
  }
  if (!sets.length && !submit) return res.json({ file: f });

  // If submitting and forward_to_officer_id present, also set status and holder
  let submitting = false;
  if (submit) {
    const providedFwd = ('forward_to_officer_id' in body) ? (body.forward_to_officer_id ? Number(body.forward_to_officer_id) : null) : undefined;
    if ((providedFwd === undefined || providedFwd === null) && !f.current_holder_user_id) {
      return res.status(400).json({ error: 'forward_to_officer_id is required to submit draft' });
    }
    submitting = true;
    sets.push(`status = $${idx++}`);
    vals.push('WithOfficer');
    const holder = (providedFwd !== undefined ? providedFwd : f.current_holder_user_id) ?? null;
    sets.push(`current_holder_user_id = $${idx++}`);
    vals.push(holder);
  }
  vals.push(id);

  const sql = `UPDATE files SET ${sets.join(', ')} WHERE id = $${idx} RETURNING *`;
  // lazy require pg to run this custom update; if no pg, send 501
  if (!process.env.DATABASE_URL) {
    return res.status(501).json({ error: 'Draft edit requires Postgres adapter in this build' });
  }
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const { Pool } = require('pg');
  const pool = new Pool({ connectionString: process.env.DATABASE_URL });
  const r = await pool.query(sql, vals);
  const updated = r.rows[0];

  // If submitting, create initial Forward event now to start SLA/movement
  if (submitting) {
    const to = (('forward_to_officer_id' in body) ? (body.forward_to_officer_id ? Number(body.forward_to_officer_id) : null) : f.current_holder_user_id) ?? null;
    await addEvent(id, { from_user_id: userId ?? null, to_user_id: to, action_type: 'Forward', remarks: body.remarks ?? null });
  }

  try { await logAudit({ req, userId, fileId: id, action: 'Write', details: { route: 'PUT /files/:id', submit } }); } catch {}
  return res.json({ file: updated });
});

router.get('/', async (req, res) => {
  const parsed = FileListQuery.safeParse(req.query);
  if (!parsed.success) {
    return res.status(400).json({ error: parsed.error.format() });
  }
  const q = parsed.data as FileListQueryType;
  const list = await listFiles(q as any);
  // Optional enrichment: includeSla=true will compute live SLA for each row and override persisted fields in the JSON response
  const includeSlaRaw = (req.query as any).includeSla ?? (req.query as any).include_sla;
  // Default includeSla to true unless explicitly set to false by the caller
  const flag = includeSlaRaw === undefined
    ? true
    : String(includeSlaRaw).toLowerCase() === 'true';
  if (!flag) { try { await logAudit({ req, action: 'Read', details: { route: 'GET /files', query: q } }); } catch {}; return res.json(list); }
  try {
    const persist = String((req.query as any).persistSla || (req.query as any).persist_sla || '').toLowerCase() === 'true';
    if (persist) {
      try {
        await Promise.all((list.results || []).map((row: any) => refreshFileSla(Number(row.id)).catch(() => false)));
      } catch {}
    }
    const enriched = await Promise.all((list.results || []).map(async (row: any) => {
      try {
        const sla = await computeSlaStatus(Number(row.id));
        if (sla) {
          let hasReason = false;
          if (String(sla.status) === 'Breach') {
            try {
              const evs = await listEvents(Number(row.id));
              hasReason = Array.isArray(evs) && evs.some((e: any) => String(e.action_type || '') === 'SLAReason');
            } catch {}
          }
          return {
            ...row,
            // override with live snapshot
            sla_minutes: sla.sla_minutes,
            sla_consumed_minutes: sla.consumed_minutes,
            sla_percent: sla.percent_used,
            sla_status: sla.status,
            sla_remaining_minutes: sla.remaining_minutes,
            sla_warning_pct: sla.warning_pct,
            sla_escalate_pct: sla.escalate_pct,
            sla_pause_on_hold: sla.pause_on_hold,
            sla_policy_name: sla.policy_name,
            sla_policy_id_resolved: sla.policy_id,
            calc_mode: sla.calc_mode,
            has_sla_reason: hasReason,
          };
        }
      } catch {}
      return row;
    }));
    try { await logAudit({ req, action: 'Read', details: { route: 'GET /files', query: q, includeSla: true } }); } catch {}
    return res.json({ ...list, results: enriched });
  } catch (e: any) {
    // fall back to original list on errors
    try { await logAudit({ req, action: 'Read', details: { route: 'GET /files', query: q, includeSla: true, error: e?.message } }); } catch {}
    return res.json(list);
  }
});

router.get('/next-number', async (_req, res) => {
  try {
    const no = await generateFileNo();
    res.json({ file_no: no });
  } catch (e: any) {
    res.status(500).json({ error: e?.message ?? 'failed to generate' });
  }
});

router.get('/:id', requireAuth as any, async (req, res) => {
  const raw = (req.params as any).id;
  const id = Number(raw);
  if (!raw || Number.isNaN(id)) return res.status(400).json({ error: 'invalid id' });
  // Explicitly ignore token query param on protected route and do not allow it to alter access
  if ((req.query as any)?.t) {
    // Force protected access path; token-only path is /files/shared/*
    return res.status(403).json({ error: 'forbidden' });
  }
  const f = await getFile(id);
  if (!f) return res.status(404).json({ error: 'not found' });
  // Authorization: Only the file creator, COF, or Admin can view a file by id
  try {
    const user = (req as any).user;
    const viewerId = Number(user?.id ?? 0);
    let role = '';
    try {
      const u = await getUserById(viewerId);
      role = String(u?.role || '').toUpperCase();
    } catch {}
    const isPrivileged = role === 'COF' || role === 'ADMIN';
    const isCreator = viewerId && Number(f.created_by ?? 0) === viewerId;
    if (!isCreator && !isPrivileged) {
      return res.status(403).json({ error: 'forbidden' });
    }
  } catch {
    return res.status(403).json({ error: 'forbidden' });
  }
  // persist SLA snapshot into files.* columns so the DB reflects latest
  try { await refreshFileSla(id); } catch {}
  // enrich with computed SLA snapshot
  try {
    const sla = await computeSlaStatus(id as any);
    if (sla) {
      let hasReason = false;
      if (String(sla.status) === 'Breach') {
        try { const evs = await listEvents(id); hasReason = Array.isArray(evs) && evs.some((e: any) => String(e.action_type || '') === 'SLAReason'); } catch {}
      }
      const body = {
        ...f,
        sla_minutes: sla.sla_minutes,
        sla_consumed_minutes: sla.consumed_minutes,
        sla_percent: sla.percent_used,
        sla_status: sla.status,
        sla_remaining_minutes: sla.remaining_minutes,
        // extra policy context
        sla_warning_pct: sla.warning_pct,
        sla_escalate_pct: sla.escalate_pct,
        sla_pause_on_hold: sla.pause_on_hold,
        sla_policy_name: sla.policy_name,
        sla_policy_id_resolved: sla.policy_id,
        has_sla_reason: hasReason,
      };
      try { await logAudit({ req, fileId: id, action: 'Read', details: { route: 'GET /files/:id', includeSla: true } }); } catch {}
      return res.json(body);
    }
  } catch (e) {
    // ignore SLA compute errors and return base file
  }
  try { await logAudit({ req, fileId: id, action: 'Read', details: { route: 'GET /files/:id' } }); } catch {}
  res.json(f);
});

// Create a share token for a file. Caller must be authenticated and be authorized (creator, current holder, AccountsOfficer, COF, Admin).
router.post('/:id/token', requireAuth as any, async (req, res) => {
  const raw = (req.params as any).id;
  const id = Number(raw);
  if (!raw || Number.isNaN(id)) return res.status(400).json({ error: 'invalid id' });
  const f = await getFile(id);
  if (!f) return res.status(404).json({ error: 'not found' });

  // req.user is set by requireAuth middleware
  const user = (req as any).user;
  // Authorization: allow creator, current holder, or privileged roles (AccountsOfficer, COF, Admin)
  try {
    const viewer = await getUserById(Number(user?.id || 0));
    const role = String(viewer?.role || '').toUpperCase();
    const isPrivileged = role === 'COF' || role === 'ADMIN' || role === 'ACCOUNTSOFFICER' || role === 'ACCOUNTS_OFFICER';
    const isCreator = Number(user?.id) === Number(f.created_by ?? 0);
    const isHolder = Number(user?.id) === Number(f.current_holder_user_id ?? 0);
    if (!isPrivileged && !isCreator && !isHolder) {
      return res.status(403).json({ error: 'forbidden' });
    }
  } catch {
    return res.status(403).json({ error: 'forbidden' });
  }

  // Durable opaque token stored in DB. If a token exists, return it; otherwise create.
  try {
    // prefer stable tokens; caller can hit this repeatedly without changing token unless they choose to regenerate elsewhere
    const token = await getOrCreateShareToken(id, Number(user.id) || null, Boolean((req.query as any).force));
    try { await logAudit({ req, userId: user.id, fileId: id, action: 'Write', details: { route: 'POST /files/:id/token', stable: true } }); } catch {}
    return res.json({ token });
  } catch {
    // fallback to previous JWT path if helper not available
    const secret = process.env.FILE_SHARE_SECRET || process.env.JWT_SECRET || 'dev-file-share-secret';
    const token = jwt.sign({ fileId: id, scope: 'file_share_read' }, secret);
    try { await setFileShareToken(id, token); } catch {}
    try { await logAudit({ req, userId: user.id, fileId: id, action: 'Write', details: { route: 'POST /files/:id/token', stable: false } }); } catch {}
    return res.json({ token });
  }
  
});

// Read current share token for a file so all roles see the same link without regenerating
router.get('/:id/token', requireAuth as any, async (req, res) => {
  const raw = (req.params as any).id;
  const id = Number(raw);
  if (!raw || Number.isNaN(id)) return res.status(400).json({ error: 'invalid id' });
  const f = await getFile(id);
  if (!f) return res.status(404).json({ error: 'not found' });

  const user = (req as any).user;
  // Same authorization as POST token: creator, holder, or privileged roles
  try {
    const viewer = await getUserById(Number(user?.id || 0));
    const role = String(viewer?.role || '').toUpperCase();
    const isPrivileged = role === 'COF' || role === 'ADMIN' || role === 'ACCOUNTSOFFICER' || role === 'ACCOUNTS_OFFICER';
    const isCreator = Number(user?.id) === Number(f.created_by ?? 0);
    const isHolder = Number(user?.id) === Number(f.current_holder_user_id ?? 0);
    if (!isPrivileged && !isCreator && !isHolder) {
      return res.status(403).json({ error: 'forbidden' });
    }
  } catch {
    return res.status(403).json({ error: 'forbidden' });
  }

  try {
    const token = await getShareToken(id);
    try { await logAudit({ req, userId: user?.id, fileId: id, action: 'Read', details: { route: 'GET /files/:id/token', hasToken: !!token } }); } catch {}
    return res.json({ token: token ?? null });
  } catch (e: any) {
    return res.status(500).json({ error: e?.message || 'failed to read token' });
  }
});

// Public endpoint to fetch a file using a share token. Token must be a valid signed JWT with fileId.
// Token-only access: no auth required; token expires in 5 minutes
router.get('/shared/files/:token', requireAuth as any, async (req, res) => {
  const token = (req.params as any).token;
  if (!token) return res.status(400).json({ error: 'missing token' });
  try {
    const fileId = await findFileIdByToken(token);
    if (!fileId) return res.status(401).json({ error: 'invalid or expired token' });
    const f = await getFile(Number(fileId));
    if (!f) return res.status(404).json({ error: 'file not found' });
    try { await logAudit({ req, fileId: Number(fileId), action: 'Read', details: { route: 'GET /files/shared/files/:token' } }); } catch {}
    return res.json(f);
  } catch (e: any) {
    return res.status(401).json({ error: 'invalid or expired token' });
  }
});

// Token-only access for events (timeline)
router.get('/shared/events/:token', requireAuth as any, async (req, res) => {
  const token = (req.params as any).token;
  if (!token) return res.status(400).json({ error: 'missing token' });
  try {
    const fileId = await findFileIdByToken(token);
    if (!fileId) return res.status(401).json({ error: 'invalid or expired token' });
    const ev = await listEvents(Number(fileId));
    try { await logAudit({ req, fileId: Number(fileId), action: 'Read', details: { route: 'GET /files/shared/events/:token', count: Array.isArray(ev) ? ev.length : 0 } }); } catch {}
    return res.json(ev);
  } catch (e: any) {
    return res.status(401).json({ error: 'invalid or expired token' });
  }
});

// Token-only with id match: file
router.get('/shared/:id/:token', requireAuth as any, async (req, res) => {
  const raw = (req.params as any).id;
  const id = Number(raw);
  const token = (req.params as any).token;
  if (!raw || Number.isNaN(id)) return res.status(400).json({ error: 'invalid id' });
  if (!token) return res.status(400).json({ error: 'missing token' });
  try {
    const fileId = await findFileIdByToken(token);
    if (!fileId) return res.status(401).json({ error: 'invalid or expired token' });
    if (Number(fileId) !== id) return res.status(401).json({ error: 'token does not match file' });
    const f = await getFile(Number(fileId));
    if (!f) return res.status(404).json({ error: 'file not found' });
    try { await logAudit({ req, fileId: Number(fileId), action: 'Read', details: { route: 'GET /files/shared/:id/:token' } }); } catch {}
    return res.json(f);
  } catch (e: any) {
    return res.status(401).json({ error: 'invalid or expired token' });
  }
});

// Token-only with id match: events
router.get('/shared/:id/:token/events', requireAuth as any, async (req, res) => {
  const raw = (req.params as any).id;
  const id = Number(raw);
  const token = (req.params as any).token;
  if (!raw || Number.isNaN(id)) return res.status(400).json({ error: 'invalid id' });
  if (!token) return res.status(400).json({ error: 'missing token' });
  try {
    const fileId = await findFileIdByToken(token);
    if (!fileId) return res.status(401).json({ error: 'invalid or expired token' });
    if (Number(fileId) !== id) return res.status(401).json({ error: 'token does not match file' });
    const ev = await listEvents(Number(fileId));
    try { await logAudit({ req, fileId: Number(fileId), action: 'Read', details: { route: 'GET /files/shared/:id/:token/events', count: Array.isArray(ev) ? ev.length : 0 } }); } catch {}
    return res.json(ev);
  } catch (e: any) {
    return res.status(401).json({ error: 'invalid or expired token' });
  }
});

router.get('/:id/sla', requireAuth as any, async (req, res) => {
  const raw = (req.params as any).id;
  const id = Number(raw);
  if (!raw || Number.isNaN(id)) return res.status(400).json({ error: 'invalid id' });
  try {
    const s = await computeSlaStatus(id as any);
    if (s === null) return res.status(404).json({ error: 'file not found' });
    try { await logAudit({ req, fileId: id, action: 'Read', details: { route: 'GET /files/:id/sla' } }); } catch {}
    return res.json(s);
  } catch (e: any) {
    return res.status(500).json({ error: e?.message ?? 'sla compute failed' });
  }
});

// Record SLA breach reason by current holder (or COF/Admin). Does not change status/holder.
router.post('/:id/sla/reason', requireAuth as any, async (req, res) => {
  const raw = (req.params as any).id;
  const id = Number(raw);
  if (!raw || Number.isNaN(id)) return res.status(400).json({ error: 'invalid id' });
  const f = await getFile(id);
  if (!f) return res.status(404).json({ error: 'not found' });

  const user = (req as any).user;
  const viewerId = Number(user?.id ?? 0);
  let role = '';
  try { const u = await getUserById(viewerId); role = String(u?.role || '').toUpperCase(); } catch {}
  const isPrivileged = role === 'COF' || role === 'ADMIN' || role === 'ACCOUNTSOFFICER' || role === 'ACCOUNTS_OFFICER';
  const isHolder = viewerId && Number(f.current_holder_user_id ?? 0) === viewerId;
  if (!isHolder && !isPrivileged) return res.status(403).json({ error: 'forbidden' });

  const body = req.body || {};
  const reason = String(body.reason || body.remarks || '').trim();
  if (!reason) return res.status(400).json({ error: 'reason is required' });

  try {
    const ev = await addEvent(id, { from_user_id: viewerId, to_user_id: f.current_holder_user_id ?? null, action_type: 'SLAReason', remarks: reason });
    try { await logAudit({ req, userId: viewerId, fileId: id, action: 'Write', details: { route: 'POST /files/:id/sla/reason' } }); } catch {}
    return res.status(201).json(ev);
  } catch (e: any) {
    return res.status(400).json({ error: e?.message || 'failed to record' });
  }
});

export default router;
