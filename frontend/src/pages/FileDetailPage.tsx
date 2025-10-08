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
import SlaReasonModal from '../components/common/SlaReasonModal';

export default function FileDetailPage() {
  const { id } = useParams();
  const [search] = useSearchParams();
  const token = search.get('t');
  const [file, setFile] = useState<any>(null);
  const [loading, setLoading] = useState(false);
  const [events, setEvents] = useState<any[]>([]);
  const [showUnholdModal, setShowUnholdModal] = useState(false);
  const [showSlaModal, setShowSlaModal] = useState(false);
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const currentUser = authService.getCurrentUser();

  useEffect(() => {
    async function load() {
      setLoading(true);
      try {
        // Token-gated mode: require login; redirect to login if not authenticated
        if (token) {
          if (!authService.isAuthenticated()) {
            const returnTo = window.location.pathname + window.location.search;
            navigate(`/login?next=${encodeURIComponent(returnTo)}`);
            setLoading(false);
            return;
          }
          if (id) {
            const rid = Number(id);
            const res = await fileService.getFileByIdAndToken(rid, token);
            setFile(res);
            try { const ev = await fileService.listEventsByIdAndToken(rid, token); setEvents(Array.isArray(ev) ? ev : []); } catch {}
          } else {
            const res = await fileService.getFileByToken(token);
            setFile(res);
            try { const ev = await fileService.listEventsByToken(token); setEvents(Array.isArray(ev) ? ev : []); } catch {}
          }
        }
      } catch (e: any) {
        toast.error(String(e?.message ?? 'Failed to load file'));
      } finally {
        setLoading(false);
      }
    }
    load();
  }, [id, token]);

  if (!token) return (
    <div className="p-6 bg-white border rounded">
      This page requires a valid QR token. The link is missing or invalid.
    </div>
  );
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
        <div className="flex items-start justify-between gap-4">
          <div>
            <h2 className="text-xl font-bold mb-1 flex items-center gap-3">
              <span>{file.file_no}</span>
              {file.priority && (
                <span className="px-2 py-0.5 text-xs rounded bg-indigo-50 text-indigo-700 border border-indigo-200">{file.priority}</span>
              )}
              {file.sla_status && (
                <span className="px-2 py-0.5 text-xs rounded border" title={`Time limit ${file.sla_percent ?? 0}%`}>
                  {file.sla_status}
                </span>
              )}
            </h2>
            <div className="text-sm text-gray-700 mb-2">{file.subject}</div>
            <dl className="grid grid-cols-2 gap-4 text-sm">
              <div><dt className="font-semibold">Owning office</dt><dd>{file.owning_office?.name ?? file.owning_office}</dd></div>
              <div><dt className="font-semibold">Category</dt><dd>{file.category?.name ?? file.category}</dd></div>
              <div><dt className="font-semibold">Status</dt><dd>{file.status}</dd></div>
              <div><dt className="font-semibold">Created by</dt><dd>{file.created_by_user?.username ?? file.created_by}</dd></div>
            </dl>
          </div>
          <div className="flex flex-col items-end gap-2">
            {file?.sla_status === 'Breach' && !file?.has_sla_reason && Number(file?.current_holder_user_id ?? 0) === Number(currentUser?.id) && (
              <button
                className="inline-flex items-center px-3 py-2 text-sm font-medium rounded-md border border-transparent text-white bg-red-600 hover:bg-red-700"
                onClick={() => setShowSlaModal(true)}
              >
                Add reason for delay
              </button>
            )}
          </div>
        </div>
      </div>

      {/* Movement form: hide by default for QR viewers; allow AO/COF/Admin */}
      {/* Hide movement entirely when viewing via token */}
      {!token && (['accounts_officer','cof','admin'].includes(String(currentUser?.role || ''))) && (
        <div className="p-6 bg-white border rounded">
          <h3 className="text-lg font-semibold mb-4">Movement</h3>
          {String(file.status) === 'OnHold' && (
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
            fileId={Number(file?.id ?? id)}
            currentUser={currentUser}
            onDone={async () => {
              try {
                await queryClient.invalidateQueries({ queryKey: ['dashboard', 'officer'] });
                const rid = Number(file?.id ?? id);
                const fres = await fileService.getFile(rid);
                setFile(fres);
                const ev = await fileService.listEvents(rid);
                setEvents(Array.isArray(ev) ? ev : []);
              } catch {}
            }}
          />
          <MovementForm
            fileId={Number(file?.id ?? id)}
            currentUser={authService.getCurrentUser()}
            onMoved={async () => {
              try {
                const rid = Number(file?.id ?? id);
                const fres = await fileService.getFile(rid);
                setFile(fres);
                const ev = await fileService.listEvents(rid);
                setEvents(Array.isArray(ev) ? ev : []);
              } catch {}
            }}
          />
        </div>
      )}

      {/* Timeline */}
      <div className="p-6 bg-white border rounded">
        <h3 className="text-lg font-semibold mb-4">Timeline</h3>
        <Timeline events={eventsAugmented as any} />
      </div>

      <SlaReasonModal
        open={showSlaModal}
        onClose={() => setShowSlaModal(false)}
        fileId={Number(file?.id ?? id)}
        onDone={async () => {
          try {
            const rid = Number(file?.id ?? id);
            const fres = await fileService.getFile(rid);
            setFile(fres);
            const ev = await fileService.listEvents(rid);
            setEvents(Array.isArray(ev) ? ev : []);
          } catch {}
        }}
      />
    </div>
  );
}
