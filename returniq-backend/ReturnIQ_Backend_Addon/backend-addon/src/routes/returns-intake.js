import { Router } from "express";
import { createOptionsHandler, createReturnHandler } from "./returns-intake-handlers.js";

/**
 * Additive router for POST /api/returns and GET /api/returns/options.
 * Pass the EXISTING server-side Supabase client from your application.
 * Mount alongside the current GET inventory router; do not replace it.
 */
export function createReturnsIntakeRouter(supabase) {
  if (!supabase?.from) throw new TypeError("createReturnsIntakeRouter requires the existing Supabase client");
  const router = Router();
  router.get("/options", createOptionsHandler(supabase));
  router.post("/", createReturnHandler(supabase));
  return router;
}
