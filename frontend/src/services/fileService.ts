import api from './api';

export const fileService = {
  async getNextFileNumber() {
    const response = await api.get('/files/next-number');
    return response.data;
  },

  async createFile(fileData: Record<string, any>) {
    const response = await api.post('/files', fileData);
    return response.data;
  },

  async searchFiles(params = {}) {
    const response = await api.get('/files/search', { params });
    return response.data;
  },

  async listFiles(params = {}) {
    // Use the main list endpoint which supports holder and pagination
    const response = await api.get('/files', { params });
    return response.data;
  },

  async getFile(id: number) {
    const response = await api.get(`/files/${id}`);
    return response.data;
  },

  async createShareToken(id: number, force?: boolean) {
    const response = await api.post(`/files/${id}/token${force ? '?force=true' : ''}`);
    return response.data;
  },

  async getShareToken(id: number) {
    const response = await api.get(`/files/${id}/token`);
    return response.data;
  },

  async getFileByToken(token: string) {
    const response = await api.get(`/files/shared/files/${token}`);
    return response.data;
  },

  // Movement/events
  async addEvent(id: number, data: { to_user_id?: number; action_type: string; remarks?: string }) {
    const response = await api.post(`/files/${id}/events`, data);
    return response.data;
  },

  async listEvents(id: number) {
    const response = await api.get(`/files/${id}/events`);
    return response.data;
  },

  async listEventsByToken(token: string) {
    const response = await api.get(`/files/shared/events/${token}`);
    return response.data;
  },

  async getFileByIdAndToken(id: number, token: string) {
    const response = await api.get(`/files/shared/${id}/${token}`);
    return response.data;
  },

  async listEventsByIdAndToken(id: number, token: string) {
    const response = await api.get(`/files/shared/${id}/${token}/events`);
    return response.data;
  },

  async updateFile(id: number, data: Record<string, any>) {
    const response = await api.put(`/files/${id}`, data);
    return response.data;
  },

  async submitSlaReason(id: number, reason: string) {
    const response = await api.post(`/files/${id}/sla/reason`, { reason });
    return response.data;
  }
};