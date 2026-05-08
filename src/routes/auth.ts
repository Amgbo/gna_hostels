import { Router } from "express";
import bcrypt from "bcryptjs";
import jwt from "jsonwebtoken";
import { randomUUID } from "node:crypto";
import { z } from "zod";
import { OAuth2Client } from "google-auth-library";
import { pool } from "../config/db";
import { env } from "../config/env";
import { USER_ROLES, type UserRole } from "../types/user";
import { requireAuth, type AuthRequest } from "../middlewares/auth";
import { authLimiter, oauthLimiter } from "../middlewares/rateLimiter";

const router = Router();

// Password validation: at least 8 chars, 1 uppercase, 1 number, 1 special char
const passwordRegex = /^(?=.*[A-Z])(?=.*\d)(?=.*[@$!%*?&])[A-Za-z\d@$!%*?&]{8,}$/;

const registerSchema = z.object({
  email: z.string().email("Invalid email address"),
  password: z.string()
    .min(8, "Password must be at least 8 characters")
    .regex(passwordRegex, "Password must contain 1 uppercase letter, 1 number, and 1 special character"),
  name: z.string().min(2, "Name must be at least 2 characters"),
  role: z.enum(USER_ROLES).optional()
});

const loginSchema = z.object({
  email: z.string().email("Invalid email address"),
  password: z.string().min(1, "Password required")
});

const googleOAuthSchema = z.object({
  token: z.string().min(1, "Google token required")
});

// Initialize Google OAuth client if credentials are provided
const googleClient = env.GOOGLE_CLIENT_ID ? new OAuth2Client(env.GOOGLE_CLIENT_ID) : null;

// POST /register - Create new account with email/password
router.post("/register", authLimiter, async (req, res, next) => {
  try {
    const body = registerSchema.parse(req.body);

    // Check if email already exists (case-insensitive)
    const existingUser = await pool.query<{ id: string }>(
      `SELECT id FROM users WHERE lower(email) = lower($1) LIMIT 1`,
      [body.email]
    );

    if (existingUser.rows.length > 0) {
      res.status(409).json({ message: "Email already in use" });
      return;
    }

    const hashedPassword = await bcrypt.hash(body.password, 10);
    const userId = randomUUID();
    const role: UserRole = body.role ?? "STUDENT";

    const createdUser = await pool.query<{
      id: string;
      email: string;
      name: string;
      role: UserRole;
    }>(
      `
        INSERT INTO users (id, email, password, name, role)
        VALUES ($1, $2, $3, $4, $5)
        RETURNING id, email, name, role
      `,
      [userId, body.email, hashedPassword, body.name, role]
    );

    const user = createdUser.rows[0];

    const token = jwt.sign(
      { userId: user.id, role: user.role },
      env.JWT_SECRET,
      { expiresIn: "7d" }
    );

    res.status(201).json({
      token,
      user: {
        id: user.id,
        email: user.email,
        name: user.name,
        role: user.role
      }
    });
  } catch (error) {
    if (error instanceof z.ZodError) {
      res.status(400).json({ message: error.errors[0].message });
      return;
    }
    next(error);
  }
});

// POST /login - Login with email/password
router.post("/login", authLimiter, async (req, res, next) => {
  try {
    const body = loginSchema.parse(req.body);

    const userResult = await pool.query<{
      id: string;
      email: string;
      password: string | null;
      name: string;
      role: UserRole;
    }>(
      `
        SELECT id, email, password, name, role
        FROM users
        WHERE lower(email) = lower($1)
        LIMIT 1
      `,
      [body.email]
    );

    const user = userResult.rows[0];

    if (!user || !user.password) {
      res.status(401).json({ message: "Invalid credentials" });
      return;
    }

    const isPasswordValid = await bcrypt.compare(body.password, user.password);

    if (!isPasswordValid) {
      res.status(401).json({ message: "Invalid credentials" });
      return;
    }

    const token = jwt.sign(
      { userId: user.id, role: user.role },
      env.JWT_SECRET,
      { expiresIn: "7d" }
    );

    res.status(200).json({
      token,
      user: {
        id: user.id,
        email: user.email,
        name: user.name,
        role: user.role
      }
    });
  } catch (error) {
    if (error instanceof z.ZodError) {
      res.status(400).json({ message: error.errors[0].message });
      return;
    }
    next(error);
  }
});

