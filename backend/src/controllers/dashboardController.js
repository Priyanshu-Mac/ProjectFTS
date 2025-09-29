const { Op } = require('sequelize');
const { sequelize } = require('../config/database');
const { File, FileEvent, User, Office, Category } = require('../models');
const BusinessTimeCalculator = require('../utils/businessTimeCalculator');

class DashboardController {
  /**
   * Get executive dashboard data (COF view)
   */
  static async getExecutiveDashboard(req, res) {
    try {
      const today = new Date();
      const startOfWeek = new Date(today.setDate(today.getDate() - today.getDay()));
      const endOfWeek = new Date(startOfWeek);
      endOfWeek.setDate(startOfWeek.getDate() + 6);

      // KPI Strip
      const [
        totalFilesInAccounts,
        filesToday,
        weeklyOnTimePercentage,
        averageTAT,
        oldestFiles
      ] = await Promise.all([
        // Total files currently in accounts
        File.count({
          where: { 
            status: { [Op.in]: ['open', 'with_officer', 'with_cof', 'on_hold', 'waiting_on_origin'] }
          }
        }),

        // Files received today
        File.count({
          where: {
            date_received_accounts: {
              [Op.gte]: new Date(new Date().setHours(0, 0, 0, 0))
            }
          }
        }),

        // Weekly on-time percentage
        this.calculateWeeklyOnTimePercentage(startOfWeek, endOfWeek),

        // Average TAT in business days
        this.calculateAverageTAT(),

        // Oldest 5 files
        File.findAll({
          where: { 
            status: { [Op.in]: ['with_officer', 'with_cof', 'on_hold'] }
          },
          include: [
            { model: User, as: 'currentHolder', attributes: ['full_name'] },
            { model: Office, as: 'owningOffice', attributes: ['name'] }
          ],
          order: [['date_received_accounts', 'ASC']],
          limit: 5
        })
      ]);

      // Longest delays (files breaching SLA)
      const longestDelays = await File.findAll({
        where: { 
          sla_status: 'breach',
          status: { [Op.in]: ['with_officer', 'with_cof', 'on_hold'] }
        },
        include: [
          { model: User, as: 'currentHolder', attributes: ['full_name'] },
          { model: Office, as: 'owningOffice', attributes: ['name'] }
        ],
        order: [['date_received_accounts', 'ASC']],
        limit: 10
      });

      // Pendency by owning office
      const pendencyByOffice = await sequelize.query(`
        SELECT o.name as office_name, o.code as office_code,
               COUNT(f.id) as pending_count,
               SUM(CASE WHEN f.sla_status = 'breach' THEN 1 ELSE 0 END) as breach_count
        FROM files f
        JOIN offices o ON f.owning_office_id = o.id
        WHERE f.status IN ('open', 'with_officer', 'with_cof', 'on_hold', 'waiting_on_origin')
        GROUP BY o.id, o.name, o.code
        ORDER BY pending_count DESC
      `, { type: sequelize.QueryTypes.SELECT });

      // Aging buckets
      const agingBuckets = await this.getAgingBuckets();

      // Imminent SLA breaches (due in next 24 business hours)
      const businessTimeCalc = new BusinessTimeCalculator();
      const next24Hours = await businessTimeCalc.addBusinessMinutes(new Date(), 24 * 60);
      
      const imminentBreaches = await File.findAll({
        where: {
          sla_due_date: { [Op.lte]: next24Hours },
          sla_status: { [Op.in]: ['on_track', 'warning'] },
          status: { [Op.in]: ['with_officer', 'with_cof'] }
        },
        include: [
          { model: User, as: 'currentHolder', attributes: ['full_name'] },
          { model: Category, as: 'category', attributes: ['name'] }
        ],
        order: [['sla_due_date', 'ASC']]
      });

      res.json({
        success: true,
        data: {
          kpis: {
            files_in_accounts: totalFilesInAccounts,
            files_today: filesToday,
            weekly_ontime_percentage: weeklyOnTimePercentage,
            average_tat_days: averageTAT
          },
          oldest_files: oldestFiles,
          longest_delays: longestDelays,
          pendency_by_office: pendencyByOffice,
          aging_buckets: agingBuckets,
          imminent_breaches: imminentBreaches
        }
      });
    } catch (error) {
      console.error('Executive dashboard error:', error);
      res.status(500).json({
        success: false,
        message: 'Internal server error'
      });
    }
  }

