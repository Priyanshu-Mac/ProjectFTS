import { Router } from 'express';
import { Pool } from 'pg';

const router = Router();

// Static fallback data when not using Postgres (matches provided SQL snapshot)
const FALLBACK = {
  offices: [
    { id: 1, name: 'Finance' },
    { id: 2, name: 'Procurement' },
    { id: 3, name: 'HR' },
    { id: 4, name: 'Admin' },
  ],
  categories: [
    { id: 1, name: 'Budget' },
    { id: 2, name: 'Audit' },
    { id: 3, name: 'Salary' },
    { id: 4, name: 'Procurement' },
    { id: 5, name: 'Misc' },
  ],
  sla_policies: [
    { id: 19, category_id: 1, sla_minutes: 1440, name: 'Budget - Routine (3 business days)', priority: 'Routine' },
    { id: 20, category_id: 1, sla_minutes: 480, name: 'Budget - Urgent (1 business day)', priority: 'Urgent' },
    { id: 21, category_id: 1, sla_minutes: 240, name: 'Budget - Critical (half day)', priority: 'Critical' },
    // ... other policies omitted for brevity
  ],
  users: [
    { id: 1, username: 'clerk1', name: 'Clerk One', office_id: 1, role: 'Clerk' },
    { id: 2, username: 'officer1', name: 'Officer One', office_id: 1, role: 'AccountsOfficer' },
    { id: 3, username: 'cof1', name: 'COF One', office_id: 1, role: 'COF' },
    { id: 4, username: 'admin1', name: 'Admin One', office_id: 1, role: 'Admin' },
    { id: 7, username: 'clerk', name: 'Clerk User', office_id: null, role: 'Clerk' },
    { id: 10, username: 'cofhai', name: 'COF User', office_id: null, role: 'COF' },
  ],
};

function getPool() {
  if (!process.env.DATABASE_URL) return null;
  return new Pool({ connectionString: process.env.DATABASE_URL });
}

router.get('/offices', async (_req, res) => {
  const pool = getPool();
  if (!pool) return res.json(FALLBACK.offices);
  try {
    const r = await pool.query('SELECT id, name FROM offices ORDER BY id');
    return res.json(r.rows);
  } catch (e: any) {
    return res.status(500).json({ error: e?.message ?? 'db error' });
  } finally {
    pool.end().catch(() => {});
  }
});

router.get('/categories', async (_req, res) => {
  const pool = getPool();
  if (!pool) return res.json(FALLBACK.categories);
  try {
    const r = await pool.query('SELECT id, name FROM categories ORDER BY id');
    return res.json(r.rows);
  } catch (e: any) {
    return res.status(500).json({ error: e?.message ?? 'db error' });
  } finally {
    pool.end().catch(() => {});
  }
});

router.get('/sla-policies', async (_req, res) => {
  const pool = getPool();
  if (!pool) return res.json(FALLBACK.sla_policies);
  try {
    const r = await pool.query('SELECT id, category_id, sla_minutes, name, priority, active FROM sla_policies WHERE active IS TRUE ORDER BY id');
    return res.json(r.rows);
  } catch (e: any) {
    return res.status(500).json({ error: e?.message ?? 'db error' });
  } finally {
    pool.end().catch(() => {});
  }
});

router.get('/users', async (req, res) => {
  const role = req.query.role as string | undefined;
  const pool = getPool();
  if (!pool) {
    const rows = FALLBACK.users.filter(u => !role ? true : (u.role && u.role.toLowerCase() === role.toLowerCase()));
    return res.json(rows);
  }
  try {
    if (role) {
      const r = await pool.query('SELECT id, username, name, office_id, role, email FROM users WHERE role = $1 ORDER BY id', [role]);
      return res.json(r.rows);
    }
    const r = await pool.query('SELECT id, username, name, office_id, role, email FROM users ORDER BY id');
    return res.json(r.rows);
  } catch (e: any) {
    return res.status(500).json({ error: e?.message ?? 'db error' });
  } finally {
    pool.end().catch(() => {});
  }
});

router.get('/constants', (_req, res) => {
  // Provide useful constants for the frontend
  return res.json({
    priorities: ['Routine', 'Urgent', 'Critical'],
    statuses: ['Open', 'WithOfficer', 'WithCOF', 'Dispatched', 'OnHold', 'WaitingOnOrigin', 'Closed'],
  });
});

export default router;