// POST /google - Google OAuth login/register
router.post("/google", oauthLimiter, async (req, res, next) => {
  try {
    if (!googleClient || !env.GOOGLE_CLIENT_ID) {
      res.status(501).json({ message: "Google OAuth not configured" });
      return;
    }

    const body = googleOAuthSchema.parse(req.body);

    // Verify Google token
    const ticket = await googleClient.verifyIdToken({
      idToken: body.token,
      audience: env.GOOGLE_CLIENT_ID
    });

    const payload = ticket.getPayload();
    if (!payload) {
      res.status(401).json({ message: "Invalid Google token" });
      return;
    }

    const { sub: googleUserId, email, name: googleName } = payload;

    if (!email) {
      res.status(400).json({ message: "Google account must have an email" });
      return;
    }

    // Check if OAuth identity already exists
    let existingIdentity = await pool.query<{ user_id: string }>(
      `SELECT user_id FROM oauth_identities WHERE provider = 'google' AND provider_user_id = $1`,
      [googleUserId]
    );

    if (existingIdentity.rows.length > 0) {
      // Existing OAuth user - return token
      const userId = existingIdentity.rows[0].user_id;
      const user = await pool.query<{ id: string; email: string; name: string; role: UserRole }>(
        `SELECT id, email, name, role FROM users WHERE id = $1`,
        [userId]
      );

      if (user.rows.length === 0) {
        res.status(404).json({ message: "User not found" });
        return;
      }

      const userRecord = user.rows[0];
      const token = jwt.sign(
        { userId: userRecord.id, role: userRecord.role },
        env.JWT_SECRET,
        { expiresIn: "7d" }
      );

      res.status(200).json({
        token,
        user: {
          id: userRecord.id,
          email: userRecord.email,
          name: userRecord.name,
          role: userRecord.role
        }
      });
      return;
    }

    // Check if email already exists with different provider
    let existingUser = await pool.query<{ id: string; name: string; role: UserRole }>(
      `SELECT id, name, role FROM users WHERE lower(email) = lower($1)`,
      [email]
    );

    let userId: string;
    if (existingUser.rows.length > 0) {
      // Email exists - link OAuth to existing account
      userId = existingUser.rows[0].id;
    } else {
      // New user - create account
      userId = randomUUID();
      const displayName = googleName || email.split("@")[0];
      await pool.query(
        `INSERT INTO users (id, email, name, role) VALUES ($1, $2, $3, $4)`,
        [userId, email, displayName, "STUDENT"]
      );
    }

    // Store OAuth identity
    await pool.query(
      `
        INSERT INTO oauth_identities (id, user_id, provider, provider_user_id, provider_email)
        VALUES ($1, $2, $3, $4, $5)
        ON CONFLICT (provider, provider_user_id) DO UPDATE
        SET provider_email = $5, updated_at = now()
      `,
      [randomUUID(), userId, "google", googleUserId, email]
    );

    // Get full user record
    const finalUser = await pool.query<{ id: string; email: string; name: string; role: UserRole }>(
      `SELECT id, email, name, role FROM users WHERE id = $1`,
      [userId]
    );

    if (finalUser.rows.length === 0) {
      res.status(404).json({ message: "User not found" });
      return;
    }

    const userRecord = finalUser.rows[0];
    const token = jwt.sign(
      { userId: userRecord.id, role: userRecord.role },
      env.JWT_SECRET,
      { expiresIn: "7d" }
    );

    res.status(200).json({
      token,
      user: {
        id: userRecord.id,
        email: userRecord.email,
        name: userRecord.name,
        role: userRecord.role
      }
    });
  } catch (error) {
    if (error instanceof z.ZodError) {
      res.status(400).json({ message: error.errors[0].message });
      return;
    }
    next(error);
  }
});

// GET /me - Get current user profile (protected route)
router.get("/me", requireAuth, async (req: AuthRequest, res, next) => {
  try {
    const user = await pool.query<{ id: string; email: string; name: string; role: UserRole }>(
      `SELECT id, email, name, role FROM users WHERE id = $1 LIMIT 1`,
      [req.user!.userId]
    );

    if (user.rows.length === 0) {
      res.status(404).json({ message: "User not found" });
      return;
    }

    res.status(200).json({ data: user.rows[0] });
  } catch (err) {
    next(err);
  }
});

export default router;
