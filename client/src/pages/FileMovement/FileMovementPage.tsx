import FileMovementForm from "./FileMovementForm";
import MovementTimeline from "./MovementTimeline";

function FileMovementPage() {
  return (
    <div className="max-w-7xl mx-auto px-4 py-10 flex flex-col md:flex-row gap-6">
      <FileMovementForm />
      <MovementTimeline />
    </div>
  );
}

export default FileMovementPage;
