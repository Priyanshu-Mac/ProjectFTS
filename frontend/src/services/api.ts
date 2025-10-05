import axios from 'axios';

// Default to the auth server running on localhost:3000. If you deploy or run the API
// on a different origin, set VITE_API_BASE_URL in your .env (e.g. VITE_API_BASE_URL="http://api.example.com").
const API_BASE_URL = import.meta.env.VITE_API_BASE_URL || 'http://localhost:3000';

// Create axios instance
const api = axios.create({
  baseURL: API_BASE_URL,
  timeout: 10000,
  headers: {
    'Content-Type': 'application/json',
  },
});

// Request interceptor to add auth token
api.interceptors.request.use(
  (config) => {
    const token = localStorage.getItem('auth_token');
    if (token) {
      config.headers.Authorization = `Bearer ${token}`;
    }
    return config;
  },
  (error) => {
    return Promise.reject(error);
  }
);

// Response interceptor for error handling
api.interceptors.response.use(
  (response) => response,
  (error) => {
    const status = error?.response?.status;
    const url: string = error?.config?.url || '';
    const hadAuthHeader = !!(error?.config?.headers?.Authorization);
    const isTokenOnlyEndpoint = url.startsWith('/files/shared/') || url.includes('/files/shared/');
    // Only log out for true session/auth failures: 401 responses on requests that used our auth header
    // and are NOT token-only endpoints. Token-only endpoints (QR) should not log the user out.
    if (status === 401 && hadAuthHeader && !isTokenOnlyEndpoint) {
      localStorage.removeItem('auth_token');
      localStorage.removeItem('user_data');
      window.location.href = '/login';
      return; // prevent further handling
    }
    return Promise.reject(error);
  }
);

export default api;