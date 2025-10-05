import React from 'react';
import { Link, useLocation, useNavigate } from 'react-router-dom';
import { 
  Home, 
  FileText, 
  Plus, 
  Search, 
  BarChart3, 
  LogOut,
  User,
  Building,
  FolderOpen
} from 'lucide-react';
import type { LucideIcon } from 'lucide-react';
import { authService } from '../../services/authService';

interface NavigationItem {
  name: string;
  href: string;
  icon: LucideIcon;
  roles: string[];
}

interface LayoutProps {
  children: React.ReactNode;
}

const Layout: React.FC<LayoutProps> = ({ children }) => {
  const location = useLocation();
  const navigate = useNavigate();
  const currentUser = authService.getCurrentUser();

  const handleLogout = () => {
    authService.logout();
    navigate('/login');
  };

  const navigation: NavigationItem[] = [
    { 
      name: 'Dashboard', 
      href: '/', 
      icon: Home, 
      roles: ['clerk', 'accounts_officer', 'cof', 'admin'] 
    },
    { 
      name: 'File Intake', 
      href: '/file-intake', 
      icon: Plus, 
      roles: ['clerk', 'cof', 'admin'] 
    },
    { 
      name: 'Move File', 
      href: '/move-file', 
      icon: FolderOpen, 
      roles: ['accounts_officer', 'cof', 'admin'] 
    },
    { 
      name: 'File Search', 
      href: '/file-search', 
      icon: Search, 
      roles: ['clerk', 'accounts_officer', 'cof', 'admin'] 
    },
    { 
      name: 'COF Review', 
      href: '/cof-review', 
      icon: FileText, 
      roles: ['cof', 'admin'] 
    },
    { 
      name: 'Officer Kanban', 
      href: '/kanban', 
      icon: FolderOpen, 
      roles: ['accounts_officer', 'cof', 'admin'] 
    },
    { 
      name: 'Reports / Exports', 
      href: '/reports', 
      icon: BarChart3, 
      roles: ['cof', 'admin'] 
    },
    { 
      name: 'Audit Logs', 
      href: '/audit-logs', 
      icon: FileText, 
      roles: ['cof', 'admin'] 
    },
    { 
      name: 'Admin', 
      href: '/admin', 
      icon: User, 
      roles: ['admin'] 
    },
    { 
      name: 'Master Data', 
      href: '/master-data', 
      icon: Building, 
      roles: ['admin'] 
    }
  ];

  const allowedNavigation = navigation.filter(item => 
    currentUser?.role && item.roles.includes(currentUser.role)
  );

  return (
    <div className="min-h-screen bg-gray-50">
      {/* Header */}
      <header className="gov-header">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
          <div className="flex justify-between items-center py-4">
            <div className="flex items-center">
              <div className="flex-shrink-0">
                <h1 className="text-xl font-bold">DTU File Tracking System</h1>
                <p className="text-sm text-blue-200">Accounts Department</p>
              </div>
            </div>
            
            <div className="flex items-center space-x-4">
              <div className="flex items-center space-x-2">
                <User className="h-5 w-5" />
                <div className="text-sm">
                  <div className="font-medium">{currentUser?.name}</div>
                  <div className="text-blue-200">{currentUser?.role}</div>
                </div>
              </div>
              
              <button
                onClick={handleLogout}
                className="flex items-center space-x-2 text-blue-200 hover:text-white transition-colors"
              >
                <LogOut className="h-5 w-5" />
                <span>Logout</span>
              </button>
            </div>
          </div>
        </div>
      </header>

      <div className="flex">
        {/* Sidebar */}
        <nav className="gov-sidebar w-64 min-h-screen">
          <div className="p-4">
            <ul className="space-y-2">
              {allowedNavigation.map((item) => {
                const Icon = item.icon;
                const isActive = location.pathname === item.href;
                
                return (
                  <li key={item.name}>
                    <Link
                      to={item.href}
                      className={`flex items-center space-x-3 px-3 py-2 rounded-md transition-colors ${
                        isActive
                          ? 'bg-primary-100 text-primary-700 border-r-2 border-primary-500'
                          : 'text-gray-700 hover:bg-gray-100'
                      }`}
                    >
                      <Icon className="h-5 w-5" />
                      <span className="text-sm font-medium">{item.name}</span>
                    </Link>
                  </li>
                );
              })}
            </ul>
          </div>
        </nav>

        {/* Main Content */}
        <main className="flex-1 p-6">
          <div className="max-w-7xl mx-auto">
            {children}
          </div>
        </main>
      </div>
    </div>
  );
};

export default Layout;