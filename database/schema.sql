-- Step 1: Schema Setup for Baan Na Resort

-- 1. Enable UUID Extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- 2. Create Profiles table (Linked to Auth)
CREATE TABLE IF NOT EXISTS public.profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    email TEXT UNIQUE NOT NULL,
    full_name TEXT,
    phone TEXT,
    role TEXT DEFAULT 'user' CHECK (role IN ('user', 'admin')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

-- 3. Create Rooms table (Static Metadata)
CREATE TABLE IF NOT EXISTS public.rooms (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name TEXT NOT NULL,
    type TEXT NOT NULL,
    price DECIMAL(10, 2) NOT NULL,
    image_url TEXT,
    description TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

-- 4. Create Bookings table (The Source of Truth for Room Status)
CREATE TABLE IF NOT EXISTS public.bookings (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    room_id UUID NOT NULL REFERENCES public.rooms(id) ON DELETE CASCADE,
    status TEXT DEFAULT 'pending_payment' CHECK (status IN ('pending_payment', 'awaiting_verification', 'paid', 'cancelled')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL
);

-- 5. Create Payments table
CREATE TABLE IF NOT EXISTS public.payments (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    booking_id UUID NOT NULL REFERENCES public.bookings(id) ON DELETE CASCADE,
    slip_url TEXT,
    amount DECIMAL(10, 2) NOT NULL,
    status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected')),
    uploaded_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

-- 6. Create Settings table
CREATE TABLE IF NOT EXISTS public.settings (
    id SERIAL PRIMARY KEY,
    bank_name TEXT,
    account_number TEXT,
    account_name TEXT,
    qr_code_url TEXT,
    resort_map_url TEXT,
    booking_expiry_mins INTEGER DEFAULT 30,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

-- 7. Create Admin Logs table
CREATE TABLE IF NOT EXISTS public.admin_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    admin_id UUID REFERENCES public.profiles(id),
    action TEXT NOT NULL,
    target_id TEXT,
    details JSONB,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

-- 6. Trigger to create Profile on Auth Signup
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger AS $$
BEGIN
    INSERT INTO public.profiles (id, email, full_name)
    VALUES (new.id, new.email, new.raw_user_meta_data->>'full_name');
    RETURN new;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE PROCEDURE public.handle_new_user();

-- 7. Atomic Booking Function (v3)
-- Improvements: Fetches expiry from settings inside the function, fully atomic.
CREATE OR REPLACE FUNCTION public.create_booking_v2(p_room_id UUID)
RETURNS UUID AS $$
DECLARE
    v_booking_id UUID;
    v_expiry_mins INTEGER;
    v_user_id UUID := auth.uid();
BEGIN
    -- 1. Verify Authentication
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'ต้องเข้าสู่ระบบก่อนทำการจองครับ';
    END IF;

    -- 2. Fetch booking expiry from settings
    SELECT booking_expiry_mins INTO v_expiry_mins FROM public.settings WHERE id = 1;
    IF v_expiry_mins IS NULL THEN v_expiry_mins := 30; END IF;

    -- 3. Atomically check and lock the room status
    IF EXISTS (
        SELECT 1 FROM public.bookings
        WHERE room_id = p_room_id
        AND status IN ('pending_payment', 'paid', 'awaiting_verification')
        AND expires_at > NOW()
        FOR UPDATE
    ) THEN
        RAISE EXCEPTION 'ห้องนี้ไม่ว่างหรือมีการจองค้างอยู่ครับ';
    END IF;

    -- 4. Create the booking
    INSERT INTO public.bookings (user_id, room_id, status, expires_at)
    VALUES (v_user_id, p_room_id, 'pending_payment', NOW() + (v_expiry_mins || ' minutes')::interval)
    RETURNING id INTO v_booking_id;

    RETURN v_booking_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 7.1 Submit Payment Slip Function
CREATE OR REPLACE FUNCTION public.submit_payment_slip(p_booking_id UUID, p_slip_url TEXT, p_amount DECIMAL)
RETURNS VOID AS $$
BEGIN
    -- 1. Verify ownership and status
    IF NOT EXISTS (
        SELECT 1 FROM public.bookings 
        WHERE id = p_booking_id AND user_id = auth.uid() AND expires_at > NOW()
    ) THEN
        RAISE EXCEPTION 'รายการจองหมดอายุหรือหาไม่เจอครับ';
    END IF;

    -- 2. Insert payment record
    INSERT INTO public.payments (booking_id, slip_url, amount, status)
    VALUES (p_booking_id, p_slip_url, p_amount, 'pending');

    -- 3. Update booking status
    UPDATE public.bookings 
    SET status = 'awaiting_verification' 
    WHERE id = p_booking_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 7.2 Admin Approve Payment Function
CREATE OR REPLACE FUNCTION public.admin_approve_booking(p_booking_id UUID)
RETURNS VOID AS $$
BEGIN
    -- 1. Check Admin Role from DB
    IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin') THEN
        RAISE EXCEPTION 'สิทธิ์ไม่เพียงพอ สงวนไว้สำหรับผู้ดูแลระบบ';
    END IF;

    -- 2. Update status
    UPDATE public.payments SET status = 'approved' WHERE booking_id = p_booking_id;
    UPDATE public.bookings SET status = 'paid' WHERE id = p_booking_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 7.3 Admin Statistics function
CREATE OR REPLACE FUNCTION public.get_admin_stats()
RETURNS JSON AS $$
DECLARE
    v_stats JSON;
BEGIN
    -- Only admins can call this
    IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin') THEN
        RAISE EXCEPTION 'สิทธิ์ไม่เพียงพอ';
    END IF;

    SELECT json_build_object(
        'total_revenue', COALESCE((SELECT SUM(amount) FROM public.payments WHERE status = 'approved'), 0),
        'revenue_today', COALESCE((SELECT SUM(amount) FROM public.payments WHERE status = 'approved' AND uploaded_at::date = CURRENT_DATE), 0),
        'revenue_month', COALESCE((SELECT SUM(amount) FROM public.payments WHERE status = 'approved' AND date_trunc('month', uploaded_at) = date_trunc('month', CURRENT_DATE)), 0),
        'total_bookings', (SELECT COUNT(*) FROM public.bookings),
        'paid_bookings', (SELECT COUNT(*) FROM public.bookings WHERE status = 'paid'),
        'pending_payment', (SELECT COUNT(*) FROM public.bookings WHERE status = 'pending_payment'),
        'awaiting_verification', (SELECT COUNT(*) FROM public.bookings WHERE status = 'awaiting_verification')
    ) INTO v_stats;

    RETURN v_stats;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 7.4 Auto-expire Cleanup function (Can be called by any auth user or cron)
CREATE OR REPLACE FUNCTION public.check_and_cancel_expired_bookings()
RETURNS VOID AS $$
BEGIN
    UPDATE public.bookings
    SET status = 'cancelled'
    WHERE status = 'pending_payment'
    AND expires_at < NOW();
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 8. Row Level Security (RLS) Policies

-- Profiles: Users can read/update their own profile. Admins can see all.
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their own profile" ON public.profiles
    FOR SELECT USING (auth.uid() = id);

CREATE POLICY "Admins can view all profiles" ON public.profiles
    FOR ALL USING (
        EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
    );

-- Rooms: Anyone can read. Admins can manage.
ALTER TABLE public.rooms ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can view rooms" ON public.rooms
    FOR SELECT TO public USING (true);

CREATE POLICY "Admins can manage rooms" ON public.rooms
    FOR ALL USING (
        EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
    );

-- Bookings: Users can view their own. Anyone can view booking status (for map). Admins manage.
ALTER TABLE public.bookings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can view booking status" ON public.bookings
    FOR SELECT TO public USING (true);

CREATE POLICY "Users can create their own bookings" ON public.bookings
    FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can view/update their own bookings" ON public.bookings
    FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Admins can manage bookings" ON public.bookings
    FOR ALL USING (
        EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
    );

-- Payments: Users can see their own. Admins can manage.
ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their own payments" ON public.payments
    FOR SELECT USING (
        EXISTS (SELECT 1 FROM public.bookings WHERE id = booking_id AND user_id = auth.uid())
    );

CREATE POLICY "Users can upload their own payment" ON public.payments
    FOR INSERT WITH CHECK (
        EXISTS (SELECT 1 FROM public.bookings WHERE id = booking_id AND user_id = auth.uid())
    );

CREATE POLICY "Admins can manage payments" ON public.payments
    FOR ALL USING (
        EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
    );

-- Settings: Anyone can view. Admins can manage.
ALTER TABLE public.settings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can view settings" ON public.settings
    FOR SELECT TO public USING (true);

CREATE POLICY "Admins can manage settings" ON public.settings
    FOR ALL USING (
        EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
    );

-- Admin Logs: Only admins can view/manage.
ALTER TABLE public.admin_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins can manage logs" ON public.admin_logs
    FOR ALL USING (
        EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
    );

-- 9. Storage Buckets Setup (Instructional)
-- Note: Supabase Storage policies need to be set in the Dashboard or via API.
-- bucket: 'rooms' (public read)
-- bucket: 'slips' (private read, only admin and owner)

-- 10. Initial Settings
INSERT INTO public.settings (id, bank_name, account_number, account_name, qr_code_url, resort_map_url, booking_expiry_mins) VALUES
(1, 'Kasikorn Bank (KBank)', '123-456-7890', 'Baan Na Resort Co., Ltd.', 'https://example.com/qr-code.png', '/images/resort-map.png', 30)
ON CONFLICT (id) DO NOTHING;

-- 11. Initial Room Data (Mock)
INSERT INTO public.rooms (name, type, price, image_url, description) VALUES
('R01', 'Standard', 1200.00, 'https://picsum.photos/800/600?random=1', 'Standard room with pool view'),
('R02', 'Standard', 1200.00, 'https://picsum.photos/800/600?random=2', 'Standard room with garden view'),
('R03', 'Standard', 1200.00, 'https://picsum.photos/800/600?random=3', 'Standard room near lobby'),
('R04', 'Standard', 1200.00, 'https://picsum.photos/800/600?random=4', 'Standard room quiet zone'),
('R05', 'Deluxe', 1800.00, 'https://picsum.photos/800/600?random=5', 'Deluxe room with balcony'),
('R06', 'Deluxe', 1800.00, 'https://picsum.photos/800/600?random=6', 'Deluxe room near beach'),
('R07', 'Deluxe', 1800.00, 'https://picsum.photos/800/600?random=7', 'Deluxe room mountain view'),
('R08', 'Deluxe', 1800.00, 'https://picsum.photos/800/600?random=8', 'Deluxe room luxury setup'),
('R09', 'Suite', 2500.00, 'https://picsum.photos/800/600?random=9', 'Suite room with private pool'),
('R10', 'Suite', 2500.00, 'https://picsum.photos/800/600?random=10', 'Presidential Suite');

-- 12. Storage Buckets & Policies
-- Note: These commands initialize buckets and secure them.

-- Create Buckets
INSERT INTO storage.buckets (id, name, public) VALUES ('rooms', 'rooms', true) ON CONFLICT (id) DO NOTHING;
INSERT INTO storage.buckets (id, name, public) VALUES ('slips', 'slips', false) ON CONFLICT (id) DO NOTHING;

-- Rooms Policy: Public Read (Anyone can see the resort rooms)
CREATE POLICY "Public Read Rooms" ON storage.objects FOR SELECT TO public USING (bucket_id = 'rooms');

-- Rooms Policy: Admin Manage (Only admins can upload/delete room photos)
CREATE POLICY "Admin Manage Rooms" ON storage.objects FOR ALL TO authenticated USING (
    bucket_id = 'rooms' AND (SELECT role FROM public.profiles WHERE id = auth.uid()) = 'admin'
);

-- Slips Policy: User Upload (Customers can upload their own slips)
CREATE POLICY "User Upload Slips" ON storage.objects FOR INSERT TO authenticated WITH CHECK (
    bucket_id = 'slips'
);

-- Slips Policy: Admin Read (Admins can see all slips for verification)
CREATE POLICY "Admin View All Slips" ON storage.objects FOR SELECT TO authenticated USING (
    bucket_id = 'slips' AND (SELECT role FROM public.profiles WHERE id = auth.uid()) = 'admin'
);

-- Slips Policy: Owner Read (Users can see their own uploaded slips)
CREATE POLICY "Owner Read Slips" ON storage.objects FOR SELECT TO authenticated USING (
    bucket_id = 'slips' AND auth.uid() = owner
);
