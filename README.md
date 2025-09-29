# Government File Management System

A comprehensive file management and tracking system designed for government accounting departments. This system streamlines the entire file lifecycle from intake to dispatch with complete audit trails and business intelligence.

## 🏛️ System Overview

This system handles the complete workflow of government file processing:

1. **File Receiving (Intake)** - Create records with auto-generated file numbers
2. **File Movement** - Track file movement between officers with business time calculations  
3. **COF Review** - Chief Officer Finance final review and dispatch
4. **Dashboards** - Executive and operational dashboards with KPIs
5. **Audit & Compliance** - Complete audit trails and SLA monitoring

## 🚀 Features

### Core Functionality
- ✅ **Auto File Numbering**: ACC-YYYYMMDD-XX format with collision protection
- ✅ **Business Time Tracking**: Excludes weekends and holidays
- ✅ **SLA Management**: Automatic breach detection and notifications
- ✅ **Role-Based Access**: Clerk, Accounts Officer, COF, and Admin roles
- ✅ **Immutable Audit Trail**: Complete event sourcing for compliance
- ✅ **Confidential File Handling**: Restricted access controls

### Advanced Features
- 📊 **Executive Dashboards**: KPIs, aging analysis, bottleneck identification
- 🔄 **File Movement Tracking**: Real-time status with business time calculations
- 📈 **Analytics & Reports**: Performance metrics and efficiency analysis
- 🏷️ **QR Code Generation**: Physical file tracking integration
- 🔔 **SLA Notifications**: Automated breach warnings and escalations
- 📋 **Comprehensive Reporting**: Export capabilities for all data

## 🏗️ Architecture

### Backend (Express.js + MySQL)
- **Framework**: Express.js with Sequelize ORM
- **Database**: MySQL with proper indexing and relationships
- **Authentication**: JWT-based with role permissions
- **Security**: Helmet, CORS, rate limiting, input validation
- **Business Logic**: Custom time calculators and SLA processors

### Frontend (React + Vite) 
*Note: You mentioned you'll create the React app separately*

## 📁 Project Structure

```
dtu/
├── backend/                 # Express.js backend
│   ├── src/
│   │   ├── config/         # Database and app configuration
│   │   ├── controllers/    # Business logic controllers
│   │   ├── middleware/     # Authentication, audit, error handling
│   │   ├── models/         # Sequelize database models
│   │   ├── routes/         # API route definitions
│   │   ├── services/       # Business services
│   │   ├── utils/          # Utility functions
│   │   └── database/       # Seeders and migrations
│   ├── uploads/            # File attachments storage
│   └── README.md           # Backend documentation
├── frontend/               # React frontend (to be created)
└── README.md               # This file
```

## 🚀 Quick Start

### Prerequisites
- Node.js (v16+)
- MySQL (v8.0+)
- Git

### Backend Setup

1. **Navigate to backend directory**
   ```bash
   cd backend
   ```

2. **Install dependencies**
   ```bash
   npm install
   ```

3. **Configure environment**
   ```bash
   cp .env.example .env
   # Edit .env with your database credentials
   ```

4. **Setup database**
   ```bash
   # Create database
   mysql -u root -p -e "CREATE DATABASE gov_file_management;"
   
   # Seed with sample data
   npm run seed
   ```

5. **Start development server**
   ```bash
   npm run dev
   ```
   Server runs on http://localhost:5000

### Frontend Setup
*You mentioned you'll create the React app, so this section is for your reference*

Recommended setup:
```bash
cd frontend
npm create vite@latest . -- --template react
npm install
# Add additional dependencies as needed
npm run dev
```

## 🔐 Default Login Credentials

After running the seeder:

| Role | Username | Password | Description |
|------|----------|----------|-------------|
| **Admin** | `admin` | `admin123` | System Administrator |
| **COF** | `cof.accounts` | `cof123` | Chief Officer Finance |
| **Clerk** | `clerk.intake` | `clerk123` | File Intake Clerk |
| **AO** | `ao.ramesh` | `ao123` | Accounts Officer |
| **AO** | `ao.priya` | `ao123` | Accounts Officer |
| **AO** | `ao.suresh` | `ao123` | Senior Accounts Officer |

## 📊 Core Workflows

### 1. File Intake Process
- Auto-generate file number (ACC-YYYYMMDD-XX)
- Capture subject, notesheet title, owning office
- Set priority and confidentiality level
- Assign to first Accounts Officer
- Start SLA timer

