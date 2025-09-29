# Government File Management System - Backend

A comprehensive file management system for government accounting departments built with Express.js, MySQL, and JWT authentication.

## Features

### Core Functionality
- **File Receiving (Intake)**: Auto-generated file numbers, subject tracking, priority management
- **File Movement**: Immutable event tracking with business time calculations
- **COF Review & Dispatch**: Complete journey visualization and authority forwarding
- **Role-based Access Control**: Clerk, Accounts Officer, COF, and Admin roles

### Key Capabilities
- ✅ Auto file numbering (ACC-YYYYMMDD-XX format)
- ✅ Business time calculation (excludes weekends/holidays)
- ✅ SLA monitoring with breach notifications
- ✅ Comprehensive audit logging
- ✅ Executive and officer dashboards
- ✅ Real-time file movement tracking
- ✅ QR code generation for physical files
- ✅ Confidential file handling

## Technology Stack

- **Backend**: Node.js, Express.js
- **Database**: MySQL with Sequelize ORM
- **Authentication**: JWT (JSON Web Tokens)
- **Security**: Helmet, CORS, Rate Limiting
- **File Upload**: Multer
- **Validation**: Express Validator
- **Business Logic**: Custom business time calculator

## Installation

### Prerequisites
- Node.js (v16 or higher)
- MySQL (v8.0 or higher)
- npm or yarn

### Setup Steps

1. **Clone and Navigate**
   ```bash
   cd backend
   ```

2. **Install Dependencies**
   ```bash
   npm install
   ```

3. **Environment Configuration**
   ```bash
   cp .env.example .env
   ```
   
   Update `.env` with your configuration:
   ```env
   NODE_ENV=development
   PORT=5000
   
   # Database
   DB_HOST=localhost
   DB_PORT=3306
   DB_NAME=gov_file_management
   DB_USER=root
   DB_PASSWORD=your_password
   
   # JWT
   JWT_SECRET=your-super-secret-jwt-key
   JWT_EXPIRES_IN=24h
   ```

4. **Database Setup**
   ```bash
   # Create database
   mysql -u root -p -e "CREATE DATABASE gov_file_management;"
   
   # Run seeders (creates tables and sample data)
   npm run seed
   ```

5. **Start Development Server**
   ```bash
   npm run dev
   ```

## API Endpoints

### Authentication
- `POST /api/auth/login` - User login
- `GET /api/auth/profile` - Get user profile
- `POST /api/auth/change-password` - Change password
- `POST /api/auth/logout` - Logout

### File Management
- `GET /api/files/next-number` - Get next file number
- `POST /api/files` - Create new file (intake)
- `GET /api/files/search` - Search/list files
- `GET /api/files/:id` - Get file details
- `POST /api/files/:id/move` - Move file (forward/return/hold)

### Dashboards
- `GET /api/dashboard/executive` - Executive dashboard (COF)
- `GET /api/dashboard/officer` - Officer dashboard
- `GET /api/dashboard/analytics` - Analytics data

### Master Data
- `GET /api/master-data/offices` - Get all offices
- `GET /api/master-data/categories` - Get all categories
- `GET /api/master-data/users` - Get users (filterable by role)
- `GET /api/master-data/sla-policies` - Get SLA policies
- `GET /api/master-data/constants` - Get application constants

## Default Users

After running the seeder, the following users are available:

| Role | Username | Password | Description |
|------|----------|----------|-------------|
| Admin | `admin` | `admin123` | System Administrator |
| COF | `cof.accounts` | `cof123` | Chief Officer Finance |
| Clerk | `clerk.intake` | `clerk123` | File Intake Clerk |
| AO | `ao.ramesh` | `ao123` | Accounts Officer |
| AO | `ao.priya` | `ao123` | Accounts Officer |
| AO | `ao.suresh` | `ao123` | Senior Accounts Officer |

## Database Schema

### Key Tables
- **users**: User accounts and roles
- **offices**: Owning offices (Finance, HR, etc.)
- **categories**: File categories (Budget, Audit, etc.)
- **files**: Main file records with SLA tracking
- **file_events**: Immutable movement history
- **sla_policies**: SLA rules by category and priority
- **holidays**: Business day calculations
- **audit_logs**: Complete audit trail

## Business Rules

### File Number Generation
- Format: `ACC-YYYYMMDD-XX`
- Daily counter with collision protection
- Transaction-safe generation

### Business Time Calculation
- Working hours: 9:00 AM - 5:30 PM
- Working days: Monday to Friday
- Excludes configured holidays
- SLA timers pause during holds

### SLA Management
- Warning at 70% threshold
- Automatic breach detection
- Real-time status updates
- Business time only calculations

## Security Features

- JWT-based authentication
- Role-based access control
- Rate limiting (100 requests/15 minutes)
- Input validation and sanitization
- Audit logging for all operations
- Confidential file access restrictions

## Development

### Scripts
```bash
npm start        # Production server
npm run dev      # Development with nodemon
npm run seed     # Database seeding
npm test         # Run tests
```

### Adding New Features
1. Create models in `src/models/`
2. Add controllers in `src/controllers/`
3. Define routes in `src/routes/`
4. Update associations in `src/models/index.js`

## Production Deployment

1. **Environment Variables**
   ```env
   NODE_ENV=production
   JWT_SECRET=strong-production-secret
   DB_HOST=production-db-host
   ```

2. **Database Migration**
   ```bash
   # Run on production database
   npm run seed
   ```

3. **Security Considerations**
   - Use strong JWT secrets
   - Configure proper CORS origins
   - Set up SSL/TLS
   - Regular database backups
   - Monitor audit logs

## API Usage Examples

### Login
```javascript
POST /api/auth/login
{
  "username": "ao.ramesh",
  "password": "ao123"
}
```

### Create File
```javascript
POST /api/files
{
  "subject": "Budget revision for Q4",
  "notesheet_title": "Quarterly budget adjustment",
  "owning_office_id": 1,
  "category_id": 1,
  "priority": "urgent",
  "date_initiated": "2025-09-29",
  "forward_to_user_id": 4
}
```

### Move File
```javascript
POST /api/files/1/move
{
  "to_user_id": 5,
  "action_type": "forward",
  "remarks": "Please review and process"
}
```

## Support

For technical support or feature requests, contact the IT Department at admin@accounts.gov.in

## License

Government of India - Internal Use Only