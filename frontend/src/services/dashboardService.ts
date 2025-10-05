import api from './api';

type FileRow = {
  id: number;
  file_no: string;
  subject?: string;
  status?: string;
  priority?: string | null;
  owning_office?: { id: number; name: string } | string | null;
  category?: { id: number; name: string } | string | null;
  current_holder_user_id?: number | null;
  created_at?: string;
  date_received_accounts?: string;
  sla_status?: 'On-track' | 'Warning' | 'Breach';
  sla_percent?: number;
  sla_remaining_minutes?: number;
  sla_warning_pct?: number;
  sla_escalate_pct?: number;
};

export const dashboardService = {
  // Officer dashboard computed on the client using /files includeSla
  async getOfficerDashboard(userId: number, opts: { onlyMine?: boolean } = { onlyMine: true }) {
    const onlyMine = opts.onlyMine !== undefined ? opts.onlyMine : true;
    const res = await api.get('/files', { params: { includeSla: true, limit: 200, ...(onlyMine ? { holder: userId } : {}) } });
    const results: FileRow[] = res.data?.results ?? res.data ?? [];
    const assigned = results; // when onlyMine=false, this effectively becomes the open list being viewed
    const overdue = assigned.filter((f) => (f.sla_status === 'Breach'));
    const dueSoon = assigned.filter((f) => (f.sla_status === 'Warning'));
    const onHold = assigned.filter((f) => (f.status === 'OnHold'));
    return {
      data: {
        summary: {
          total_assigned: assigned.length,
          total_due_soon: dueSoon.length,
          total_overdue: overdue.length,
        },
        my_queue: {
          assigned,
          due_soon: dueSoon,
          overdue,
          on_hold: onHold,
        },
        view: { onlyMine },
      },
    };
  },

  // Executive dashboard computed on the client using /files includeSla
  async getExecutiveDashboard(opts: { onlyWithCOF?: boolean } = {}) {
    const res = await api.get('/files', { params: { includeSla: true, limit: 500 } });
    const results: FileRow[] = res.data?.results ?? res.data ?? [];
    const openStatuses = new Set(['Open', 'WithOfficer', 'WithCOF', 'WaitingOnOrigin', 'OnHold']);
    let openFiles = results.filter((f) => openStatuses.has(String(f.status)));
    if (opts.onlyWithCOF) {
      openFiles = openFiles.filter((f) => String(f.status) === 'WithCOF');
    }

    const todayStr = new Date().toISOString().slice(0, 10);
    const filesToday = results.filter((f) => (f.created_at ?? '').slice(0, 10) === todayStr).length;

    // Oldest 5 open files by received date (fallback to created_at)
    const sortDate = (f: FileRow) => (f.date_received_accounts || f.created_at || '9999-12-31');
    const oldest_files = openFiles
      .slice()
      .sort((a, b) => (sortDate(a) < sortDate(b) ? -1 : sortDate(a) > sortDate(b) ? 1 : 0))
      .slice(0, 5);

    // Separate breached files from longest delays
    const breached_files = openFiles
      .filter((f) => f.sla_status === 'Breach')
      .slice()
      .sort((a, b) => (Number(b.sla_percent ?? 0) - Number(a.sla_percent ?? 0)));

    const longest_delays = openFiles
      .filter((f) => f.sla_status !== 'Breach')
      .slice()
      .sort((a, b) => (Number(b.sla_percent ?? 0) - Number(a.sla_percent ?? 0)))
      .slice(0, 10);

    const pendencyMap: Record<string, { office_code: string; office_name: string; pending_count: number; breach_count: number }>
      = {};
    for (const f of openFiles) {
      const officeName = typeof f.owning_office === 'object' ? (f.owning_office?.name ?? 'Unknown') : (f.owning_office ?? 'Unknown');
      const key = officeName || 'Unknown';
      if (!pendencyMap[key]) pendencyMap[key] = { office_code: key, office_name: officeName, pending_count: 0, breach_count: 0 };
      pendencyMap[key].pending_count += 1;
      if (f.sla_status === 'Breach') pendencyMap[key].breach_count += 1;
    }
    const pendency_by_office = Object.values(pendencyMap);

    // Imminent breaches: remaining minutes <= 24h and not already breached
    const imminent_breaches = openFiles.filter((f) => (f.sla_status !== 'Breach') && Number(f.sla_remaining_minutes ?? 999999) <= 1440).slice(0, 20).map((f) => ({
      ...f,
      // we don't have due date in business time; expose remaining minutes instead
      sla_due_date: null,
    }));

    // Officer workload leaderboard (counts only, due soon/overdue)
  const workload: Record<string, { user_id: number; assigned: number; due_soon: number; overdue: number; on_time_pct?: number; score?: number }> = {};
    for (const f of openFiles) {
      const uid = Number(f.current_holder_user_id || 0);
      if (!uid) continue;
      if (!workload[uid]) workload[uid] = { user_id: uid, assigned: 0, due_soon: 0, overdue: 0 };
      workload[uid].assigned += 1;
      if (f.sla_status === 'Warning') workload[uid].due_soon += 1;
      if (f.sla_status === 'Breach') workload[uid].overdue += 1;
    }
    // Compute a lightweight efficiency proxy: on-time% ~ (assigned - overdue)/assigned; score = 0.6*onTime + 0.4*(1 - overdue/assigned)
    const officer_workload = Object.values(workload).map((w) => {
      const assigned = Math.max(1, w.assigned);
      const onTime = Math.max(0, Math.min(1, (w.assigned - w.overdue) / assigned));
      const overdueRatio = Math.max(0, Math.min(1, w.overdue / assigned));
      const score = 0.6 * onTime + 0.4 * (1 - overdueRatio);
      return { ...w, on_time_pct: Math.round(onTime * 100), score: Math.round(score * 100) };
    }).sort((a, b) => (b.score! - a.score!)).slice(0, 10);

    // Aging buckets 0–2d, 3–5d, 6–10d, >10d (using received date fallback to created)
    const ageInDays = (f: FileRow) => {
      const d = new Date(f.date_received_accounts || f.created_at || new Date().toISOString());
      const now = new Date();
      const diff = Math.max(0, (now.getTime() - d.getTime()) / (1000 * 60 * 60 * 24));
      return Math.floor(diff);
    };
    const bucketOf = (d: number) => (d <= 2 ? '0-2' : d <= 5 ? '3-5' : d <= 10 ? '6-10' : '>10');
    const agingBucketsMap: Record<string, { bucket: string; total: number; by_category: Record<string, number> }> = {
      '0-2': { bucket: '0-2', total: 0, by_category: {} },
      '3-5': { bucket: '3-5', total: 0, by_category: {} },
      '6-10': { bucket: '6-10', total: 0, by_category: {} },
      '>10': { bucket: '>10', total: 0, by_category: {} },
    };
    for (const f of openFiles) {
      const d = ageInDays(f);
      const b = bucketOf(d);
      const catName = typeof f.category === 'object' ? (f.category?.name ?? 'Unknown') : (f.category ?? 'Unknown');
      agingBucketsMap[b].total += 1;
      agingBucketsMap[b].by_category[catName] = (agingBucketsMap[b].by_category[catName] || 0) + 1;
    }
    const aging_buckets = ['0-2','3-5','6-10','>10'].map((k) => agingBucketsMap[k]);

    // Compute a naive average TAT in days using consumed SLA minutes for closed files if present
    const closedFiles = results.filter((f) => f.status === 'Closed');
    const avgTatDays = (() => {
      const mins = closedFiles.map((f: any) => Number(f.sla_consumed_minutes ?? 0)).filter((n: number) => Number.isFinite(n) && n > 0);
      if (!mins.length) return 0;
      return Number((mins.reduce((a: number, b: number) => a + b, 0) / mins.length / 60 / 24).toFixed(1));
    })();

    // Weekly on-time %: among files created in last 7 days, percent not currently in Breach
    const now = new Date();
    const sevenDaysAgo = new Date(now.getTime() - 7 * 24 * 60 * 60 * 1000);
    const recent = results.filter((f) => {
      const d = new Date(f.created_at || f.date_received_accounts || now.toISOString());
      return d >= sevenDaysAgo;
    });
    const recentTotal = recent.length || 1;
    const recentOnTime = recent.filter((f) => f.sla_status !== 'Breach').length;
    const weeklyOnTimePct = Math.round((recentOnTime / recentTotal) * 100);

    return {
      data: {
        kpis: {
          files_in_accounts: openFiles.length,
          files_today: filesToday,
          weekly_ontime_percentage: weeklyOnTimePct,
          average_tat_days: avgTatDays,
          overdue_count: breached_files.length,
        },
        oldest_files,
        longest_delays,
        breached_files,
        pendency_by_office,
        aging_buckets,
        imminent_breaches,
        officer_workload,
        view: { onlyWithCOF: !!opts.onlyWithCOF },
      },
    };
  },

  async getAnalytics(params: Record<string, any> = {}) {
    const res = await api.get('/files', { params: { includeSla: true, limit: 500, ...params } });
    return { data: res.data };
  },
};