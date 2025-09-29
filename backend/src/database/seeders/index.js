const bcrypt = require('bcryptjs');
const { sequelize } = require('../../config/database');
const {
  User, Office, Category, SLAPolicy, Holiday
} = require('../../models');

// Fixed paths to work from database/seeders directory

async function seedDatabase() {
  try {
    console.log('🌱 Starting database seeding...');

    // Clear existing data in development
    if (process.env.NODE_ENV === 'development') {
      await sequelize.sync({ force: true });
      console.log('✅ Database tables recreated');
    }

    // Seed Offices
    const offices = await Office.bulkCreate([
      { name: 'Finance Department', code: 'FIN', description: 'Financial operations and budgeting' },
      { name: 'Procurement Department', code: 'PROC', description: 'Purchase and procurement activities' },
      { name: 'Human Resources', code: 'HR', description: 'Personnel and administrative matters' },
      { name: 'Administration', code: 'ADMIN', description: 'General administration' },
      { name: 'Audit Department', code: 'AUDIT', description: 'Internal audit and compliance' }
    ]);
    console.log('✅ Offices seeded');

    // Seed Categories
    const categories = await Category.bulkCreate([
      { name: 'Budget', code: 'BUD', description: 'Budget related files', default_sla_hours: 48, color: '#10B981' },
      { name: 'Audit', code: 'AUD', description: 'Audit related files', default_sla_hours: 72, color: '#F59E0B' },
      { name: 'Salary', code: 'SAL', description: 'Salary and compensation files', default_sla_hours: 24, color: '#3B82F6' },
      { name: 'Procurement', code: 'PROC', description: 'Procurement and purchase files', default_sla_hours: 96, color: '#8B5CF6' },
      { name: 'Miscellaneous', code: 'MISC', description: 'Other administrative files', default_sla_hours: 72, color: '#6B7280' }
    ]);
    console.log('✅ Categories seeded');

    // Seed SLA Policies
    const slaPolicies = [];
    for (const category of categories) {
      slaPolicies.push(
        { category_id: category.id, priority: 'routine', sla_hours: category.default_sla_hours },
        { category_id: category.id, priority: 'urgent', sla_hours: Math.floor(category.default_sla_hours * 0.5) },
        { category_id: category.id, priority: 'critical', sla_hours: Math.floor(category.default_sla_hours * 0.25) }
      );
    }
    await SLAPolicy.bulkCreate(slaPolicies);
    console.log('✅ SLA Policies seeded');

    // Seed Users
    const saltRounds = 12;
    const users = await User.bulkCreate([
      {
        username: 'admin',
        email: 'admin@accounts.gov.in',
        password: await bcrypt.hash('admin123', saltRounds),
        full_name: 'System Administrator',
        employee_id: 'ADM001',
        designation: 'System Administrator',
        department: 'IT Department',
        role: 'admin'
      },
      {
        username: 'cof.accounts',
        email: 'cof@accounts.gov.in',
        password: await bcrypt.hash('cof123', saltRounds),
        full_name: 'Chief Officer Finance',
        employee_id: 'COF001',
        designation: 'Chief Officer Finance',
        department: 'Accounts Department',
        role: 'cof'
      },
      {
        username: 'clerk.intake',
        email: 'clerk@accounts.gov.in',
        password: await bcrypt.hash('clerk123', saltRounds),
        full_name: 'Rajesh Kumar',
        employee_id: 'CLK001',
        designation: 'Senior Clerk',
        department: 'Accounts Department',
        role: 'clerk'
      },
      {
        username: 'ao.ramesh',
        email: 'ramesh.ao@accounts.gov.in',
        password: await bcrypt.hash('ao123', saltRounds),
        full_name: 'Ramesh Sharma',
        employee_id: 'AO001',
        designation: 'Accounts Officer',
        department: 'Accounts Department',
        role: 'accounts_officer'
      },
      {
        username: 'ao.priya',
        email: 'priya.ao@accounts.gov.in',
        password: await bcrypt.hash('ao123', saltRounds),
        full_name: 'Priya Verma',
        employee_id: 'AO002',
        designation: 'Accounts Officer',
        department: 'Accounts Department',
        role: 'accounts_officer'
      },
      {
        username: 'ao.suresh',
        email: 'suresh.ao@accounts.gov.in',
        password: await bcrypt.hash('ao123', saltRounds),
        full_name: 'Suresh Patel',
        employee_id: 'AO003',
        designation: 'Senior Accounts Officer',
        department: 'Accounts Department',
        role: 'accounts_officer'
      }
    ]);
    console.log('✅ Users seeded');

    // Update office heads
    await offices[0].update({ head_user_id: users.find(u => u.role === 'cof').id }); // Finance
    console.log('✅ Office heads updated');

    // Seed common holidays for current year
    const currentYear = new Date().getFullYear();
    const holidays = [
      { date: `${currentYear}-01-01`, name: 'New Year Day', type: 'national' },
      { date: `${currentYear}-01-26`, name: 'Republic Day', type: 'national' },
      { date: `${currentYear}-08-15`, name: 'Independence Day', type: 'national' },
      { date: `${currentYear}-10-02`, name: 'Gandhi Jayanti', type: 'national' },
      { date: `${currentYear}-12-25`, name: 'Christmas Day', type: 'national' }
    ];
    await Holiday.bulkCreate(holidays);
    console.log('✅ Holidays seeded');

    console.log('🎉 Database seeding completed successfully!');
    console.log('\n📋 Default Login Credentials:');
    console.log('Admin: admin / admin123');
    console.log('COF: cof.accounts / cof123');
    console.log('Clerk: clerk.intake / clerk123');
    console.log('AO1: ao.ramesh / ao123');
    console.log('AO2: ao.priya / ao123');
    console.log('AO3: ao.suresh / ao123');

  } catch (error) {
    console.error('❌ Database seeding failed:', error);
    throw error;
  }
}

module.exports = seedDatabase;

// Run seeder if called directly
if (require.main === module) {
  seedDatabase()
    .then(() => process.exit(0))
    .catch(() => process.exit(1));
}