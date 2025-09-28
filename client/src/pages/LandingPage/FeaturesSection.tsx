function FeaturesSection() {
  return (
    <section className="py-20 bg-gray-50">
      <div className="max-w-7xl mx-auto px-4">
        <h2 className="text-3xl font-bold text-center mb-12">Key Features</h2>
        <div className="grid md:grid-cols-3 gap-8">
          <div className="bg-white p-6 rounded-lg shadow hover:shadow-lg transition">
            <h3 className="font-semibold text-xl mb-2">File Intake</h3>
            <p>Create files, assign officers, and start the SLA timer instantly.</p>
          </div>
          <div className="bg-white p-6 rounded-lg shadow hover:shadow-lg transition">
            <h3 className="font-semibold text-xl mb-2">File Movement</h3>
            <p>Track every hand-off with immutable logs and SLA monitoring.</p>
          </div>
          <div className="bg-white p-6 rounded-lg shadow hover:shadow-lg transition">
            <h3 className="font-semibold text-xl mb-2">COF Dashboard</h3>
            <p>Review, forward, and monitor performance with analytics and reports.</p>
          </div>
        </div>
      </div>
    </section>
  );
}

export default FeaturesSection;
