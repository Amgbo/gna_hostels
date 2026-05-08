export const USER_ROLES = ["STUDENT", "LANDLORD", "ADMIN"] as const;

export type UserRole = (typeof USER_ROLES)[number];