const { DataTypes } = require('sequelize');
const { sequelize } = require('../config/database');

const Category = sequelize.define('Category', {
  id: {
    type: DataTypes.INTEGER,
    primaryKey: true,
    autoIncrement: true
  },
  name: {
    type: DataTypes.STRING(100),
    allowNull: false,
    unique: true
  },
  code: {
    type: DataTypes.STRING(10),
    allowNull: false,
    unique: true
  },
  description: {
    type: DataTypes.TEXT
  },
  default_sla_hours: {
    type: DataTypes.INTEGER,
    allowNull: false,
    defaultValue: 72 // 3 days default
  },
  color: {
    type: DataTypes.STRING(7), // hex color code
    defaultValue: '#3B82F6'
  },
  is_active: {
    type: DataTypes.BOOLEAN,
    defaultValue: true
  }
}, {
  tableName: 'categories',
  indexes: [
    { fields: ['code'] },
    { fields: ['name'] }
  ]
});

module.exports = Category;