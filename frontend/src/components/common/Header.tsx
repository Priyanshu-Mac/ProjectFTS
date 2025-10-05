import React from 'react';
import { FolderKanban, LogOut, User } from 'lucide-react'; 

interface HeaderProps {
  currentUser: { name?: string; role?: string; } | null;
  onLogout: () => void;
}

export const Header: React.FC<HeaderProps> = ({ currentUser, onLogout }) => {
  return (
    <header className="bg-white border-b border-gray-200">
      <div className="relative flex items-center h-16 px-6">
        
        <div className="absolute left-1/2 -translate-x-1/2 flex items-center space-x-3">
          <FolderKanban className="h-7 w-7 text-indigo-600" />
          <h1 className="text-xl font-bold text-slate-800">
            DTU File Tracking System
          </h1>
        </div>

        <div className="relative group ml-auto">
          <button className="flex items-center space-x-2 p-2 rounded-lg hover:bg-gray-100 transition-colors">
            <div className="w-8 h-8 rounded-full bg-indigo-600 text-white flex items-center justify-center font-bold">
              {currentUser?.name?.charAt(0).toUpperCase()}
            </div>
            <div className="text-left hidden md:block">
              <div className="text-sm font-semibold text-gray-800">{currentUser?.name}</div>
              <div className="text-xs text-gray-500 capitalize">{currentUser?.role?.replace('_', ' ')}</div>
            </div>
          </button>
          
          <div className="absolute right-0 mt-2 w-48 bg-white rounded-md shadow-lg py-1 z-20 opacity-0 group-hover:opacity-100 transition-opacity duration-200 pointer-events-none group-hover:pointer-events-auto">
            <button
              onClick={onLogout}
              className="w-full text-left flex items-center space-x-2 px-4 py-2 text-sm text-gray-700 hover:bg-gray-100"
            >
              <LogOut className="h-4 w-4" />
              <span>Logout</span>
            </button>
          </div>
        </div>
      </div>
    </header>
  );
};