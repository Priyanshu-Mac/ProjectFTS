import { z } from 'zod';

export const EventCreateSchema = z.object({
  from_user_id: z.number().int().positive().optional(),
  to_user_id: z.number().int().positive().optional(),
  action_type: z.enum(['Forward','Return','SeekInfo','Hold','Escalate','Close','Dispatch','Reopen','SLAReason']),
  remarks: z.string().optional(),
});

export type EventCreate = z.infer<typeof EventCreateSchema>;
