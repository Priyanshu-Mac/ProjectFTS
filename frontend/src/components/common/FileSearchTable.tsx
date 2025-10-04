import React, { useMemo, useState, useRef, useEffect } from 'react';
import toast from 'react-hot-toast';
import { fileService } from '../../services/fileService';
import { format } from 'date-fns';
import StatusBadge from './StatusBadge';
import Timeline from './Timeline';

type FileRow = {
  id: number;
  file_no: string;
  subject: string;
  notesheet_title?: string;
  owning_office: string;
  owning_office_id?: number | null;
  category: string;
  priority: string | null;
  status: string;
  created_by: string;
  created_by_user?: any;
  current_holder_user_id?: number | null;
  sla_policy_id?: number | null;
  date_initiated?: string | null;
  date_received_accounts?: string | null;
  created_at: string; // ISO
  confidentiality?: boolean;
  attachments_count: number;
  raw?: any;
};

interface Props {
  data: FileRow[];
  perPage?: number;
  // serverSide mode: when true the table will call onChange for control updates
  serverSide?: boolean;
  // total number of results when serverSide true
  total?: number;
  // current page when serverSide true (1-indexed)
  page?: number;
  loading?: boolean;
  onChange?: (opts: {
    query?: string;
    statusFilter?: string;
    officeFilter?: string;
    sortBy?: keyof FileRow | '';
    sortDir?: 'asc' | 'desc';
    page?: number;
  }) => void;
}

const dateDisplay = (iso?: string | null) => (iso ? format(new Date(iso), 'yyyy-MM-dd') : '—');

