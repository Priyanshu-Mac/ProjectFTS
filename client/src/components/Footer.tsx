import { Link } from "react-router-dom";

function Footer() {
  return (
    <footer className="bg-gray-800 text-gray-300 py-6 mt-12">
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 flex flex-col md:flex-row justify-between items-center">
        <p className="text-sm">&copy; 2025 GovFiles. All rights reserved.</p>
        <div className="flex space-x-4 mt-2 md:mt-0">
          <Link to="/" className="hover:text-white text-sm">Home</Link>
          <Link to="/file-intake" className="hover:text-white text-sm">File Intake</Link>
          <Link to="/dashboard" className="hover:text-white text-sm">Dashboard</Link>
          <Link to="/contact" className="hover:text-white text-sm">Contact</Link>
        </div>
      </div>
    </footer>
  );
}

export default Footer;
