# Backend — Express API

## Stack

| Layer | Technology |
| --- | --- |
| Runtime | Node 22 |
| Framework | Express 4 |
| Database | MongoDB 8.0 (via Mongoose 6) |
| Dev runner | Nodemon |

## Structure

```
backend/
├── Dockerfile               # Production image (node:22-bookworm-slim)
├── Dockerfile-local          # Local dev image (same as Dockerfile)
├── server.js                 # Entry point
├── config/                   # App config
├── db/                       # Mongoose connection (retry logic)
├── models/todos/             # Todo model
├── routes/                   # API routes
├── utils/helpers/            # Logger, response helpers
└── logs/                     # App log output
```

## API routes

Base path: `/api`

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
