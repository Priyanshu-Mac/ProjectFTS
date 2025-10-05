import { Router } from 'express';
import { z } from 'zod';
import bcrypt from 'bcryptjs';
import { requireAuth } from '../middleware/auth';
import { getUserById, createUser, findUserByUsername } from '../db/index';
// We'll import via require to avoid circular type deps for optional functions
// eslint-disable-next-line @typescript-eslint/no-var-requires
const db = require('../db/index');
import { logAudit } from '../middleware/audit';

const router = Router();

const RoleEnum = z.enum(['Clerk','AccountsOfficer','COF','Admin']);

const CreateUserSchema = z.object({
  username: z.string().min(3),
  name: z.string().min(1),
  role: RoleEnum,
  password: z.string().min(8),
  office_id: z.number().int().positive().optional(),
  email: z.string().email().optional(),
});

const UpdateUserSchema = z.object({
  name: z.string().min(1).optional(),
  role: RoleEnum.optional(),
  office_id: z.number().int().positive().nullable().optional(),
  email: z.string().email().nullable().optional(),
});

const ResetPasswordSchema = z.object({
  password: z.string().min(8),
});

function ensureAdmin(req: any) {
  return (async () => {
    const uid = Number(req?.user?.id || 0);
    if (!uid) return false;
    try {
      const u = await getUserById(uid);
      const role = String(u?.role || '').toUpperCase();
      return role === 'ADMIN';
    } catch {
      return false;
    }
  })();
}

// List users (admin only)
router.get('/', requireAuth as any, async (req, res) => {
  if (!(await ensureAdmin(req))) return res.status(403).json({ error: 'forbidden' });
  const q = req.query || {};
  const page = q.page ? Number(q.page) : 1;
  const limit = q.limit ? Number(q.limit) : 50;
  const search = q.q ? String(q.q) : '';
  try {
    const list = await db.listUsers({ page, limit, q: search });
  try { await logAudit({ req, action: 'Read', details: { route: 'GET /users', page, limit, q: search } }); } catch {}
    return res.json(list);
  } catch (e: any) {
    return res.status(500).json({ error: e?.message || 'failed to list users' });
  }
});

// Create user (admin only)
router.post('/', requireAuth as any, async (req, res) => {
  if (!(await ensureAdmin(req))) return res.status(403).json({ error: 'forbidden' });
  const parsed = CreateUserSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: parsed.error.format() });
  const { username, name, role, password, office_id, email } = parsed.data;
  const existing = await findUserByUsername(username);
  if (existing) return res.status(409).json({ error: 'username taken' });
  const hash = await bcrypt.hash(password, 10);
  try {
    const u = await createUser({ username, name, role, office_id, email, password_hash: hash } as any);
  try { await logAudit({ req, action: 'Write', details: { route: 'POST /users', username } }); } catch {}
    return res.status(201).json({ id: u.id, username: u.username, name: u.name, role: u.role, office_id: u.office_id ?? null, email: u.email ?? null });
  } catch (e: any) {
    // Handle conflicts gracefully
    const msg = e?.message || '';
    if (/duplicate/i.test(msg)) return res.status(409).json({ error: 'conflict' });
    return res.status(500).json({ error: 'internal error' });
  }
});

// Update user (admin only)
router.patch('/:id', requireAuth as any, async (req, res) => {
  if (!(await ensureAdmin(req))) return res.status(403).json({ error: 'forbidden' });
  const idRaw = (req.params as any).id;
  const id = Number(idRaw);
  if (!idRaw || Number.isNaN(id)) return res.status(400).json({ error: 'invalid id' });
  const parsed = UpdateUserSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: parsed.error.format() });
  try {
    const updated = await db.updateUser(id, parsed.data);
  try { await logAudit({ req, action: 'Write', details: { route: 'PATCH /users/:id', id } }); } catch {}
    return res.json(updated);
  } catch (e: any) {
    return res.status(500).json({ error: e?.message || 'failed to update user' });
  }
});

// Reset password (admin only)
router.post('/:id/password', requireAuth as any, async (req, res) => {
  if (!(await ensureAdmin(req))) return res.status(403).json({ error: 'forbidden' });
  const idRaw = (req.params as any).id;
  const id = Number(idRaw);
  if (!idRaw || Number.isNaN(id)) return res.status(400).json({ error: 'invalid id' });
  const parsed = ResetPasswordSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: parsed.error.format() });
  const hash = await bcrypt.hash(parsed.data.password, 10);
  try {
    if (typeof db.updateUserPassword === 'function') {
      const ok = await db.updateUserPassword(id, hash);
      if (!ok) return res.status(404).json({ error: 'not found' });
  try { await logAudit({ req, action: 'Write', details: { route: 'POST /users/:id/password', id } }); } catch {}
      return res.json({ ok: true });
    }
    return res.status(501).json({ error: 'not implemented' });
  } catch (e: any) {
    return res.status(500).json({ error: e?.message || 'failed to reset password' });
  }
});

export default router;