  /**
   * Get officer dashboard data
   */
  static async getOfficerDashboard(req, res) {
    try {
      const userId = req.user.id;

      // My queue with different statuses
      const [
        assigned,
        awaitingInfo,
        onHold,
        dueSoon,
        overdue
      ] = await Promise.all([
        // Assigned to me
        File.findAll({
          where: {
            current_holder_user_id: userId,
            status: 'with_officer'
          },
          include: [
            { model: Office, as: 'owningOffice', attributes: ['name', 'code'] },
            { model: Category, as: 'category', attributes: ['name', 'color'] }
          ],
          order: [['date_received_accounts', 'ASC']]
        }),

        // Waiting for information
        File.findAll({
          where: {
            current_holder_user_id: userId,
            status: 'waiting_on_origin'
          },
          include: [
            { model: Office, as: 'owningOffice', attributes: ['name', 'code'] },
            { model: Category, as: 'category', attributes: ['name', 'color'] }
          ]
        }),

        // On hold
        File.findAll({
          where: {
            current_holder_user_id: userId,
            status: 'on_hold'
          },
          include: [
            { model: Office, as: 'owningOffice', attributes: ['name', 'code'] },
            { model: Category, as: 'category', attributes: ['name', 'color'] }
          ]
        }),

        // Due soon (next 24 business hours)
        this.getFilesDueSoon(userId),

        // Overdue
        File.findAll({
          where: {
            current_holder_user_id: userId,
            sla_status: 'breach',
            status: { [Op.in]: ['with_officer', 'on_hold'] }
          },
          include: [
            { model: Office, as: 'owningOffice', attributes: ['name', 'code'] },
            { model: Category, as: 'category', attributes: ['name', 'color'] }
          ]
        })
      ]);

      res.json({
        success: true,
        data: {
          my_queue: {
            assigned,
            awaiting_info: awaitingInfo,
            on_hold: onHold,
            due_soon: dueSoon,
            overdue
          },
          summary: {
            total_assigned: assigned.length,
            total_overdue: overdue.length,
            total_due_soon: dueSoon.length
          }
        }
      });
    } catch (error) {
      console.error('Officer dashboard error:', error);
      res.status(500).json({
        success: false,
        message: 'Internal server error'
      });
    }
  }

  /**
   * Get analytics data
   */
  static async getAnalytics(req, res) {
    try {
      const { period = '30', office_id, category_id } = req.query;
      const days = parseInt(period);
      const startDate = new Date();
      startDate.setDate(startDate.getDate() - days);

      // Build filters
      const whereConditions = {
        created_at: { [Op.gte]: startDate }
      };
      if (office_id) whereConditions.owning_office_id = office_id;
      if (category_id) whereConditions.category_id = category_id;

      const [
        owningOfficeReport,
        categoryReport,
        bottleneckMap,
        reworkHeatmap
      ] = await Promise.all([
        this.getOwningOfficeReport(whereConditions),
        this.getCategoryReport(whereConditions),
        this.getBottleneckMap(whereConditions),
        this.getReworkHeatmap(whereConditions)
      ]);

      res.json({
        success: true,
        data: {
          period_days: days,
          owning_office_report: owningOfficeReport,
          category_report: categoryReport,
          bottleneck_map: bottleneckMap,
          rework_heatmap: reworkHeatmap
        }
      });
    } catch (error) {
      console.error('Analytics error:', error);
      res.status(500).json({
        success: false,
        message: 'Internal server error'
      });
    }
  }

  // Helper methods
  static async calculateWeeklyOnTimePercentage(startOfWeek, endOfWeek) {
    const completedFiles = await File.findAll({
      where: {
        status: { [Op.in]: ['dispatched', 'closed'] },
        updated_at: { [Op.between]: [startOfWeek, endOfWeek] }
      }
    });

    if (completedFiles.length === 0) return 100;

    const onTimeFiles = completedFiles.filter(file => file.sla_status !== 'breach');
    return Math.round((onTimeFiles.length / completedFiles.length) * 100);
  }

  static async calculateAverageTAT() {
    const result = await sequelize.query(`
      SELECT AVG(total_business_minutes / 1440) as avg_tat_days
      FROM files 
      WHERE status IN ('dispatched', 'closed') 
      AND total_business_minutes > 0
      AND created_at >= DATE_SUB(NOW(), INTERVAL 30 DAY)
    `, { type: sequelize.QueryTypes.SELECT });

    return Math.round((result[0]?.avg_tat_days || 0) * 10) / 10;
  }

  static async getAgingBuckets() {
    const result = await sequelize.query(`
      SELECT 
        CASE 
          WHEN DATEDIFF(NOW(), date_received_accounts) <= 2 THEN '0-2 days'
          WHEN DATEDIFF(NOW(), date_received_accounts) <= 5 THEN '3-5 days'
          WHEN DATEDIFF(NOW(), date_received_accounts) <= 10 THEN '6-10 days'
          ELSE '>10 days'
        END as age_bucket,
        c.name as category_name,
        COUNT(*) as count
      FROM files f
      JOIN categories c ON f.category_id = c.id
      WHERE f.status IN ('open', 'with_officer', 'with_cof', 'on_hold', 'waiting_on_origin')
      GROUP BY age_bucket, c.name
      ORDER BY 
        CASE age_bucket
          WHEN '0-2 days' THEN 1
          WHEN '3-5 days' THEN 2
          WHEN '6-10 days' THEN 3
          ELSE 4
        END, c.name
    `, { type: sequelize.QueryTypes.SELECT });

    return result;
  }

