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
    <footer className="relative bg-slate-900 text-white overflow-hidden border-t border-slate-800">
      {/* Subtle gradient overlay */}
      <div className="absolute inset-0 bg-gradient-to-r from-slate-900 via-slate-850 to-slate-900 opacity-50"></div>
      
      {/* Accent glow */}
      <div className="absolute top-0 right-1/3 w-96 h-32 bg-indigo-600/5 rounded-full blur-3xl"></div>
      
      <div className="relative max-w-[1400px] mx-auto px-8 py-10 w-full">
        {/* Main Content - Horizontal Layout */}
        <div className="flex flex-wrap items-start justify-between gap-12 mb-8">
          
          {/* Brand Section - Now takes more space */}
          <div className="flex-1 min-w-[300px] max-w-lg space-y-4">
            <h2 className="text-3xl font-bold tracking-tight text-white">
              DTU <span className="text-indigo-400">Accounts Department</span>
            </h2>
            <p className="text-slate-400 text-sm leading-relaxed">
              Intelligent file tracking system powering seamless document management for Delhi Technological University's finance operations.
            </p>
            
            {/* DTU Main Website Link */}
            <a 
              href="http://dtu.ac.in/"
              target="_blank"
              rel="noopener noreferrer"
              className="inline-flex items-center gap-2 text-sm text-indigo-400 hover:text-indigo-300 transition-colors group"
            >
              <span>Visit DTU Main Website</span>
              <ExternalLink className="h-4 w-4 group-hover:translate-x-0.5 group-hover:-translate-y-0.5 transition-transform" />
            </a>
            
            {/* Social Links */}
            <div className="flex gap-3 pt-2">
              <a href="https://x.com/dtu_delhi" target="_blank" rel="noopener noreferrer" className="bg-slate-800 hover:bg-slate-700 p-2.5 rounded-lg transition-all duration-300 hover:scale-110">
                <Twitter className="h-4 w-4 text-slate-400 hover:text-indigo-400 transition-colors" />
              </a>
              <a href="https://www.linkedin.com/in/delhi-technological-university-delhi-397129209/" target="_blank" rel="noopener noreferrer" className="bg-slate-800 hover:bg-slate-700 p-2.5 rounded-lg transition-all duration-300 hover:scale-110">
                <Linkedin className="h-4 w-4 text-slate-400 hover:text-indigo-400 transition-colors" />
              </a>
              <a href="https://www.instagram.com/dtu.delhi/" target="_blank" rel="noopener noreferrer" className="bg-slate-800 hover:bg-slate-700 p-2.5 rounded-lg transition-all duration-300 hover:scale-110">
                <Instagram className="h-4 w-4 text-slate-400 hover:text-indigo-400 transition-colors" />
              </a>
              <a href="https://www.facebook.com/people/DTU_Official/100065103819173/" target="_blank" rel="noopener noreferrer" className="bg-slate-800 hover:bg-slate-700 p-2.5 rounded-lg transition-all duration-300 hover:scale-110">
                <Facebook className="h-4 w-4 text-slate-400 hover:text-indigo-400 transition-colors" />
              </a>
            </div>
          </div>

          {/* Contact Section */}
          <div className="flex-1 min-w-[280px] max-w-sm">
            <h3 className="text-xs font-semibold text-slate-500 uppercase tracking-wider mb-4">Get in Touch</h3>
            <div className="space-y-3">
              <div className="flex items-start gap-3 p-3 rounded-lg bg-slate-800/40 border border-slate-700/40">
                <div className="bg-indigo-500/10 p-2 rounded-lg">
                  <MapPin className="h-4 w-4 text-indigo-400" />
                </div>
                <div className="text-xs text-slate-400 leading-relaxed">
                  Shahbad Daulatpur, Main Bawana Road,<br />
                  Delhi-110042, India
                </div>
              </div>
              
              <div className="flex items-center gap-3 p-3 rounded-lg bg-slate-800/40 border border-slate-700/40">
                <div className="bg-indigo-500/10 p-2 rounded-lg">
                  <Phone className="h-4 w-4 text-indigo-400" />
                </div>
                <span className="text-xs text-slate-400">+91-11-27871018</span>
              </div>
              
              <a 
                href="mailto:accounts@dtu.ac.in"
                className="flex items-center gap-3 p-3 rounded-lg bg-slate-800/40 border border-slate-700/40 hover:border-indigo-500/50 hover:bg-slate-800/60 transition-all duration-300 group"
              >
                <div className="bg-indigo-500/10 p-2 rounded-lg">
                  <Mail className="h-4 w-4 text-indigo-400" />
                </div>
                <span className="text-xs text-slate-400 group-hover:text-indigo-400 transition-colors">accounts@dtu.ac.in</span>
              </a>
            </div>
          </div>
        </div>

        {/* Bottom bar */}
        <div className="border-t border-slate-800 pt-6">
          <div className="flex flex-wrap items-center justify-between gap-4">
            <p className="text-xs text-slate-500">
              © {currentYear} Delhi Technological University — All Rights Reserved
            </p>
            <div className="flex items-center gap-6">
              <a href="#" className="text-xs text-slate-500 hover:text-slate-300 transition-colors">Terms</a>
              <a href="#" className="text-xs text-slate-500 hover:text-slate-300 transition-colors">Security</a>
              <a href="#" className="text-xs text-slate-500 hover:text-slate-300 transition-colors">Accessibility</a>
            </div>
          </div>
        </div>
      </div>
    </footer>
  );
};

export default Footer;