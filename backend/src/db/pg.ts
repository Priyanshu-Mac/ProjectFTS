import { Pool, PoolClient } from 'pg';
import crypto from 'crypto';

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
});

function sanitizeConnectionString(conn?: string) {
  if (!conn) return 'undefined';
  try {
    return `${conn}`;
  } catch (err) {
    return '[invalid-connection-string]';
  }
}

async function withClient<T>(fn: (client: PoolClient) => Promise<T>) {
  const client = await pool.connect();
  try {
    return await fn(client);
  } finally {
    client.release();
  }
}

export async function generateFileNo(date = new Date()): Promise<string> {
  // Generate the next file number by looking at the latest persisted file_no
  // for the given date and returning max + 1. This ensures numbering follows
  // existing DB records (avoids drift between in-memory counters and DB).
  const day = date.toISOString().slice(0, 10); // YYYY-MM-DD
  return withClient(async (client) => {
    // Look for the latest file_no for this day in files table
    const dstr = day.replace(/-/g, ''); // YYYYMMDD
    const prefix = `ACC-${dstr}-`;
    const q = 'SELECT file_no FROM files WHERE file_no LIKE $1 ORDER BY file_no DESC LIMIT 1';
    const r = await client.query(q, [prefix + '%']);
    let nextCounter = 1;
    if ((r.rowCount ?? 0) > 0 && r.rows?.[0]?.file_no) {
      const last = r.rows[0].file_no as string;
      const parts = last.split('-');
      const lastNumStr = parts[parts.length - 1] || '0';
      const lastNum = Number(lastNumStr.replace(/^0+/, '') || '0');
      nextCounter = lastNum + 1;
    }
    return `ACC-${dstr}-${String(nextCounter).padStart(2, '0')}`;
  });
}

export async function createFile(payload: any) {
  const file_no = payload.file_no || await generateFileNo(new Date());
  // Use COALESCE for date_initiated and date_received_accounts so NULL/undefined
  // values are replaced with CURRENT_DATE on the DB side and don't violate
  // NOT NULL constraints. We still accept a provided date string if present.
  const q = `INSERT INTO files(
      file_no, subject, notesheet_title, owning_office_id, category_id,
      date_initiated, date_received_accounts, current_holder_user_id,
      status, confidentiality, sla_policy_id, created_by, created_at
    ) VALUES(
      $1, $2, $3, $4, $5,
      COALESCE($6::date, CURRENT_DATE), COALESCE($7::date, CURRENT_DATE), $8,
      $9, $10, $11, $12, CURRENT_TIMESTAMP
    ) RETURNING *`;
  const vals = [
    file_no,
    payload.subject,
    payload.notesheet_title,
    payload.owning_office_id,
    payload.category_id,
    payload.date_initiated,
    payload.date_received_accounts,
    payload.current_holder_user_id,
    payload.status || 'Open',
    payload.confidentiality || false,
    payload.sla_policy_id,
    payload.created_by,
  ];
  const r = await pool.query(q, vals);
  return r.rows[0];
}

export async function listFiles(query?: {
  q?: string;
  office?: number;
  category?: number;
  status?: string;
  priority?: string;
  holder?: number;
  creator?: number;
  page?: number;
  limit?: number;
  date_from?: string;
  date_to?: string;
}) {
  const where: string[] = [];
  const vals: any[] = [];
  if (query?.q) {
    vals.push(`%${query.q}%`);
    where.push(`(file_no ILIKE $${vals.length} OR subject ILIKE $${vals.length} OR notesheet_title ILIKE $${vals.length})`);
  }
  if (query?.office) {
    vals.push(query.office);
    where.push(`owning_office_id = $${vals.length}`);
  }
  if (query?.category) {
    vals.push(query.category);
    where.push(`category_id = $${vals.length}`);
  }
  if (query?.status) {
    vals.push(query.status);
    where.push(`status = $${vals.length}`);
  }
  if (query?.priority) {
    vals.push(query.priority);
    where.push(`priority = $${vals.length}`);
  }
  if (query?.holder) {
    vals.push(query.holder);
    where.push(`current_holder_user_id = $${vals.length}`);
  }
  if (query?.creator) {
    vals.push(query.creator);
    where.push(`created_by = $${vals.length}`);
  }
  if (query?.date_from) {
    vals.push(query.date_from);
    where.push(`created_at >= $${vals.length}`);
  }
  if (query?.date_to) {
    vals.push(query.date_to);
    where.push(`created_at <= $${vals.length}`);
  }
  const whereSql = where.length ? 'WHERE ' + where.join(' AND ') : '';

  const limit = query?.limit && query.limit > 0 ? Math.min(query.limit, 500) : 50;
  const page = query?.page && query.page > 0 ? query.page : 1;
  const offset = (page - 1) * limit;

  // Include human-friendly names for foreign keys by joining related tables.
  // Return small JSON objects for owning_office, category and created_by_user so the frontend can use .name/.username
  const q = `SELECT files.*, 
    json_build_object('id', o.id, 'name', o.name) AS owning_office,
    json_build_object('id', c.id, 'name', c.name) AS category,
    json_build_object('id', u.id, 'username', u.username, 'name', u.name) AS created_by_user
    FROM files
    LEFT JOIN offices o ON files.owning_office_id = o.id
    LEFT JOIN categories c ON files.category_id = c.id
    LEFT JOIN users u ON files.created_by = u.id
    ${whereSql} ORDER BY files.id DESC LIMIT ${limit} OFFSET ${offset}`;

  // log the raw query and a sanitized connection URL for debugging (no password)
  // eslint-disable-next-line no-console
  console.log('[pg] listFiles SQL:', q, 'params:', JSON.stringify(vals), 'url:', sanitizeConnectionString(process.env.DATABASE_URL));
  const r = await pool.query(q, vals);

  // also return total count for pagination
  let total = r.rowCount;
  try {
    const countQ = `SELECT COUNT(*) as cnt FROM files ${whereSql}`;
    const cntR = await pool.query(countQ, vals);
    total = Number(cntR.rows[0].cnt);
  } catch (err) {
    // ignore count errors
  }

  return { total, page, limit, results: r.rows };
}

