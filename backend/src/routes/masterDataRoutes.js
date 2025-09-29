const express = require('express');
const MasterDataController = require('../controllers/masterDataController');
const { authMiddleware } = require('../middleware/authMiddleware');

const router = express.Router();

// Get master data
router.get('/offices', authMiddleware, MasterDataController.getOffices);
router.get('/categories', authMiddleware, MasterDataController.getCategories);
router.get('/users', authMiddleware, MasterDataController.getUsers);
router.get('/sla-policies', authMiddleware, MasterDataController.getSLAPolicies);
router.get('/constants', authMiddleware, MasterDataController.getConstants);

module.exports = router;