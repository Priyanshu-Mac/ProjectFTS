import { useMemo, useState, useCallback, useEffect } from 'react';
import FileSearchTable from '../components/common/FileSearchTable';
import { authService } from '../services/authService';
import { useQuery } from '@tanstack/react-query';
import { fileService } from '../services/fileService';
import { useLocation } from 'react-router-dom';
// toast intentionally not used here; errors are shown inline

export default function FileSearchPage() {
  const currentUser = authService.getCurrentUser();
  const location = useLocation() as any;
  const [params, setParams] = useState<{ q?: string; status?: string; owning_office?: string; sortBy?: string; sortDir?: string; page?: number }>({ page: 1 });
  const [onlyMine, setOnlyMine] = useState(true);
  const [onlyWithCOF, setOnlyWithCOF] = useState(false);

  const queryKey = useMemo(() => ['files', params, currentUser?.id, { onlyMine, onlyWithCOF }], [params, currentUser?.id, onlyMine, onlyWithCOF]);

  const fetchFiles = useCallback(async () => {
    const apiParams: any = {
      q: params.q,
      status: params.status,
      office: params.owning_office,
      page: params.page ?? 1,
      limit: 50,
      sort_by: params.sortBy,
      sort_dir: params.sortDir,
      includeSla: true,
    };

    const role = (currentUser?.role ?? '').toLowerCase();
    if (role === 'clerk') {
      if (currentUser?.id) apiParams.creator = currentUser.id;
    } else if (role === 'accounts_officer') {
      if (onlyMine && currentUser?.id) apiParams.holder = currentUser.id;
    } else if (role === 'cof' || role === 'admin') {
      if (onlyWithCOF) apiParams.status = 'WithCOF';
    }

    const res = await fileService.listFiles(apiParams);
    return res;
  }, [params, currentUser, onlyMine, onlyWithCOF]);

  const { data, isLoading, isError } = useQuery({
    queryKey,
    queryFn: fetchFiles,
    retry: 1,
  });

  const rows = useMemo(() => {
    const results = (data as any)?.results ?? (data as any)?.data ?? [];
    return results.map((r: any) => ({
      id: r.id,
      file_no: r.file_no ?? `FTS-?-${r.id}`,
      subject: r.subject ?? '',
      notesheet_title: r.notesheet_title ?? '',
      owning_office_id: r.owning_office?.id ?? r.owning_office_id ?? null,
      owning_office: r.owning_office?.name ?? (typeof r.owning_office === 'string' ? r.owning_office : null) ?? (r.owning_office_id ? String(r.owning_office_id) : '—'),
      category: r.category?.name ?? r.category_name ?? r.category ?? (r.category_id ? `#${r.category_id}` : '—'),
      priority: r.priority ?? r.priority_level ?? r.priority_type ?? '—',
      status: r.status ?? 'Open',
      created_by: r.created_by_user?.username ?? r.created_by_user?.name ?? String(r.created_by ?? ''),
      created_by_user: r.created_by_user ?? null,
      current_holder_user_id: r.current_holder_user_id ?? null,
      sla_policy_id: r.sla_policy_id ?? null,
      date_initiated: r.date_initiated ?? null,
      date_received_accounts: r.date_received_accounts ?? null,
      created_at: r.created_at ?? r.date_initiated ?? new Date().toISOString(),
      confidentiality: !!r.confidentiality,
      raw: r,
    }));
  }, [data]);

  const handleTableChange = useCallback((opts: any) => {
    setParams((p) => ({
      ...p,
      q: opts.query ?? p.q,
      status: opts.statusFilter ?? p.status,
      owning_office: opts.officeFilter ?? p.owning_office,
      sortBy: opts.sortBy ? String(opts.sortBy) : p.sortBy,
      sortDir: opts.sortDir ?? p.sortDir,
      page: Number(opts.page ?? p.page ?? 1),
    }));
  }, []);

  // When redirected from intake with { state: { openId } }, auto focus that file
  useEffect(() => {
    const openId = location?.state?.openId;
    if (!openId) return;
    // attempt to locate and expand/scroll to the row after data loads
    const t = setTimeout(() => {
      try {
        const row = document.querySelector(`[data-file-row="${openId}"]`);
        if (row) {
          (row as HTMLElement).scrollIntoView({ behavior: 'smooth', block: 'center' });
          (row as HTMLElement).dispatchEvent(new Event('click', { bubbles: true }));
        }
      } catch {}
    }, 300);
    return () => clearTimeout(t);
  }, [location?.state?.openId, data, isLoading]);

  return (
    <div>
      <div className="flex items-center justify-between mb-6">
        <div>
          <h2 className="text-2xl font-bold">File Search</h2>
          <p className="text-gray-600 mt-1">
            Search, filter, sort and paginate files.
            { (currentUser?.role ?? '').toLowerCase() === 'clerk' ? ' Showing only files you created.' : '' }
          </p>
        </div>
        <div className="ml-4 flex items-center gap-4">
          {((currentUser?.role ?? '').toLowerCase() === 'accounts_officer') && (
            <label className="inline-flex items-center gap-2 text-sm text-gray-700">
              <input type="checkbox" className="rounded border-gray-300" checked={onlyMine} onChange={(e) => setOnlyMine(e.target.checked)} />
              <span>Show only my assigned files</span>
            </label>
          )}
          {(((currentUser?.role ?? '').toLowerCase() === 'cof') || ((currentUser?.role ?? '').toLowerCase() === 'admin')) && (
            <label className="inline-flex items-center gap-2 text-sm text-gray-700">
              <input type="checkbox" className="rounded border-gray-300" checked={onlyWithCOF} onChange={(e) => setOnlyWithCOF(e.target.checked)} />
              <span>Show only files With COF</span>
            </label>
          )}
        </div>
      </div>

      {(!data && isLoading) && (
        <div className="p-6 bg-white border rounded">Loading files...</div>
      )}

      {isError && (
        <div className="p-6 bg-white border rounded text-red-600">Failed to load files.</div>
      )}

      <FileSearchTable
        data={rows}
        perPage={50}
        serverSide={true}
        total={(data as any)?.total ?? rows.length}
        page={params.page}
        onChange={handleTableChange}
        loading={isLoading}
      />
    </div>
  );
}