export async function getFile(id: number) {
  const q = `SELECT files.*, 
    json_build_object('id', o.id, 'name', o.name) AS owning_office,
    json_build_object('id', c.id, 'name', c.name) AS category,
    json_build_object('id', u.id, 'username', u.username, 'name', u.name) AS created_by_user
    FROM files
    LEFT JOIN offices o ON files.owning_office_id = o.id
    LEFT JOIN categories c ON files.category_id = c.id
    LEFT JOIN users u ON files.created_by = u.id
    WHERE files.id = $1`;
  // eslint-disable-next-line no-console
  console.log('[pg] getFile SQL:', q, 'params:', JSON.stringify([id]), 'url:', sanitizeConnectionString(process.env.DATABASE_URL));
  const r = await pool.query(q, [id]);
  return r.rows[0] || null;
}

export async function addEvent(file_id: number|undefined, payload: any) {
  // perform within transaction: close open event, compute seq, insert new event, update file
  return withClient(async (client) => {
    await client.query('BEGIN');
    try {
      // Read existing holder to preserve assignment on Hold if no to_user_id provided
      const existingFileR = await client.query('SELECT current_holder_user_id FROM files WHERE id = $1', [file_id]);
      const existingHolder: number | null = existingFileR.rowCount ? (existingFileR.rows[0].current_holder_user_id ?? null) : null;
      // close previous open event (ended_at = now)
      await client.query('UPDATE file_events SET ended_at = CURRENT_TIMESTAMP WHERE file_id = $1 AND ended_at IS NULL', [file_id]);

      // compute seq_no
      const qSeq = 'SELECT COALESCE(MAX(seq_no),0) as maxseq FROM file_events WHERE file_id = $1';
      const seqR = await client.query(qSeq, [file_id]);
      const seq = (seqR.rows[0].maxseq || 0) + 1;

      const q = `INSERT INTO file_events(file_id, seq_no, from_user_id, to_user_id, action_type, started_at, ended_at, business_minutes_held, remarks)
        VALUES($1,$2,$3,$4,$5,CURRENT_TIMESTAMP,$6,$7,$8) RETURNING *`;
      const vals = [file_id, seq, payload.from_user_id ?? null, payload.to_user_id ?? null, payload.action_type, payload.ended_at ?? null, payload.business_minutes_held ?? null, payload.remarks ?? null];
      // eslint-disable-next-line no-console
      console.log('[pg] addEvent SQL:', q, 'params:', JSON.stringify(vals), 'url:', sanitizeConnectionString(process.env.DATABASE_URL));
      const r = await client.query(q, vals);

      // If action is SeekInfo, create a query thread record linked to this file_event
      if (payload.action_type === 'SeekInfo') {
        try {
          await client.query(
            'INSERT INTO query_threads(file_id, initiator_user_id, target_user_id, query_text, status, created_at) VALUES($1,$2,$3,$4,$5,CURRENT_TIMESTAMP)',
            [file_id, payload.from_user_id ?? null, payload.to_user_id ?? null, payload.remarks ?? null, 'Open']
          );
        } catch (e: any) {
          // ignore query thread creation errors but don't abort main transaction
          // eslint-disable-next-line no-console
          console.warn('[pg] query_threads insert failed', e?.message ?? e);
        }
      }

    // update files: current_holder_user_id and status mapping
  let newStatus = 'WithOfficer';
  if (payload.action_type === 'Close') newStatus = 'Closed';
  else if (payload.action_type === 'Dispatch') newStatus = 'Dispatched';
  else if (payload.action_type === 'Hold') newStatus = 'OnHold';
  else if (payload.action_type === 'SeekInfo') newStatus = 'WaitingOnOrigin';
  else if (payload.action_type === 'Escalate') newStatus = 'WithCOF';
      // For SLAReason, do not change holder or status (annotation-only event)
      if (payload.action_type === 'SLAReason') {
        // No-op on files table
      } else {
        // Preserve holder for Hold if to_user_id not provided
        const nextHolder = ((payload.action_type === 'Hold') && (payload.to_user_id == null))
          ? (existingHolder ?? null)
          : (payload.to_user_id ?? null);
        await client.query('UPDATE files SET current_holder_user_id = $1, status = $2 WHERE id = $3', [nextHolder, newStatus, file_id]);
      }

      await client.query('COMMIT');
      return r.rows[0];
    } catch (err) {
      await client.query('ROLLBACK');
      throw err;
    }
  });
}

