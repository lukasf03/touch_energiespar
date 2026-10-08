# node:sqlite ist ab Node 22.5 eingebaut - darum keine nativen Abhaengigkeiten
# und kein Build-Schritt.
FROM node:22.20-alpine

ENV NODE_ENV=production
WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund && npm cache clean --force

COPY src ./src
COPY public ./public

# Datenbank liegt auf einem Volume, damit sie Updates ueberlebt.
RUN mkdir -p /data && chown -R node:node /data /app
VOLUME ["/data"]

ENV PORT=8080 \
    DB_FILE=/data/walldisplay.db \
    NODE_NO_WARNINGS=1

USER node
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||8080)+'/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "src/index.js"]
