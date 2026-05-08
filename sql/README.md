Apply the schema and seed the database

1) Ensure you have a PostgreSQL database and a connection URL in `DATABASE_URL`.

2) To apply the schema directly with `psql`:

```bash
# Example (replace with your database URL or use a .env file):
psql "$DATABASE_URL" -f backend/sql/schema.sql
```

3) Use the TypeScript seed script to insert sample data (it hashes passwords for you).

Requirements:
- Node.js 18+ (to run `npx tsx`)
- `DATABASE_URL` env var set to your Postgres connection string

Run the seed script from the project root:

```bash
# install dependencies if not already installed
npm install

# run the seed script (uses tsx to execute TypeScript directly)
npx tsx backend/scripts/seed.ts
```

Notes:
- The seed script creates one landlord (`landlord@example.com`) and one student (`student@example.com`) with password `password123` (hashed before insertion).
- If you prefer raw SQL seeding, you can translate the generated inserts from the script into a SQL file and run with `psql`.
