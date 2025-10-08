import { useEffect, useRef, useState } from 'react';
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
  remarks?: string | null;
};

export default function FileIntakePage() {
  const navigate = useNavigate();
  const currentUser = authService.getCurrentUser();
  const [submitting, setSubmitting] = useState(false);
  type FormErrors = Partial<Record<'subject' | 'notesheet_title' | 'date_initiated' | 'remarks', string>>;
  const [formErrors, setFormErrors] = useState<FormErrors>({});

  // Refs to programmatically open native date pickers
  const dateInitiatedRef = useRef<HTMLInputElement | null>(null);
  const dateReceivedRef = useRef<HTMLInputElement | null>(null);

  const openDatePicker = (ref: React.RefObject<HTMLInputElement>) => {
    const el = ref.current as any;
    if (!el) return;
    if (typeof el.showPicker === 'function') {
      try { el.showPicker(); return; } catch {}
    }
    // Fallback: focus (won't open picker everywhere, but harmless)
    el.focus();
  };

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
    date_received_accounts: new Date().toISOString().slice(0, 10),
    forward_to_officer_id: undefined,
    save_as_draft: false,
    remarks: undefined,
  });

  const [offices, setOffices] = useState<Array<any>>([]);
  const [categories, setCategories] = useState<Array<any>>([]);
  const [slaPolicies, setSlaPolicies] = useState<Array<any>>([]);
  const [officers, setOfficers] = useState<Array<any>>([]);
  const [nextFileNo, setNextFileNo] = useState<string | null>(null);
  const [slaPreview, setSlaPreview] = useState<{ id?: number; name?: string; sla_minutes?: number } | null>(null);
  // Similar files state (right panel)
  const [similarLoading, setSimilarLoading] = useState(false);
  const [similar, setSimilar] = useState<any[]>([]);

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
    // Validate required fields first and show inline errors
    const errs: FormErrors = {};
    if (!form.subject?.trim()) errs.subject = 'Subject is required';
    if (!form.notesheet_title?.trim()) errs.notesheet_title = 'Notesheet title is required';
    if (!form.date_initiated) errs.date_initiated = 'Date initiated is required';
    if (!form.remarks) errs.remarks = 'Remarks are required';

    if (Object.keys(errs).length > 0) {
      setFormErrors(errs);
      toast.error('Please fill the required fields.');
      return;
    } else {
      setFormErrors({});
    }

    setSubmitting(true);
    try {
      // ensure user is logged in (frontend) — backend will also enforce auth
      if (!authService.isAuthenticated()) {
        toast.error('You must be logged in to create a file');
        navigate('/login');
        return;
      }
      // Basic client-side validation per DB constraints handled above
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
        remarks: form.remarks,
      };
      const data = await fileService.createFile(payload);
      toast.success('File created — ' + (data?.file?.file_no ?? ''));
      // Redirect to File Search and auto-open the newly created file
      if (data?.file?.id) {
        navigate('/file-search', { state: { openId: data.file.id } });
      } else {
        navigate('/file-search');
      }
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

  // Debounced fetch for similar-subject files
  useEffect(() => {
    const subject = (form.subject || '').trim();
    // Only search when at least 3 characters
    if (subject.length < 3) { setSimilar([]); return; }
    const handle = setTimeout(async () => {
      setSimilarLoading(true);
      try {
        const dateFrom = new Date(Date.now() - 60 * 24 * 60 * 60 * 1000).toISOString();
        const res = await fileService.listFiles({ q: subject, date_from: dateFrom, limit: 8, includeSla: false });
        const results = (res as any)?.results ?? (res as any)?.data ?? [];
        setSimilar(results);
      } catch {
        setSimilar([]);
      } finally {
        setSimilarLoading(false);
      }
    }, 350); // debounce ~350ms
    return () => clearTimeout(handle);
  }, [form.subject]);

  return (
    <div className="max-w-6xl mx-auto py-10">
      <h2 className="text-2xl font-bold mb-2">File Intake</h2>
  {/* Top strip: File No preview and time limit preview */}
      <div className="mb-4 grid grid-cols-1 md:grid-cols-2 gap-3">
        <div className="p-3 border rounded bg-gray-50">
          <div className="text-xs text-gray-500">File No (preview)</div>
          <div className="font-mono text-lg">{nextFileNo ?? '—'}</div>
        </div>
        <div className="p-3 border rounded bg-gray-50">
          <div className="text-xs text-gray-500">Time limit (auto from Category + Priority)</div>
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

      <div className="grid grid-cols-1 lg:grid-cols-4 gap-6">
        {/* Main form */}
        <form onSubmit={handleSubmit} className="space-y-4 lg:col-span-3">
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
            onChange={(e) => { update('subject', e.target.value); if (formErrors.subject) setFormErrors((s) => ({ ...s, subject: e.target.value.trim() ? undefined : 'Subject is required' })); }}
            className={`mt-1 block w-full border rounded p-2 ${formErrors.subject ? 'border-red-500' : ''}`}
            placeholder="Enter file subject"
          />
            {formErrors.subject && (
              <p className="mt-1 text-sm text-red-600">{formErrors.subject}</p>
            )}
        </div>

        <div>
          <label className="block text-sm font-medium text-gray-700">Notesheet Title *</label>
          <input
            required
            value={form.notesheet_title ?? ''}
            onChange={(e) => { update('notesheet_title', e.target.value); if (formErrors.notesheet_title) setFormErrors((s) => ({ ...s, notesheet_title: e.target.value.trim() ? undefined : 'Notesheet title is required' })); }}
            className={`mt-1 block w-full border rounded p-2 ${formErrors.notesheet_title ? 'border-red-500' : ''}`}
            placeholder="Notesheet title (required by DB)"
          />
            {formErrors.notesheet_title && (
              <p className="mt-1 text-sm text-red-600">{formErrors.notesheet_title}</p>
            )}
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
            <p className="mt-1 text-xs text-gray-600">Time limit is auto-selected based on Category + Priority.</p>
          </div>
        </div>

        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium text-gray-700">Office</label>
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
            <label className="block text-sm font-medium text-gray-700">Forward to</label>
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
              ref={dateInitiatedRef}
              value={form.date_initiated ?? ''}
              onChange={(e) => update('date_initiated', e.target.value || undefined)}
              onClick={() => openDatePicker(dateInitiatedRef)}
              className={`mt-1 block w-full border rounded p-2 ${formErrors.date_initiated ? 'border-red-500' : ''}`}
            />
            {formErrors.date_initiated && (
              <p className="mt-1 text-sm text-red-600">{formErrors.date_initiated}</p>
            )}
          </div>

          <div>
            <label className="block text-sm font-medium text-gray-700">Date Received (Accounts)</label>
            <input
              type="date"
              ref={dateReceivedRef}
              value={form.date_received_accounts ?? ''}
              onChange={(e) => update('date_received_accounts', e.target.value || undefined)}
              onClick={() => openDatePicker(dateReceivedRef)}
              className="mt-1 block w-full border rounded p-2"
            />
          </div>
        </div>

        {/* Attachments removed entirely */}

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

        {/* Right panel: similar files */}
        <aside className="lg:col-span-1">
          <div className="sticky top-20">
            <div className="p-4 bg-white border rounded">
              <div className="flex items-center justify-between mb-2">
                <h3 className="text-sm font-semibold text-gray-800">Similar files</h3>
                {similarLoading && <span className="text-xs text-gray-500">Loading…</span>}
              </div>
              <p className="text-xs text-gray-500 mb-3">Shows recent files matching the subject.</p>
              {(!similar || similar.length === 0) && !similarLoading && (
                <div className="text-xs text-gray-400">No similar files yet.</div>
              )}
              <ul className="space-y-2 max-h-[420px] overflow-auto pr-1">
                {similar.map((r: any) => (
                  <li key={r.id} className="group">
                    <div className="p-2 rounded border hover:bg-slate-50">
                      <div className="flex items-center justify-between">
                        <span className="text-[11px] font-mono text-gray-600">{r.file_no || `#${r.id}`}</span>
                        <span className={"text-[10px] px-1.5 py-0.5 rounded " + (String(r.status||'').toLowerCase().includes('cof') ? 'bg-indigo-50 text-indigo-700' : 'bg-slate-100 text-slate-700')}>{r.status || 'Open'}</span>
                      </div>
                      <div className="mt-1 text-sm text-gray-800 line-clamp-2" title={r.subject}>{r.subject}</div>
                      <div className="mt-1 text-[11px] text-gray-500 flex items-center justify-between">
                        <span>{r.category?.name || r.category_name || r.category || '—'}</span>
                        <span>{new Date(r.created_at || r.date_initiated || Date.now()).toLocaleDateString()}</span>
                      </div>
                    </div>
                  </li>
                ))}
              </ul>
              <div className="mt-3 text-right">
                <a
                  href={`/file-search?q=${encodeURIComponent(form.subject || '')}`}
                  className="text-xs text-indigo-600 hover:text-indigo-700"
                >
                  Open in Search
                </a>
              </div>
            </div>
          </div>
        </aside>
      </div>
    </div>
  );
}
