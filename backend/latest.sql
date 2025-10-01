--
-- PostgreSQL database dump
--

\restrict ZXzzhFpc3Ua1e66R1Qlb6tBCzijIKRmRLJD7zlatL6GEx6uFvvqA2vhaNMFXhAR

-- Dumped from database version 16.10 (Ubuntu 16.10-0ubuntu0.24.04.1)
-- Dumped by pg_dump version 16.10 (Ubuntu 16.10-0ubuntu0.24.04.1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: tsm_system_rows; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS tsm_system_rows WITH SCHEMA public;


--
-- Name: EXTENSION tsm_system_rows; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION tsm_system_rows IS 'TABLESAMPLE method which accepts number of rows as a limit';


--
-- Name: calculate_business_minutes(timestamp with time zone, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.calculate_business_minutes(start_time timestamp with time zone, end_time timestamp with time zone) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
    total_minutes INT := 0;
    current_day DATE;
    day_start TIME;
    day_end TIME;
    is_holiday BOOLEAN;
BEGIN
    IF start_time IS NULL OR end_time IS NULL THEN
        RETURN 0;
    END IF;

    current_day := start_time::DATE;
    WHILE current_day <= end_time::DATE LOOP
        -- Check if it's a holiday
        SELECT COUNT(*) > 0 INTO is_holiday FROM holidays WHERE holiday_date = current_day;
        
        -- Skip weekends (Saturday=6, Sunday=0) and holidays
        IF EXTRACT(DOW FROM current_day) NOT IN (0, 6) AND NOT is_holiday THEN
            -- Get working hours for the day
            SELECT start_time, end_time INTO day_start, day_end 
            FROM working_hours 
            WHERE weekday = EXTRACT(DOW FROM current_day);
            
            IF day_start IS NOT NULL AND day_end IS NOT NULL THEN
                -- Calculate minutes for the day
                IF current_day = start_time::DATE AND current_day = end_time::DATE THEN
                    total_minutes := total_minutes + 
                        EXTRACT(EPOCH FROM (
                            LEAST(end_time, current_day + day_end) - 
                            GREATEST(start_time, current_day + day_start)
                        )) / 60;
                ELSIF current_day = start_time::DATE THEN
                    total_minutes := total_minutes + 
                        EXTRACT(EPOCH FROM (current_day + day_end - GREATEST(start_time, current_day + day_start))) / 60;
                ELSIF current_day = end_time::DATE THEN
                    total_minutes := total_minutes + 
                        EXTRACT(EPOCH FROM (LEAST(end_time, current_day + day_end) - (current_day + day_start))) / 60;
                ELSE
                    total_minutes := total_minutes + 
                        EXTRACT(EPOCH FROM (day_end - day_start)) / 60;
                END IF;
            END IF;
        END IF;
        current_day := current_day + INTERVAL '1 day';
    END LOOP;
    
    RETURN GREATEST(total_minutes, 0);
END;
$$;


ALTER FUNCTION public.calculate_business_minutes(start_time timestamp with time zone, end_time timestamp with time zone) OWNER TO postgres;

--
-- Name: calculate_efficiency_score(integer, date); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.calculate_efficiency_score(officer_id integer, month_start date) RETURNS double precision
    LANGUAGE plpgsql
    AS $$
DECLARE
    on_time_percentage FLOAT;
    avg_holding_minutes FLOAT;
    peer_median_minutes FLOAT;
    score FLOAT;
    total_handled INT;
    on_time_count INT;
BEGIN
    -- Calculate on-time percentage
    SELECT COUNT(*) FILTER (WHERE f.status = 'Closed' AND fe.business_minutes_held <= sp.sla_minutes),
           COUNT(*)
    INTO on_time_count, total_handled
    FROM file_events fe
    JOIN files f ON fe.file_id = f.id
    JOIN sla_policies sp ON f.sla_policy_id = sp.id
    WHERE fe.to_user_id = officer_id
    AND fe.started_at >= month_start
    AND fe.started_at < month_start + INTERVAL '1 month';
    
    on_time_percentage := CASE WHEN total_handled > 0 THEN on_time_count::FLOAT / total_handled ELSE 0 END;
    
    -- Calculate average holding minutes
    SELECT AVG(fe.business_minutes_held)
    INTO avg_holding_minutes
    FROM file_events fe
    WHERE fe.to_user_id = officer_id
    AND fe.started_at >= month_start
    AND fe.started_at < month_start + INTERVAL '1 month';
    
    -- Calculate peer median holding minutes
    SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY fe.business_minutes_held)
    INTO peer_median_minutes
    FROM file_events fe
    JOIN users u ON fe.to_user_id = u.id
    WHERE u.role = 'AccountsOfficer'
    AND fe.started_at >= month_start
    AND fe.started_at < month_start + INTERVAL '1 month';
    
    -- Calculate efficiency score
    score := 0.6 * on_time_percentage + 0.4 * (CASE WHEN peer_median_minutes > 0 THEN avg_holding_minutes / peer_median_minutes ELSE 1 END);
    
    RETURN COALESCE(score, 0);
END;
$$;


ALTER FUNCTION public.calculate_efficiency_score(officer_id integer, month_start date) OWNER TO postgres;

--
-- Name: generate_file_no(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.generate_file_no() RETURNS character varying
    LANGUAGE plpgsql
    AS $$
DECLARE
    today DATE := CURRENT_DATE;
    counter INT;
    file_no VARCHAR;
BEGIN
    -- Lock the row for today's counter
    PERFORM 1 FROM daily_counters WHERE counter_date = today FOR UPDATE;
    
    -- Get or initialize counter, explicitly qualifying the column
    SELECT daily_counters.counter INTO counter 
    FROM daily_counters 
    WHERE counter_date = today;
    
    IF NOT FOUND THEN
        INSERT INTO daily_counters (counter_date, counter) VALUES (today, 0);
        counter := 0;
    END IF;
    
    -- Increment counter, explicitly qualifying the column
    UPDATE daily_counters 
    SET counter = daily_counters.counter + 1 
    WHERE counter_date = today 
    RETURNING daily_counters.counter INTO counter;
    
    -- Format as ACC-YYYYMMDD-XX
    file_no := 'ACC-' || TO_CHAR(today, 'YYYYMMDD') || '-' || LPAD(counter::TEXT, 2, '0');
    RETURN file_no;
END;
$$;


ALTER FUNCTION public.generate_file_no() OWNER TO postgres;

--
-- Name: update_business_minutes(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_business_minutes() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.ended_at IS NOT NULL THEN
        NEW.business_minutes_held := calculate_business_minutes(NEW.started_at, NEW.ended_at);
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.update_business_minutes() OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: attachments; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.attachments (
    id integer NOT NULL,
    file_id integer,
    file_event_id integer,
    file_path character varying(255) NOT NULL,
    file_type character varying(50) NOT NULL,
    uploaded_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.attachments OWNER TO postgres;

--
-- Name: attachments_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.attachments_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.attachments_id_seq OWNER TO postgres;

--
-- Name: attachments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.attachments_id_seq OWNED BY public.attachments.id;


--
-- Name: audit_logs; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.audit_logs (
    id integer NOT NULL,
    file_id integer,
    user_id integer,
    action_type character varying(20) NOT NULL,
    action_details jsonb,
    action_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT audit_logs_action_type_check CHECK (((action_type)::text = ANY ((ARRAY['Read'::character varying, 'Write'::character varying, 'Delete'::character varying])::text[])))
);


ALTER TABLE public.audit_logs OWNER TO postgres;

--
-- Name: audit_logs_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.audit_logs_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.audit_logs_id_seq OWNER TO postgres;

--
-- Name: audit_logs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.audit_logs_id_seq OWNED BY public.audit_logs.id;


--
-- Name: categories; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.categories (
    id integer NOT NULL,
    name character varying(100) NOT NULL
);


ALTER TABLE public.categories OWNER TO postgres;

--
-- Name: categories_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.categories_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.categories_id_seq OWNER TO postgres;

--
-- Name: categories_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.categories_id_seq OWNED BY public.categories.id;


--
-- Name: daily_counters; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.daily_counters (
    counter_date date NOT NULL,
    counter integer DEFAULT 0 NOT NULL
);


ALTER TABLE public.daily_counters OWNER TO postgres;

--
-- Name: file_events; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.file_events (
    id integer NOT NULL,
    file_id integer,
    seq_no integer NOT NULL,
    from_user_id integer,
    to_user_id integer,
    action_type character varying(20) NOT NULL,
    started_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    ended_at timestamp with time zone,
    business_minutes_held integer,
    remarks text,
    attachments_json jsonb,
    CONSTRAINT file_events_action_type_check CHECK (((action_type)::text = ANY ((ARRAY['Forward'::character varying, 'Return'::character varying, 'SeekInfo'::character varying, 'Hold'::character varying, 'Escalate'::character varying, 'Close'::character varying, 'Dispatch'::character varying, 'Reopen'::character varying])::text[])))
);


ALTER TABLE public.file_events OWNER TO postgres;

--
-- Name: files; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.files (
    id integer NOT NULL,
    file_no character varying(20) NOT NULL,
    subject text NOT NULL,
    notesheet_title text NOT NULL,
    owning_office_id integer,
    category_id integer,
    date_initiated date NOT NULL,
    date_received_accounts date DEFAULT CURRENT_DATE NOT NULL,
    current_holder_user_id integer,
    status character varying(20) NOT NULL,
    confidentiality boolean DEFAULT false NOT NULL,
    sla_policy_id integer,
    created_by integer,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT files_status_check CHECK (((status)::text = ANY ((ARRAY['Open'::character varying, 'WithOfficer'::character varying, 'WithCOF'::character varying, 'Dispatched'::character varying, 'OnHold'::character varying, 'WaitingOnOrigin'::character varying, 'Closed'::character varying])::text[])))
);


ALTER TABLE public.files OWNER TO postgres;

--
-- Name: sla_policies; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.sla_policies (
    id integer NOT NULL,
    category_id integer,
    sla_minutes integer NOT NULL,
    name character varying(200),
    warning_pct integer DEFAULT 70,
    escalate_pct integer DEFAULT 100,
    pause_on_hold boolean DEFAULT true,
    notify_role character varying(32),
    notify_user_id integer,
    notify_channel jsonb,
    auto_escalate boolean DEFAULT false,
    active boolean DEFAULT true,
    description text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


ALTER TABLE public.sla_policies OWNER TO postgres;

--
-- Name: users; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.users (
    id integer NOT NULL,
    username character varying(50) NOT NULL,
    name character varying(100) NOT NULL,
    office_id integer,
    role character varying(20) NOT NULL,
    password_hash text,
    email text,
    CONSTRAINT users_role_check CHECK (((role)::text = ANY ((ARRAY['Clerk'::character varying, 'AccountsOfficer'::character varying, 'COF'::character varying, 'Admin'::character varying])::text[])))
);


ALTER TABLE public.users OWNER TO postgres;

--
-- Name: executive_dashboard; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.executive_dashboard AS
 SELECT ( SELECT count(*) AS count
           FROM public.files
          WHERE ((files.status)::text = ANY ((ARRAY['Open'::character varying, 'WithOfficer'::character varying, 'WithCOF'::character varying])::text[]))) AS total_open,
    ( SELECT COALESCE((((count(*) FILTER (WHERE (((f.status)::text = 'Closed'::text) AND (fe.business_minutes_held <= sp.sla_minutes))))::double precision / (NULLIF(count(*), 0))::double precision) * (100)::double precision), (0)::double precision) AS "coalesce"
           FROM ((public.files f
             JOIN public.file_events fe ON ((f.id = fe.file_id)))
             JOIN public.sla_policies sp ON ((f.sla_policy_id = sp.id)))
          WHERE (fe.ended_at >= (CURRENT_DATE - '7 days'::interval))) AS on_time_percentage_week,
    ( SELECT COALESCE((avg(fe.business_minutes_held) / ((60 * 8))::numeric), (0)::numeric) AS "coalesce"
           FROM (public.file_events fe
             JOIN public.files f ON ((fe.file_id = f.id)))
          WHERE (((f.status)::text = 'Closed'::text) AND (fe.ended_at IS NOT NULL))) AS avg_tat_days,
    ( SELECT string_agg(sub.file_info, '; '::text) AS string_agg
           FROM ( SELECT ((((((f.file_no)::text || ' ('::text) || (u.name)::text) || ', '::text) || (age(f.created_at))::text) || ')'::text) AS file_info
                   FROM (public.files f
                     JOIN public.users u ON ((f.current_holder_user_id = u.id)))
                  WHERE ((f.status)::text = ANY ((ARRAY['Open'::character varying, 'WithOfficer'::character varying, 'WithCOF'::character varying])::text[]))
                  ORDER BY f.created_at
                 LIMIT 5) sub) AS oldest_files,
    ( SELECT json_agg(sub.file_info) AS json_agg
           FROM ( SELECT json_build_object('file_no', f.file_no, 'holder', u.name, 'age', age(f.created_at)) AS file_info
                   FROM (public.files f
                     JOIN public.users u ON ((f.current_holder_user_id = u.id)))
                  WHERE ((f.status)::text = ANY ((ARRAY['Open'::character varying, 'WithOfficer'::character varying, 'WithCOF'::character varying])::text[]))
                  ORDER BY (age(f.created_at)) DESC
                 LIMIT 10) sub) AS longest_delays;


ALTER VIEW public.executive_dashboard OWNER TO postgres;

--
-- Name: file_events_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.file_events_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.file_events_id_seq OWNER TO postgres;

--
-- Name: file_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.file_events_id_seq OWNED BY public.file_events.id;


--
-- Name: files_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.files_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.files_id_seq OWNER TO postgres;

--
-- Name: files_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.files_id_seq OWNED BY public.files.id;


--
-- Name: holidays; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.holidays (
    id integer NOT NULL,
    holiday_date date NOT NULL,
    description character varying(200)
);


ALTER TABLE public.holidays OWNER TO postgres;

--
-- Name: holidays_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.holidays_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.holidays_id_seq OWNER TO postgres;

--
-- Name: holidays_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.holidays_id_seq OWNED BY public.holidays.id;


--
-- Name: officer_queue; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.officer_queue AS
 SELECT u.id AS user_id,
    f.file_no,
    f.subject,
    f.status,
        CASE
            WHEN ((f.status)::text = 'OnHold'::text) THEN 'On Hold'::text
            WHEN ((f.status)::text = 'WaitingOnOrigin'::text) THEN 'Awaiting Info'::text
            WHEN (age(CURRENT_TIMESTAMP, fe.started_at) > '24:00:00'::interval) THEN 'Overdue'::text
            WHEN (age(CURRENT_TIMESTAMP, fe.started_at) > '12:00:00'::interval) THEN 'Due Soon'::text
            ELSE 'Assigned'::text
        END AS queue_status,
    fe.started_at
   FROM ((public.files f
     JOIN public.file_events fe ON ((f.id = fe.file_id)))
     JOIN public.users u ON ((f.current_holder_user_id = u.id)))
  WHERE (((f.status)::text = ANY ((ARRAY['Open'::character varying, 'WithOfficer'::character varying, 'OnHold'::character varying, 'WaitingOnOrigin'::character varying])::text[])) AND (fe.ended_at IS NULL));


ALTER VIEW public.officer_queue OWNER TO postgres;

--
-- Name: offices; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.offices (
    id integer NOT NULL,
    name character varying(100) NOT NULL
);


ALTER TABLE public.offices OWNER TO postgres;

--
-- Name: offices_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.offices_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.offices_id_seq OWNER TO postgres;

--
-- Name: offices_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.offices_id_seq OWNED BY public.offices.id;


--
-- Name: query_threads; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.query_threads (
    id integer NOT NULL,
    file_id integer,
    initiator_user_id integer,
    target_user_id integer,
    query_text text NOT NULL,
    response_text text,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    resolved_at timestamp with time zone,
    status character varying(20) NOT NULL,
    CONSTRAINT query_threads_status_check CHECK (((status)::text = ANY ((ARRAY['Open'::character varying, 'Resolved'::character varying])::text[])))
);


ALTER TABLE public.query_threads OWNER TO postgres;

--
-- Name: query_threads_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.query_threads_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.query_threads_id_seq OWNER TO postgres;

--
-- Name: query_threads_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.query_threads_id_seq OWNED BY public.query_threads.id;


--
-- Name: sla_policies_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.sla_policies_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.sla_policies_id_seq OWNER TO postgres;

--
-- Name: sla_policies_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.sla_policies_id_seq OWNED BY public.sla_policies.id;


--
-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.users_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.users_id_seq OWNER TO postgres;

--
-- Name: users_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.users_id_seq OWNED BY public.users.id;


--
-- Name: working_hours; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.working_hours (
    id integer NOT NULL,
    weekday integer NOT NULL,
    start_time time without time zone NOT NULL,
    end_time time without time zone NOT NULL,
    CONSTRAINT working_hours_weekday_check CHECK (((weekday >= 0) AND (weekday <= 6)))
);


ALTER TABLE public.working_hours OWNER TO postgres;

--
-- Name: working_hours_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.working_hours_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.working_hours_id_seq OWNER TO postgres;

--
-- Name: working_hours_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.working_hours_id_seq OWNED BY public.working_hours.id;


--
-- Name: attachments id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.attachments ALTER COLUMN id SET DEFAULT nextval('public.attachments_id_seq'::regclass);


--
-- Name: audit_logs id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.audit_logs ALTER COLUMN id SET DEFAULT nextval('public.audit_logs_id_seq'::regclass);


--
-- Name: categories id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.categories ALTER COLUMN id SET DEFAULT nextval('public.categories_id_seq'::regclass);


--
-- Name: file_events id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.file_events ALTER COLUMN id SET DEFAULT nextval('public.file_events_id_seq'::regclass);


--
-- Name: files id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.files ALTER COLUMN id SET DEFAULT nextval('public.files_id_seq'::regclass);


--
-- Name: holidays id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.holidays ALTER COLUMN id SET DEFAULT nextval('public.holidays_id_seq'::regclass);


--
-- Name: offices id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.offices ALTER COLUMN id SET DEFAULT nextval('public.offices_id_seq'::regclass);


--
-- Name: query_threads id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.query_threads ALTER COLUMN id SET DEFAULT nextval('public.query_threads_id_seq'::regclass);


--
-- Name: sla_policies id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sla_policies ALTER COLUMN id SET DEFAULT nextval('public.sla_policies_id_seq'::regclass);


--
-- Name: users id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq'::regclass);


--
-- Name: working_hours id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.working_hours ALTER COLUMN id SET DEFAULT nextval('public.working_hours_id_seq'::regclass);


--
-- Data for Name: attachments; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.attachments (id, file_id, file_event_id, file_path, file_type, uploaded_at) FROM stdin;
\.


--
-- Data for Name: audit_logs; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.audit_logs (id, file_id, user_id, action_type, action_details, action_at) FROM stdin;
\.


--
-- Data for Name: categories; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.categories (id, name) FROM stdin;
1	Budget
2	Audit
3	Salary
4	Procurement
5	Misc
\.


--
-- Data for Name: daily_counters; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.daily_counters (counter_date, counter) FROM stdin;
2025-09-28	9
2025-09-29	4
2025-09-30	4
\.


--
-- Data for Name: file_events; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.file_events (id, file_id, seq_no, from_user_id, to_user_id, action_type, started_at, ended_at, business_minutes_held, remarks, attachments_json) FROM stdin;
1	\N	1	\N	2	Forward	2025-09-28 05:24:27.039631+00	\N	\N	Initial assignment	\N
11	13	1	\N	2	Forward	2025-09-29 04:32:09.380709+00	\N	\N	Initial intake - please verify figures	\N
12	19	1	\N	7	Forward	2025-09-30 07:34:47.304057+00	\N	\N	\N	\N
\.


--
-- Data for Name: files; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.files (id, file_no, subject, notesheet_title, owning_office_id, category_id, date_initiated, date_received_accounts, current_holder_user_id, status, confidentiality, sla_policy_id, created_by, created_at) FROM stdin;
13	ACC-20250929-02	Q3 Budget Approval - Dept A	Approval notesheet - Q3 Budget	1	2	2025-09-25	2025-09-25	2	WithOfficer	f	\N	\N	2025-09-29 04:32:09.37031+00
14	ACC-20250929-03	Draft: new budget procedure	Draft notesheet	1	2	2025-09-29	2025-09-29	\N	Open	f	\N	\N	2025-09-29 04:32:22.613977+00
17	ACC-20250930-02	Personnel Promotion - Senior Analyst	Promotion Approval Notesheet	1	2	2025-09-30	2025-09-30	7	WithOfficer	f	19	\N	2025-09-30 07:29:10.495787+00
18	ACC-20250930-03	Personnel Promotion - Senior Analyst	Promotion Approval Notesheet	1	2	2025-09-30	2025-09-30	7	WithOfficer	f	19	\N	2025-09-30 07:30:04.238655+00
19	ACC-20250930-04	Test	T	1	1	2025-09-30	2025-09-30	7	WithOfficer	f	\N	\N	2025-09-30 07:34:47.300697+00
\.


--
-- Data for Name: holidays; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.holidays (id, holiday_date, description) FROM stdin;
\.


--
-- Data for Name: offices; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.offices (id, name) FROM stdin;
1	Finance
2	Procurement
3	HR
4	Admin
\.


--
-- Data for Name: query_threads; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.query_threads (id, file_id, initiator_user_id, target_user_id, query_text, response_text, created_at, resolved_at, status) FROM stdin;
\.


--
-- Data for Name: sla_policies; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.sla_policies (id, category_id, sla_minutes, name, warning_pct, escalate_pct, pause_on_hold, notify_role, notify_user_id, notify_channel, auto_escalate, active, description, created_at, updated_at) FROM stdin;
19	1	1440	Budget - Routine (3 business days)	70	100	t	AccountsOfficer	\N	{"channel": "in_app"}	f	t	Routine SLA for Budget files	2025-09-29 04:20:54.812049+00	2025-09-29 04:20:54.812049+00
20	1	480	Budget - Urgent (1 business day)	70	100	t	AccountsOfficer	\N	{"channel": "in_app"}	f	t	Urgent SLA for Budget	2025-09-29 04:20:54.812049+00	2025-09-29 04:20:54.812049+00
21	1	240	Budget - Critical (half day)	70	100	t	AccountsOfficer	\N	{"channel": "sms"}	t	t	Critical SLA for Budget	2025-09-29 04:20:54.812049+00	2025-09-29 04:20:54.812049+00
22	2	1440	Audit - Routine (3 business days)	70	100	t	AccountsOfficer	\N	{"channel": "in_app"}	f	t	Routine SLA for Audit files	2025-09-29 04:20:54.812049+00	2025-09-29 04:20:54.812049+00
23	2	480	Audit - Urgent (1 business day)	70	100	t	AccountsOfficer	\N	{"channel": "in_app"}	f	t	Urgent SLA for Audit	2025-09-29 04:20:54.812049+00	2025-09-29 04:20:54.812049+00
24	2	240	Audit - Critical (half day)	70	100	t	AccountsOfficer	\N	{"channel": "sms"}	t	t	Critical SLA for Audit	2025-09-29 04:20:54.812049+00	2025-09-29 04:20:54.812049+00
25	3	1440	Salary - Routine (3 business days)	70	100	t	AccountsOfficer	\N	{"channel": "in_app"}	f	t	Routine SLA for Salary files	2025-09-29 04:20:54.812049+00	2025-09-29 04:20:54.812049+00
26	3	480	Salary - Urgent (1 business day)	70	100	t	AccountsOfficer	\N	{"channel": "in_app"}	f	t	Urgent SLA for Salary	2025-09-29 04:20:54.812049+00	2025-09-29 04:20:54.812049+00
27	3	240	Salary - Critical (half day)	70	100	t	AccountsOfficer	\N	{"channel": "sms"}	t	t	Critical SLA for Salary	2025-09-29 04:20:54.812049+00	2025-09-29 04:20:54.812049+00
28	4	1440	Procurement - Routine (3 business days)	70	100	t	AccountsOfficer	\N	{"channel": "in_app"}	f	t	Routine SLA for Procurement	2025-09-29 04:20:54.812049+00	2025-09-29 04:20:54.812049+00
29	4	480	Procurement - Urgent (1 business day)	70	100	t	AccountsOfficer	\N	{"channel": "in_app"}	f	t	Urgent SLA for Procurement	2025-09-29 04:20:54.812049+00	2025-09-29 04:20:54.812049+00
30	4	240	Procurement - Critical (half day)	70	100	t	AccountsOfficer	\N	{"channel": "sms"}	t	t	Critical SLA for Procurement	2025-09-29 04:20:54.812049+00	2025-09-29 04:20:54.812049+00
31	5	1440	Misc - Routine (3 business days)	70	100	t	AccountsOfficer	\N	{"channel": "in_app"}	f	t	Routine SLA for Misc files	2025-09-29 04:20:54.812049+00	2025-09-29 04:20:54.812049+00
32	5	480	Misc - Urgent (1 business day)	70	100	t	AccountsOfficer	\N	{"channel": "in_app"}	f	t	Urgent SLA for Misc	2025-09-29 04:20:54.812049+00	2025-09-29 04:20:54.812049+00
33	5	240	Misc - Critical (half day)	70	100	t	AccountsOfficer	\N	{"channel": "sms"}	t	t	Critical SLA for Misc	2025-09-29 04:20:54.812049+00	2025-09-29 04:20:54.812049+00
\.


--
-- Data for Name: users; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.users (id, username, name, office_id, role, password_hash, email) FROM stdin;
1	clerk1	Clerk One	1	Clerk	\N	\N
2	officer1	Officer One	1	AccountsOfficer	\N	\N
3	cof1	COF One	1	COF	\N	\N
4	admin1	Admin One	1	Admin	\N	\N
5	admin	Admin User	\N	Clerk	$2a$10$WuIfh6YbvGKoatBQYk2S3.2I4JSlhkLDvxFOEWxYFL2OgyU0PFUC6	admin@gmail.com
6	cof	Cof User	\N	Clerk	$2a$10$r.1dIxglZwq4UeWCzrAIqeFKpScnYveXicpp1S0aW2bFDrMV0YsHK	cof@gmail.com
7	clerk	Clerk User	\N	Clerk	$2a$10$iD5x/e65Z6sLoBrh4RrELehOaYoeaqknh1yB9oXWMS72tTWDxNiiK	clerk@gmail.com
8	acct_officer1	Accounts Officer One	\N	Clerk	$2a$10$EtceQvTwxfyVcOy5J/qBN.4iu9cQIsXIQrbWRqwFxv.XXsl/37bZq	\N
9	cof_user	COF User	\N	Clerk	$2a$10$Di3xrPXwVk98XW72vAo7b.g1x6rVFIRW/Eb7dFENkrztqwp1YAtbS	\N
10	cofhai	COF User	\N	COF	$2a$10$XgnVtsvPxYEdWNJfCDcAROz.1PpG5gbnJImI.VnPCSIe.1EqSNtky	\N
\.


--
-- Data for Name: working_hours; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.working_hours (id, weekday, start_time, end_time) FROM stdin;
1	1	09:00:00	17:00:00
2	2	09:00:00	17:00:00
3	3	09:00:00	17:00:00
4	4	09:00:00	17:00:00
5	5	09:00:00	17:00:00
\.


--
-- Name: attachments_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.attachments_id_seq', 1, false);


--
-- Name: audit_logs_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.audit_logs_id_seq', 1, false);


--
-- Name: categories_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.categories_id_seq', 5, true);


--
-- Name: file_events_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.file_events_id_seq', 12, true);


--
-- Name: files_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.files_id_seq', 19, true);


--
-- Name: holidays_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.holidays_id_seq', 1, false);


--
-- Name: offices_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.offices_id_seq', 4, true);


--
-- Name: query_threads_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.query_threads_id_seq', 1, false);


--
-- Name: sla_policies_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.sla_policies_id_seq', 33, true);


--
-- Name: users_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.users_id_seq', 10, true);


--
-- Name: working_hours_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.working_hours_id_seq', 5, true);


--
-- Name: attachments attachments_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.attachments
    ADD CONSTRAINT attachments_pkey PRIMARY KEY (id);


--
-- Name: audit_logs audit_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.audit_logs
    ADD CONSTRAINT audit_logs_pkey PRIMARY KEY (id);


--
-- Name: categories categories_name_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT categories_name_key UNIQUE (name);


--
-- Name: categories categories_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT categories_pkey PRIMARY KEY (id);


--
-- Name: daily_counters daily_counters_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.daily_counters
    ADD CONSTRAINT daily_counters_pkey PRIMARY KEY (counter_date);


--
-- Name: file_events file_events_file_id_seq_no_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.file_events
    ADD CONSTRAINT file_events_file_id_seq_no_key UNIQUE (file_id, seq_no);


--
-- Name: file_events file_events_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.file_events
    ADD CONSTRAINT file_events_pkey PRIMARY KEY (id);


--
-- Name: files files_file_no_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.files
    ADD CONSTRAINT files_file_no_key UNIQUE (file_no);


--
-- Name: files files_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.files
    ADD CONSTRAINT files_pkey PRIMARY KEY (id);


--
-- Name: holidays holidays_holiday_date_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.holidays
    ADD CONSTRAINT holidays_holiday_date_key UNIQUE (holiday_date);


--
-- Name: holidays holidays_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.holidays
    ADD CONSTRAINT holidays_pkey PRIMARY KEY (id);


--
-- Name: offices offices_name_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.offices
    ADD CONSTRAINT offices_name_key UNIQUE (name);


--
-- Name: offices offices_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.offices
    ADD CONSTRAINT offices_pkey PRIMARY KEY (id);


--
-- Name: query_threads query_threads_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.query_threads
    ADD CONSTRAINT query_threads_pkey PRIMARY KEY (id);


--
-- Name: sla_policies sla_policies_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sla_policies
    ADD CONSTRAINT sla_policies_pkey PRIMARY KEY (id);


--
-- Name: users users_email_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_email_unique UNIQUE (email);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: users users_username_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_username_key UNIQUE (username);


--
-- Name: working_hours working_hours_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.working_hours
    ADD CONSTRAINT working_hours_pkey PRIMARY KEY (id);


--
-- Name: idx_attachments_file_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_attachments_file_id ON public.attachments USING btree (file_id);


--
-- Name: idx_audit_logs_file_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_audit_logs_file_id ON public.audit_logs USING btree (file_id);


--
-- Name: idx_file_events_file_id_seq; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_file_events_file_id_seq ON public.file_events USING btree (file_id, seq_no);


--
-- Name: idx_files_file_no; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_files_file_no ON public.files USING btree (file_no);


--
-- Name: idx_files_status_holder; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_files_status_holder ON public.files USING btree (status, current_holder_user_id);


--
-- Name: idx_query_threads_file_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_query_threads_file_id ON public.query_threads USING btree (file_id);


--
-- Name: idx_sla_policies_active; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_sla_policies_active ON public.sla_policies USING btree (active);


--
-- Name: idx_users_email; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_users_email ON public.users USING btree (email);


--
-- Name: idx_users_username; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_users_username ON public.users USING btree (username);


--
-- Name: file_events trigger_update_business_minutes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trigger_update_business_minutes BEFORE INSERT OR UPDATE OF ended_at ON public.file_events FOR EACH ROW EXECUTE FUNCTION public.update_business_minutes();


--
-- Name: attachments attachments_file_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.attachments
    ADD CONSTRAINT attachments_file_event_id_fkey FOREIGN KEY (file_event_id) REFERENCES public.file_events(id);


--
-- Name: attachments attachments_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.attachments
    ADD CONSTRAINT attachments_file_id_fkey FOREIGN KEY (file_id) REFERENCES public.files(id) ON DELETE CASCADE;


--
-- Name: audit_logs audit_logs_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.audit_logs
    ADD CONSTRAINT audit_logs_file_id_fkey FOREIGN KEY (file_id) REFERENCES public.files(id) ON DELETE CASCADE;


--
-- Name: audit_logs audit_logs_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.audit_logs
    ADD CONSTRAINT audit_logs_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: file_events file_events_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.file_events
    ADD CONSTRAINT file_events_file_id_fkey FOREIGN KEY (file_id) REFERENCES public.files(id) ON DELETE CASCADE;


--
-- Name: file_events file_events_from_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.file_events
    ADD CONSTRAINT file_events_from_user_id_fkey FOREIGN KEY (from_user_id) REFERENCES public.users(id);


--
-- Name: file_events file_events_to_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.file_events
    ADD CONSTRAINT file_events_to_user_id_fkey FOREIGN KEY (to_user_id) REFERENCES public.users(id);


--
-- Name: files files_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.files
    ADD CONSTRAINT files_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.categories(id);


--
-- Name: files files_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.files
    ADD CONSTRAINT files_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: files files_current_holder_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.files
    ADD CONSTRAINT files_current_holder_user_id_fkey FOREIGN KEY (current_holder_user_id) REFERENCES public.users(id);


--
-- Name: files files_owning_office_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.files
    ADD CONSTRAINT files_owning_office_id_fkey FOREIGN KEY (owning_office_id) REFERENCES public.offices(id);


--
-- Name: files files_sla_policy_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.files
    ADD CONSTRAINT files_sla_policy_id_fkey FOREIGN KEY (sla_policy_id) REFERENCES public.sla_policies(id);


--
-- Name: sla_policies fk_sla_policies_notify_user; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sla_policies
    ADD CONSTRAINT fk_sla_policies_notify_user FOREIGN KEY (notify_user_id) REFERENCES public.users(id);


--
-- Name: query_threads query_threads_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.query_threads
    ADD CONSTRAINT query_threads_file_id_fkey FOREIGN KEY (file_id) REFERENCES public.files(id) ON DELETE CASCADE;


--
-- Name: query_threads query_threads_initiator_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.query_threads
    ADD CONSTRAINT query_threads_initiator_user_id_fkey FOREIGN KEY (initiator_user_id) REFERENCES public.users(id);


--
-- Name: query_threads query_threads_target_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.query_threads
    ADD CONSTRAINT query_threads_target_user_id_fkey FOREIGN KEY (target_user_id) REFERENCES public.users(id);


--
-- Name: sla_policies sla_policies_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sla_policies
    ADD CONSTRAINT sla_policies_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.categories(id);


--
-- Name: users users_office_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_office_id_fkey FOREIGN KEY (office_id) REFERENCES public.offices(id);


--
-- Name: attachments; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.attachments ENABLE ROW LEVEL SECURITY;

--
-- Name: audit_logs; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;

--
-- Name: files clerk_files; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY clerk_files ON public.files TO clerk USING (((created_by = ( SELECT users.id
   FROM public.users
  WHERE ((users.username)::text = CURRENT_USER))) OR (confidentiality = false)));


--
-- Name: files cof_files; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY cof_files ON public.files TO cof USING (true);


--
-- Name: file_events; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.file_events ENABLE ROW LEVEL SECURITY;

--
-- Name: files; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.files ENABLE ROW LEVEL SECURITY;

--
-- Name: files officer_files; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY officer_files ON public.files TO accounts_officer USING (((current_holder_user_id = ( SELECT users.id
   FROM public.users
  WHERE ((users.username)::text = CURRENT_USER))) OR (confidentiality = false)));


--
-- Name: query_threads; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.query_threads ENABLE ROW LEVEL SECURITY;

--
-- Name: TABLE attachments; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.attachments TO clerk;
GRANT SELECT,INSERT ON TABLE public.attachments TO accounts_officer;
GRANT ALL ON TABLE public.attachments TO cof;
GRANT ALL ON TABLE public.attachments TO admin;


--
-- Name: TABLE audit_logs; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.audit_logs TO cof;
GRANT ALL ON TABLE public.audit_logs TO admin;


--
-- Name: TABLE categories; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.categories TO admin;


--
-- Name: TABLE daily_counters; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.daily_counters TO admin;


--
-- Name: TABLE file_events; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.file_events TO clerk;
GRANT SELECT,INSERT ON TABLE public.file_events TO accounts_officer;
GRANT ALL ON TABLE public.file_events TO cof;
GRANT ALL ON TABLE public.file_events TO admin;


--
-- Name: TABLE files; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT ON TABLE public.files TO clerk;
GRANT SELECT,UPDATE ON TABLE public.files TO accounts_officer;
GRANT ALL ON TABLE public.files TO cof;
GRANT ALL ON TABLE public.files TO admin;


--
-- Name: TABLE sla_policies; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.sla_policies TO admin;


--
-- Name: TABLE users; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.users TO admin;


--
-- Name: TABLE holidays; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.holidays TO admin;


--
-- Name: TABLE officer_queue; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.officer_queue TO admin;


--
-- Name: TABLE offices; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.offices TO admin;


--
-- Name: TABLE query_threads; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.query_threads TO clerk;
GRANT SELECT,INSERT ON TABLE public.query_threads TO accounts_officer;
GRANT ALL ON TABLE public.query_threads TO cof;
GRANT ALL ON TABLE public.query_threads TO admin;


--
-- Name: TABLE working_hours; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.working_hours TO admin;


--
-- PostgreSQL database dump complete
--

\unrestrict ZXzzhFpc3Ua1e66R1Qlb6tBCzijIKRmRLJD7zlatL6GEx6uFvvqA2vhaNMFXhAR

