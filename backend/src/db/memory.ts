import { Echo } from '../schemas/echo';

type FileRecord = {
  id: number;
  file_no: string;
  subject: string;
  notesheet_title: string;
  owning_office_id: number;
  category_id: number;
  priority?: 'Routine' | 'Urgent' | 'Critical';
  date_initiated?: string;
  date_received_accounts?: string;
  current_holder_user_id?: number;
  status: string;
  confidentiality?: boolean;
  sla_policy_id?: number;
  created_by?: number;
  created_at: string;
  attachments?: any[];
};

type FileEvent = {
  id: number;
  file_id?: number;
  seq_no: number;
  from_user_id?: number | null;
  to_user_id?: number | null;
  action_type: string;
  started_at: string;
  ended_at?: string | null;
  business_minutes_held?: number | null;
  remarks?: string | null;
  attachments_json?: any;
};

const files: FileRecord[] = [];
const events: FileEvent[] = [];
const queryThreads: any[] = [];
// simple in-memory sla_policies map for simulation (id -> policy)
const slaPolicies = new Map<number, { sla_minutes: number; warning_pct?: number; escalate_pct?: number; pause_on_hold?: boolean }>();
const dailyCounters = new Map<string, number>();

let fileIdSeq = 1;
let eventIdSeq = 1;

export function generateFileNo(date = new Date()): string {
  // Compute the next file number by inspecting existing files for the day
  const d = date.toISOString().slice(0, 10).replace(/-/g, ''); // YYYYMMDD
  const prefix = `ACC-${d}-`;
  // Find highest numeric suffix for today's files
  let max = 0;
  for (const f of files) {
    if (typeof f.file_no === 'string' && f.file_no.startsWith(prefix)) {
      const parts = f.file_no.split('-');
      const n = Number(parts[parts.length - 1].replace(/^0+/, '') || '0');
      if (!Number.isNaN(n) && n > max) max = n;
    }
  }
  const next = max + 1;
  return `ACC-${d}-${String(next).padStart(2, '0')}`;
}

export function createFile(payload: Partial<FileRecord>): FileRecord {
  const rec: FileRecord = {
    id: fileIdSeq++,
    file_no: payload.file_no || generateFileNo(new Date()),
    subject: payload.subject || '',
    notesheet_title: payload.notesheet_title || '',
    owning_office_id: payload.owning_office_id || 1,
    category_id: payload.category_id || 1,
    priority: (payload as any).priority,
    date_initiated: payload.date_initiated,
    date_received_accounts: payload.date_received_accounts || new Date().toISOString().slice(0,10),
    current_holder_user_id: payload.current_holder_user_id,
    status: payload.status || 'Open',
    confidentiality: payload.confidentiality || false,
    sla_policy_id: payload.sla_policy_id,
    created_by: payload.created_by,
    created_at: new Date().toISOString(),
    attachments: (payload as any).attachments ?? [],
  };
  files.push(rec);
  return rec;
}

export function listFiles(query?: {
  q?: string;
  office?: number;
  category?: number;
  status?: string;
  sla_policy_id?: number;
  holder?: number;
  page?: number;
  limit?: number;
  date_from?: string;
  date_to?: string;
}) {
  let res = files.slice().reverse();
  if (query?.q) {
    const ql = query.q.toLowerCase();
    res = res.filter(f => f.file_no.toLowerCase().includes(ql) || f.subject.toLowerCase().includes(ql) || f.notesheet_title.toLowerCase().includes(ql));
  }
  if (query?.office) {
    res = res.filter(f => f.owning_office_id === query.office);
  }
  if (query?.category) {
    res = res.filter(f => f.category_id === query.category);
  }
  if (query?.status) {
    res = res.filter(f => f.status === query.status);
  }
  if (query?.sla_policy_id) {
    res = res.filter(f => f.sla_policy_id === query.sla_policy_id);
  }
  if (query?.holder) {
    res = res.filter(f => f.current_holder_user_id === query.holder);
  }
  if ((query as any)?.creator) {
    res = res.filter(f => f.created_by === (query as any).creator);
  }
  const dateFrom = query?.date_from;
  const dateTo = query?.date_to;
  if (dateFrom) {
    res = res.filter(f => f.created_at >= dateFrom);
  }
  if (dateTo) {
    res = res.filter(f => f.created_at <= dateTo);
  }

  // pagination
  const limit = query?.limit && query.limit > 0 ? query.limit : 50;
  const page = query?.page && query.page > 0 ? query.page : 1;
  const start = (page - 1) * limit;
  const paged = res.slice(start, start + limit);
  return { total: res.length, page, limit, results: paged };
}

export function getFile(id: number) {
  return files.find(f => f.id === id) || null;
}

