const express = require('express');
const { body } = require('express-validator');
const AuthController = require('../controllers/authController');
const { authMiddleware } = require('../middleware/authMiddleware');
const auditMiddleware = require('../middleware/auditMiddleware');

const router = express.Router();

// Validation rules
const loginValidation = [
  body('username').trim().notEmpty().withMessage('Username is required'),
  body('password').notEmpty().withMessage('Password is required')
];

const changePasswordValidation = [
  body('currentPassword').notEmpty().withMessage('Current password is required'),
  body('newPassword')
    .isLength({ min: 6 })
    .withMessage('New password must be at least 6 characters long')
    .matches(/^(?=.*[a-z])(?=.*[A-Z])(?=.*\d)/)
    .withMessage('New password must contain at least one lowercase letter, one uppercase letter, and one number')
];

// Routes
router.post('/login', loginValidation, AuthController.login);
router.get('/profile', authMiddleware, auditMiddleware('read', 'user'), AuthController.getProfile);
router.post('/change-password', authMiddleware, changePasswordValidation, AuthController.changePassword);
router.post('/logout', authMiddleware, AuthController.logout);

module.exports = router;