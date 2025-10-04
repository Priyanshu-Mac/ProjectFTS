import api from './api';

export const masterDataService = {
  async getOffices() {
    const response = await api.get('/master-data/offices');
    return response.data;
  },

  async getCategories() {
    const response = await api.get('/master-data/categories');
    return response.data;
  },

  async getUsers(role: string | null = null) {
    const params: any = role ? { role } : {};
    const response = await api.get('/master-data/users', { params });
    return response.data;
  },

  async getSLAPolicies() {
    const response = await api.get('/master-data/sla-policies');
    return response.data;
  },

  async getConstants() {
    const response = await api.get('/master-data/constants');
    return response.data;
  }
};