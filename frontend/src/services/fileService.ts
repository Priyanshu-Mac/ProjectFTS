import api from './api';

export const fileService = {
  async getNextFileNumber() {
    const response = await api.get('/files/next-number');
    return response.data;
  },

  async createFile(fileData) {
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

  async getFile(id) {
    const response = await api.get(`/files/${id}`);
    return response.data;
  },

  async moveFile(id, moveData) {
    const response = await api.post(`/files/${id}/move`, moveData);
    return response.data;
  }
};