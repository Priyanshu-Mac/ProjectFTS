import { Router } from 'express';
import { listFiles, listEvents } from '../db/index';

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
