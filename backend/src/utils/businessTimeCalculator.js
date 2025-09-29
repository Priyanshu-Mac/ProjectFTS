const moment = require('moment');
const { Holiday } = require('../models');

class BusinessTimeCalculator {
  constructor() {
    this.workingHours = {
      start: process.env.WORKING_HOURS_START || '09:00',
      end: process.env.WORKING_HOURS_END || '17:30'
    };
    this.workingDays = [1, 2, 3, 4, 5]; // Monday to Friday
  }

  /**
   * Calculate business minutes between two dates
   * @param {Date} startDate 
   * @param {Date} endDate 
   * @returns {Promise<number>} Business minutes
   */
  async calculateBusinessMinutes(startDate, endDate) {
    if (!startDate || !endDate) return 0;
    if (endDate <= startDate) return 0;

    const start = moment(startDate);
    const end = moment(endDate);
    let totalMinutes = 0;

    // Get holidays in the date range
    const holidays = await Holiday.findAll({
      where: {
        date: {
          [require('sequelize').Op.between]: [start.format('YYYY-MM-DD'), end.format('YYYY-MM-DD')]
        }
      }
    });
    
    const holidayDates = new Set(holidays.map(h => h.date));

    // Iterate through each day
    const current = start.clone();
    while (current.isSameOrBefore(end, 'day')) {
      // Skip weekends and holidays
      if (this.workingDays.includes(current.day()) && 
          !holidayDates.has(current.format('YYYY-MM-DD'))) {
        
        const dayStart = current.clone().startOf('day').add(this.parseTime(this.workingHours.start));
        const dayEnd = current.clone().startOf('day').add(this.parseTime(this.workingHours.end));
        
        let periodStart = moment.max(start, dayStart);
        let periodEnd = moment.min(end, dayEnd);
        
        if (periodEnd.isAfter(periodStart)) {
          totalMinutes += periodEnd.diff(periodStart, 'minutes');
        }
      }
      
      current.add(1, 'day');
    }

    return totalMinutes;
  }

  /**
   * Add business minutes to a date
   * @param {Date} startDate 
   * @param {number} minutes 
   * @returns {Promise<Date>}
   */
  async addBusinessMinutes(startDate, minutes) {
    if (minutes <= 0) return startDate;

    const holidays = await Holiday.findAll({
      where: {
        date: {
          [require('sequelize').Op.gte]: moment(startDate).format('YYYY-MM-DD')
        }
      },
      limit: 100 // Reasonable limit for future holidays
    });
    
    const holidayDates = new Set(holidays.map(h => h.date));
    
    let current = moment(startDate);
    let remainingMinutes = minutes;

    while (remainingMinutes > 0) {
      // Skip to next working day if current day is weekend or holiday
      while (!this.workingDays.includes(current.day()) || 
             holidayDates.has(current.format('YYYY-MM-DD'))) {
        current.add(1, 'day').startOf('day');
      }

      const dayStart = current.clone().startOf('day').add(this.parseTime(this.workingHours.start));
      const dayEnd = current.clone().startOf('day').add(this.parseTime(this.workingHours.end));
      
      // If current time is before working hours, move to start of working hours
      if (current.isBefore(dayStart)) {
        current = dayStart.clone();
      }
      
      // If current time is after working hours, move to next working day
      if (current.isAfter(dayEnd)) {
        current.add(1, 'day').startOf('day');
        continue;
      }

      // Calculate remaining working minutes in current day
      const remainingInDay = dayEnd.diff(current, 'minutes');
      
      if (remainingMinutes <= remainingInDay) {
        // Can finish within current day
        current.add(remainingMinutes, 'minutes');
        remainingMinutes = 0;
      } else {
        // Move to next working day
        remainingMinutes -= remainingInDay;
        current.add(1, 'day').startOf('day');
      }
    }

    return current.toDate();
  }

  /**
   * Parse time string to moment duration
   * @param {string} timeStr - Format: "HH:MM"
   * @returns {object} Moment duration
   */
  parseTime(timeStr) {
    const [hours, minutes] = timeStr.split(':').map(Number);
    return moment.duration({ hours, minutes });
  }

  /**
   * Check if a date falls within working hours
   * @param {Date} date 
   * @returns {boolean}
   */
  isWorkingTime(date) {
    const moment_date = moment(date);
    
    // Check if it's a working day
    if (!this.workingDays.includes(moment_date.day())) {
      return false;
    }
    
    const dayStart = moment_date.clone().startOf('day').add(this.parseTime(this.workingHours.start));
    const dayEnd = moment_date.clone().startOf('day').add(this.parseTime(this.workingHours.end));
    
    return moment_date.isBetween(dayStart, dayEnd, null, '[]');
  }
}

module.exports = BusinessTimeCalculator;