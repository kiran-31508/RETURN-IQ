import dotenv from 'dotenv';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Explicitly ensure backend root .env is loaded regardless of caller working directory
dotenv.config({ path: path.resolve(__dirname, '../.env') });

import express from 'express';
import cors from 'cors';

import healthRoutes from './routes/health.js';
import returnsRoutes from './routes/returns.js';
import evaluateRoutes from './routes/evaluate.js';
import plansRoutes from './routes/plans.js';
import analyticsRoutes from './routes/analytics.js';
import { getSupabaseClient } from './supabase.js';
import { createReturnsIntakeRouter } from './routes/returns-intake.js';

const app = express();
const PORT = process.env.PORT || 5000;

// Configure CORS for local development (supports Vite port 5173 and Next.js port 3000)
const allowedOrigins = (process.env.ALLOWED_ORIGINS || 'http://localhost:3000,http://localhost:5173')
  .split(',')
  .map((origin) => origin.trim())
  .filter(Boolean);

app.use(
  cors({
    origin: (origin, callback) => {
      // Allow requests with no origin (e.g. local CLI curl or server-to-server health checks).
      // Note: Absence of an Origin header does NOT imply authentication or authorization.
      if (!origin) {
        return callback(null, true);
      }
      // Strictly allow only origins explicitly listed in ALLOWED_ORIGINS
      if (allowedOrigins.includes(origin)) {
        return callback(null, true);
      }
      // Explicitly reject unlisted origins
      return callback(new Error('Origin not allowed by CORS'));
    },
    methods: ['GET', 'POST', 'PATCH', 'OPTIONS'],
    allowedHeaders: ['Content-Type', 'Authorization'],
  })
);

app.use(express.json());

// Dynamic client adapter to safely reuse the existing Supabase client singleton
const existingSupabaseClient = new Proxy({}, {
  get(_target, prop) {
    const client = getSupabaseClient();
    if (!client) {
      if (prop === 'from') {
        return () => {
          throw new Error('Supabase client is not configured');
        };
      }
      return undefined;
    }
    const val = client[prop];
    return typeof val === 'function' ? val.bind(client) : val;
  },
  has(_target, prop) {
    const client = getSupabaseClient();
    return client ? prop in client : prop === 'from';
  },
});

// Mount API routes
app.use('/api/health', healthRoutes);
app.use('/api/returns', returnsRoutes);
app.use('/api/returns', createReturnsIntakeRouter(existingSupabaseClient));
app.use('/api/routes/evaluate', evaluateRoutes);
app.use('/api/plans', plansRoutes);
app.use('/api/analytics', analyticsRoutes);

// 404 handler for unknown routes
app.use((req, res) => {
  res.status(404).json({
    error: 'Endpoint not found',
    path: req.originalUrl,
  });
});

// Centralized error handling middleware
app.use((err, req, res, next) => {
  // Handle CORS rejection errors
  if (err.message === 'Origin not allowed by CORS') {
    return res.status(403).json({
      error: 'Forbidden',
      message: 'Origin not allowed by CORS policy',
    });
  }

  console.error('Unhandled server error:', err);

  // Handle malformed JSON body
  if (err instanceof SyntaxError && err.status === 400 && 'body' in err) {
    return res.status(400).json({
      error: 'Malformed JSON payload',
    });
  }

  res.status(500).json({
    error: 'Internal server error',
    message: err.message || 'An unexpected error occurred.',
  });
});

// Start server if executed directly
if (process.env.NODE_ENV !== 'test') {
  app.listen(PORT, () => {
    console.log(`===============================================`);
    console.log(` ReturnIQ Backend API running on port ${PORT}`);
    console.log(` Health check: http://localhost:${PORT}/api/health`);
    console.log(`===============================================`);
  });
}

export default app;
