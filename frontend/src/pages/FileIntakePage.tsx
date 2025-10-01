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
  status?: string | null;
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
          sla_policy_id: s.sla_policy_id ?? (sla?.[0]?.id ?? undefined),
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

  return (
    <div className="max-w-3xl mx-auto py-10">
      <h2 className="text-2xl font-bold mb-4">File Intake</h2>

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
            <label className="block text-sm font-medium text-gray-700">Owning Office</label>
            <select
              value={form.owning_office_id ?? ''}
              onChange={(e) => update('owning_office_id', e.target.value ? Number(e.target.value) : undefined)}
              className="mt-1 block w-full border rounded p-2"
            >
              <option value="">Select office</option>
              {offices.map((o) => (
                <option key={o.id} value={o.id}>{o.name}</option>
              ))}
            </select>
          </div>

          <div>
            <label className="block text-sm font-medium text-gray-700">Category</label>
            <select
              value={form.category_id ?? ''}
              onChange={(e) => update('category_id', e.target.value ? Number(e.target.value) : undefined)}
              className="mt-1 block w-full border rounded p-2"
            >
              <option value="">Select category</option>
              {categories.map((c) => (
                <option key={c.id} value={c.id}>{c.name}</option>
              ))}
            </select>
          </div>
        </div>

        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium text-gray-700">SLA Policy</label>
            <select
              value={form.sla_policy_id ?? ''}
              onChange={(e) => update('sla_policy_id', e.target.value ? Number(e.target.value) : undefined)}
              className="mt-1 block w-full border rounded p-2"
            >
              <option value="">Select SLA policy</option>
              {slaPolicies.map((s) => (
                <option key={s.id} value={s.id}>{s.name ?? `${s.sla_minutes} mins`}</option>
              ))}
            </select>
          </div>

          <div>
            <label className="block text-sm font-medium text-gray-700">Priority</label>
            <select
              value={form.priority ?? ''}
              onChange={(e) => update('priority', e.target.value || undefined)}
              className="mt-1 block w-full border rounded p-2"
            >
              <option value="">Select</option>
              <option value="Routine">Routine</option>
              <option value="Urgent">Urgent</option>
              <option value="Critical">Critical</option>
            </select>
          </div>
        </div>

        <div className="grid grid-cols-2 gap-4">
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

          <div>
            <label className="block text-sm font-medium text-gray-700">Forward to Officer</label>
            <select
              value={form.forward_to_officer_id ?? ''}
              onChange={(e) => update('forward_to_officer_id', e.target.value ? Number(e.target.value) : undefined)}
              className="mt-1 block w-full border rounded p-2"
            >
              <option value="">Select officer</option>
              {officers.map((u) => (
                <option key={u.id} value={u.id}>{u.name ?? u.username}</option>
              ))}
            </select>
          </div>
        </div>

        {/* created_by and current_holder are set automatically by the backend */}

        <div className="grid grid-cols-2 gap-4 items-end">
          <div>
            <label className="block text-sm font-medium text-gray-700">Status</label>
            <select
              value={(form.status as any) ?? ''}
              onChange={(e) => update('status', e.target.value || undefined)}
              className="mt-1 block w-full border rounded p-2"
            >
              <option value="">Select status</option>
              <option value="Open">Open</option>
              <option value="WithOfficer">WithOfficer</option>
              <option value="WithCOF">WithCOF</option>
              <option value="Dispatched">Dispatched</option>
              <option value="OnHold">OnHold</option>
              <option value="WaitingOnOrigin">WaitingOnOrigin</option>
              <option value="Closed">Closed</option>
            </select>
          </div>

          <div>
            <label className="block text-sm font-medium text-gray-700">File No (preview)</label>
            <div className="mt-1 p-2 border rounded bg-gray-50">{nextFileNo ?? '—'}</div>
          </div>
        </div>

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
