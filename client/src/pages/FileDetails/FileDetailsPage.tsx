import React, { useState } from "react";
import OverviewTab from "./OverviewTab";
import TimelineTab from "./TimelineTab";
import AttachmentsTab from "./AttachmentsTab";

const FileDetailsPage: React.FC = () => {
  const [activeTab, setActiveTab] = useState("overview");

  const fileData = {
    fileNo: "ACC-20250928-01",
    subject: "Salary Review",
    notesheetTitle: "Notesheet 1",
    owningOffice: "Finance",
    category: "Salary",
    priority: "Critical",
    currentHolder: "John Doe",
    status: "With Officer",
    dateInitiated: "2025-09-28",
    dateReceived: "2025-09-28",
    confidential: true,
  };

  const timelineEvents = [
    {
      id: "1",
      from: "Intake Clerk",
      to: "Officer John",
      action: "Forward",
      remarks: "Initial processing",
      startedAt: "2025-09-28 09:00",
      endedAt: "2025-09-28 12:00",
      businessTime: "3h",
    },
  ];

  const attachments = [
    { id: "1", name: "SalarySheet.pdf", url: "#" },
    { id: "2", name: "AuditReport.docx", url: "#" },
  ];

  return (
    <div className="p-6 space-y-6">
      <h1 className="text-2xl font-bold mb-4">File Details</h1>
      <div className="flex space-x-4 border-b mb-4">
        <button
          onClick={() => setActiveTab("overview")}
          className={`px-4 py-2 ${activeTab === "overview" ? "border-b-2 border-blue-600 font-semibold" : ""}`}
        >
          Overview
        </button>
        <button
          onClick={() => setActiveTab("timeline")}
          className={`px-4 py-2 ${activeTab === "timeline" ? "border-b-2 border-blue-600 font-semibold" : ""}`}
        >
          Timeline
        </button>
        <button
          onClick={() => setActiveTab("attachments")}
          className={`px-4 py-2 ${activeTab === "attachments" ? "border-b-2 border-blue-600 font-semibold" : ""}`}
        >
          Attachments
        </button>
      </div>

      {activeTab === "overview" && <OverviewTab file={fileData} />}
      {activeTab === "timeline" && <TimelineTab events={timelineEvents} />}
      {activeTab === "attachments" && <AttachmentsTab attachments={attachments} />}
    </div>
  );
};

export default FileDetailsPage;
