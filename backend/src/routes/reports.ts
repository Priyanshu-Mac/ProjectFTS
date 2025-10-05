import { Router } from 'express';
import { listFiles, listAllEvents, computeSlaStatus } from '../db/index';
import { requireAuth } from '../middleware/auth';

const router = Router();

function toCsv(rows: any[]): string {
  if (!rows || !rows.length) return '';
  const headers = Array.from(new Set(rows.flatMap(r => Object.keys(r))));
  const esc = (v: any) => {
    if (v == null) return '';
    const s = typeof v === 'object' ? JSON.stringify(v) : String(v);
    const needs = /[",\n]/.test(s);
    return needs ? '"' + s.replace(/"/g, '""') + '"' : s;
  };
  const lines = [headers.join(',')];
  for (const r of rows) lines.push(headers.map(h => esc((r as any)[h])).join(','));
  return lines.join('\n');
}

function dateYmd(val: any): string {
  if (!val) return '';
  try {
    if (val instanceof Date) return val.toISOString().slice(0, 10);
    if (typeof val === 'number') return new Date(val).toISOString().slice(0, 10);
    if (typeof val === 'string') {
      const m = val.match(/\d{4}-\d{2}-\d{2}/);
      if (m) return m[0];
      const d = new Date(val);
      if (!isNaN(d.getTime())) return d.toISOString().slice(0, 10);
      return '';
    }
    const d = new Date(val);
    if (!isNaN(d.getTime())) return d.toISOString().slice(0, 10);
  } catch {}
  return '';
}

// CSV export for files
router.get('/files.csv', requireAuth as any, async (req, res) => {
  const user = (req as any).user;
  const role = String(user?.role || '').toLowerCase();
  const params: any = { q: (req.query as any)?.q, status: (req.query as any)?.status, holder: undefined, creator: undefined, limit: 500 };
  // Restrict visibility similar to list endpoint
  if (role === 'clerk') params.creator = Number(user?.id);
  const data = await listFiles(params);
  const rows = Array.isArray((data as any).results) ? (data as any).results : (data as any);
  const csv = toCsv(rows.map((r: any) => ({ id: r.id, file_no: r.file_no, subject: r.subject, status: r.status, holder: r.current_holder_user_id, created_at: r.created_at })));
  res.setHeader('Content-Type', 'text/csv; charset=utf-8');
  res.setHeader('Content-Disposition', `attachment; filename="files-${new Date().toISOString().slice(0,10)}.csv"`);
  res.send(csv);
});

// Intake Register: date, file no., owning office, subject, category, assigned officer
router.get('/intake.csv', requireAuth as any, async (req, res) => {
  const user = (req as any).user;
  const role = String(user?.role || '').toLowerCase();
  const params: any = { limit: 1000 };
  if (role === 'clerk') params.creator = Number(user?.id);
  const data = await listFiles(params);
  const rows = Array.isArray((data as any).results) ? (data as any).results : (data as any);
  const shaped = rows.map((r: any) => ({
    date: dateYmd(r.created_at),
    file_no: r.file_no,
    owning_office: r.owning_office?.name || r.owning_office_id,
    subject: r.subject,
    category: r.category?.name || r.category_id,
    assigned_officer: r.current_holder_user_id,
  }));
  const csv = toCsv(shaped);
  res.setHeader('Content-Type', 'text/csv; charset=utf-8');
  res.setHeader('Content-Disposition', `attachment; filename="intake-${new Date().toISOString().slice(0,10)}.csv"`);
  res.send(csv);
});

// Movement Register: file no., from, to, start, end, business time, remarks
router.get('/movements.csv', requireAuth as any, async (_req, res) => {
  const events = await listAllEvents();
  const rows = (events as any[]).map((e: any) => ({
    file_no: e.file_no || e.file_id,
    from: e.from_user ? e.from_user.name || e.from_user.username : '',
    to: e.to_user ? e.to_user.name || e.to_user.username : '',
    start: e.started_at,
    end: e.ended_at,
    business_time_mins: e.business_minutes_held,
    remarks: e.remarks,
  }));
  const csv = toCsv(rows);
  res.setHeader('Content-Type', 'text/csv; charset=utf-8');
  res.setHeader('Content-Disposition', `attachment; filename="movements-${new Date().toISOString().slice(0,10)}.csv"`);
  res.send(csv);
});

// COF Dispatch Register: file no., authority, date, covering letter no.
router.get('/cof-dispatch.csv', requireAuth as any, async (_req, res) => {
  const events = await listAllEvents();
  const rows = (events as any[])
    .filter((e: any) => String(e.action_type || '').toLowerCase() === 'dispatch')
    .map((e: any) => {
      let authority = '';
      let covering_letter_no = '';
      let remarks = e.remarks || '';
      try {
        const obj = typeof remarks === 'string' ? JSON.parse(remarks) : remarks;
        authority = obj?.authority || obj?.recipient || '';
        covering_letter_no = obj?.covering_letter_no || obj?.covering || '';
      } catch {}
      return {
        file_no: e.file_no || e.file_id,
        authority,
        date: dateYmd(e.started_at),
        covering_letter_no,
      };
    });
  const csv = toCsv(rows);
  res.setHeader('Content-Type', 'text/csv; charset=utf-8');
  res.setHeader('Content-Disposition', `attachment; filename="cof-dispatch-${new Date().toISOString().slice(0,10)}.csv"`);
  res.send(csv);
});

// Pendency by Owning Office / by Officer (with aging buckets)
router.get('/pendency.csv', requireAuth as any, async (_req, res) => {
  // Group open files by office and by officer, add aging buckets since created_at
  const data = await listFiles({ limit: 2000 });
  const rows = Array.isArray((data as any).results) ? (data as any).results : (data as any);
  const open = rows.filter((r: any) => !['CLOSED','DISPATCHED'].includes(String(r.status || '').toUpperCase()));
  function bucketDays(created_at: string) {
    const start = new Date(created_at).getTime();
    const now = Date.now();
    const days = Math.floor((now - start) / (1000*60*60*24));
    if (days <= 7) return '0-7d';
    if (days <= 15) return '8-15d';
    if (days <= 30) return '16-30d';
    if (days <= 60) return '31-60d';
    if (days <= 90) return '61-90d';
    return '90d+';
  }
  const officeAgg: Record<string, any> = {};
  const officerAgg: Record<string, any> = {};
  for (const f of open) {
    const ob = bucketDays(f.created_at);
    const office = f.owning_office?.name || `Office-${f.owning_office_id}`;
    const officer = String(f.current_holder_user_id || 'Unassigned');
    officeAgg[office] = officeAgg[office] || { group: 'office', name: office, total: 0, ['0-7d']:0, ['8-15d']:0, ['16-30d']:0, ['31-60d']:0, ['61-90d']:0, ['90d+']:0 };
    officerAgg[officer] = officerAgg[officer] || { group: 'officer', name: officer, total: 0, ['0-7d']:0, ['8-15d']:0, ['16-30d']:0, ['31-60d']:0, ['61-90d']:0, ['90d+']:0 };
    officeAgg[office][ob]++;
    officeAgg[office].total++;
    officerAgg[officer][ob]++;
    officerAgg[officer].total++;
  }
  const out = [...Object.values(officeAgg), ...Object.values(officerAgg)];
  const csv = toCsv(out as any[]);
  res.setHeader('Content-Type', 'text/csv; charset=utf-8');
  res.setHeader('Content-Disposition', `attachment; filename="pendency-${new Date().toISOString().slice(0,10)}.csv"`);
  res.send(csv);
});

// SLA Breach Log (why, where, remarks)
router.get('/sla-breaches.csv', requireAuth as any, async (_req, res) => {
  // Preload all events and build a map of latest SLAReason per file_id
  let reasonsByFileId = new Map<number, { id: number; remarks: string }>();
  try {
    const evs = await listAllEvents();
    for (const e of (evs as any[])) {
      if (String(e.action_type || '') !== 'SLAReason') continue;
      const fid = Number(e.file_id || 0);
      if (!fid) continue;
      const prev = reasonsByFileId.get(fid);
      if (!prev || Number(e.id || 0) > Number(prev.id)) {
        reasonsByFileId.set(fid, { id: Number(e.id || 0), remarks: String(e.remarks || '').trim() });
      }
    }
  } catch {}

  const data = await listFiles({ limit: 5000 });
  const rows = Array.isArray((data as any).results) ? (data as any).results : (data as any);
  const out: any[] = [];
  for (const f of rows) {
    try {
      const sla = await computeSlaStatus(Number(f.id));
      if (sla && String(sla.status).toLowerCase() === 'breach') {
        const reason = (reasonsByFileId.get(Number(f.id))?.remarks || '').trim();
        out.push({
          file_no: f.file_no,
          where: f.owning_office?.name || `Office-${f.owning_office_id}`,
          why: reason ? reason : 'Not provided yet',
          remarks: f.subject,
        });
      }
    } catch {}
  }
  const csv = toCsv(out);
  res.setHeader('Content-Type', 'text/csv; charset=utf-8');
  res.setHeader('Content-Disposition', `attachment; filename="sla-breaches-${new Date().toISOString().slice(0,10)}.csv"`);
  res.send(csv);
});

export default router;
