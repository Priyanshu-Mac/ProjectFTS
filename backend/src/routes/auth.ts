import { Router } from 'express';
import { z } from 'zod';
import { createUser, findUserByUsername } from '../db/index';
import bcrypt from 'bcryptjs';
import jwt from 'jsonwebtoken';

const router = Router();

const RegisterSchema = z.object({
  username: z.string().min(3),
  name: z.string().min(1),
  role: z.enum(['Clerk', 'AccountsOfficer', 'COF', 'Admin']),
  password: z.string().min(8),
  // new optional fields
  office_id: z.number().int().positive().optional(),
  email: z.string().email().optional(),
});
const LoginSchema = z.object({ username: z.string().min(1), password: z.string().min(1) });

router.post('/register', async (req, res) => {
  const parsed = RegisterSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: parsed.error.format() });
  const { username, name, role, password, office_id, email } = parsed.data;
  const existing = await findUserByUsername(username);
  if (existing) return res.status(409).json({ error: 'username taken' });
  const hash = await bcrypt.hash(password, 10);
  try {
    const user = await createUser({ username, name, role, office_id, email, password_hash: hash } as any);
    res.status(201).json({ id: user.id, username: user.username, name: user.name, role: (user as any).role || 'Clerk' });
  } catch (e: any) {
    // Handle duplicate email or other constraint violations
    const msg = e?.message || '';
    const code = e?.code || '';
    if (code === '23505' || /duplicate key value/i.test(msg)) {
      if (/email/i.test(msg)) {
        return res.status(409).json({ error: 'email taken' });
      }
      if (/username/i.test(msg)) {
        return res.status(409).json({ error: 'username taken' });
      }
      return res.status(409).json({ error: 'conflict' });
    }
    if (code === 'EMAIL_TAKEN') {
      return res.status(409).json({ error: 'email taken' });
    }
    // fallback
    // eslint-disable-next-line no-console
    console.error('[auth] register failed', e);
    return res.status(500).json({ error: 'internal error' });
  }
});

router.post('/login', async (req, res) => {
  const parsed = LoginSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: parsed.error.format() });
  const { username, password } = parsed.data;
  const user = await findUserByUsername(username);
  if (!user) return res.status(401).json({ error: 'invalid credentials' });
  const ok = await bcrypt.compare(password, user.password_hash || '');
  if (!ok) return res.status(401).json({ error: 'invalid credentials' });
  const token = jwt.sign({ sub: user.id, username: user.username }, process.env.JWT_SECRET || 'dev-secret', { expiresIn: '8h' });
res.json({ token, user: { id: user.id, username: user.username, name: user.name, role: (user as any).role || 'Clerk' } });  
});

export default router;
