import React from "react";

interface FileData {
  id: string;
  fileNo: string;
  currentHolder: string;
  ageDays: number;
  slaStatus: string;
}

interface DelayBarProps {
  files: FileData[];
}

const DelayBar: React.FC<DelayBarProps> = ({ files }) => {
  const delayedFiles = files.filter(f => f.slaStatus === "Warning" || f.slaStatus === "Breach");

  return (
    <div className="mb-6">
      <h2 className="text-xl font-semibold mb-2">Longest Delays</h2>
      <div className="bg-white rounded shadow p-4">
        {delayedFiles.length === 0 ? (
          <p>No delayed files</p>
        ) : (
          <ul className="space-y-2">
            {delayedFiles.map(f => (
              <li key={f.id} className="flex justify-between border-b py-1">
                <span>{f.fileNo} - {f.currentHolder}</span>
                <span className={`font-semibold ${f.slaStatus === "Breach" ? "text-red-600" : "text-yellow-600"}`}>
                  {f.slaStatus}
                </span>
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
};

export default DelayBar;
