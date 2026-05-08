import { Router } from "express";
import { randomUUID } from "node:crypto";
import { pool } from "../config/db";
import { z } from "zod";
import { requireAuth, AuthRequest } from "../middlewares/auth";

const router = Router();


const createBookingSchema = z.object({
  academic_term_id: z.string().uuid("Invalid academic_term_id"),
  hostel_id: z.string().uuid("Invalid hostel_id"),
  room_id: z.string().uuid("Invalid room_id"),
  bed_id: z.string().uuid("Invalid bed_id").optional(), // Optional for room bookings
  check_in_date: z.string().date("Invalid check_in_date"),
  check_out_date: z.string().date("Invalid check_out_date")
});
router.post("/", requireAuth, async (req: AuthRequest, res, next) => {
  try {
    const { roomId } = req.body as { roomId?: string };
    // Validate request body
    const body = createBookingSchema.parse(req.body);

    // Validate check-out is after check-in
    const checkIn = new Date(body.check_in_date);
    const checkOut = new Date(body.check_out_date);
    if (checkOut <= checkIn) {
      res.status(400).json({ message: "check_out_date must be after check_in_date" });
      return;
    }

    if (!roomId) return res.status(400).json({ message: "roomId required" });

    const client = await pool.connect();

      // Verify academic term exists and is active
      const termRes = await client.query(
        `SELECT id FROM academic_terms WHERE id = $1 AND is_active = true`,
        [body.academic_term_id]
      );
      if (termRes.rows.length === 0) {
        await client.query("ROLLBACK");
        res.status(404).json({ message: "Academic term not found or inactive" });
        return;
      }

      // Check for duplicate booking in same term (only 1 active booking per term per student)
      const duplicateRes = await client.query(
        `
          SELECT id FROM bookings
          WHERE student_id = $1 AND academic_term_id = $2 AND deleted_at IS NULL
            AND booking_status NOT IN ('CANCELLED', 'REJECTED')
          LIMIT 1
        `,
        [req.user!.userId, body.academic_term_id]
      );
      if (duplicateRes.rows.length > 0) {
        await client.query("ROLLBACK");
        res.status(409).json({ message: "Student already has an active booking for this academic term" });
        return;
      }

      // Lock and verify room for update
    try {
        `
          SELECT id, hostel_id, total_beds, available_beds, price_per_semester
          FROM rooms WHERE id = $1 AND hostel_id = $2 AND deleted_at IS NULL
          FOR UPDATE
        `,
        [body.room_id, body.hostel_id]
      const roomRes = await client.query(
        `SELECT id, available_beds FROM rooms WHERE id = $1 FOR UPDATE`,
        [roomId]
      );

        res.status(404).json({ message: "Room not found in specified hostel" });
        return;
      if (!room) {
        await client.query("ROLLBACK");
      // If bed_id is specified, lock and verify the bed
      let bed: { id: string; price_override: number | null } | null = null;
      if (body.bed_id) {
        const bedRes = await client.query(
          `
            SELECT id, price_override FROM beds
            WHERE id = $1 AND room_id = $2 AND bed_status = 'AVAILABLE' AND deleted_at IS NULL
            FOR UPDATE
          `,
          [body.bed_id, body.room_id]
        );
        bed = bedRes.rows[0] || null;
        if (!bed) {
          await client.query("ROLLBACK");
          res.status(400).json({ message: "Bed not available or not found" });
          return;
        }
      } else if (room.available_beds <= 0) {
      }
        res.status(400).json({ message: "No available beds in this room" });
        return;
      if (room.available_beds <= 0) {
        await client.query("ROLLBACK");
      // Decrement available beds if room booking (not bed-specific)
      if (!body.bed_id) {
        await client.query(
          `UPDATE rooms SET available_beds = available_beds - 1 WHERE id = $1`,
          [body.room_id]
        );
      } else if (bed) {
        // Update bed status to RESERVED
        await client.query(
          `UPDATE beds SET bed_status = 'RESERVED' WHERE id = $1`,
          [bed.id]
        );
      }
      await client.query(
      // Create booking
        `UPDATE rooms SET available_beds = available_beds - 1 WHERE id = $1`,
      const unitPrice = bed?.price_override || room.price_per_semester;
      const subtotalAmount = unitPrice; // For now, single unit. Could multiply by stay duration
      
        [roomId]
        `
          INSERT INTO bookings (
            id, student_id, academic_term_id, hostel_id,
            booking_status, payment_status,
            check_in_date, check_out_date,
            reservation_expires_at,
            subtotal_amount, total_amount, currency
          ) VALUES ($1, $2, $3, $4, 'PENDING', 'PENDING', $5, $6, now() + interval '24 hours', $7, $7, 'GHS')
        `,
        [bookingId, req.user!.userId, body.academic_term_id, body.hostel_id,
         body.check_in_date, body.check_out_date, subtotalAmount]
      const bookingId = randomUUID();
      await client.query(
      // Create booking item (line item)
      const itemId = randomUUID();
      await client.query(
        `
          INSERT INTO booking_items (
            id, booking_id, item_type, room_id, bed_id, quantity, unit_price, subtotal
          ) VALUES ($1, $2, $3, $4, $5, 1, $6, $7)
        `,
        [itemId, bookingId, body.bed_id ? 'BED' : 'ROOM', body.room_id, body.bed_id || null, unitPrice, subtotalAmount]
      );

        `INSERT INTO bookings (id, student_id, room_id, status) VALUES ($1, $2, $3, 'PENDING')`,
        [bookingId, req.user!.userId, roomId]
      res.status(201).json({
        data: {
          id: bookingId,
          student_id: req.user!.userId,
          academic_term_id: body.academic_term_id,
          hostel_id: body.hostel_id,
          room_id: body.room_id,
          bed_id: body.bed_id || null,
          booking_status: "PENDING",
          payment_status: "PENDING",
          check_in_date: body.check_in_date,
          check_out_date: body.check_out_date,
          subtotal_amount: subtotalAmount,
          total_amount: subtotalAmount,
          currency: "GHS"
        }
      });

      await client.query("COMMIT");

      res.status(201).json({ data: { id: bookingId, roomId, status: "PENDING" } });
    } catch (err) {
      await client.query("ROLLBACK");
      throw err;
    if (err instanceof z.ZodError) {
      res.status(400).json({ message: err.errors[0].message });
      return;
    }
    } finally {
      client.release();
    }
  } catch (err) {
    next(err);
  }
});

export default router;

// GET /bookings - List student's bookings
router.get("/", requireAuth, async (req: AuthRequest, res, next) => {
  try {
    const bookings = await pool.query(
      `
        SELECT
          b.id, b.booking_reference, b.academic_term_id, b.hostel_id,
          b.booking_status, b.payment_status,
          b.check_in_date, b.check_out_date,
          b.subtotal_amount, b.discount_amount, b.total_amount, b.currency,
          h.name as hostel_name,
          at.year as academic_year, at.term as semester
        FROM bookings b
        JOIN hostels h ON h.id = b.hostel_id
        JOIN academic_terms at ON at.id = b.academic_term_id
        WHERE b.student_id = $1 AND b.deleted_at IS NULL
        ORDER BY b.created_at DESC
      `,
      [req.user!.userId]
    );

    res.status(200).json({ data: bookings.rows });
  } catch (err) {
    next(err);
  }
});

// GET /bookings/:id - Get booking details
router.get("/:id", requireAuth, async (req: AuthRequest, res, next) => {
  try {
    const bookingId = req.params.id;

    const booking = await pool.query(
      `
        SELECT
          b.id, b.booking_reference, b.student_id, b.academic_term_id, b.hostel_id,
          b.booking_status, b.payment_status,
          b.check_in_date, b.check_out_date,
          b.subtotal_amount, b.discount_amount, b.total_amount, b.currency,
          b.notes, b.created_at, b.updated_at,
          h.name as hostel_name, h.address as hostel_address,
          at.year as academic_year, at.term as semester
        FROM bookings b
        JOIN hostels h ON h.id = b.hostel_id
        JOIN academic_terms at ON at.id = b.academic_term_id
        WHERE b.id = $1 AND b.deleted_at IS NULL
      `,
      [bookingId]
    );

    if (booking.rows.length === 0) {
      res.status(404).json({ message: "Booking not found" });
      return;
    }

    const bookingData = booking.rows[0];

    // Verify student owns this booking
    if (bookingData.student_id !== req.user!.userId) {
      res.status(403).json({ message: "Insufficient permissions" });
      return;
    }

    // Get booking items (rooms/beds)
    const items = await pool.query(
      `
        SELECT
          id, item_type, room_id, bed_id, quantity, unit_price, subtotal
        FROM booking_items
        WHERE booking_id = $1 AND deleted_at IS NULL
      `,
      [bookingId]
    );

    res.status(200).json({
      data: {
        ...bookingData,
        items: items.rows
      }
    });
  } catch (err) {
    next(err);
  }
});
