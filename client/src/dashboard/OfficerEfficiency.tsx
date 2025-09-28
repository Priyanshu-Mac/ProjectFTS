import React from "react";

interface FileData {
  id: string;
  currentHolder: string;
  ageDays: number;
}

interface OfficerEfficiencyProps {
  files: FileData[];
}

const OfficerEfficiency: React.FC<OfficerEfficiencyProps> = ({ files }) => {
  const officerMap: Record<string, { total: number; overdue: number }> = {};

  files.forEach(f => {
    if (!officerMap[f.currentHolder]) officerMap[f.currentHolder] = { total: 0, overdue: 0 };
    officerMap[f.currentHolder].total += 1;
    if (f.ageDays > 5) officerMap[f.currentHolder].overdue += 1;
  });

  return (
    <div className="mb-6">
      <h2 className="text-xl font-semibold mb-2">Officer Efficiency</h2>
      <div className="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-4 gap-4">
        {Object.entries(officerMap).map(([officer, stats], i) => (
          <div key={i} className="bg-white p-4 rounded shadow text-center">
            <p className="font-semibold">{officer}</p>
            <p>Total Files: {stats.total}</p>
            <p className="text-red-600">Overdue: {stats.overdue}</p>
          </div>
        ))}
      </div>
    </div>
  );
};

export default OfficerEfficiency;
