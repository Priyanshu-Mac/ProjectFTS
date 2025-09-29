import dotenv from 'dotenv';
// Load project .env and merge into process.env so project values override global env
const _env = dotenv.config();
if (_env.parsed) {
  // overwrite process.env entries with values from .env
  Object.assign(process.env, _env.parsed);
}
import express from 'express';
import { Request, Response } from 'express';
import { validateBody } from './middleware/validate';
import { EchoSchema, Echo } from './schemas/echo';
import filesRouter from './routes/files';
import eventsRouter from './routes/events';
import dashboardRouter from './routes/dashboard';
import internalRouter from './routes/internal';

const app = express();
app.use(express.json());

app.get('/', (_req: Request, res: Response) => {
  res.json({ message: 'Hello from Express + TypeScript + Zod!' });
});

app.get('/health', (_req: Request, res: Response) => {
  res.json({ status: 'ok' });
});

app.post('/echo', validateBody(EchoSchema), (req: Request, res: Response) => {
  const body = (req as any).validatedBody as Echo;
  res.json({ received: body });
});

// API routes
app.use('/files', filesRouter);
app.use('/files/:id/events', eventsRouter);
app.use('/dashboards', dashboardRouter);
app.use('/internal', internalRouter);

const PORT = process.env.PORT ? Number(process.env.PORT) : 3000;
const server = app.listen(PORT, () => {
  console.log(`Server listening on http://localhost:${PORT}`);
});

process.on('SIGINT', () => {
  console.log('Shutting down...');
  server.close(() => process.exit(0));
});
