const User = require('./User');
const Office = require('./Office');
const Category = require('./Category');
const SLAPolicy = require('./SLAPolicy');
const File = require('./File');
const FileEvent = require('./FileEvent');
const Holiday = require('./Holiday');
const Attachment = require('./Attachment');
const AuditLog = require('./AuditLog');
const DailyCounter = require('./DailyCounter');

// User associations
User.hasMany(File, { foreignKey: 'created_by', as: 'createdFiles' });
User.hasMany(File, { foreignKey: 'current_holder_user_id', as: 'currentFiles' });
User.hasMany(FileEvent, { foreignKey: 'from_user_id', as: 'sentEvents' });
User.hasMany(FileEvent, { foreignKey: 'to_user_id', as: 'receivedEvents' });
User.hasMany(Attachment, { foreignKey: 'uploaded_by', as: 'uploadedAttachments' });
User.hasMany(AuditLog, { foreignKey: 'user_id', as: 'auditLogs' });

// Office associations
Office.belongsTo(User, { foreignKey: 'head_user_id', as: 'head' });
Office.hasMany(File, { foreignKey: 'owning_office_id', as: 'files' });

// Category associations
Category.hasMany(File, { foreignKey: 'category_id', as: 'files' });
Category.hasMany(SLAPolicy, { foreignKey: 'category_id', as: 'slaPolicies' });

// SLA Policy associations
SLAPolicy.belongsTo(Category, { foreignKey: 'category_id', as: 'category' });
SLAPolicy.hasMany(File, { foreignKey: 'sla_policy_id', as: 'files' });

// File associations
File.belongsTo(User, { foreignKey: 'created_by', as: 'creator' });
File.belongsTo(User, { foreignKey: 'current_holder_user_id', as: 'currentHolder' });
File.belongsTo(Office, { foreignKey: 'owning_office_id', as: 'owningOffice' });
File.belongsTo(Category, { foreignKey: 'category_id', as: 'category' });
File.belongsTo(SLAPolicy, { foreignKey: 'sla_policy_id', as: 'slaPolicy' });
File.hasMany(FileEvent, { foreignKey: 'file_id', as: 'events' });
File.hasMany(Attachment, { foreignKey: 'file_id', as: 'attachments' });

// File Event associations
FileEvent.belongsTo(File, { foreignKey: 'file_id', as: 'file' });
FileEvent.belongsTo(User, { foreignKey: 'from_user_id', as: 'fromUser' });
FileEvent.belongsTo(User, { foreignKey: 'to_user_id', as: 'toUser' });

// Attachment associations
Attachment.belongsTo(File, { foreignKey: 'file_id', as: 'file' });
Attachment.belongsTo(User, { foreignKey: 'uploaded_by', as: 'uploader' });

// Audit Log associations
AuditLog.belongsTo(User, { foreignKey: 'user_id', as: 'user' });

module.exports = {
  User,
  Office,
  Category,
  SLAPolicy,
  File,
  FileEvent,
  Holiday,
  Attachment,
  AuditLog,
  DailyCounter
};