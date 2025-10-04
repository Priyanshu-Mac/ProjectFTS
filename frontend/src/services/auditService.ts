import api from './api';

export const auditService = {
  async list(params: { page?: number; limit?: number; user_id?: number; file_id?: number; action_type?: string; q?: string; date_from?: string; date_to?: string } = {}) {
    const response = await api.get('/internal/audit-logs', { params });
    return response.data;
  },
};
