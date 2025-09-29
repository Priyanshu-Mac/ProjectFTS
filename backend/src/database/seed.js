const bcrypt = require('bcrypt');
const { User, Office, Category, SLAPolicy } = require('../models');

async function seedDatabase() {
  try {
    console.log('🌱 Starting database seeding...');

    // Create sample offices
    const offices = await Office.bulkCreate([
      {
        name: 'Accounts Office',
        code: 'ACC',
        description: 'Main Accounts Office',
        is_active: true
      },
      {
        name: 'Administrative Office',
        code: 'ADM',
        description: 'Administrative Department',
        is_active: true
      },
      {
        name: 'COF Office',
        code: 'COF',
        description: 'Chief Operating Officer Office',
        is_active: true
      }
    ]);

    // Create sample categories
    const categories = await Category.bulkCreate([
      {
        name: 'Budget & Finance',
        code: 'BF',
        description: 'Budget and financial matters',
        default_sla_hours: 72,
        color: '#10B981'
      },
      {
        name: 'Personnel',
        code: 'PER',
        description: 'Personnel and HR related files',
        default_sla_hours: 48,
        color: '#3B82F6'
      },
      {
        name: 'Administrative',
        code: 'ADM',
        description: 'General administrative matters',
        default_sla_hours: 96,
        color: '#8B5CF6'
      },
      {
        name: 'Procurement',
        code: 'PRO',
        description: 'Procurement and purchase matters',
        default_sla_hours: 120,
        color: '#F59E0B'
      }
    ]);

    // Create SLA policies
    await SLAPolicy.bulkCreate([
      // Budget & Finance SLA policies
      { category_id: categories[0].id, priority: 'urgent', sla_hours: 24, warning_threshold_percentage: 80 },
      { category_id: categories[0].id, priority: 'high', sla_hours: 48, warning_threshold_percentage: 75 },
      { category_id: categories[0].id, priority: 'routine', sla_hours: 72, warning_threshold_percentage: 70 },
      
      // Personnel SLA policies
      { category_id: categories[1].id, priority: 'urgent', sla_hours: 12, warning_threshold_percentage: 80 },
      { category_id: categories[1].id, priority: 'high', sla_hours: 24, warning_threshold_percentage: 75 },
      { category_id: categories[1].id, priority: 'routine', sla_hours: 48, warning_threshold_percentage: 70 },
      
      // Administrative SLA policies
      { category_id: categories[2].id, priority: 'urgent', sla_hours: 48, warning_threshold_percentage: 80 },
      { category_id: categories[2].id, priority: 'high', sla_hours: 72, warning_threshold_percentage: 75 },
      { category_id: categories[2].id, priority: 'routine', sla_hours: 96, warning_threshold_percentage: 70 },
      
      // Procurement SLA policies
      { category_id: categories[3].id, priority: 'urgent', sla_hours: 72, warning_threshold_percentage: 80 },
      { category_id: categories[3].id, priority: 'high', sla_hours: 96, warning_threshold_percentage: 75 },
      { category_id: categories[3].id, priority: 'routine', sla_hours: 120, warning_threshold_percentage: 70 }
    ]);

    // Create sample users with hashed passwords
    const saltRounds = 10;
    const users = await User.bulkCreate([
      {
        username: 'admin',
        email: 'admin@gov.in',
        password: await bcrypt.hash('admin123', saltRounds),
        full_name: 'System Administrator',
        employee_id: 'EMP001',
        designation: 'System Administrator',
        department: 'IT Department',
        role: 'admin',
        is_active: true
      },
      {
        username: 'cof',
        email: 'cof@gov.in',
        password: await bcrypt.hash('cof123', saltRounds),
        full_name: 'Chief Operating Officer',
        employee_id: 'EMP002',
        designation: 'Chief Operating Officer',
        department: 'Administration',
        role: 'cof',
        is_active: true
      },
      {
        username: 'clerk1',
        email: 'clerk1@gov.in',
        password: await bcrypt.hash('clerk123', saltRounds),
        full_name: 'Ramesh Kumar',
        employee_id: 'EMP003',
        designation: 'Senior Clerk',
        department: 'Accounts',
        role: 'clerk',
        is_active: true
      },
      {
        username: 'officer1',
        email: 'officer1@gov.in',
        password: await bcrypt.hash('officer123', saltRounds),
        full_name: 'Priya Sharma',
        employee_id: 'EMP004',
        designation: 'Accounts Officer',
        department: 'Accounts',
        role: 'accounts_officer',
        is_active: true
      },
      {
        username: 'officer2',
        email: 'officer2@gov.in',
        password: await bcrypt.hash('officer123', saltRounds),
        full_name: 'Suresh Gupta',
        employee_id: 'EMP005',
        designation: 'Assistant Accounts Officer',
        department: 'Accounts',
        role: 'accounts_officer',
        is_active: true
      }
    ]);

    // Update office heads
    await Office.update(
      { head_user_id: users[1].id }, // COF as head of COF office
      { where: { code: 'COF' } }
    );

    await Office.update(
      { head_user_id: users[3].id }, // Officer1 as head of Accounts office
      { where: { code: 'ACC' } }
    );

    console.log('✅ Database seeded successfully!');
    console.log('📧 Login credentials:');
    console.log('   Admin: admin / admin123');
    console.log('   COF: cof / cof123');
    console.log('   Clerk: clerk1 / clerk123');
    console.log('   Officer: officer1 / officer123');
    
    return {
      users: users.length,
      offices: offices.length,
      categories: categories.length,
      message: 'Database seeded successfully'
    };

  } catch (error) {
    console.error('❌ Error seeding database:', error);
    throw error;
  }
}

module.exports = seedDatabase;