-- ============================================
-- UKRAINE TRIPS & CARGO - Supabase SQL Setup
-- Виконай цей код у Supabase SQL Editor
-- ============================================

-- 1. РОЗШИРЕННЯ
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- 2. ТАБЛИЦЯ КОРИСТУВАЧІВ
CREATE TABLE public.users (
  id UUID REFERENCES auth.users(id) ON DELETE CASCADE PRIMARY KEY,
  full_name TEXT NOT NULL,
  email TEXT,
  avatar_url TEXT,
  role TEXT DEFAULT 'user' CHECK (role IN ('user', 'admin')),
  is_banned BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 3. ТАБЛИЦЯ РЕЙСІВ
CREATE TABLE public.trips (
  id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  from_city TEXT NOT NULL,
  to_city TEXT NOT NULL,
  trip_date DATE NOT NULL,
  trip_time TIME NOT NULL,
  price NUMERIC(10,2) NOT NULL,
  total_seats INT NOT NULL DEFAULT 4,
  available_seats INT NOT NULL DEFAULT 4,
  driver_name TEXT NOT NULL,
  driver_phone TEXT NOT NULL,
  driver_contact TEXT,
  notes TEXT,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 4. ТАБЛИЦЯ БРОНЮВАНЬ
CREATE TABLE public.bookings (
  id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  user_id UUID REFERENCES public.users(id) ON DELETE CASCADE NOT NULL,
  trip_id UUID REFERENCES public.trips(id) ON DELETE CASCADE NOT NULL,
  seats_booked INT NOT NULL DEFAULT 1,
  status TEXT DEFAULT 'confirmed' CHECK (status IN ('confirmed', 'cancelled')),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(user_id, trip_id)
);

-- 5. ТАБЛИЦЯ ЗАЯВОК НА ВАНТАЖ
CREATE TABLE public.cargo_requests (
  id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  user_id UUID REFERENCES public.users(id) ON DELETE CASCADE NOT NULL,
  from_city TEXT NOT NULL,
  to_city TEXT NOT NULL,
  cargo_date DATE NOT NULL,
  description TEXT NOT NULL,
  status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'confirmed', 'rejected')),
  admin_note TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 6. ТАБЛИЦЯ ВІДГУКІВ
CREATE TABLE public.reviews (
  id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  user_id UUID REFERENCES public.users(id) ON DELETE CASCADE NOT NULL,
  rating INT NOT NULL CHECK (rating BETWEEN 1 AND 5),
  text TEXT NOT NULL,
  is_visible BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================
-- ROW LEVEL SECURITY (RLS)
-- ============================================

ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.trips ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bookings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cargo_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reviews ENABLE ROW LEVEL SECURITY;

-- USERS policies
CREATE POLICY "Users can view own profile" ON public.users
  FOR SELECT USING (auth.uid() = id);

CREATE POLICY "Users can update own profile" ON public.users
  FOR UPDATE USING (auth.uid() = id);

CREATE POLICY "Admin can view all users" ON public.users
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.users WHERE id = auth.uid() AND role = 'admin')
  );

CREATE POLICY "Allow insert on registration" ON public.users
  FOR INSERT WITH CHECK (auth.uid() = id);

-- TRIPS policies
CREATE POLICY "Anyone can view active trips" ON public.trips
  FOR SELECT USING (is_active = TRUE);

CREATE POLICY "Admin can manage trips" ON public.trips
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.users WHERE id = auth.uid() AND role = 'admin')
  );

-- BOOKINGS policies
CREATE POLICY "Users can view own bookings" ON public.bookings
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Users can create bookings" ON public.bookings
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can cancel own bookings" ON public.bookings
  FOR UPDATE USING (auth.uid() = user_id);

CREATE POLICY "Admin can view all bookings" ON public.bookings
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.users WHERE id = auth.uid() AND role = 'admin')
  );

-- CARGO policies
CREATE POLICY "Users can view own cargo" ON public.cargo_requests
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Users can create cargo requests" ON public.cargo_requests
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Admin can manage cargo" ON public.cargo_requests
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.users WHERE id = auth.uid() AND role = 'admin')
  );

-- REVIEWS policies
CREATE POLICY "Anyone can view visible reviews" ON public.reviews
  FOR SELECT USING (is_visible = TRUE);

CREATE POLICY "Auth users can create reviews" ON public.reviews
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own reviews" ON public.reviews
  FOR UPDATE USING (auth.uid() = user_id);

CREATE POLICY "Admin can manage reviews" ON public.reviews
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.users WHERE id = auth.uid() AND role = 'admin')
  );

-- ============================================
-- ФУНКЦІЇ ТА ТРИГЕРИ
-- ============================================

