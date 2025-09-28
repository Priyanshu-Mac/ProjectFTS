interface Officer {
  name: string;
  onTime: string;
  avgHold: string;
}

const officers: Officer[] = [
  { name: "Officer 1", onTime: "95%", avgHold: "1.2h" },
  { name: "Officer 2", onTime: "88%", avgHold: "2.1h" },
];

function OfficerEfficiency() {
  return (
    <div className="bg-gray-50 p-6 rounded-lg shadow mb-6">
      <h3 className="text-lg font-semibold mb-4">Officer Efficiency</h3>
      <table className="min-w-full border-collapse border border-gray-300">
        <thead className="bg-gray-100">
          <tr>
            <th className="border px-3 py-2">Officer</th>
            <th className="border px-3 py-2">On-time %</th>
            <th className="border px-3 py-2">Avg Hold Time</th>
          </tr>
        </thead>
        <tbody>
          {officers.map((o, i) => (
            <tr key={i} className="text-center">
              <td className="border px-3 py-2">{o.name}</td>
              <td className="border px-3 py-2">{o.onTime}</td>
              <td className="border px-3 py-2">{o.avgHold}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export default OfficerEfficiency;
