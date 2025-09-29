import api from './api';

export const dashboardService = {
  async getExecutiveDashboard() {
    const response = await api.get('/dashboard/executive');
    return response.data;
  },

  async getOfficerDashboard() {
    const response = await api.get('/dashboard/officer');
    return response.data;
  },

  async getAnalytics(params = {}) {
    const response = await api.get('/dashboard/analytics', { params });
    return response.data;
  }
};