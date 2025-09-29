const { validationResult } = require('express-validator');
const { Op } = require('sequelize');
const { File, FileEvent, User, Office, Category, SLAPolicy, Attachment } = require('../models');
const FileNumberGenerator = require('../utils/fileNumberGenerator');
const BusinessTimeCalculator = require('../utils/businessTimeCalculator');

class FileController {
  /**
   * Create new file (Intake)
   */
  static async createFile(req, res) {
    try {
      const errors = validationResult(req);
      if (!errors.isEmpty()) {
        return res.status(400).json({
          success: false,
          message: 'Validation failed',
          errors: errors.array()
        });
      }

      const {
        subject,
        notesheet_title,
        owning_office_id,
        category_id,
        priority = 'routine',
        date_initiated,
        date_received_accounts,
        forward_to_user_id,
        confidentiality = false,
        remarks
      } = req.body;

      // Generate unique file number
      const file_no = await FileNumberGenerator.generateFileNumber();

      // Find appropriate SLA policy
      const slaPolicy = await SLAPolicy.findOne({
        where: { category_id, priority, is_active: true }
      });

      // Calculate SLA due date
      const businessTimeCalc = new BusinessTimeCalculator();
      const sla_due_date = slaPolicy 
        ? await businessTimeCalc.addBusinessMinutes(
            new Date(date_received_accounts || new Date()), 
            slaPolicy.sla_hours * 60
          )
        : null;

      // Create file record
      const file = await File.create({
        file_no,
        subject,
        notesheet_title,
        owning_office_id,
        category_id,
        priority,
        date_initiated: new Date(date_initiated),
        date_received_accounts: new Date(date_received_accounts || new Date()),
        current_holder_user_id: forward_to_user_id,
        status: 'with_officer',
        confidentiality,
        sla_policy_id: slaPolicy?.id,
        sla_due_date,
        remarks,
        created_by: req.user.id
      });

      // Create initial file event (assignment)
      await FileEvent.create({
        file_id: file.id,
        seq_no: 1,
        from_user_id: null, // System assignment
        to_user_id: forward_to_user_id,
        action_type: 'receive',
        started_at: new Date(),
        remarks: 'Initial assignment from intake'
      });

      // Fetch complete file data with associations
      const completeFile = await File.findByPk(file.id, {
        include: [
          { model: User, as: 'creator', attributes: ['id', 'full_name', 'designation'] },
          { model: User, as: 'currentHolder', attributes: ['id', 'full_name', 'designation'] },
          { model: Office, as: 'owningOffice', attributes: ['id', 'name', 'code'] },
          { model: Category, as: 'category', attributes: ['id', 'name', 'code', 'color'] },
          { model: SLAPolicy, as: 'slaPolicy' }
        ]
      });

      res.status(201).json({
        success: true,
        message: 'File created successfully',
        data: completeFile
      });
    } catch (error) {
      console.error('Create file error:', error);
      res.status(500).json({
        success: false,
        message: 'Internal server error'
      });
    }
  }

  /**
   * Get file details
   */
  static async getFile(req, res) {
    try {
      const { id } = req.params;

      const file = await File.findByPk(id, {
        include: [
          { model: User, as: 'creator', attributes: ['id', 'full_name', 'designation'] },
          { model: User, as: 'currentHolder', attributes: ['id', 'full_name', 'designation'] },
          { model: Office, as: 'owningOffice' },
          { model: Category, as: 'category' },
          { model: SLAPolicy, as: 'slaPolicy' },
          {
            model: FileEvent,
            as: 'events',
            include: [
              { model: User, as: 'fromUser', attributes: ['id', 'full_name', 'designation'] },
              { model: User, as: 'toUser', attributes: ['id', 'full_name', 'designation'] }
            ],
            order: [['seq_no', 'ASC']]
          },
          {
            model: Attachment,
            as: 'attachments',
            include: [
              { model: User, as: 'uploader', attributes: ['id', 'full_name'] }
            ]
          }
        ]
      });

      if (!file) {
        return res.status(404).json({
          success: false,
          message: 'File not found'
        });
      }

      // Check permissions for confidential files
      if (file.confidentiality && !['cof', 'admin'].includes(req.user.role)) {
        return res.status(403).json({
          success: false,
          message: 'Access denied to confidential file'
        });
      }

      res.json({
        success: true,
        data: file
      });
    } catch (error) {
      console.error('Get file error:', error);
      res.status(500).json({
        success: false,
        message: 'Internal server error'
      });
    }
  }

