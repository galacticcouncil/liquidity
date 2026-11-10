# Builds the keeper and runs it; every setting comes from the environment (see README.md).
# Build from this folder: docker build -t galacticcouncil/bandhook-keeper:latest .
FROM node:23-slim AS build
WORKDIR /app
COPY package.json package-lock.json tsconfig.json tsconfig.build.json ./
RUN npm ci
COPY src/ ./src/
RUN npm run build

FROM node:23-slim
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --omit=optional
COPY --from=build /app/dist/ ./dist/
USER node
CMD ["node", "dist/main.js"]
