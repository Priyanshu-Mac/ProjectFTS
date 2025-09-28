import { Link } from "react-router-dom";

function Navbar() {
  return (
    <nav className="bg-brand text-white shadow-md">
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
        <div className="flex justify-between h-16 items-center">
          <div className="flex-shrink-0">
            <Link to="/" className="text-xl font-bold">GovFiles</Link>
          </div>
          <div className="hidden md:flex space-x-6">
            <Link to="/" className="hover:text-accent">Home</Link>
            <Link to="/file-intake" className="hover:text-accent">File Intake</Link>
            <Link to="/file-movement" className="hover:text-accent">File Movement</Link>
            <Link to="/cof-review" className="hover:text-accent">COF Review</Link>
            <Link to="/dashboard" className="hover:text-accent">Dashboard</Link>
          </div>
        </div>
      </div>
    </nav>
  );
}

export default Navbar;
