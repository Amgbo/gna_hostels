"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
const express_1 = require("express");
const bcryptjs_1 = __importDefault(require("bcryptjs"));
const jsonwebtoken_1 = __importDefault(require("jsonwebtoken"));
const node_crypto_1 = require("node:crypto");
const zod_1 = require("zod");
const db_1 = require("../config/db");
const env_1 = require("../config/env");
const user_1 = require("../types/user");
const router = (0, express_1.Router)();
const registerSchema = zod_1.z.object({
    email: zod_1.z.string().email(),
    password: zod_1.z.string().min(6),
    name: zod_1.z.string().min(2),
    role: zod_1.z.enum(user_1.USER_ROLES).optional()
});
const loginSchema = zod_1.z.object({
    email: zod_1.z.string().email(),
    password: zod_1.z.string().min(1)
});
router.post("/register", async (req, res, next) => {
    try {
        const body = registerSchema.parse(req.body);
        const existingUser = await db_1.pool.query(`SELECT id FROM users WHERE email = $1 LIMIT 1`, [body.email]);
        if (existingUser.rows.length > 0) {
            res.status(409).json({ message: "Email already in use" });
            return;
        }
        const hashedPassword = await bcryptjs_1.default.hash(body.password, 10);
        const userId = (0, node_crypto_1.randomUUID)();
        const role = body.role ?? "STUDENT";
        const createdUser = await db_1.pool.query(`
        INSERT INTO users (id, email, password, name, role)
        VALUES ($1, $2, $3, $4, $5)
        RETURNING id, email, name, role
      `, [userId, body.email, hashedPassword, body.name, role]);
        const user = createdUser.rows[0];
        const token = jsonwebtoken_1.default.sign({ userId: user.id, role: user.role }, env_1.env.JWT_SECRET, { expiresIn: "7d" });
        res.status(201).json({
            token,
            user: {
                id: user.id,
                email: user.email,
                name: user.name,
                role: user.role
            }
        });
    }
    catch (error) {
        next(error);
    }
});
router.post("/login", async (req, res, next) => {
    try {
        const body = loginSchema.parse(req.body);
        const userResult = await db_1.pool.query(`
        SELECT id, email, password, name, role
        FROM users
        WHERE email = $1
        LIMIT 1
      `, [body.email]);
        const user = userResult.rows[0];
        if (!user) {
            res.status(401).json({ message: "Invalid credentials" });
            return;
        }
        const isPasswordValid = await bcryptjs_1.default.compare(body.password, user.password);
        if (!isPasswordValid) {
            res.status(401).json({ message: "Invalid credentials" });
            return;
        }
        const token = jsonwebtoken_1.default.sign({ userId: user.id, role: user.role }, env_1.env.JWT_SECRET, { expiresIn: "7d" });
        res.status(200).json({
            token,
            user: {
                id: user.id,
                email: user.email,
                name: user.name,
                role: user.role
            }
        });
    }
    catch (error) {
        next(error);
    }
});
exports.default = router;
