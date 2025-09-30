import React, { useState, useEffect } from 'react';
import { useQuery } from '@tanstack/react-query';
import { 
  FileText, 
  Clock, 
  AlertTriangle, 
  TrendingUp,
  Users,
  Calendar,
  BarChart3
} from 'lucide-react';
import { dashboardService } from '../services/dashboardService';
import { fileService } from '../services/fileService';
import { authService } from '../services/authService';
import LoadingSpinner from '../components/common/LoadingSpinner';
import StatusBadge from '../components/common/StatusBadge';
import { formatDistanceToNow, format } from 'date-fns';

const DashboardPage = () => {
  const currentUser = authService.getCurrentUser();
  const isCOF = currentUser?.role === 'cof' || currentUser?.role === 'admin';
  const isClerk = currentUser?.role === 'clerk';

  // Fetch dashboard data based on user role (COF/Admin vs Officer). Disabled for clerks.
  const { data: dashboardData, isLoading, error } = useQuery({
    queryKey: isCOF ? ['dashboard', 'executive'] : ['dashboard', 'officer'],
    queryFn: isCOF ? dashboardService.getExecutiveDashboard : dashboardService.getOfficerDashboard,
    refetchInterval: 30000, // Refresh every 30 seconds
    // Only run when we have a current user and the user isn't a clerk. This prevents
    // the officer dashboard from firing during initial render when currentUser may be null.
    enabled: !!currentUser?.id && !isClerk,
  });

  // For clerks we will show a focused view: file intake link and files owned by the clerk
  const { data: clerkFilesData, isLoading: isClerkLoading, error: clerkError } = useQuery({
    queryKey: ['files', 'owned', currentUser?.id],
    // Request files with optimistic server-side filters and also apply a defensive
    // client-side filter to ensure we only show files that were created by the
    // current clerk and that are file-intake type (handles different backend field names).
    queryFn: async () => {
      // Ask the API to filter by creator/type if it supports those params. We keep
      // `holder` for compatibility but rely on client-side filtering below as a fallback.
      const res = await fileService.listFiles({ holder: currentUser?.id, creator: currentUser?.id, type: 'file_intake', page: 1, limit: 50 });

      // Debug: raw API response
      // eslint-disable-next-line no-console
      console.log('[Dashboard] fileService.listFiles raw response:', res);

      // Normalize the list of files whether the service returned an array or an
      // object with `data` or `results` (API sample uses `results`).
      const files = Array.isArray(res) ? res : (res?.data ?? res?.results ?? []);

      // Debug: normalized files
      // eslint-disable-next-line no-console
      console.log('[Dashboard] normalized files count:', Array.isArray(files) ? files.length : (files?.length ?? 0));
      // eslint-disable-next-line no-console
      console.log('[Dashboard] normalized files sample:', Array.isArray(files) ? files.slice(0,5) : (files?.slice ? files.slice(0,5) : files));

      // Return the API-filtered results unchanged (preserve response shape)
      if (Array.isArray(res)) {
        return files;
      }
      if (res?.results) {
        return { ...res, results: files, total: files.length };
      }
      return { ...res, data: files, meta: { ...res?.meta, total: files.length } };
    },
    enabled: !!isClerk && !!currentUser?.id,
    refetchInterval: 30000,
  });

  // Log clerkFilesData updates for debugging
  React.useEffect(() => {
    // eslint-disable-next-line no-console
    console.log('[Dashboard] clerkFilesData changed:', clerkFilesData);
  }, [clerkFilesData]);

  if (isLoading || (isClerk && isClerkLoading)) {
    return (
      <div className="flex items-center justify-center h-64">
        <LoadingSpinner size="lg" text="Loading dashboard..." />
      </div>
    );
  }

  if (error || (isClerk && clerkError)) {
    return (
      <div className="bg-red-50 border border-red-200 rounded-lg p-4">
        <p className="text-red-800">Failed to load dashboard data. Please try again.</p>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {/* Page Header */}
      <div className="border-b border-gray-200 pb-4">
        <h1 className="text-2xl font-bold text-gray-900">
          {isCOF ? 'Executive Dashboard' : 'My Dashboard'}
        </h1>
        <p c  lassName="mt-1 text-sm text-gray-600">
          {isCOF 
            ? 'Overview of file processing and department performance' 
            : 'Your current workload and pending files'
          }
        </p>
      </div>

      {isClerk ? (
      <ClerkDashboard files={
        Array.isArray(clerkFilesData)
          ? clerkFilesData
          : (clerkFilesData?.data ?? clerkFilesData?.results ?? [])
      } />
      ) : isCOF ? (
        <ExecutiveDashboard data={dashboardData.data} />
      ) : (
        <OfficerDashboard data={dashboardData.data} />
      )}
    </div>
  );
};

const ClerkDashboard = ({ files = [] }) => {
  return (
    <div className="space-y-6">
      <div className="border-b border-gray-200 pb-4">
        <h1 className="text-2xl font-bold text-gray-900">Clerk Dashboard</h1>
        <p className="mt-1 text-sm text-gray-600">File intake and your owned files</p>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
        <div className="card">
          <div className="card-body text-center">
            <h3 className="text-lg font-medium">File Intake</h3>
            <p className="text-sm text-gray-500 mt-2">Create new files (Clerk access)</p>
            <div className="mt-4">
              <a href="/file-intake" className="btn btn-primary">Go to File Intake</a>
            </div>
          </div>
        </div>

        <div className="card">
          <div className="card-header">
            <h3 className="text-lg font-medium text-gray-900">My Owned Files</h3>
            <p className="text-sm text-gray-500">Files you created/own</p>
          </div>
          <div className="card-body">
            {files.length > 0 ? (
              <div className="space-y-3">
                {files.slice(0, 10).map((file) => (
                  <div key={file.id} className="p-3 rounded-lg bg-gray-50">
                    <div className="flex items-center justify-between">
                      <div className="flex-1">
                        <div className="flex items-baseline gap-3">
                          <div className="text-sm font-medium text-gray-900">{file.file_no}</div>
                          <div className="text-xs text-gray-500"># {file.id}</div>
                        </div>
                        <div className="text-xs text-gray-500 truncate">{file.subject}</div>
                      </div>
                      <div className="text-right">
                        <StatusBadge status={file.status} />
                      </div>
                    </div>
                  </div>
                ))}
                {files.length > 10 && (
                  <div className="text-center pt-2">
                    <span className="text-sm text-gray-500">+{files.length - 10} more files</span>
                  </div>
                )}
              </div>
            ) : (
              <p className="text-gray-500 text-center py-4">You have no owned files</p>
            )}
          </div>
        </div>
      </div>
    </div>
  );
};

const ExecutiveDashboard = ({ data }) => {
  const { kpis, oldest_files, longest_delays, pendency_by_office, aging_buckets, imminent_breaches } = data;

  return (
    <>
      {/* KPI Cards */}
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
        <KPICard
          title="Files in Accounts"
          value={kpis.files_in_accounts}
          subtitle={`${kpis.files_today} received today`}
          icon={FileText}
          color="blue"
        />
        <KPICard
          title="Weekly On-time %"
          value={`${kpis.weekly_ontime_percentage}%`}
          subtitle="Current week performance"
          icon={TrendingUp}
          color="green"
        />
        <KPICard
          title="Average TAT"
          value={`${kpis.average_tat_days} days`}
          subtitle="Business days average"
          icon={Clock}
          color="orange"
        />
        <KPICard
          title="Overdue Files"
          value={longest_delays.length}
          subtitle="Requiring immediate attention"
          icon={AlertTriangle}
          color="red"
        />
      </div>

      {/* Main Content Grid */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* Longest Delays */}
        <div className="card">
          <div className="card-header">
            <h3 className="text-lg font-medium text-gray-900">Longest Delays</h3>
            <p className="text-sm text-gray-500">Files breaching SLA</p>
          </div>
          <div className="card-body">
            {longest_delays.length > 0 ? (
              <div className="space-y-3">
                {longest_delays.slice(0, 5).map((file) => (
                  <div key={file.id} className="flex items-center justify-between p-3 bg-red-50 rounded-lg">
                    <div className="flex-1">
                      <div className="text-sm font-medium text-gray-900">{file.file_no}</div>
                      <div className="text-xs text-gray-500 truncate">{file.subject}</div>
                      <div className="text-xs text-gray-500">
                        With: {file.currentHolder?.full_name}
                      </div>
                    </div>
                    <div className="text-right">
                      <div className="text-xs text-red-600 font-medium">
                        {formatDistanceToNow(new Date(file.date_received_accounts), { addSuffix: true })}
                      </div>
                      <StatusBadge status="breach" />
                    </div>
                  </div>
                ))}
              </div>
            ) : (
              <p className="text-gray-500 text-center py-4">No overdue files</p>
            )}
          </div>
        </div>

        {/* Pendency by Office */}
        <div className="card">
          <div className="card-header">
            <h3 className="text-lg font-medium text-gray-900">Pendency by Office</h3>
            <p className="text-sm text-gray-500">Current workload distribution</p>
          </div>
          <div className="card-body">
            {pendency_by_office.length > 0 ? (
              <div className="space-y-3">
                {pendency_by_office.map((office) => (
                  <div key={office.office_code} className="flex items-center justify-between">
                    <div>
                      <div className="text-sm font-medium text-gray-900">{office.office_name}</div>
                      <div className="text-xs text-gray-500">{office.office_code}</div>
                    </div>
                    <div className="text-right">
                      <div className="text-sm font-medium text-gray-900">{office.pending_count}</div>
                      {office.breach_count > 0 && (
                        <div className="text-xs text-red-600">{office.breach_count} breached</div>
                      )}
                    </div>
                  </div>
                ))}
              </div>
            ) : (
              <p className="text-gray-500 text-center py-4">No pending files</p>
            )}
          </div>
        </div>
      </div>

      {/* Imminent Breaches */}
      {imminent_breaches.length > 0 && (
        <div className="card">
          <div className="card-header">
            <h3 className="text-lg font-medium text-gray-900">Imminent SLA Breaches</h3>
            <p className="text-sm text-gray-500">Due in next 24 business hours</p>
          </div>
          <div className="card-body">
            <div className="overflow-x-auto">
              <table className="table">
                <thead className="table-header">
                  <tr>
                    <th>File No</th>
                    <th>Subject</th>
                    <th>Current Holder</th>
                    <th>Due Date</th>
                    <th>Status</th>
                  </tr>
                </thead>
                <tbody className="table-body">
                  {imminent_breaches.map((file) => (
                    <tr key={file.id}>
                      <td className="font-medium">{file.file_no}</td>
                      <td className="max-w-xs truncate">{file.subject}</td>
                      <td>{file.currentHolder?.full_name}</td>
                      <td>{format(new Date(file.sla_due_date), 'MMM dd, yyyy HH:mm')}</td>
                      <td>
                        <StatusBadge status={file.sla_status} />
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        </div>
      )}
    </>
  );
};

const OfficerDashboard = ({ data }) => {
  const { my_queue, summary } = data;

  return (
    <>
      {/* Summary Cards */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
        <KPICard
          title="Assigned Files"
          value={summary.total_assigned}
          subtitle="Current workload"
          icon={FileText}
          color="blue"
        />
        <KPICard
          title="Due Soon"
          value={summary.total_due_soon}
          subtitle="Next 24 hours"
          icon={Clock}
          color="orange"
        />
        <KPICard
          title="Overdue"
          value={summary.total_overdue}
          subtitle="Requires immediate attention"
          icon={AlertTriangle}
          color="red"
        />
      </div>

      {/* File Queue */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* Assigned Files */}
        <FileQueueCard 
          title="Assigned Files" 
          files={my_queue.assigned} 
          emptyMessage="No files assigned"
        />
        
        {/* Due Soon */}
        <FileQueueCard 
          title="Due Soon" 
          files={my_queue.due_soon} 
          emptyMessage="No files due soon"
          highlight="warning"
        />
        
        {/* Overdue */}
        <FileQueueCard 
          title="Overdue Files" 
          files={my_queue.overdue} 
          emptyMessage="No overdue files"
          highlight="danger"
        />
        
        {/* On Hold */}
        <FileQueueCard 
          title="On Hold" 
          files={my_queue.on_hold} 
          emptyMessage="No files on hold"
        />
      </div>
    </>
  );
};

const KPICard = ({ title, value, subtitle, icon: Icon, color }) => {
  const colorClasses = {
    blue: 'bg-blue-500 text-blue-600 bg-blue-100',
    green: 'bg-green-500 text-green-600 bg-green-100',
    orange: 'bg-orange-500 text-orange-600 bg-orange-100',
    red: 'bg-red-500 text-red-600 bg-red-100'
  };

  const [bgColor, textColor, iconBg] = colorClasses[color].split(' ');

  return (
    <div className="card">
      <div className="card-body">
        <div className="flex items-center">
          <div className={`p-2 rounded-lg ${iconBg}`}>
            <Icon className={`h-6 w-6 ${textColor}`} />
          </div>
          <div className="ml-4 flex-1">
            <div className="text-2xl font-bold text-gray-900">{value}</div>
            <div className="text-sm font-medium text-gray-600">{title}</div>
            <div className="text-xs text-gray-500">{subtitle}</div>
          </div>
        </div>
      </div>
    </div>
  );
};

const FileQueueCard = ({ title, files, emptyMessage, highlight }) => {
  const highlightClasses = {
    warning: 'border-l-4 border-yellow-400 bg-yellow-50',
    danger: 'border-l-4 border-red-400 bg-red-50'
  };

  return (
    <div className="card">
      <div className="card-header">
        <h3 className="text-lg font-medium text-gray-900">{title}</h3>
        <span className="text-sm text-gray-500">({files.length})</span>
      </div>
      <div className="card-body">
        {files.length > 0 ? (
          <div className="space-y-3">
            {files.slice(0, 5).map((file) => (
              <div 
                key={file.id} 
                className={`p-3 rounded-lg ${highlight ? highlightClasses[highlight] : 'bg-gray-50'}`}
              >
                <div className="flex items-center justify-between">
                  <div className="flex-1">
                    <div className="text-sm font-medium text-gray-900">{file.file_no}</div>
                    <div className="text-xs text-gray-500 truncate">{file.subject}</div>
                    <div className="flex items-center space-x-2 mt-1">
                      <StatusBadge status={file.priority} />
                      <span className="text-xs text-gray-500">
                        {file.owningOffice?.name}
                      </span>
                    </div>
                  </div>
                  <div className="text-right">
                    <StatusBadge status={file.status} />
                  </div>
                </div>
              </div>
            ))}
            {files.length > 5 && (
              <div className="text-center pt-2">
                <span className="text-sm text-gray-500">+{files.length - 5} more files</span>
              </div>
            )}
          </div>
        ) : (
          <p className="text-gray-500 text-center py-4">{emptyMessage}</p>
        )}
      </div>
    </div>
  );
};

export default DashboardPage;