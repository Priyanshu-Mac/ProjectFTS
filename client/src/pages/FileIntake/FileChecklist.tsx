function FileChecklist() {
  return (
    <div className="bg-gray-50 p-6 rounded-lg shadow w-80">
      <h3 className="text-lg font-semibold mb-4">Checklist</h3>
      <ul className="space-y-2">
        <li><input type="checkbox" className="mr-2"/>Initiation date present?</li>
        <li><input type="checkbox" className="mr-2"/>Attachments included?</li>
        <li><input type="checkbox" className="mr-2"/>Priority set?</li>
        <li><input type="checkbox" className="mr-2"/>Duplicate check done?</li>
      </ul>
    </div>
  );
}

export default FileChecklist;
