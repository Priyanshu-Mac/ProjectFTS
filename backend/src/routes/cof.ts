import { Router } from 'express';
import { listFiles, addEvent, getUserById } from '../db/index';
import { requireAuth } from '../middleware/auth';

const router = Router();

// List files that are with COF for final review
router.get('/review-queue', requireAuth as any, async (req, res) => {
  const user = (req as any).user;
  let role = '';
  try { const u = await getUserById(Number(user?.id)); role = String(u?.role || '').toUpperCase(); } catch {}
  if (!(role === 'COF' || role === 'ADMIN')) return res.status(403).json({ error: 'forbidden' });
  const q = req.query as any;
  const onlyMine = (String(q.assigned || q.onlyMine || '').toLowerCase() === '1') || (String(q.assigned || q.onlyMine || '').toLowerCase() === 'true');
  const results: any[] = [];
  // Always include escalated items (WithCOF)
  const withCof = await listFiles({ status: 'WithCOF', limit: 500 });
  const arr1 = Array.isArray((withCof as any).results) ? (withCof as any).results : (withCof as any);
  results.push(...arr1);
  // Also include files currently assigned to this COF (even if status is WithOfficer)
  const mine = await listFiles({ holder: Number(user?.id), limit: 500 });
  const arr2 = Array.isArray((mine as any).results) ? (mine as any).results : (mine as any);
  for (const r of arr2) {
    if (!results.find(x => x.id === r.id)) results.push(r);
  }
  // Filter out final statuses from the union; keep WithCOF always, and assigned-to-me only if not final
  const isFinal = (s: any) => ['CLOSED','DISPATCHED'].includes(String(s || '').toUpperCase());
  const filtered = results.filter((r: any) => {
    const status = String(r.status || '').toUpperCase();
    const mine = Number(r.current_holder_user_id ?? 0) === Number(user?.id);
    if (status === 'WITHCOF') return true;
    if (mine && !isFinal(status)) return true;
    return false;
  });
  // Apply onlyMine filter client-side if requested
  const final = onlyMine ? filtered.filter((r: any) => Number(r.current_holder_user_id ?? 0) === Number(user?.id)) : filtered;
  // Stable sort: newest first by id
  final.sort((a:any,b:any)=> Number(b.id) - Number(a.id));
  res.json(final);
});

// Dispatch a file from COF to an external recipient (recorded as Dispatch event)
router.post('/dispatch/:id', requireAuth as any, async (req, res) => {
  const user = (req as any).user;
  let role = '';
  try { const u = await getUserById(Number(user?.id)); role = String(u?.role || '').toUpperCase(); } catch {}
  if (!(role === 'COF' || role === 'ADMIN')) return res.status(403).json({ error: 'forbidden' });
  const fileId = Number((req.params as any).id);
  const body = req.body || {};
  const to_user_id = Number(body.to_user_id || user?.id);
  const remarks = body.remarks || 'Dispatched';
  const signature = body.signature || null; // base64 image or vector JSON
  if (!signature || typeof signature !== 'string' || !signature.startsWith('data:image')) {
    return res.status(400).json({ error: 'signature is required for dispatch' });
  }
  // Store signature reference inside remarks JSON to avoid schema change
  const payload: any = {
    from_user_id: Number(user?.id),
    to_user_id,
    action_type: 'Dispatch',
    remarks: signature ? JSON.stringify({ remarks, signature }) : remarks,
  };
  try {
    const ev = await addEvent(fileId, payload);
    return res.status(201).json(ev);
  } catch (e: any) {
    return res.status(400).json({ error: e?.message || 'failed' });
  }
});

export default router;
