// import React, { useState } from 'react';
// import { Link, useLocation } from 'react-router-dom';
// // We'll use a new icon for the logo area
// import { ChevronsLeft, ChevronsRight, ShieldCheck } from 'lucide-react'; 
// import type { LucideIcon } from 'lucide-react';
// import clsx from 'clsx';
// import dtuLogo from './Dtu_logo.webp'; 

// // ... (interface SidebarProps remains the same)
// interface SidebarProps {
//   navigation: {
//     name: string;
//     href: string;
//     icon: LucideIcon;
//   }[];
// }


// export const Sidebar: React.FC<SidebarProps> = ({ navigation }) => {
//   const location = useLocation();
//   const [isCollapsed, setIsCollapsed] = useState(false);

//   return (
//     <aside
//       className={clsx(
//         'relative bg-slate-900 text-slate-50 transition-all duration-300 ease-in-out flex flex-col',
//         isCollapsed ? 'w-20' : 'w-64'
//       )}
//     >
//       <button
//         onClick={() => setIsCollapsed(!isCollapsed)}
//         className="absolute -right-3 top-8 z-10 p-1.5 bg-slate-700 hover:bg-indigo-600 rounded-full text-white transition-colors"
//       >
//         {isCollapsed ? <ChevronsRight size={16} /> : <ChevronsLeft size={16} />}
//       </button>

//       {/* MODIFIED: Logo / App Icon Area */}
//       <div className="flex items-center justify-center h-20 border-b border-slate-800">
//         {/* We replace the H1 title with a single clean icon */}
//         <div className="p-3 bg-slate-800 rounded-lg">
//            <ShieldCheck className="h-8 w-8 text-indigo-400" />
           
//         </div>
//       </div>

//       {/* Navigation Links (this part remains the same) */}
//       <nav className="flex-1 px-4 py-6">
//         <ul className="space-y-2">
//           {navigation.map((item) => {
//             const Icon = item.icon;
//             const isActive = location.pathname === item.href;
            
//             return (
//               <li key={item.name}>
//                 <Link
//                   to={item.href}
//                   className={clsx(
//                     'group flex items-center space-x-3 px-3 py-2.5 rounded-lg transition-colors',
//                     isActive
//                       ? 'bg-indigo-600 text-white font-semibold'
//                       : 'text-slate-300 hover:bg-slate-800 hover:text-white',
//                     isCollapsed && 'justify-center'
//                   )}
//                 >
//                   <Icon className="h-5 w-5" />
//                   <span className={clsx(
//                       "text-sm",
//                       isCollapsed && 'hidden'
//                   )}>
//                     {item.name}
//                   </span>
                  
//                   {isCollapsed && (
//                     <span className="absolute left-full ml-4 w-auto p-2 min-w-max rounded-md shadow-md text-white bg-slate-800 text-xs font-bold transition-all duration-100 scale-0 group-hover:scale-100 origin-left">
//                       {item.name}
//                     </span>
//                   )}
//                 </Link>
//               </li>
//             );
//           })}
//         </ul>
//       </nav>
//     </aside>
//   );
// };


import React, { useState, useEffect } from 'react'; // Import useEffect
import { Link, useLocation } from 'react-router-dom';
import { ChevronsLeft, ChevronsRight } from 'lucide-react'; 
import type { LucideIcon } from 'lucide-react';
import clsx from 'clsx';
import dtuLogo from '../../assets/dtu-logo.png';

interface SidebarProps {
  navigation: {
    name: string;
    href: string;
    icon: LucideIcon;
  }[];
}

export const Sidebar: React.FC<SidebarProps> = ({ navigation }) => {
  const location = useLocation();
  // The initial state is now dynamically set, but the useEffect will handle it robustly.
  const [isCollapsed, setIsCollapsed] = useState(false);

  // --- START: RESPONSIVE LOGIC ---
  useEffect(() => {
    // Function to check the screen size and update the state
    const handleResize = () => {
      // We use 768px as the breakpoint, which is Tailwind's default for `md` screens.
      if (window.innerWidth < 768) {
        setIsCollapsed(true);
      } else {
        setIsCollapsed(false);
      }
    };

    // Run the function once on component mount
    handleResize();

    // Add an event listener to run the function on every window resize
    window.addEventListener('resize', handleResize);

    // Cleanup: Remove the event listener when the component is unmounted
    return () => {
      window.removeEventListener('resize', handleResize);
    };
  }, []); // The empty array ensures this effect runs only once on mount and cleanup on unmount
  // --- END: RESPONSIVE LOGIC ---

  return (
    <aside
      className={clsx(
        'relative bg-slate-50 text-slate-700 transition-all duration-300 ease-in-out flex flex-col border-r border-slate-200', 
        isCollapsed ? 'w-20' : 'w-64'
      )}
    >
      <button
        onClick={() => setIsCollapsed(!isCollapsed)}
        className="absolute -right-3 top-8 z-10 p-1.5 bg-white border border-slate-200 hover:bg-slate-100 rounded-full text-slate-600 transition-colors shadow-sm"
        aria-label="Toggle sidebar"
      >
        {isCollapsed ? <ChevronsRight size={16} /> : <ChevronsLeft size={16} />}
      </button>

      {/* Logo */}

      <div className="flex items-center justify-center h-16 border-b border-slate-200 px-2">
        <div className="flex items-center gap-2">
          <img src={dtuLogo} alt="DTU Logo" className="h-8 w-8 rounded-full" />
          {!isCollapsed && (
            <span className="text-sm font-semibold text-slate-800">DTU FTS</span>
          )}
        </div>
      </div>



      {/* Navigation Links */}
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
                    'group relative flex items-center space-x-3 px-3 py-2.5 rounded-lg transition-colors',
                    isActive
                      ? 'bg-indigo-50 text-indigo-700 font-semibold'
                      : 'text-slate-700 hover:bg-slate-100 hover:text-slate-900',
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
                  
                  {/* Tooltip for collapsed state */}
                  {isCollapsed && (
                    <span className="absolute left-full ml-4 w-auto p-2 min-w-max rounded-md shadow-md text-slate-800 bg-white border border-slate-200 text-xs font-medium transition-all duration-100 scale-0 group-hover:scale-100 origin-left z-20">
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