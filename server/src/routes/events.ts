import { Router } from 'express';
import { EventCreateSchema } from '../schemas/event';
import { addEvent, listEvents, getFile } from '../db/index';

const router = Router({ mergeParams: true });

router.post('/', async (req, res) => {
  const id = Number((req.params as any).id);
  const f = await getFile(id);
  if (!f) return res.status(404).json({ error: 'file not found' });

  const parsed = EventCreateSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: parsed.error.format() });
  const body = parsed.data;

  // Derive actor (current user) from header if available (no auth implemented yet)
  const actorHeader = req.header('x-user-id');
  const actor = actorHeader ? Number(actorHeader) : undefined;

  // Determine last holder (from last event) or fallback to file.current_holder_user_id
  const events = await listEvents(id);
  const lastEvent = (events && events.length) ? events.slice().sort((a:any,b:any)=>b.seq_no-a.seq_no)[0] : null;
  const lastHolder = lastEvent?.to_user_id ?? f.current_holder_user_id ?? null;

  // Build payload with auto-filled from_user_id and current holder
  const payload: any = {
    from_user_id: lastHolder ?? null,
    to_user_id: body.to_user_id ?? actor ?? null,
    action_type: body.action_type,
    remarks: body.remarks ?? null,
    attachments_json: body.attachments ?? null,
  };

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
  res.status(201).json(ev);
});

router.get('/', async (req, res) => {
  const id = Number((req.params as any).id);
  const list = await listEvents(id);
  res.json(list);
});

export default router;
