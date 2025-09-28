import { BrowserRouter as Router, Routes, Route } from "react-router-dom";
import Navbar from "./components/Navbar";
import Footer from "./components/Footer";
import LandingPage from "./pages/LandingPage/LandingPage";
import FileIntakePage from "./pages/FileIntake/FileIntakePage";
import FileMovementPage from "./pages/FileMovement/FileMovementPage";
import COFReviewPage from "./pages/COFReview/COFFinalReviewPage";
import DashboardPageComponent from "./dashboard/DashboardPage.tsx";
import NotFound from "./pages/NotFound";

function App() {
  return (
    <Router>
      <Navbar />
      <Routes>
        <Route path="/" element={<LandingPage />} />
        <Route path="/file-intake" element={<FileIntakePage />} />
        <Route path="/file-movement" element={<FileMovementPage />} />
        <Route path="/cof-review" element={<COFReviewPage />} />
        <Route path="/dashboard" element={<DashboardPageComponent />} />
        <Route path="*" element={<NotFound />} />
      </Routes>
      <Footer />
    </Router>
  );
}

export default App;
