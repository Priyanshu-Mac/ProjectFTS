import FileIntakeForm from "./FileIntakeForm";
import FileChecklist from "./FileChecklist";

function FileIntakePage() {
  return (
    <div className="max-w-7xl mx-auto px-4 py-10 flex flex-col md:flex-row gap-6">
      <FileIntakeForm />
      <FileChecklist />
    </div>
  );
}

export default FileIntakePage;
