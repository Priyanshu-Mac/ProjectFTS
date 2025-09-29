import api from './api';

export interface User {
  id: number;
  username: string;
  name: string;
  role: 'clerk' | 'accounts_officer' | 'cof' | 'admin';
  office: string;
  isActive: boolean;
}

export interface LoginCredentials {
  username: string;
  password: string;
}

export interface ChangePasswordData {
  currentPassword: string;
  newPassword: string;
}

export interface AuthResponse {
  success: boolean;
  message: string;
  data?: {
    token: string;
    user: User;
  };
}

export const authService = {
  async login(credentials: LoginCredentials): Promise<AuthResponse> {
    const response = await api.post('/auth/login', credentials);
    if (response.data.success) {
      localStorage.setItem('auth_token', response.data.data.token);
      localStorage.setItem('user_data', JSON.stringify(response.data.data.user));
    }
    return response.data;
  },

  async getProfile(): Promise<AuthResponse> {
    const response = await api.get('/auth/profile');
    return response.data;
  },

  async changePassword(passwordData: ChangePasswordData): Promise<AuthResponse> {
    const response = await api.post('/auth/change-password', passwordData);
    return response.data;
  },

  logout(): void {
    localStorage.removeItem('auth_token');
    localStorage.removeItem('user_data');
    window.location.href = '/login';
  },

  getCurrentUser(): User | null {
    const userData = localStorage.getItem('user_data');
    return userData ? JSON.parse(userData) : null;
  },

  isAuthenticated(): boolean {
    return !!localStorage.getItem('auth_token');
  }
};