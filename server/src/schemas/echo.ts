import { z } from 'zod';

export const EchoSchema = z.object({
  name: z.string().min(1),
  msg: z.string().optional(),
});

export type Echo = z.infer<typeof EchoSchema>;
