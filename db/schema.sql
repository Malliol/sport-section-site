-- Схема БД: типовой сайт спортивной школы / секции (один проект, PostgreSQL 15+)
-- Соответствует PLAN.md, разделы 2, 4, 7.
-- Порядок: 0 база -> 1 люди и роли -> 2 каталог -> 3 группы и занятия ->
-- 4 зачисление и места -> 5 здоровье и документы -> 6 финансы ->
-- 7 посещаемость и прогресс -> 8 события -> 9 коммуникации -> 10 контент -> 11 аудит.

CREATE EXTENSION IF NOT EXISTS citext;

-- =====================================================================
-- 0. НАСТРОЙКИ ШКОЛЫ (одна строка; заменяет site.yml)
-- =====================================================================
CREATE TABLE org_settings (
    id                  boolean PRIMARY KEY DEFAULT true CHECK (id),   -- ровно одна строка
    name                text    NOT NULL,
    short_name          text,
    licensed            boolean NOT NULL DEFAULT false,                -- флаг license
    flags               jsonb   NOT NULL DEFAULT '{}',                 -- adults, levels, support, services, volunteers, distance, streams, sponsors, seo_sport_place
    vocabulary          jsonb   NOT NULL DEFAULT '{}',                 -- тренер/педагог, объект/зал, сезон/учебный год, ...
    athlete_naming      text    NOT NULL DEFAULT 'anonymous' CHECK (athlete_naming IN ('anonymous','named_with_consent')),
    contacts            jsonb   NOT NULL DEFAULT '{}',                 -- телефоны, мессенджеры, соцсети
    requisites          jsonb   NOT NULL DEFAULT '{}',
    lead_destination    jsonb   NOT NULL DEFAULT '{}',                 -- куда отправлять заявки
    safety              jsonb   NOT NULL DEFAULT '{}',                 -- ответственное лицо, политика «привёл-забрал», ссылки на кодексы
    cabinet_mode        text    NOT NULL DEFAULT 'builtin' CHECK (cabinet_mode IN ('none','external_url','builtin')),
    updated_at          timestamptz NOT NULL DEFAULT now()
);

-- =====================================================================
-- 1. ЛЮДИ И РОЛИ
-- Принцип: один аккаунт = один человек, роли навешиваются со scope.
-- =====================================================================
CREATE TABLE accounts (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    phone         text UNIQUE,
    email         citext UNIQUE,
    full_name     text NOT NULL,
    avatar_key    text,
    is_active     boolean NOT NULL DEFAULT true,
    last_login_at timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now(),
    CHECK (phone IS NOT NULL OR email IS NOT NULL)
);

CREATE TYPE role_code AS ENUM (
    'guest','guardian','athlete','trainer','dept_head','admin',
    'medic','referee','accountant','owner'
);
CREATE TYPE scope_type AS ENUM ('org','department','group','student','event');

-- Роль = набор прав (в коде) + привязка. Права без привязки ничего не дают.
CREATE TABLE role_assignments (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id  uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    role        role_code  NOT NULL,
    scope       scope_type NOT NULL DEFAULT 'org',
    scope_id    uuid,                                  -- NULL только для scope='org'
    granted_by  uuid REFERENCES accounts(id),
    valid_from  date NOT NULL DEFAULT current_date,
    valid_to    date,
    CHECK ((scope = 'org') = (scope_id IS NULL)),
    CHECK (valid_to IS NULL OR valid_to >= valid_from)
);
CREATE UNIQUE INDEX role_assignments_uq
    ON role_assignments (account_id, role, scope, COALESCE(scope_id, '00000000-0000-0000-0000-000000000000'::uuid));
CREATE INDEX role_assignments_scope_idx ON role_assignments (scope, scope_id);

-- Ученик — сущность. Собственный аккаунт только с 14 лет (account_id).
CREATE TABLE students (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    full_name     text NOT NULL,
    birth_date    date NOT NULL,
    sex           char(1) CHECK (sex IN ('m','f')),
    photo_key     text,
    account_id    uuid UNIQUE REFERENCES accounts(id),   -- спортсмен 14+
    status        text NOT NULL DEFAULT 'lead'
                  CHECK (status IN ('lead','trial','active','frozen','dropped')),
    created_at    timestamptz NOT NULL DEFAULT now()
);

