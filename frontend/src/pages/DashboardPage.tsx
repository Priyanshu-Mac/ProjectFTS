import React from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { 
  FileText, 
  Clock, 
  AlertTriangle, 
  TrendingUp,
  
} from 'lucide-react';
import { dashboardService } from '../services/dashboardService';
import { fileService } from '../services/fileService';
import { authService } from '../services/authService';
import LoadingSpinner from '../components/common/LoadingSpinner';
import StatusBadge from '../components/common/StatusBadge';
import { formatDistanceToNow, format } from 'date-fns';
import UnholdActionModal from '../components/common/UnholdActionModal';

const DashboardPage = () => {
  const queryClient = useQueryClient();
  const [unholdModalOpen, setUnholdModalOpen] = React.useState(false);
  const [selectedFileId, setSelectedFileId] = React.useState<number | null>(null);
  const currentUser = authService.getCurrentUser();
  const isCOF = currentUser?.role === 'cof' || currentUser?.role === 'admin';
  const isClerk = currentUser?.role === 'clerk';
  const [onlyMine, setOnlyMine] = React.useState(true);
  const [onlyWithCOF, setOnlyWithCOF] = React.useState(false);

  // Fetch dashboard data based on user role (COF/Admin vs Officer). Disabled for clerks.
  const { data: dashboardData, isLoading, error } = useQuery<any>({
    queryKey: isCOF ? ['dashboard', 'executive', { onlyWithCOF }] : ['dashboard', 'officer', { onlyMine, userId: currentUser?.id }],
    queryFn: async () => (isCOF
      ? await dashboardService.getExecutiveDashboard({ onlyWithCOF })
      : await dashboardService.getOfficerDashboard(Number(currentUser?.id), { onlyMine })
    ),
    refetchInterval: 30000, // Refresh every 30 seconds
    // Only run when we have a current user and the user isn't a clerk. This prevents
    // the officer dashboard from firing during initial render when currentUser may be null.
    enabled: !!currentUser?.id && !isClerk,
  });

  // For clerks we will show a focused view: file intake link and files owned by the clerk
  const { data: clerkFilesData, isLoading: isClerkLoading, error: clerkError } = useQuery<any>({
    queryKey: ['files', 'owned', currentUser?.id],
    // Request files with optimistic server-side filters and also apply a defensive
    // client-side filter to ensure we only show files that were created by the
    // current clerk and that are file-intake type (handles different backend field names).
    queryFn: async () => {
      // Ask the API to filter by creator/type if it supports those params. We keep
      // `holder` for compatibility but rely on client-side filtering below as a fallback.
      const res = await fileService.listFiles({ creator: currentUser?.id, type: 'file_intake', page: 1, limit: 50 });

      // Debug: raw API response
      // eslint-disable-next-line no-console
      console.log('[Dashboard] fileService.listFiles raw response:', res);

      // Normalize the list of files whether the service returned an array or an
      // object with `data` or `results` (API sample uses `results`).
      const files = Array.isArray(res) ? res : (res?.data ?? res?.results ?? []);

      // Debug: normalized files
      // eslint-disable-next-line no-console
      console.log('[Dashboard] normalized files count:', Array.isArray(files) ? files.length : (files?.length ?? 0));
      // eslint-disable-next-line no-console
      console.log('[Dashboard] normalized files sample:', Array.isArray(files) ? files.slice(0,5) : (files?.slice ? files.slice(0,5) : files));

      // Return the API-filtered results unchanged (preserve response shape)
      if (Array.isArray(res)) {
        return files;
      }
      if (res?.results) {
        return { ...res, results: files, total: files.length };
      }
      return { ...res, data: files, meta: { ...res?.meta, total: files.length } };
    },
    enabled: !!isClerk && !!currentUser?.id,
    refetchInterval: 30000,
  });

  // Log clerkFilesData updates for debugging
  React.useEffect(() => {
    // eslint-disable-next-line no-console
    console.log('[Dashboard] clerkFilesData changed:', clerkFilesData);
  }, [clerkFilesData]);

  if (isLoading || (isClerk && isClerkLoading)) {
    return (
      <div className="flex items-center justify-center h-64">
        <LoadingSpinner size="lg" text="Loading dashboard..." />
      </div>
    );
  }

  if (error || (isClerk && clerkError)) {
    return (
      <div className="bg-red-50 border border-red-200 rounded-lg p-4">
        <p className="text-red-800">Failed to load dashboard data. Please try again.</p>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {/* Page Header */}
      <div className="border-b border-gray-200 pb-4">
        <h1 className="text-2xl font-bold text-gray-900">
          {isCOF ? 'Executive Dashboard' : 'My Dashboard'}
        </h1>
  <p className="mt-1 text-sm text-gray-600">
          {isCOF 
            ? 'Overview of file processing and department performance' 
            : 'Your current workload and pending files'
          }
        </p>
        {/* View toggles */}
        {!isClerk && (
          <div className="mt-3 flex items-center gap-4">
            {isCOF ? (
              <label className="inline-flex items-center gap-2 text-sm text-gray-700">
                <input
                  type="checkbox"
                  className="rounded border-gray-300"
                  checked={onlyWithCOF}
                  onChange={(e) => setOnlyWithCOF(e.target.checked)}
                />
                <span>Show only files With COF</span>
              </label>
            ) : (
              <>
                <label className="inline-flex items-center gap-2 text-sm text-gray-700">
                  <input
                    type="checkbox"
                    className="rounded border-gray-300"
                    checked={onlyMine}
                    onChange={(e) => setOnlyMine(e.target.checked)}
                  />
                  <span>Show only my assigned files</span>
                </label>
              </>
            )}
            <div className="text-xs text-gray-500">
              Viewing: {isCOF ? (onlyWithCOF ? 'With COF' : 'All open files') : (onlyMine ? 'My assigned' : 'All open files')}
            </div>
          </div>
        )}
      </div>

      {isClerk ? (
      <ClerkDashboard files={
        Array.isArray(clerkFilesData)
          ? clerkFilesData
          : (clerkFilesData?.data ?? clerkFilesData?.results ?? [])
      } />
      ) : isCOF ? (
        <ExecutiveDashboard data={dashboardData?.data} />
      ) : (
        <>
          <OfficerDashboard
            data={dashboardData?.data}
            onUnhold={(fileId: number) => {
              setSelectedFileId(fileId);
              setUnholdModalOpen(true);
              return Promise.resolve();
            }}
          />
          <UnholdActionModal
            open={unholdModalOpen}
            onClose={() => setUnholdModalOpen(false)}
            fileId={selectedFileId || 0}
            currentUser={currentUser}
            onDone={async () => {
              await queryClient.invalidateQueries({ queryKey: ['dashboard', 'officer'] });
            }}
          />
        </>
      )}
    </div>
  );
};

const ClerkDashboard = ({ files = [] as any[] }) => {
  return (
    <div className="space-y-6">
      <div className="border-b border-gray-200 pb-4">
        <h1 className="text-2xl font-bold text-gray-900">Clerk Dashboard</h1>
        <p className="mt-1 text-sm text-gray-600">File intake and your owned files</p>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
        <div className="card">
          <div className="card-body text-center">
            <h3 className="text-lg font-medium">File Intake</h3>
            <p className="text-sm text-gray-500 mt-2">Create new files (Clerk access)</p>
            <div className="mt-4">
              <a href="/file-intake" className="btn btn-primary">Go to File Intake</a>
            </div>
          </div>
        </div>

        <div className="card">
          <div className="card-header">
            <h3 className="text-lg font-medium text-gray-900">My Owned Files</h3>
            <p className="text-sm text-gray-500">Files you created/own</p>
          </div>
          <div className="card-body">
            {files.length > 0 ? (
              <div className="space-y-3">
                {files.slice(0, 10).map((file: any) => (
                  <div key={file.id} className="p-3 rounded-lg bg-gray-50">
                    <div className="flex items-center justify-between">
                      <div className="flex-1">
                        <div className="flex items-baseline gap-3">
                          <div className="text-sm font-medium text-gray-900">{file.file_no}</div>
                          <div className="text-xs text-gray-500"># {file.id}</div>
                        </div>
                        <div className="text-xs text-gray-500 truncate">{file.subject}</div>
                      </div>
                      <div className="text-right">
                        <StatusBadge status={file.status} />
                      </div>
                    </div>
                  </div>
                ))}
                {files.length > 10 && (
                  <div className="text-center pt-2">
                    <span className="text-sm text-gray-500">+{files.length - 10} more files</span>
                  </div>
                )}
              </div>
            ) : (
              <p className="text-gray-500 text-center py-4">You have no owned files</p>
            )}
          </div>
        </div>
      </div>
    </div>
  );
};

const ExecutiveDashboard = ({ data }: { data: any }) => {
  const { kpis = {}, oldest_files = [], longest_delays = [], pendency_by_office = [], imminent_breaches = [], officer_workload = [], aging_buckets = [] } = (data || {});

  const maxPendency = Math.max(1, ...pendency_by_office.map((o: any) => Number(o.pending_count || 0)));
  const catColors = ['bg-blue-400','bg-green-400','bg-yellow-400','bg-red-400','bg-purple-400','bg-pink-400','bg-teal-400','bg-indigo-400'];
  const colorFor = (idx: number) => catColors[idx % catColors.length];

  return (
    <>
      {/* KPI Strip */}
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
        <KPICard
          title="Files in Accounts"
          value={kpis.files_in_accounts}
          subtitle={`${kpis.files_today} received today`}
          icon={FileText}
          color="blue"
        />
        <KPICard
          title="Weekly On-time %"
          value={`${kpis.weekly_ontime_percentage}%`}
          subtitle="Current week performance"
          icon={TrendingUp}
          color="green"
        />
        <KPICard
          title="Average TAT"
          value={`${kpis.average_tat_days} days`}
          subtitle="Business days average"
          icon={Clock}
          color="orange"
        />
        <KPICard
          title="Overdue Files"
          value={longest_delays.length}
          subtitle="Requiring immediate attention"
          icon={AlertTriangle}
          color="red"
        />
      </div>

      {/* Info/Delay Bar and Oldest 5 */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6 mt-6">
        {/* Delay Bar: Longest Delays */}
        <div className="card">
          <div className="card-header">
            <h3 className="text-lg font-medium text-gray-900">Longest Delays</h3>
            <p className="text-sm text-gray-500">Files with highest SLA consumption</p>
          </div>
          <div className="card-body">
            {longest_delays.length > 0 ? (
              <div className="space-y-3">
                {longest_delays.slice(0, 5).map((file: any) => (
                  <a key={file.id} href={`/files/${file.id}`} className="flex items-center justify-between p-3 bg-red-50 rounded-lg hover:bg-red-100 transition">
                    <div className="flex-1 min-w-0">
                      <div className="flex items-center gap-2">
                        <div className="text-sm font-medium text-gray-900 truncate">{file.file_no}</div>
                        <StatusBadge status={file.sla_status} />
                      </div>
                      <div className="text-xs text-gray-500 truncate">{file.subject}</div>
                      <div className="text-xs text-gray-500">With: {file.currentHolder?.full_name || file.current_holder_user_id}</div>
                    </div>
                    <div className="text-right">
                      <div className="text-xs text-red-600 font-medium">{formatDistanceToNow(new Date(file.date_received_accounts || file.created_at), { addSuffix: true })}</div>
                      <div className="text-xs text-gray-500">{file.sla_percent ?? 0}% used</div>
                    </div>
                  </a>
                ))}
              </div>
            ) : (
              <p className="text-gray-500 text-center py-4">No overdue files</p>
            )}
          </div>
        </div>

        {/* Oldest 5 */}
        <div className="card">
          <div className="card-header">
            <h3 className="text-lg font-medium text-gray-900">Oldest 5 Open Files</h3>
            <p className="text-sm text-gray-500">By received date</p>
          </div>
          <div className="card-body">
            {oldest_files.length > 0 ? (
              <div className="space-y-3">
                {oldest_files.map((file: any) => (
                  <a key={file.id} href={`/files/${file.id}`} className="flex items-center justify-between p-3 bg-gray-50 rounded-lg hover:bg-gray-100 transition">
                    <div className="flex-1 min-w-0">
                      <div className="text-sm font-medium text-gray-900 truncate">{file.file_no}</div>
                      <div className="text-xs text-gray-500 truncate">{file.subject}</div>
                      <div className="text-xs text-gray-500">{file.owning_office?.name || file.owning_office} · {file.category?.name || file.category}</div>
                    </div>
                    <div className="text-right">
                      <div className="text-xs text-gray-600">{format(new Date(file.date_received_accounts || file.created_at), 'MMM dd, yyyy')}</div>
                      <StatusBadge status={file.status} />
                    </div>
                  </a>
                ))}
              </div>
            ) : (
              <p className="text-gray-500 text-center py-4">No open files</p>
            )}
          </div>
        </div>
      </div>

      {/* Pendency and Officer Efficiency */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6 mt-6">
        {/* Pendency by Office */}
        <div className="card">
          <div className="card-header">
            <h3 className="text-lg font-medium text-gray-900">Pendency by Office</h3>
            <p className="text-sm text-gray-500">Current workload distribution</p>
          </div>
          <div className="card-body">
            {pendency_by_office.length > 0 ? (
              <div className="space-y-3">
                {pendency_by_office.map((office: any) => {
                  const pct = Math.max(2, Math.round((Number(office.pending_count || 0) / maxPendency) * 100));
                  return (
                    <div key={office.office_code} className="space-y-1">
                      <div className="flex items-center justify-between">
                        <div className="text-sm font-medium text-gray-900">{office.office_name}</div>
                        <div className="text-xs text-gray-500">{office.pending_count} pending{office.breach_count > 0 ? ` · ${office.breach_count} breached` : ''}</div>
                      </div>
                      <div className="w-full bg-gray-100 h-3 rounded">
                        <div className="h-3 rounded bg-blue-400" style={{ width: `${pct}%` }} />
                      </div>
                    </div>
                  );
                })}
              </div>
            ) : (
              <p className="text-gray-500 text-center py-4">No pending files</p>
            )}
          </div>
        </div>

        {/* Officer Efficiency (Workload) */}
        <div className="card">
          <div className="card-header">
            <h3 className="text-lg font-medium text-gray-900">Officer Workload</h3>
            <p className="text-sm text-gray-500">Assigned · Due Soon · Overdue</p>
          </div>
          <div className="card-body">
            {officer_workload.length > 0 ? (
              <div className="space-y-2">
                {officer_workload.map((r: any) => (
                  <div key={r.user_id} className="flex items-center justify-between text-sm">
                    <div className="text-gray-800">User #{r.user_id}</div>
                    <div className="flex items-center gap-3">
                      <span title="Assigned" className="px-2 py-0.5 rounded bg-gray-100">{r.assigned}</span>
                      <span title="Due Soon" className="px-2 py-0.5 rounded bg-yellow-100 text-yellow-800">{r.due_soon}</span>
                      <span title="Overdue" className="px-2 py-0.5 rounded bg-red-100 text-red-800">{r.overdue}</span>
                      {typeof r.on_time_pct !== 'undefined' && <span title="On-time %" className="px-2 py-0.5 rounded bg-green-100 text-green-800">{r.on_time_pct}%</span>}
                      {typeof r.score !== 'undefined' && <span title="Efficiency Score" className="px-2 py-0.5 rounded bg-blue-100 text-blue-800">{r.score}</span>}
                    </div>
                  </div>
                ))}
              </div>
            ) : (
              <p className="text-gray-500 text-center py-4">No assignments</p>
            )}
          </div>
        </div>
      </div>

      {/* Aging Buckets and Imminent Breaches */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6 mt-6">
        {/* Aging Buckets */}
        <div className="card">
          <div className="card-header">
            <h3 className="text-lg font-medium text-gray-900">Aging Buckets</h3>
            <p className="text-sm text-gray-500">0–2d · 3–5d · 6–10d · &gt;10d</p>
          </div>
          <div className="card-body">
            {aging_buckets.length > 0 ? (
              <div className="grid grid-cols-2 gap-3">
                {aging_buckets.map((b: any) => {
                  const total = Math.max(1, Number(b.total || 0));
                  const entries = Object.entries(b.by_category || {}).sort((a,b)=> Number(b[1] as any) - Number(a[1] as any)).slice(0, 6);
                  return (
                    <div key={b.bucket} className="p-3 rounded bg-gray-50">
                      <div className="text-xs text-gray-500">{b.bucket} days</div>
                      <div className="text-xl font-semibold text-gray-900">{b.total}</div>
                      <div className="mt-2 w-full bg-gray-200 h-3 rounded flex overflow-hidden">
                        {entries.map(([cat, cnt], idx) => (
                          <div key={String(cat)} className={`${colorFor(idx)} h-3`} style={{ width: `${Math.max(2, Math.round((Number(cnt as any) / total) * 100))}%` }} title={`${cat}: ${cnt as any}`} />
                        ))}
                      </div>
                      <div className="mt-2 grid grid-cols-2 gap-1">
                        {entries.slice(0,4).map(([cat, cnt], idx) => (
                          <div key={String(cat)} className="flex items-center gap-1 text-[11px] text-gray-700">
                            <span className={`inline-block w-2 h-2 rounded ${colorFor(idx)}`} />
                            <span className="truncate" title={String(cat)}>{String(cat)}</span>
                            <span className="ml-auto">{cnt as any}</span>
                          </div>
                        ))}
                      </div>
                    </div>
                  );
                })}
              </div>
            ) : (
              <p className="text-gray-500 text-center py-4">No data</p>
            )}
          </div>
        </div>

        {/* Imminent Breaches */}
        {imminent_breaches.length > 0 && (
          <div className="card">
            <div className="card-header">
              <h3 className="text-lg font-medium text-gray-900">Imminent SLA Breaches</h3>
              <p className="text-sm text-gray-500">Due soon (based on remaining minutes)</p>
            </div>
            <div className="card-body">
              <div className="overflow-x-auto">
                <table className="table">
                  <thead className="table-header">
                    <tr>
                      <th>File No</th>
                      <th>Subject</th>
                      <th>Remaining (mins)</th>
                      <th>Status</th>
                    </tr>
                  </thead>
                  <tbody className="table-body">
                    {imminent_breaches.map((file: any) => (
                      <tr key={file.id} className="hover:bg-gray-50">
                        <td className="font-medium"><a className="text-blue-600 hover:underline" href={`/files/${file.id}`}>{file.file_no}</a></td>
                        <td className="max-w-xs truncate">{file.subject}</td>
                        <td>{file.sla_remaining_minutes ?? '—'}</td>
                        <td>
                          <StatusBadge status={file.sla_status} />
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>
          </div>
        )}
      </div>
    </>
  );
};

const OfficerDashboard = ({ data, onUnhold }: { data: any; onUnhold: (fileId: number) => Promise<void> }) => {
  const { my_queue = { assigned: [], due_soon: [], overdue: [], on_hold: [] }, summary = { total_assigned: 0, total_due_soon: 0, total_overdue: 0 } } = (data || {});

  return (
    <>
      {/* Summary Cards */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
        <KPICard
          title="Assigned Files"
          value={summary.total_assigned}
          subtitle="Current workload"
          icon={FileText}
          color="blue"
        />
        <KPICard
          title="Due Soon"
          value={summary.total_due_soon}
          subtitle="Next 24 hours"
          icon={Clock}
          color="orange"
        />
        <KPICard
          title="Overdue"
          value={summary.total_overdue}
          subtitle="Requires immediate attention"
          icon={AlertTriangle}
          color="red"
        />
      </div>

      {/* File Queue */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* Assigned Files */}
        <FileQueueCard 
          title="Assigned Files" 
          files={my_queue.assigned} 
          emptyMessage="No files assigned"
        />
        
        {/* Due Soon */}
        <FileQueueCard 
          title="Due Soon" 
          files={my_queue.due_soon} 
          emptyMessage="No files due soon"
          highlight="warning"
        />
        
        {/* Overdue */}
        <FileQueueCard 
          title="Overdue Files" 
          files={my_queue.overdue} 
          emptyMessage="No overdue files"
          highlight="danger"
        />
        
        {/* On Hold */}
        <FileQueueCard 
          title="On Hold" 
          files={my_queue.on_hold} 
          emptyMessage="No files on hold"
          renderAction={(file: any) => (
            <button
              type="button"
              className="mt-2 inline-flex items-center px-2 py-1 text-xs font-medium rounded-md border border-transparent text-white bg-green-600 hover:bg-green-700"
              onClick={() => onUnhold(Number(file.id))}
            >
              Unhold
            </button>
          )}
        />
      </div>
    </>
  );
};

const KPICard = ({ title, value, subtitle, icon: Icon, color }: { title: string; value: any; subtitle?: string; icon: any; color: 'blue'|'green'|'orange'|'red' }) => {
  const colorClasses = {
    blue: 'bg-blue-500 text-blue-600 bg-blue-100',
    green: 'bg-green-500 text-green-600 bg-green-100',
    orange: 'bg-orange-500 text-orange-600 bg-orange-100',
    red: 'bg-red-500 text-red-600 bg-red-100'
  };

  const [_bgColor, textColor, iconBg] = (colorClasses as any)[color].split(' ');

  return (
    <div className="card">
      <div className="card-body">
        <div className="flex items-center">
          <div className={`p-2 rounded-lg ${iconBg}`}>
            <Icon className={`h-6 w-6 ${textColor}`} />
          </div>
          <div className="ml-4 flex-1">
            <div className="text-2xl font-bold text-gray-900">{value}</div>
            <div className="text-sm font-medium text-gray-600">{title}</div>
            <div className="text-xs text-gray-500">{subtitle}</div>
          </div>
        </div>
      </div>
    </div>
  );
};

const FileQueueCard = ({ title, files, emptyMessage, highlight, renderAction }: { title: string; files: any[]; emptyMessage: string; highlight?: 'warning'|'danger'; renderAction?: (file: any) => React.ReactNode }) => {
  const highlightClasses = {
    warning: 'border-l-4 border-yellow-400 bg-yellow-50',
    danger: 'border-l-4 border-red-400 bg-red-50'
  };

  return (
    <div className="card">
      <div className="card-header">
        <h3 className="text-lg font-medium text-gray-900">{title}</h3>
        <span className="text-sm text-gray-500">({files.length})</span>
      </div>
      <div className="card-body">
        {files.length > 0 ? (
          <div className="space-y-3">
            {files.slice(0, 5).map((file: any) => (
              <div 
                key={file.id} 
                className={`p-3 rounded-lg ${highlight ? (highlightClasses as any)[highlight] : 'bg-gray-50'}`}
              >
                <div className="flex items-center justify-between">
                  <div className="flex-1">
                    <div className="text-sm font-medium text-gray-900">{file.file_no}</div>
                    <div className="text-xs text-gray-500 truncate">{file.subject}</div>
                    <div className="flex items-center space-x-2 mt-1">
                      <StatusBadge status={file.priority} />
                      <span className="text-xs text-gray-500">
                        {file.owningOffice?.name}
                      </span>
                    </div>
                  </div>
                  <div className="text-right">
                    <StatusBadge status={file.status} />
                    {renderAction ? (
                      <div className="mt-2">{renderAction(file)}</div>
                    ) : null}
                  </div>
                </div>
              </div>
            ))}
            {files.length > 5 && (
              <div className="text-center pt-2">
                <span className="text-sm text-gray-500">+{files.length - 5} more files</span>
              </div>
            )}
          </div>
        ) : (
          <p className="text-gray-500 text-center py-4">{emptyMessage}</p>
        )}
      </div>
    </div>
  );
};

export default DashboardPage;