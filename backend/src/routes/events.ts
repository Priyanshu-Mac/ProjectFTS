import { Router } from 'express';
import { EventCreateSchema } from '../schemas/event';
import { addEvent, listEvents, getFile, getUserById } from '../db/index';
import { logAudit } from '../middleware/audit';
import { requireAuth } from '../middleware/auth';

const router = Router({ mergeParams: true });

router.post('/', requireAuth as any, async (req, res) => {
  const id = Number((req.params as any).id);
  const f = await getFile(id);
  if (!f) return res.status(404).json({ error: 'file not found' });

  const parsed = EventCreateSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: parsed.error.format() });
  const body = parsed.data;

  // Derive actor (current user) from auth middleware or header fallback
  const authUser = (req as any).user;
  const actorHeader = req.header('x-user-id');
  const actor = authUser?.id ? Number(authUser.id) : (actorHeader ? Number(actorHeader) : undefined);
  if (!actor) return res.status(401).json({ error: 'unauthorized' });

  // Fetch actor role for permission checks (COF/Admin can move any file)
  let actorRole = '';
  try {
    const au = await getUserById(Number(actor));
    actorRole = String(au?.role || '').toUpperCase();
  } catch {
    actorRole = '';
  }

  // Determine last holder (from last event) or fallback to file.current_holder_user_id
  const events = await listEvents(id);
  const lastEvent = (events && events.length) ? events.slice().sort((a:any,b:any)=>b.seq_no-a.seq_no)[0] : null;
  const lastHolder = lastEvent?.to_user_id ?? f.current_holder_user_id ?? null;

  // Permission: only current holder can move the file, except COF/Admin who are allowed for any file
  const isCofOrAdmin = actorRole === 'COF' || actorRole === 'ADMIN';
  if (!isCofOrAdmin && (lastHolder == null || Number(lastHolder) !== Number(actor))) {
    return res.status(403).json({ error: 'forbidden: only current holder can move this file' });
  }

  // Build payload with auto-filled from_user_id and current holder
  const payload: any = {
    from_user_id: lastHolder ?? null,
    to_user_id: body.to_user_id ?? actor ?? null,
    action_type: body.action_type,
    remarks: body.remarks ?? null,
  };

  // If action is Hold and no explicit to_user_id was provided, keep/assign to actor or last holder
  // so the file remains assigned to the same officer while in OnHold status.
  if (payload.action_type === 'Hold' && (payload.to_user_id == null)) {
    payload.to_user_id = (actor ?? lastHolder ?? f.current_holder_user_id ?? null) as any;
  }

  // Auto-convert Forward to COF => Escalate (remarks required)
  if (payload.action_type === 'Forward' && payload.to_user_id != null) {
    try {
      const u = await getUserById(Number(payload.to_user_id));
      const role = (u?.role || '').toString().toUpperCase();
      if (role === 'COF') {
        payload.action_type = 'Escalate';
      }
    } catch (e) {
      // ignore lookup errors
    }
  }

  // Guards
  const requiresTo = ['Forward','Return','SeekInfo','Escalate','Dispatch','Reopen'];
  if (requiresTo.includes(payload.action_type) && !payload.to_user_id) {
    return res.status(400).json({ error: 'to_user_id is required for this action' });
  }
  const remarksRequired = ['Hold','Escalate'];
  if (remarksRequired.includes(payload.action_type) && !payload.remarks) {
    return res.status(400).json({ error: 'remarks required for Hold or Escalate actions' });
  }

  // For SeekInfo, create a query thread (the DB adapter will implement query creation when action_type === 'SeekInfo')
  const ev = await addEvent(id, payload);
  try { await logAudit({ req, userId: actor ?? undefined, fileId: id, action: 'Write', details: { route: 'POST /files/:id/events', payload: body, stored: ev?.id } }); } catch {}
  res.status(201).json(ev);
});

router.get('/', requireAuth as any, async (req, res) => {
  const id = Number((req.params as any).id);
  if ((req.query as any)?.t) {
    return res.status(403).json({ error: 'forbidden' });
  }
  // Visibility restriction is enforced by the file detail route; align here too
  try {
    const f = await getFile(id);
    if (!f) return res.status(404).json({ error: 'file not found' });
    const user = (req as any).user;
    const viewerId = Number(user?.id ?? 0);
    // require db access to user to get role
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const { getUserById } = require('../db/index');
    let role = '';
    try { const u = await getUserById(viewerId); role = String(u?.role || '').toUpperCase(); } catch {}
    const isPrivileged = role === 'COF' || role === 'ADMIN';
    const isCreator = viewerId && Number(f.created_by ?? 0) === viewerId;
    if (!isCreator && !isPrivileged) {
      return res.status(403).json({ error: 'forbidden' });
    }
  } catch { return res.status(403).json({ error: 'forbidden' }); }
  const list = await listEvents(id);
  try { await logAudit({ req, fileId: id, action: 'Read', details: { route: 'GET /files/:id/events', count: Array.isArray(list) ? list.length : 0 } }); } catch {}
  // list already contains from_user/to_user JSON objects when using pg adapter
  res.json(list);
});

export default router;
