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
import { Mail, Phone, MapPin, ExternalLink, Instagram, Facebook, Twitter, Linkedin } from 'lucide-react';

const Footer: React.FC = () => {
  const currentYear = new Date().getFullYear();

  return (
  <footer className="relative bg-slate-100 text-slate-800 overflow-hidden border-t border-slate-200">
      {/* Subtle gradient to be a touch darker than main content */}
      <div className="absolute inset-0 bg-gradient-to-r from-white via-slate-100 to-white opacity-70"></div>
      
      {/* Gentle accent glow */}
      <div className="absolute top-0 right-1/3 w-80 h-28 bg-indigo-400/10 rounded-full blur-3xl"></div>
      
      <div className="relative max-w-[1400px] mx-auto px-6 py-5 w-full">
        {/* Main Content - Horizontal Layout */}
        <div className="flex flex-wrap items-start justify-between gap-6 mb-4">
          
          {/* Brand Section - Now takes more space */}
          <div className="flex-1 min-w-[280px] max-w-lg space-y-2.5">
            <h2 className="text-xl font-bold tracking-tight text-slate-900">
              DTU <span className="text-indigo-600">Accounts Department</span>
            </h2>
            <p className="text-slate-600 text-sm leading-snug">
              Intelligent file tracking system powering seamless document management for Delhi Technological University's finance operations.
            </p>
            
            {/* DTU Main Website Link */}
            <a 
              href="http://dtu.ac.in/"
              target="_blank"
              rel="noopener noreferrer"
              className="inline-flex items-center gap-1.5 text-sm text-indigo-600 hover:text-indigo-700 transition-colors group"
            >
              <span>Visit DTU Main Website</span>
              <ExternalLink className="h-4 w-4 group-hover:translate-x-0.5 group-hover:-translate-y-0.5 transition-transform" />
            </a>
            
            {/* Social Links */}
            <div className="flex gap-2.5 pt-1.5">
              <a href="https://x.com/dtu_delhi" target="_blank" rel="noopener noreferrer" className="bg-white border border-slate-200 hover:bg-slate-50 p-2 rounded-lg transition-all duration-300 hover:scale-105">
                <Twitter className="h-4 w-4 text-slate-500 hover:text-indigo-600 transition-colors" />
              </a>
              <a href="https://www.linkedin.com/in/delhi-technological-university-delhi-397129209/" target="_blank" rel="noopener noreferrer" className="bg-white border border-slate-200 hover:bg-slate-50 p-2 rounded-lg transition-all duration-300 hover:scale-105">
                <Linkedin className="h-4 w-4 text-slate-500 hover:text-indigo-600 transition-colors" />
              </a>
              <a href="https://www.instagram.com/dtu.delhi/" target="_blank" rel="noopener noreferrer" className="bg-white border border-slate-200 hover:bg-slate-50 p-2 rounded-lg transition-all duration-300 hover:scale-105">
                <Instagram className="h-4 w-4 text-slate-500 hover:text-indigo-600 transition-colors" />
              </a>
              <a href="https://www.facebook.com/people/DTU_Official/100065103819173/" target="_blank" rel="noopener noreferrer" className="bg-white border border-slate-200 hover:bg-slate-50 p-2 rounded-lg transition-all duration-300 hover:scale-105">
                <Facebook className="h-4 w-4 text-slate-500 hover:text-indigo-600 transition-colors" />
              </a>
            </div>
          </div>

          {/* Contact Section */}
          <div className="flex-1 min-w-[260px] max-w-sm">
            <h3 className="text-xs font-semibold text-slate-500 uppercase tracking-wider mb-3">Get in Touch</h3>
            <div className="space-y-3">
              <div className="flex items-start gap-2.5 p-2.5 rounded-lg bg-white border border-slate-200 shadow-sm">
                <div className="bg-indigo-500/10 p-2 rounded-lg">
                  <MapPin className="h-4 w-4 text-indigo-600" />
                </div>
                <div className="text-xs text-slate-600 leading-relaxed">
                  Shahbad Daulatpur, Main Bawana Road,<br />
                  Delhi-110042, India
                </div>
              </div>
              
              <div className="flex items-center gap-2.5 p-2.5 rounded-lg bg-white border border-slate-200 shadow-sm">
                <div className="bg-indigo-500/10 p-2 rounded-lg">
                  <Phone className="h-4 w-4 text-indigo-600" />
                </div>
                <span className="text-xs text-slate-600">+91-11-27871018</span>
              </div>
              
              <a 
                href="mailto:accounts@dtu.ac.in"
                className="flex items-center gap-2.5 p-2.5 rounded-lg bg-white border border-slate-200 hover:border-indigo-500/30 hover:bg-slate-50 transition-all duration-300 group shadow-sm"
              >
                <div className="bg-indigo-500/10 p-2 rounded-lg">
                  <Mail className="h-4 w-4 text-indigo-600" />
                </div>
                <span className="text-xs text-slate-600 group-hover:text-indigo-700 transition-colors">accounts@dtu.ac.in</span>
              </a>
            </div>
          </div>
        </div>

        {/* Bottom bar */}
        <div className="border-t border-slate-200 pt-3">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <p className="text-xs text-slate-600">
              © {currentYear} Delhi Technological University — All Rights Reserved
            </p>
            <div className="flex items-center gap-4">
              <a href="#" className="text-xs text-slate-600 hover:text-slate-800 transition-colors">Terms</a>
              <a href="#" className="text-xs text-slate-600 hover:text-slate-800 transition-colors">Security</a>
              <a href="#" className="text-xs text-slate-600 hover:text-slate-800 transition-colors">Accessibility</a>
            </div>
          </div>
        </div>
      </div>
    </footer>
  );
};

export default Footer;