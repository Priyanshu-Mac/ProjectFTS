import api from './api';

export interface User {
  id: number;
  username: string;
  name: string;
  // server may return additional optional fields; keep them optional on the frontend
  role?: 'clerk' | 'accounts_officer' | 'cof' | 'admin';
  office?: string;
  office_id?: number | null;
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
  // Normalize various server role strings to frontend canonical slugs
  _normalizeRole(role: any): 'clerk' | 'accounts_officer' | 'cof' | 'admin' | undefined {
    if (!role) return undefined;
    const r = String(role).toLowerCase();
    if (r === 'clerk') return 'clerk';
    if (r === 'accounts_officer' || r === 'accountsofficer' || r === 'accounts officer') return 'accounts_officer';
    if (r === 'cof') return 'cof';
    if (r === 'admin' || r === 'administrator') return 'admin';
    return r as any;
  },

  async login(credentials: LoginCredentials): Promise<LoginResponse> {
    const response = await api.post('/auth/login', credentials);
    // New API returns { token, user } on success
    const data: LoginResponse = response.data;
    if (data?.token) {
      // Normalize role casing (server may return 'Clerk' vs 'clerk')
      const normRole = authService._normalizeRole((data.user as any).role);
      const user = { ...data.user, role: normRole } as User;
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
    if (!userData) return null;
    try {
      const parsed = JSON.parse(userData);
      const normRole = authService._normalizeRole(parsed?.role);
      if (normRole && normRole !== parsed?.role) {
        const updated = { ...parsed, role: normRole };
        localStorage.setItem('user_data', JSON.stringify(updated));
        return updated;
      }
      return parsed;
    } catch {
      return null;
    }
  },

  isAuthenticated(): boolean {
    return !!localStorage.getItem('auth_token');
  }
};