export function addEvent(file_id: number | undefined, payload: Partial<FileEvent>): FileEvent {
  // close previous open event for this file (ended_at = now) if any
  const now = new Date().toISOString();
  const open = events.filter(e => e.file_id === file_id && !e.ended_at).sort((a,b)=>b.seq_no-a.seq_no)[0];
  if (open) {
    open.ended_at = now;
    // naive business_minutes_held; memory adapter can't compute business minutes accurately
    open.business_minutes_held = 0;
  }

  const seq = events.filter(e => e.file_id === file_id).length + 1;
  const ev: FileEvent = {
    id: eventIdSeq++,
    file_id,
    seq_no: seq,
    from_user_id: payload.from_user_id ?? null,
    to_user_id: payload.to_user_id ?? null,
    action_type: payload.action_type || 'Forward',
    started_at: payload.started_at || now,
    ended_at: payload.ended_at ?? null,
    business_minutes_held: payload.business_minutes_held ?? null,
    remarks: payload.remarks ?? null,
    attachments_json: payload.attachments_json ?? null,
  };
  events.push(ev);

  // create query thread for SeekInfo
  if (ev.action_type === 'SeekInfo') {
    queryThreads.push({ id: queryThreads.length + 1, file_id, initiator_user_id: ev.from_user_id, target_user_id: ev.to_user_id, query_text: ev.remarks, status: 'Open', created_at: new Date().toISOString() });
  }

  // update file current holder and status
  const f = files.find(ff => ff.id === file_id);
  if (f) {
    if (ev.to_user_id) f.current_holder_user_id = ev.to_user_id;
    // map action_type to status
    if (ev.action_type === 'Close' || ev.action_type === 'Dispatch') f.status = 'Closed';
    else if (ev.action_type === 'Hold') f.status = 'OnHold';
    else if (ev.action_type === 'SeekInfo') f.status = 'WaitingOnOrigin';
    else f.status = 'WithOfficer';
  }

  return ev;
}

export function listEvents(file_id?: number) {
  return events.filter(e => (file_id ? e.file_id === file_id : true));
}

export function computeSlaStatus(file_id: number) {
  const f = files.find(ff => ff.id === file_id);
  if (!f) return null;
  const defaultSla = 1440;
  let slaMinutes = defaultSla;
  let pauseOnHold = true;
  let warningPct = 70;
  let escalatePct = 100;
  if (f.sla_policy_id && slaPolicies.has(f.sla_policy_id)) {
    const p = slaPolicies.get(f.sla_policy_id)!;
    slaMinutes = p.sla_minutes || slaMinutes;
    pauseOnHold = p.pause_on_hold ?? pauseOnHold;
    warningPct = p.warning_pct ?? warningPct;
    escalatePct = p.escalate_pct ?? escalatePct;
  }

  const evs = events.filter(e => e.file_id === file_id);
  // sum closed events but optionally exclude Hold/SeekInfo durations when pauseOnHold
  const closedSum = evs.filter(e => e.ended_at != null && !(pauseOnHold && (e.action_type === 'Hold' || e.action_type === 'SeekInfo'))).reduce((s,e)=>s+(e.business_minutes_held||0),0);

  // ongoing minutes approximated as 0 in memory adapter
  const ongoingMinutes = 0;

  const consumed = closedSum + ongoingMinutes;
  const percent = Math.min(100, Math.round((consumed / Math.max(1, slaMinutes)) * 100));
  const status = percent >= escalatePct ? 'Breach' : (percent >= warningPct ? 'Warning' : 'On-track');
  return { sla_minutes: slaMinutes, consumed_minutes: consumed, percent_used: percent, status, remaining_minutes: Math.max(0, slaMinutes - consumed) };
}

export function resetMemory() {
  files.length = 0;
  events.length = 0;
  dailyCounters.clear();
  fileIdSeq = 1;
  eventIdSeq = 1;
}

export { files as _files, events as _events };

// Simple in-memory users for auth when not using Postgres
type User = { id: number; username: string; name: string; role: string; office_id?: number | null; password_hash?: string; email?: string };
const users: User[] = [];
let userSeq = 1;

export function findUserByUsername(username: string) {
  return users.find(u => u.username === username) || null;
}

export function createUser(payload: { username: string; name: string; password_hash: string; email?: string; role?: string; office_id?: number | null }) {
  const u: User = { id: userSeq++, username: payload.username, name: payload.name, role: payload.role || 'Clerk', office_id: payload.office_id ?? null, password_hash: payload.password_hash, email: payload.email };
  users.push(u);
  return u;
}

export function updateUserPassword(userId: number, password_hash: string) {
  const u = users.find(x => x.id === userId);
  if (!u) return false;
  u.password_hash = password_hash;
  return true;
}
