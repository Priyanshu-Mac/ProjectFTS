import { useEffect, useState } from 'react';
import { useParams, useSearchParams } from 'react-router-dom';
import { useNavigate } from 'react-router-dom';
import { fileService } from '../services/fileService';
import { authService } from '../services/authService';
import toast from 'react-hot-toast';
import MovementForm from '../components/common/MovementForm';
import UnholdActionModal from '../components/common/UnholdActionModal';
import { useQueryClient } from '@tanstack/react-query';
import Timeline from '../components/common/Timeline';

export default function FileDetailPage() {
  const { id } = useParams();
  const [search] = useSearchParams();
  const token = search.get('t');
  const [file, setFile] = useState<any>(null);
  const [loading, setLoading] = useState(false);
  const [events, setEvents] = useState<any[]>([]);
  const [showUnholdModal, setShowUnholdModal] = useState(false);
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const currentUser = authService.getCurrentUser();

  useEffect(() => {
    async function load() {
      setLoading(true);
      try {
        // Require login before fetching any file data. If not logged in, redirect to login with return url
        if (!authService.isAuthenticated()) {
          // keep token in query string so it can be used after login
          const returnTo = window.location.pathname + window.location.search;
          navigate(`/login?next=${encodeURIComponent(returnTo)}`);
          setLoading(false);
          return;
        }

        if (token) {
          // authenticated fetch using token endpoint (server will also check token)
          const res = await fileService.getFileByToken(token);
          setFile(res);
        } else if (id) {
          const res = await fileService.getFile(Number(id));
          setFile(res);
        }
        if (id) {
          try {
            const ev = await fileService.listEvents(Number(id));
            setEvents(Array.isArray(ev) ? ev : []);
          } catch {}
        }
      } catch (e: any) {
        toast.error(String(e?.message ?? 'Failed to load file'));
      } finally {
        setLoading(false);
      }
    }
    load();
  }, [id, token]);

  if (loading) return <div className="p-6 bg-white border rounded">Loading file...</div>;
  if (!file) return <div className="p-6 bg-white border rounded">File not found or access denied.</div>;
  // Build a synthetic "Created" event to prepend to the movement timeline for clarity
  const createdEvent = file ? {
    id: -1,
    seq_no: 0,
    action_type: 'Created',
    started_at: file.created_at,
    ended_at: file.created_at,
    business_minutes_held: null,
    remarks: null,
    from_user_id: file.created_by_user?.id ?? null,
    to_user_id: null,
    from_user: file.created_by_user ? { id: file.created_by_user.id, username: file.created_by_user.username, name: file.created_by_user.name } : null,
    to_user: null,
  } : null;
  const eventsAugmented = createdEvent ? [createdEvent, ...events] : events;

  return (
    <div className="space-y-6">
      <div className="p-6 bg-white border rounded">
        <h2 className="text-xl font-bold mb-2 flex items-center gap-3">
          <span>{file.file_no}</span>
          {file.priority && (
            <span className="px-2 py-0.5 text-xs rounded bg-indigo-50 text-indigo-700 border border-indigo-200">{file.priority}</span>
          )}
          {file.sla_status && (
            <span className="px-2 py-0.5 text-xs rounded border" data-title={`SLA ${file.sla_percent ?? 0}%`}>
              {file.sla_status}
            </span>
          )}
        </h2>
        <div className="text-sm text-gray-600 mb-4">Subject: {file.subject}</div>
        <dl className="grid grid-cols-2 gap-4">
          <div><dt className="font-semibold">Owning office</dt><dd>{file.owning_office?.name ?? file.owning_office}</dd></div>
          <div><dt className="font-semibold">Category</dt><dd>{file.category?.name ?? file.category}</dd></div>
          <div><dt className="font-semibold">Status</dt><dd>{file.status}</dd></div>
          <div><dt className="font-semibold">Created by</dt><dd>{file.created_by_user?.username ?? file.created_by}</dd></div>
        </dl>
      </div>

      {/* Movement form for Accounts Officer */}
      <div className="p-6 bg-white border rounded">
        <h3 className="text-lg font-semibold mb-4">Movement</h3>
        {String(file.status) === 'OnHold' && (['accounts_officer','cof','admin'].includes(String(currentUser?.role || ''))) && (
          <div className="mb-4">
            <button
              type="button"
              className="inline-flex items-center px-3 py-2 text-sm font-medium rounded-md border border-transparent text-white bg-green-600 hover:bg-green-700"
              onClick={() => setShowUnholdModal(true)}
            >
              Unhold & Move
            </button>
          </div>
        )}
        <UnholdActionModal
          open={showUnholdModal}
          onClose={() => setShowUnholdModal(false)}
          fileId={Number(id)}
          currentUser={currentUser}
          onDone={async () => {
            try {
              await queryClient.invalidateQueries({ queryKey: ['dashboard', 'officer'] });
              const res = await fileService.getFile(Number(id));
              setFile(res);
              const ev = await fileService.listEvents(Number(id));
              setEvents(Array.isArray(ev) ? ev : []);
            } catch {}
          }}
        />
        <MovementForm
          fileId={Number(id)}
          currentUser={authService.getCurrentUser()}
          onMoved={async () => {
            try {
              const res = await fileService.getFile(Number(id));
              setFile(res);
              const ev = await fileService.listEvents(Number(id));
              setEvents(Array.isArray(ev) ? ev : []);
            } catch {}
          }}
        />
      </div>

      {/* Timeline */}
      <div className="p-6 bg-white border rounded">
        <h3 className="text-lg font-semibold mb-4">Timeline</h3>
        <Timeline events={eventsAugmented as any} />
      </div>
    </div>
  );
}
