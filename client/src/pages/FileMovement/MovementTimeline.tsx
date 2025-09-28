interface Event {
  seq: number;
  from: string;
  to: string;
  action: string;
  remarks: string;
  date: string;
}

const events: Event[] = [
  { seq: 1, from: "Clerk", to: "Officer 1", action: "Forward", remarks: "Initial", date: "2025-09-28" },
  { seq: 2, from: "Officer 1", to: "Officer 2", action: "Forward", remarks: "Checked", date: "2025-09-28" },
];

function MovementTimeline() {
  return (
    <div className="bg-gray-50 p-6 rounded-lg shadow w-80 md:w-96">
      <h3 className="text-lg font-semibold mb-4">Movement Timeline</h3>
      <ul className="space-y-3">
        {events.map(evt => (
          <li key={evt.seq} className="p-3 bg-white rounded shadow">
            <p><strong>From:</strong> {evt.from} → <strong>To:</strong> {evt.to}</p>
            <p><strong>Action:</strong> {evt.action}</p>
            <p><strong>Remarks:</strong> {evt.remarks}</p>
            <p className="text-sm text-gray-500">{evt.date}</p>
          </li>
        ))}
      </ul>
    </div>
  );
}

export default MovementTimeline;
