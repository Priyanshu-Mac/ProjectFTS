const express = require('express');
const authRoutes = require('./authRoutes');
const fileRoutes = require('./fileRoutes');
const dashboardRoutes = require('./dashboardRoutes');
const masterDataRoutes = require('./masterDataRoutes');

const router = express.Router();

// API Routes
router.use('/auth', authRoutes);
router.use('/files', fileRoutes);
router.use('/dashboard', dashboardRoutes);
router.use('/master-data', masterDataRoutes);

// API Health Check
router.get('/health', (req, res) => {
  res.json({
    success: true,
    message: 'API is running',
    timestamp: new Date().toISOString()
  });
});

module.exports = router;