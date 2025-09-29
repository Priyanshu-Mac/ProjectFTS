const express = require('express');
const DashboardController = require('../controllers/dashboardController');
const { authMiddleware, authorize } = require('../middleware/authMiddleware');
const auditMiddleware = require('../middleware/auditMiddleware');

const router = express.Router();

// Executive dashboard (COF access)
router.get('/executive', 
  authMiddleware, 
  authorize('cof', 'admin'), 
  auditMiddleware('read', 'dashboard'), 
  DashboardController.getExecutiveDashboard
);

// Officer dashboard
router.get('/officer', 
  authMiddleware, 
  authorize('accounts_officer', 'cof', 'admin'), 
  auditMiddleware('read', 'dashboard'), 
  DashboardController.getOfficerDashboard
);

// Analytics dashboard
router.get('/analytics', 
  authMiddleware, 
  authorize('cof', 'admin'), 
  auditMiddleware('read', 'analytics'), 
  DashboardController.getAnalytics
);

module.exports = router;