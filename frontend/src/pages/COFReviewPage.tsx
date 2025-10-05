import React, { useEffect, useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import toast from 'react-hot-toast';
import { authService } from '../services/authService';
import api from '../services/api';

function SignaturePad({ onChange }: { onChange: (dataUrl: string | null) => void }) {
  const canvasRef = React.useRef<HTMLCanvasElement | null>(null);
  const containerRef = React.useRef<HTMLDivElement | null>(null);
  const drawingRef = React.useRef(false);
  const hasDrawnRef = React.useRef(false);

  // Resize canvas to match container and device pixel ratio for crisp lines
  useEffect(() => {
    function resize() {
      const canvas = canvasRef.current; const container = containerRef.current; if (!canvas || !container) return;
      const dpr = Math.max(1, Math.floor(window.devicePixelRatio || 1));
      const cssWidth = Math.min(600, Math.max(300, container.clientWidth));
      const cssHeight = 160;
      canvas.style.width = cssWidth + 'px';
      canvas.style.height = cssHeight + 'px';
      canvas.width = Math.floor(cssWidth * dpr);
      canvas.height = Math.floor(cssHeight * dpr);
      const ctx = canvas.getContext('2d'); if (!ctx) return;
      ctx.scale(dpr, dpr);
      ctx.lineWidth = 2; ctx.lineCap = 'round'; ctx.strokeStyle = '#111827';
      // Clear on resize
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      hasDrawnRef.current = false;
      onChange(null);
    }
    resize();
    const ro = new ResizeObserver(resize);
    if (containerRef.current) ro.observe(containerRef.current);
    window.addEventListener('resize', resize);
    return () => { window.removeEventListener('resize', resize); ro.disconnect(); };
  }, [onChange]);

  useEffect(() => {
    const canvas = canvasRef.current; if (!canvas) return;
    const ctx = canvas.getContext('2d'); if (!ctx) return;

    function getPos(e: PointerEvent) {
      const rect = canvas.getBoundingClientRect();
      const x = e.clientX - rect.left;
      const y = e.clientY - rect.top;
      return { x, y };
    }
    function onDown(e: PointerEvent) {
      e.preventDefault();
      canvas.setPointerCapture(e.pointerId);
      drawingRef.current = true;
      const p = getPos(e);
      ctx.beginPath();
      ctx.moveTo(p.x, p.y);
    }
    function onMove(e: PointerEvent) {
      if (!drawingRef.current) return;
      e.preventDefault();
      const p = getPos(e);
      ctx.lineTo(p.x, p.y);
      ctx.stroke();
      hasDrawnRef.current = true;
    }
    function onUp(e: PointerEvent) {
      if (!drawingRef.current) return;
      e.preventDefault();
      drawingRef.current = false;
      if (hasDrawnRef.current) {
        onChange(canvas.toDataURL('image/png'));
      }
    }

    canvas.addEventListener('pointerdown', onDown);
    canvas.addEventListener('pointermove', onMove);
    canvas.addEventListener('pointerup', onUp);
    canvas.addEventListener('pointerleave', onUp);
    return () => {
      canvas.removeEventListener('pointerdown', onDown);
      canvas.removeEventListener('pointermove', onMove);
      canvas.removeEventListener('pointerup', onUp);
      canvas.removeEventListener('pointerleave', onUp);
    };
  }, [onChange]);

  function clearCanvas() {
    const canvas = canvasRef.current; if (!canvas) return;
    const ctx = canvas.getContext('2d'); if (!ctx) return;
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    hasDrawnRef.current = false;
    onChange(null);
  }

  return (
    <div ref={containerRef} className="w-full max-w-md">
      <canvas ref={canvasRef} className="border rounded bg-white w-full max-w-full touch-none" />
      <div className="mt-2 flex items-center justify-between">
        <div className="text-xs text-gray-500">Sign above</div>
        <button type="button" className="text-xs px-2 py-1 border rounded" onClick={clearCanvas}>Clear</button>
      </div>
    </div>
  );
}

function SignatureModal({ open, onClose, onConfirm }: { open: boolean; onClose: () => void; onConfirm: (signature: string, remarks: string) => void }) {
  const [sig, setSig] = useState<string | null>(null);
  const [remarks, setRemarks] = useState<string>('Approved & Dispatched');
  if (!open) return null;
  return (
    <div className="fixed inset-0 bg-black/40 flex items-center justify-center z-50">
      <div className="bg-white w-full max-w-lg rounded shadow-lg p-4">
        <div className="text-lg font-semibold">Sign Dispatch</div>
        <div className="text-sm text-gray-600 mb-3">Signature is required to dispatch this file.</div>
        <div className="space-y-3">
          <div>
            <div className="text-sm font-medium mb-1">Signature</div>
            <SignaturePad onChange={setSig} />
            {!sig && <div className="text-xs text-red-600 mt-1">Signature is required</div>}
          </div>
          <div>
            <div className="text-sm font-medium mb-1">Remarks</div>
            <textarea className="w-full border rounded p-2 text-sm" value={remarks} onChange={(e)=>setRemarks(e.target.value)} rows={3} />
          </div>
        </div>
        <div className="mt-4 flex items-center justify-end gap-2">
          <button className="btn" onClick={onClose}>Cancel</button>
          <button className="btn btn-primary" onClick={() => { if (!sig) return; onConfirm(sig, remarks); }}>Dispatch</button>
        </div>
      </div>
    </div>
  );
}

export default function COFReviewPage() {
  const currentUser = authService.getCurrentUser();
  const queryClient = useQueryClient();
  const navigate = useNavigate();
  const [modalOpen, setModalOpen] = useState(false);
  const [pendingDispatchId, setPendingDispatchId] = useState<number | null>(null);
  const [onlyMine, setOnlyMine] = useState<boolean>(false);
  const { data, isLoading, isError } = useQuery({
    queryKey: ['cof-review-queue', { onlyMine }],
    queryFn: async () => {
      const res = await api.get('/cof/review-queue', { params: onlyMine ? { assigned: 1 } : {} });
      return res.data;
    },
    enabled: !!currentUser?.id,
  });

  const dispatchMutation = useMutation({
    mutationFn: async ({ id, remarks, signature }:{id:number;remarks:string; signature: string}) => {
      const res = await api.post(`/cof/dispatch/${id}`,{ remarks, signature });
      return res.data;
    },
    onSuccess: (_data, vars) => {
      toast.success('Dispatched');
      // Refresh queue and take the user to search focused on the dispatched file
      queryClient.invalidateQueries({ queryKey: ['cof-review-queue'] });
      navigate('/file-search', { state: { openId: vars.id } });
    },
    onError: (e: any) => toast.error(e?.response?.data?.error || 'Failed to dispatch'),
  });

  const rows = useMemo(() => Array.isArray(data) ? data : [], [data]);

  if (isLoading) return <div className="p-6">Loading...</div>;
  if (isError) return <div className="p-6 text-red-600">Failed to load</div>;

  return (
    <div className="space-y-6 overflow-x-hidden">
      <div>
        <h1 className="text-2xl font-bold">COF Final Review</h1>
  <p className="text-sm text-gray-600">Review files With COF, add remarks, and dispatch with a required signature.</p>
        <label className="inline-flex items-center gap-2 mt-3 text-sm text-gray-700">
          <input type="checkbox" className="rounded" checked={onlyMine} onChange={(e)=>setOnlyMine(e.target.checked)} />
          <span>Show only files assigned to me</span>
        </label>
      </div>

      <div className="grid grid-cols-1 gap-6">
        <div>
          <div className="card">
            <div className="card-header"><h3 className="text-lg font-semibold">Queue</h3></div>
            <div className="card-body divide-y">
              {rows.map((r:any)=> (
                <div key={r.id} className="py-3 flex items-center justify-between">
                  <div className="min-w-0">
                    <div className="font-medium text-gray-900 truncate">{r.file_no} · {r.subject}</div>
                    <div className="text-xs text-gray-500">Holder: {r.current_holder_user_id}</div>
                  </div>
                  <div className="flex items-center gap-2">
                    <button className="btn btn-sm" onClick={() => navigate('/file-search', { state: { openId: r.id } })}>Open</button>
                    <button className="btn btn-primary btn-sm" onClick={()=> { setPendingDispatchId(r.id); setModalOpen(true); }}>Dispatch</button>
                  </div>
                </div>
              ))}
              {rows.length === 0 && (<div className="text-sm text-gray-500">No files in review.</div>)}
            </div>
          </div>
        </div>
      </div>

      {/* Signature modal */}
      <SignatureModal
        open={modalOpen}
        onClose={() => { setModalOpen(false); setPendingDispatchId(null); }}
        onConfirm={(signature, remarks) => {
          if (pendingDispatchId != null) {
            dispatchMutation.mutate({ id: pendingDispatchId, remarks, signature });
          }
          setModalOpen(false);
          setPendingDispatchId(null);
        }}
      />
    </div>
  );
}
