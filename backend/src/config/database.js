const { Sequelize } = require('sequelize');
const path = require('path');

// Use SQLite for development if MySQL is not available
const isDevelopment = process.env.NODE_ENV === 'development';
const useSQLite = isDevelopment && !process.env.DB_PASSWORD;

let sequelize;

if (useSQLite) {
  // SQLite configuration for development
  sequelize = new Sequelize({
    dialect: 'sqlite',
    storage: path.join(__dirname, '../../database.sqlite'),
    logging: console.log,
    define: {
      timestamps: true,
      underscored: true,
      freezeTableName: true
    }
  });
  console.log('🗃️  Using SQLite database for development');
} else {
  // MySQL configuration for production
  sequelize = new Sequelize(
    process.env.DB_NAME || 'gov_file_management',
    process.env.DB_USER || 'root',
    process.env.DB_PASSWORD || '',
    {
      host: process.env.DB_HOST || 'localhost',
      port: process.env.DB_PORT || 3306,
      dialect: 'mysql',
      logging: process.env.NODE_ENV === 'development' ? console.log : false,
      pool: {
        max: 5,
        min: 0,
        acquire: 30000,
        idle: 10000
      },
      define: {
        timestamps: true,
        underscored: true,
        freezeTableName: true
      }
    }
  );
  console.log('🗃️  Using MySQL database');
}

module.exports = {
  sequelize,
  Sequelize
};