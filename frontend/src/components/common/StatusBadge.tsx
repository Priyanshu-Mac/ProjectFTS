import React from 'react';

const StatusBadge = ({ status, className = '' }) => {
  const getStatusConfig = (status) => {
    const configs = {
      // File statuses
      open: { label: 'Open', className: 'badge-secondary' },
      with_officer: { label: 'With Officer', className: 'badge-info' },
      with_cof: { label: 'With COF', className: 'badge-warning' },
      dispatched: { label: 'Dispatched', className: 'badge-success' },
      on_hold: { label: 'On Hold', className: 'badge-warning' },
      waiting_on_origin: { label: 'Waiting on Origin', className: 'badge-warning' },
      closed: { label: 'Closed', className: 'badge-secondary' },
      
      // SLA statuses
      on_track: { label: 'On Track', className: 'badge-success' },
      warning: { label: 'Warning', className: 'badge-warning' },
      breach: { label: 'Breach', className: 'badge-danger' },
      
      // Priority statuses
      routine: { label: 'Routine', className: 'badge-info' },
      urgent: { label: 'Urgent', className: 'badge-warning' },
      critical: { label: 'Critical', className: 'badge-danger' }
    };
    
    return configs[status] || { label: status, className: 'badge-secondary' };
  };

  const config = getStatusConfig(status);

  return (
    <span className={`badge ${config.className} ${className}`}>
      {config.label}
    </span>
  );
};

export default StatusBadge;