// import React from 'react';
// import { FolderKanban, LogOut } from 'lucide-react';
// import dtuLogo from './Dtu_logo.webp'; 

// interface HeaderProps {
//   currentUser: { name?: string; role?: string; } | null;
//   onLogout: () => void;
// }

// export const Header: React.FC<HeaderProps> = ({ currentUser, onLogout }) => {
//   return (
//     <header className="bg-white border-b border-gray-200">
//       <div className="relative flex items-center h-16 px-6">
        
//         <div className="absolute left-1/2 -translate-x-1/2 flex items-center space-x-3">
//           {/* <FolderKanban className="h-7 w-7 text-indigo-600" /> */}
//           <img src={dtuLogo} alt="DTU Logo" className="h-19 w-14 -mr-4" />
//           <h1 className="text-xl font-bold text-slate-800">
//             DTU File Tracking System
//           </h1>
//         </div>

//         <div className="relative group ml-auto pt-2">
//   <button className="flex items-center space-x-2 p-2 rounded-lg hover:bg-gray-100 transition-colors">
//     <div className="w-8 h-8 rounded-full bg-indigo-600 text-white flex items-center justify-center font-bold">
//       {currentUser?.name?.charAt(0).toUpperCase()}
//     </div>
//     <div className="text-left hidden md:block">
//       <div className="text-sm font-semibold text-gray-800">{currentUser?.name}</div>
//       <div className="text-xs text-gray-500 capitalize">{currentUser?.role?.replace('_', ' ')}</div>
//     </div>
//   </button>
  
//   {/* CHANGE 2: Remove margin-top (mt-2) so it uses the parent's padding */}
//   <div className="absolute right-0 w-48 bg-white rounded-md shadow-lg py-1 z-20 opacity-0 group-hover:opacity-100 transition-opacity duration-200 pointer-events-none group-hover:pointer-events-auto">
//     <button
//       onClick={onLogout}
//       className="w-full text-left flex items-center space-x-2 px-4 py-2 text-sm text-gray-700 hover:bg-gray-100"
//     >
//       <LogOut className="h-4 w-4" />
//       <span>Logout</span>
//     </button>
//   </div>
// </div>
//       </div>
//     </header>
//   );
// };


import React from 'react';
import { LogOut } from 'lucide-react';
import dtuLogo from '../../assets/dtu-logo.png'; 

interface HeaderProps {
  currentUser: { name?: string; role?: string; } | null;
  onLogout: () => void;
}

export const Header: React.FC<HeaderProps> = ({ currentUser, onLogout }) => {
  return (
    <header className="bg-white border-b border-gray-200">
      <div className="relative flex items-center h-12 sm:h-14 px-3 sm:px-5"> {/* Compact header height */}
        
        {/* --- MODIFIED THIS SECTION FOR RESPONSIVENESS --- */}
        <div className="absolute left-1/2 -translate-x-1/2 flex items-center space-x-1 sm:space-x-2">
          <img 
            src={dtuLogo} 
            alt="DTU Logo" 
            className="h-8 w-8 sm:h-9 sm:w-9" // Smaller logo size
          />
          <h1 className="text-sm sm:text-lg font-bold text-slate-800 whitespace-nowrap">
            <span>DTU </span>
            {/* Show "File Tracking System" only on medium screens and up */}
            <span className="hidden md:inline">File Tracking System</span>
            {/* Show "FTS" on small screens, hide on medium and up */}
            <span className="md:hidden">FTS</span>
          </h1>
        </div>
        {/* --- END OF MODIFICATION --- */}

        <div className="relative group ml-auto">
          <button className="flex items-center space-x-2 p-2 rounded-lg hover:bg-gray-100 transition-colors">
            <div className="w-7 h-7 rounded-full bg-indigo-600 text-white flex items-center justify-center font-bold text-xs">
              {currentUser?.name?.charAt(0).toUpperCase()}
            </div>
            <div className="text-left hidden md:block">
              <div className="text-xs sm:text-sm font-semibold text-gray-800">{currentUser?.name}</div>
              <div className="text-[11px] text-gray-500 capitalize">{currentUser?.role?.replace('_', ' ')}</div>
            </div>
          </button>
          
          <div className="absolute right-0 w-48 bg-white rounded-md shadow-lg py-1 z-20 opacity-0 group-hover:opacity-100 transition-opacity duration-200 pointer-events-none group-hover:pointer-events-auto">
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