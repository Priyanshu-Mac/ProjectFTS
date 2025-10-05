// no imports needed

export default function ConfirmModal({
  open,
  title = 'Are you sure?',
  message,
  confirmText = 'Confirm',
  cancelText = 'Cancel',
  onConfirm,
  onCancel,
}: {
  open: boolean;
  title?: string;
  message?: string;
  confirmText?: string;
  cancelText?: string;
  onConfirm: () => void;
  onCancel: () => void;
}) {
  if (!open) return null;
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/30 p-4">
      <div className="w-full max-w-md rounded-lg bg-white shadow-lg">
        <div className="px-4 py-3 border-b">
          <h3 className="text-lg font-semibold">{title}</h3>
        </div>
        <div className="px-4 py-4 text-sm text-gray-700">
          {message}
        </div>
        <div className="px-4 py-3 border-t flex items-center justify-end gap-2">
          <button onClick={onCancel} className="px-3 py-1.5 text-sm rounded-md border bg-white hover:bg-gray-50">{cancelText}</button>
          <button onClick={onConfirm} className="px-3 py-1.5 text-sm rounded-md text-white bg-red-600 hover:bg-red-700">{confirmText}</button>
        </div>
      </div>
    </div>
  );
}
