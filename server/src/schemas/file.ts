import { z } from 'zod';

export const FileCreateSchema = z.object({
  subject: z.string().min(1),
  notesheet_title: z.string().min(1),
  owning_office_id: z.number().int().positive(),
  category_id: z.number().int().positive(),
  sla_policy_id: z.number().int().positive().optional(),
  priority: z.enum(['Routine','Urgent','Critical']).optional(),
  confidentiality: z.boolean().optional(),
  date_initiated: z.string().optional(),
  date_received_accounts: z.string().optional(),
  forward_to_officer_id: z.number().int().positive(),
  attachments: z.array(z.any()).optional(),
  save_as_draft: z.boolean().optional(),
  remarks: z.string().optional(),
});

export const FileListQuery = z.object({
  q: z.string().optional(),
  office: z.preprocess((s) => (s ? Number(s) : undefined), z.number().int().positive().optional()),
  category: z.preprocess((s) => (s ? Number(s) : undefined), z.number().int().positive().optional()),
  status: z.string().optional(),
  sla_policy_id: z.preprocess((s) => (s ? Number(s) : undefined), z.number().int().positive().optional()),
  holder: z.preprocess((s) => (s ? Number(s) : undefined), z.number().int().positive().optional()),
  page: z.preprocess((s) => (s ? Number(s) : undefined), z.number().int().positive().optional()),
  limit: z.preprocess((s) => (s ? Number(s) : undefined), z.number().int().positive().optional()),
  date_from: z.string().optional(),
  date_to: z.string().optional(),
});

export type FileListQueryType = z.infer<typeof FileListQuery>;

export type FileCreate = z.infer<typeof FileCreateSchema>;
