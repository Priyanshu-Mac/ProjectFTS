import React, { useEffect, useMemo, useState } from 'react';
import { masterDataService } from '../../services/masterDataService';
import { fileService } from '../../services/fileService';
import toast from 'react-hot-toast';

export type UnholdAction = 'Forward'|'Return'|'SeekInfo'|'Escalate'|'Dispatch'|'Reopen';

export default function UnholdActionModal({
  open,
  onClose,
  fileId,
  currentUser,
  onDone,
}: {
  open: boolean;
  onClose: () => void;
  fileId: number;
  currentUser: any;
  onDone?: () => void;
}) {
  const [officers, setOfficers] = useState<any[]>([]);
  const [actionType, setActionType] = useState<UnholdAction>('Forward');
  const [toUserId, setToUserId] = useState<number | ''>('');
  const [remarks, setRemarks] = useState('');
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    if (!open) return;
    (async () => {
      try {
        const res = await masterDataService.getUsers(null);
        setOfficers(Array.isArray(res) ? res : (res?.results ?? []));
      } catch {
        setOfficers([]);
      }
    })();
  }, [open]);

  const myUserId = Number(currentUser?.id || 0);
  const otherUsers = useMemo(() => (officers || []).filter((u) => Number(u?.id) !== myUserId), [officers, myUserId]);
  const cofUsers = useMemo(() => otherUsers.filter((u) => String(u?.role || '').toUpperCase() === 'COF'), [otherUsers]);
  const nonCofUsers = useMemo(() => otherUsers.filter((u) => String(u?.role || '').toUpperCase() !== 'COF'), [otherUsers]);
  const isEscalate = actionType === 'Escalate';

  const requiresToUser = ['Forward','Return','SeekInfo','Escalate','Dispatch','Reopen'].includes(actionType);

  const userLabel = (u: any) => `${u?.name ?? u?.username ?? `User #${u?.id}`} ${u?.role ? `· ${u.role}` : ''}`;

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (requiresToUser && !toUserId) {
      toast.error('Please select recipient');
      return;
    }
    if ((actionType === 'Escalate') && !remarks.trim()) {
      toast.error('Remarks are required for escalation');
      return;
    }
    setSubmitting(true);
    try {
      await fileService.addEvent(fileId, {
        to_user_id: requiresToUser ? Number(toUserId) : undefined,
        action_type: actionType,
        remarks: remarks.trim() || undefined,
      });
      toast.success('File unheld and moved');
      onDone && onDone();
      onClose();
      setActionType('Forward');
      setToUserId('');
      setRemarks('');
    } catch (e: any) {
      toast.error(String(e?.message ?? 'Failed to unhold'));
    } finally {
      setSubmitting(false);
    }
  }

  if (!open) return null;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/30 p-4">
      <div className="w-full max-w-lg rounded-lg bg-white shadow-lg">
        <div className="px-4 py-3 border-b">
          <h3 className="text-lg font-semibold">Unhold and Move</h3>
          <p className="text-xs text-gray-500">Choose the next action and recipient. This will remove hold implicitly.</p>
        </div>
        <form onSubmit={handleSubmit} className="px-4 py-3 space-y-4">
          <div>
            <label className="block text-sm font-medium text-gray-700">Action</label>
            <select
              value={actionType}
              onChange={(e) => setActionType(e.target.value as UnholdAction)}
              className="mt-1 block w-full border-gray-300 rounded-md shadow-sm focus:ring-indigo-500 focus:border-indigo-500"
            >
              <option value="Forward">Forward</option>
              <option value="Return">Return for Rework</option>
              <option value="SeekInfo">Seek Clarification</option>
              <option value="Escalate">Escalate to COF</option>
              <option value="Dispatch">Dispatch / Close Loop</option>
              <option value="Reopen">Reopen</option>
            </select>
          </div>
          <div>
            <label className="block text-sm font-medium text-gray-700">Recipient</label>
            <select
              value={toUserId}
              onChange={(e) => {
                const val = e.target.value ? Number(e.target.value) : '';
                if (val && Number(val) === myUserId) {
                  toast.error('You cannot forward to yourself');
                  setToUserId('');
                  return;
                }
                setToUserId(val);
                if (val) {
                  const chosen = otherUsers.find(u => Number(u.id) === Number(val));
                  const role = String(chosen?.role || '').toUpperCase();
                  if (role === 'COF' && actionType !== 'Escalate') {
                    setActionType('Escalate');
                    toast.success('Action changed to Escalate for COF recipient');
                  }
                }
              }}
              className="mt-1 block w-full border-gray-300 rounded-md shadow-sm focus:ring-indigo-500 focus:border-indigo-500"
            >
              <option value="">Select recipient</option>
              {cofUsers.length > 0 && (
                <optgroup label="COF">
                  {cofUsers.map((u) => (
                    <option key={u.id} value={u.id}>{userLabel(u)}</option>
                  ))}
                </optgroup>
              )}
              {!isEscalate && nonCofUsers.length > 0 && (
                <optgroup label="Users">
                  {nonCofUsers.map((u) => (
                    <option key={u.id} value={u.id}>{userLabel(u)}</option>
                  ))}
                </optgroup>
              )}
            </select>
          </div>
          <div>
            <label className="block text-sm font-medium text-gray-700">Remarks {actionType === 'Escalate' ? <span className="text-red-600">(required)</span> : null}</label>
            <textarea
              value={remarks}
              onChange={(e) => setRemarks(e.target.value)}
              rows={3}
              placeholder={actionType === 'Escalate' ? 'Reason for escalation (required)' : 'Optional note'}
              className="mt-1 block w-full border-gray-300 rounded-md shadow-sm focus:ring-indigo-500 focus:border-indigo-500"
            />
          </div>
          <div className="flex items-center justify-end gap-2 border-t pt-3">
            <button type="button" onClick={onClose} className="px-4 py-2 text-sm rounded-md border bg-white hover:bg-gray-50">Cancel</button>
            <button type="submit" disabled={submitting} className="px-4 py-2 text-sm rounded-md text-white bg-indigo-600 hover:bg-indigo-700 disabled:opacity-60">
              {submitting ? 'Moving…' : 'Unhold & Move'}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
