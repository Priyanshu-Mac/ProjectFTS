import { Router } from 'express';
import { listFiles, listEvents } from '../db/index';

const router = Router();

router.get('/summary', async (req, res) => {
  const fl = await listFiles();
  const el = await listEvents();
  const files = Array.isArray((fl as any).results) ? (fl as any).results : (fl as any);
  const events = Array.isArray(el) ? el : (el as any).results || [];
  const total_open = files.filter((f: any) => ['Open','WithOfficer','WithCOF'].includes(f.status)).length;
  const avg_tat_days = (() => {
    const closedEvents = events.filter((e: any) => e.action_type === 'Close' && e.ended_at);
    if (closedEvents.length === 0) return 0;
    const avgMs = closedEvents.reduce((s:any,e:any)=>s + (new Date(e.ended_at).getTime() - new Date(e.started_at).getTime()), 0) / closedEvents.length;
    return avgMs / (1000*60*60*24);
  })();
  res.json({ total_open, avg_tat_days });
});

export default router;
