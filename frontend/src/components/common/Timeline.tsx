// Timeline component to display movement history

type TimelineEvent = {
  id: number;
  seq_no: number;
  action_type: string;
  started_at?: string | null;
  ended_at?: string | null;
  business_minutes_held?: number | null;
  remarks?: string | null;
  from_user_id?: number | null;
  to_user_id?: number | null;
  from_user?: { id: number; username?: string; name?: string; role?: string } | null;
  to_user?: { id: number; username?: string; name?: string; role?: string } | null;
};

export default function Timeline({ events }: { events: TimelineEvent[] }) {
  if (!events || events.length === 0) {
    return <div className="text-sm text-gray-500">No movements yet.</div>;
  }
  const renderRemarks = (remarks?: string | null) => {
    if (!remarks) return null;
    // Try to parse remarks if it contains JSON payload (e.g., { remarks, signature })
    try {
      const obj = JSON.parse(remarks);
      const text = obj?.remarks || '';
      const sig = obj?.signature || '';
      return (
        <div className="mt-1 text-sm break-words overflow-hidden">
          {text && <div className="mb-1 whitespace-pre-wrap break-words max-w-full">{text}</div>}
          {typeof sig === 'string' && sig.startsWith('data:image') && (
            <div className="mt-1">
              <img src={sig} alt="Signature" className="max-w-[240px] max-h-[120px] border rounded shadow-sm" />
            </div>
          )}
        </div>
      );
    } catch {
      // If it's a long base64 or long text, clamp layout impact
      const isDataUrl = typeof remarks === 'string' && remarks.startsWith('data:image');
      if (isDataUrl) {
        return (
          <div className="mt-1">
            <img src={remarks} alt="Attachment" className="max-w-[240px] max-h-[120px] border rounded shadow-sm" />
          </div>
        );
      }
      return <div className="mt-1 text-sm whitespace-pre-wrap break-words max-w-full overflow-hidden">{remarks}</div>;
    }
  };
  return (
    <div className="space-y-3">
      {events.map((ev) => (
        <div key={ev.id} className="p-3 border rounded bg-white overflow-hidden">
          <div className="flex items-center justify-between">
            <div className="font-medium">{ev.action_type}</div>
            <div className="text-xs text-gray-500">Seq #{ev.seq_no}</div>
          </div>
          <div className="text-sm text-gray-700 mt-0.5">
            {ev.action_type === 'Created' ? (
              <>Created by: {ev.from_user?.name || ev.from_user?.username || ev.from_user_id || '—'}</>
            ) : (
              <>From: {ev.from_user?.name || ev.from_user?.username || ev.from_user_id || '—'} → To: {ev.to_user?.name || ev.to_user?.username || ev.to_user_id || '—'}</>
            )}
          </div>
          <div className="text-xs text-gray-500 mt-0.5">Started: {ev.started_at ?? '—'} {ev.ended_at ? `· Ended: ${ev.ended_at}` : ''}</div>
          {typeof ev.business_minutes_held === 'number' && (
            <div className="text-xs text-gray-500">Business minutes: {ev.business_minutes_held}</div>
          )}
          {ev.remarks && (
            <div className="mt-1 text-sm">
              <div className="text-gray-600">Remarks:</div>
              {renderRemarks(ev.remarks)}
            </div>
          )}
        </div>
      ))}
    </div>
  );
}