  static async getFilesDueSoon(userId) {
    const businessTimeCalc = new BusinessTimeCalculator();
    const next24Hours = await businessTimeCalc.addBusinessMinutes(new Date(), 24 * 60);

    return File.findAll({
      where: {
        current_holder_user_id: userId,
        sla_due_date: { [Op.lte]: next24Hours },
        sla_status: { [Op.in]: ['on_track', 'warning'] },
        status: 'with_officer'
      },
      include: [
        { model: Office, as: 'owningOffice', attributes: ['name', 'code'] },
        { model: Category, as: 'category', attributes: ['name', 'color'] }
      ],
      order: [['sla_due_date', 'ASC']]
    });
  }

  static async getOwningOfficeReport(whereConditions) {
    return sequelize.query(`
      SELECT 
        o.name as office_name,
        COUNT(f.id) as total_files,
        SUM(CASE WHEN f.sla_status != 'breach' THEN 1 ELSE 0 END) as ontime_files,
        ROUND(AVG(f.total_business_minutes / 1440), 1) as avg_tat_days,
        ROUND((SUM(CASE WHEN f.sla_status != 'breach' THEN 1 ELSE 0 END) / COUNT(f.id)) * 100, 1) as ontime_percentage
      FROM files f
      JOIN offices o ON f.owning_office_id = o.id
      WHERE f.created_at >= :startDate
      GROUP BY o.id, o.name
      ORDER BY total_files DESC
    `, {
      replacements: { startDate: whereConditions.created_at[Op.gte] },
      type: sequelize.QueryTypes.SELECT
    });
  }

  static async getCategoryReport(whereConditions) {
    return sequelize.query(`
      SELECT 
        c.name as category_name,
        COUNT(f.id) as total_files,
        ROUND(AVG(f.total_business_minutes / 1440), 1) as avg_processing_days,
        SUM(CASE WHEN f.sla_status = 'breach' THEN 1 ELSE 0 END) as breach_count
      FROM files f
      JOIN categories c ON f.category_id = c.id
      WHERE f.created_at >= :startDate
      GROUP BY c.id, c.name
      ORDER BY total_files DESC
    `, {
      replacements: { startDate: whereConditions.created_at[Op.gte] },
      type: sequelize.QueryTypes.SELECT
    });
  }

  static async getBottleneckMap(whereConditions) {
    return sequelize.query(`
      SELECT 
        u_from.full_name as from_user,
        u_to.full_name as to_user,
        COUNT(*) as movement_count,
        ROUND(AVG(fe.business_minutes_held / 1440), 1) as avg_hold_days
      FROM file_events fe
      JOIN files f ON fe.file_id = f.id
      LEFT JOIN users u_from ON fe.from_user_id = u_from.id
      JOIN users u_to ON fe.to_user_id = u_to.id
      WHERE f.created_at >= :startDate AND fe.action_type = 'forward'
      GROUP BY fe.from_user_id, fe.to_user_id, u_from.full_name, u_to.full_name
      HAVING movement_count > 1
      ORDER BY movement_count DESC
      LIMIT 20
    `, {
      replacements: { startDate: whereConditions.created_at[Op.gte] },
      type: sequelize.QueryTypes.SELECT
    });
  }

  static async getReworkHeatmap(whereConditions) {
    return sequelize.query(`
      SELECT 
        c.name as category_name,
        o.name as office_name,
        COUNT(CASE WHEN fe.action_type = 'return' THEN 1 END) as rework_count,
        COUNT(DISTINCT f.id) as total_files,
        ROUND(COUNT(CASE WHEN fe.action_type = 'return' THEN 1 END) / COUNT(DISTINCT f.id), 2) as rework_ratio
      FROM files f
      JOIN categories c ON f.category_id = c.id
      JOIN offices o ON f.owning_office_id = o.id
      JOIN file_events fe ON f.id = fe.file_id
      WHERE f.created_at >= :startDate
      GROUP BY c.id, o.id, c.name, o.name
      HAVING total_files > 0
      ORDER BY rework_ratio DESC
    `, {
      replacements: { startDate: whereConditions.created_at[Op.gte] },
      type: sequelize.QueryTypes.SELECT
    });
  }
}

module.exports = DashboardController;