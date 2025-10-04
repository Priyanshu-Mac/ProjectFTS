import { useEffect, useMemo, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { fileService } from '../services/fileService';
import { authService } from '../services/authService';
import MovementForm from '../components/common/MovementForm';

export default function MoveFilePage() {
  const currentUser = authService.getCurrentUser();
  const [query, setQuery] = useState('');
  const [selected, setSelected] = useState<any | null>(null);

  const { data, isLoading, refetch } = useQuery({
    queryKey: ['move-files', query, currentUser?.id],
    queryFn: async () => {
      // COF and Admin can move any file; others see only those assigned to them
      const isCOForAdmin = ['cof', 'admin'].includes(String(currentUser?.role || ''));
      const params: any = { q: query || undefined, includeSla: true, limit: 50 };
      if (!isCOForAdmin) params.holder = currentUser?.id;
      const res = await fileService.listFiles(params);
      return res?.results ?? res ?? [];
    },
    enabled: !!currentUser?.id,
  });

  const rows = useMemo(() => {
    const arr = Array.isArray(data) ? data : [];
    return arr.filter((f: any) => String(f?.status || '') !== 'Closed');
  }, [data]);

  useEffect(() => {
    const t = setTimeout(() => { refetch(); }, 300);
    return () => clearTimeout(t);
  }, [query]);

  return (
    <div className="space-y-6">
      <div className="border-b border-gray-200 pb-4">
        <h1 className="text-2xl font-bold text-gray-900">Move File</h1>
        <p className="mt-1 text-sm text-gray-600">
          {['cof','admin'].includes(String(currentUser?.role || ''))
            ? 'Search any open file and record movement.'
            : 'Search your assigned files and record movement.'}
        </p>
      </div>

      <div className="bg-white border rounded p-4">
        <input
          type="text"
          className="w-full border rounded px-3 py-2"
          placeholder="Search by file no. or subject"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
        />
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <div className="bg-white border rounded p-4">
          <h3 className="font-semibold mb-3">My Assigned Files</h3>
          {isLoading ? (
            <div>Loading…</div>
          ) : rows.length === 0 ? (
            <div className="text-sm text-gray-500">No files found.</div>
          ) : (
            <div className="space-y-2 max-h-[520px] overflow-auto">
              {rows.map((f: any) => (
                <button
                  key={f.id}
                  className={`w-full text-left p-3 rounded border ${selected?.id === f.id ? 'border-indigo-500 bg-indigo-50' : 'border-gray-200 hover:bg-gray-50'}`}
                  onClick={() => setSelected(f)}
                >
                  <div className="flex items-center justify-between">
                    <div>
                      <div className="font-medium">{f.file_no}</div>
                      <div className="text-xs text-gray-500 truncate max-w-[28rem]">{f.subject}</div>
                    </div>
                    <div className="text-xs">{f.sla_status ?? '—'}</div>
                  </div>
                </button>
              ))}
            </div>
          )}
        </div>

        <div className="bg-white border rounded p-4">
          <h3 className="font-semibold mb-3">Movement</h3>
          {selected ? (
            <MovementForm
              fileId={Number(selected.id)}
              currentUser={currentUser}
              onMoved={async () => {
                setSelected(null);
                refetch();
              }}
            />
          ) : (
            <div className="text-sm text-gray-500">Select a file from the left to move.</div>
          )}
        </div>
      </div>
    </div>
  );
}
