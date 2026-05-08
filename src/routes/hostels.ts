import { Router } from "express";
import { z } from "zod";
import { pool } from "../config/db";

const router = Router();

const filtersSchema = z.object({
  q: z.string().optional(),
  roomType: z.enum(["SINGLE", "SHARED"]).optional(),
  verified: z.coerce.boolean().optional(),
  minPrice: z.coerce.number().nonnegative().optional(),
  maxPrice: z.coerce.number().nonnegative().optional(),
  maxDistance: z.coerce.number().nonnegative().optional(),
  sort: z.enum(["price_asc", "price_desc", "distance_asc", "distance_desc"]).optional()
});

const paginationSchema = z.object({
  page: z.coerce.number().positive().default(1),
  limit: z.coerce.number().positive().max(100).default(20)
});

type RoomType = "SINGLE" | "SHARED";

type HostelRow = {
  id: string;
  name: string;
  description: string;
  address: string;
  distance_from_campus: number;
  amenities: unknown;
  landlordId: string;
  isVerified: boolean;
  min_price?: number | null;
};

type RoomRow = {
  id: string;
  hostelId: string;
  type: RoomType;
  pricePerSemester: string;
  totalBeds: number;
  availableBeds: number;
};

router.get("/", async (req, res, next) => {
  try {
    const filters = filtersSchema.parse(req.query);
    const { page, limit } = paginationSchema.parse(req.query);
    const offset = (page - 1) * limit;

    const queryValues: Array<string | number | boolean> = [];
    const conditions: string[] = [];

    if (filters.maxDistance !== undefined) {
      queryValues.push(filters.maxDistance);
      conditions.push(`h.distance_from_campus <= $${queryValues.length}`);
    }

    if (filters.verified !== undefined) {
      queryValues.push(filters.verified);
      conditions.push(`h.is_verified = $${queryValues.length}`);
    }

    if (filters.minPrice !== undefined || filters.maxPrice !== undefined || filters.roomType !== undefined) {
      const priceConditions: string[] = [];

      if (filters.minPrice !== undefined) {
        queryValues.push(filters.minPrice);
        priceConditions.push(`r.price_per_semester >= $${queryValues.length}`);
      }

      if (filters.maxPrice !== undefined) {
        queryValues.push(filters.maxPrice);
        priceConditions.push(`r.price_per_semester <= $${queryValues.length}`);
      }

      if (filters.roomType !== undefined) {
        queryValues.push(filters.roomType);
        priceConditions.push(`r.type = $${queryValues.length}`);
      }

      conditions.push(`EXISTS (
        SELECT 1
        FROM rooms r
        WHERE r.hostel_id = h.id
        AND ${priceConditions.join(" AND ")}
      )`);
    }

    if (filters.q) {
      queryValues.push(`%${filters.q}%`);
      conditions.push(`(h.name ILIKE $${queryValues.length} OR h.address ILIKE $${queryValues.length} OR h.description ILIKE $${queryValues.length})`);
    }

    // Get total count for pagination
    const countQueryValues = queryValues.slice();
    const countResult = await pool.query<{ total: number }>(
      `
        SELECT COUNT(DISTINCT h.id) AS total
        FROM hostels h
        ${conditions.length > 0 ? `WHERE ${conditions.join(" AND ")}` : ""}
      `,
      countQueryValues
    );
    const total = countResult.rows[0].total;
    const totalPages = Math.ceil(total / limit);

    // Add min_price subquery to support price-based sorting
    const hostelsResult = await pool.query<HostelRow>(
      `
        SELECT
          h.id,
          h.name,
          h.description,
          h.address,
          h.distance_from_campus,
          COALESCE(amenities.amenities, '[]'::jsonb) AS amenities,
          h.landlord_id AS "landlordId",
          h.is_verified AS "isVerified",
          (
            SELECT MIN(price_per_semester) FROM rooms r2 WHERE r2.hostel_id = h.id
          ) AS min_price
        FROM hostels h
        LEFT JOIN LATERAL (
          SELECT jsonb_agg(
            jsonb_build_object(
              'id', a.id,
              'name', a.name,
              'category', a.category,
              'icon', a.icon,
              'description', a.description
            )
            ORDER BY a.name ASC
          ) AS amenities
          FROM hostel_amenities ha
          JOIN amenities a ON a.id = ha.amenity_id
          WHERE ha.hostel_id = h.id
            AND ha.deleted_at IS NULL
            AND a.deleted_at IS NULL
        ) amenities ON true
        ${conditions.length > 0 ? `WHERE ${conditions.join(" AND ")}` : ""}
        ${filters.sort === "price_asc" ? "ORDER BY min_price ASC NULLS LAST, h.name ASC" : ""}
        ${filters.sort === "price_desc" ? "ORDER BY min_price DESC NULLS LAST, h.name ASC" : ""}
        ${filters.sort === "distance_asc" ? "ORDER BY h.distance_from_campus ASC, h.name ASC" : ""}
        ${filters.sort === "distance_desc" ? "ORDER BY h.distance_from_campus DESC, h.name ASC" : ""}
        ${!filters.sort ? "ORDER BY h.distance_from_campus ASC, h.name ASC" : ""}
        LIMIT $${queryValues.length + 1}
        OFFSET $${queryValues.length + 2}
      `,
      [...queryValues, limit, offset]
    );

    const hostels: HostelRow[] = hostelsResult.rows;

    if (hostels.length === 0) {
      res.status(200).json({ data: [] });
      return;
    }

    const roomRows = await pool.query<RoomRow>(
      `
        SELECT
          id,
          hostel_id AS "hostelId",
          type,
          price_per_semester::text AS "pricePerSemester",
          total_beds AS "totalBeds",
          available_beds AS "availableBeds"
        FROM rooms
        WHERE hostel_id = ANY($1::uuid[])
        ${filters.roomType ? "AND type = $2" : ""}
        ORDER BY price_per_semester ASC, id ASC
      `,
      filters.roomType ? [hostels.map((hostel) => hostel.id), filters.roomType] : [hostels.map((hostel) => hostel.id)]
    );

    const roomsByHostelId = new Map<string, RoomRow[]>();

    for (const room of roomRows.rows) {
      const rooms = roomsByHostelId.get(room.hostelId) ?? [];
      rooms.push(room);
      roomsByHostelId.set(room.hostelId, rooms);
    }

    const payload = hostels.map((hostel) => ({
      ...hostel,
      rooms: roomsByHostelId.get(hostel.id) ?? []
    }));

    res.status(200).json({
      data: payload,
      pagination: {
        page,
        limit,
        total,
        totalPages
      }
    });
  } catch (error) {
    next(error);
  }
});

