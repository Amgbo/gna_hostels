CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'user_account_status') THEN
    CREATE TYPE user_account_status AS ENUM ('ACTIVE', 'PENDING_VERIFICATION', 'SUSPENDED', 'DELETED');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'room_type') THEN
    CREATE TYPE room_type AS ENUM ('SINGLE', 'DOUBLE', 'TRIPLE', 'QUAD', 'SHARED', 'DORMITORY', 'STUDIO', 'APARTMENT');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'gender_type') THEN
    CREATE TYPE gender_type AS ENUM ('MALE', 'FEMALE', 'MIXED', 'ANY');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'hostel_status') THEN
    CREATE TYPE hostel_status AS ENUM ('DRAFT', 'PENDING_APPROVAL', 'ACTIVE', 'SUSPENDED', 'REJECTED', 'ARCHIVED');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'room_status') THEN
    CREATE TYPE room_status AS ENUM ('AVAILABLE', 'PARTIALLY_OCCUPIED', 'FULL', 'MAINTENANCE', 'INACTIVE');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'bed_status') THEN
    CREATE TYPE bed_status AS ENUM ('AVAILABLE', 'RESERVED', 'OCCUPIED', 'MAINTENANCE', 'OUT_OF_SERVICE');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'booking_status') THEN
    CREATE TYPE booking_status AS ENUM ('PENDING', 'AWAITING_PAYMENT', 'CONFIRMED', 'CHECKED_IN', 'CHECKED_OUT', 'COMPLETED', 'CANCELLED', 'EXPIRED', 'REJECTED');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'payment_status') THEN
    CREATE TYPE payment_status AS ENUM ('PENDING', 'PROCESSING', 'PAID', 'FAILED', 'REFUNDED', 'PARTIALLY_REFUNDED', 'VOIDED');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'payment_method') THEN
    CREATE TYPE payment_method AS ENUM ('CARD', 'BANK_TRANSFER', 'MOBILE_MONEY', 'WALLET', 'CASH', 'USSD');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'payment_provider') THEN
    CREATE TYPE payment_provider AS ENUM ('STRIPE', 'PAYSTACK', 'FLUTTERWAVE', 'PAYPAL', 'BANK_TRANSFER', 'MANUAL');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'review_status') THEN
    CREATE TYPE review_status AS ENUM ('PENDING', 'APPROVED', 'REJECTED', 'HIDDEN');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'notification_type') THEN
    CREATE TYPE notification_type AS ENUM ('BOOKING', 'PAYMENT', 'REVIEW', 'PROMOTION', 'MAINTENANCE', 'SYSTEM');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'discount_scope') THEN
    CREATE TYPE discount_scope AS ENUM ('GLOBAL', 'HOSTEL', 'ROOM');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'discount_type') THEN
    CREATE TYPE discount_type AS ENUM ('PERCENTAGE', 'FIXED_AMOUNT');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'booking_item_type') THEN
    CREATE TYPE booking_item_type AS ENUM ('ROOM', 'BED');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'maintenance_status') THEN
    CREATE TYPE maintenance_status AS ENUM ('REPORTED', 'IN_PROGRESS', 'RESOLVED', 'CLOSED');
  END IF;
END $$;

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION generate_reference(prefix text)
RETURNS text
LANGUAGE sql
VOLATILE
AS $$
  SELECT prefix || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));
$$;

-- Reference roles used for authorization and admin workflows.
CREATE TABLE IF NOT EXISTS roles (
  code text PRIMARY KEY,
  name text NOT NULL,
  description text,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz
);

INSERT INTO roles (code, name, description, is_active)
VALUES
  ('STUDENT', 'Student', 'Normal student account', true),
  ('LANDLORD', 'Hostel Owner', 'Hostel owner or manager account', true),
  ('ADMIN', 'Admin', 'Platform administrator', true)
ON CONFLICT (code) DO UPDATE
SET
  name = EXCLUDED.name,
  description = EXCLUDED.description,
  is_active = EXCLUDED.is_active,
  updated_at = now();

