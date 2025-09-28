import React from "react";

interface Attachment {
  id: string;
  name: string;
  url: string;
}

interface AttachmentsTabProps {
  attachments: Attachment[];
}

const AttachmentsTab: React.FC<AttachmentsTabProps> = ({ attachments }) => {
  return (
    <div className="bg-white p-6 rounded shadow space-y-3">
      <h2 className="text-xl font-semibold mb-4">Attachments</h2>
      {attachments.length === 0 ? (
        <p>No attachments uploaded.</p>
      ) : (
        <ul className="space-y-2">
          {attachments.map(att => (
            <li key={att.id}>
              <a
                href={att.url}
                target="_blank"
                rel="noopener noreferrer"
                className="text-blue-600 hover:underline"
              >
                {att.name}
              </a>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
};

export default AttachmentsTab;
