import { createClient } from '@supabase/supabase-js';
import dotenv from 'dotenv';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Ensure backend .env is loaded if environment variables are not already present in runtime
dotenv.config({ path: path.resolve(__dirname, '../.env') });

/**
 * Checks whether Supabase environment variables are properly configured with real values.
 * Returns false if missing or left as default placeholders.
 */
export function isSupabaseConfigured() {
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;

  if (!url || !key) return false;
  if (url.includes('your-project-id') || key.includes('your-supabase-service-role-key')) return false;

  return true;
}

let supabase = null;
let isMockInjected = false;

/**
 * Initializes and exports a singleton Supabase client using the private service_role key.
 * If credentials are not configured, client is set to null.
 */
export function initSupabaseClient() {
  if (isMockInjected) {
    return supabase;
  }

  if (isSupabaseConfigured()) {
    supabase = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: {
        persistSession: false,
        autoRefreshToken: false,
      },
    });
  } else {
    supabase = null;
  }

  return supabase;
}

// Initial evaluation attempt on module load
initSupabaseClient();

/**
 * Returns the singleton Supabase client.
 * If the client has not been initialized yet (e.g. .env was populated after module evaluation),
 * lazily initializes and returns it.
 */
export function getSupabaseClient() {
  if (!supabase && !isMockInjected && isSupabaseConfigured()) {
    initSupabaseClient();
  }
  return supabase;
}

/**
 * Sets the Supabase client instance.
 * Used by automated isolated tests to inject a mock client without hitting real databases.
 */
export function setSupabaseClient(client) {
  supabase = client;
  isMockInjected = true;
}

/**
 * Resets the Supabase client state.
 * Useful for tests that need to clear mock injections.
 */
export function resetSupabaseClient() {
  isMockInjected = false;
  supabase = null;
  return initSupabaseClient();
}

/**
 * Returns a safe diagnostic summary of Supabase configuration and initialization status.
 * Crucially: Never exposes or logs the private service role key.
 */
export function getSupabaseDiagnostic() {
  const configured = isSupabaseConfigured();
  const client = getSupabaseClient();
  let projectHost = null;
  let projectRef = null;

  if (process.env.SUPABASE_URL) {
    try {
      const parsed = new URL(process.env.SUPABASE_URL);
      projectHost = parsed.hostname;
      projectRef = parsed.hostname.split('.')[0] || null;
    } catch {
      projectHost = 'invalid_url_format';
    }
  }

  return {
    configured,
    clientInitialized: Boolean(client),
    projectHost,
    projectRef,
    serviceRoleKeyConfigured: Boolean(
      process.env.SUPABASE_SERVICE_ROLE_KEY &&
      !process.env.SUPABASE_SERVICE_ROLE_KEY.includes('your-supabase-service-role-key')
    ),
  };
}

