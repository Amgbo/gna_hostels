"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.errorHandler = exports.notFoundHandler = void 0;
const notFoundHandler = (_req, res) => {
    res.status(404).json({ message: "Route not found" });
};
exports.notFoundHandler = notFoundHandler;
const errorHandler = (err, _req, res, _next) => {
    console.error(err);
    if (err instanceof Error) {
        res.status(500).json({ message: err.message });
        return;
    }
    res.status(500).json({ message: "Internal Server Error" });
};
exports.errorHandler = errorHandler;
