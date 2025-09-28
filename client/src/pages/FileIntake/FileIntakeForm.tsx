import { ChangeEvent, FormEvent, useState } from "react";

interface FileIntakeData {
  subject: string;
  notesheetTitle: string;
  owningOffice: string;
  category: string;
  priority: string;
  forwardTo: string;
  remarks: string;
  dateInitiated: string;
  attachments: File[];
}

function FileIntakeForm() {
  const [formData, setFormData] = useState<FileIntakeData>({
    subject: "",
    notesheetTitle: "",
    owningOffice: "Finance",
    category: "Budget",
    priority: "Routine",
    forwardTo: "Officer 1",
    remarks: "",
    dateInitiated: "",
    attachments: [],
  });

  const handleChange = (e: ChangeEvent<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>) => {
    const { name, value } = e.target;
    setFormData(prev => ({ ...prev, [name]: value }));
  };

  const handleFileChange = (e: ChangeEvent<HTMLInputElement>) => {
    if (e.target.files) {
      setFormData(prev => ({ ...prev, attachments: Array.from(e.target.files) }));
    }
  };

  const handleSubmit = (e: FormEvent) => {
    e.preventDefault();
    console.log(formData);
  };

  return (
    <form onSubmit={handleSubmit} className="bg-white p-6 rounded-lg shadow space-y-6 flex-1">
      <div className="grid md:grid-cols-2 gap-4">
        <div>
          <label className="block mb-1 font-semibold">Auto File No.</label>
          <input type="text" value="ACC-20250928-01" readOnly className="w-full border rounded px-3 py-2 bg-gray-100"/>
        </div>
        <div>
          <label className="block mb-1 font-semibold">Owning Office</label>
          <select name="owningOffice" value={formData.owningOffice} onChange={handleChange} className="w-full border rounded px-3 py-2">
            <option>Finance</option>
            <option>Procurement</option>
            <option>HR</option>
            <option>Admin</option>
          </select>
        </div>
        <div>
          <label className="block mb-1 font-semibold">File Type / Category</label>
          <select name="category" value={formData.category} onChange={handleChange} className="w-full border rounded px-3 py-2">
            <option>Budget</option>
            <option>Audit</option>
            <option>Salary</option>
            <option>Procurement</option>
            <option>Misc</option>
          </select>
        </div>
        <div>
          <label className="block mb-1 font-semibold">Priority</label>
          <select name="priority" value={formData.priority} onChange={handleChange} className="w-full border rounded px-3 py-2">
            <option>Routine</option>
            <option>Urgent</option>
            <option>Critical</option>
          </select>
        </div>
      </div>

      <div>
        <label className="block mb-1 font-semibold">Subject of File</label>
        <input name="subject" value={formData.subject} onChange={handleChange} type="text" className="w-full border rounded px-3 py-2" required/>
      </div>

      <div>
        <label className="block mb-1 font-semibold">Title of Notesheet</label>
        <input name="notesheetTitle" value={formData.notesheetTitle} onChange={handleChange} type="text" className="w-full border rounded px-3 py-2" required/>
      </div>

      <div className="grid md:grid-cols-2 gap-4">
        <div>
          <label className="block mb-1 font-semibold">Date of Initiation</label>
          <input name="dateInitiated" value={formData.dateInitiated} onChange={handleChange} type="date" className="w-full border rounded px-3 py-2"/>
        </div>
        <div>
          <label className="block mb-1 font-semibold">Date Received in Accounts</label>
          <input type="date" value={new Date().toISOString().slice(0,10)} readOnly className="w-full border rounded px-3 py-2 bg-gray-100"/>
        </div>
      </div>

      <div>
        <label className="block mb-1 font-semibold">Forward to Accounts Officer</label>
        <select name="forwardTo" value={formData.forwardTo} onChange={handleChange} className="w-full border rounded px-3 py-2">
          <option>Officer 1</option>
          <option>Officer 2</option>
          <option>Officer 3</option>
        </select>
      </div>

      <div>
        <label className="block mb-1 font-semibold">Attachments</label>
        <input type="file" multiple onChange={handleFileChange} className="w-full border rounded px-3 py-2"/>
      </div>

      <div>
        <label className="block mb-1 font-semibold">Remarks</label>
        <textarea name="remarks" value={formData.remarks} onChange={handleChange} className="w-full border rounded px-3 py-2" rows={3}/>
      </div>

      <div className="flex space-x-4">
        <button type="submit" className="bg-accent hover:bg-accent-dark text-gray-900 font-semibold px-6 py-2 rounded">Save & Assign</button>
        <button type="button" className="bg-gray-200 hover:bg-gray-300 text-gray-900 px-6 py-2 rounded">Save Draft</button>
      </div>
    </form>
  );
}

export default FileIntakeForm;
