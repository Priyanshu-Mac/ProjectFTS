import React from "react";

interface Event {
  id: string;
  from: string;
  to: string;
  action: string;
  remarks: string;
  startedAt: string;
  endedAt: string;
  businessTime: string;
}

interface TimelineTabProps {
  events: Event[];
}

const TimelineTab: React.FC<TimelineTabProps> = ({ events }) => {
  return (
    <div className="bg-white p-6 rounded shadow space-y-4">
      <h2 className="text-xl font-semibold mb-4">Timeline</h2>
      {events.length === 0 ? (
        <p>No events recorded.</p>
      ) : (
        <ul className="space-y-3">
          {events.map(e => (
            <li key={e.id} className="border-l-4 border-blue-500 pl-4">
              <p><strong>From:</strong> {e.from} <strong>→ To:</strong> {e.to}</p>
              <p><strong>Action:</strong> {e.action}</p>
              <p><strong>Remarks:</strong> {e.remarks}</p>
              <p><strong>Time:</strong> {e.startedAt} - {e.endedAt} ({e.businessTime})</p>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
};

export default TimelineTab;
