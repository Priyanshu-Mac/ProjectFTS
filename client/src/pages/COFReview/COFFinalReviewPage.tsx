import COFDispatchForm from "./COFDispatchForm";
import MovementHistoryTable from "./MovementHistoryTable";

function COFFinalReviewPage() {
  return (
    <div className="max-w-7xl mx-auto px-4 py-10 flex flex-col gap-6">
      <div className="flex flex-col md:flex-row gap-6">
        <COFDispatchForm />
        <MovementHistoryTable />
      </div>
    </div>
  );
}

export default COFFinalReviewPage;
