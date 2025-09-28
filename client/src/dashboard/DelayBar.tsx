interface DelayFile {
  fileNo: string;
  owner: string;
  age: string;
}

const delayedFiles: DelayFile[] = [
  { fileNo: "ACC-20250928-01", owner: "Officer 1", age: "3d 4h" },
  { fileNo: "ACC-20250927-08", owner: "Officer 2", age: "2d 6h" },
];

function DelayBar() {
  return (
    <div className="bg-gray-50 p-6 rounded-lg shadow mb-6">
      <h3 className="text-lg font-semibold mb-4">Longest Delays</h3>
      <ul className="space-y-2">
        {delayedFiles.map((file, i) => (
          <li key={i} className="flex justify-between bg-white p-3 rounded shadow">
            <span>{file.fileNo} ({file.owner})</span>
            <span className="text-red-600 font-semibold">{file.age}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}

export default DelayBar;
