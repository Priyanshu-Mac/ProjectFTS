import { Link } from "react-router-dom";

function Footer() {
  return (
    <footer className="bg-gray-800 text-white py-12 mt-20">
      <div className="container">
        <div className="grid md:grid-cols-4 gap-8">
          <div>
            <div className="text-xl font-bold mb-4">GovFiles</div>
            <p className="text-gray-300 mb-4">
              Digital transformation for government and corporate 
              file management systems with precision tracking.
            </p>
            <div className="flex gap-4">
              <div className="w-8 h-8 bg-gray-700 rounded-full flex items-center justify-center hover:bg-gray-600 transition-colors cursor-pointer">
                <span className="text-sm">🐦</span>
              </div>
              <div className="w-8 h-8 bg-gray-700 rounded-full flex items-center justify-center hover:bg-gray-600 transition-colors cursor-pointer">
                <span className="text-sm">📧</span>
              </div>
              <div className="w-8 h-8 bg-gray-700 rounded-full flex items-center justify-center hover:bg-gray-600 transition-colors cursor-pointer">
                <span className="text-sm">💼</span>
              </div>
            </div>
          </div>

          <div>
            <h4 className="font-bold mb-4">Product</h4>
            <div className="space-y-2 text-gray-300">
              <div><Link to="/file-intake" className="hover:text-white transition-colors">File Intake</Link></div>
              <div><Link to="/file-movement" className="hover:text-white transition-colors">File Movement</Link></div>
              <div><Link to="/cof-review" className="hover:text-white transition-colors">COF Review</Link></div>
              <div><Link to="/dashboard" className="hover:text-white transition-colors">Dashboard</Link></div>
              <div><Link to="/reports" className="hover:text-white transition-colors">Reports</Link></div>
            </div>
          </div>

          <div>
            <h4 className="font-bold mb-4">Resources</h4>
            <div className="space-y-2 text-gray-300">
              <div><a href="#" className="hover:text-white transition-colors">Documentation</a></div>
              <div><a href="#" className="hover:text-white transition-colors">API Reference</a></div>
              <div><a href="#" className="hover:text-white transition-colors">Training</a></div>
              <div><a href="#" className="hover:text-white transition-colors">Best Practices</a></div>
              <div><a href="#" className="hover:text-white transition-colors">Support</a></div>
            </div>
          </div>

          <div>
            <h4 className="font-bold mb-4">Contact</h4>
            <div className="space-y-3 text-gray-300">
              <div className="flex items-center gap-2">
                <span>📞</span>
                <span>+91 11 2345-6789</span>
              </div>
              <div className="flex items-center gap-2">
                <span>✉️</span>
                <span>support@govfiles.gov</span>
              </div>
              <div className="flex items-center gap-2">
                <span>🏢</span>
                <span>New Delhi, India</span>
              </div>
              <div className="flex items-center gap-2">
                <span>⏰</span>
                <span>Mon-Fri 9:00-18:00</span>
              </div>
            </div>
          </div>
        </div>

        <div className="border-t border-gray-700 mt-12 pt-8">
          <div className="flex flex-col md:flex-row justify-between items-center gap-4">
            <div className="text-gray-400 text-sm">
              © 2025 GovFiles. All rights reserved. 
            </div>
            <div className="flex gap-6 text-sm text-gray-400">
              <a href="#" className="hover:text-white transition-colors">Privacy Policy</a>
              <a href="#" className="hover:text-white transition-colors">Terms of Service</a>
              <a href="#" className="hover:text-white transition-colors">Compliance</a>
              <a href="#" className="hover:text-white transition-colors">Security</a>
            </div>
          </div>
          <div className="text-center mt-4 text-gray-500 text-sm">
            Secure • Compliant • Scalable • Government Ready
          </div>
        </div>
      </div>
    </footer>
  );
}

export default Footer;
