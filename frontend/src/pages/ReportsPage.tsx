// Reports page with links to CSV exports
import { useEffect, useState } from 'react';
import toast from 'react-hot-toast';
import api from '../services/api';
import { reportsService } from '../services/reportsService';
import {
  BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip as RTooltip, ResponsiveContainer, Legend as RLegend,
  PieChart, Pie, Cell,
  AreaChart, Area
} from 'recharts';

export default function ReportsPage() {
  const [downloading, setDownloading] = useState(false);
  const [selectedExport, setSelectedExport] = useState<string>('files');

  async function downloadCsv(path: string, name: string) {
    try {
      setDownloading(true);
      const res = await api.get(path, { responseType: 'blob', headers: { Accept: 'text/csv' } });
      const blob = new Blob([res.data], { type: 'text/csv;charset=utf-8;' });
      const url = window.URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = `${name}-${new Date().toISOString().slice(0,10)}.csv`;
      document.body.appendChild(a);
      a.click();
      a.remove();
      window.URL.revokeObjectURL(url);
    } catch (e: any) {
      const msg = e?.response?.data?.error || 'Failed to download CSV';
      toast.error(msg);
    } finally {
      setDownloading(false);
    }
  }
  const exportOptions = [
    { key: 'files', label: 'Files (All)', path: '/reports/files.csv', name: 'files' },
    { key: 'intake', label: 'Intake Register', path: '/reports/intake.csv', name: 'intake' },
    { key: 'movements', label: 'Movement Register', path: '/reports/movements.csv', name: 'movements' },
    { key: 'cof-dispatch', label: 'COF Dispatch Register', path: '/reports/cof-dispatch.csv', name: 'cof-dispatch' },
    { key: 'pendency', label: 'Pendency (Office/Officer)', path: '/reports/pendency.csv', name: 'pendency' },
    { key: 'sla-breaches', label: 'SLA Breach Log', path: '/reports/sla-breaches.csv', name: 'sla-breaches' },
  ];
  const selected = exportOptions.find(o => o.key === selectedExport) || exportOptions[0];
  return (
    <div className="space-y-4">
      <h1 className="text-2xl font-bold">Reports & Exports</h1>
      <div className="card">
        <div className="card-header"><h3 className="text-lg font-semibold">Exports</h3></div>
        <div className="card-body">
          <div className="flex flex-col sm:flex-row items-stretch sm:items-center gap-3">
            <div className="flex-1 min-w-[240px]">
              <label className="block text-sm font-medium text-gray-700 mb-1">Select CSV export</label>
              <select
                className="w-full border rounded px-3 py-2 bg-white"
                value={selectedExport}
                onChange={(e) => setSelectedExport(e.target.value)}
              >
                {exportOptions.map((opt) => (
                  <option key={opt.key} value={opt.key}>{opt.label}</option>
                ))}
              </select>
            </div>
            <div>
              <label className="block text-sm font-medium text-transparent mb-1">Download</label>
              <button
                className="btn btn-primary"
                onClick={() => downloadCsv(selected.path, selected.name)}
                disabled={downloading}
                title={`Download ${selected.label}`}
              >
                {downloading ? 'Preparing…' : 'Download CSV'}
              </button>
            </div>
          </div>
        </div>
      </div>

      {/* Charts */}
      <ChartsBlock />
    </div>
  );
}

function ChartsBlock() {
  const [loading, setLoading] = useState(true);
  const [pendency, setPendency] = useState<Array<{ office: string; count: number }>>([]);
  const [slaDist, setSlaDist] = useState<Record<string, number>>({ 'On-track': 0, 'Warning': 0, 'Breach': 0 });
  const [intake, setIntake] = useState<Array<{ date: string; count: number }>>([]);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const [p, s, i] = await Promise.all([
          reportsService.getPendencyByOffice(),
          reportsService.getSlaDistribution(),
          reportsService.getIntakeTrend(14),
        ]);
        if (!cancelled) {
          setPendency(p);
          setSlaDist(s);
          setIntake(i);
        }
      } catch (e: any) {
        // eslint-disable-next-line no-console
        console.error(e);
        toast.error('Failed to load charts');
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => { cancelled = true; };
  }, []);

  // datasets are computed inline for Recharts

  if (loading) {
    return (
      <div className="card">
        <div className="card-body">Loading charts…</div>
      </div>
    );
  }

  return (
    <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
      <div className="card">
        <div className="card-header"><h3 className="text-lg font-semibold">Pendency by Office</h3></div>
        <div className="card-body" style={{ height: 320 }}>
          <ResponsiveContainer width="100%" height="100%">
            <BarChart data={pendency.map((p) => ({ name: p.office, count: p.count }))} margin={{ top: 10, right: 10, left: -20, bottom: 0 }}>
              <CartesianGrid strokeDasharray="3 3" />
              <XAxis dataKey="name" tick={{ fontSize: 12 }} interval={0} angle={-20} textAnchor="end" height={60} />
              <YAxis allowDecimals={false} />
              <RTooltip />
              <Bar dataKey="count" fill="#3b82f6" name="Pending" />
            </BarChart>
          </ResponsiveContainer>
        </div>
      </div>

      <div className="card">
        <div className="card-header"><h3 className="text-lg font-semibold">SLA Distribution</h3></div>
        <div className="card-body" style={{ height: 320 }}>
          <ResponsiveContainer width="100%" height="100%">
            <PieChart>
              <Pie dataKey="value" nameKey="name" data={[
                { name: 'On-track', value: slaDist['On-track'] || 0, color: '#10b981' },
                { name: 'Warning', value: slaDist['Warning'] || 0, color: '#f59e0b' },
                { name: 'Breach', value: slaDist['Breach'] || 0, color: '#ef4444' },
              ]} cx="50%" cy="50%" outerRadius={90} label>
                {[
                  { name: 'On-track', value: slaDist['On-track'] || 0, color: '#10b981' },
                  { name: 'Warning', value: slaDist['Warning'] || 0, color: '#f59e0b' },
                  { name: 'Breach', value: slaDist['Breach'] || 0, color: '#ef4444' },
                ].map((entry, index) => (
                  <Cell key={`cell-${index}`} fill={entry.color} />
                ))}
              </Pie>
              <RLegend verticalAlign="bottom" height={36} />
              <RTooltip />
            </PieChart>
          </ResponsiveContainer>
        </div>
      </div>

      <div className="card lg:col-span-1">
        <div className="card-header"><h3 className="text-lg font-semibold">Intake (Last 14 days)</h3></div>
        <div className="card-body" style={{ height: 320 }}>
          <ResponsiveContainer width="100%" height="100%">
            <AreaChart data={intake.map((d) => ({ name: d.date.slice(5), count: d.count }))} margin={{ top: 10, right: 10, left: -10, bottom: 0 }}>
              <defs>
                <linearGradient id="colorIntake" x1="0" y1="0" x2="0" y2="1">
                  <stop offset="5%" stopColor="#6366f1" stopOpacity={0.8}/>
                  <stop offset="95%" stopColor="#6366f1" stopOpacity={0}/>
                </linearGradient>
              </defs>
              <CartesianGrid strokeDasharray="3 3" />
              <XAxis dataKey="name" />
              <YAxis allowDecimals={false} />
              <RTooltip />
              <Area type="monotone" dataKey="count" stroke="#6366f1" fillOpacity={1} fill="url(#colorIntake)" />
            </AreaChart>
          </ResponsiveContainer>
        </div>
      </div>
    </div>
  );
}
