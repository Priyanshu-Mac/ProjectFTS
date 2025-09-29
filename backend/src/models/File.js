const { DataTypes } = require('sequelize');
const { sequelize } = require('../config/database');

const File = sequelize.define('File', {
  id: {
    type: DataTypes.INTEGER,
    primaryKey: true,
    autoIncrement: true
  },
  file_no: {
    type: DataTypes.STRING(20),
    allowNull: false,
    unique: true
  },
  subject: {
    type: DataTypes.TEXT,
    allowNull: false
  },
  notesheet_title: {
    type: DataTypes.TEXT,
    allowNull: false
  },
  owning_office_id: {
    type: DataTypes.INTEGER,
    allowNull: false,
    references: {
      model: 'offices',
      key: 'id'
    }
  },
  category_id: {
    type: DataTypes.INTEGER,
    allowNull: false,
    references: {
      model: 'categories',
      key: 'id'
    }
  },
  priority: {
    type: DataTypes.ENUM('routine', 'urgent', 'critical'),
    allowNull: false,
    defaultValue: 'routine'
  },
  date_initiated: {
    type: DataTypes.DATE,
    allowNull: false
  },
  date_received_accounts: {
    type: DataTypes.DATE,
    allowNull: false,
    defaultValue: DataTypes.NOW
  },
  current_holder_user_id: {
    type: DataTypes.INTEGER,
    references: {
      model: 'users',
      key: 'id'
    }
  },
  status: {
    type: DataTypes.ENUM(
      'open', 'with_officer', 'with_cof', 'dispatched', 
      'on_hold', 'waiting_on_origin', 'closed'
    ),
    allowNull: false,
    defaultValue: 'open'
  },
  confidentiality: {
    type: DataTypes.BOOLEAN,
    defaultValue: false
  },
  sla_policy_id: {
    type: DataTypes.INTEGER,
    references: {
      model: 'sla_policies',
      key: 'id'
    }
  },
  sla_due_date: {
    type: DataTypes.DATE
  },
  sla_status: {
    type: DataTypes.ENUM('on_track', 'warning', 'breach'),
    defaultValue: 'on_track'
  },
  total_business_minutes: {
    type: DataTypes.INTEGER,
    defaultValue: 0
  },
  dispatch_authority: {
    type: DataTypes.STRING(200)
  },
  dispatch_date: {
    type: DataTypes.DATE
  },
  covering_letter_no: {
    type: DataTypes.STRING(50)
  },
  remarks: {
    type: DataTypes.TEXT
  },
  created_by: {
    type: DataTypes.INTEGER,
    allowNull: false,
    references: {
      model: 'users',
      key: 'id'
    }
  }
}, {
  tableName: 'files',
  indexes: [
    { fields: ['file_no'] },
    { fields: ['status', 'current_holder_user_id'] },
    { fields: ['owning_office_id', 'category_id', 'priority'] },
    { fields: ['sla_due_date'] },
    { fields: ['created_at'] }
  ]
});

module.exports = File;