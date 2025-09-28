import { Link } from "react-router-dom";
import { useState } from "react";

function Navbar() {
  const [isMenuOpen, setIsMenuOpen] = useState(false);

  return (
    <nav className="bg-brand text-white shadow-lg sticky top-0 z-50">
      <div className="container">
        <div className="flex justify-between items-center h-16">
          <div className="flex items-center gap-md">
            <Link to="/" className="text-xl font-bold hover:text-accent transition-colors">
              GovFiles
            </Link>
            <span className="badge badge-info text-xs">v2.0</span>
          </div>

          <div className="hidden md:flex items-center gap-lg">
            <Link to="/" className="hover:text-accent transition-colors">Home</Link>
            <Link to="/file-intake" className="hover:text-accent transition-colors">File Intake</Link>
            <Link to="/file-movement" className="hover:text-accent transition-colors">Movement</Link>
            <Link to="/cof-review" className="hover:text-accent transition-colors">COF Review</Link>
            <Link to="/dashboard" className="hover:text-accent transition-colors">Dashboard</Link>
            <div className="flex gap-sm ml-lg">
              <Link to="/login" className="btn btn-secondary text-sm px-4 py-2">Login</Link>
              <Link to="/demo" className="btn btn-warning text-sm px-4 py-2">Try Demo</Link>
            </div>
          </div>

          <button 
            className="md:hidden p-2 hover:bg-brand-dark rounded transition-colors" 
            onClick={() => setIsMenuOpen(!isMenuOpen)}
          >
            <svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              {isMenuOpen ? (
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M6 18L18 6M6 6l12 12" />
              ) : (
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M4 6h16M4 12h16M4 18h16" />
              )}
            </svg>
          </button>
        </div>

        {isMenuOpen && (
          <div className="md:hidden py-4 border-t border-brand-light">
            <div className="flex flex-col gap-md">
              <Link to="/" className="py-2 hover:text-accent transition-colors">Home</Link>
              <Link to="/file-intake" className="py-2 hover:text-accent transition-colors">File Intake</Link>
              <Link to="/file-movement" className="py-2 hover:text-accent transition-colors">Movement</Link>
              <Link to="/cof-review" className="py-2 hover:text-accent transition-colors">COF Review</Link>
              <Link to="/dashboard" className="py-2 hover:text-accent transition-colors">Dashboard</Link>
              <div className="flex gap-sm mt-4 pt-4 border-t border-brand-light">
                <Link to="/login" className="btn btn-secondary text-sm flex-1 justify-center">Login</Link>
                <Link to="/demo" className="btn btn-warning text-sm flex-1 justify-center">Demo</Link>
              </div>
            </div>
          </div>
        )}
      </div>
    </nav>
  );
}

export default Navbar;
