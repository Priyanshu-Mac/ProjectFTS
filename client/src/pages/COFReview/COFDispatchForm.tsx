import { ChangeEvent, FormEvent, useState } from "react";

interface DispatchData {
  dispatchTo: string;
  authorityName: string;
  coveringNote: string;
  digitalSignature: boolean;
}

function COFDispatchForm() {
  const [data, setData] = useState<DispatchData>({
    dispatchTo: "Authority 1",
    authorityName: "",
    coveringNote: "",
    digitalSignature: false,
  });

  const handleChange = (e: ChangeEvent<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>) => {
    const { name, value, type, checked } = e.target;
    setData(prev => ({
      ...prev,
      [name]: type === "checkbox" ? checked : value
    }));
  };

  const handleSubmit = (e: FormEvent) => {
    e.preventDefault();
    console.log(data);
  };

  return (
    <form onSubmit={handleSubmit} className="bg-white p-6 rounded-lg shadow space-y-6 flex-1">
      <div>
        <label className="block mb-1 font-semibold">Dispatch To Authority</label>
        <select name="dispatchTo" value={data.dispatchTo} onChange={handleChange} className="w-full border rounded px-3 py-2">
          <option>Authority 1</option>
          <option>Authority 2</option>
          <option>Authority 3</option>
        </select>
      </div>

      <div>
        <label className="block mb-1 font-semibold">Authority Name (if not listed)</label>
        <input type="text" name="authorityName" value={data.authorityName} onChange={handleChange} className="w-full border rounded px-3 py-2"/>
      </div>

      <div>
        <label className="block mb-1 font-semibold">Covering Note / Letter</label>
        <textarea name="coveringNote" value={data.coveringNote} onChange={handleChange} className="w-full border rounded px-3 py-2" rows={4}/>
      </div>

      <div className="flex items-center space-x-2">
        <input type="checkbox" name="digitalSignature" checked={data.digitalSignature} onChange={handleChange} />
        <label>Use Digital Signature</label>
      </div>

      <button type="submit" className="bg-accent hover:bg-accent-dark text-gray-900 font-semibold px-6 py-2 rounded">Dispatch File</button>
    </form>
  );
}

export default COFDispatchForm;