export async function listEvents(file_id?: number) {
  if (file_id) {
    const q = `SELECT e.*, 
      json_build_object('id', fu.id, 'username', fu.username, 'name', fu.name, 'role', fu.role) AS from_user,
      json_build_object('id', tu.id, 'username', tu.username, 'name', tu.name, 'role', tu.role) AS to_user
      FROM file_events e
      LEFT JOIN users fu ON fu.id = e.from_user_id
      LEFT JOIN users tu ON tu.id = e.to_user_id
      WHERE e.file_id = $1
      ORDER BY e.seq_no`;
    const r = await pool.query(q, [file_id]);
    return r.rows;
  }
  const q = `SELECT e.*, 
      json_build_object('id', fu.id, 'username', fu.username, 'name', fu.name, 'role', fu.role) AS from_user,
      json_build_object('id', tu.id, 'username', tu.username, 'name', tu.name, 'role', tu.role) AS to_user
      FROM file_events e
      LEFT JOIN users fu ON fu.id = e.from_user_id
      LEFT JOIN users tu ON tu.id = e.to_user_id
      ORDER BY e.id DESC LIMIT 100`;
  const r = await pool.query(q);
  return r.rows;
}

export async function listAllEvents() {
  const q = `SELECT e.*, f.file_no,
    json_build_object('id', fu.id, 'username', fu.username, 'name', fu.name, 'role', fu.role) AS from_user,
    json_build_object('id', tu.id, 'username', tu.username, 'name', tu.name, 'role', tu.role) AS to_user
    FROM file_events e
    LEFT JOIN users fu ON fu.id = e.from_user_id
    LEFT JOIN users tu ON tu.id = e.to_user_id
    LEFT JOIN files f ON f.id = e.file_id
    ORDER BY e.id`;
  const r = await pool.query(q);
  return r.rows;
}

export async function refreshFileSla(file_id: number) {
  try {
    await pool.query('SELECT public.update_file_sla($1)', [file_id]);
    return true;
  } catch (e) {
    // ignore if function not present
    return false;
  }
}

// User helper functions for auth
export async function findUserByUsername(username: string) {
  const r = await pool.query('SELECT * FROM users WHERE username = $1 LIMIT 1', [username]);
  return r.rows[0] || null;
}
export async function getUserById(id: number) {
  const r = await pool.query('SELECT * FROM users WHERE id = $1 LIMIT 1', [id]);
  return r.rows[0] || null;
}
export async function createUser(payload: { username: string; name: string; password_hash: string; role?: string; office_id?: number | null; email?: string | null }) {
  // Insert including optional email and office_id; role defaults to Clerk
  const q = `INSERT INTO users(username, name, role, office_id, email) VALUES($1,$2,$3,$4,$5) RETURNING *`;
  const vals = [payload.username, payload.name, payload.role || 'Clerk', payload.office_id ?? null, payload.email ?? null];
  const r = await pool.query(q, vals);
  // store password_hash
  try {
    await pool.query('UPDATE users SET password_hash = $1 WHERE id = $2', [payload.password_hash, r.rows[0].id]);
  } catch (e) {
    // ignore if column doesn't exist
  }
  return r.rows[0];
}