export default router;

// Get single hostel by id with rooms
router.get("/:id", async (req, res, next) => {
  try {
    const id = req.params.id;

    const hostelResult = await pool.query(
      `
        SELECT
          h.id,
          h.name,
          h.description,
          h.address,
          h.distance_from_campus,
          COALESCE(amenities.amenities, '[]'::jsonb) AS amenities,
          h.landlord_id AS "landlordId",
          h.is_verified AS "isVerified"
        FROM hostels h
        LEFT JOIN LATERAL (
          SELECT jsonb_agg(
            jsonb_build_object(
              'id', a.id,
              'name', a.name,
              'category', a.category,
              'icon', a.icon,
              'description', a.description
            )
            ORDER BY a.name ASC
          ) AS amenities
          FROM hostel_amenities ha
          JOIN amenities a ON a.id = ha.amenity_id
          WHERE ha.hostel_id = h.id
            AND ha.deleted_at IS NULL
            AND a.deleted_at IS NULL
        ) amenities ON true
        WHERE h.id = $1
        LIMIT 1
      `,
      [id]
    );

    const hostel = hostelResult.rows[0];
    if (!hostel) {
      res.status(404).json({ message: "Not found" });
      return;
    }

    const roomsResult = await pool.query(
      `
        SELECT
          id,
          hostel_id AS "hostelId",
          type,
          price_per_semester::text AS "pricePerSemester",
          total_beds AS "totalBeds",
          available_beds AS "availableBeds"
        FROM rooms
        WHERE hostel_id = $1
        ORDER BY price_per_semester ASC
      `,
      [id]
    );

    res.status(200).json({ data: { ...hostel, rooms: roomsResult.rows } });
  } catch (err) {
    next(err);
  }
});
