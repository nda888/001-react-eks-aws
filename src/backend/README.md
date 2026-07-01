# Backend — Express API

## Stack

| Layer | Technology |
| --- | --- |
| Runtime | Node 22 |
| Framework | Express 4 |
| Database | MongoDB 8.0 (via Mongoose 8) |
| Security | Helmet, express-rate-limit, CORS |
| Dev runner | Nodemon |

## Structure

```
backend/
├── Dockerfile                # Node 22 image running `npm run dev` (Nodemon)
├── Dockerfile-local          # Same as Dockerfile; used by compose.yaml
├── .dockerignore
├── server.js                 # Entry point
├── config/                   # App config (config.js, config.json, messages.js)
├── db/                       # Mongoose connection (retry logic)
├── middleware/               # Auth middleware (requireAuth)
├── models/todos/             # Todo model
├── routes/                   # API routes
├── utils/helpers/            # Logger, response helpers
└── logs/                     # App log output
```

## API routes

Base path: `/api`. All `/api` routes require `Authorization: Bearer <API_TOKEN>`.

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api` | List todos |
| `POST` | `/api/todos` | Create todo (body: `{ "text": "..." }`, max 200 chars) |
| `DELETE` | `/api/todos/:id` | Delete todo |
| `GET` | `/healthz` | Liveness check |

Rate limits (per IP): 60 req/min (list), 20 req/min (create), 30 req/min (delete).

## Environment variables

Required via `.env`:

| Variable | Purpose |
| --- | --- |
| `MONGODB_URI` | MongoDB connection string |
| `API_TOKEN` | Bearer token required by `/api` routes |
| `CORS_ORIGINS` | (optional) Comma-separated allowed origins, defaults to `http://localhost:3000` |
| `PORT` | (optional) Server port, defaults to `3000` |

## Local development

```bash
npm install
npm run dev      # Nodemon with hot reload
```

## Production

```bash
npm start        # node server.js
```

## Docker

```bash
docker build -t backend .
docker run -p 3000:3000 --env-file .env backend
```

Note: the provided `Dockerfile` runs `npm run dev`; override `CMD` or build a dedicated image for a true production start.
