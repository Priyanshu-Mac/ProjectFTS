const express = require('express');
const { body, param } = require('express-validator');
const FileController = require('../controllers/fileController');
const { authMiddleware, authorize } = require('../middleware/authMiddleware');
const auditMiddleware = require('../middleware/auditMiddleware');

const router = express.Router();

// Validation rules
const createFileValidation = [
  body('subject').trim().notEmpty().withMessage('Subject is required'),
  body('notesheet_title').trim().notEmpty().withMessage('Notesheet title is required'),
  body('owning_office_id').isInt().withMessage('Valid owning office is required'),
  body('category_id').isInt().withMessage('Valid category is required'),
  body('priority').optional().isIn(['routine', 'urgent', 'critical']).withMessage('Invalid priority'),
  body('date_initiated').isISO8601().withMessage('Valid initiation date is required'),
  body('date_received_accounts').optional().isISO8601().withMessage('Invalid received date'),
  body('forward_to_user_id').isInt().withMessage('Valid officer to forward is required'),
  body('confidentiality').optional().isBoolean().withMessage('Confidentiality must be boolean')
];

const moveFileValidation = [
  param('id').isInt().withMessage('Valid file ID is required'),
  body('to_user_id').isInt().withMessage('Valid recipient is required'),
  body('action_type').isIn(['forward', 'return', 'seek_info', 'hold', 'escalate', 'dispatch']).withMessage('Invalid action type'),
  body('remarks').optional().trim(),
  body('pause_reason').optional().trim()
];

const fileIdValidation = [
  param('id').isInt().withMessage('Valid file ID is required')
];

// Routes
router.get('/next-number', 
  authMiddleware, 
  authorize('clerk', 'admin'), 
  FileController.getNextFileNumber
);

router.post('/', 
  authMiddleware, 
  authorize('clerk', 'admin'), 
  createFileValidation, 
  auditMiddleware('create', 'file'), 
  FileController.createFile
);

router.get('/search', 
  authMiddleware, 
  auditMiddleware('read', 'file'), 
  FileController.searchFiles
);

router.get('/:id', 
  authMiddleware, 
  fileIdValidation, 
  auditMiddleware('read', 'file'), 
  FileController.getFile
);

router.post('/:id/move', 
  authMiddleware, 
  authorize('accounts_officer', 'cof', 'admin'), 
  moveFileValidation, 
  auditMiddleware('update', 'file'), 
  FileController.moveFile
);

module.exports = router;