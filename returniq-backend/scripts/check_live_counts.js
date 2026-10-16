
import path from 'path';
import { fileURLToPath } from 'url';
import dotenv from 'dotenv';
import { getSupabaseClient } from '../src/supabase.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
dotenv.config({ path: path.resolve(__dirname, '../.env') });

const supabase = getSupabaseClient();
const tables = [
  'gb_products',
  'gb_inventory',
  'gb_vendor_terms',
  'gb_refurbishment',
  'gb_liquidation',
  'gb_returns',
  'gb_sales'
];

async function run() {
  console.log('=== REAL SUPABASE LIVE COUNTS ===');
  for (const t of tables) {
    const { count, error } = await supabase.from(t).select('*', { count: 'exact', head: true });
    console.log(`${t}: ${count} rows ${error ? `(Error: ${error.message})` : '✓'}`);
  }
}
run();
