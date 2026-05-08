import { Request, Response, NextFunction } from "express";
import jwt from "jsonwebtoken";
import { env } from "../config/env";

export interface AuthRequest extends Request {
  user?: { userId: string; role: string };
}

export function requireAuth(req: AuthRequest, res: Response, next: NextFunction) {
  try {
    const auth = req.headers.authorization;
    if (!auth || !auth.startsWith("Bearer ")) {
      res.status(401).json({ message: "Missing authorization" });
      return;
    }

    const token = auth.slice("Bearer ".length);
    const payload = jwt.verify(token, env.JWT_SECRET) as { userId: string; role: string };
    req.user = { userId: payload.userId, role: payload.role };
    next();
  } catch (err) {
    res.status(401).json({ message: "Invalid token" });
  }
}

/**
 * Factory function to create role-based access control middleware
 * @param allowedRoles - Array of roles that are allowed to access this route
 */
export function requireRole(allowedRoles: string[]) {
  return (req: AuthRequest, res: Response, next: NextFunction) => {
    if (!req.user) {
      res.status(401).json({ message: "Missing authorization" });
      return;
    }

    if (!allowedRoles.includes(req.user.role)) {
      res.status(403).json({ 
        message: "Insufficient permissions",
        required_role: allowedRoles,
        current_role: req.user.role
      });
      return;
    }

    next();
  };
}
