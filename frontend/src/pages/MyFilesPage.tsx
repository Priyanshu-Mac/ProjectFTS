import { useMemo, useState, useCallback } from 'react';
import { useQuery } from '@tanstack/react-query';
import { authService } from '../services/authService';
import { fileService } from '../services/fileService';
import FileSearchTable from '../components/common/FileSearchTable';

export default function MyFilesPage() {
  const currentUser = authService.getCurrentUser();
  const [params, setParams] = useState<{ q?: string; status?: string; page?: number }>({ page: 1 });

  const queryKey = useMemo(() => ['my-files', params, currentUser?.id, currentUser?.office_id], [params, currentUser?.id, currentUser?.office_id]);

  const fetchFiles = useCallback(async () => {
    const apiParams: any = {
      q: params.q,
      status: params.status,
      page: params.page ?? 1,
      limit: 50,
      includeSla: true,
    };
    // Officer should see all files of their office
    if (currentUser?.role === 'accounts_officer' && currentUser?.office_id) {
      apiParams.office = currentUser.office_id;
    }
    // COF/Admin can filter by office if needed (left as-is; show all if none provided)

    const res = await fileService.listFiles(apiParams);
    return res;
  }, [params, currentUser]);

  const { data, isLoading } = useQuery<any>({ queryKey, queryFn: fetchFiles });

  const rows = useMemo(() => {
    const results = (data?.results ?? data?.data ?? []) as any[];
    return results.map((r: any) => ({
      id: r.id,
      file_no: r.file_no,
      subject: r.subject,
      notesheet_title: r.notesheet_title,
      owning_office_id: r.owning_office?.id ?? r.owning_office_id ?? null,
      owning_office: r.owning_office?.name ?? r.owning_office ?? (r.owning_office_id ? `#${r.owning_office_id}` : '—'),
      category: r.category?.name ?? r.category ?? (r.category_id ? `#${r.category_id}` : '—'),
      priority: r.priority ?? '—',
      status: r.status ?? 'Open',
      created_by: r.created_by_user?.username ?? r.created_by,
      created_by_user: r.created_by_user,
      current_holder_user_id: r.current_holder_user_id,
      created_at: r.created_at ?? r.date_initiated ?? new Date().toISOString(),
      sla_status: r.sla_status,
      raw: r,
    }));
  }, [data]);

  const handleTableChange = useCallback((opts: any) => {
    setParams((p) => ({
      ...p,
      q: opts.query ?? p.q,
      status: opts.statusFilter ?? p.status,
      page: Number(opts.page ?? p.page ?? 1),
    }));
  }, []);

  return (
    <div>
      <div className="flex items-center justify-between mb-6">
        <div>
          <h2 className="text-2xl font-bold">My Files</h2>
          <p className="text-gray-600 mt-1">{currentUser?.role === 'accounts_officer' ? 'Showing all files from your office' : 'Your files'}</p>
        </div>
      </div>
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