export async function listUsers(query?: { page?: number; limit?: number; q?: string }) {
  const conditions: string[] = [];
  const vals: any[] = [];
  if (query?.q) {
    vals.push(`%${query.q}%`);
    conditions.push(`(username ILIKE $${vals.length} OR name ILIKE $${vals.length} OR role ILIKE $${vals.length} OR COALESCE(email,'') ILIKE $${vals.length})`);
  }
  const whereSql = conditions.length ? ('WHERE ' + conditions.join(' AND ')) : '';
  const limit = query?.limit && query.limit > 0 ? Math.min(query.limit, 200) : 50;
  const page = query?.page && query.page > 0 ? query.page : 1;
  const offset = (page - 1) * limit;
  const sql = `SELECT id, username, name, role, office_id, email FROM users ${whereSql} ORDER BY id DESC LIMIT ${limit} OFFSET ${offset}`;
  const r = await pool.query(sql, vals);
  let total = r.rowCount || 0;
  try {
    const cr = await pool.query(`SELECT COUNT(*) AS cnt FROM users ${whereSql}`, vals);
    total = Number(cr.rows?.[0]?.cnt || 0);
  } catch {}
  return { total, page, limit, results: r.rows };
}

export async function updateUser(id: number, updates: { name?: string; role?: string; office_id?: number | null; email?: string | null }) {
  const sets: string[] = [];
  const vals: any[] = [];
  let idx = 1;
  if (updates.name !== undefined) { sets.push(`name = $${idx++}`); vals.push(updates.name); }
  if (updates.role !== undefined) { sets.push(`role = $${idx++}`); vals.push(updates.role); }
  if (updates.office_id !== undefined) { sets.push(`office_id = $${idx++}`); vals.push(updates.office_id); }
  if (updates.email !== undefined) { sets.push(`email = $${idx++}`); vals.push(updates.email); }
  if (!sets.length) {
    const u = await getUserById(id);
    return u ? { id: u.id, username: u.username, name: u.name, role: u.role, office_id: u.office_id ?? null, email: u.email ?? null } : null;
  }
  vals.push(id);
  const sql = `UPDATE users SET ${sets.join(', ')} WHERE id = $${idx} RETURNING id, username, name, role, office_id, email`;
  const r = await pool.query(sql, vals);
  if (!r.rowCount) throw new Error('not found');
  return r.rows[0];
}

export async function updateUserPassword(userId: number, password_hash: string) {
  const r = await pool.query('UPDATE users SET password_hash = $1 WHERE id = $2', [password_hash, userId]);
  return (r.rowCount ?? 0) > 0;
}

