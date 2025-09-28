interface Kpi {
  label: string;
  value: string | number;
}

const kpis: Kpi[] = [
  { label: "Files in Accounts Today", value: 25 },
  { label: "Total Open Files", value: 112 },
  { label: "% On-time This Week", value: "92%" },
  { label: "Avg TAT (Business Days)", value: 3.4 },
];

function KpiStrip() {
  return (
    <div className="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-4 gap-4 mb-6">
      {kpis.map((kpi, i) => (
        <div key={i} className="bg-white p-4 rounded-lg shadow text-center">
          <p className="text-gray-500">{kpi.label}</p>
          <p className="text-2xl font-semibold">{kpi.value}</p>
        </div>
      ))}
    </div>
  );
}

export default KpiStrip;
