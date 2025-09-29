const { DataTypes } = require('sequelize');
const { sequelize } = require('../config/database');

const Attachment = sequelize.define('Attachment', {
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
  original_name: {
    type: DataTypes.STRING(255),
    allowNull: false
  },
  file_name: {
    type: DataTypes.STRING(255),
    allowNull: false
  },
  file_path: {
    type: DataTypes.STRING(500),
    allowNull: false
  },
  file_size: {
    type: DataTypes.INTEGER,
    allowNull: false
  },
  mime_type: {
    type: DataTypes.STRING(100),
    allowNull: false
  },
  uploaded_by: {
    type: DataTypes.INTEGER,
    allowNull: false,
    references: {
      model: 'users',
      key: 'id'
    }
  },
  upload_stage: {
    type: DataTypes.ENUM('intake', 'movement', 'dispatch'),
    defaultValue: 'intake'
  }
}, {
  tableName: 'attachments',
  indexes: [
    { fields: ['file_id'] },
    { fields: ['uploaded_by'] }
  ]
});

module.exports = Attachment;