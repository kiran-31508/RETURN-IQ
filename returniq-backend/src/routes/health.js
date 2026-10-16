import { Router } from 'express';
import { isSupabaseConfigured } from '../supabase.js';

const router = Router();

/**
 * GET /api/health
 * Public health check confirming the server is online without exposing any secrets.
 */
router.get('/', (req, res) => {
  res.status(200).json({
    status: 'healthy',
    service: 'ReturnIQ Backend API',
    database_configured: isSupabaseConfigured(),
    timestamp: new Date().toISOString(),
  });
});

export default router;