export async function computeSlaStatus(file_id: number) {
  // fetch file and its sla policy minutes
  const fileR = await pool.query('SELECT id, sla_policy_id, created_at, date_initiated, date_received_accounts, status FROM files WHERE id = $1', [file_id]);
  if (fileR.rowCount === 0) return null;
  const file = fileR.rows[0];
  // If the file is a Draft, SLA must not accrue. Return a zero-consumption snapshot.
  if (String(file.status || '').toLowerCase() === 'draft') {
    // Load policy to report correct sla_minutes even for drafts
    let slaMinutes = 1440;
    let warningPct = 70;
    let escalatePct = 100;
    let pauseOnHold = true;
    let policyName: string | null = null;
    let policyId: number | null = file.sla_policy_id ?? null;
    if (file.sla_policy_id) {
      try {
        const sp = await pool.query('SELECT id, name, sla_minutes, warning_pct, escalate_pct, pause_on_hold FROM sla_policies WHERE id = $1', [file.sla_policy_id]);
        if (sp.rowCount) {
          const row = sp.rows[0];
          policyId = Number(row.id || policyId);
          policyName = row.name ?? null;
          slaMinutes = Number(row.sla_minutes || slaMinutes);
          warningPct = Number(row.warning_pct ?? warningPct);
          escalatePct = Number(row.escalate_pct ?? escalatePct);
          pauseOnHold = Boolean(row.pause_on_hold ?? pauseOnHold);
        }
      } catch {}
    }
    return {
      sla_minutes: slaMinutes,
      consumed_minutes: 0,
      percent_used: 0,
      status: 'On-track',
      remaining_minutes: slaMinutes,
      warning_pct: warningPct,
      escalate_pct: escalatePct,
      pause_on_hold: pauseOnHold,
      policy_id: policyId,
      policy_name: policyName,
      calc_mode: (String(process.env.SLA_CALC_MODE || '').toLowerCase() === 'calendar') || (String(process.env.SLA_IGNORE_BUSINESS_TIME || '').toLowerCase() === 'true') ? 'calendar' : 'business',
    };
  }
  // Allow switching to calendar-time mode for testing (ignore weekends/business hours)
  const calendarMode = (String(process.env.SLA_CALC_MODE || '').toLowerCase() === 'calendar') || (String(process.env.SLA_IGNORE_BUSINESS_TIME || '').toLowerCase() === 'true');
  // fetch sla policy details
  let slaMinutes = 1440; // default
  let warningPct = 70;
  let escalatePct = 100;
  let pauseOnHold = true;
  let policyName: string | null = null;
  let policyId: number | null = file.sla_policy_id ?? null;
  if (file.sla_policy_id) {
    const sp = await pool.query('SELECT id, name, sla_minutes, warning_pct, escalate_pct, pause_on_hold FROM sla_policies WHERE id = $1', [file.sla_policy_id]);
    if (sp.rowCount) {
      const row = sp.rows[0];
      policyId = Number(row.id || policyId);
      policyName = row.name ?? null;
      slaMinutes = Number(row.sla_minutes || slaMinutes);
      warningPct = Number(row.warning_pct ?? warningPct);
      escalatePct = Number(row.escalate_pct ?? escalatePct);
      pauseOnHold = Boolean(row.pause_on_hold ?? pauseOnHold);
    }
  }

  // Sum business minutes for closed events but optionally exclude events that should not count
  // If pauseOnHold is true, exclude durations for events where action_type IN ('Hold','SeekInfo')
  const excludeTypes = pauseOnHold ? ['Hold','SeekInfo'] : [];
  let excludeClause = '';
  const vals: any[] = [file_id];
  if (excludeTypes.length) {
    vals.push(excludeTypes);
    excludeClause = `AND (action_type IS NULL OR action_type <> ALL($2::text[]))`;
  }

  const sumQ = calendarMode
    ? `SELECT COALESCE(SUM(FLOOR(EXTRACT(EPOCH FROM (ended_at - started_at))/60)),0) as summins FROM file_events WHERE file_id = $1 AND ended_at IS NOT NULL ${excludeClause}`
    : `SELECT COALESCE(SUM(COALESCE(business_minutes_held, FLOOR(EXTRACT(EPOCH FROM (ended_at - started_at))/60))),0) as summins FROM file_events WHERE file_id = $1 AND ended_at IS NOT NULL ${excludeClause}`;
  const sumR = await pool.query(sumQ, vals);
  const closedSum = Number(sumR.rows[0].summins || 0);

  // compute ongoing minutes for open event using DB function calculate_business_minutes, but only if its action_type is not excluded
  const openR = await pool.query('SELECT id, started_at, action_type FROM file_events WHERE file_id = $1 AND ended_at IS NULL ORDER BY seq_no DESC LIMIT 1', [file_id]);
  let ongoingMinutes = 0;
  if (openR.rowCount) {
    const row = openR.rows[0];
    const isExcluded = pauseOnHold && (row.action_type === 'Hold' || row.action_type === 'SeekInfo');
    if (!isExcluded) {
      const startedAt = row.started_at;
      if (calendarMode) {
        try {
          const calc = await pool.query('SELECT FLOOR(EXTRACT(EPOCH FROM (NOW()::timestamptz - $1::timestamptz))/60) as mins', [startedAt]);
          ongoingMinutes = Number(calc.rows?.[0]?.mins || 0);
        } catch {
          ongoingMinutes = 0;
        }
      } else {
        try {
          const calc = await pool.query('SELECT public.calculate_business_minutes($1::timestamptz, NOW()::timestamptz) as mins', [startedAt]);
          ongoingMinutes = Number(calc.rows?.[0]?.mins || 0);
          // Defensive fallback: if business-time returns 0 but there is elapsed wall time, use wall-clock minutes so testing on weekends still progresses
          if (!ongoingMinutes || ongoingMinutes <= 0) {
            const wc = await pool.query('SELECT FLOOR(EXTRACT(EPOCH FROM (NOW()::timestamptz - $1::timestamptz))/60) as mins', [startedAt]);
            const wcmins = Number(wc.rows?.[0]?.mins || 0);
            if (wcmins > 0) ongoingMinutes = wcmins;
          }
        } catch (e: any) {
          // If DB function is missing or errors, default ongoing minutes to 0 so endpoint does not fail
          ongoingMinutes = 0;
        }
      }
    } else {
      // When paused (Hold/SeekInfo) and policy says to pause, do not accrue ongoing minutes.
      ongoingMinutes = 0;
    }
  } else {
    // No open event found; fall back to computing from a file-level timestamp so SLA progresses even before first event is created
    const fallbackStart = file.date_received_accounts || file.date_initiated || file.created_at;
    if (fallbackStart) {
      try {
        if (calendarMode) {
          const wc = await pool.query('SELECT FLOOR(EXTRACT(EPOCH FROM (NOW()::timestamptz - $1::timestamptz))/60) as mins', [fallbackStart]);
          ongoingMinutes = Number(wc.rows?.[0]?.mins || 0);
        } else {
          const calc = await pool.query('SELECT public.calculate_business_minutes($1::timestamptz, NOW()::timestamptz) as mins', [fallbackStart]);
          ongoingMinutes = Number(calc.rows?.[0]?.mins || 0);
        }
      } catch {
        ongoingMinutes = 0;
      }
    }
  }

  const consumed = closedSum + ongoingMinutes;
  const percent = Math.min(100, Math.round((consumed / Math.max(1, slaMinutes)) * 100));
  const status = percent >= escalatePct ? 'Breach' : (percent >= warningPct ? 'Warning' : 'On-track');
  return {
    sla_minutes: slaMinutes,
    consumed_minutes: consumed,
    percent_used: percent,
    status,
    remaining_minutes: Math.max(0, slaMinutes - consumed),
    warning_pct: warningPct,
    escalate_pct: escalatePct,
    pause_on_hold: pauseOnHold,
    policy_id: policyId,
    policy_name: policyName,
    calc_mode: calendarMode ? 'calendar' : 'business',
  };
}

