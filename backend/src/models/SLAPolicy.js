const { DataTypes } = require('sequelize');
const { sequelize } = require('../config/database');

const SLAPolicy = sequelize.define('SLAPolicy', {
  id: {
    type: DataTypes.INTEGER,
    primaryKey: true,
    autoIncrement: true
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
    allowNull: false
  },
  sla_hours: {
    type: DataTypes.INTEGER,
    allowNull: false
  },
  warning_threshold_percentage: {
    type: DataTypes.INTEGER,
    defaultValue: 70,
    validate: {
      min: 1,
      max: 100
    }
  },
  is_active: {
    type: DataTypes.BOOLEAN,
    defaultValue: true
  }
}, {
  tableName: 'sla_policies',
  indexes: [
    { 
      unique: true, 
      fields: ['category_id', 'priority'],
      name: 'sla_policies_category_priority_unique'
    }
  ]
});

module.exports = SLAPolicy;