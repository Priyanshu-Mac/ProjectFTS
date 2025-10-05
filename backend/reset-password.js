const bcrypt = require('bcryptjs');

// 1. Choose a new, simple password for the admin user.
const newPassword = 'admin123';

// 2. Define the "salt rounds", which controls the hash strength.
//    The "10" in your database hash ($2b$10$...) means your value is 10.
const saltRounds = 10;

console.log('Generating hash...');

// 3. This function creates the new hash.
bcrypt.hash(newPassword, saltRounds, (err, hash) => {
  if (err) {
    console.error('Error creating hash:', err);
    return;
  }
  console.log('SUCCESS! Here is the new hash for your database:');
  console.log(hash);
});