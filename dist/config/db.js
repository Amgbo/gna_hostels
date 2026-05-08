"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.pool = void 0;
const pg_1 = require("pg");
const env_1 = require("./env");
exports.pool = global.postgresPool ??
    new pg_1.Pool({
        connectionString: env_1.env.DATABASE_URL
    });
if (process.env.NODE_ENV !== "production") {
    global.postgresPool = exports.pool;
}
