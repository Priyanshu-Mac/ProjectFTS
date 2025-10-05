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

REBUILD.
