import { BrowserRouter as Router, Routes, Route, Navigate } from 'react-router-dom';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { Toaster } from 'react-hot-toast';

// Components
import Layout from './components/common/Layout';
import ProtectedRoute from './components/common/ProtectedRoute';

// Pages
import LoginPage from './pages/LoginPage';
import DashboardPage from './pages/DashboardPage';
import FileIntakePage from './pages/FileIntakePage';
import FileSearchPage from './pages/FileSearchPage';
import FileDetailPage from './pages/FileDetailPage';
import MoveFilePage from './pages/MoveFilePage';
import AuditLogsPage from './pages/AuditLogsPage';
import COFReviewPage from './pages/COFReviewPage';
import OfficerKanbanPage from './pages/OfficerKanbanPage';
import ReportsPage from './pages/ReportsPage';
import AdminDashboardPage from './pages/AdminDashboardPage';

// Services
import { authService } from './services/authService';

// Create a client
const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      retry: 1,
      refetchOnWindowFocus: false,
    },
  },
});

function App() {
  return (
    <QueryClientProvider client={queryClient}>
      <Router>
        <div className="App">
          <Routes>
            {/* Public Routes */}
            <Route path="/login" element={<LoginPage />} />
            
            {/* Protected Routes */}
            <Route
              path="/"
              element={
                <ProtectedRoute>
                  <Layout>
                    <DashboardPage />
                  </Layout>
                </ProtectedRoute>
              }
            />

            {/* Admin Dashboard - Admin only */}
            <Route
              path="/admin"
              element={
                <ProtectedRoute allowedRoles={['admin']}>
                  <Layout>
                    <AdminDashboardPage />
                  </Layout>
                </ProtectedRoute>
              }
            />
            
            {/* File Intake - Clerk, COF and Admin */}
            <Route
              path="/file-intake"
              element={
                <ProtectedRoute allowedRoles={['clerk', 'cof', 'admin']}>
                  <Layout>
                    <FileIntakePage />
                  </Layout>
                </ProtectedRoute>
              }
            />
            

            {/* Move File - Officers and above */}
            <Route
              path="/move-file"
              element={
                <ProtectedRoute allowedRoles={['accounts_officer', 'cof', 'admin']}>
                  <Layout>
                    <MoveFilePage />
                  </Layout>
                </ProtectedRoute>
              }
            />
            
            {/* File Search - All roles */}
            <Route
              path="/file-search"
              element={
                <ProtectedRoute>
                  <Layout>
                    <FileSearchPage />
                  </Layout>
                </ProtectedRoute>
              }
            />

            {/* File detail (public if token provided, or protected) */}
            <Route path="/files/:id" element={<FileDetailPage />} />
            
            {/* COF Review - COF and Admin only */}
            <Route
              path="/cof-review"
              element={
                <ProtectedRoute allowedRoles={['cof', 'admin']}>
                  <Layout>
                    <COFReviewPage />
                  </Layout>
                </ProtectedRoute>
              }
            />

            {/* Officer Kanban - Officers, COF and Admin */}
            <Route
              path="/kanban"
              element={
                <ProtectedRoute allowedRoles={['accounts_officer','cof','admin']}>
                  <Layout>
                    <OfficerKanbanPage />
                  </Layout>
                </ProtectedRoute>
              }
            />
            
            {/* Analytics - COF and Admin only */}
            <Route
              path="/analytics"
              element={
                <ProtectedRoute allowedRoles={['cof', 'admin']}>
                  <Layout>
                    <div className="text-center py-12">
                      <h2 className="text-2xl font-bold text-gray-900">Analytics</h2>
                      <p className="text-gray-600 mt-2">Coming soon...</p>
                    </div>
                  </Layout>
                </ProtectedRoute>
              }
            />

            {/* Reports - COF and Admin only */}
            <Route
              path="/reports"
              element={
                <ProtectedRoute allowedRoles={['cof','admin']}>
                  <Layout>
                    <ReportsPage />
                  </Layout>
                </ProtectedRoute>
              }
            />

            {/* Audit Logs - COF and Admin only */}
            <Route
              path="/audit-logs"
              element={
                <ProtectedRoute allowedRoles={['cof', 'admin']}>
                  <Layout>
                    <AuditLogsPage />
                  </Layout>
                </ProtectedRoute>
              }
            />
            
            {/* Master Data - Admin only */}
            <Route
              path="/master-data"
              element={
                <ProtectedRoute allowedRoles={['admin']}>
                  <Layout>
                    <div className="text-center py-12">
                      <h2 className="text-2xl font-bold text-gray-900">Master Data</h2>
                      <p className="text-gray-600 mt-2">Coming soon...</p>
                    </div>
                  </Layout>
                </ProtectedRoute>
              }
            />
            
            {/* Catch all route */}
            <Route 
              path="*" 
              element={
                authService.isAuthenticated() ? (
                  <Navigate to="/" replace />
                ) : (
                  <Navigate to="/login" replace />
                )
              } 
            />
          </Routes>
          
          {/* Toast notifications */}
          <Toaster
            position="top-right"
            toastOptions={{
              duration: 4000,
              style: {
                background: '#363636',
                color: '#fff',
              },
              success: {
                style: {
                  background: '#10b981',
                },
              },
              error: {
                style: {
                  background: '#ef4444',
                },
              },
            }}
          />
        </div>
      </Router>
    </QueryClientProvider>
  );
}

export default App;
