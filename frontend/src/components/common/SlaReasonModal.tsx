import React from 'react';
import toast from 'react-hot-toast';
import { fileService } from '../../services/fileService';

type Props = {
  open: boolean;
  onClose: () => void;
  fileId: number;
  onDone?: () => Promise<void> | void;
};

export default function SlaReasonModal({ open, onClose, fileId, onDone }: Props) {
  const [reason, setReason] = React.useState('');
  const [loading, setLoading] = React.useState(false);

  React.useEffect(() => {
    if (open) setReason('');
  }, [open]);

  if (!open) return null;

  const submit = async () => {
    if (!reason.trim()) { toast.error('Please provide a reason'); return; }
    try {
      setLoading(true);
      await fileService.submitSlaReason(fileId, reason.trim());
      toast.success('Reason recorded');
      if (onDone) await onDone();
      onClose();
    } catch (e: any) {
      toast.error(e?.response?.data?.error || 'Failed to submit reason');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50">
      <div className="bg-white w-full max-w-md rounded shadow-lg">
        <div className="p-4 border-b">
          <h3 className="text-lg font-semibold">SLA Breach Reason</h3>
        </div>
        <div className="p-4 space-y-3">
          <p className="text-sm text-gray-600">This file has breached SLA. Please provide the reason.</p>
          <textarea
            className="w-full min-h-[120px] p-2 border rounded focus:outline-none focus:ring"
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            placeholder="Enter reason..."
          />
        </div>
        <div className="p-4 border-t flex items-center justify-end gap-2">
          <button className="btn" onClick={onClose} disabled={loading}>Cancel</button>
          <button className="btn btn-primary" onClick={submit} disabled={loading}>{loading ? 'Saving...' : 'Submit'}</button>
        </div>
      </div>
    </div>
  );
}
