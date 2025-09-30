import api from './api';

export interface User {
  id: number;
  username: string;
  name: string;
  // server may return additional optional fields; keep them optional on the frontend
  role?: 'clerk' | 'accounts_officer' | 'cof' | 'admin';
  office?: string;
  isActive?: boolean;
}

export interface LoginCredentials {
  username: string;
  password: string;
}

export interface ChangePasswordData {
  currentPassword: string;
  newPassword: string;
}

// The backend login response is { token: string, user: User } on success.
export interface LoginResponse {
  token: string;
  user: User;
}

export const authService = {
  async login(credentials: LoginCredentials): Promise<LoginResponse> {
    const response = await api.post('/auth/login', credentials);
    // New API returns { token, user } on success
    const data: LoginResponse = response.data;
    if (data?.token) {
      // Normalize role casing (server may return 'Clerk' vs 'clerk')
      const user = { ...data.user, role: typeof data.user.role === 'string' ? data.user.role.toLowerCase() : data.user.role };
      localStorage.setItem('auth_token', data.token);
      localStorage.setItem('user_data', JSON.stringify(user));
    }
    return data;
  },

  async getProfile(): Promise<User> {
    const response = await api.get('/auth/profile');
    // Be flexible: some backends may return { user } or the user object directly
    return response.data?.user ?? response.data;
  },

  async changePassword(passwordData: ChangePasswordData): Promise<any> {
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