  /**
   * Search/List files with filters
   */
  static async searchFiles(req, res) {
    try {
      const {
        page = 1,
        limit = 20,
        search,
        status,
        priority,
        category_id,
        owning_office_id,
        current_holder_user_id,
        date_from,
        date_to,
        sla_status,
        confidential
      } = req.query;

      const offset = (parseInt(page) - 1) * parseInt(limit);
      
      // Build where conditions
      const whereConditions = {};
      
      if (search) {
        whereConditions[Op.or] = [
          { file_no: { [Op.like]: `%${search}%` } },
          { subject: { [Op.like]: `%${search}%` } },
          { notesheet_title: { [Op.like]: `%${search}%` } }
        ];
      }

      if (status) whereConditions.status = status;
      if (priority) whereConditions.priority = priority;
      if (category_id) whereConditions.category_id = category_id;
      if (owning_office_id) whereConditions.owning_office_id = owning_office_id;
      if (current_holder_user_id) whereConditions.current_holder_user_id = current_holder_user_id;
      if (sla_status) whereConditions.sla_status = sla_status;
      if (confidential !== undefined) whereConditions.confidentiality = confidential === 'true';

      if (date_from || date_to) {
        whereConditions.created_at = {};
        if (date_from) whereConditions.created_at[Op.gte] = new Date(date_from);
        if (date_to) whereConditions.created_at[Op.lte] = new Date(date_to);
      }

      // Role-based filtering
      if (req.user.role === 'accounts_officer') {
        whereConditions.current_holder_user_id = req.user.id;
      }

      const { count, rows: files } = await File.findAndCountAll({
        where: whereConditions,
        include: [
          { model: User, as: 'creator', attributes: ['id', 'full_name', 'designation'] },
          { model: User, as: 'currentHolder', attributes: ['id', 'full_name', 'designation'] },
          { model: Office, as: 'owningOffice', attributes: ['id', 'name', 'code'] },
          { model: Category, as: 'category', attributes: ['id', 'name', 'code', 'color'] }
        ],
        order: [['created_at', 'DESC']],
        limit: parseInt(limit),
        offset
      });

      res.json({
        success: true,
        data: {
          files,
          pagination: {
            current_page: parseInt(page),
            per_page: parseInt(limit),
            total: count,
            total_pages: Math.ceil(count / parseInt(limit))
          }
        }
      });
    } catch (error) {
      console.error('Search files error:', error);
      res.status(500).json({
        success: false,
        message: 'Internal server error'
      });
    }
  }

  /**
   * Move file (Forward/Return/Hold etc.)
   */
  static async moveFile(req, res) {
    try {
      const errors = validationResult(req);
      if (!errors.isEmpty()) {
        return res.status(400).json({
          success: false,
          message: 'Validation failed',
          errors: errors.array()
        });
      }

      const { id } = req.params;
      const { 
        to_user_id, 
        action_type, 
        remarks, 
        pause_reason 
      } = req.body;

      const file = await File.findByPk(id);
      if (!file) {
        return res.status(404).json({
          success: false,
          message: 'File not found'
        });
      }

      // Check if user is current holder or has permission
      if (file.current_holder_user_id !== req.user.id && !['cof', 'admin'].includes(req.user.role)) {
        return res.status(403).json({
          success: false,
          message: 'You are not authorized to move this file'
        });
      }

      // Get the last event to calculate holding time
      const lastEvent = await FileEvent.findOne({
        where: { file_id: id },
        order: [['seq_no', 'DESC']]
      });

      let business_minutes_held = 0;
      if (lastEvent && !lastEvent.ended_at) {
        const businessTimeCalc = new BusinessTimeCalculator();
        business_minutes_held = await businessTimeCalc.calculateBusinessMinutes(
          lastEvent.started_at,
          new Date()
        );
        
        // Update the last event with end time and holding duration
        lastEvent.ended_at = new Date();
        lastEvent.business_minutes_held = business_minutes_held;
        await lastEvent.save();
        
        // Update file's total business time
        file.total_business_minutes += business_minutes_held;
      }

      // Create new file event
      const nextSeqNo = lastEvent ? lastEvent.seq_no + 1 : 1;
      await FileEvent.create({
        file_id: id,
        seq_no: nextSeqNo,
        from_user_id: req.user.id,
        to_user_id,
        action_type,
        started_at: new Date(),
        remarks,
        is_sla_paused: action_type === 'hold' || action_type === 'seek_info',
        pause_reason: action_type === 'hold' ? pause_reason : null
      });

      // Update file status and current holder
      let newStatus = file.status;
      if (action_type === 'forward') {
        newStatus = 'with_officer';
      } else if (action_type === 'escalate') {
        newStatus = 'with_cof';
      } else if (action_type === 'hold') {
        newStatus = 'on_hold';
      } else if (action_type === 'seek_info') {
        newStatus = 'waiting_on_origin';
      } else if (action_type === 'dispatch') {
        newStatus = 'dispatched';
      }

      file.current_holder_user_id = to_user_id;
      file.status = newStatus;
      await file.save();

      res.json({
        success: true,
        message: 'File moved successfully',
        data: {
          file_id: id,
          action_type,
          business_minutes_held
        }
      });
    } catch (error) {
      console.error('Move file error:', error);
      res.status(500).json({
        success: false,
        message: 'Internal server error'
      });
    }
  }

  /**
   * Get next file number preview
   */
  static async getNextFileNumber(req, res) {
    try {
      const nextFileNumber = await FileNumberGenerator.getNextFileNumber();
      
      res.json({
        success: true,
        data: { file_no: nextFileNumber }
      });
    } catch (error) {
      console.error('Get next file number error:', error);
      res.status(500).json({
        success: false,
        message: 'Internal server error'
      });
    }
  }
}

module.exports = FileController;