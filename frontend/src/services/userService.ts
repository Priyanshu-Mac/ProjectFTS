import api from './api';

export interface UserDto {
  id: number;
  username: string;
  name: string;
  role: string;
  office_id?: number | null;
  email?: string | null;
}

export const userService = {
  async list(params?: { page?: number; limit?: number; q?: string }) {
    const res = await api.get('/users', { params });
    return res.data;
  },
  async create(payload: { username: string; name: string; role: 'Clerk'|'AccountsOfficer'|'COF'|'Admin'; password: string; office_id?: number; email?: string }) {
    const res = await api.post('/users', payload);
    return res.data as UserDto;
  },
  async update(id: number, payload: Partial<{ name: string; role: 'Clerk'|'AccountsOfficer'|'COF'|'Admin'; office_id: number|null; email: string|null }>) {
    const res = await api.patch(`/users/${id}`, payload);
    return res.data as UserDto;
  },
  async resetPassword(id: number, password: string) {
    const res = await api.post(`/users/${id}/password`, { password });
    return res.data;
  }
};
