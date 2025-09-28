import React, { useState, useEffect } from "react";
import KpiStrip from "./KpiStrip";
import DelayBar from "./DelayBar";
import OfficerEfficiency from "./OfficerEfficiency";

interface FileData {
  id: string;
  fileNo: string;
  subject: string;
  owningOffice: string;
  priority: "Routine" | "Urgent" | "Critical";
  currentHolder: string;
  ageDays: number;
  slaStatus: "On-track" | "Warning" | "Breach";
}

interface DashboardProps {
  role?: "Executive" | "Officer";
}

const mockFiles: FileData[] = [
  {
    id: "1",
    fileNo: "ACC-20250928-01",
    subject: "Budget Proposal",
    owningOffice: "Finance",
    priority: "Critical",
    currentHolder: "John Doe",
    ageDays: 2,
    slaStatus: "On-track",
  },
  {
    id: "2",
    fileNo: "ACC-20250928-02",
    subject: "Salary Audit",
    owningOffice: "HR",
    priority: "Urgent",
    currentHolder: "Jane Smith",
    ageDays: 5,
    slaStatus: "Warning",
  },
];

const DashboardPage: React.FC<DashboardProps> = ({ role = "Executive" }) => {
  const [files, setFiles] = useState<FileData[]>([]);

  useEffect(() => {
    setFiles(mockFiles);
  }, []);

  return (
    <div className="p-6 bg-gray-50 min-h-screen">
      <KpiStrip />
      {role === "Executive" && <DelayBar files={files} />}
      <OfficerEfficiency files={files} />
      <div className="mt-6">
        <h2 className="text-xl font-semibold mb-2">Files in Accounts</h2>
        <div className="overflow-x-auto bg-white rounded shadow">
          <table className="min-w-full table-auto">
            <thead className="bg-gray-100">
              <tr>
                <th className="px-4 py-2 text-left">File No.</th>
                <th className="px-4 py-2 text-left">Subject</th>
                <th className="px-4 py-2 text-left">Owning Office</th>
                <th className="px-4 py-2 text-left">Priority</th>
                <th className="px-4 py-2 text-left">Current Holder</th>
                <th className="px-4 py-2 text-left">Age (days)</th>
                <th className="px-4 py-2 text-left">SLA Status</th>
              </tr>
            </thead>
            <tbody>
              {files.map((file) => (
                <tr key={file.id} className="border-b hover:bg-gray-50">
                  <td className="px-4 py-2">{file.fileNo}</td>
                  <td className="px-4 py-2">{file.subject}</td>
                  <td className="px-4 py-2">{file.owningOffice}</td>
                  <td className="px-4 py-2">{file.priority}</td>
                  <td className="px-4 py-2">{file.currentHolder}</td>
                  <td className="px-4 py-2">{file.ageDays}</td>
                  <td className="px-4 py-2">{file.slaStatus}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      <div className="mt-6">
        <h2 className="text-xl font-semibold mb-2">Aging Buckets</h2>
        <div className="grid grid-cols-1 sm:grid-cols-4 gap-4">
          <div className="bg-white p-4 rounded shadow text-center">
            <p className="text-gray-500">0-2 days</p>
            <p className="text-2xl font-bold">{files.filter(f => f.ageDays <= 2).length}</p>
          </div>
          <div className="bg-white p-4 rounded shadow text-center">
            <p className="text-gray-500">3-5 days</p>
            <p className="text-2xl font-bold">{files.filter(f => f.ageDays >= 3 && f.ageDays <=5).length}</p>
          </div>
          <div className="bg-white p-4 rounded shadow text-center">
            <p className="text-gray-500">6-10 days</p>
            <p className="text-2xl font-bold">{files.filter(f => f.ageDays >= 6 && f.ageDays <=10).length}</p>
          </div>
          <div className="bg-white p-4 rounded shadow text-center">
            <p className="text-gray-500">&gt;10 days</p>
            <p className="text-2xl font-bold">{files.filter(f => f.ageDays > 10).length}</p>
          </div>
        </div>
      </div>
    </div>
  );
};

export default DashboardPage;
