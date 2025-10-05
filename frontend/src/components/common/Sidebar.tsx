import React, { useState } from 'react';
import { Link, useLocation } from 'react-router-dom';
// We'll use a new icon for the logo area
import { ChevronsLeft, ChevronsRight, ShieldCheck } from 'lucide-react'; 
import type { LucideIcon } from 'lucide-react';
import clsx from 'clsx';

// ... (interface SidebarProps remains the same)
interface SidebarProps {
  navigation: {
    name: string;
    href: string;
    icon: LucideIcon;
  }[];
}


export const Sidebar: React.FC<SidebarProps> = ({ navigation }) => {
  const location = useLocation();
  const [isCollapsed, setIsCollapsed] = useState(false);

  return (
    <aside
      className={clsx(
        'relative bg-slate-900 text-slate-50 transition-all duration-300 ease-in-out flex flex-col',
        isCollapsed ? 'w-20' : 'w-64'
      )}
    >
      <button
        onClick={() => setIsCollapsed(!isCollapsed)}
        className="absolute -right-3 top-8 z-10 p-1.5 bg-slate-700 hover:bg-indigo-600 rounded-full text-white transition-colors"
      >
        {isCollapsed ? <ChevronsRight size={16} /> : <ChevronsLeft size={16} />}
      </button>

      {/* MODIFIED: Logo / App Icon Area */}
      <div className="flex items-center justify-center h-20 border-b border-slate-800">
        {/* We replace the H1 title with a single clean icon */}
        <div className="p-3 bg-slate-800 rounded-lg">
           <ShieldCheck className="h-8 w-8 text-indigo-400" />
        </div>
      </div>

      {/* Navigation Links (this part remains the same) */}
      <nav className="flex-1 px-4 py-6">
        <ul className="space-y-2">
          {navigation.map((item) => {
            const Icon = item.icon;
            const isActive = location.pathname === item.href;
            
            return (
              <li key={item.name}>
                <Link
                  to={item.href}
                  className={clsx(
                    'group flex items-center space-x-3 px-3 py-2.5 rounded-lg transition-colors',
                    isActive
                      ? 'bg-indigo-600 text-white font-semibold'
                      : 'text-slate-300 hover:bg-slate-800 hover:text-white',
                    isCollapsed && 'justify-center'
                  )}
                >
                  <Icon className="h-5 w-5" />
                  <span className={clsx(
                      "text-sm",
                      isCollapsed && 'hidden'
                  )}>
                    {item.name}
                  </span>
                  
                  {isCollapsed && (
                    <span className="absolute left-full ml-4 w-auto p-2 min-w-max rounded-md shadow-md text-white bg-slate-800 text-xs font-bold transition-all duration-100 scale-0 group-hover:scale-100 origin-left">
                      {item.name}
                    </span>
                  )}
                </Link>
              </li>
            );
          })}
        </ul>
      </nav>
    </aside>
  );
};