import { useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import toast from 'react-hot-toast';
import { masterDataService } from '../services/masterDataService';
import { fileService } from '../services/fileService';
import { authService } from '../services/authService';

type Payload = {
  subject: string;
  notesheet_title?: string | null;
  owning_office_id?: number | null;
  category_id?: number | null;
  sla_policy_id?: number | null;
  priority?: string | null;
  confidentiality?: boolean | null;
  date_initiated?: string | null;
  date_received_accounts?: string | null;
  forward_to_officer_id?: number | null;
  save_as_draft?: boolean;
  attachments?: Array<{ name?: string; url?: string }> | null;
  remarks?: string | null;
};

export default function FileIntakePage() {
  const navigate = useNavigate();
  const currentUser = authService.getCurrentUser();
  const [submitting, setSubmitting] = useState(false);

  const [form, setForm] = useState<Payload>({
    subject: '',
    notesheet_title: '',
    owning_office_id: undefined,
    category_id: undefined,
    sla_policy_id: undefined,
    priority: undefined,
    confidentiality: undefined,
    // date_initiated is required by the DB; default to today
    date_initiated: new Date().toISOString().slice(0, 10),
    date_received_accounts: undefined,
    forward_to_officer_id: undefined,
    save_as_draft: false,
    attachments: undefined,
    remarks: undefined,
  });

  const [offices, setOffices] = useState<Array<any>>([]);
  const [categories, setCategories] = useState<Array<any>>([]);
  const [slaPolicies, setSlaPolicies] = useState<Array<any>>([]);
  const [officers, setOfficers] = useState<Array<any>>([]);
  const [nextFileNo, setNextFileNo] = useState<string | null>(null);
  const [slaPreview, setSlaPreview] = useState<{ id?: number; name?: string; sla_minutes?: number } | null>(null);

  function truncateLabel(s: any, max = 30) {
    const str = String(s ?? '');
    if (str.length <= max) return str;
    return str.slice(0, max - 1) + '…';
  }

  function formatBusinessDuration(mins?: number | null) {
    if (mins == null || mins <= 0) return '';
    const hours = Math.round(mins / 60);
    return `${hours} business hour${hours === 1 ? '' : 's'}`;
  }

  function update<K extends keyof Payload>(key: K, value: Payload[K]) {
    setForm((s) => ({ ...s, [key]: value }));
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setSubmitting(true);
    try {
      // ensure user is logged in (frontend) — backend will also enforce auth
      if (!authService.isAuthenticated()) {
        toast.error('You must be logged in to create a file');
        navigate('/login');
        return;
      }
      // Basic client-side validation per DB constraints
      if (!form.subject?.trim()) throw new Error('Subject is required');
      if (!form.notesheet_title?.trim()) throw new Error('Notesheet title is required');
      if (!form.date_initiated) throw new Error('Date initiated is required');
      // Build payload following backend expectations
      const payload: any = {
        subject: form.subject,
        notesheet_title: form.notesheet_title,
        owning_office_id: form.owning_office_id ?? null,
        category_id: form.category_id ?? null,
        sla_policy_id: form.sla_policy_id ?? null,
        priority: form.priority ?? null,
        // backend expects confidentiality boolean
        confidentiality: !!form.confidentiality,
        date_initiated: form.date_initiated ?? null,
        date_received_accounts: form.date_received_accounts ?? null,
        forward_to_officer_id: form.forward_to_officer_id ?? null,
        save_as_draft: !!form.save_as_draft,
        attachments: form.attachments ?? null,
        remarks: form.remarks ?? null,
      };
      const data = await fileService.createFile(payload);
      toast.success('File created — ' + (data?.file?.file_no ?? ''));
      // navigate to the created file view if the backend returned an id
      if (data?.file?.id) navigate(`/files/${data.file.id}`);
      else navigate('/');
    } catch (err: any) {
      toast.error(String(err?.message ?? err));
    } finally {
      setSubmitting(false);
    }
  }

  useEffect(() => {
    let mounted = true;
    async function load() {
      try {
        const [off, cat, sla, officersResp] = await Promise.all([
          masterDataService.getOffices().catch(() => []),
          masterDataService.getCategories().catch(() => []),
          masterDataService.getSLAPolicies().catch(() => []),
          // fetch accounts officers only (backend uses role names like 'AccountsOfficer')
          masterDataService.getUsers('AccountsOfficer').catch(() => []),
        ]);
        if (!mounted) return;
        setOffices(off || []);
        setCategories(cat || []);
        setSlaPolicies(sla || []);
  setOfficers(officersResp || []);

        // set sensible defaults if not already set
        setForm((s) => ({
          ...s,
          owning_office_id: s.owning_office_id ?? (off?.[0]?.id ?? undefined),
          category_id: s.category_id ?? (cat?.[0]?.id ?? undefined),
          // sla_policy_id is now auto-derived from Category + Priority; no default from list
          forward_to_officer_id: s.forward_to_officer_id ?? (officersResp?.[0]?.id ?? undefined),
        }));

        // fetch next file no
        const nf = await fileService.getNextFileNumber().catch(() => null);
        if (mounted) setNextFileNo(nf?.file_no ?? null);
      } catch (e) {
        // ignore — master data is optional
      }
    }
    load();
    return () => {
      mounted = false;
    };
  }, []);

  // Recompute SLA preview and auto-derive sla_policy_id when category or priority changes
  useEffect(() => {
    if (!form.category_id || !form.priority) {
      setSlaPreview(null);
      // clear auto-derived selection
      setForm((s) => (s.sla_policy_id ? { ...s, sla_policy_id: undefined } : s));
      return;
    }
    // Try to find a matching policy by category and priority label
    const match = slaPolicies.find((p) => p.category_id === form.category_id && (
      (p.priority && p.priority === form.priority) ||
      // fallback: infer from name if priority field missing
      (typeof p.name === 'string' && p.name.toLowerCase().includes(String(form.priority).toLowerCase()))
    ));
    if (match) {
      setSlaPreview({ id: match.id, name: match.name, sla_minutes: match.sla_minutes });
      // set auto-derived sla_policy_id if changed
      setForm((s) => (s.sla_policy_id === match.id ? s : { ...s, sla_policy_id: match.id }));
    } else {
      setSlaPreview(null);
      setForm((s) => (s.sla_policy_id ? { ...s, sla_policy_id: undefined } : s));
    }
  }, [form.category_id, form.priority, slaPolicies]);

  return (
    <div className="max-w-3xl mx-auto py-10">
      <h2 className="text-2xl font-bold mb-2">File Intake</h2>
      {/* Top strip: File No preview and SLA preview */}
      <div className="mb-4 grid grid-cols-1 md:grid-cols-2 gap-3">
        <div className="p-3 border rounded bg-gray-50">
          <div className="text-xs text-gray-500">File No (preview)</div>
          <div className="font-mono text-lg">{nextFileNo ?? '—'}</div>
        </div>
        <div className="p-3 border rounded bg-gray-50">
          <div className="text-xs text-gray-500">SLA (auto from Category + Priority)</div>
          {slaPreview ? (
            <div>
              <div className="font-medium">{slaPreview.name ?? `Policy #${slaPreview.id}`}</div>
              {typeof slaPreview.sla_minutes === 'number' && (
                <div className="text-sm text-gray-600">{formatBusinessDuration(slaPreview.sla_minutes)}</div>
              )}
            </div>
          ) : (
            <div className="text-sm text-gray-500">Select category and priority to preview</div>
          )}
        </div>
      </div>

      <form onSubmit={handleSubmit} className="space-y-4">
        {currentUser ? (
          <div className="text-sm text-gray-600">Creating as: <strong>{currentUser.name ?? currentUser.username}</strong></div>
        ) : (
          <div className="text-sm text-red-600">You are not logged in. You will be redirected to login on submit.</div>
        )}
        <div>
          <label className="block text-sm font-medium text-gray-700">Subject *</label>
          <input
            required
            value={form.subject}
            onChange={(e) => update('subject', e.target.value)}
            className="mt-1 block w-full border rounded p-2"
            placeholder="Enter file subject"
          />
        </div>

        <div>
          <label className="block text-sm font-medium text-gray-700">Notesheet Title *</label>
          <input
            required
            value={form.notesheet_title ?? ''}
            onChange={(e) => update('notesheet_title', e.target.value)}
            className="mt-1 block w-full border rounded p-2"
            placeholder="Notesheet title (required by DB)"
          />
        </div>

        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium text-gray-700">Category</label>
            <select
              value={form.category_id ?? ''}
              onChange={(e) => update('category_id', e.target.value ? Number(e.target.value) : undefined)}
              className="mt-1 block w-full border rounded p-2 truncate"
            >
              <option value="">Select category</option>
              {categories.map((c) => (
                <option key={c.id} value={c.id} title={c.name}>{truncateLabel(c.name)}</option>
              ))}
            </select>
          </div>
          <div>
            <label className="block text-sm font-medium text-gray-700">Priority</label>
            <select
              value={form.priority ?? ''}
              onChange={(e) => update('priority', e.target.value || undefined)}
              className="mt-1 block w-full border rounded p-2 truncate"
            >
              <option value="">Select</option>
              <option value="Routine">Routine</option>
              <option value="Urgent">Urgent</option>
              <option value="Critical">Critical</option>
            </select>
            <p className="mt-1 text-xs text-gray-600">SLA is auto-selected based on Category + Priority.</p>
          </div>
        </div>

        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium text-gray-700">Owning Office</label>
            <select
              value={form.owning_office_id ?? ''}
              onChange={(e) => update('owning_office_id', e.target.value ? Number(e.target.value) : undefined)}
              className="mt-1 block w-full border rounded p-2 truncate"
            >
              <option value="">Select office</option>
              {offices.map((o) => (
                <option key={o.id} value={o.id} title={o.name}>{truncateLabel(o.name)}</option>
              ))}
            </select>
          </div>
          <div>
            <label className="block text-sm font-medium text-gray-700">Forward to Officer</label>
            <select
              value={form.forward_to_officer_id ?? ''}
              onChange={(e) => update('forward_to_officer_id', e.target.value ? Number(e.target.value) : undefined)}
              className="mt-1 block w-full border rounded p-2 truncate"
            >
              <option value="">Select officer</option>
              {officers.map((u) => (
                <option key={u.id} value={u.id} title={u.name ?? u.username}>{truncateLabel(u.name ?? u.username)}</option>
              ))}
            </select>
          </div>
        </div>

        <div className="grid grid-cols-1 gap-4">
          <div>
            <label className="block text-sm font-medium text-gray-700">Confidential</label>
            <div className="mt-1">
              <label className="inline-flex items-center">
                <input
                  type="checkbox"
                  checked={!!form.confidentiality}
                  onChange={(e) => update('confidentiality', e.target.checked)}
                  className="mr-2"
                />
                Mark as confidential
              </label>
            </div>
          </div>
        </div>

        {/* created_by and current_holder are set automatically by the backend */}

        {/* Status is auto-managed by the system and set on backend based on actions; no manual selection here */}

        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium text-gray-700">Date Initiated</label>
            <input
              type="date"
              value={form.date_initiated ?? ''}
              onChange={(e) => update('date_initiated', e.target.value || undefined)}
              className="mt-1 block w-full border rounded p-2"
            />
          </div>

          <div>
            <label className="block text-sm font-medium text-gray-700">Date Received (Accounts)</label>
            <input
              type="date"
              value={form.date_received_accounts ?? ''}
              onChange={(e) => update('date_received_accounts', e.target.value || undefined)}
              className="mt-1 block w-full border rounded p-2"
            />
          </div>
        </div>

        <div>
          <label className="block text-sm font-medium text-gray-700">Attachments (comma separated file paths)</label>
          <input
            value={form.attachments ? form.attachments.map((a) => a.url).join(',') : ''}
            onChange={(e) =>
              update(
                'attachments',
                e.target.value
                  ? e.target.value.split(',').map((u) => ({ url: u.trim(), name: undefined }))
                  : undefined,
              )
            }
            className="mt-1 block w-full border rounded p-2"
            placeholder="/uploads/file1.pdf, /uploads/file2.jpg"
          />
        </div>

        <div>
          <label className="block text-sm font-medium text-gray-700">Remarks</label>
          <textarea
            value={form.remarks ?? ''}
            onChange={(e) => update('remarks', e.target.value || undefined)}
            className="mt-1 block w-full border rounded p-2"
            rows={4}
          />
        </div>

        <div className="flex items-center gap-4">
          <label className="inline-flex items-center">
            <input
              type="checkbox"
              checked={!!form.save_as_draft}
              onChange={(e) => update('save_as_draft', e.target.checked)}
              className="mr-2"
            />
            Save as draft
          </label>

          <button
            type="submit"
            disabled={submitting}
            className="ml-auto bg-blue-600 text-white px-4 py-2 rounded disabled:opacity-50"
          >
            {submitting ? 'Submitting...' : 'Create File'}
          </button>
        </div>
      </form>
    </div>
  );
}
