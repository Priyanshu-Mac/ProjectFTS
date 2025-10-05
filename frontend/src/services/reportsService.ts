import api from './api';

export const reportsService = {
  async getPendencyByOffice() {
    const res = await api.get('/files', { params: { includeSla: true, limit: 1000 } });
    const results: any[] = res.data?.results ?? res.data ?? [];
    const openStatuses = new Set(['Open','WithOfficer','WithCOF','WaitingOnOrigin','OnHold']);
    const pendency: Record<string, number> = {};
    for (const f of results) {
      if (!openStatuses.has(String(f.status))) continue;
      const office = f.owning_office?.name || f.owning_office || `Office-${f.owning_office_id}`;
      pendency[office] = (pendency[office] || 0) + 1;
    }
    return Object.entries(pendency).map(([office, count]) => ({ office, count }));
  },

  async getSlaDistribution() {
    const res = await api.get('/files', { params: { includeSla: true, limit: 1000 } });
    const results: any[] = res.data?.results ?? res.data ?? [];
    const dist: Record<string, number> = { 'On-track': 0, 'Warning': 0, 'Breach': 0 };
    for (const f of results) {
      const s = f.sla_status || 'On-track';
      if (s in dist) dist[s] += 1; else dist['On-track'] += 1;
    }
    return dist;
  },

  async getIntakeTrend(days = 14) {
    const since = new Date(Date.now() - days * 24 * 60 * 60 * 1000).toISOString().slice(0, 10);
    const res = await api.get('/files', { params: { includeSla: false, limit: 1000, date_from: since } });
    const results: any[] = res.data?.results ?? res.data ?? [];
    const counts = new Map<string, number>();
    for (let i = days - 1; i >= 0; i--) {
      const d = new Date(Date.now() - i * 24 * 60 * 60 * 1000).toISOString().slice(0,10);
      counts.set(d, 0);
    }
    for (const f of results) {
      const d = (f.created_at || '').slice(0,10);
      if (counts.has(d)) counts.set(d, (counts.get(d) || 0) + 1);
    }
    return Array.from(counts.entries()).map(([date, count]) => ({ date, count }));
  }
};
