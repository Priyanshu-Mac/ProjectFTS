const { AuditLog } = require('../models');

const auditMiddleware = (action, resourceType) => {
  return async (req, res, next) => {
    const originalSend = res.send;
    
    res.send = function(data) {
      // Log the audit entry after successful response
      if (req.user && res.statusCode < 400) {
        const auditData = {
          user_id: req.user.id,
          action,
          resource_type: resourceType,
          resource_id: req.params.id || req.body.id || null,
          details: {
            method: req.method,
            url: req.originalUrl,
            query: req.query,
            body: action !== 'read' ? req.body : undefined
          },
          ip_address: req.ip || req.connection.remoteAddress,
          user_agent: req.get('user-agent')
        };

        AuditLog.create(auditData).catch(err => {
          console.error('Audit log creation failed:', err);
        });
      }
      
      originalSend.call(this, data);
    };
    
    next();
  };
};

module.exports = auditMiddleware;