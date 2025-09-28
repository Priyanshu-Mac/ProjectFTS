import { Link } from "react-router-dom";

function CTASection() {
  return (
    <section className="py-20 bg-brand text-white">
      <div className="container text-center">
        <h2 className="text-3xl font-bold mb-4">
          Ready to Transform Your File Management?
        </h2>
        <p className="text-xl mb-8 opacity-90 max-w-2xl mx-auto">
          Join hundreds of government organizations already using GovFiles 
          to streamline their operations and improve efficiency.
        </p>
        <div className="flex flex-col sm:flex-row gap-4 justify-center mb-12">
          <Link to="/file-intake" className="btn btn-warning px-8 py-4 text-lg font-semibold">
            Start Free Trial
          </Link>
          <button className="btn btn-secondary px-8 py-4 text-lg">
            Schedule Demo
          </button>
          <button className="btn btn-secondary px-8 py-4 text-lg">
            Contact Sales
          </button>
        </div>
        
        <div className="grid md:grid-cols-3 gap-8 max-w-4xl mx-auto">
          <div className="text-center">
            <div className="text-2xl mb-2">🚀</div>
            <h3 className="font-bold mb-2">Quick Setup</h3>
            <p className="text-sm opacity-80">Get started in under 30 minutes with our guided setup process</p>
          </div>
          <div className="text-center">
            <div className="text-2xl mb-2">🛡️</div>
            <h3 className="font-bold mb-2">Government Ready</h3>
            <p className="text-sm opacity-80">Built with security and compliance standards for government use</p>
          </div>
          <div className="text-center">
            <div className="text-2xl mb-2">📞</div>
            <h3 className="font-bold mb-2">Expert Support</h3>
            <p className="text-sm opacity-80">24/7 technical support and training for your team</p>
          </div>
        </div>
      </div>
    </section>
  );
}

export default CTASection;