const { Office, Category, User, SLAPolicy } = require('../models');

class MasterDataController {
  /**
   * Get all offices
   */
  static async getOffices(req, res) {
    try {
      const offices = await Office.findAll({
        where: { is_active: true },
        include: [
          { model: User, as: 'head', attributes: ['id', 'full_name', 'designation'] }
        ],
        order: [['name', 'ASC']]
      });

      res.json({
        success: true,
        data: offices
      });
    } catch (error) {
      console.error('Get offices error:', error);
      res.status(500).json({
        success: false,
        message: 'Internal server error'
      });
    }
  }

  /**
   * Get all categories
   */
  static async getCategories(req, res) {
    try {
      const categories = await Category.findAll({
        where: { is_active: true },
        order: [['name', 'ASC']]
      });

      res.json({
        success: true,
        data: categories
      });
    } catch (error) {
      console.error('Get categories error:', error);
      res.status(500).json({
        success: false,
        message: 'Internal server error'
      });
    }
  }

  /**
   * Get users by role
   */
  static async getUsers(req, res) {
    try {
      const { role } = req.query;
      const whereConditions = { is_active: true };
      
      if (role) {
        whereConditions.role = role;
      }

      const users = await User.findAll({
        where: whereConditions,
        attributes: ['id', 'username', 'full_name', 'designation', 'department', 'role', 'employee_id'],
        order: [['full_name', 'ASC']]
      });

      res.json({
        success: true,
        data: users
      });
    } catch (error) {
      console.error('Get users error:', error);
      res.status(500).json({
        success: false,
        message: 'Internal server error'
      });
    }
  }

  /**
   * Get SLA policies
   */
  static async getSLAPolicies(req, res) {
    try {
      const { category_id } = req.query;
      const whereConditions = { is_active: true };
      
      if (category_id) {
        whereConditions.category_id = category_id;
      }

      const policies = await SLAPolicy.findAll({
        where: whereConditions,
        include: [
          { model: Category, as: 'category', attributes: ['id', 'name', 'code'] }
        ],
        order: [['category_id', 'ASC'], ['priority', 'ASC']]
      });

      res.json({
        success: true,
        data: policies
      });
    } catch (error) {
      console.error('Get SLA policies error:', error);
      res.status(500).json({
        success: false,
        message: 'Internal server error'
      });
    }
  }

  /**
   * Get application constants
   */
  static async getConstants(req, res) {
    try {
      const constants = {
        priorities: [
          { value: 'routine', label: 'Routine', color: '#10B981' },
          { value: 'urgent', label: 'Urgent', color: '#F59E0B' },
          { value: 'critical', label: 'Critical', color: '#EF4444' }
        ],
        statuses: [
          { value: 'open', label: 'Open', color: '#6B7280' },
          { value: 'with_officer', label: 'With Officer', color: '#3B82F6' },
          { value: 'with_cof', label: 'With COF', color: '#8B5CF6' },
          { value: 'dispatched', label: 'Dispatched', color: '#10B981' },
          { value: 'on_hold', label: 'On Hold', color: '#F59E0B' },
          { value: 'waiting_on_origin', label: 'Waiting on Origin', color: '#F97316' },
          { value: 'closed', label: 'Closed', color: '#6B7280' }
        ],
        sla_statuses: [
          { value: 'on_track', label: 'On Track', color: '#10B981' },
          { value: 'warning', label: 'Warning', color: '#F59E0B' },
          { value: 'breach', label: 'Breach', color: '#EF4444' }
        ],
        action_types: [
          { value: 'forward', label: 'Forward' },
          { value: 'return', label: 'Return for Rework' },
          { value: 'seek_info', label: 'Seek Clarification' },
          { value: 'hold', label: 'Put On Hold' },
          { value: 'escalate', label: 'Escalate to COF' },
          { value: 'dispatch', label: 'Dispatch to Authority' }
        ],
        roles: [
          { value: 'clerk', label: 'Clerk' },
          { value: 'accounts_officer', label: 'Accounts Officer' },
          { value: 'cof', label: 'Chief Officer Finance' },
          { value: 'admin', label: 'Administrator' }
        ]
      };

      res.json({
        success: true,
        data: constants
      });
    } catch (error) {
      console.error('Get constants error:', error);
      res.status(500).json({
        success: false,
        message: 'Internal server error'
      });
    }
  }
}

module.exports = MasterDataController;