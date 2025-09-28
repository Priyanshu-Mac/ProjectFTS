import { Link } from "react-router-dom";
import { useState } from "react";

function HeroSection() {
  const [isPlaying, setIsPlaying] = useState(false);

  return (
    <section className="bg-brand text-white py-20 relative overflow-hidden">
      <div className="absolute inset-0 bg-gradient-to-br from-brand to-brand-dark opacity-90"></div>
      <div className="container relative z-10">
        <div className="grid lg:grid-cols-2 gap-xl items-center">
          <div className="text-center lg:text-left">
            <h1 className="text-4xl lg:text-5xl font-bold mb-lg leading-tight">
              Digital File Management System
            </h1>
            <p className="text-xl mb-xl opacity-90 leading-relaxed">
              Streamline your accounts department with automated file tracking, 
              SLA monitoring, and seamless workflow management. From intake to dispatch, 
              every file movement is tracked with precision.
            </p>
            <div className="flex flex-col sm:flex-row gap-md justify-center lg:justify-start">
              <Link
                to="/file-intake"
                className="btn btn-warning px-8 py-4 text-lg font-semibold"
              >
                Start File Intake
              </Link>
              <button 
                className="btn btn-secondary px-8 py-4 text-lg"
                onClick={() => setIsPlaying(!isPlaying)}
              >
                {isPlaying ? "⏸️ Pause" : "▶️ Watch Demo"}
              </button>
            </div>
            <div className="flex items-center gap-lg mt-xl justify-center lg:justify-start">
              <div className="text-center">
                <div className="text-2xl font-bold">99.9%</div>
                <div className="text-sm opacity-80">Uptime</div>
              </div>
              <div className="text-center">
                <div className="text-2xl font-bold">24/7</div>
                <div className="text-sm opacity-80">Support</div>
              </div>
              <div className="text-center">
                <div className="text-2xl font-bold">500+</div>
                <div className="text-sm opacity-80">Organizations</div>
              </div>
            </div>
          </div>
          <div className="relative mt-xl lg:mt-0">
            <div className="bg-white/10 backdrop-blur rounded-xl p-8">
              <div className="bg-white rounded-lg p-6 shadow-xl">
                <div className="flex items-center gap-md mb-md">
                  <div className="w-3 h-3 bg-danger rounded-full"></div>
                  <div className="w-3 h-3 bg-warning rounded-full"></div>
                  <div className="w-3 h-3 bg-success rounded-full"></div>
                  <div className="text-gray-600 text-sm ml-auto">GovFiles Dashboard</div>
                </div>
                <div className="text-gray-800">
                  <div className="flex justify-between items-center mb-4">
                    <h3 className="font-bold">File No: ACC-20250928-001</h3>
                    <span className="badge badge-success">On Track</span>
                  </div>
                  <div className="grid grid-cols-2 gap-4 text-sm">
                    <div>
                      <div className="text-gray-500">Subject</div>
                      <div className="font-medium">Budget Approval Request</div>
                    </div>
                    <div>
                      <div className="text-gray-500">Priority</div>
                      <div className="font-medium">Urgent</div>
                    </div>
                    <div>
                      <div className="text-gray-500">Current Holder</div>
                      <div className="font-medium">A. Kumar (Finance)</div>
                    </div>
                    <div>
                      <div className="text-gray-500">SLA Status</div>
                      <div className="font-medium text-success">2d 4h remaining</div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}

export default HeroSection;
