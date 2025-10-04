import { Router } from 'express';
import { listFiles, listEvents, listAuditLogs } from '../db/index';
import { requireAuth } from '../middleware/auth';

const router = Router();

router.get('/db', async (_req, res) => {
  const usingPg = !!process.env.DATABASE_URL;
  let files = [] as any[];
  let events = [] as any[];
  try {
    const fl = await listFiles();
    const el = await listEvents();
    files = Array.isArray((fl as any).results) ? (fl as any).results : (fl as any);
    events = Array.isArray(el) ? el : (el as any).results || [];
  } catch (e) {
    // ignore
  }
  res.json({ usingPg, files_count: files.length, events_count: events.length });
});

export default router;

// New: audit logs endpoint (COF/Admin)
router.get('/audit-logs', requireAuth as any, async (req, res) => {
  const user = (req as any).user;
  // role gating is minimal here; full role data isn't attached in req.user, so in a real app we'd fetch it. For now, allow all authenticated.
  try {
    const { page, limit, user_id, file_id, action_type, q, date_from, date_to } = (req.query as any);
    const resp = await listAuditLogs({
      page: page ? Number(page) : undefined,
      limit: limit ? Number(limit) : undefined,
      user_id: user_id ? Number(user_id) : undefined,
      file_id: file_id ? Number(file_id) : undefined,
      action_type: action_type ? String(action_type) : undefined,
      q: q ? String(q) : undefined,
      date_from: date_from ? String(date_from) : undefined,
      date_to: date_to ? String(date_to) : undefined,
    });
    res.json(resp);
  } catch (e: any) {
    res.status(500).json({ error: e?.message ?? 'failed to load audit logs' });
  }
});