-- User accounts, credentials, and profile metadata.
CREATE TABLE IF NOT EXISTS users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email citext NOT NULL,
  password text,
  name text NOT NULL,
  role text NOT NULL DEFAULT 'STUDENT' REFERENCES roles(code) ON UPDATE CASCADE ON DELETE RESTRICT,
  phone text,
  avatar_url text,
  account_status user_account_status NOT NULL DEFAULT 'ACTIVE',
  email_verified_at timestamptz,
  last_login_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  CONSTRAINT users_name_not_blank CHECK (length(trim(name)) > 0),
  CONSTRAINT users_email_valid CHECK (
    email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_users_email_active
  ON users (email)
  WHERE deleted_at IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_users_phone_active
  ON users (phone)
  WHERE phone IS NOT NULL AND deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_users_role_active
  ON users (role)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_users_status_active
  ON users (account_status)
  WHERE deleted_at IS NULL;

-- External identity links for OAuth-based authentication.
CREATE TABLE IF NOT EXISTS oauth_identities (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  provider text NOT NULL,
  provider_user_id text NOT NULL,
  provider_email text,
  expires_at timestamptz,
  profile_json jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  CONSTRAINT uq_oauth_provider_identity UNIQUE (provider, provider_user_id)
);

CREATE INDEX IF NOT EXISTS idx_oauth_identities_user_id ON oauth_identities (user_id);
CREATE INDEX IF NOT EXISTS idx_oauth_identities_provider ON oauth_identities (provider);

-- Hostel listings owned by hostel landlords and moderated by admins.
CREATE TABLE IF NOT EXISTS hostels (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  landlord_id uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  deleted_by uuid REFERENCES users(id) ON DELETE SET NULL,
  slug text,
  name text NOT NULL,
  description text NOT NULL,
  address text NOT NULL,
  street_address text,
  city text,
  state text,
  region text,
  postal_code text,
  country text,
  latitude numeric(9,6),
  longitude numeric(9,6),
  distance_from_campus numeric(10,2) NOT NULL DEFAULT 0,
  hostel_status hostel_status NOT NULL DEFAULT 'PENDING_APPROVAL',
  gender_policy gender_type NOT NULL DEFAULT 'ANY',
  is_active boolean NOT NULL DEFAULT true,
  is_verified boolean NOT NULL DEFAULT false,
  approved_by uuid REFERENCES users(id) ON DELETE SET NULL,
  approved_at timestamptz,
  rejection_reason text,
  contact_email text,
  contact_phone text,
  website_url text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  CONSTRAINT hostels_distance_non_negative CHECK (distance_from_campus >= 0),
  CONSTRAINT hostels_latitude_valid CHECK (latitude IS NULL OR (latitude >= -90 AND latitude <= 90)),
  CONSTRAINT hostels_longitude_valid CHECK (longitude IS NULL OR (longitude >= -180 AND longitude <= 180))
);

CREATE INDEX IF NOT EXISTS idx_hostels_landlord_id ON hostels (landlord_id) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_hostels_slug_active ON hostels (lower(slug)) WHERE slug IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_hostels_status ON hostels (hostel_status) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_hostels_verified ON hostels (is_verified) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_hostels_active ON hostels (is_active) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_hostels_gender_policy ON hostels (gender_policy) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_hostels_distance_from_campus ON hostels (distance_from_campus) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_hostels_name_trgm ON hostels USING gin (name gin_trgm_ops) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_hostels_address_trgm ON hostels USING gin (address gin_trgm_ops) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_hostels_description_trgm ON hostels USING gin (description gin_trgm_ops) WHERE deleted_at IS NULL;

-- Amenity catalog shared across hostels and rooms.
CREATE TABLE IF NOT EXISTS amenities (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  category text NOT NULL DEFAULT 'general',
  icon text,
  description text,
  is_active boolean NOT NULL DEFAULT true,
  deleted_by uuid REFERENCES users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_amenities_name_active
  ON amenities (lower(name))
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_amenities_category_active
  ON amenities (category)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_amenities_active ON amenities (is_active) WHERE deleted_at IS NULL;

-- Many-to-many link between hostels and amenities.
CREATE TABLE IF NOT EXISTS hostel_amenities (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hostel_id uuid NOT NULL REFERENCES hostels(id) ON DELETE CASCADE,
  amenity_id uuid NOT NULL REFERENCES amenities(id) ON DELETE CASCADE,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_hostel_amenities_unique_active
  ON hostel_amenities (hostel_id, amenity_id)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_hostel_amenities_hostel_id ON hostel_amenities (hostel_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_hostel_amenities_amenity_id ON hostel_amenities (amenity_id) WHERE deleted_at IS NULL;

-- Rooms within a hostel, including bed counts, pricing, and availability.
CREATE TABLE IF NOT EXISTS rooms (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hostel_id uuid NOT NULL REFERENCES hostels(id) ON DELETE RESTRICT,
  deleted_by uuid REFERENCES users(id) ON DELETE SET NULL,
  room_number text NOT NULL,
  type room_type NOT NULL,
  total_beds integer NOT NULL,
  price_per_semester numeric(12,2) NOT NULL,
  available_beds integer NOT NULL,
  gender_type gender_type NOT NULL DEFAULT 'ANY',
  floor_number integer NOT NULL DEFAULT 1,
  room_status room_status NOT NULL DEFAULT 'AVAILABLE',
  is_active boolean NOT NULL DEFAULT true,
  description text,
  -- Audit fields for admin verification of individual rooms
  verified_by uuid REFERENCES users(id) ON DELETE SET NULL,
  verified_at timestamptz,
  check_in_time time NOT NULL DEFAULT '12:00'::time,
  check_out_time time NOT NULL DEFAULT '10:00'::time,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  CONSTRAINT rooms_total_beds_positive CHECK (total_beds > 0),
  CONSTRAINT rooms_available_beds_valid CHECK (available_beds >= 0 AND available_beds <= total_beds),
  CONSTRAINT rooms_price_non_negative CHECK (price_per_semester >= 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_rooms_hostel_room_number_active
  ON rooms (hostel_id, room_number)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_rooms_hostel_id ON rooms (hostel_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_rooms_type ON rooms (type) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_rooms_gender_type ON rooms (gender_type) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_rooms_status ON rooms (room_status) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_rooms_active ON rooms (is_active) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_rooms_price_per_semester ON rooms (price_per_semester) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_rooms_available_beds ON rooms (available_beds) WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_rooms_verified_by ON rooms (verified_by) WHERE deleted_at IS NULL;

-- Many-to-many link between rooms and amenities.
CREATE TABLE IF NOT EXISTS room_amenities (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  room_id uuid NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
  amenity_id uuid NOT NULL REFERENCES amenities(id) ON DELETE CASCADE,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_room_amenities_unique_active
  ON room_amenities (room_id, amenity_id)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_room_amenities_room_id ON room_amenities (room_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_room_amenities_amenity_id ON room_amenities (amenity_id) WHERE deleted_at IS NULL;

-- Physical beds inside a room for bed-space booking support.
CREATE TABLE IF NOT EXISTS beds (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  room_id uuid NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
  deleted_by uuid REFERENCES users(id) ON DELETE SET NULL,
  bed_number text NOT NULL,
  bed_label text,
  bed_status bed_status NOT NULL DEFAULT 'AVAILABLE',
  is_active boolean NOT NULL DEFAULT true,
  price_override numeric(12,2),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  CONSTRAINT beds_price_override_non_negative CHECK (price_override IS NULL OR price_override >= 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_beds_room_bed_number_active
  ON beds (room_id, bed_number)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_beds_room_id ON beds (room_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_beds_status ON beds (bed_status) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_beds_active ON beds (is_active) WHERE deleted_at IS NULL;

-- Booking headers for student reservations and payment tracking.
-- Academic terms / semesters table to support semester-based bookings
CREATE TABLE IF NOT EXISTS academic_terms (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  year integer NOT NULL,
  term smallint NOT NULL CHECK (term IN (1,2)), -- 1 = first semester, 2 = second semester
  title text,
  starts_at date,
  ends_at date,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  CONSTRAINT academic_terms_year_term_unique UNIQUE (year, term)
);

CREATE INDEX IF NOT EXISTS idx_academic_terms_year_term ON academic_terms (year, term) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS bookings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_reference text NOT NULL DEFAULT generate_reference('BKG-'),
  student_id uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  -- Link booking to an academic term/semester
  academic_term_id uuid NOT NULL REFERENCES academic_terms(id) ON DELETE RESTRICT,
  hostel_id uuid NOT NULL REFERENCES hostels(id) ON DELETE RESTRICT,
  booking_status booking_status NOT NULL DEFAULT 'PENDING',
  payment_status payment_status NOT NULL DEFAULT 'PENDING',
  check_in_date date NOT NULL,
  check_out_date date NOT NULL,
  reservation_expires_at timestamptz,
  cancelled_at timestamptz,
  cancellation_reason text,
  cancelled_by uuid REFERENCES users(id) ON DELETE SET NULL,
  subtotal_amount numeric(12,2) NOT NULL DEFAULT 0,
  discount_amount numeric(12,2) NOT NULL DEFAULT 0,
  total_amount numeric(12,2) NOT NULL DEFAULT 0,
  currency char(3) NOT NULL DEFAULT 'GHS',
  booking_source text,
  notes text,
  deleted_by uuid REFERENCES users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  CONSTRAINT bookings_date_window_valid CHECK (check_in_date < check_out_date),
  CONSTRAINT bookings_subtotal_non_negative CHECK (subtotal_amount >= 0),
  CONSTRAINT bookings_discount_non_negative CHECK (discount_amount >= 0),
  CONSTRAINT bookings_total_non_negative CHECK (total_amount >= 0),
  CONSTRAINT bookings_currency_length CHECK (char_length(currency) = 3)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_bookings_reference_active
  ON bookings (booking_reference)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_bookings_student_id ON bookings (student_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_bookings_academic_term_id ON bookings (academic_term_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_bookings_hostel_id ON bookings (hostel_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_bookings_status ON bookings (booking_status) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_bookings_payment_status ON bookings (payment_status) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_bookings_check_in_date ON bookings (check_in_date) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_bookings_check_out_date ON bookings (check_out_date) WHERE deleted_at IS NULL;

-- Prevent a student from creating more than one active booking per academic term
CREATE UNIQUE INDEX IF NOT EXISTS idx_bookings_student_term_unique
  ON bookings (student_id, academic_term_id)
  WHERE deleted_at IS NULL AND booking_status != 'CANCELLED';

-- Individual booking line items for rooms or bed spaces.
CREATE TABLE IF NOT EXISTS booking_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id uuid NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  item_type booking_item_type NOT NULL,
  room_id uuid NOT NULL REFERENCES rooms(id) ON DELETE RESTRICT,
  bed_id uuid REFERENCES beds(id) ON DELETE RESTRICT,
  quantity integer NOT NULL DEFAULT 1,
  unit_price numeric(12,2) NOT NULL,
  subtotal numeric(12,2) NOT NULL,
  allocated_at timestamptz,
  released_at timestamptz,
  deleted_by uuid REFERENCES users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  CONSTRAINT booking_items_quantity_positive CHECK (quantity > 0),
  CONSTRAINT booking_items_price_non_negative CHECK (unit_price >= 0 AND subtotal >= 0),
  CONSTRAINT booking_items_type_matches_parent CHECK (
    (item_type = 'ROOM' AND room_id IS NOT NULL AND bed_id IS NULL) OR
    (item_type = 'BED' AND room_id IS NOT NULL AND bed_id IS NOT NULL)
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_booking_items_unique_active
  ON booking_items (booking_id, item_type, room_id, COALESCE(bed_id, '00000000-0000-0000-0000-000000000000'::uuid))
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_booking_items_booking_id ON booking_items (booking_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_booking_items_room_id ON booking_items (room_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_booking_items_room_dates ON booking_items (room_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_booking_items_bed_id ON booking_items (bed_id) WHERE bed_id IS NOT NULL AND deleted_at IS NULL;

-- Payment records tied to bookings and external providers.
CREATE TABLE IF NOT EXISTS payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id uuid NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  transaction_reference text NOT NULL DEFAULT generate_reference('TXN-'),
  amount numeric(12,2) NOT NULL,
  currency char(3) NOT NULL DEFAULT 'GHS',
  payment_provider payment_provider NOT NULL,
  payment_method payment_method NOT NULL,
  payment_status payment_status NOT NULL DEFAULT 'PENDING',
  provider_reference text,
  paid_at timestamptz,
  failure_reason text,
  raw_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  deleted_by uuid REFERENCES users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  CONSTRAINT payments_amount_non_negative CHECK (amount >= 0),
  CONSTRAINT payments_currency_length CHECK (char_length(currency) = 3)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_payments_transaction_reference_active
  ON payments (transaction_reference)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_payments_booking_id ON payments (booking_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_payments_status ON payments (payment_status) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_payments_provider ON payments (payment_provider) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_payments_method ON payments (payment_method) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_payments_paid_at ON payments (paid_at) WHERE deleted_at IS NULL;

-- Student reviews and moderation status for hostel quality control.
CREATE TABLE IF NOT EXISTS reviews (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hostel_id uuid NOT NULL REFERENCES hostels(id) ON DELETE CASCADE,
  room_id uuid REFERENCES rooms(id) ON DELETE SET NULL,
  booking_id uuid UNIQUE REFERENCES bookings(id) ON DELETE SET NULL,
  student_id uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  rating smallint NOT NULL,
  title text,
  comment text NOT NULL,
  review_status review_status NOT NULL DEFAULT 'PENDING',
  moderated_by uuid REFERENCES users(id) ON DELETE SET NULL,
  moderated_at timestamptz,
  moderation_reason text,
  deleted_by uuid REFERENCES users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  CONSTRAINT reviews_rating_valid CHECK (rating BETWEEN 1 AND 5)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_reviews_booking_unique_active
  ON reviews (booking_id)
  WHERE booking_id IS NOT NULL AND deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_reviews_hostel_id ON reviews (hostel_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_reviews_room_id ON reviews (room_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_reviews_student_id ON reviews (student_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_reviews_status ON reviews (review_status) WHERE deleted_at IS NULL;

-- Image gallery entries for hostels and rooms.
CREATE TABLE IF NOT EXISTS images (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hostel_id uuid REFERENCES hostels(id) ON DELETE CASCADE,
  room_id uuid REFERENCES rooms(id) ON DELETE CASCADE,
  uploaded_by uuid REFERENCES users(id) ON DELETE SET NULL,
  storage_key text NOT NULL,
  image_url text NOT NULL,
  image_type text NOT NULL DEFAULT 'gallery',
  caption text,
  alt_text text,
  mime_type text,
  file_size_bytes bigint,
  sort_order integer NOT NULL DEFAULT 0,
  is_primary boolean NOT NULL DEFAULT false,
  deleted_by uuid REFERENCES users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  CONSTRAINT images_single_parent CHECK (
    (hostel_id IS NOT NULL AND room_id IS NULL) OR
    (hostel_id IS NULL AND room_id IS NOT NULL)
  ),
  CONSTRAINT images_file_size_non_negative CHECK (file_size_bytes IS NULL OR file_size_bytes >= 0)
);

CREATE INDEX IF NOT EXISTS idx_images_hostel_id ON images (hostel_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_images_room_id ON images (room_id) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_images_primary_hostel ON images (hostel_id) WHERE hostel_id IS NOT NULL AND is_primary AND deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_images_primary_room ON images (room_id) WHERE room_id IS NOT NULL AND is_primary AND deleted_at IS NULL;

-- Discount and promotion rules for bookings.
CREATE TABLE IF NOT EXISTS discounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code text NOT NULL,
  title text NOT NULL,
  description text,
  discount_scope discount_scope NOT NULL DEFAULT 'GLOBAL',
  discount_type discount_type NOT NULL,
  discount_value numeric(12,2) NOT NULL,
  hostel_id uuid REFERENCES hostels(id) ON DELETE CASCADE,
  room_id uuid REFERENCES rooms(id) ON DELETE CASCADE,
  starts_at timestamptz,
  ends_at timestamptz,
  usage_limit integer,
  usage_count integer NOT NULL DEFAULT 0,
  min_booking_amount numeric(12,2) NOT NULL DEFAULT 0,
  max_discount_amount numeric(12,2),
  is_active boolean NOT NULL DEFAULT true,
  created_by uuid REFERENCES users(id) ON DELETE SET NULL,
  updated_by uuid REFERENCES users(id) ON DELETE SET NULL,
  deleted_by uuid REFERENCES users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  CONSTRAINT discounts_scope_matches_parent CHECK (
    (discount_scope = 'GLOBAL' AND hostel_id IS NULL AND room_id IS NULL) OR
    (discount_scope = 'HOSTEL' AND hostel_id IS NOT NULL AND room_id IS NULL) OR
    (discount_scope = 'ROOM' AND hostel_id IS NULL AND room_id IS NOT NULL)
  ),
  CONSTRAINT discounts_value_valid CHECK (
    (discount_type = 'PERCENTAGE' AND discount_value > 0 AND discount_value <= 100) OR
    (discount_type = 'FIXED_AMOUNT' AND discount_value > 0)
  ),
  CONSTRAINT discounts_usage_limit_valid CHECK (usage_limit IS NULL OR usage_limit > 0),
  CONSTRAINT discounts_amounts_valid CHECK (
    min_booking_amount >= 0 AND (max_discount_amount IS NULL OR max_discount_amount >= 0)
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_discounts_code_active
  ON discounts (lower(code))
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_discounts_scope_active ON discounts (discount_scope) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_discounts_hostel_id ON discounts (hostel_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_discounts_room_id ON discounts (room_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_discounts_active_period ON discounts (starts_at, ends_at) WHERE deleted_at IS NULL;

-- Student favorites and saved hostels.
CREATE TABLE IF NOT EXISTS favorites (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  hostel_id uuid NOT NULL REFERENCES hostels(id) ON DELETE CASCADE,
  deleted_by uuid REFERENCES users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_favorites_user_hostel_active
  ON favorites (user_id, hostel_id)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_favorites_user_id ON favorites (user_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_favorites_hostel_id ON favorites (hostel_id) WHERE deleted_at IS NULL;

-- In-app notifications for students, owners, and admins.
CREATE TABLE IF NOT EXISTS notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  notification_type notification_type NOT NULL,
  title text NOT NULL,
  message text NOT NULL,
  action_url text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  sent_at timestamptz NOT NULL DEFAULT now(),
  read_at timestamptz,
  expires_at timestamptz,
  deleted_by uuid REFERENCES users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz
);

CREATE INDEX IF NOT EXISTS idx_notifications_user_id ON notifications (user_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_notifications_read_at ON notifications (user_id, read_at) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_notifications_type ON notifications (notification_type) WHERE deleted_at IS NULL;

-- Operational log for room maintenance events and incidents.
CREATE TABLE IF NOT EXISTS maintenance_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  room_id uuid NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
  bed_id uuid REFERENCES beds(id) ON DELETE SET NULL,
  reported_by uuid REFERENCES users(id) ON DELETE SET NULL,
  assigned_to uuid REFERENCES users(id) ON DELETE SET NULL,
  resolved_by uuid REFERENCES users(id) ON DELETE SET NULL,
  maintenance_status maintenance_status NOT NULL DEFAULT 'REPORTED',
  title text NOT NULL,
  description text,
  downtime_reason text,
  started_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz,
  resolution_notes text,
  deleted_by uuid REFERENCES users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz
);

CREATE INDEX IF NOT EXISTS idx_maintenance_logs_room_id ON maintenance_logs (room_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_maintenance_logs_bed_id ON maintenance_logs (bed_id) WHERE bed_id IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_maintenance_logs_status ON maintenance_logs (maintenance_status) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_maintenance_logs_started_at ON maintenance_logs (started_at) WHERE deleted_at IS NULL;

DO $$
DECLARE
  table_name text;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'roles',
    'users',
    'oauth_identities',
    'hostels',
    'amenities',
    'hostel_amenities',
    'rooms',
    'room_amenities',
    'beds',
    'bookings',
    'booking_items',
    'payments',
    'reviews',
    'images',
    'discounts',
    'favorites',
    'notifications',
    'maintenance_logs'
  ] LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM pg_trigger
      WHERE tgname = format('trg_%s_updated_at', table_name)
    ) THEN
      EXECUTE format(
        'CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION set_updated_at()',
        table_name,
        table_name
      );
    END IF;
  END LOOP;
END $$;