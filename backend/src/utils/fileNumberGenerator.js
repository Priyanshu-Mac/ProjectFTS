const moment = require('moment');
const { DailyCounter } = require('../models');
const { sequelize } = require('../config/database');

class FileNumberGenerator {
  /**
   * Generate unique file number in format ACC-YYYYMMDD-XX
   * @returns {Promise<string>}
   */
  static async generateFileNumber() {
    const today = moment().format('YYYY-MM-DD');
    const dateString = moment().format('YYYYMMDD');
    
    // Use transaction to ensure atomicity
    const transaction = await sequelize.transaction();
    
    try {
      // Find or create today's counter
      const [counter, created] = await DailyCounter.findOrCreate({
        where: { date: today },
        defaults: { date: today, counter: 0 },
        transaction
      });
      
      // Increment counter
      counter.counter += 1;
      await counter.save({ transaction });
      
      // Generate file number with zero-padded counter
      const paddedCounter = counter.counter.toString().padStart(2, '0');
      const fileNumber = `ACC-${dateString}-${paddedCounter}`;
      
      await transaction.commit();
      return fileNumber;
      
    } catch (error) {
      await transaction.rollback();
      throw new Error(`Failed to generate file number: ${error.message}`);
    }
  }

  /**
   * Validate file number format
   * @param {string} fileNumber 
   * @returns {boolean}
   */
  static validateFileNumber(fileNumber) {
    const pattern = /^ACC-\d{8}-\d{2}$/;
    return pattern.test(fileNumber);
  }

  /**
   * Extract date from file number
   * @param {string} fileNumber 
   * @returns {string|null} Date in YYYY-MM-DD format
   */
  static extractDateFromFileNumber(fileNumber) {
    if (!this.validateFileNumber(fileNumber)) {
      return null;
    }
    
    const dateString = fileNumber.split('-')[1];
    const year = dateString.substring(0, 4);
    const month = dateString.substring(4, 6);
    const day = dateString.substring(6, 8);
    
    return `${year}-${month}-${day}`;
  }

  /**
   * Get next expected file number for today (for preview)
   * @returns {Promise<string>}
   */
  static async getNextFileNumber() {
    const today = moment().format('YYYY-MM-DD');
    const dateString = moment().format('YYYYMMDD');
    
    const counter = await DailyCounter.findOne({
      where: { date: today }
    });
    
    const nextCounter = counter ? counter.counter + 1 : 1;
    const paddedCounter = nextCounter.toString().padStart(2, '0');
    
    return `ACC-${dateString}-${paddedCounter}`;
  }
}

module.exports = FileNumberGenerator;