-- Несколько опекунов на ребёнка с разными правами.
CREATE TABLE guardianships (
    student_id        uuid NOT NULL REFERENCES students(id) ON DELETE CASCADE,
    account_id        uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    relation          text NOT NULL DEFAULT 'parent',     -- parent, grandparent, legal_guardian...
    can_pay           boolean NOT NULL DEFAULT false,
    gets_notifications boolean NOT NULL DEFAULT true,
    can_manage        boolean NOT NULL DEFAULT true,       -- заявления, документы, приглашение второго опекуна
    confirmed_by      uuid REFERENCES accounts(id),        -- подтверждает администратор
    confirmed_at      timestamptz,
    PRIMARY KEY (student_id, account_id)
);

-- Доверенные лица, кто может забирать (не имеют аккаунта).
CREATE TABLE pickup_persons (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    student_id  uuid NOT NULL REFERENCES students(id) ON DELETE CASCADE,
    full_name   text NOT NULL,
    phone       text NOT NULL,
    relation    text,
    added_by    uuid REFERENCES accounts(id),
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- Профиль сотрудника (тренер, руководитель, медик...). Публичная часть идёт на сайт.
CREATE TABLE staff_profiles (
    account_id      uuid PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
    position        text,
    education       text,
    category        text,
    title           text,                                 -- звание
    sport_rank      text,
    experience_from date,                                 -- стаж считается от даты
    qualifications  jsonb NOT NULL DEFAULT '[]',          -- повышение квалификации
    bio             text,
    show_on_site    boolean NOT NULL DEFAULT true,
    slug            text UNIQUE
);

-- =====================================================================
-- 2. КАТАЛОГ
-- =====================================================================
CREATE TABLE sports (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    slug          text NOT NULL UNIQUE,
    name          text NOT NULL,
    description   text,
    for_whom      text,
    min_age       smallint,
    equipment     text,                                   -- «что нужно»
    contraindications text,
    med_requirements  text,
    photo_key     text,
    sort_order    int NOT NULL DEFAULT 0,
    is_published  boolean NOT NULL DEFAULT true
);

CREATE TABLE departments (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    sport_id      uuid NOT NULL REFERENCES sports(id),
    name          text NOT NULL,
    head_id       uuid REFERENCES accounts(id),
    regulation_doc_id uuid,                               -- FK добавляется ниже (public_documents)
    contacts      jsonb NOT NULL DEFAULT '{}'
);

CREATE TABLE venues (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    slug          text NOT NULL UNIQUE,
    name          text NOT NULL,
    address       text NOT NULL,
    lat           double precision,
    lon           double precision,
    how_to_get    text,
    infrastructure text,
    accessibility text,
    work_hours    jsonb NOT NULL DEFAULT '{}',
    contact       text,
    photos        jsonb NOT NULL DEFAULT '[]',
    is_published  boolean NOT NULL DEFAULT true
);
CREATE TABLE halls (
    id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    venue_id  uuid NOT NULL REFERENCES venues(id) ON DELETE CASCADE,
    name      text NOT NULL,
    capacity  int
);

CREATE TABLE seasons (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name             text NOT NULL,
    starts_on        date NOT NULL,
    ends_on          date NOT NULL,
    enroll_from      date,
    enroll_to        date,
    age_cutoff       date NOT NULL,                       -- контрольная дата возраста
    status           text NOT NULL DEFAULT 'upcoming'
                     CHECK (status IN ('upcoming','enrolling','running','archived')),
    CHECK (ends_on > starts_on)
);

-- Программа: ДОПСП или общеразвивающая
CREATE TABLE programs (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    sport_id      uuid NOT NULL REFERENCES sports(id),
    slug          text NOT NULL UNIQUE,
    name          text NOT NULL,
    kind          text NOT NULL CHECK (kind IN ('dopsp','general')),
    description   text,
    annotation    text,
    outcome       text,
    funding       text NOT NULL DEFAULT 'paid' CHECK (funding IN ('budget','paid','both')),
    is_published  boolean NOT NULL DEFAULT true
);
-- Этапы программы: НП, УТ, ССМ, ВСМ или ознакомительный / базовый
CREATE TABLE program_stages (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    program_id    uuid NOT NULL REFERENCES programs(id) ON DELETE CASCADE,
    code          text NOT NULL,                          -- НП, УТ, ...
    name          text NOT NULL,
    sort_order    int NOT NULL,
    duration_years numeric(3,1),
    min_age       smallint,
    norms         jsonb NOT NULL DEFAULT '[]',            -- нормативы зачисления
    min_group_size smallint,
    UNIQUE (program_id, code)
);
-- Уровни внутри направления (пояса, ступени), включается флагом levels
CREATE TABLE levels (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    sport_id      uuid NOT NULL REFERENCES sports(id),
    sort_order    int NOT NULL,
    name          text NOT NULL,
    typical_age   text,
    criteria      jsonb NOT NULL DEFAULT '{}',            -- навыки, нормативы, посещаемость
    assessment    text,
    UNIQUE (sport_id, sort_order)
);

-- =====================================================================
-- 3. ГРУППЫ, РАСПИСАНИЕ, ЗАНЯТИЯ
-- =====================================================================
CREATE TABLE groups (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    program_id     uuid NOT NULL REFERENCES programs(id),
    stage_id       uuid REFERENCES program_stages(id),
    level_id       uuid REFERENCES levels(id),
    season_id      uuid NOT NULL REFERENCES seasons(id),
    department_id  uuid REFERENCES departments(id),
    venue_id       uuid NOT NULL REFERENCES venues(id),
    hall_id        uuid REFERENCES halls(id),
    name           text NOT NULL,
    birth_year_from smallint NOT NULL,                    -- на контрольную дату сезона
    birth_year_to   smallint NOT NULL,
    sex_limit      text NOT NULL DEFAULT 'any' CHECK (sex_limit IN ('any','m','f')),
    capacity       smallint NOT NULL CHECK (capacity > 0),
    waitlist_max   smallint NOT NULL DEFAULT 0,
    status         text NOT NULL DEFAULT 'enrolling'
                   CHECK (status IN ('enrolling','running','waitlist','closed')),
    funding        text NOT NULL DEFAULT 'paid' CHECK (funding IN ('budget','paid','both')),
    trial_allowed  boolean NOT NULL DEFAULT true,
    dropin_allowed boolean NOT NULL DEFAULT false,
    note           text,
    is_published   boolean NOT NULL DEFAULT true,
    CHECK (birth_year_to >= birth_year_from)
);
CREATE INDEX groups_season_status_idx ON groups (season_id, status);

CREATE TABLE group_trainers (
    group_id    uuid NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    account_id  uuid NOT NULL REFERENCES accounts(id),
    kind        text NOT NULL DEFAULT 'main' CHECK (kind IN ('main','assistant','substitute')),
    PRIMARY KEY (group_id, account_id)
);
-- Ровно один основной тренер на группу
CREATE UNIQUE INDEX group_one_main_trainer ON group_trainers (group_id) WHERE kind = 'main';

-- Регулярное расписание (шаблон)
CREATE TABLE schedule_slots (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id    uuid NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    weekday     smallint NOT NULL CHECK (weekday BETWEEN 1 AND 7),
    starts_at   time NOT NULL,
    ends_at     time NOT NULL,
    hall_id     uuid REFERENCES halls(id),
    CHECK (ends_at > starts_at)
);

-- Конкретное занятие (occurrence): генерируется из слотов, к нему привязаны отмены и посещаемость
CREATE TABLE sessions (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id    uuid NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    slot_id     uuid REFERENCES schedule_slots(id) ON DELETE SET NULL,
    session_date date NOT NULL,
    starts_at   time NOT NULL,
    ends_at     time NOT NULL,
    hall_id     uuid REFERENCES halls(id),
    trainer_id  uuid REFERENCES accounts(id),             -- фактический тренер (с подменой)
    status      text NOT NULL DEFAULT 'planned'
                CHECK (status IN ('planned','held','cancelled','moved')),
    change_note text,                                     -- причина отмены / переноса / замены
    UNIQUE (group_id, session_date, starts_at)
);
CREATE INDEX sessions_date_idx ON sessions (session_date);

-- =====================================================================
-- 4. ЗАЯВКИ, ЗАЧИСЛЕНИЕ, МЕСТА, ЛИСТ ОЖИДАНИЯ
-- =====================================================================
CREATE TABLE leads (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    kind            text NOT NULL CHECK (kind IN ('trial','enroll','waitlist','event','callback','question')),
    status          text NOT NULL DEFAULT 'new'
                    CHECK (status IN ('new','in_work','invited','done','rejected','spam')),
    child_name      text,
    child_birth_year smallint,
    guardian_name   text NOT NULL,
    guardian_phone  text NOT NULL,
    guardian_email  citext,
    sport_id        uuid REFERENCES sports(id),
    group_id        uuid REFERENCES groups(id),
    venue_id        uuid REFERENCES venues(id),
    event_id        uuid,                                 -- FK ниже (events)
    has_more_kids   boolean NOT NULL DEFAULT false,
    comment         text,
    utm             jsonb NOT NULL DEFAULT '{}',
    landing_page    text,
    referrer        text,
    pd_consent      boolean NOT NULL CHECK (pd_consent),  -- без согласия заявку не принимаем
    pd_consent_at   timestamptz NOT NULL DEFAULT now(),
    pd_doc_version  text NOT NULL,
    assigned_to     uuid REFERENCES accounts(id),
    account_id      uuid REFERENCES accounts(id),         -- если заявитель уже гость/родитель
    student_id      uuid REFERENCES students(id),         -- после конверсии
    created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX leads_status_idx ON leads (status, created_at DESC);

CREATE TABLE enrollments (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    student_id    uuid NOT NULL REFERENCES students(id),
    group_id      uuid NOT NULL REFERENCES groups(id),
    kind          text NOT NULL DEFAULT 'regular'
                  CHECK (kind IN ('regular','trial','dropin','makeup','transfer')),
    status        text NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','approved','active','frozen','finished','dropped','rejected')),
    started_on    date,
    ended_on      date,
    leave_reason  text,
    approved_by   uuid REFERENCES accounts(id),
    created_at    timestamptz NOT NULL DEFAULT now()
);
-- Один живой regular-зачисление на ученика в группе
CREATE UNIQUE INDEX enrollments_one_active
    ON enrollments (student_id, group_id)
    WHERE kind = 'regular' AND status IN ('pending','approved','active','frozen');

-- Занятость места: считают только regular в активных статусах.
CREATE OR REPLACE FUNCTION group_seats_taken(g uuid) RETURNS int
LANGUAGE sql STABLE AS $$
    SELECT count(*)::int FROM enrollments
    WHERE group_id = g AND kind = 'regular'
      AND status IN ('approved','active','frozen');
$$;

-- Защита от гонки «два родителя заняли последнее место».
-- Блокируем строку группы, потом проверяем число мест.
CREATE OR REPLACE FUNCTION enforce_group_capacity() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE cap smallint;
BEGIN
    IF NEW.kind = 'regular' AND NEW.status IN ('approved','active','frozen') THEN
        SELECT capacity INTO cap FROM groups WHERE id = NEW.group_id FOR UPDATE;
        IF (SELECT count(*) FROM enrollments
              WHERE group_id = NEW.group_id AND kind = 'regular'
                AND status IN ('approved','active','frozen')
                AND id IS DISTINCT FROM NEW.id) >= cap THEN
            RAISE EXCEPTION 'group % is full', NEW.group_id USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER enrollments_capacity
    BEFORE INSERT OR UPDATE OF status, kind, group_id ON enrollments
    FOR EACH ROW EXECUTE FUNCTION enforce_group_capacity();

CREATE TABLE waitlist_entries (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id       uuid NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    student_id     uuid NOT NULL REFERENCES students(id) ON DELETE CASCADE,
    status         text NOT NULL DEFAULT 'waiting'
                   CHECK (status IN ('waiting','invited','accepted','declined','expired','cancelled')),
    invited_at     timestamptz,
    invite_expires timestamptz,                           -- бронь N часов
    created_at     timestamptz NOT NULL DEFAULT now()      -- позиция = порядок created_at
);
CREATE UNIQUE INDEX waitlist_one_live
    ON waitlist_entries (group_id, student_id) WHERE status IN ('waiting','invited');
CREATE INDEX waitlist_queue_idx ON waitlist_entries (group_id, created_at) WHERE status = 'waiting';

-- Публичный статус группы для сайта: места считаются, не хранятся.
CREATE VIEW group_availability AS
SELECT g.id AS group_id, g.capacity,
       group_seats_taken(g.id) AS seats_taken,
       g.capacity - group_seats_taken(g.id) AS seats_free,
       (SELECT count(*) FROM waitlist_entries w
          WHERE w.group_id = g.id AND w.status IN ('waiting','invited')) AS waitlist_len,
       g.status
FROM groups g;

-- =====================================================================
-- 5. ЗДОРОВЬЕ, ДОКУМЕНТЫ, СОГЛАСИЯ
-- =====================================================================
CREATE TABLE document_templates (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    kind        text NOT NULL CHECK (kind IN
                ('charter','license','rules','contract','consent_pd','consent_photo',
                 'consent_trip','code_of_conduct','policy','report','form')),
    title       text NOT NULL,
    version     text NOT NULL,
    file_key    text NOT NULL,
    effective_from date NOT NULL,
    required_for text[] NOT NULL DEFAULT '{}',            -- роли/формы, где обязателен
    licensed_only boolean NOT NULL DEFAULT false,
    UNIQUE (kind, version)
);

-- Документы ученика со сроками (медсправка, страховка, сканы)
CREATE TABLE student_documents (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    student_id  uuid NOT NULL REFERENCES students(id) ON DELETE CASCADE,
    kind        text NOT NULL CHECK (kind IN ('medical_cert','insurance','contract','consent','other')),
    template_id uuid REFERENCES document_templates(id),
    file_key    text,
    issued_on   date,
    valid_until date,
    status      text NOT NULL DEFAULT 'uploaded'
                CHECK (status IN ('uploaded','verified','rejected','expired')),
    uploaded_by uuid REFERENCES accounts(id),
    verified_by uuid REFERENCES accounts(id),
    signed_at   timestamptz
);
CREATE INDEX student_documents_expiry_idx ON student_documents (valid_until) WHERE status = 'verified';

-- Согласия: источник правды для публикации имени/фото на сайте.
CREATE TABLE student_consents (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    student_id  uuid NOT NULL REFERENCES students(id) ON DELETE CASCADE,
    kind        text NOT NULL CHECK (kind IN ('publish_name','publish_photo','pd_processing','trip')),
    given_by    uuid NOT NULL REFERENCES accounts(id),
    template_id uuid REFERENCES document_templates(id),
    granted_at  timestamptz NOT NULL DEFAULT now(),
    revoked_at  timestamptz
);
CREATE UNIQUE INDEX consents_one_live ON student_consents (student_id, kind) WHERE revoked_at IS NULL;

-- Единственная точка проверки «можно ли показывать на сайте».
-- Сайт и API читают только через это представление.
CREATE VIEW student_publishable AS
SELECT s.id AS student_id,
       EXISTS (SELECT 1 FROM student_consents c WHERE c.student_id = s.id
               AND c.kind = 'publish_name'  AND c.revoked_at IS NULL) AS name_ok,
       EXISTS (SELECT 1 FROM student_consents c WHERE c.student_id = s.id
               AND c.kind = 'publish_photo' AND c.revoked_at IS NULL) AS photo_ok
FROM students s;

-- Допуск (видят тренер и опекуны): без диагноза.
CREATE TABLE medical_clearances (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    student_id   uuid NOT NULL REFERENCES students(id) ON DELETE CASCADE,
    status       text NOT NULL CHECK (status IN ('cleared','restricted','not_cleared')),
    restrictions text,                                    -- «без прыжков», без диагноза
    health_group text,
    valid_until  date,
    set_by       uuid NOT NULL REFERENCES accounts(id),
    set_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX medical_clearances_student_idx ON medical_clearances (student_id, set_at DESC);

-- Медблок: диагнозы, травмы. Только медработник и опекуны. Отдельная таблица под RLS.
CREATE TABLE medical_records (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    student_id  uuid NOT NULL REFERENCES students(id) ON DELETE CASCADE,
    kind        text NOT NULL CHECK (kind IN ('note','injury','diagnosis')),
    payload_enc bytea NOT NULL,                           -- шифруется на уровне приложения
    occurred_on date,
    created_by  uuid NOT NULL REFERENCES accounts(id),
    created_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE medical_records ENABLE ROW LEVEL SECURITY;
-- Политики задаются в миграции приложения: current_setting('app.account_id'),
-- доступ только role='medic' или опекуну этого student_id. Без политик таблица закрыта для всех, кроме владельца БД.

-- =====================================================================
-- 6. ФИНАНСЫ
-- =====================================================================
CREATE TABLE tariffs (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name          text NOT NULL,
    kind          text NOT NULL CHECK (kind IN ('subscription','single','trial','period','camp','fee')),
    price_kopecks bigint NOT NULL CHECK (price_kopecks >= 0),
    sessions_count int,                                   -- NULL = безлимит на срок
    valid_days    int,
    freeze_allowed boolean NOT NULL DEFAULT false,
    freeze_max_days int,
    missed_policy text NOT NULL DEFAULT 'burn' CHECK (missed_policy IN ('burn','transfer','makeup')),
    makeup_window_days int,
    installment   boolean NOT NULL DEFAULT false,
    refund_rules  text,
    payment_methods text[] NOT NULL DEFAULT '{}',
    active_from   date,
    active_to     date,
    is_published  boolean NOT NULL DEFAULT true
);
-- Применимость тарифа: пустой набор строк = ко всем
CREATE TABLE tariff_scopes (
    tariff_id   uuid NOT NULL REFERENCES tariffs(id) ON DELETE CASCADE,
    sport_id    uuid REFERENCES sports(id),
    program_id  uuid REFERENCES programs(id),
    stage_id    uuid REFERENCES program_stages(id),
    group_id    uuid REFERENCES groups(id)
);
CREATE TABLE discounts (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name        text NOT NULL,
    condition   text NOT NULL CHECK (condition IN ('sibling','multi_program','early_bird','promo_code','manual')),
    code        text UNIQUE,
    percent     numeric(5,2),
    amount_kopecks bigint,
    active_from date,
    active_to   date,
    CHECK ((percent IS NOT NULL) <> (amount_kopecks IS NOT NULL))
);

-- Абонемент ученика
CREATE TABLE subscriptions (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    student_id      uuid NOT NULL REFERENCES students(id),
    tariff_id       uuid NOT NULL REFERENCES tariffs(id),
    enrollment_id   uuid REFERENCES enrollments(id),
    sessions_left   int,
    starts_on       date NOT NULL,
    ends_on         date,
    status          text NOT NULL DEFAULT 'active'
                    CHECK (status IN ('pending_payment','active','frozen','expired','refunded')),
    created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE subscription_freezes (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    subscription_id uuid NOT NULL REFERENCES subscriptions(id) ON DELETE CASCADE,
    from_date       date NOT NULL,
    to_date         date NOT NULL,
    reason          text,
    CHECK (to_date >= from_date)
);

CREATE TABLE invoices (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    payer_id      uuid NOT NULL REFERENCES accounts(id),   -- опекун с can_pay
    student_id    uuid REFERENCES students(id),
    subscription_id uuid REFERENCES subscriptions(id),
    event_registration_id uuid,                            -- FK ниже
    description   text NOT NULL,
    amount_kopecks bigint NOT NULL CHECK (amount_kopecks >= 0),
    discount_id   uuid REFERENCES discounts(id),
    status        text NOT NULL DEFAULT 'issued'
                  CHECK (status IN ('issued','paid','partial','cancelled','refunded')),
    due_on        date,
    created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE payments (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    invoice_id    uuid NOT NULL REFERENCES invoices(id),
    amount_kopecks bigint NOT NULL,                        -- отрицательное = возврат
    method        text NOT NULL CHECK (method IN ('card','sbp','cash','transfer','budget')),
    provider_id   text UNIQUE,                             -- id платежа в эквайринге (идемпотентность)
    receipt_url   text,                                    -- чек 54-ФЗ
    paid_at       timestamptz NOT NULL DEFAULT now(),
    recorded_by   uuid REFERENCES accounts(id)
);

-- =====================================================================
-- 7. ПОСЕЩАЕМОСТЬ И ПРОГРЕСС
-- =====================================================================
CREATE TABLE attendance (
    session_id    uuid NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    student_id    uuid NOT NULL REFERENCES students(id),
    status        text NOT NULL CHECK (status IN ('present','absent','excused','late','makeup')),
    reason        text,
    announced_in_advance boolean NOT NULL DEFAULT false,    -- заявлен родителем заранее
    makeup_for    uuid REFERENCES sessions(id),             -- какое занятие отрабатывает
    marked_by     uuid REFERENCES accounts(id),
    marked_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (session_id, student_id)
);

CREATE TABLE assessments (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    student_id  uuid NOT NULL REFERENCES students(id) ON DELETE CASCADE,
    kind        text NOT NULL CHECK (kind IN ('level_exam','norm_test','trainer_note')),
    level_id    uuid REFERENCES levels(id),
    stage_id    uuid REFERENCES program_stages(id),
    result      jsonb NOT NULL DEFAULT '{}',
    passed      boolean,
    comment     text,
    assessed_by uuid NOT NULL REFERENCES accounts(id),
    assessed_on date NOT NULL DEFAULT current_date
);
-- Текущий уровень ученика
CREATE TABLE student_levels (
    student_id  uuid NOT NULL REFERENCES students(id) ON DELETE CASCADE,
    level_id    uuid NOT NULL REFERENCES levels(id),
    reached_on  date NOT NULL,
    PRIMARY KEY (student_id, level_id)
);
CREATE TABLE rank_awards (                                  -- спортивные разряды (ЕВСК)
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    student_id  uuid NOT NULL REFERENCES students(id) ON DELETE CASCADE,
    sport_id    uuid NOT NULL REFERENCES sports(id),
    rank        text NOT NULL,
    awarded_on  date NOT NULL,
    order_ref   text
);

-- =====================================================================
-- 8. СОБЫТИЯ И ДОСТИЖЕНИЯ
-- =====================================================================
CREATE TABLE events (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    slug          text NOT NULL UNIQUE,
    title         text NOT NULL,
    kind          text NOT NULL CHECK (kind IN
                  ('competition','camp','intensive','exam','open_lesson','showcase',
                   'open_day','tryout','holidays','meeting')),
    starts_at     timestamptz NOT NULL,
    ends_at       timestamptz,
    venue_id      uuid REFERENCES venues(id),
    external_place text,
    description   text,
    regulation_key text,
    registration_required boolean NOT NULL DEFAULT false,
    reg_from      timestamptz,
    reg_to        timestamptz,
    tariff_id     uuid REFERENCES tariffs(id),
    seats         int,
    livestream_url text,
    early_bird_until date,
    is_published  boolean NOT NULL DEFAULT true
);
CREATE TABLE event_targets (                                -- для каких видов спорта / программ / групп
    event_id    uuid NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    sport_id    uuid REFERENCES sports(id),
    program_id  uuid REFERENCES programs(id),
    group_id    uuid REFERENCES groups(id)
);
CREATE TABLE event_registrations (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id    uuid NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    student_id  uuid REFERENCES students(id),
    account_id  uuid REFERENCES accounts(id),               -- судья/волонтёр
    role        text NOT NULL DEFAULT 'participant' CHECK (role IN ('participant','referee','volunteer','spectator')),
    status      text NOT NULL DEFAULT 'registered' CHECK (status IN ('registered','confirmed','declined','waitlist','cancelled')),
    created_at  timestamptz NOT NULL DEFAULT now(),
    CHECK (student_id IS NOT NULL OR account_id IS NOT NULL)
);
ALTER TABLE leads    ADD CONSTRAINT leads_event_fk    FOREIGN KEY (event_id) REFERENCES events(id);
ALTER TABLE invoices ADD CONSTRAINT invoices_ereg_fk  FOREIGN KEY (event_registration_id) REFERENCES event_registrations(id);

CREATE TABLE achievements (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id    uuid REFERENCES events(id),
    title       text,
    sport_id    uuid REFERENCES sports(id),
    achieved_on date NOT NULL,
    result      text NOT NULL,
    trainer_id  uuid REFERENCES accounts(id),
    team_name   text,                                       -- командный результат без имён
    is_published boolean NOT NULL DEFAULT false
);
-- Участники: имя выдаётся на сайте только через student_publishable.name_ok
CREATE TABLE achievement_participants (
    achievement_id uuid NOT NULL REFERENCES achievements(id) ON DELETE CASCADE,
    student_id     uuid NOT NULL REFERENCES students(id),
    PRIMARY KEY (achievement_id, student_id)
);
CREATE TABLE alumni (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    student_id  uuid REFERENCES students(id),
    display_name text NOT NULL,
    sport_id    uuid REFERENCES sports(id),
    years       text,
    trainer_id  uuid REFERENCES accounts(id),
    now_status  text,
    consent_id  uuid NOT NULL REFERENCES student_consents(id)   -- без согласия не заводим
);

-- =====================================================================
-- 9. КОММУНИКАЦИИ
-- =====================================================================
CREATE TABLE notifications (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id  uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    kind        text NOT NULL,                              -- session_cancelled, doc_expiring, invoice_due, waitlist_invite...
    channel     text NOT NULL CHECK (channel IN ('telegram','sms','email','push','in_app')),
    payload     jsonb NOT NULL DEFAULT '{}',
    status      text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','sent','failed','read')),
    created_at  timestamptz NOT NULL DEFAULT now(),
    sent_at     timestamptz
);
CREATE INDEX notifications_queue_idx ON notifications (status, created_at) WHERE status = 'queued';

CREATE TABLE notification_prefs (
    account_id  uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    kind        text NOT NULL,
    channels    text[] NOT NULL,
    PRIMARY KEY (account_id, kind)
);
CREATE TABLE account_channels (                             -- Telegram chat_id, push-токены
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id  uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    channel     text NOT NULL CHECK (channel IN ('telegram','push')),
    address     text NOT NULL,
    UNIQUE (channel, address)
);

CREATE TABLE chat_threads (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id    uuid REFERENCES groups(id) ON DELETE CASCADE,   -- чат группы
    kind        text NOT NULL CHECK (kind IN ('group','direct','support'))
);
CREATE TABLE chat_members (
    thread_id   uuid NOT NULL REFERENCES chat_threads(id) ON DELETE CASCADE,
    account_id  uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    PRIMARY KEY (thread_id, account_id)
);
CREATE TABLE chat_messages (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    thread_id   uuid NOT NULL REFERENCES chat_threads(id) ON DELETE CASCADE,
    author_id   uuid NOT NULL REFERENCES accounts(id),
    body        text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX chat_messages_thread_idx ON chat_messages (thread_id, created_at);

-- Заявления из ЛК: перевод, отчисление, справка
CREATE TABLE requests (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    kind        text NOT NULL CHECK (kind IN ('transfer','withdrawal','certificate','freeze','other')),
    student_id  uuid NOT NULL REFERENCES students(id),
    author_id   uuid NOT NULL REFERENCES accounts(id),
    target_group_id uuid REFERENCES groups(id),
    body        text,
    status      text NOT NULL DEFAULT 'new' CHECK (status IN ('new','approved','rejected','done')),
    resolved_by uuid REFERENCES accounts(id),
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- =====================================================================
-- 10. КОНТЕНТ САЙТА
-- =====================================================================
CREATE TABLE public_documents (                             -- «Сведения» и раздел «Документы»
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    title       text NOT NULL,
    kind        text NOT NULL,
    sveden_section text,                                    -- common, struct, document, education, ... NULL вне «Сведений»
    file_key    text NOT NULL,
    doc_date    date,
    version     text,
    licensed_only boolean NOT NULL DEFAULT false,
    sort_order  int NOT NULL DEFAULT 0,
    is_published boolean NOT NULL DEFAULT true
);
ALTER TABLE departments ADD CONSTRAINT departments_regulation_fk
    FOREIGN KEY (regulation_doc_id) REFERENCES public_documents(id);

CREATE TABLE pages (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    slug        text NOT NULL UNIQUE,
    title       text NOT NULL,
    body        text,
    seo         jsonb NOT NULL DEFAULT '{}',
    licensed_only boolean NOT NULL DEFAULT false,
    flag_required text,                                     -- ключ из org_settings.flags
    is_published boolean NOT NULL DEFAULT true
);
CREATE TABLE posts (                                        -- новости, блог, объявления
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    kind        text NOT NULL CHECK (kind IN ('news','blog','announcement')),
    slug        text NOT NULL UNIQUE,
    title       text NOT NULL,
    body        text,
    cover_key   text,
    group_id    uuid REFERENCES groups(id),                  -- объявления для группы
    published_at timestamptz,
    expires_at  timestamptz
);
CREATE TABLE faq_items (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    category    text NOT NULL CHECK (category IN ('general','sport','payment','rules')),
    sport_id    uuid REFERENCES sports(id),
    question    text NOT NULL,
    answer      text NOT NULL,
    sort_order  int NOT NULL DEFAULT 0
);
CREATE TABLE reviews (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    author_name text NOT NULL,
    body        text NOT NULL,
    sport_id    uuid REFERENCES sports(id),
    consent     boolean NOT NULL,
    is_published boolean NOT NULL DEFAULT false
);
CREATE TABLE vacancies (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    title       text NOT NULL,
    description text,
    contact     text,
    is_open     boolean NOT NULL DEFAULT true
);
CREATE TABLE gallery_items (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    kind        text NOT NULL CHECK (kind IN ('photo','video','stream')),
    file_key    text,
    url         text,
    event_id    uuid REFERENCES events(id),
    sport_id    uuid REFERENCES sports(id),
    shows_students boolean NOT NULL DEFAULT false,           -- если true, нужны photo-согласия (проверка в приложении)
    is_published boolean NOT NULL DEFAULT false
);
CREATE TABLE sponsors (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name        text NOT NULL,
    logo_key    text,
    url         text,
    sort_order  int NOT NULL DEFAULT 0
);

-- =====================================================================
-- 11. АУДИТ
-- =====================================================================
CREATE TABLE audit_log (
    id          bigserial PRIMARY KEY,
    account_id  uuid REFERENCES accounts(id),
    action      text NOT NULL,                               -- read, create, update, delete, export, login
    entity      text NOT NULL,                               -- medical_records, students, payments...
    entity_id   uuid,
    student_id  uuid,                                        -- чей ПДн затронуты
    ip          inet,
    meta        jsonb NOT NULL DEFAULT '{}',
    at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX audit_student_idx ON audit_log (student_id, at DESC);
CREATE INDEX audit_entity_idx  ON audit_log (entity, at DESC);
