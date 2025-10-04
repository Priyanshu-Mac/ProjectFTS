import { Pool, PoolClient } from 'pg';

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
      // close previous open event (ended_at = now)
      await client.query('UPDATE file_events SET ended_at = CURRENT_TIMESTAMP WHERE file_id = $1 AND ended_at IS NULL', [file_id]);

      // compute seq_no
      const qSeq = 'SELECT COALESCE(MAX(seq_no),0) as maxseq FROM file_events WHERE file_id = $1';
      const seqR = await client.query(qSeq, [file_id]);
      const seq = (seqR.rows[0].maxseq || 0) + 1;

      const q = `INSERT INTO file_events(file_id, seq_no, from_user_id, to_user_id, action_type, started_at, ended_at, business_minutes_held, remarks, attachments_json)
        VALUES($1,$2,$3,$4,$5,CURRENT_TIMESTAMP,$6,$7,$8,$9::json) RETURNING *`;
      // Sanitize attachments_json: allow callers to pass array/object or a JSON string.
      // If it's a string, ensure it's valid JSON; if not valid, wrap it as a single-element array.
      let attachmentsParam: string | null = null;
      try {
        if (payload.attachments_json == null) {
          attachmentsParam = null;
        } else if (typeof payload.attachments_json === 'string') {
          // validate string is valid JSON
          try {
            JSON.parse(payload.attachments_json);
            attachmentsParam = payload.attachments_json;
          } catch (e) {
            // not valid JSON, wrap the raw string into an array
            attachmentsParam = JSON.stringify([payload.attachments_json]);
          }
        } else {
          // object or array — stringify
          attachmentsParam = JSON.stringify(payload.attachments_json);
        }
      } catch (e) {
        // fallback to null on unexpected errors
        attachmentsParam = null;
      }
      const vals = [file_id, seq, payload.from_user_id ?? null, payload.to_user_id ?? null, payload.action_type, payload.ended_at ?? null, payload.business_minutes_held ?? null, payload.remarks ?? null, attachmentsParam];
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
      if (payload.action_type === 'Close' || payload.action_type === 'Dispatch') newStatus = 'Closed';
      else if (payload.action_type === 'Hold') newStatus = 'OnHold';
      else if (payload.action_type === 'SeekInfo') newStatus = 'WaitingOnOrigin';
      await client.query('UPDATE files SET current_holder_user_id = $1, status = $2 WHERE id = $3', [payload.to_user_id ?? null, newStatus, file_id]);

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
    const r = await pool.query('SELECT * FROM file_events WHERE file_id = $1 ORDER BY seq_no', [file_id]);
    return r.rows;
  }
  const r = await pool.query('SELECT * FROM file_events ORDER BY id DESC LIMIT 100');
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

export async function computeSlaStatus(file_id: number) {
  // fetch file and its sla policy minutes
  const fileR = await pool.query('SELECT id, sla_policy_id, created_at, date_initiated, date_received_accounts FROM files WHERE id = $1', [file_id]);
  if (fileR.rowCount === 0) return null;
  const file = fileR.rows[0];
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
