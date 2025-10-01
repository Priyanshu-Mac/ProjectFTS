import React, { useMemo, useState, useCallback } from 'react';
import FileSearchTable from '../components/common/FileSearchTable';
import { authService } from '../services/authService';
import { useQuery } from '@tanstack/react-query';
import { fileService } from '../services/fileService';
import toast from 'react-hot-toast';

// Create a function that returns sample data covering many fields
function makeSampleRows(count = 200) {
  const offices = ['Accounts', 'Revenue', 'Legal', 'Procurement', 'IT'];
  const categories = ['Invoice', 'Audit', 'Contract', 'Policy', 'Application'];
  const statuses = ['Open', 'WithOfficer', 'WithCOF', 'Dispatched', 'OnHold', 'Closed'];
  const priorities = [null, 'Routine', 'Urgent', 'Critical'];

  const rows = Array.from({ length: count }).map((_, i) => {
    const created = new Date(Date.now() - (i * 86400000));
    return {
      id: i + 1,
      file_no: `FTS-${2025}-${String(1000 + i)}`,
      subject: `Sample subject for file ${i + 1} regarding ${categories[i % categories.length]}`,
      owning_office: offices[i % offices.length],
      category: categories[i % categories.length],
      priority: priorities[i % priorities.length],
      status: statuses[i % statuses.length],
      created_by: `user${(i % 8) + 1}`,
      created_at: created.toISOString(),
      confidential: i % 7 === 0,
      attachments_count: (i % 4),
    };
  });

  return rows;
}

export default function FileSearchPage() {
  const currentUser = authService.getCurrentUser();
  const [params, setParams] = useState<{ q?: string; status?: string; owning_office?: string; sortBy?: string; sortDir?: string; page?: number }>({ page: 1 });

  // Build the query key from params and user
  const queryKey = useMemo(() => ['files', params, currentUser?.id], [params, currentUser?.id]);

  const fetchFiles = useCallback(async () => {
    const apiParams: any = {
      q: params.q,
      status: params.status,
      office: params.owning_office,
      // backend uses `limit` and `page`
      page: params.page ?? 1,
      limit: 50,
      // sorting is not implemented server-side in current API but pass through for future
      sort_by: params.sortBy,
      sort_dir: params.sortDir,
    };

    // Clerks should only see files they created — apply created_by filter
    if ((currentUser?.role ?? '').toLowerCase() === 'clerk') {
      // backend expects `creator` param to filter by creator user id
      apiParams.creator = currentUser.id;
    }

    const res = await fileService.listFiles(apiParams);
    return res;
  }, [params, currentUser]);

  const { data, isLoading, isError } = useQuery({
    queryKey,
    queryFn: fetchFiles,
    keepPreviousData: true,
    retry: 1,
    onError: (e: any) => toast.error(String(e?.message ?? 'Failed to load files')),
  });

  // Map backend results into the FileRow shape the table expects
  const rows = useMemo(() => {
    const results = data?.results ?? [];
    return results.map((r: any, idx: number) => ({
      id: r.id,
      file_no: r.file_no ?? `FTS-?-${r.id}`,
      subject: r.subject ?? '',
      notesheet_title: r.notesheet_title ?? '',
      owning_office_id: r.owning_office?.id ?? r.owning_office_id ?? null,
      owning_office: r.owning_office?.name ?? (typeof r.owning_office === 'string' ? r.owning_office : null) ?? (r.owning_office_id ? String(r.owning_office_id) : '—'),
      // category may be provided as nested object, a name field, or an id — show best available
      category:
        r.category?.name ?? r.category_name ?? r.category ?? (r.category_id ? `#${r.category_id}` : '—'),
      // priority might be stored under different keys depending on the API; coalesce to a human value
      priority: r.priority ?? r.priority_level ?? r.priority_type ?? '—',
      status: r.status ?? 'Open',
      created_by: r.created_by_user?.username ?? r.created_by_user?.name ?? String(r.created_by ?? ''),
      created_by_user: r.created_by_user ?? null,
      current_holder_user_id: r.current_holder_user_id ?? null,
      sla_policy_id: r.sla_policy_id ?? null,
      notesheet_title: r.notesheet_title ?? '',
      date_initiated: r.date_initiated ?? null,
      date_received_accounts: r.date_received_accounts ?? null,
      created_at: r.created_at ?? r.date_initiated ?? new Date().toISOString(),
      confidentiality: !!r.confidentiality,
      attachments_count: Array.isArray(r.attachments) ? r.attachments.length : (r.attachments_count ?? 0),
      raw: r,
    }));
  }, [data]);

  // Handler called by table when user interacts with filters, search, pagination
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

  return (
    <div>
      <div className="flex items-center justify-between mb-6">
        <div>
          <h2 className="text-2xl font-bold">File Search</h2>
          <p className="text-gray-600 mt-1">Search, filter, sort and paginate files. { (currentUser?.role ?? '').toLowerCase() === 'clerk' ? 'Showing only files you created.' : '' }</p>
        </div>
      </div>

      {(!data && isLoading) && (
        <div className="p-6 bg-white border rounded">Loading files...</div>
      )}

      {isError && (
        <div className="p-6 bg-white border rounded text-red-600">Failed to load files. If you're developing locally, sample data will be used.</div>
      )}

      {/* Always render the table so client state (search input) is preserved while refetching. Pass loading flag for UI */}
      <FileSearchTable
        data={rows}
        perPage={50}
        serverSide={true}
        total={data?.total ?? rows.length}
        page={params.page}
        onChange={handleTableChange}
        loading={isLoading}
      />
    </div>
  );
}
