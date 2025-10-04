import React, { useEffect, useMemo, useRef, useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { masterDataService } from '../../services/masterDataService';
import { fileService } from '../../services/fileService';
import toast from 'react-hot-toast';

type MovementFormProps = {
  fileId: number;
  currentUser: any;
  onMoved?: () => void;
};

const ACTIONS = [
  { id: 'Forward', label: 'Forward' },
  { id: 'Return', label: 'Return for Rework' },
  { id: 'SeekInfo', label: 'Seek Clarification' },
  { id: 'Hold', label: 'Put On Hold' },
  { id: 'Escalate', label: 'Escalate to COF' },
  { id: 'Dispatch', label: 'Dispatch / Close Loop' },
  { id: 'Reopen', label: 'Reopen' },
];

type NiceOption = { value: any; label: string; group?: string };
type NiceSelectProps = {
  value: any;
  onChange: (value: any) => void;
  options: NiceOption[];
  placeholder?: string;
  disabled?: boolean;
};

const NiceSelect: React.FC<NiceSelectProps> = ({ value, onChange, options, placeholder = 'Select…', disabled = false }) => {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement | null>(null);

  const current = options.find((o) => String(o.value) === String(value));
  const display = current?.label || placeholder;

  useEffect(() => {
    function onDocClick(e: MouseEvent) {
      if (!ref.current) return;
      if (!ref.current.contains(e.target as Node)) setOpen(false);
    }
    document.addEventListener('mousedown', onDocClick);
    return () => document.removeEventListener('mousedown', onDocClick);
  }, []);

  // group options by group label
  const grouped: Record<string, NiceOption[]> = options.reduce((acc, o) => {
    const g = o.group || 'Options';
    if (!acc[g]) acc[g] = [];
    acc[g].push(o);
    return acc;
  }, {} as Record<string, NiceOption[]>);
  const groupKeys = Object.keys(grouped);

  return (
    <div className={`relative ${disabled ? 'opacity-60' : ''}`} ref={ref}>
      <button
        type="button"
        disabled={disabled}
        onClick={() => !disabled && setOpen((o) => !o)}
        className="w-full flex items-center justify-between border border-gray-300 rounded-lg bg-white px-3 py-2 shadow-sm hover:border-gray-400 focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:border-transparent transition-colors duration-150 ease-in-out"
      >
        <span className={`truncate ${current ? 'text-gray-900' : 'text-gray-500'}`}>{display}</span>
        <svg className="h-4 w-4 text-gray-400 ml-2" viewBox="0 0 20 20" fill="currentColor" aria-hidden="true">
          <path fillRule="evenodd" d="M5.23 7.21a.75.75 0 011.06.02L10 10.94l3.71-3.71a.75.75 0 111.06 1.06l-4.24 4.24a.75.75 0 01-1.06 0L5.21 8.29a.75.75 0 01.02-1.08z" clipRule="evenodd" />
        </svg>
      </button>
      {open && !disabled && (
        <div className="absolute z-20 mt-2 w-full max-h-64 overflow-auto rounded-lg border border-gray-200 bg-white shadow-lg">
          {groupKeys.map((g) => (
            <div key={g} className="py-1">
              {groupKeys.length > 1 && (
                <div className="px-3 py-1 text-xs font-medium text-gray-500 sticky top-0 bg-white">{g}</div>
              )}
              {grouped[g].map((opt) => {
                const active = String(opt.value) === String(value);
                return (
                  <button
                    type="button"
                    key={`${g}-${opt.value}`}
                    className={`w-full text-left px-3 py-2 text-sm hover:bg-gray-50 ${active ? 'bg-indigo-50 text-indigo-700' : 'text-gray-700'}`}
                    onClick={() => {
                      onChange(opt.value);
                      setOpen(false);
                    }}
                  >
                    {opt.label}
                  </button>
                );
              })}
            </div>
          ))}
        </div>
      )}
    </div>
  );
};

export default function MovementForm({ fileId, currentUser, onMoved }: MovementFormProps) {
  const queryClient = useQueryClient();
  const [officers, setOfficers] = useState<any[]>([]);
  const [actionType, setActionType] = useState<string>('Forward');
  const [toUserId, setToUserId] = useState<number | ''>('');
  const [remarks, setRemarks] = useState('');
  const [submitting, setSubmitting] = useState(false);

  const requiresToUser = useMemo(() => {
    return ['Forward', 'Return', 'SeekInfo', 'Escalate', 'Dispatch', 'Reopen'].includes(actionType);
  }, [actionType]);

  const remarksRequired = useMemo(() => {
    return ['Hold', 'Escalate'].includes(actionType);
  }, [actionType]);

  useEffect(() => {
    async function load() {
      try {
        // Fetch all users so officer can forward to anyone
        const res = await masterDataService.getUsers(null);
        setOfficers(Array.isArray(res) ? res : (res?.results ?? []));
      } catch (e: any) {
        // fallback to empty
        setOfficers([]);
      }
    }
    load();
  }, []);

  // Helpers for COF detection
  function findUserById(id: number | '') {
    if (!id || !Array.isArray(officers)) return null;
    return officers.find((u) => Number(u.id) === Number(id)) || null;
  }
  function isCofUser(id: number | '') {
    const u = findUserById(id);
    const role = String(u?.role || '').toUpperCase();
    return role === 'COF';
  }

  // Derived lists for better UX
  const myUserId = Number(currentUser?.id || 0);
  const otherUsers = React.useMemo(() => (officers || []).filter((u) => Number(u?.id) !== myUserId), [officers, myUserId]);
  const cofUsers = React.useMemo(() => otherUsers.filter((u) => String(u?.role || '').toUpperCase() === 'COF'), [otherUsers]);
  const nonCofUsers = React.useMemo(() => otherUsers.filter((u) => String(u?.role || '').toUpperCase() !== 'COF'), [otherUsers]);
  const isEscalate = actionType === 'Escalate';
  const recipientPlaceholder = requiresToUser ? (isEscalate ? 'Select COF' : 'Select user') : 'Not required';
  const remarksPlaceholder = (remarksRequired ? (isEscalate ? 'Reason for escalation (required)' : 'Provide reason/details...') : 'Optional note');
  const userLabel = (u: any) => `${u?.name ?? u?.username ?? `User #${u?.id}`} ${u?.role ? `· ${u.role}` : ''}`;

  function handleActionTypeChange(next: string) {
    // If a COF recipient is selected and user changes action away from Escalate, clear the recipient
    if (next !== 'Escalate' && toUserId && isCofUser(toUserId)) {
      setToUserId('');
      toast((t) => (
        <span>
          Recipient cleared because action changed away from Escalate
          <button onClick={() => toast.dismiss(t.id)} className="ml-2 underline">Dismiss</button>
        </span>
      ));
    }
    setActionType(next);
  }

  function handleToUserChange(val: string) {
    const id = val ? Number(val) : '';
    // Prevent forwarding to self
    if (id && Number(id) === myUserId) {
      setToUserId('');
      toast.error('You cannot forward to yourself');
      return;
    }
    setToUserId(id);
    if (id && isCofUser(id) && actionType !== 'Escalate') {
      setActionType('Escalate');
      toast.success('Action changed to Escalate for COF recipient');
    }
  }

  // If switching into Escalate while a non-COF is currently selected, clear it
  useEffect(() => {
    if (isEscalate && toUserId && !isCofUser(toUserId)) {
      setToUserId('');
    }
  }, [isEscalate]);

  // Clear selection if current value becomes self due to any state changes
  useEffect(() => {
    if (toUserId && Number(toUserId) === myUserId) {
      setToUserId('');
    }
  }, [myUserId, toUserId]);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (requiresToUser && !toUserId) {
      toast.error('Please select who to forward to');
      return;
    }
    if (remarksRequired && !remarks.trim()) {
      toast.error('Remarks are required for this action');
      return;
    }
    setSubmitting(true);
    try {
      await fileService.addEvent(fileId, {
        to_user_id: requiresToUser ? Number(toUserId) : undefined,
        action_type: actionType,
        remarks: remarks.trim() || undefined,
        attachments: [],
      });
      toast.success('Movement recorded');
      // Proactively refresh dashboards and file lists so UI reflects changes immediately
      queryClient.invalidateQueries({ queryKey: ['dashboard', 'officer'] }).catch(() => {});
      queryClient.invalidateQueries({ queryKey: ['dashboard', 'executive'] }).catch(() => {});
      queryClient.invalidateQueries({ queryKey: ['files'] }).catch(() => {});
      setRemarks('');
      setToUserId('');
      setActionType('Forward');
      onMoved && onMoved();
    } catch (e: any) {
      toast.error(String(e?.message ?? 'Failed to move file'));
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-4">
      <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
        <div>
          <label className="block text-sm font-medium text-gray-700">Action Type</label>
          <div className="mt-1">
            <NiceSelect
              value={actionType}
              onChange={(v: any) => handleActionTypeChange(v)}
              options={ACTIONS.map((a) => ({ value: a.id, label: a.label }))}
            />
          </div>
        </div>
        <div>
          <label className="block text-sm font-medium text-gray-700">Recipient</label>
          <div className="mt-1">
            <NiceSelect
              value={toUserId}
              onChange={(v: any) => handleToUserChange(String(v))}
              disabled={!requiresToUser}
              placeholder={recipientPlaceholder}
              options={
                isEscalate
                  ? cofUsers.map((u) => ({ value: u.id, label: userLabel(u), group: 'COF' }))
                  : [
                      ...cofUsers.map((u) => ({ value: u.id, label: userLabel(u), group: 'COF' })),
                      ...nonCofUsers.map((u) => ({ value: u.id, label: userLabel(u), group: 'Users' })),
                    ]
              }
            />
          </div>
        </div>
        <div className="md:col-span-1">
          <label className="block text-sm font-medium text-gray-700">Current User</label>
          <div className="mt-2 text-gray-800">{currentUser?.name ?? currentUser?.username ?? 'You'}</div>
        </div>
      </div>

      <div>
        <label className="block text-sm font-medium text-gray-700">Remarks {remarksRequired ? <span className="text-red-600">(required)</span> : ''}</label>
        <textarea
          className="mt-1 block w-full border-gray-300 rounded-md shadow-sm focus:ring-indigo-500 focus:border-indigo-500"
          rows={3}
          placeholder={remarksPlaceholder}
          value={remarks}
          onChange={(e) => setRemarks(e.target.value)}
        />
      </div>

      <div className="flex items-center gap-3">
        <button
          type="submit"
          disabled={submitting}
          className="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md shadow-sm text-white bg-indigo-600 hover:bg-indigo-700 disabled:opacity-60"
        >
          {submitting ? 'Saving…' : 'Save Movement'}
        </button>
        <div className="text-sm text-gray-500">Every movement becomes an immutable event.</div>
      </div>
    </form>
  );
}
