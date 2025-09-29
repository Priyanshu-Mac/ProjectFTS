const { DataTypes } = require('sequelize');
const { sequelize } = require('../config/database');

const AuditLog = sequelize.define('AuditLog', {
  id: {
    type: DataTypes.INTEGER,
    primaryKey: true,
    autoIncrement: true
  },
  user_id: {
    type: DataTypes.INTEGER,
    allowNull: false,
    references: {
      model: 'users',
      key: 'id'
    }
  },
  action: {
    type: DataTypes.ENUM('create', 'read', 'update', 'delete'),
    allowNull: false
  },
  resource_type: {
    type: DataTypes.STRING(50),
    allowNull: false
  },
  resource_id: {
    type: DataTypes.INTEGER
  },
  details: {
    type: DataTypes.JSON
  },
  ip_address: {
    type: DataTypes.STRING(45)
  },
  user_agent: {
    type: DataTypes.TEXT
  }
}, {
  tableName: 'audit_logs',
  indexes: [
    { fields: ['user_id'] },
    { fields: ['action'] },
    { fields: ['resource_type', 'resource_id'] },
    { fields: ['created_at'] }
  ]
});

module.exports = AuditLog;