export default function FileSearchTable({ data, perPage = 50, serverSide = false, total: propsTotal, page: propsPage, onChange }: Props) {
  const [query, setQuery] = useState('');
  const [statusFilter, setStatusFilter] = useState('');
  const [officeFilter, setOfficeFilter] = useState('');
  const [sortBy, setSortBy] = useState<keyof FileRow | ''>('');
  const [sortDir, setSortDir] = useState<'asc' | 'desc'>('asc');
  const [page, setPage] = useState(1);
  // ref for debouncing server-side search calls
  const debounceRef = useRef<number | null>(null);

  const statuses = useMemo(() => Array.from(new Set(data.map((d) => d.status))), [data]);
  // Map offices to ids/names if backend provided objects
  const offices = useMemo(() => {
    const set = new Map<string, string>();
    data.forEach((d) => {
      // try to parse 'owning_office' if it contains a name or id-like string
      const name = (d as any).owning_office;
      const id = (d as any).owning_office_id ?? (typeof name === 'string' && name.match(/^\d+$/) ? name : undefined);
      if (id) set.set(String(id), String(name ?? id));
      else if (name) set.set(String(name), String(name));
    });
    return Array.from(set.entries()).map(([id, name]) => ({ id, name }));
  }, [data]);

  // When in serverSide mode, parent controls paging and provides total and page.
  const total = serverSide ? (propsTotal ?? data.length) : undefined;
  const totalPages = serverSide ? Math.max(1, Math.ceil((total ?? data.length) / perPage)) : undefined;

  const pageData = useMemo(() => {
    if (serverSide) return data;
    // client-side mode: filter, sort, and paginate here
    let out = data.slice();
    if (query.trim()) {
      const q = query.toLowerCase();
      out = out.filter((r) => [r.file_no, r.subject, r.owning_office, r.category, r.created_by].join(' ').toLowerCase().includes(q));
    }
    if (statusFilter) out = out.filter((r) => r.status === statusFilter);
    if (officeFilter) out = out.filter((r) => r.owning_office === officeFilter);

    if (sortBy) {
      out.sort((a, b) => {
        const va = (a as any)[sortBy];
        const vb = (b as any)[sortBy];
        if (va == null && vb == null) return 0;
        if (va == null) return sortDir === 'asc' ? -1 : 1;
        if (vb == null) return sortDir === 'asc' ? 1 : -1;
        if (typeof va === 'string' && typeof vb === 'string') {
          return sortDir === 'asc' ? va.localeCompare(vb) : vb.localeCompare(va);
        }
        if (va instanceof Date || vb instanceof Date) {
          return sortDir === 'asc' ? new Date(va).getTime() - new Date(vb).getTime() : new Date(vb).getTime() - new Date(va).getTime();
        }
        return sortDir === 'asc' ? (va as number) - (vb as number) : (vb as number) - (va as number);
      });
    }

    const t = out.length;
    const pages = Math.max(1, Math.ceil(t / perPage));
    // do not set state here (causes focus/selection loss); adjust page in an effect below
    return { rows: out.slice((page - 1) * perPage, page * perPage), pages, totalCount: t } as any;
  }, [data, query, statusFilter, officeFilter, sortBy, sortDir, page, perPage, serverSide]);

  // If client side, extract pageData.rows; if serverSide, pageData is data array
  let computedPageData: FileRow[] = [];
  let computedTotal = 0;
  let computedPages = 1;
  if (serverSide) {
    computedPageData = data;
    computedTotal = propsTotal ?? data.length;
    computedPages = Math.max(1, Math.ceil((computedTotal) / perPage));
  } else {
    const wrapped = pageData as any;
    computedPageData = wrapped.rows ?? [];
    computedTotal = wrapped.totalCount ?? computedPageData.length;
    computedPages = wrapped.pages ?? 1;
  }

  // keep page within bounds when computedPages changes
  React.useEffect(() => {
    setPage((p) => Math.min(p, computedPages));
  }, [computedPages]);

  // clear any pending debounce timer on unmount
  useEffect(() => {
    return () => {
      if (debounceRef.current) {
        window.clearTimeout(debounceRef.current);
      }
    };
  }, []);

  function toggleSort(col: keyof FileRow) {
    if (sortBy === col) {
      setSortDir((d) => (d === 'asc' ? 'desc' : 'asc'));
    } else {
      setSortBy(col);
      setSortDir('asc');
    }
    setPage(1);
    if (serverSide && onChange) {
      onChange({ query, statusFilter, officeFilter, sortBy: col, sortDir: sortDir === 'asc' ? 'desc' : 'asc', page: 1 });
    }
  }

  // expanded row id for showing QR and details
  const [expandedId, setExpandedId] = useState<number | null>(null);
  const [shareTokenMap, setShareTokenMap] = useState<Record<number, string>>({});
  const [eventsMap, setEventsMap] = useState<Record<number, any[]>>({});

  async function ensureShareToken(id: number) {
    if (shareTokenMap[id]) return shareTokenMap[id];
    try {
      const body = await fileService.createShareToken(id);
      const token = body?.token ?? '';
      if (token) setShareTokenMap((m) => ({ ...m, [id]: token }));
      return token;
    } catch (e) {
      console.error('create token failed', e);
      return '';
    }
  }

  return (
    <div>
      <div className="flex flex-col md:flex-row md:items-center md:justify-between gap-4 mb-4">
        <div className="flex items-center gap-2">
          <input
            placeholder="Search by file no, subject, office, category, creator..."
            value={query}
            onChange={(e) => {
              const v = e.target.value;
              setQuery(v);
              setPage(1);
              // debounce calling onChange to avoid refetching on every keystroke
              if (serverSide && onChange) {
                // use a ref-based timer so it survives renders
                if (debounceRef.current) window.clearTimeout(debounceRef.current);
                // capture current values and schedule the parent update
                debounceRef.current = window.setTimeout(() => {
                  onChange({ query: v, statusFilter, officeFilter, sortBy, sortDir, page: 1 });
                }, 300);
              }
            }}
            className="border rounded p-2 w-72"
          />

          <select value={statusFilter} onChange={(e) => { const v = e.target.value; setStatusFilter(v); setPage(1); if (serverSide && onChange) onChange({ query, statusFilter: v, officeFilter, sortBy, sortDir, page: 1 }); }} className="border rounded p-2">
            <option value="">All statuses</option>
            {statuses.map((s) => <option key={s} value={s}>{s}</option>)}
          </select>

          <select value={officeFilter} onChange={(e) => { const v = e.target.value; setOfficeFilter(v); setPage(1); if (serverSide && onChange) onChange({ query, statusFilter, officeFilter: v, sortBy, sortDir, page: 1 }); }} className="border rounded p-2">
            <option value="">All offices</option>
            {offices.map((o) => <option key={o.id} value={o.id}>{o.name}</option>)}
          </select>
        </div>

        <div className="text-sm text-gray-600">Showing {computedPageData.length} {serverSide ? `of ${propsTotal ?? total}` : `of ${total ?? computedPageData.length}`} results</div>
      </div>

      <div className="overflow-x-auto bg-white border rounded">
        <table className="min-w-full text-sm">
          <thead className="bg-gray-50">
            <tr>
              <th className="p-2 text-left cursor-pointer" onClick={() => toggleSort('file_no')}>File No {sortBy === 'file_no' ? (sortDir === 'asc' ? '▲' : '▼') : ''}</th>
              <th className="p-2 text-left cursor-pointer" onClick={() => toggleSort('subject')}>Subject {sortBy === 'subject' ? (sortDir === 'asc' ? '▲' : '▼') : ''}</th>
              <th className="p-2 text-left cursor-pointer" onClick={() => toggleSort('notesheet_title')}>Notesheet Title {sortBy === 'notesheet_title' ? (sortDir === 'asc' ? '▲' : '▼') : ''}</th>
              <th className="p-2 text-left cursor-pointer" onClick={() => toggleSort('owning_office')}>Owning Office {sortBy === 'owning_office' ? (sortDir === 'asc' ? '▲' : '▼') : ''}</th>
              <th className="p-2 text-left">Category</th>
              <th className="p-2 text-left">Priority</th>
              <th className="p-2 text-left">Status</th>
              <th className="p-2 text-left cursor-pointer" onClick={() => toggleSort('created_by')}>Created By {sortBy === 'created_by' ? (sortDir === 'asc' ? '▲' : '▼') : ''}</th>
              <th className="p-2 text-left cursor-pointer" onClick={() => toggleSort('created_at')}>Created At {sortBy === 'created_at' ? (sortDir === 'asc' ? '▲' : '▼') : ''}</th>
              <th className="p-2 text-left">Confidential</th>
              <th className="p-2 text-left">Attachments</th>
            </tr>
          </thead>

          <tbody>
            {computedPageData.map((r) => {
              const computePriority = (row: any): string | null => {
                const direct = row.priority && row.priority !== '—' ? String(row.priority) : '';
                if (direct) return direct;
                const name = String(row.raw?.sla_policy_name || row.raw?.policy_name || row.sla_policy_name || '').toLowerCase();
                if (!name) return null;
                if (name.includes('critical')) return 'Critical';
                if (name.includes('urgent')) return 'Urgent';
                if (name.includes('routine')) return 'Routine';
                return null;
              };
              const derivedPriority = computePriority(r);
              return (
              <React.Fragment key={r.id}>
                  <tr onClick={async () => {
                    setExpandedId((s) => (s === r.id ? null : r.id));
                    // lazy load events when expanding
                    try {
                      if (!eventsMap[r.id]) {
                        const ev = await fileService.listEvents(r.id);
                        setEventsMap((m) => ({ ...m, [r.id]: Array.isArray(ev) ? ev : [] }));
                      }
                    } catch (e) {
                      // eslint-disable-next-line no-console
                      console.warn('Failed to load events for file', r.id, e);
                    }
                  }} className="border-t hover:bg-gray-50 cursor-pointer">
                    <td className="p-2">{r.file_no}</td>
                    <td className="p-2 max-w-xs truncate">{r.subject}</td>
                    <td className="p-2 max-w-xs truncate">{r.notesheet_title ?? '—'}</td>
                    <td className="p-2">{r.owning_office}</td>
                    <td className="p-2">{r.category}</td>
                    <td className="p-2">{derivedPriority ?? '—'}</td>
                    <td className="p-2">{r.status}</td>
                    <td className="p-2">{r.created_by_user?.name ?? r.created_by}</td>
                    <td className="p-2">{dateDisplay(r.created_at)}</td>
                    <td className="p-2">{r.confidentiality ? 'Yes' : 'No'}</td>
                    <td className="p-2">{r.attachments_count}</td>
                  </tr>
                {expandedId === r.id && (
                  <tr className="bg-gray-50">
                    <td colSpan={11} className="p-4">
                      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
                        {/* Left: Metadata */}
                        <div className="space-y-4">
                          <div className="flex items-center justify-between">
                            <div>
                              <div className="text-sm text-gray-500">File No</div>
                              <div className="text-lg font-semibold">{r.file_no}</div>
                            </div>
                            <div className="flex items-center gap-2">
                              {derivedPriority ? (
                                <span className="px-2 py-0.5 rounded text-xs bg-indigo-50 text-indigo-700 border border-indigo-200">{derivedPriority}</span>
                              ) : null}
                              {r.confidentiality ? (
                                <span className="px-2 py-0.5 rounded text-xs bg-red-50 text-red-700 border border-red-200">Confidential</span>
                              ) : null}
                              <StatusBadge status={r.status} />
                            </div>
                          </div>

                          <div className="grid grid-cols-2 gap-3 text-sm">
                            <div>
                              <div className="text-gray-500">Subject</div>
                              <div className="font-medium truncate" title={r.subject}>{r.subject || '—'}</div>
                            </div>
                            <div>
                              <div className="text-gray-500">Notesheet</div>
                              <div className="font-medium truncate" title={r.notesheet_title ?? ''}>{r.notesheet_title ?? '—'}</div>
                            </div>
                            <div>
                              <div className="text-gray-500">Owning Office</div>
                              <div className="font-medium">{r.owning_office}</div>
                            </div>
                            <div>
                              <div className="text-gray-500">Category</div>
                              <div className="font-medium">{r.category}</div>
                            </div>
                            <div>
                              <div className="text-gray-500">Initiated</div>
                              <div className="font-medium">{dateDisplay(r.date_initiated)}</div>
                            </div>
                            <div>
                              <div className="text-gray-500">Received (Accounts)</div>
                              <div className="font-medium">{dateDisplay(r.date_received_accounts)}</div>
                            </div>
                            <div>
                              <div className="text-gray-500">Current Holder</div>
                              <div className="font-medium">{r.current_holder_user_id ?? '—'}</div>
                            </div>
                            <div>
                              <div className="text-gray-500">Creator</div>
                              <div className="font-medium">{r.created_by_user?.name ?? r.created_by}</div>
                            </div>
                          </div>

                          <div className="grid grid-cols-2 gap-3 text-sm">
                            <div>
                              <div className="text-gray-500">Attachments</div>
                              <div className="font-medium">{r.attachments_count}</div>
                            </div>
                            <div>
                              <div className="text-gray-500">SLA Policy</div>
                              <div className="font-medium">{(r.raw?.sla_policy_name) || (r.sla_policy_id ?? '—')}</div>
                            </div>
                          </div>

                          {/* Recent Movement (compact) */}
                          <div className="mt-4">
                            <div className="text-sm text-gray-600 mb-2">Recent Movement</div>
                            <div className="space-y-2">
                              {(eventsMap[r.id]?.slice(-3) || []).map((ev: any) => (
                                <div key={ev.id} className="text-xs text-gray-700 flex items-center justify-between">
                                  <div>
                                    <span className="font-medium">{ev.action_type}</span>
                                    <span className="ml-2">{ev.from_user?.name || ev.from_user?.username || ev.from_user_id || '—'} → {ev.to_user?.name || ev.to_user?.username || ev.to_user_id || '—'}</span>
                                  </div>
                                  <div className="text-gray-500">{ev.started_at?.slice(0,10)}</div>
                                </div>
                              ))}
                              {!eventsMap[r.id] && (
                                <div className="text-xs text-gray-500">Click row to load movement…</div>
                              )}
                              {eventsMap[r.id] && eventsMap[r.id].length === 0 && (
                                <div className="text-xs text-gray-500">No movements</div>
                              )}
                            </div>
                          </div>
                        </div>

                        {/* Right: SLA & Share */}
                        <div className="space-y-4">
                          {/* SLA & Status Card */}
                          <div className="p-4 bg-white border rounded">
                            <div className="flex items-center justify-between">
                              <div className="text-sm text-gray-600">SLA & Status</div>
                              <StatusBadge status={(r.raw?.sla_status ?? r.status)} />
                            </div>
                            <div className="mt-2 text-xs text-gray-600">{r.raw?.sla_policy_name || 'Policy'} · {r.raw?.calc_mode || 'business'}</div>
                            <div className="mt-3">
                              <div className="flex items-center justify-between text-xs text-gray-600">
                                <span>0%</span>
                                <span>{Math.min(100, Number(r.raw?.sla_percent ?? 0))}%</span>
                              </div>
                              <div className="h-2 bg-gray-200 rounded mt-1">
                                <div
                                  className={`h-2 rounded ${r.raw?.sla_status === 'Breach' ? 'bg-red-500' : r.raw?.sla_status === 'Warning' ? 'bg-yellow-500' : 'bg-green-500'}`}
                                  style={{ width: `${Math.min(100, Number(r.raw?.sla_percent ?? 0))}%` }}
                                />
                              </div>
                              <div className="mt-2 grid grid-cols-3 gap-2 text-xs text-gray-700">
                                <div>
                                  <div className="text-gray-500">SLA (mins)</div>
                                  <div className="font-medium">{r.raw?.sla_minutes ?? '—'}</div>
                                </div>
                                <div>
                                  <div className="text-gray-500">Remaining</div>
                                  <div className="font-medium">{r.raw?.sla_remaining_minutes ?? '—'}</div>
                                </div>
                                <div>
                                  <div className="text-gray-500">Thresholds</div>
                                  <div className="font-medium">{r.raw?.sla_warning_pct ?? 70}% / {r.raw?.sla_escalate_pct ?? 100}%</div>
                                </div>
                              </div>
                            </div>
                          </div>

                          {/* Share Link Card */}
                          <div className="p-4 bg-white border rounded">
                            <div className="flex items-center justify-between">
                              <div className="text-sm font-medium text-gray-900">Share</div>
                              <button
                                onClick={async (e) => {
                                  e.stopPropagation();
                                  const token = await ensureShareToken(r.id);
                                  if (!token) return;
                                }}
                                className="px-3 py-1 bg-blue-600 text-white rounded"
                              >Generate Link</button>
                            </div>
                            <div className="mt-3">
                              {shareTokenMap[r.id] ? (
                                <div className="flex items-start gap-4">
                                  <img src={`https://api.qrserver.com/v1/create-qr-code/?size=120x120&data=${encodeURIComponent(window.location.origin + '/files/' + r.id + '?t=' + shareTokenMap[r.id])}`} alt="QR code" />
                                  <div className="flex flex-col gap-2">
                                    <a
                                      className="text-blue-600 underline break-all text-xs"
                                      href={`${window.location.origin}/files/${r.id}?t=${shareTokenMap[r.id]}`}
                                      target="_blank"
                                      rel="noopener noreferrer"
                                    >
                                      {`${window.location.origin}/files/${r.id}?t=${shareTokenMap[r.id]}`}
                                    </a>
                                    <button
                                      onClick={(e) => {
                                        e.stopPropagation();
                                        const url = `${window.location.origin}/files/${r.id}?t=${shareTokenMap[r.id]}`;
                                        try {
                                          navigator.clipboard.writeText(url);
                                          toast.success('Share link copied');
                                        } catch (err) {
                                          toast.error('Failed to copy');
                                        }
                                      }}
                                      className="px-2 py-1 bg-gray-200 rounded text-xs self-start"
                                    >Copy</button>
                                  </div>
                                </div>
                              ) : (
                                <div className="text-xs text-gray-600">No link yet</div>
                              )}
                            </div>
                          </div>

                          {/* Full Timeline */}
                          <div className="p-4 bg-white border rounded">
                            <div className="flex items-center justify-between">
                              <div className="text-sm font-medium text-gray-900">Timeline</div>
                              <div className="text-xs text-gray-500">History of movements</div>
                            </div>
                            <div className="mt-3">
                              {(() => {
                                const creator = (r.raw?.created_by_user || r.created_by_user || null);
                                const createdEvent = {
                                  id: -1,
                                  seq_no: 0,
                                  action_type: 'Created',
                                  started_at: r.created_at,
                                  ended_at: r.created_at,
                                  business_minutes_held: null,
                                  remarks: null,
                                  from_user_id: creator?.id ?? null,
                                  to_user_id: null,
                                  from_user: creator ? { id: creator.id, username: creator.username, name: creator.name } : null,
                                  to_user: null,
                                } as any;
                                const evs = eventsMap[r.id] ? [createdEvent, ...eventsMap[r.id]] : [createdEvent];
                                return <Timeline events={evs as any} />;
                              })()}
                            </div>
                          </div>
                        </div>
                      </div>
                    </td>
                  </tr>
                )}
              </React.Fragment>
              );
            })}
          </tbody>
        </table>
      </div>

      {/* Pagination controls */}
      <div className="flex items-center justify-between mt-3">
        <div className="text-sm text-gray-600">Page {serverSide ? (propsPage ?? page) : page} {totalPages ? `of ${totalPages}` : ''}</div>
        <div className="flex items-center gap-2">
          <button
            disabled={(serverSide ? (propsPage ?? page) : page) === 1}
            onClick={() => {
              const p = 1;
              setPage(p);
              if (serverSide && onChange) onChange({ query, statusFilter, officeFilter, sortBy, sortDir, page: p });
            }}
            className="px-2 py-1 border rounded disabled:opacity-50"
          >First</button>

          <button
            disabled={(serverSide ? (propsPage ?? page) : page) === 1}
            onClick={() => {
              const p = (serverSide ? (propsPage ?? page) : page) - 1;
              setPage(p);
              if (serverSide && onChange) onChange({ query, statusFilter, officeFilter, sortBy, sortDir, page: p });
            }}
            className="px-2 py-1 border rounded disabled:opacity-50"
          >Prev</button>

          <button
            disabled={(serverSide ? (propsPage ?? page) : page) === (totalPages ?? 1)}
            onClick={() => {
              const p = (serverSide ? (propsPage ?? page) : page) + 1;
              setPage(p);
              if (serverSide && onChange) onChange({ query, statusFilter, officeFilter, sortBy, sortDir, page: p });
            }}
            className="px-2 py-1 border rounded disabled:opacity-50"
          >Next</button>

          <button
            disabled={(serverSide ? (propsPage ?? page) : page) === (totalPages ?? 1)}
            onClick={() => {
              const p = totalPages ?? 1;
              setPage(p);
              if (serverSide && onChange) onChange({ query, statusFilter, officeFilter, sortBy, sortDir, page: p });
            }}
            className="px-2 py-1 border rounded disabled:opacity-50"
          >Last</button>
        </div>
      </div>
    </div>
  );
}

// end of FileSearchTable