// Audit logging
export async function addAuditLog(entry: { file_id?: number | null; user_id?: number | null; action_type: 'Read'|'Write'|'Delete'; action_details?: any }) {
  try {
    const q = `INSERT INTO audit_logs(file_id, user_id, action_type, action_details) VALUES($1,$2,$3,$4::jsonb) RETURNING id`;
    const details = entry.action_details == null ? null : JSON.stringify(entry.action_details);
    const vals = [entry.file_id ?? null, entry.user_id ?? null, entry.action_type, details];
    await pool.query(q, vals);
    return true;
  } catch (e) {
    // eslint-disable-next-line no-console
    console.warn('[audit] failed to insert audit log', (e as any)?.message || e);
    return false;
  }
}

export async function listAuditLogs(query?: {
  page?: number; limit?: number; user_id?: number; file_id?: number; action_type?: string; q?: string; date_from?: string; date_to?: string;
}) {
  // Reinterpret "audit logs" as file activity: file_events plus a synthetic Created entry
  const conditions: string[] = [];
  const vals: any[] = [];
  // We'll filter after union using plain columns to avoid jsonb extraction
  if (query?.file_id) { vals.push(query.file_id); conditions.push(`lu.file_id = $${vals.length}`); }
  if (query?.user_id) {
    vals.push(query.user_id); const idx = vals.length;
    conditions.push(`(lu.from_user_id = $${idx} OR lu.to_user_id = $${idx})`);
  }
  if (query?.action_type) { vals.push(query.action_type); conditions.push(`lu.action_type = $${vals.length}`); }
  if (query?.q) {
    const idx1 = vals.push(`%${query.q}%`);
    const idx2 = vals.push(`%${query.q}%`);
    const idx3 = vals.push(`%${query.q}%`);
    conditions.push(`(lu.remarks ILIKE $${idx1} OR lu.file_no ILIKE $${idx2} OR lu.subject ILIKE $${idx3})`);
  }
  if (query?.date_from) { vals.push(query.date_from); conditions.push(`lu.action_at >= $${vals.length}`); }
  if (query?.date_to) { vals.push(query.date_to); conditions.push(`lu.action_at <= $${vals.length}`); }
  const whereSql = conditions.length ? ('WHERE ' + conditions.join(' AND ')) : '';

  const limit = query?.limit && query.limit > 0 ? Math.min(query.limit, 200) : 50;
  const page = query?.page && query.page > 0 ? query.page : 1;
  const offset = (page - 1) * limit;

  const sql = `
    WITH logs_union AS (
      SELECT 
        e.id::bigint AS id,
        e.file_id::bigint AS file_id,
        e.started_at AS action_at,
        e.action_type::text AS action_type,
        e.remarks::text AS remarks,
        e.from_user_id::bigint AS from_user_id,
        e.to_user_id::bigint AS to_user_id,
        e.ended_at,
        e.business_minutes_held,
        f.file_no::text AS file_no,
        f.subject::text AS subject,
        NULL::text AS route,
        NULL::text AS ip,
        NULL::text AS http_method,
        NULL::text AS username,
        NULL::text AS result,
        json_build_object('id', fu.id, 'username', fu.username, 'name', fu.name, 'role', fu.role) AS from_user,
        json_build_object('id', tu.id, 'username', tu.username, 'name', tu.name, 'role', tu.role) AS to_user,
        json_build_object('id', f.id, 'file_no', f.file_no) AS file,
        false AS is_synthetic
      FROM file_events e
      LEFT JOIN users fu ON fu.id = e.from_user_id
      LEFT JOIN users tu ON tu.id = e.to_user_id
      LEFT JOIN files f ON f.id = e.file_id
      UNION ALL
      SELECT 
        (1000000000 + f.id)::bigint AS id,
        f.id::bigint AS file_id,
        f.created_at AS action_at,
        'Created'::text AS action_type,
        NULL::text AS remarks,
        NULL::bigint AS from_user_id,
        f.created_by::bigint AS to_user_id,
        NULL::timestamptz AS ended_at,
        NULL::int AS business_minutes_held,
        f.file_no::text AS file_no,
        f.subject::text AS subject,
        NULL::text AS route,
        NULL::text AS ip,
        NULL::text AS http_method,
        NULL::text AS username,
        NULL::text AS result,
        NULL::json AS from_user,
        json_build_object('id', u.id, 'username', u.username, 'name', u.name, 'role', u.role) AS to_user,
        json_build_object('id', f.id, 'file_no', f.file_no) AS file,
        true AS is_synthetic
      FROM files f
      LEFT JOIN users u ON u.id = f.created_by
      UNION ALL
      SELECT 
        (2000000000 + l.id)::bigint AS id,
        NULL::bigint AS file_id,
        l.action_at AS action_at,
        CASE 
          WHEN (l.action_details->>'route') ILIKE '%/auth/login%' THEN 'Login'
          WHEN (l.action_details->>'route') ILIKE '%/auth/register%' THEN 'Register'
          ELSE l.action_type::text
        END AS action_type,
        COALESCE(
          CASE 
            WHEN (l.action_details->>'route') ILIKE '%/auth/login%' THEN 'Login: ' || COALESCE(l.action_details->>'username','')
            WHEN (l.action_details->>'route') ILIKE '%/auth/register%' THEN 'Register: ' || COALESCE(l.action_details->>'username','')
            ELSE NULL
          END,
          NULL
        ) AS remarks,
        NULL::bigint AS from_user_id,
        l.user_id::bigint AS to_user_id,
        NULL::timestamptz AS ended_at,
        NULL::int AS business_minutes_held,
        NULL::text AS file_no,
        NULL::text AS subject,
        (l.action_details->>'route')::text AS route,
        (l.action_details->>'ip')::text AS ip,
        (l.action_details->>'method')::text AS http_method,
        (l.action_details->>'username')::text AS username,
        (l.action_details->>'result')::text AS result,
        NULL::json AS from_user,
        json_build_object('id', u2.id, 'username', u2.username, 'name', u2.name, 'role', u2.role) AS to_user,
        NULL::json AS file,
        true AS is_synthetic
      FROM audit_logs l
      LEFT JOIN users u2 ON u2.id = l.user_id
      WHERE (l.action_details->>'route') ILIKE '%/auth/login%' OR (l.action_details->>'route') ILIKE '%/auth/register%'
    )
    SELECT * FROM logs_union lu
    ${whereSql}
    ORDER BY lu.action_at DESC
    LIMIT ${limit} OFFSET ${offset}
  `;

  const r = await pool.query(sql, vals);
  let total = r.rowCount || 0;
  try {
    const countSql = `WITH logs_union AS (
      SELECT e.id::bigint AS id, e.file_id::bigint AS file_id, e.started_at AS action_at, e.action_type::text AS action_type, e.remarks::text AS remarks,
        e.from_user_id::bigint AS from_user_id, e.to_user_id::bigint AS to_user_id, f.file_no::text AS file_no, f.subject::text AS subject
      FROM file_events e LEFT JOIN files f ON f.id = e.file_id
      UNION ALL
      SELECT (1000000000 + f.id)::bigint AS id, f.id::bigint AS file_id, f.created_at AS action_at, 'Created'::text AS action_type, NULL::text AS remarks,
        NULL::bigint AS from_user_id, f.created_by::bigint AS to_user_id, f.file_no::text AS file_no, f.subject::text AS subject
      FROM files f
      UNION ALL
      SELECT (2000000000 + l.id)::bigint AS id, NULL::bigint AS file_id, l.action_at AS action_at,
        CASE WHEN (l.action_details->>'route') ILIKE '%/auth/login%' THEN 'Login'
        WHEN (l.action_details->>'route') ILIKE '%/auth/register%' THEN 'Register'
        ELSE l.action_type::text END AS action_type,
        COALESCE(CASE WHEN (l.action_details->>'route') ILIKE '%/auth/login%' THEN 'Login: ' || COALESCE(l.action_details->>'username','')
            WHEN (l.action_details->>'route') ILIKE '%/auth/register%' THEN 'Register: ' || COALESCE(l.action_details->>'username','')
            ELSE NULL END, NULL) AS remarks,
        NULL::bigint AS from_user_id, l.user_id::bigint AS to_user_id, NULL::text AS file_no, NULL::text AS subject
      FROM audit_logs l
      WHERE (l.action_details->>'route') ILIKE '%/auth/login%' OR (l.action_details->>'route') ILIKE '%/auth/register%'
    )
    SELECT COUNT(*) AS cnt FROM logs_union lu ${whereSql}`;
    const cr = await pool.query(countSql, vals);
    total = Number(cr.rows?.[0]?.cnt || 0);
  } catch (e) {
    // ignore count errors
  }
  return { total, page, limit, results: r.rows };
}

