# BeStrong sample application image.
# Built locally by scripts/deploy.ps1 (ACR Tasks are blocked in the sandbox)
# and pushed to acrbestrong<suffix>.azurecr.io/bestrong-sample:<tag>.
FROM node:20-alpine

WORKDIR /app

# Install production dependencies first to maximize layer caching.
# npm install (not npm ci): no lock file is committed yet.
COPY package*.json ./
RUN npm install --omit=dev

# Copy application source.
COPY server.js ./

EXPOSE 8080

# Run as the unprivileged user provided by the base image.
USER node

CMD ["node", "server.js"]
