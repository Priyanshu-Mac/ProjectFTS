import React, { useMemo, useState, useRef, useEffect } from 'react';
import toast from 'react-hot-toast';
import { fileService } from '../../services/fileService';
import { format } from 'date-fns';

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

const dateDisplay = (iso?: string) => (iso ? format(new Date(iso), 'yyyy-MM-dd') : '—');

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
            {computedPageData.map((r) => (
              <React.Fragment key={r.id}>
                  <tr onClick={() => setExpandedId((s) => (s === r.id ? null : r.id))} className="border-t hover:bg-gray-50 cursor-pointer">
                    <td className="p-2">{r.file_no}</td>
                    <td className="p-2 max-w-xs truncate">{r.subject}</td>
                    <td className="p-2 max-w-xs truncate">{r.notesheet_title ?? '—'}</td>
                    <td className="p-2">{r.owning_office}</td>
                    <td className="p-2">{r.category}</td>
                    <td className="p-2">{r.priority ?? '—'}</td>
                    <td className="p-2">{r.status}</td>
                    <td className="p-2">{r.created_by_user?.name ?? r.created_by}</td>
                    <td className="p-2">{dateDisplay(r.created_at)}</td>
                    <td className="p-2">{r.confidentiality ? 'Yes' : 'No'}</td>
                    <td className="p-2">{r.attachments_count}</td>
                  </tr>
                {expandedId === r.id && (
                  <tr className="bg-gray-50">
                    <td colSpan={11} className="p-4">
                      <div className="grid grid-cols-2 gap-4">
                        <div>
                          <h3 className="font-semibold">Details</h3>
                          <dl className="grid grid-cols-2 gap-2 mt-2 text-sm">
                            <div><dt className="font-medium">Notesheet title</dt><dd>{r.notesheet_title ?? '—'}</dd></div>
                            <div><dt className="font-medium">Date initiated</dt><dd>{dateDisplay(r.date_initiated)}</dd></div>
                            <div><dt className="font-medium">Date received (accounts)</dt><dd>{dateDisplay(r.date_received_accounts)}</dd></div>
                            <div><dt className="font-medium">Current holder</dt><dd>{r.current_holder_user_id ?? '—'}</dd></div>
                            <div><dt className="font-medium">SLA policy</dt><dd>{r.sla_policy_id ?? '—'}</dd></div>
                            <div><dt className="font-medium">Attachments</dt><dd>{r.attachments_count}</dd></div>
                          </dl>
                          <div className="mt-3">
                            <h4 className="font-semibold">Creator</h4>
                            <div className="text-sm">{r.created_by_user?.name ?? r.created_by}</div>
                          </div>
                        </div>

                        <div>
                          <div className="flex items-center gap-4">
                            <div>
                              <button
                                onClick={async (e) => {
                                  e.stopPropagation();
                                  const token = await ensureShareToken(r.id);
                                  if (!token) return;
                                }}
                                className="px-3 py-1 bg-blue-600 text-white rounded"
                              >Create share link</button>
                            </div>
                            <div>
                              {shareTokenMap[r.id] ? (
                                <div className="flex items-start gap-4">
                                  <img src={`https://api.qrserver.com/v1/create-qr-code/?size=150x150&data=${encodeURIComponent(window.location.origin + '/files/' + r.id + '?t=' + shareTokenMap[r.id])}`} alt="QR code" />
                                  <div className="flex flex-col">
                                    <a
                                      className="text-blue-600 underline break-all"
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
                                          toast.success('Share link copied to clipboard');
                                        } catch (err) {
                                          toast.error('Failed to copy link');
                                        }
                                      }}
                                      className="mt-2 px-2 py-1 bg-gray-200 rounded text-sm"
                                    >Copy link</button>
                                  </div>
                                </div>
                              ) : (
                                <div className="text-sm text-gray-600">No share token yet</div>
                              )}
                            </div>
                          </div>

                          <div className="mt-4">
                            <h4 className="font-semibold">Raw record</h4>
                            <pre className="mt-2 p-2 bg-white border rounded text-xs overflow-auto">{JSON.stringify(r.raw ?? r, null, 2)}</pre>
                          </div>
                        </div>
                      </div>
                    </td>
                  </tr>
                )}
              </React.Fragment>
            ))}
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
