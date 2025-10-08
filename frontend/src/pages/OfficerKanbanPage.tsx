import { useMemo } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { authService } from '../services/authService';
import { fileService } from '../services/fileService';

export default function OfficerKanbanPage() {
  const currentUser = authService.getCurrentUser();
  const navigate = useNavigate();
  const { data, isLoading, isError } = useQuery({
    queryKey: ['kanban', currentUser?.id],
    queryFn: async () => {
      const isCOF = ['cof','admin'].includes(String(currentUser?.role||''));
      const params: any = { includeSla: true, limit: 200 };
      if (!isCOF) params.holder = currentUser?.id;
      const res = await fileService.listFiles(params);
      return res?.results ?? res ?? [];
    },
    enabled: !!currentUser?.id,
    staleTime: 30000,
  });

  const groups = useMemo(() => {
    const rows = Array.isArray(data) ? data : [];
    const buckets: Record<string, any[]> = { 'Assigned': [], 'Due Soon': [], 'Overdue': [], 'On Hold': [], 'Awaiting Info': [] };
    const now = Date.now();
    for (const r of rows) {
      const status = String(r.status||'');
      if (status === 'OnHold') buckets['On Hold'].push(r);
      else if (status === 'WaitingOnOrigin') buckets['Awaiting Info'].push(r);
      else {
        const startedAt = new Date(r.created_at || r.date_received_accounts || Date.now()).getTime();
        const ageHrs = (now - startedAt)/(1000*60*60);
        if (ageHrs > 24) buckets['Overdue'].push(r); else if (ageHrs > 12) buckets['Due Soon'].push(r); else buckets['Assigned'].push(r);
      }
    }
    return buckets;
  }, [data]);

  if (isLoading) return <div className="p-6">Loading...</div>;
  if (isError) return <div className="p-6 text-red-600">Failed to load</div>;

  const cols = Object.entries(groups);

  return (
    <div>
  <h1 className="text-2xl font-bold mb-4">Work board</h1>
      <div className="grid grid-cols-1 md:grid-cols-3 xl:grid-cols-5 gap-4">
        {cols.map(([name, rows]) => (
          <div key={name} className="bg-gray-50 border rounded p-3">
            <div className="font-semibold text-gray-800 mb-2">{name} <span className="text-xs text-gray-500">({(rows as any[]).length})</span></div>
            <div className="space-y-2">
              {(rows as any[]).map((r:any) => (
                <button
                  key={r.id}
                  className="block w-full text-left p-2 rounded bg-white border hover:shadow"
                  onClick={() => navigate('/file-search', { state: { openId: r.id } })}
                >
                  <div className="text-sm font-medium truncate">{r.file_no}</div>
                  <div className="text-xs text-gray-600 truncate">{r.subject}</div>
                </button>
              ))}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
