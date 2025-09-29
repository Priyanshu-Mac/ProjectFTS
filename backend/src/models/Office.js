const { DataTypes } = require('sequelize');
const { sequelize } = require('../config/database');

const Office = sequelize.define('Office', {
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
  head_user_id: {
    type: DataTypes.INTEGER,
    references: {
      model: 'users',
      key: 'id'
    }
  },
  is_active: {
    type: DataTypes.BOOLEAN,
    defaultValue: true
  }
}, {
  tableName: 'offices',
  indexes: [
    { fields: ['code'] },
    { fields: ['name'] }
  ]
});

module.exports = Office;