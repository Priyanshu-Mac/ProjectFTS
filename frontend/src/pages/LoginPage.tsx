import React, { useState } from 'react';
import { useNavigate, Navigate } from 'react-router-dom';
import { useForm } from 'react-hook-form';
import type { SubmitHandler } from 'react-hook-form';
import { toast } from 'react-hot-toast';
import { Building, User, Lock, Eye, EyeOff } from 'lucide-react';
import { authService } from '../services/authService';
import type { LoginCredentials } from '../services/authService';
import LoadingSpinner from '../components/common/LoadingSpinner';

interface DefaultCredential {
  role: string;
  username: string;
  password: string;
}

const LoginPage: React.FC = () => {
  const navigate = useNavigate();
  const [showPassword, setShowPassword] = useState<boolean>(false);
  const [isLoading, setIsLoading] = useState<boolean>(false);
  
  const { register, handleSubmit, formState: { errors } } = useForm<LoginCredentials>();

  // Redirect if already authenticated
  if (authService.isAuthenticated()) {
    return <Navigate to="/" replace />;
  }

  const onSubmit: SubmitHandler<LoginCredentials> = async (data) => {
    setIsLoading(true);
    try {
      await authService.login(data);
      toast.success('Login successful!');
      navigate('/', { replace: true });
    } catch (error: any) {
      const message = error?.response?.data?.message || 'Login failed. Please try again.';
      toast.error(message);
    } finally {
      setIsLoading(false);
    }
  };

  const defaultCredentials: DefaultCredential[] = [
    { role: 'Admin', username: 'admin', password: 'admin123' },
    { role: 'COF', username: 'cof.accounts', password: 'cof123' },
    { role: 'Clerk', username: 'clerk.intake', password: 'clerk123' },
    { role: 'AO', username: 'ao.ramesh', password: 'ao123' }
  ];

  return (
    <div className="min-h-screen bg-gradient-to-br from-blue-50 to-indigo-100 flex items-center justify-center py-12 px-4 sm:px-6 lg:px-8">
      <div className="max-w-md w-full space-y-8">
        {/* Header */}
        <div className="text-center">
          <div className="mx-auto h-16 w-16 bg-primary-600 rounded-full flex items-center justify-center">
            <Building className="h-8 w-8 text-white" />
          </div>
          <h2 className="mt-6 text-3xl font-bold text-gray-900">
            Government File Management
          </h2>
          <p className="mt-2 text-sm text-gray-600">
            Accounts Department - Sign in to your account
          </p>
        </div>

        {/* Login Form */}
        <div className="bg-white py-8 px-6 shadow-lg rounded-lg border border-gray-200">
          <form className="space-y-6" onSubmit={handleSubmit(onSubmit)}>
            <div>
              <label htmlFor="username" className="form-label">
                Username or Email
              </label>
              <div className="relative">
                <div className="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none">
                  <User className="h-5 w-5 text-gray-400" />
                </div>
                <input
                  {...register('username', { 
                    required: 'Username is required' 
                  })}
                  type="text"
                  className="form-input pl-10"
                  placeholder="Enter your username"
                  disabled={isLoading}
                />
              </div>
              {errors.username && (
                <p className="mt-1 text-sm text-red-600">{errors.username.message}</p>
              )}
            </div>

            <div>
              <label htmlFor="password" className="form-label">
                Password
              </label>
              <div className="relative">
                <div className="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none">
                  <Lock className="h-5 w-5 text-gray-400" />
                </div>
                <input
                  {...register('password', { 
                    required: 'Password is required' 
                  })}
                  type={showPassword ? 'text' : 'password'}
                  className="form-input pl-10 pr-10"
                  placeholder="Enter your password"
                  disabled={isLoading}
                />
                <button
                  type="button"
                  className="absolute inset-y-0 right-0 pr-3 flex items-center"
                  onClick={() => setShowPassword(!showPassword)}
                  disabled={isLoading}
                >
                  {showPassword ? (
                    <EyeOff className="h-5 w-5 text-gray-400" />
                  ) : (
                    <Eye className="h-5 w-5 text-gray-400" />
                  )}
                </button>
              </div>
              {errors.password && (
                <p className="mt-1 text-sm text-red-600">{errors.password.message}</p>
              )}
            </div>

            <div>
              <button
                type="submit"
                disabled={isLoading}
                className="w-full btn btn-primary"
              >
                {isLoading ? <LoadingSpinner size="sm" text="Signing in..." /> : 'Sign In'}
              </button>
            </div>
          </form>
        </div>

        {/* Default Credentials */}
        <div className="bg-yellow-50 border border-yellow-200 rounded-lg p-4">
          <h3 className="text-sm font-medium text-yellow-800 mb-2">
            Default Login Credentials:
          </h3>
          <div className="space-y-1 text-xs text-yellow-700">
            {defaultCredentials.map((cred, index) => (
              <div key={index} className="flex justify-between">
                <span className="font-medium">{cred.role}:</span>
                <span>{cred.username} / {cred.password}</span>
              </div>
            ))}
          </div>
        </div>

        {/* Footer */}
        <div className="text-center text-xs text-gray-500">
          <p>Government of India - Accounts Department</p>
          <p className="mt-1">For authorized personnel only</p>
        </div>
      </div>
    </div>
  );
};

export default LoginPage;