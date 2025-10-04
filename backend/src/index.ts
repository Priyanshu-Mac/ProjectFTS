import dotenv from 'dotenv';
// Load project .env and merge into process.env so project values override global env
const _env = dotenv.config();
if (_env.parsed) {
  // overwrite process.env entries with values from .env
  Object.assign(process.env, _env.parsed);
}
import express from 'express';
import { Request, Response } from 'express';
import cors from 'cors';
import { validateBody } from './middleware/validate';
import { EchoSchema, Echo } from './schemas/echo';
import filesRouter from './routes/files';
import eventsRouter from './routes/events';
import dashboardRouter from './routes/dashboard';
import internalRouter from './routes/internal';
import authRouter from './routes/auth';
import masterDataRouter from './routes/masterData';
import { optionalAuth } from './middleware/auth';
import { logAudit } from './middleware/audit';

const app = express();
// CORS: allow the frontend origin (configurable). Default to http://localhost:5173 for local dev.
const allowedOrigin = process.env.FRONTEND_ORIGIN;
app.use(cors({ origin: allowedOrigin, methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'], credentials: true }));
app.use(express.json());

// optional auth: populates req.user when Authorization: Bearer <token> present
app.use(optionalAuth as any);

app.get('/', (_req: Request, res: Response) => {
  res.json({ message: 'Hello from Express + TypeScript + Zod!' });
});

app.get('/health', async (req: Request, res: Response) => {
  try { await logAudit({ req, action: 'Read', details: { route: 'GET /health' } }); } catch {}
  res.json({ status: 'ok' });
});

app.post('/echo', validateBody(EchoSchema), async (req: Request, res: Response) => {
  const body = (req as any).validatedBody as Echo;
  try { await logAudit({ req, action: 'Read', details: { route: 'POST /echo', body } }); } catch {}
  res.json({ received: body });
});

// API routes
app.use('/files', filesRouter);
app.use('/files/:id/events', eventsRouter);
app.use('/auth', authRouter);
app.use('/dashboards', dashboardRouter);
app.use('/internal', internalRouter);
app.use('/master-data', masterDataRouter);

const PORT = process.env.PORT ? Number(process.env.PORT) : 3000;
const server = app.listen(PORT, () => {
  console.log(`Server listening on http://localhost:${PORT}`);
});

process.on('SIGINT', () => {
  console.log('Shutting down...');
  server.close(() => process.exit(0));
});
