function FeaturesSection() {
  const features = [
    {
      icon: "📁",
      title: "File Intake & Assignment",
      description: "Automated file numbering (ACC-YYYYMMDD-XX), priority setting, and instant assignment to officers with SLA timer activation.",
      benefits: ["Auto file numbering", "Priority management", "SLA tracking", "Officer assignment"]
    },
    {
      icon: "🔄",
      title: "Movement Tracking",
      description: "Real-time file movement with business-time calculation, immutable audit trail, and automated notifications.",
      benefits: ["Business time calculation", "Immutable ledger", "Real-time tracking", "Automated alerts"]
    },
    {
      icon: "📊",
      title: "Executive Dashboard",
      description: "Comprehensive KPI monitoring, officer efficiency tracking, and aging analysis with drill-down capabilities.",
      benefits: ["Live KPI monitoring", "Performance analytics", "Aging reports", "Bottleneck analysis"]
    },
    {
      icon: "✅",
      title: "COF Final Review",
      description: "Complete journey visualization, TAT computation, covering letter templates, and digital dispatch capabilities.",
      benefits: ["Journey visualization", "TAT computation", "Letter templates", "Digital signatures"]
    },
    {
      icon: "🔍",
      title: "Advanced Search",
      description: "Global search across file numbers, subjects, remarks with smart filters and duplicate detection.",
      benefits: ["Full-text search", "Smart filters", "Duplicate detection", "Quick access"]
    },
    {
      icon: "📈",
      title: "Analytics & Reports",
      description: "Detailed reporting on pendency, officer performance, SLA breaches with CSV/PDF export capabilities.",
      benefits: ["Pendency analysis", "Performance metrics", "Breach reports", "Export options"]
    }
  ];

  return (
    <section id="features" className="py-20">
      <div className="container">
        <div className="text-center mb-16">
          <h2 className="text-3xl font-bold mb-4">Comprehensive File Management</h2>
          <p className="text-xl text-gray-600 max-w-3xl mx-auto">
            Every aspect of file handling from intake to dispatch is covered with 
            precision tracking, automated workflows, and intelligent analytics.
          </p>
        </div>

        <div className="grid md:grid-cols-2 lg:grid-cols-3 gap-8 mb-16">
          {features.map((feature, index) => (
            <div key={index} className="card hover:shadow-md transition-all">
              <div className="text-4xl mb-4">{feature.icon}</div>
              <h3 className="text-xl font-bold mb-3 text-gray-900">{feature.title}</h3>
              <p className="text-gray-600 mb-4">{feature.description}</p>
              <div className="space-y-2">
                {feature.benefits.map((benefit, idx) => (
                  <div key={idx} className="flex items-center gap-2 text-sm">
                    <div className="w-2 h-2 bg-brand rounded-full"></div>
                    <span>{benefit}</span>
                  </div>
                ))}
              </div>
            </div>
          ))}
        </div>

        <div className="card">
          <h3 className="text-2xl font-bold mb-6 text-center">Role-Based Access Control</h3>
          <div className="grid md:grid-cols-4 gap-6">
            <div className="text-center">
              <div className="w-16 h-16 bg-blue-100 rounded-full flex items-center justify-center mx-auto mb-3">
                <span className="text-2xl">👥</span>
              </div>
              <h4 className="font-bold mb-2">Clerk (Intake)</h4>
              <ul className="text-sm text-gray-600 space-y-1">
                <li className="text-success">✅ Create files</li>
                <li className="text-success">✅ Initial assignment</li>
                <li className="text-gray-400">❌ File movement</li>
                <li className="text-gray-400">❌ Final dispatch</li>
              </ul>
            </div>
            <div className="text-center">
              <div className="w-16 h-16 bg-green-100 rounded-full flex items-center justify-center mx-auto mb-3">
                <span className="text-2xl">👤</span>
              </div>
              <h4 className="font-bold mb-2">Accounts Officer</h4>
              <ul className="text-sm text-gray-600 space-y-1">
                <li className="text-gray-400">❌ Create files</li>
                <li className="text-success">✅ Move files</li>
                <li className="text-success">✅ Put on hold</li>
                <li className="text-gray-400">❌ Final dispatch</li>
              </ul>
            </div>
            <div className="text-center">
              <div className="w-16 h-16 bg-orange-100 rounded-full flex items-center justify-center mx-auto mb-3">
                <span className="text-2xl">👨‍💼</span>
              </div>
              <h4 className="font-bold mb-2">COF</h4>
              <ul className="text-sm text-gray-600 space-y-1">
                <li className="text-success">✅ Create files</li>
                <li className="text-success">✅ Move any file</li>
                <li className="text-success">✅ Put on hold</li>
                <li className="text-success">✅ Final dispatch</li>
              </ul>
            </div>
            <div className="text-center">
              <div className="w-16 h-16 bg-purple-100 rounded-full flex items-center justify-center mx-auto mb-3">
                <span className="text-2xl">⚙️</span>
              </div>
              <h4 className="font-bold mb-2">Admin</h4>
              <ul className="text-sm text-gray-600 space-y-1">
                <li className="text-success">✅ View all files</li>
                <li className="text-success">✅ Audit logs</li>
                <li className="text-success">✅ Manage users</li>
                <li className="text-success">✅ System config</li>
              </ul>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}

export default FeaturesSection;
