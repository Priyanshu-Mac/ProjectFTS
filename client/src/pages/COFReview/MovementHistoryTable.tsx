interface Movement {
  officer: string;
  received: string;
  forwarded: string;
  timeHeld: string;
  action: string;
  remarks: string;
}

const movements: Movement[] = [
  { officer: "Clerk", received: "2025-09-28 09:00", forwarded: "2025-09-28 09:30", timeHeld: "30 mins", action: "Forward", remarks: "Initial Intake" },
  { officer: "Officer 1", received: "2025-09-28 09:30", forwarded: "2025-09-28 10:15", timeHeld: "45 mins", action: "Forward", remarks: "Checked details" },
];

function MovementHistoryTable() {
  return (
    <div className="bg-gray-50 p-6 rounded-lg shadow w-full overflow-x-auto">
      <h3 className="text-lg font-semibold mb-4">Movement History</h3>
      <table className="min-w-full border-collapse border border-gray-300">
        <thead className="bg-gray-100">
          <tr>
            <th className="border px-3 py-2">Officer</th>
            <th className="border px-3 py-2">Received</th>
            <th className="border px-3 py-2">Forwarded</th>
            <th className="border px-3 py-2">Business Time Held</th>
            <th className="border px-3 py-2">Action</th>
            <th className="border px-3 py-2">Remarks</th>
          </tr>
        </thead>
        <tbody>
          {movements.map((m, i) => (
            <tr key={i} className="text-center">
              <td className="border px-3 py-2">{m.officer}</td>
              <td className="border px-3 py-2">{m.received}</td>
              <td className="border px-3 py-2">{m.forwarded}</td>
              <td className="border px-3 py-2">{m.timeHeld}</td>
              <td className="border px-3 py-2">{m.action}</td>
              <td className="border px-3 py-2">{m.remarks}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export default MovementHistoryTable;
