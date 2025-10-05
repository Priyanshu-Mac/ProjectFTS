# Backend Dockerfile (Node + TypeScript)
# Multi-stage: build -> runtime

FROM node:20-alpine AS build
WORKDIR /app

# Install dependencies
COPY package.json ./
# Use npm install since lockfile may not exist
RUN npm install

# Copy source and build
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

FROM node:20-alpine AS runtime
WORKDIR /app
ENV NODE_ENV=production

# Install production dependencies only
COPY package.json ./
RUN npm install --omit=dev

# Copy built app
COPY --from=build /app/dist ./dist

EXPOSE 3000
CMD ["node", "dist/index.js"]

# A lightweight image for running migrations using psql (multi-target)
FROM alpine:3.20 AS migrate
RUN apk add --no-cache postgresql-client bash
WORKDIR /app
COPY scripts/apply-migrations.sh /app/apply-migrations.sh
RUN chmod +x /app/apply-migrations.sh