### 2. File Movement Process
- Forward between officers with business time tracking
- Support actions: Forward, Return, Hold, Seek Info, Escalate
- Automatic SLA monitoring and breach detection
- Immutable event logging

### 3. COF Dispatch Process
- Complete file journey review
- Generate covering letters
- Dispatch to external authorities
- Close internal processing loop

## 🎛️ Dashboard Features

### Executive Dashboard (COF)
- Files in accounts today vs total
- Weekly on-time percentage
- Average TAT in business days
- Longest delays and imminent breaches
- Officer efficiency metrics
- Pendency by owning office

### Officer Dashboard
- Personal queue (Assigned, Due Soon, Overdue)
- Quick actions for file movement
- Performance metrics
- Workload distribution

## 🔧 API Endpoints

### Authentication
- `POST /api/auth/login` - User authentication
- `GET /api/auth/profile` - User profile data
- `POST /api/auth/change-password` - Password change

### File Management  
- `GET /api/files/next-number` - Preview next file number
- `POST /api/files` - Create new file (intake)
- `GET /api/files/search` - Search and filter files
- `GET /api/files/:id` - Get complete file details
- `POST /api/files/:id/move` - Move file between officers

### Dashboards
- `GET /api/dashboard/executive` - Executive KPIs
- `GET /api/dashboard/officer` - Officer workload
- `GET /api/dashboard/analytics` - Performance analytics

### Master Data
- `GET /api/master-data/offices` - All offices
- `GET /api/master-data/categories` - File categories
- `GET /api/master-data/users` - System users
- `GET /api/master-data/constants` - Application constants

## 🛡️ Security Features

- **JWT Authentication**: Secure token-based authentication
- **Role-Based Access Control**: Granular permissions by user role
- **Input Validation**: Comprehensive request validation
- **Rate Limiting**: API abuse prevention
- **Audit Logging**: Complete operation tracking
- **Confidential File Protection**: Restricted access controls

## 📈 Business Intelligence

### KPI Tracking
- File processing efficiency
- SLA compliance rates
- Officer performance metrics
- Bottleneck identification
- Workload distribution analysis

### Reporting Capabilities
- Movement registers
- Pendency reports by office/officer
- SLA breach analysis
- Processing time trends
- Rework pattern analysis

## 🔄 Development Workflow

### Running Tasks in VS Code
The project includes VS Code tasks for easy development:

1. **Start Backend Server**: Runs the Express.js development server
   - Press `Ctrl+Shift+P` → "Tasks: Run Task" → "Start Backend Server"
   - Or use the Command Palette

### Database Operations
```bash
# Reset and reseed database
npm run seed

# Check database connection
npm start
```

## 🚀 Production Deployment

### Environment Configuration
```env
NODE_ENV=production
JWT_SECRET=strong-production-secret
DB_HOST=production-database-host
DB_NAME=gov_file_management_prod
```

### Security Checklist
- [ ] Strong JWT secrets
- [ ] Database connection encryption  
- [ ] CORS configuration for production domains
- [ ] Rate limiting configuration
- [ ] Regular database backups
- [ ] SSL/TLS certificates
- [ ] Audit log monitoring

## 📋 Business Rules

### File Number Generation
- Daily sequential counter with date prefix
- Transaction-safe to prevent duplicates
- Format: ACC-YYYYMMDD-XX (e.g., ACC-20250929-01)

### Business Time Calculations
- Working hours: 9:00 AM - 5:30 PM
- Working days: Monday to Friday  
- Excludes configured government holidays
- SLA timers pause during "On Hold" status

### SLA Management
- Warning threshold: 70% of allocated time
- Automatic breach detection at 100%
- Different SLA policies by category and priority
- Real-time status updates

## 🎯 Next Steps (Frontend Integration)

When you create the React frontend, consider these integration points:

1. **Authentication Flow**: JWT token management and route protection
2. **Dashboard Components**: Charts and KPI widgets
3. **File Management UI**: Forms for intake, movement, and dispatch
4. **Real-time Updates**: WebSocket or polling for live status updates
5. **Government UI Theme**: Professional, accessible design following government guidelines

## 📞 Support

For technical support or feature requests:
- **Email**: admin@accounts.gov.in
- **System Administrator**: Use admin credentials for user management

## 📄 License

Government of India - Internal Use Only

---

**Built for**: Government Accounting Departments  
**Technology Stack**: Node.js, Express.js, MySQL, React (frontend)  
**Compliance**: Government IT standards and audit requirements