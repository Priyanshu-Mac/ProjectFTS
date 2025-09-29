const fetch = require('node-fetch');

async function testLogin() {
  try {
    const response = await fetch('http://localhost:5000/api/auth/login', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        username: 'admin',
        password: 'admin123'
      })
    });

    const data = await response.json();
    console.log('Status:', response.status);
    console.log('Response:', JSON.stringify(data, null, 2));
    
    if (response.status === 401) {
      console.log('\n🔍 Testing password directly...');
      // Let's also test the password verification manually
      const bcrypt = require('bcrypt');
      const testPassword = 'admin123';
      const hashedPassword = '$2b$10$uVqw8fMhcSZ/uP1ipnjhXuhsJOFn8DkAF8S49Qi2SPE9BeufpbPf.';
      
      const isValid = await bcrypt.compare(testPassword, hashedPassword);
      console.log('Password validation result:', isValid);
    }
  } catch (error) {
    console.error('Error:', error.message);
  }
}

testLogin();