// File share tokens — persist a single durable token per file. Old links stop working only on explicit regenerate.
async function ensureShareTable() {
  await pool.query(`CREATE TABLE IF NOT EXISTS file_share_tokens (
    file_id integer PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
    token_hash text NOT NULL,
    token text,
    created_by integer,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    last_used_at timestamptz
  )`);
  // Add columns/indexes for older installs
  await pool.query(`ALTER TABLE file_share_tokens ADD COLUMN IF NOT EXISTS token text`);
  await pool.query(`ALTER TABLE file_share_tokens ADD COLUMN IF NOT EXISTS created_by integer`);
  await pool.query(`ALTER TABLE file_share_tokens ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now()`);
  await pool.query(`ALTER TABLE file_share_tokens ADD COLUMN IF NOT EXISTS last_used_at timestamptz`);
  await pool.query(`CREATE UNIQUE INDEX IF NOT EXISTS ux_file_share_tokens_hash ON file_share_tokens(token_hash)`);
}

function makeRandomToken(bytes = 24) {
  return crypto.randomBytes(bytes).toString('base64url');
}

export async function setFileShareToken(file_id: number, token: string, created_by?: number | null) {
  await ensureShareTable();
  const hash = crypto.createHash('sha256').update(token).digest('hex');
  await pool.query(
    `INSERT INTO file_share_tokens(file_id, token_hash, token, created_by)
     VALUES($1,$2,$3,$4)
     ON CONFLICT (file_id) DO UPDATE SET token_hash = EXCLUDED.token_hash, token = EXCLUDED.token, created_by = COALESCE(file_share_tokens.created_by, EXCLUDED.created_by), updated_at = now()`,
    [file_id, hash, token, created_by ?? null]
  );
  return true;
}

