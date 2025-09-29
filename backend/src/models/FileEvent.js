const { DataTypes } = require('sequelize');
const { sequelize } = require('../config/database');

const FileEvent = sequelize.define('FileEvent', {
  id: {
    type: DataTypes.INTEGER,
    primaryKey: true,
    autoIncrement: true
  },
  file_id: {
    type: DataTypes.INTEGER,
    allowNull: false,
    references: {
      model: 'files',
      key: 'id'
    }
  },
  seq_no: {
    type: DataTypes.INTEGER,
    allowNull: false
  },
  from_user_id: {
    type: DataTypes.INTEGER,
    references: {
      model: 'users',
      key: 'id'
    }
  },
  to_user_id: {
    type: DataTypes.INTEGER,
    allowNull: false,
    references: {
      model: 'users',
      key: 'id'
    }
  },
  action_type: {
    type: DataTypes.ENUM(
      'forward', 'return', 'seek_info', 'hold', 
      'escalate', 'close', 'dispatch', 'reopen', 'receive'
    ),
    allowNull: false
  },
  started_at: {
    type: DataTypes.DATE,
    allowNull: false,
    defaultValue: DataTypes.NOW
  },
  ended_at: {
    type: DataTypes.DATE
  },
  business_minutes_held: {
    type: DataTypes.INTEGER,
    defaultValue: 0
  },
  remarks: {
    type: DataTypes.TEXT
  },
  attachments_json: {
    type: DataTypes.JSON
  },
  is_sla_paused: {
    type: DataTypes.BOOLEAN,
    defaultValue: false
  },
  pause_reason: {
    type: DataTypes.TEXT
  }
}, {
  tableName: 'file_events',
  indexes: [
    { fields: ['file_id', 'seq_no'] },
    { fields: ['from_user_id'] },
    { fields: ['to_user_id'] },
    { fields: ['action_type'] },
    { fields: ['started_at'] }
  ]
});

module.exports = FileEvent;