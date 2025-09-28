function StatsSection() {
  const stats = [
    { value: "50,000+", label: "Files Processed", subtext: "This month" },
    { value: "96.8%", label: "On-time Delivery", subtext: "SLA compliance" },
    { value: "2.3 days", label: "Average TAT", subtext: "Business days" },
    { value: "12 mins", label: "Avg Hold Time", subtext: "Per officer" }
  ];

  const recentActivity = [
    { file: "ACC-20250928-045", action: "Forwarded to Finance", officer: "R. Sharma", time: "5 mins ago", status: "success" },
    { file: "ACC-20250928-044", action: "Put on Hold", officer: "M. Singh", time: "12 mins ago", status: "warning" },
    { file: "ACC-20250928-043", action: "Dispatched to Authority", officer: "COF", time: "25 mins ago", status: "success" },
    { file: "ACC-20250928-042", action: "Escalated to COF", officer: "A. Kumar", time: "1 hour ago", status: "critical" },
    { file: "ACC-20250928-041", action: "Received in Accounts", officer: "P. Gupta", time: "2 hours ago", status: "info" }
  ];

  return (
    <section id="dashboard" className="py-20 bg-gray-50">
      <div className="container">
        <div className="text-center mb-16">
          <h2 className="text-3xl font-bold mb-4">Real-time Dashboard</h2>
          <p className="text-xl text-gray-600 max-w-3xl mx-auto">
            Live monitoring of file movement, officer performance, and system health 
            with actionable insights and immediate alerts.
          </p>
        </div>

        <div className="grid md:grid-cols-2 lg:grid-cols-4 gap-6 mb-16">
          {stats.map((stat, index) => (
            <div key={index} className="card text-center">
              <div className="text-3xl font-bold text-brand mb-2">{stat.value}</div>
              <div className="font-semibold text-gray-800 mb-1">{stat.label}</div>
              <div className="text-sm text-gray-500">{stat.subtext}</div>
            </div>
          ))}
        </div>

        <div className="grid lg:grid-cols-2 gap-8">
          <div className="card">
            <div className="border-b border-gray-200 pb-4 mb-6">
              <h3 className="text-xl font-bold text-gray-900">Live Activity Feed</h3>
            </div>
            <div className="space-y-4">
              {recentActivity.map((activity, index) => (
                <div key={index} className="flex items-center gap-4 p-3 bg-gray-50 rounded-lg">
                  <div className={`w-3 h-3 rounded-full ${
                    activity.status === 'success' ? 'bg-success' :
                    activity.status === 'warning' ? 'bg-warning' :
                    activity.status === 'critical' ? 'bg-danger' : 'bg-info'
                  }`}></div>
                  <div className="flex-1">
                    <div className="font-semibold text-sm">{activity.file}</div>
                    <div className="text-gray-600 text-sm">{activity.action}</div>
                  </div>
                  <div className="text-right text-sm">
                    <div className="font-medium">{activity.officer}</div>
                    <div className="text-gray-500">{activity.time}</div>
                  </div>
                </div>
              ))}
            </div>
          </div>

          <div className="card">
            <div className="border-b border-gray-200 pb-4 mb-6">
              <h3 className="text-xl font-bold text-gray-900">SLA Monitoring</h3>
            </div>
            <div className="space-y-4">
              <div className="flex items-center justify-between p-4 bg-green-50 rounded-lg border-l-4 border-success">
                <div>
                  <div className="font-bold text-success">On Track</div>
                  <div className="text-sm text-gray-600">42 files</div>
                </div>
                <div className="text-2xl font-bold text-success">78%</div>
              </div>
              <div className="flex items-center justify-between p-4 bg-yellow-50 rounded-lg border-l-4 border-warning">
                <div>
                  <div className="font-bold text-warning">Warning</div>
                  <div className="text-sm text-gray-600">8 files</div>
                </div>
                <div className="text-2xl font-bold text-warning">15%</div>
              </div>
              <div className="flex items-center justify-between p-4 bg-red-50 rounded-lg border-l-4 border-danger">
                <div>
                  <div className="font-bold text-danger">Breach</div>
                  <div className="text-sm text-gray-600">4 files</div>
                </div>
                <div className="text-2xl font-bold text-danger">7%</div>
              </div>
            </div>
            
            <div className="mt-6 p-4 bg-blue-50 rounded-lg">
              <h4 className="font-bold text-brand mb-2">Quick Actions</h4>
              <div className="grid grid-cols-2 gap-2">
                <button className="btn btn-primary text-sm">View Overdue</button>
                <button className="btn btn-secondary text-sm">Send Reminders</button>
                <button className="btn btn-warning text-sm">Generate Report</button>
                <button className="btn btn-success text-sm">Export Data</button>
              </div>
            </div>
          </div>
        </div>

        <div className="mt-16 bg-gradient-to-r from-brand to-brand-dark text-white rounded-xl p-8">
          <div className="grid md:grid-cols-3 gap-8 text-center">
            <div>
              <div className="text-3xl font-bold mb-2">24/7</div>
              <div className="opacity-80">Continuous Monitoring</div>
            </div>
            <div>
              <div className="text-3xl font-bold mb-2">100%</div>
              <div className="opacity-80">Audit Trail Coverage</div>
            </div>
            <div>
              <div className="text-3xl font-bold mb-2">&lt;1s</div>
              <div className="opacity-80">Search Response Time</div>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}

export default StatsSection;