"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const express_1 = require("express");
const zod_1 = require("zod");
const db_1 = require("../config/db");
const router = (0, express_1.Router)();
const filtersSchema = zod_1.z.object({
    minPrice: zod_1.z.coerce.number().nonnegative().optional(),
    maxPrice: zod_1.z.coerce.number().nonnegative().optional(),
    maxDistance: zod_1.z.coerce.number().nonnegative().optional()
});
router.get("/", async (req, res, next) => {
    try {
        const filters = filtersSchema.parse(req.query);
        const queryValues = [];
        const conditions = [];
        if (filters.maxDistance !== undefined) {
            queryValues.push(filters.maxDistance);
            conditions.push(`h.distance_from_campus <= $${queryValues.length}`);
        }
        if (filters.minPrice !== undefined || filters.maxPrice !== undefined) {
            const priceConditions = [];
            if (filters.minPrice !== undefined) {
                queryValues.push(filters.minPrice);
                priceConditions.push(`r.price_per_semester >= $${queryValues.length}`);
            }
            if (filters.maxPrice !== undefined) {
                queryValues.push(filters.maxPrice);
                priceConditions.push(`r.price_per_semester <= $${queryValues.length}`);
            }
            conditions.push(`EXISTS (
        SELECT 1
        FROM rooms r
        WHERE r.hostel_id = h.id
        AND ${priceConditions.join(" AND ")}
      )`);
        }
        const hostelsResult = await db_1.pool.query(`
        SELECT
          h.id,
          h.name,
          h.description,
          h.address,
          h.distance_from_campus,
          h.amenities,
          h.landlord_id AS "landlordId",
          h.is_verified AS "isVerified"
        FROM hostels h
        ${conditions.length > 0 ? `WHERE ${conditions.join(" AND ")}` : ""}
        ORDER BY h.distance_from_campus ASC, h.name ASC
      `, queryValues);
        const hostels = hostelsResult.rows;
        if (hostels.length === 0) {
            res.status(200).json({ data: [] });
            return;
        }
        const roomRows = await db_1.pool.query(`
        SELECT
          id,
          hostel_id AS "hostelId",
          type,
          price_per_semester::text AS "pricePerSemester",
          total_beds AS "totalBeds",
          available_beds AS "availableBeds"
        FROM rooms
        WHERE hostel_id = ANY($1::text[])
        ORDER BY price_per_semester ASC, id ASC
      `, [hostels.map((hostel) => hostel.id)]);
        const roomsByHostelId = new Map();
        for (const room of roomRows.rows) {
            const rooms = roomsByHostelId.get(room.hostelId) ?? [];
            rooms.push(room);
            roomsByHostelId.set(room.hostelId, rooms);
        }
        const payload = hostels.map((hostel) => ({
            ...hostel,
            rooms: roomsByHostelId.get(hostel.id) ?? []
        }));
        res.status(200).json({ data: payload });
    }
    catch (error) {
        next(error);
    }
});
exports.default = router;
