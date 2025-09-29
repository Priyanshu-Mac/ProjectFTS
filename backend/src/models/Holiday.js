const { DataTypes } = require('sequelize');
const { sequelize } = require('../config/database');

const Holiday = sequelize.define('Holiday', {
  id: {
    type: DataTypes.INTEGER,
    primaryKey: true,
    autoIncrement: true
  },
  date: {
    type: DataTypes.DATEONLY,
    allowNull: false,
    unique: true
  },
  name: {
    type: DataTypes.STRING(100),
    allowNull: false
  },
  type: {
    type: DataTypes.ENUM('national', 'gazetted', 'restricted'),
    defaultValue: 'gazetted'
  },
  is_optional: {
    type: DataTypes.BOOLEAN,
    defaultValue: false
  }
}, {
  tableName: 'holidays',
  indexes: [
    { fields: ['date'] },
    { fields: ['type'] }
  ]
});

module.exports = Holiday;