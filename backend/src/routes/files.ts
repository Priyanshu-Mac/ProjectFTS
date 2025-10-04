import { Router } from 'express';
import { FileCreateSchema, FileListQuery, FileListQueryType } from '../schemas/file';
import { createFile, listFiles, getFile, addEvent, computeSlaStatus, generateFileNo, refreshFileSla } from '../db/index';
import { EchoSchema } from '../schemas/echo';
import { requireAuth } from '../middleware/auth';
import jwt from 'jsonwebtoken';
import { findUserByUsername } from '../db/index';

const router = Router();

// Require authentication for creating files so created_by is reliably set
router.post('/', requireAuth as any, async (req, res) => {
  const parsed = FileCreateSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: parsed.error.format() });
  const payload = parsed.data;
  // created_by is set from authenticated user when available
  // since requireAuth runs, req.user should be present; fall back to null defensively
  const createdBy = (req as any).user?.id ?? null;

  // If not saving as draft, forward_to_officer_id must be provided so we can assign initial holder
  if (!payload.save_as_draft && !payload.forward_to_officer_id) {
    return res.status(400).json({ error: 'forward_to_officer_id is required when not saving as draft' });
  }
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
    attachments: payload.attachments,
    status: payload.save_as_draft ? 'Open' : 'WithOfficer',
  });

  // create initial event only if not a draft
  if (!payload.save_as_draft) {
    // record the creator as the from_user for the initial forward event
    await addEvent(rec.id, { from_user_id: createdBy ?? null, to_user_id: payload.forward_to_officer_id, action_type: 'Forward', remarks: payload.remarks, attachments_json: payload.attachments ?? null });
  }

  // quick checklist
  const checklist = {
    initiation_date_present: !!payload.date_initiated,
    has_attachments: Array.isArray(payload.attachments) && payload.attachments.length > 0,
    priority_set: !!(payload as any).priority,
  };

  // duplicate finder: naive search for similar subjects in last 30 days
  const thirtyDaysAgo = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString();
  const dupList = await listFiles({ q: payload.subject, date_from: thirtyDaysAgo, limit: 10 });

  res.status(201).json({ file: rec, checklist, duplicates: dupList.results });
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
  if (!flag) return res.json(list);
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
          };
        }
      } catch {}
      return row;
    }));
    return res.json({ ...list, results: enriched });
  } catch (e: any) {
    // fall back to original list on errors
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
  const f = await getFile(id);
  if (!f) return res.status(404).json({ error: 'not found' });
  // persist SLA snapshot into files.* columns so the DB reflects latest
  try { await refreshFileSla(id); } catch {}
  // enrich with computed SLA snapshot
  try {
    const sla = await computeSlaStatus(id as any);
    if (sla) {
      return res.json({
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
      });
    }
  } catch (e) {
    // ignore SLA compute errors and return base file
  }
  res.json(f);
});

// Create a share token for a file. Caller must be authenticated and must be the creator of the file.
router.post('/:id/token', requireAuth as any, async (req, res) => {
  const raw = (req.params as any).id;
  const id = Number(raw);
  if (!raw || Number.isNaN(id)) return res.status(400).json({ error: 'invalid id' });
  const f = await getFile(id);
  if (!f) return res.status(404).json({ error: 'not found' });

  // req.user is set by requireAuth middleware
  const user = (req as any).user;
  // allow token creation only to the creator of the file (or admin in future)
  if (!user || Number(user.id) !== Number(f.created_by)) {
    return res.status(403).json({ error: 'forbidden' });
  }

  const secret = process.env.FILE_SHARE_SECRET || process.env.JWT_SECRET || 'dev-file-share-secret';
  // default expire in 7 days
  const token = jwt.sign({ fileId: id }, secret, { expiresIn: '7d' });
  res.json({ token });
});

// Public endpoint to fetch a file using a share token. Token must be a valid signed JWT with fileId.
router.get('/shared/files/:token', requireAuth as any, async (req, res) => {
  const token = (req.params as any).token;
  if (!token) return res.status(400).json({ error: 'missing token' });
  const secret = process.env.FILE_SHARE_SECRET || process.env.JWT_SECRET || 'dev-file-share-secret';
  try {
    const payload = jwt.verify(token, secret) as any;
    const fileId = Number(payload.fileId ?? payload.fileId);
    if (!fileId || Number.isNaN(fileId)) return res.status(400).json({ error: 'invalid token payload' });
    const f = await getFile(fileId);
    if (!f) return res.status(404).json({ error: 'file not found' });
    res.json(f);
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
    return res.json(s);
  } catch (e: any) {
    return res.status(500).json({ error: e?.message ?? 'sla compute failed' });
  }
});

export default router;
