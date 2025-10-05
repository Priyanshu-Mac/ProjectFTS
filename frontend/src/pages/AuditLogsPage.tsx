import React from 'react';
import { useQuery } from '@tanstack/react-query';
import { auditService } from '../services/auditService';
import LoadingSpinner from '../components/common/LoadingSpinner';

const ActionPill = ({ action }: { action: string }) => {
  const color = action === 'Write' ? 'bg-blue-100 text-blue-800' : action === 'Delete' ? 'bg-red-100 text-red-800' : 'bg-gray-100 text-gray-800';
  return <span className={`px-2 py-0.5 rounded text-xs ${color}`}>{action}</span>;
};

export default function AuditLogsPage() {
  const [page, setPage] = React.useState(1);
  const pageSize = 50;
  const [q, setQ] = React.useState('');
  const [actionType, setActionType] = React.useState<string>('');
  const [userId, setUserId] = React.useState<string>('');
  const [fileId, setFileId] = React.useState<string>('');

  const { data, isLoading, error, refetch } = useQuery<any>({
    queryKey: ['auditLogs', { page, limit: pageSize, q, actionType, userId, fileId }],
    queryFn: async () => await auditService.list({ page, limit: pageSize, q: q || undefined, action_type: actionType || undefined, user_id: userId ? Number(userId) : undefined, file_id: fileId ? Number(fileId) : undefined }),
  });

  const results = data?.results || [];
  const total = data?.total || 0;
  const totalPages = Math.max(1, Math.ceil(total / pageSize));
  const [expandedId, setExpandedId] = React.useState<number | null>(null);

  const Name = ({ u, fallback }: { u?: any; fallback?: string }) => {
    if (!u) return <span className="text-gray-500">{fallback || '—'}</span>;
    return <span title={`${u.name || u.username || ''}${u.role ? ' · ' + u.role : ''}`}>{u.name || u.username || u.id}</span>;
  };

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between border-b pb-2">
        <div>
          <h1 className="text-2xl font-bold">Audit Logs</h1>
          <p className="text-sm text-gray-600">Movement history (Created and file events)</p>
        </div>
        <div className="text-sm text-gray-600">Total: {total}</div>
      </div>

      {/* Filters */}
      <div className="flex flex-wrap items-center gap-2">
        <input className="border rounded p-2" placeholder="Search details (route, path, etc)" value={q} onChange={(e) => setQ(e.target.value)} />
        <select className="border rounded p-2" value={actionType} onChange={(e) => setActionType(e.target.value)}>
          <option value="">All actions</option>
          <option value="Created">Created</option>
          <option value="Forward">Forward</option>
          <option value="Escalate">Escalate</option>
          <option value="Hold">Hold</option>
          <option value="SeekInfo">SeekInfo</option>
          <option value="Close">Close</option>
          <option value="Dispatch">Dispatch</option>
          <option value="Login">Login</option>
          <option value="Register">Register</option>
        </select>
        <input className="border rounded p-2 w-32" placeholder="User ID" value={userId} onChange={(e) => setUserId(e.target.value)} />
        <input className="border rounded p-2 w-32" placeholder="File ID" value={fileId} onChange={(e) => setFileId(e.target.value)} />
        <button className="px-3 py-2 bg-blue-600 text-white rounded" onClick={() => { setPage(1); refetch(); }}>Apply</button>
      </div>

      {/* Table */}
      <div className="overflow-x-auto bg-white border rounded">
        {isLoading ? (
          <div className="p-12 flex justify-center"><LoadingSpinner /></div>
        ) : error ? (
          <div className="p-4 text-red-600">Failed to load audit logs</div>
        ) : (
          <table className="min-w-full text-sm">
            <thead className="bg-gray-50">
              <tr>
                <th className="p-2 text-left">Time</th>
                <th className="p-2 text-left">File</th>
                <th className="p-2 text-left">Movement</th>
                <th className="p-2 text-left">Action</th>
                <th className="p-2 text-left">Remarks</th>
                <th className="p-2 text-left">More</th>
              </tr>
            </thead>
            <tbody>
              {results.map((r: any) => {
                const from = r.from_user;
                const to = r.to_user;
                const isAuth = r.action_type === 'Login' || r.action_type === 'Register';
                return (
                  <>
                    <tr key={r.id} className="border-t align-top">
                      <td className="p-2 whitespace-nowrap">{new Date(r.action_at).toLocaleString()}</td>
                      <td className="p-2">{r.file ? (
                        <a className="text-blue-600 underline" href="#" onClick={(e) => { e.preventDefault(); window.history.pushState({}, '', '/file-search'); window.dispatchEvent(new PopStateEvent('popstate')); setTimeout(() => { try { const ev = new CustomEvent('open-file-search', { detail: { id: r.file.id } }); window.dispatchEvent(ev); } catch {} }, 50); }}>
                          {r.file.file_no || r.file.id}
                        </a>
                      ) : (isAuth ? <span className="text-gray-500">—</span> : '—')}</td>
                      <td className="p-2 text-xs text-gray-800">
                        {r.action_type === 'Created' ? (
                          <div>Created by <Name u={to} fallback="Unknown" /></div>
                        ) : isAuth ? (
                          <div><Name u={to} fallback="Unknown" /> {r.action_type}</div>
                        ) : (
                          <div className="flex items-center gap-1">
                            <Name u={from} fallback="—" />
                            <span>→</span>
                            <Name u={to} fallback="—" />
                          </div>
                        )}
                      </td>
                      <td className="p-2"><ActionPill action={r.action_type} /></td>
                      <td className="p-2 text-xs text-gray-700 max-w-lg truncate" title={r.remarks || ''}>{r.remarks || '—'}</td>
                      <td className="p-2 text-xs">
                        <button className="px-2 py-1 border rounded" onClick={() => setExpandedId(expandedId === r.id ? null : r.id)}>
                          {expandedId === r.id ? 'Hide' : 'View'}
                        </button>
                      </td>
                    </tr>
                    {expandedId === r.id && (
                      <tr className="bg-gray-50">
                        <td colSpan={6} className="p-3">
                          {isAuth ? (
                            <div className="grid grid-cols-1 md:grid-cols-3 gap-3">
                              <div className="p-3 bg-white border rounded">
                                <div className="text-xs font-semibold text-gray-700">Auth Event</div>
                                <div className="mt-1 text-xs text-gray-800">
                                  <div><span className="text-gray-600">User:</span> <Name u={to} fallback="Unknown" /></div>
                                  <div className="mt-1"><span className="text-gray-600">Action:</span> {r.action_type}</div>
                                  {r.username && <div className="mt-1"><span className="text-gray-600">Username:</span> <span className="font-mono">{r.username}</span></div>}
                                  {r.result && <div className="mt-1"><span className="text-gray-600">Result:</span> <span className="font-mono">{r.result}</span></div>}
                                </div>
                                <div className="mt-2 text-[11px] text-gray-500">At: {new Date(r.action_at).toLocaleString()}</div>
                              </div>
                              <div className="p-3 bg-white border rounded">
                                <div className="text-xs font-semibold text-gray-700">Request</div>
                                <div className="mt-1 text-xs text-gray-800">
                                  <div><span className="text-gray-600">Route:</span> <span className="font-mono">{r.route || '—'}</span></div>
                                  <div className="mt-1"><span className="text-gray-600">Method:</span> <span className="font-mono">{(r.http_method || '').toUpperCase() || '—'}</span></div>
                                  <div className="mt-1"><span className="text-gray-600">IP:</span> <span className="font-mono">{r.ip || '—'}</span></div>
                                </div>
                              </div>
                              <div className="p-3 bg-white border rounded">
                                <div className="text-xs font-semibold text-gray-700">Remarks</div>
                                <div className="mt-1 text-xs text-gray-800 whitespace-pre-wrap">{r.remarks || '—'}</div>
                              </div>
                            </div>
                          ) : (
                            <div className="grid grid-cols-1 md:grid-cols-3 gap-3">
                              <div className="p-3 bg-white border rounded">
                              <div className="text-xs font-semibold text-gray-700">Movement</div>
                              <div className="mt-1 text-xs text-gray-800">
                                {r.action_type === 'Created' ? (
                                  <div>Created by <Name u={to} fallback="Unknown" /></div>
                                ) : (
                                  <div className="flex items-center gap-1">
                                    <span className="text-gray-600">From</span> <Name u={from} fallback="—" />
                                    <span className="mx-1">→</span>
                                    <span className="text-gray-600">To</span> <Name u={to} fallback="—" />
                                  </div>
                                )}
                              </div>
                              <div className="mt-2 text-[11px] text-gray-500">Action at: {new Date(r.action_at).toLocaleString()}</div>
                              {r.ended_at && <div className="mt-1 text-[11px] text-gray-500">Ended at: {new Date(r.ended_at).toLocaleString()}</div>}
                              {typeof r.business_minutes_held !== 'undefined' && r.business_minutes_held !== null && (
                                <div className="mt-1 text-[11px] text-gray-500">Business minutes: {r.business_minutes_held}</div>
                              )}
                              {r.is_synthetic && <div className="mt-2 text-[11px] text-yellow-700">Synthetic Created entry</div>}
                            </div>
                            <div className="p-3 bg-white border rounded">
                              <div className="text-xs font-semibold text-gray-700">Action</div>
                              <div className="mt-1"><ActionPill action={r.action_type} /></div>
                              <div className="mt-2 text-xs text-gray-700">
                                <div className="text-gray-600">Remarks</div>
                                <div className="mt-0.5 whitespace-pre-wrap">{r.remarks || '—'}</div>
                              </div>
                            </div>
                            <div className="p-3 bg-white border rounded">
                              <div className="text-xs font-semibold text-gray-700">File</div>
                              <div className="mt-1 text-xs text-gray-800">
                                {r.file ? (
                                  <a className="text-blue-600 underline" href="#" onClick={(e) => { e.preventDefault(); window.history.pushState({}, '', '/file-search'); window.dispatchEvent(new PopStateEvent('popstate')); setTimeout(() => { try { const ev = new CustomEvent('open-file-search', { detail: { id: r.file.id } }); window.dispatchEvent(ev); } catch {} }, 50); }}>
                                    {r.file.file_no || r.file.id}
                                  </a>
                                ) : '—'}
                              </div>
                              {r.subject && <div className="mt-1 text-[11px] text-gray-500">{r.subject}</div>}
                            </div>
                            </div>
                          )}
                        </td>
                      </tr>
                    )}
                  </>
                );
              })}
            </tbody>
          </table>
        )}
      </div>

      {/* Pagination */}
      <div className="flex items-center justify-between">
        <div className="text-sm text-gray-600">Page {page} of {totalPages}</div>
        <div className="flex items-center gap-2">
          <button className="px-2 py-1 border rounded" disabled={page === 1} onClick={() => setPage(1)}>First</button>
          <button className="px-2 py-1 border rounded" disabled={page === 1} onClick={() => setPage(p => Math.max(1, p - 1))}>Prev</button>
          <button className="px-2 py-1 border rounded" disabled={page === totalPages} onClick={() => setPage(p => Math.min(totalPages, p + 1))}>Next</button>
          <button className="px-2 py-1 border rounded" disabled={page === totalPages} onClick={() => setPage(totalPages)}>Last</button>
        </div>
      </div>
    </div>
  );
}
