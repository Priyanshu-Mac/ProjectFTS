import { ChangeEvent, FormEvent, useState } from "react";

interface MovementData {
  forwardTo: string;
  actionType: string;
  remarks: string;
  attachments: File[];
}

function FileMovementForm() {
  const [data, setData] = useState<MovementData>({
    forwardTo: "Officer 2",
    actionType: "Forward",
    remarks: "",
    attachments: [],
  });

  const handleChange = (e: ChangeEvent<HTMLSelectElement | HTMLTextAreaElement>) => {
    const { name, value } = e.target;
    setData(prev => ({ ...prev, [name]: value }));
  };

  const handleFileChange = (e: ChangeEvent<HTMLInputElement>) => {
    if (e.target.files) {
      setData(prev => ({ ...prev, attachments: Array.from(e.target.files) }));
    }
  };

  const handleSubmit = (e: FormEvent) => {
    e.preventDefault();
    console.log(data);
  };

  return (
    <form onSubmit={handleSubmit} className="bg-white p-6 rounded-lg shadow space-y-6 flex-1">
      <div>
        <label className="block mb-1 font-semibold">Forward To</label>
        <select name="forwardTo" value={data.forwardTo} onChange={handleChange} className="w-full border rounded px-3 py-2">
          <option>Officer 1</option>
          <option>Officer 2</option>
          <option>Officer 3</option>
        </select>
      </div>

      <div>
        <label className="block mb-1 font-semibold">Action Type</label>
        <select name="actionType" value={data.actionType} onChange={handleChange} className="w-full border rounded px-3 py-2">
          <option>Forward</option>
          <option>Return for Rework</option>
          <option>Seek Clarification</option>
          <option>Put On Hold</option>
          <option>Escalate to COF</option>
        </select>
      </div>

      <div>
        <label className="block mb-1 font-semibold">Remarks</label>
        <textarea name="remarks" value={data.remarks} onChange={handleChange} className="w-full border rounded px-3 py-2" rows={3}/>
      </div>

      <div>
        <label className="block mb-1 font-semibold">Attachments</label>
        <input type="file" multiple onChange={handleFileChange} className="w-full border rounded px-3 py-2"/>
      </div>

      <button type="submit" className="bg-accent hover:bg-accent-dark text-gray-900 font-semibold px-6 py-2 rounded">Submit Movement</button>
    </form>
  );
}

export default FileMovementForm;
