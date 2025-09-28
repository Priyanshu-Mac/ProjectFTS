import { Link } from "react-router-dom";

function HeroSection() {
  return (
    <section className="bg-brand text-white py-20">
      <div className="max-w-7xl mx-auto px-4 text-center">
        <h1 className="text-4xl md:text-5xl font-bold mb-4">GovFiles Management System</h1>
        <p className="text-lg md:text-xl mb-8">Track, manage, and dispatch files efficiently across government offices.</p>
        <Link
          to="/file-intake"
          className="bg-accent hover:bg-accent-dark text-gray-900 font-semibold py-3 px-6 rounded-lg transition"
        >
          Start Intake
        </Link>
      </div>
    </section>
  );
}

export default HeroSection;