-- Автоматичне зменшення місць при бронюванні
CREATE OR REPLACE FUNCTION update_seats_on_booking()
RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE public.trips
    SET available_seats = available_seats - NEW.seats_booked
    WHERE id = NEW.trip_id;
  ELSIF TG_OP = 'UPDATE' AND OLD.status = 'confirmed' AND NEW.status = 'cancelled' THEN
    UPDATE public.trips
    SET available_seats = available_seats + OLD.seats_booked
    WHERE id = OLD.trip_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER booking_seats_trigger
AFTER INSERT OR UPDATE ON public.bookings
FOR EACH ROW EXECUTE FUNCTION update_seats_on_booking();

-- Автоматичне створення профілю після реєстрації
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.users (id, email, full_name, avatar_url)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'full_name', ''),
    COALESCE(NEW.raw_user_meta_data->>'avatar_url', '')
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION handle_new_user();

-- ============================================
-- STORAGE BUCKET ДЛЯ АВАТАРІВ
-- ============================================

INSERT INTO storage.buckets (id, name, public) VALUES ('avatars', 'avatars', true)
ON CONFLICT DO NOTHING;

CREATE POLICY "Avatar images are publicly accessible" ON storage.objects
  FOR SELECT USING (bucket_id = 'avatars');

CREATE POLICY "Users can upload their avatar" ON storage.objects
  FOR INSERT WITH CHECK (
    bucket_id = 'avatars' AND auth.uid()::text = (storage.foldername(name))[1]
  );

CREATE POLICY "Users can update their avatar" ON storage.objects
  FOR UPDATE USING (
    bucket_id = 'avatars' AND auth.uid()::text = (storage.foldername(name))[1]
  );

-- ============================================
-- ТЕСТОВІ ДАНІ - РЕЙСИ (30 днів вперед)
-- ============================================

INSERT INTO public.trips (from_city, to_city, trip_date, trip_time, price, total_seats, available_seats, driver_name, driver_phone, driver_contact)
VALUES
  ('Київ', 'Львів', CURRENT_DATE + 1, '07:00', 450, 4, 4, 'Олександр Петренко', '+380671234567', 'Telegram: @alex_driver'),
  ('Київ', 'Харків', CURRENT_DATE + 1, '08:30', 350, 4, 4, 'Микола Іваненко', '+380501234567', 'Viber: +380501234567'),
  ('Київ', 'Одеса', CURRENT_DATE + 2, '06:00', 500, 4, 4, 'Сергій Коваль', '+380631234567', 'Telegram: @serg_driver'),
  ('Львів', 'Київ', CURRENT_DATE + 2, '09:00', 450, 4, 3, 'Василь Мельник', '+380971234567', 'Viber: +380971234567'),
  ('Харків', 'Київ', CURRENT_DATE + 3, '07:30', 350, 4, 4, 'Андрій Бондар', '+380661234567', 'Telegram: @andrii_b'),
  ('Київ', 'Дніпро', CURRENT_DATE + 3, '10:00', 300, 4, 4, 'Іван Шевченко', '+380731234567', 'Viber: +380731234567'),
  ('Одеса', 'Київ', CURRENT_DATE + 4, '05:30', 500, 4, 2, 'Дмитро Лисенко', '+380991234567', 'Telegram: @dmytro_l'),
  ('Київ', 'Запоріжжя', CURRENT_DATE + 4, '11:00', 320, 4, 4, 'Павло Романенко', '+380671111111', 'Viber: +380671111111'),
  ('Дніпро', 'Київ', CURRENT_DATE + 5, '08:00', 300, 4, 4, 'Роман Ткаченко', '+380502222222', 'Telegram: @roman_t'),
  ('Київ', 'Полтава', CURRENT_DATE + 5, '09:30', 200, 4, 4, 'Юрій Гончаренко', '+380633333333', 'Viber: +380633333333'),
  ('Київ', 'Вінниця', CURRENT_DATE + 6, '08:00', 180, 4, 4, 'Олег Марченко', '+380974444444', 'Telegram: @oleg_m'),
  ('Вінниця', 'Київ', CURRENT_DATE + 7, '09:00', 180, 4, 4, 'Тарас Кравченко', '+380665555555', 'Viber: +380665555555'),
  ('Київ', 'Суми', CURRENT_DATE + 7, '07:00', 250, 4, 4, 'Владислав Левченко', '+380736666666', 'Telegram: @vlad_l'),
  ('Київ', 'Чернігів', CURRENT_DATE + 8, '10:00', 150, 4, 4, 'Богдан Савченко', '+380997777777', 'Viber: +380997777777'),
  ('Чернігів', 'Київ', CURRENT_DATE + 9, '08:30', 150, 4, 4, 'Максим Поліщук', '+380678888888', 'Telegram: @max_p');

-- ============================================
-- ЗРОБИТИ ПЕРШОГО КОРИСТУВАЧА АДМІНОМ
-- (виконай після реєстрації)
-- UPDATE public.users SET role = 'admin' WHERE email = 'your@email.com';
-- ============================================
