// import React from 'react';

// // Using Lucide icons for a modern feel. You might need to install lucide-react:
// // npm install lucide-react
// import { Mail, Phone, MapPin } from 'lucide-react';

// const Footer: React.FC = () => {
//   const currentYear = new Date().getFullYear();

//   return (
//     <footer className="bg-gray-900 text-white mt-auto">
//       <div className="max-w-7xl mx-auto py-12 px-4 sm:px-6 lg:px-8">
//         <div className="grid grid-cols-1 md:grid-cols-3 gap-8">
//           {/* Column 1: About */}
//           <div className="space-y-4">
//             <h3 className="text-xl font-semibold text-gray-200 tracking-wider">
//               DTU Accounts Dept.
//             </h3>
//             <p className="text-gray-300">
//               File Tracking System designed to streamline and manage the movement of departmental files efficiently.
//             </p>
//             <p className="text-sm text-gray-400">
//               An initiative by Delhi Technological University.
//             </p>
//           </div>

//           {/* Column 2: Quick Links */}
//           <div className="space-y-4">
//             <h3 className="text-xl font-semibold text-gray-200 tracking-wider">
//               Quick Links
//             </h3>
//             <ul className="space-y-2">
//               <li>
//                 <a href="http://dtu.ac.in/" target="_blank" rel="noopener noreferrer" className="text-gray-300 hover:text-white transition-colors duration-300">
//                   DTU Main Website
//                 </a>
//               </li>
//               <li>
//                 <a href="#" className="text-gray-300 hover:text-white transition-colors duration-300">
//                   University Circulars
//                 </a>
//               </li>
//               <li>
//                 <a href="#" className="text-gray-300 hover:text-white transition-colors duration-300">
//                   Help & FAQ
//                 </a>
//               </li>
//                <li>
//                 <a href="#" className="text-gray-300 hover:text-white transition-colors duration-300">
//                   Privacy Policy
//                 </a>
//               </li>
//             </ul>
//           </div>

//           {/* Column 3: Contact Info */}
//           <div className="space-y-4">
//             <h3 className="text-xl font-semibold text-gray-200 tracking-wider">
//               Contact Us
//             </h3>
//             <ul className="space-y-3 text-gray-300">
//               <li className="flex items-start">
//                 <MapPin className="h-5 w-5 mr-3 mt-1 flex-shrink-0" />
//                 <span>
//                   Delhi Technological University,<br />
//                   Shahbad Daulatpur, Main Bawana Road,<br />
//                   Delhi-110042, India
//                 </span>
//               </li>
//               <li className="flex items-center">
//                 <Phone className="h-5 w-5 mr-3 flex-shrink-0" />
//                 <span>+91-11-27871018</span>
//               </li>
//               <li className="flex items-center">
//                 <Mail className="h-5 w-5 mr-3 flex-shrink-0" />
//                 <a href="mailto:accounts@dtu.ac.in" className="hover:text-white transition-colors duration-300">
//                   accounts@dtu.ac.in
//                 </a>
//               </li>
//             </ul>
//           </div>
//         </div>

//         {/* Bottom Bar */}
//         <div className="mt-12 border-t border-gray-800 pt-8 flex flex-col sm:flex-row justify-between items-center">
//           <p className="text-gray-400 text-sm">
//             &copy; {currentYear} Delhi Technological University. All Rights Reserved.
//           </p>
//            <p className="text-gray-400 text-sm mt-4 sm:mt-0">
//              Designed with ❤️
//           </p>
//         </div>
//       </div>
//     </footer>
//   );
// };

// export default Footer;

import React from 'react';

const Footer: React.FC = () => {
  const currentYear = new Date().getFullYear();

  return (
    <footer className="bg-slate-100 text-slate-700 border-t border-slate-200">
      <div className="max-w-[1200px] mx-auto px-4 py-3">
        <div className="flex flex-col sm:flex-row items-center justify-between gap-2">
          <p className="text-xs text-slate-600 text-center sm:text-left">
            © {currentYear} Delhi Technological University — File Tracking System
          </p>
          <div className="flex items-center gap-4">
            <a
              href="http://dtu.ac.in/"
              target="_blank"
              rel="noopener noreferrer"
              className="text-xs text-indigo-600 hover:text-indigo-700"
            >
              DTU Website
            </a>
            <a
              href="mailto:accounts@dtu.ac.in"
              className="text-xs text-slate-600 hover:text-slate-800"
            >
              Contact
            </a>
            <a href="#" className="text-xs text-slate-600 hover:text-slate-800">
              Privacy
            </a>
          </div>
        </div>
      </div>
    </footer>
  );
};

export default Footer;