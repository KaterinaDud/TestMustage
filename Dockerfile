
# -------- 1) deps: ставимо ВСІ залежності (включно з dev) --------
FROM node:20-alpine AS deps
WORKDIR /app
COPY package*.json ./
# ВАЖЛИВО: тут НЕ обрізаємо dev-залежності, інакше не буде tsc/nest
RUN npm ci

# -------- 2) build: збираємо dist --------
FROM node:20-alpine AS build
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
# має працювати "npm run build" (nest build або tsc -p ...)
RUN npm run build

# -------- 3) prod: мінімальний образ для запуску --------
FROM node:20-alpine AS prod
WORKDIR /app
ENV NODE_ENV=production

# тільки рантайм-залежності (без dev)
COPY package*.json ./
RUN npm ci --omit=dev

# додаємо зібраний код
COPY --from=build /app/dist ./dist

# безпечний користувач
RUN addgroup -S appgroup && adduser -S appuser -G appgroup \
  && chown -R appuser:appgroup /app
USER appuser

# порт застосунку
EXPOSE 3000

# простий healthcheck (Node 20 має вбудований fetch)
HEALTHCHECK --interval=15s --timeout=3s --start-period=20s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:3000/redis').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "dist/main.js"]

