import { Router } from 'express';
import { z } from 'zod';
import { createUser, findUserByUsername } from '../db/index';
import { logAudit } from '../middleware/audit';
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
  try { await logAudit({ req, userId: user.id, action: 'Write', details: { route: 'POST /auth/register', username } }); } catch {}
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

// router.post('/login', async (req, res) => {
//   const parsed = LoginSchema.safeParse(req.body);
//   if (!parsed.success) return res.status(400).json({ error: parsed.error.format() });
//   const { username, password } = parsed.data;
//   const user = await findUserByUsername(username);
//   if (!user) return res.status(401).json({ error: 'invalid credentials' });
//   const ok = await bcrypt.compare(password, user.password_hash || '');
//   if (!ok) return res.status(401).json({ error: 'invalid credentials' });
//   const token = jwt.sign({ sub: user.id, username: user.username }, process.env.JWT_SECRET || 'dev-secret', { expiresIn: '8h' });
//   // Keep original role casing as stored (e.g., 'AccountsOfficer'); frontend normalizes to 'accounts_officer'
//   try { await logAudit({ req, userId: user.id, action: 'Read', details: { route: 'POST /auth/login', username: user.username, result: 'ok' } }); } catch {}
//   res.json({ token, user: { id: user.id, username: user.username, name: user.name, role: (user as any).role || 'Clerk', office_id: (user as any).office_id ?? null } });  
// });

router.post('/login', async (req, res) => {
  // ---- START DEBUGGING ----
  console.log('\n--- NEW LOGIN ATTEMPT ---');
  console.log('1. Received request body:', JSON.stringify(req.body, null, 2));
  // ---- END DEBUGGING ----

  const parsed = LoginSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: parsed.error.format() });

  const { username, password } = parsed.data;
  const user = await findUserByUsername(username);

  // ---- START DEBUGGING ----
  if (!user) {
    console.log(`2. User NOT FOUND in database for username: "${username}"`);
    return res.status(401).json({ error: 'invalid credentials' });
  }
  console.log(`2. Found user in database:`, { id: user.id, username: user.username, password_hash: user.password_hash });
  // ---- END DEBUGGING ----

  const ok = await bcrypt.compare(password, user.password_hash || '');

  // ---- START DEBUGGING ----
  console.log(`3. Password comparison result for "${username}":`, ok, '<-- THIS MUST BE TRUE');
  // ---- END DEBUGGING ----

  if (!ok) {
    console.log('Password comparison failed. Sending 401 error.');
    return res.status(401).json({ error: 'invalid credentials' });
  }

  const token = jwt.sign({ sub: user.id, username: user.username }, process.env.JWT_SECRET || 'dev-secret', { expiresIn: '8h' });

  // ---- START DEBUGGING ----
  console.log('4. Login successful! Sending token and user object.');
  // ---- END DEBUGGING ----

  try { await logAudit({ req, userId: user.id, action: 'Read', details: { route: 'POST /auth/login', username: user.username, result: 'ok' } }); } catch {}
  res.json({ token, user: { id: user.id, username: user.username, name: user.name, role: (user as any).role || 'Clerk', office_id: (user as any).office_id ?? null } });  
});

export default router;
