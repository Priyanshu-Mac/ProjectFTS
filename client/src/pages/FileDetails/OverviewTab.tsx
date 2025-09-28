import React from "react";

interface OverviewTabProps {
  file: {
    fileNo: string;
    subject: string;
    notesheetTitle: string;
    owningOffice: string;
    category: string;
    priority: string;
    currentHolder: string;
    status: string;
    dateInitiated: string;
    dateReceived: string;
    confidential: boolean;
  };
}

const OverviewTab: React.FC<OverviewTabProps> = ({ file }) => {
  return (
    <div className="bg-white p-6 rounded shadow space-y-3">
      <h2 className="text-xl font-semibold mb-4">Overview</h2>
      <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
        <div><strong>File No:</strong> {file.fileNo}</div>
        <div><strong>Subject:</strong> {file.subject}</div>
        <div><strong>Notesheet Title:</strong> {file.notesheetTitle}</div>
        <div><strong>Owning Office:</strong> {file.owningOffice}</div>
        <div><strong>Category:</strong> {file.category}</div>
        <div><strong>Priority:</strong> {file.priority}</div>
        <div><strong>Current Holder:</strong> {file.currentHolder}</div>
        <div><strong>Status:</strong> {file.status}</div>
        <div><strong>Date Initiated:</strong> {file.dateInitiated}</div>
        <div><strong>Date Received:</strong> {file.dateReceived}</div>
        <div><strong>Confidential:</strong> {file.confidential ? "Yes" : "No"}</div>
      </div>
    </div>
  );
};

export default OverviewTab;
