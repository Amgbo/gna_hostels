import dotenv from "dotenv";
import { Pool } from "pg";
import bcrypt from "bcryptjs";
import { randomUUID } from "crypto";

dotenv.config();

const DATABASE_URL = process.env.DATABASE_URL;
if (!DATABASE_URL) {
  console.error("Missing DATABASE_URL in environment");
  process.exit(1);
}

const pool = new Pool({ connectionString: DATABASE_URL });

async function ensureSchemaExists() {
  const result = await pool.query(`
    SELECT
      to_regclass('public.users') AS users,
      to_regclass('public.hostels') AS hostels,
      to_regclass('public.rooms') AS rooms,
      to_regclass('public.bookings') AS bookings
  `);

  const row = result.rows[0] as {
    users: string | null;
    hostels: string | null;
    rooms: string | null;
    bookings: string | null;
  };

  const missing = Object.entries(row)
    .filter(([, value]) => value === null)
    .map(([key]) => key);

  if (missing.length > 0) {
    throw new Error(
      `Database schema is not applied yet. Missing tables: ${missing.join(", ")}. Run backend/sql/schema.sql in pgAdmin first, then rerun npm run seed.`
    );
  }
}

async function getOrCreateUser(email: string, password: string, name: string, role = "STUDENT") {
  const client = await pool.connect();
  try {
    const lower = email.toLowerCase();
    const found = await client.query("SELECT id FROM users WHERE lower(email) = $1", [lower]);
    if ((found.rowCount ?? 0) > 0) return found.rows[0].id;

    const id = randomUUID();
    const hash = await bcrypt.hash(password, 10);
    await client.query(
      `INSERT INTO users (id, email, password, name, role) VALUES ($1, $2, $3, $4, $5)`,
      [id, email, hash, name, role]
    );
    return id;
  } finally {
    client.release();
  }
}

async function getOrCreateHostel(name: string, description: string, address: string, distance: number, landlordId: string, isVerified = true) {
  const client = await pool.connect();
  try {
    const found = await client.query("SELECT id FROM hostels WHERE lower(name) = $1 AND lower(address) = $2", [name.toLowerCase(), address.toLowerCase()]);
    if ((found.rowCount ?? 0) > 0) return found.rows[0].id;

    const id = randomUUID();
    await client.query(
      `INSERT INTO hostels (id, name, description, address, distance_from_campus, landlord_id, is_verified) VALUES ($1, $2, $3, $4, $5, $6, $7)`,
      [id, name, description, address, distance, landlordId, isVerified]
    );
    return id;
  } finally {
    client.release();
  }
}

async function createRoomIfNotExists(hostelId: string, type: "SINGLE" | "SHARED", price: number, totalBeds: number, availableBeds: number) {
  const client = await pool.connect();
  try {
    const found = await client.query(
      `SELECT id FROM rooms WHERE hostel_id = $1 AND type = $2 AND price_per_semester = $3 LIMIT 1`,
      [hostelId, type, price]
    );
    if ((found.rowCount ?? 0) > 0) return found.rows[0].id;

    const id = randomUUID();
    await client.query(
      `INSERT INTO rooms (id, hostel_id, type, price_per_semester, total_beds, available_beds) VALUES ($1, $2, $3, $4, $5, $6)`,
      [id, hostelId, type, price, totalBeds, availableBeds]
    );
    return id;
  } finally {
    client.release();
  }
}

async function main() {
  try {
    console.log("Seeding database (idempotent)...");
    await ensureSchemaExists();

    // Users
    const landlordId = await getOrCreateUser("landlord@example.com", "password123", "Landlord One", "LANDLORD");
    const studentId = await getOrCreateUser("student@example.com", "password123", "Student One", "STUDENT");

    // Hostels
    const hostel1 = await getOrCreateHostel("Oak Hall", "A calm, well-maintained hostel close to campus.", "12 College Rd", 0.8, landlordId, true);
    const hostel2 = await getOrCreateHostel("Maple Suites", "Modern rooms with great study spaces.", "5 University Ave", 1.6, landlordId, true);

    // Rooms
    await createRoomIfNotExists(hostel1, "SINGLE", 1200.0, 1, 1);
    await createRoomIfNotExists(hostel1, "SHARED", 800.0, 4, 2);
    await createRoomIfNotExists(hostel2, "SINGLE", 1400.0, 1, 1);

    console.log("Seed complete. Created sample landlord and student plus hostels/rooms (idempotent).");
  } catch (err) {
    console.error("Seed failed:", err);
  } finally {
    await pool.end();
  }
}

main();