export async function getShareToken(file_id: number): Promise<string | null> {
  await ensureShareTable();
  const r = await pool.query('SELECT token FROM file_share_tokens WHERE file_id = $1 LIMIT 1', [file_id]);
  if (!r.rowCount) return null;
  return r.rows[0].token || null;
}

export async function getOrCreateShareToken(file_id: number, created_by?: number | null, force = false): Promise<string> {
  await ensureShareTable();
  if (!force) {
    const existing = await getShareToken(file_id);
    if (existing) return existing;
  }
  const token = makeRandomToken(24);
  await setFileShareToken(file_id, token, created_by);
  return token;
}

export async function isValidFileShareToken(file_id: number, token: string) {
  await ensureShareTable();
  const r = await pool.query('SELECT token_hash FROM file_share_tokens WHERE file_id = $1 LIMIT 1', [file_id]);
  if (!r.rowCount) return false;
  const hash = crypto.createHash('sha256').update(token).digest('hex');
  const ok = r.rows[0].token_hash === hash;
  if (ok) {
    try { await pool.query('UPDATE file_share_tokens SET last_used_at = now() WHERE file_id = $1', [file_id]); } catch {}
  }
  return ok;
}

export async function findFileIdByToken(token: string): Promise<number | null> {
  await ensureShareTable();
  const hash = crypto.createHash('sha256').update(token).digest('hex');
  const r = await pool.query('SELECT file_id FROM file_share_tokens WHERE token_hash = $1 LIMIT 1', [hash]);
  if (!r.rowCount) return null;
  const id = Number(r.rows[0].file_id);
  if (id) { try { await pool.query('UPDATE file_share_tokens SET last_used_at = now() WHERE file_id = $1', [id]); } catch {} }
  return id || null;
}
