import { Router } from 'express';
import { FileCreateSchema, FileListQuery, FileListQueryType } from '../schemas/file';
import { createFile, listFiles, getFile, addEvent, computeSlaStatus } from '../db/index';
import { EchoSchema } from '../schemas/echo';

const router = Router();

router.post('/', async (req, res) => {
  const parsed = FileCreateSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: parsed.error.format() });
  const payload = parsed.data;
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
    created_by: null,
    attachments: payload.attachments,
    status: payload.save_as_draft ? 'Open' : 'WithOfficer',
  });

  // create initial event only if not a draft
  if (!payload.save_as_draft) {
    await addEvent(rec.id, { to_user_id: payload.forward_to_officer_id, action_type: 'Forward', remarks: payload.remarks, attachments_json: payload.attachments ?? null });
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
  res.json(list);
});

router.get('/:id', async (req, res) => {
  const id = Number((req.params as any).id);
  const f = await getFile(id);
  if (!f) return res.status(404).json({ error: 'not found' });
  res.json(f);
});

router.get('/:id/sla', async (req, res) => {
  const id = Number((req.params as any).id);
  const s = await computeSlaStatus(id as any);
  if (s === null) return res.status(404).json({ error: 'file not found' });
  res.json(s);
});

export default router;
