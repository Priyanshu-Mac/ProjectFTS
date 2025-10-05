# Frontend Dockerfile (Vite + Nginx)
# Multi-stage: build -> nginx

FROM node:20-alpine AS build
WORKDIR /app

COPY package.json ./
RUN npm install

COPY . .
RUN npm run build

FROM nginx:1.27-alpine AS runtime
WORKDIR /usr/share/nginx/html

# Remove default nginx static content
RUN rm -rf ./*

# Copy built assets
COPY --from=build /app/dist .

# Provide a default nginx conf that supports SPA routing
COPY --from=build /app/nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
