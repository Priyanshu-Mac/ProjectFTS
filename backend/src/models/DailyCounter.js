const { DataTypes } = require('sequelize');
const { sequelize } = require('../config/database');

const DailyCounter = sequelize.define('DailyCounter', {
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
  counter: {
    type: DataTypes.INTEGER,
    allowNull: false,
    defaultValue: 0
  }
}, {
  tableName: 'daily_counters',
  indexes: [
    { fields: ['date'] }
  ]
});

module.exports = DailyCounter;