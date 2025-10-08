--
-- PostgreSQL database dump
--

\restrict ZnfcOClpmdA4ZfbPj4dLDiJmGEOAx5wfJQIWE743c4XdJ9N1jsDT640pChZYQpx

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
-- Name: sla_priority; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.sla_priority AS ENUM (
    'Routine',
    'Urgent',
    'Critical'
);


ALTER TYPE public.sla_priority OWNER TO postgres;

--
-- Name: calculate_business_minutes(timestamp with time zone, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.calculate_business_minutes(start_ts timestamp with time zone, end_ts timestamp with time zone) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
    total_minutes INT := 0;
    current_day DATE;
    day_start TIME;
    day_end TIME;
    is_holiday BOOLEAN;
BEGIN
    IF start_ts IS NULL OR end_ts IS NULL THEN
        RETURN 0;
    END IF;

    current_day := start_ts::DATE;
    WHILE current_day <= end_ts::DATE LOOP
        -- Check if it's a holiday
        SELECT COUNT(*) > 0 INTO is_holiday FROM public.holidays WHERE holiday_date = current_day;
        
        -- Do not hardcode weekends; rely on working_hours for the weekday. If no row, that day contributes 0.
        IF NOT is_holiday THEN
            SELECT wh.start_time, wh.end_time INTO day_start, day_end 
            FROM public.working_hours wh
            WHERE wh.weekday = EXTRACT(DOW FROM current_day);
            
            IF day_start IS NOT NULL AND day_end IS NOT NULL THEN
                IF current_day = start_ts::DATE AND current_day = end_ts::DATE THEN
                    total_minutes := total_minutes + 
                        EXTRACT(EPOCH FROM (
                            LEAST(end_ts, current_day + day_end) - 
                            GREATEST(start_ts, current_day + day_start)
                        )) / 60;
                ELSIF current_day = start_ts::DATE THEN
                    total_minutes := total_minutes + 
                        EXTRACT(EPOCH FROM (current_day + day_end - GREATEST(start_ts, current_day + day_start))) / 60;
                ELSIF current_day = end_ts::DATE THEN
                    total_minutes := total_minutes + 
                        EXTRACT(EPOCH FROM (LEAST(end_ts, current_day + day_end) - (current_day + day_start))) / 60;
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


ALTER FUNCTION public.calculate_business_minutes(start_ts timestamp with time zone, end_ts timestamp with time zone) OWNER TO postgres;

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
-- Name: file_events_after_change(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.file_events_after_change() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  -- Recompute SLA for the affected file. Using PERFORM keeps this light and defers heavy notifications to backend
  PERFORM public.update_file_sla(COALESCE(NEW.file_id, OLD.file_id));
  RETURN NEW;
END;
$$;


ALTER FUNCTION public.file_events_after_change() OWNER TO postgres;

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

--
-- Name: update_file_sla(integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_file_sla(p_file_id integer) RETURNS void
    LANGUAGE plpgsql
    AS $_$
DECLARE
  slaMinutes integer := 1440;
  warningPct integer := 70;
  escalatePct integer := 100;
  pauseOnHold boolean := true;
  closedSum integer := 0;
  ongoingMinutes integer := 0;
  consumed integer := 0;
  percent integer := 0;
  v_status text := 'On-track';
  remaining integer := 0;
  sp record;
  openEv record;
  excludeTypes text[] := ARRAY[]::text[];
BEGIN
  IF p_file_id IS NULL THEN
    RETURN;
  END IF;

  SELECT sla_policy_id INTO sp FROM files WHERE id = p_file_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF sp.sla_policy_id IS NOT NULL THEN
    SELECT sla_minutes, warning_pct, escalate_pct, pause_on_hold INTO slaMinutes, warningPct, escalatePct, pauseOnHold
      FROM sla_policies WHERE id = sp.sla_policy_id LIMIT 1;
  END IF;

  IF pauseOnHold THEN
    excludeTypes := ARRAY['Hold','SeekInfo'];
  END IF;

  IF array_length(excludeTypes,1) IS NOT NULL THEN
    EXECUTE format('SELECT COALESCE(SUM(business_minutes_held),0) FROM file_events WHERE file_id = %s AND ended_at IS NOT NULL AND (action_type IS NULL OR action_type <> ALL($1::text[]))', p_file_id)
    INTO closedSum USING excludeTypes;
  ELSE
    SELECT COALESCE(SUM(business_minutes_held),0) INTO closedSum FROM file_events WHERE file_id = p_file_id AND ended_at IS NOT NULL;
  END IF;

  -- compute ongoing minutes for latest open event, if not a pause action
  SELECT id, started_at, action_type INTO openEv FROM file_events WHERE file_id = p_file_id AND ended_at IS NULL ORDER BY seq_no DESC LIMIT 1;
  IF FOUND THEN
    IF NOT (pauseOnHold AND openEv.action_type = ANY(ARRAY['Hold','SeekInfo'])) THEN
      SELECT public.calculate_business_minutes(openEv.started_at, NOW()) INTO ongoingMinutes;
    ELSE
      ongoingMinutes := 0;
    END IF;
  END IF;

  consumed := COALESCE(closedSum,0) + COALESCE(ongoingMinutes,0);
  percent := LEAST(100, GREATEST(0, ROUND((consumed::numeric / GREATEST(1, slaMinutes)::numeric) * 100))::integer);
  IF percent >= escalatePct THEN
    v_status := 'Breach';
  ELSIF percent >= warningPct THEN
    v_status := 'Warning';
  ELSE
    v_status := 'On-track';
  END IF;
  remaining := GREATEST(0, slaMinutes - consumed);

  UPDATE public.files SET
    sla_consumed_minutes = consumed,
    sla_percent = percent,
    sla_status = v_status,
    sla_remaining_minutes = remaining
  WHERE id = p_file_id;
END;
$_$;


ALTER FUNCTION public.update_file_sla(p_file_id integer) OWNER TO postgres;

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
    CONSTRAINT file_events_action_type_check CHECK (((action_type)::text = ANY ((ARRAY['Forward'::character varying, 'Return'::character varying, 'SeekInfo'::character varying, 'Hold'::character varying, 'Escalate'::character varying, 'Close'::character varying, 'Dispatch'::character varying, 'Reopen'::character varying, 'SLAReason'::character varying])::text[])))
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
    sla_consumed_minutes integer DEFAULT 0 NOT NULL,
    sla_percent integer DEFAULT 0 NOT NULL,
    sla_status character varying(20) DEFAULT 'On-track'::character varying NOT NULL,
    sla_remaining_minutes integer DEFAULT 0 NOT NULL,
    sla_last_warning_at timestamp with time zone,
    sla_last_escalated_at timestamp with time zone,
    CONSTRAINT files_status_check CHECK (((status)::text = ANY ((ARRAY['Draft'::character varying, 'Open'::character varying, 'WithOfficer'::character varying, 'WithCOF'::character varying, 'Dispatched'::character varying, 'OnHold'::character varying, 'WaitingOnOrigin'::character varying, 'Closed'::character varying])::text[])))
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
    updated_at timestamp with time zone DEFAULT now(),
    priority public.sla_priority DEFAULT 'Routine'::public.sla_priority NOT NULL
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
-- Name: file_share_tokens; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.file_share_tokens (
    file_id integer NOT NULL,
    token_hash text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    token text,
    created_by integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    last_used_at timestamp with time zone
);


ALTER TABLE public.file_share_tokens OWNER TO postgres;

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
-- Name: sla_notifications; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.sla_notifications (
    id integer NOT NULL,
    file_id integer NOT NULL,
    event_type character varying(50) NOT NULL,
    payload jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    processed boolean DEFAULT false NOT NULL,
    processed_at timestamp with time zone
);


ALTER TABLE public.sla_notifications OWNER TO postgres;

--
-- Name: sla_notifications_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.sla_notifications_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.sla_notifications_id_seq OWNER TO postgres;

--
-- Name: sla_notifications_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.sla_notifications_id_seq OWNED BY public.sla_notifications.id;


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
-- Name: sla_notifications id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sla_notifications ALTER COLUMN id SET DEFAULT nextval('public.sla_notifications_id_seq'::regclass);


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
1	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 15:43:53.349478+00
2	\N	1	Read	{"ip": "::1", "path": "/files?holder=1&includeSla=true&limit=50", "query": {"limit": 50, "holder": 1}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 15:43:54.13822+00
3	\N	1	Read	{"ip": "::1", "path": "/files?holder=1&includeSla=true&limit=50", "query": {"limit": 50, "holder": 1}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 15:43:54.414453+00
4	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 15:43:55.20551+00
5	\N	1	Read	{"ip": "::1", "path": "/files?holder=1&includeSla=true&limit=50", "query": {"limit": 50, "holder": 1}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 15:43:55.557164+00
6	\N	1	Read	{"ip": "::1", "path": "/files?holder=1&includeSla=true&limit=50", "query": {"limit": 50, "holder": 1}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 15:43:55.830698+00
7	\N	2	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "clerk"}	2025-10-04 15:44:02.559599+00
8	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 15:44:02.578371+00
9	5	2	Write	{"ip": "::1", "path": "/files", "route": "POST /files", "method": "POST", "payload": {"remarks": "new", "subject": "new file audit log check", "priority": "Urgent", "attachments": [{"url": "/sd.pdf"}], "category_id": 1, "save_as_draft": false, "sla_policy_id": 2, "date_initiated": "2025-10-04", "confidentiality": true, "notesheet_title": "audit log check", "owning_office_id": 1, "forward_to_officer_id": 3, "date_received_accounts": "2025-10-04"}}	2025-10-04 15:44:26.560964+00
10	5	2	Read	{"ip": "::1", "path": "/files/5", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-04 15:44:26.575157+00
11	5	2	Read	{"ip": "::1", "path": "/files/5", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-04 15:44:26.581144+00
12	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-04 15:44:26.585358+00
13	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-04 15:44:26.588622+00
14	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 15:44:28.901045+00
15	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 15:44:30.938614+00
16	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-04 15:44:31.886195+00
17	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 15:46:13.856849+00
18	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-04 15:46:14.704929+00
19	\N	2	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 15:46:17.47013+00
20	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 15:46:17.491384+00
21	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 15:46:17.834348+00
22	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 15:48:35.744038+00
23	\N	1	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "cof"}	2025-10-04 15:48:41.840712+00
24	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 15:48:41.863597+00
25	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 15:48:43.136692+00
26	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 15:48:43.892726+00
27	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 15:48:44.372738+00
28	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 15:48:45.832865+00
29	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 15:49:44.082928+00
30	5	1	Read	{"ip": "::1", "path": "/files/5", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-04 15:49:59.118684+00
31	5	1	Read	{"ip": "::1", "path": "/files/5", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-04 15:49:59.124958+00
32	5	1	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-04 15:49:59.129097+00
33	5	1	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-04 15:49:59.132558+00
34	5	1	Read	{"ip": "::1", "path": "/files/5", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-04 15:50:02.027779+00
35	5	1	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-04 15:50:02.033666+00
36	5	1	Read	{"ip": "::1", "path": "/files/5", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-04 15:50:02.033717+00
37	5	1	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-04 15:50:02.038697+00
38	5	1	Read	{"ip": "::1", "path": "/files/5", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-04 15:50:05.960118+00
40	5	1	Read	{"ip": "::1", "path": "/files/5", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-04 15:50:05.965946+00
41	5	1	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-04 15:50:05.978951+00
1391	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:49:08.905266+00
1481	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:58:20.891407+00
1553	\N	4	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:08:00.607377+00
1554	12	4	Read	{"ip": "::1", "path": "/files/12/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 14:08:00.896724+00
1555	12	4	Read	{"ip": "::1", "path": "/files/12/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 14:08:00.912479+00
1556	\N	4	Read	{"ip": "::1", "path": "/files?q=&limit=10&includeSla=false", "query": {"q": "", "limit": 10}, "route": "GET /files", "method": "GET"}	2025-10-05 14:08:04.254254+00
1625	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:42:54.192264+00
1666	\N	2	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "clerk"}	2025-10-05 19:38:16.714274+00
1712	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:25:14.884969+00
1766	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:43:38.787116+00
1780	\N	2	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "clerk"}	2025-10-06 04:15:19.195527+00
1781	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:15:19.277219+00
1828	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:37:20.517239+00
1830	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:37:28.325927+00
1881	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:42:39.664254+00
1887	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:42:53.023295+00
1888	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:42:53.424678+00
1892	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:42:54.513458+00
1896	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:42:55.744398+00
1948	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:53:31.6221+00
1949	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:53:31.629364+00
1950	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:53:34.411334+00
1951	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:53:34.419662+00
1952	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:53:34.427648+00
1953	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:53:34.434423+00
1954	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:53:36.093624+00
1955	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:53:36.103295+00
1960	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:53:36.950831+00
1961	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:53:36.958013+00
1962	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:53:38.995562+00
1963	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:53:39.006215+00
1972	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:53:48.088252+00
1974	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:53:48.096168+00
39	5	1	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-04 15:50:05.964869+00
42	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:16:16.603467+00
43	\N	1	Read	{"ip": "::1", "path": "/files?holder=1&includeSla=true&limit=50", "query": {"limit": 50, "holder": 1}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:16:17.549436+00
44	\N	1	Read	{"ip": "::1", "path": "/files?holder=1&includeSla=true&limit=50", "query": {"limit": 50, "holder": 1}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:16:17.826434+00
45	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:16:18.314686+00
46	\N	1	Read	{"ip": "::1", "path": "/files?holder=1&includeSla=true&limit=50", "query": {"limit": 50, "holder": 1}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:16:18.848467+00
47	\N	1	Read	{"ip": "::1", "path": "/files?holder=1&includeSla=true&limit=50", "query": {"limit": 50, "holder": 1}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:16:19.124295+00
48	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:16:19.774299+00
49	\N	1	Read	{"ip": "::1", "path": "/files?holder=1&includeSla=true&limit=50", "query": {"limit": 50, "holder": 1}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:16:20.542745+00
50	\N	1	Read	{"ip": "::1", "path": "/files?holder=1&includeSla=true&limit=50", "query": {"limit": 50, "holder": 1}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:16:20.825499+00
51	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:16:21.250702+00
52	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:16:51.71446+00
53	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:17:22.183456+00
54	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:17:52.649382+00
55	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:18:23.109467+00
56	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:18:53.575547+00
57	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:19:21.112104+00
58	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:19:51.568753+00
59	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:20:22.036048+00
60	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:20:52.50154+00
61	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:21:22.976348+00
62	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:21:53.440177+00
63	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:22:23.909934+00
64	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:22:51.440644+00
65	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:23:21.903957+00
66	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:26:52.397942+00
67	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:26:52.407494+00
68	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:27:02.235673+00
69	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:27:03.963336+00
70	\N	1	Read	{"ip": "::1", "path": "/files?holder=1&includeSla=true&limit=50", "query": {"limit": 50, "holder": 1}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:27:04.497794+00
71	\N	1	Read	{"ip": "::1", "path": "/files?holder=1&includeSla=true&limit=50", "query": {"limit": 50, "holder": 1}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:27:04.77281+00
72	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:27:21.926868+00
73	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:28:03.382824+00
74	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:29:42.186551+00
75	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:29:42.741262+00
179	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:03:14.906281+00
76	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:30:06.239553+00
77	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:30:16.068418+00
78	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:30:16.075028+00
79	\N	1	Read	{"ip": "::1", "path": "/files?holder=1&includeSla=true&limit=50", "query": {"limit": 50, "holder": 1}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:30:33.805911+00
80	\N	1	Read	{"ip": "::1", "path": "/files?holder=1&includeSla=true&limit=50", "query": {"limit": 50, "holder": 1}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:30:34.075279+00
81	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:30:34.301008+00
82	\N	1	Read	{"ip": "::1", "path": "/files?holder=1&includeSla=true&limit=50", "query": {"limit": 50, "holder": 1}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:30:35.013799+00
83	\N	1	Read	{"ip": "::1", "path": "/files?holder=1&includeSla=true&limit=50", "query": {"limit": 50, "holder": 1}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:30:35.29672+00
84	\N	1	Read	{"ip": "::1", "path": "/files?holder=1&includeSla=true&limit=50", "query": {"limit": 50, "holder": 1}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:35:56.87324+00
85	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:35:57.781744+00
86	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:36:17.226017+00
87	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:36:18.121327+00
88	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:36:53.386385+00
89	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:36:53.63285+00
90	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:39:52.282015+00
91	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:40:19.817136+00
92	2	1	Read	{"ip": "::1", "path": "/files/2", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-04 16:40:22.835879+00
93	2	1	Read	{"ip": "::1", "path": "/files/2/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-04 16:40:22.841616+00
94	2	1	Read	{"ip": "::1", "path": "/files/2", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-04 16:40:22.842572+00
95	2	1	Read	{"ip": "::1", "path": "/files/2/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-04 16:40:22.851774+00
96	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:40:24.519621+00
97	\N	1	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "cof"}	2025-10-04 16:55:02.307478+00
98	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:55:02.420549+00
99	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:55:17.082584+00
100	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-04 16:55:17.402494+00
132	\N	2	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "clerk"}	2025-10-05 04:59:27.667399+00
133	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 04:59:27.721989+00
134	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 04:59:28.951986+00
135	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 04:59:29.906493+00
136	5	2	Write	{"ip": "::1", "path": "/files/5/token", "route": "POST /files/:id/token", "method": "POST"}	2025-10-05 04:59:32.675191+00
137	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsImlhdCI6MTc1OTY0MDM3MiwiZXhwIjoxNzYwMjQ1MTcyfQ.Qvm7GZosuImqWfl0Evy0GZVgr8L7SB0egw0mbpkOqAc", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 04:59:35.163946+00
138	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsImlhdCI6MTc1OTY0MDM3MiwiZXhwIjoxNzYwMjQ1MTcyfQ.Qvm7GZosuImqWfl0Evy0GZVgr8L7SB0egw0mbpkOqAc", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 04:59:35.169171+00
139	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 04:59:35.17418+00
140	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 04:59:35.178524+00
141	\N	3	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "officer"}	2025-10-05 05:00:06.555995+00
142	5	3	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsImlhdCI6MTc1OTY0MDM3MiwiZXhwIjoxNzYwMjQ1MTcyfQ.Qvm7GZosuImqWfl0Evy0GZVgr8L7SB0egw0mbpkOqAc", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:00:06.580118+00
220	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:03:54.851404+00
143	5	3	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsImlhdCI6MTc1OTY0MDM3MiwiZXhwIjoxNzYwMjQ1MTcyfQ.Qvm7GZosuImqWfl0Evy0GZVgr8L7SB0egw0mbpkOqAc", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:00:06.586044+00
144	5	3	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsImlhdCI6MTc1OTY0MDM3MiwiZXhwIjoxNzYwMjQ1MTcyfQ.Qvm7GZosuImqWfl0Evy0GZVgr8L7SB0egw0mbpkOqAc", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:00:22.823634+00
145	5	3	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsImlhdCI6MTc1OTY0MDM3MiwiZXhwIjoxNzYwMjQ1MTcyfQ.Qvm7GZosuImqWfl0Evy0GZVgr8L7SB0egw0mbpkOqAc", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:00:22.824405+00
146	5	3	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsImlhdCI6MTc1OTY0MDM3MiwiZXhwIjoxNzYwMjQ1MTcyfQ.Qvm7GZosuImqWfl0Evy0GZVgr8L7SB0egw0mbpkOqAc", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:00:23.389201+00
147	5	3	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsImlhdCI6MTc1OTY0MDM3MiwiZXhwIjoxNzYwMjQ1MTcyfQ.Qvm7GZosuImqWfl0Evy0GZVgr8L7SB0egw0mbpkOqAc", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:00:23.389681+00
148	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsImlhdCI6MTc1OTY0MDM3MiwiZXhwIjoxNzYwMjQ1MTcyfQ.Qvm7GZosuImqWfl0Evy0GZVgr8L7SB0egw0mbpkOqAc", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:02:13.166317+00
149	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:02:13.17999+00
150	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:02:13.182967+00
151	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsImlhdCI6MTc1OTY0MDM3MiwiZXhwIjoxNzYwMjQ1MTcyfQ.Qvm7GZosuImqWfl0Evy0GZVgr8L7SB0egw0mbpkOqAc", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:02:17.140366+00
152	5	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsImlhdCI6MTc1OTY0MDM3MiwiZXhwIjoxNzYwMjQ1MTcyfQ.Qvm7GZosuImqWfl0Evy0GZVgr8L7SB0egw0mbpkOqAc", "count": 1, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:02:17.150177+00
153	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:02:58.237264+00
154	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:02:59.135826+00
155	5	2	Write	{"ip": "::1", "path": "/files/5/token", "route": "POST /files/:id/token", "method": "POST"}	2025-10-05 05:03:00.160517+00
156	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQwNTgwLCJleHAiOjE3NTk2NDA4ODB9.PkS3tCZU05B934qWsuFGF-NFreY15yLI3wTvrk7JW7c", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:03:02.04117+00
157	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQwNTgwLCJleHAiOjE3NTk2NDA4ODB9.PkS3tCZU05B934qWsuFGF-NFreY15yLI3wTvrk7JW7c", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:03:02.044971+00
158	5	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQwNTgwLCJleHAiOjE3NTk2NDA4ODB9.PkS3tCZU05B934qWsuFGF-NFreY15yLI3wTvrk7JW7c", "count": 1, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:03:02.047647+00
159	5	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQwNTgwLCJleHAiOjE3NTk2NDA4ODB9.PkS3tCZU05B934qWsuFGF-NFreY15yLI3wTvrk7JW7c", "count": 1, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:03:02.051055+00
160	5	2	Read	{"ip": "::1", "path": "/files/5", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:03:10.775887+00
161	5	2	Read	{"ip": "::1", "path": "/files/5", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:03:10.783882+00
162	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:03:10.788541+00
163	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:03:10.794495+00
164	5	2	Read	{"ip": "::1", "path": "/files/5", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:03:13.139433+00
165	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:03:13.144478+00
166	5	2	Read	{"ip": "::1", "path": "/files/5", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:03:13.146872+00
167	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:03:13.152019+00
168	5	2	Read	{"ip": "::1", "path": "/files/5", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:03:13.82323+00
169	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:03:13.828572+00
170	5	2	Read	{"ip": "::1", "path": "/files/5", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:03:13.829382+00
171	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:03:13.834585+00
172	5	2	Read	{"ip": "::1", "path": "/files/5", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:03:14.249918+00
173	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:03:14.255174+00
174	5	2	Read	{"ip": "::1", "path": "/files/5", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:03:14.256936+00
175	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:03:14.261851+00
176	5	2	Read	{"ip": "::1", "path": "/files/5", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:03:14.895065+00
177	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:03:14.900695+00
178	5	2	Read	{"ip": "::1", "path": "/files/5", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:03:14.901676+00
180	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQwNTgwLCJleHAiOjE3NTk2NDA4ODB9.PkS3tCZU05B934qWsuFGF-NFreY15yLI3wTvrk7JW7c", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:03:17.214819+00
181	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQwNTgwLCJleHAiOjE3NTk2NDA4ODB9.PkS3tCZU05B934qWsuFGF-NFreY15yLI3wTvrk7JW7c", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:03:17.21965+00
182	5	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQwNTgwLCJleHAiOjE3NTk2NDA4ODB9.PkS3tCZU05B934qWsuFGF-NFreY15yLI3wTvrk7JW7c", "count": 1, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:03:17.22172+00
183	5	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQwNTgwLCJleHAiOjE3NTk2NDA4ODB9.PkS3tCZU05B934qWsuFGF-NFreY15yLI3wTvrk7JW7c", "count": 1, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:03:17.224772+00
184	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQwNTgwLCJleHAiOjE3NTk2NDA4ODB9.PkS3tCZU05B934qWsuFGF-NFreY15yLI3wTvrk7JW7c", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:03:18.597575+00
185	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQwNTgwLCJleHAiOjE3NTk2NDA4ODB9.PkS3tCZU05B934qWsuFGF-NFreY15yLI3wTvrk7JW7c", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:03:18.602891+00
190	5	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQwNTgwLCJleHAiOjE3NTk2NDA4ODB9.PkS3tCZU05B934qWsuFGF-NFreY15yLI3wTvrk7JW7c", "count": 1, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:03:18.773452+00
191	5	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQwNTgwLCJleHAiOjE3NTk2NDA4ODB9.PkS3tCZU05B934qWsuFGF-NFreY15yLI3wTvrk7JW7c", "count": 1, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:03:18.777261+00
192	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQwNTgwLCJleHAiOjE3NTk2NDA4ODB9.PkS3tCZU05B934qWsuFGF-NFreY15yLI3wTvrk7JW7c", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:03:18.979607+00
193	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQwNTgwLCJleHAiOjE3NTk2NDA4ODB9.PkS3tCZU05B934qWsuFGF-NFreY15yLI3wTvrk7JW7c", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:03:18.984122+00
198	5	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQwNTgwLCJleHAiOjE3NTk2NDA4ODB9.PkS3tCZU05B934qWsuFGF-NFreY15yLI3wTvrk7JW7c", "count": 1, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:03:19.101211+00
199	5	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQwNTgwLCJleHAiOjE3NTk2NDA4ODB9.PkS3tCZU05B934qWsuFGF-NFreY15yLI3wTvrk7JW7c", "count": 1, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:03:19.105551+00
200	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQwNTgwLCJleHAiOjE3NTk2NDA4ODB9.PkS3tCZU05B934qWsuFGF-NFreY15yLI3wTvrk7JW7c", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:03:19.216565+00
201	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQwNTgwLCJleHAiOjE3NTk2NDA4ODB9.PkS3tCZU05B934qWsuFGF-NFreY15yLI3wTvrk7JW7c", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:03:19.22057+00
1392	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:49:09.376869+00
1393	\N	4	Read	{"ip": "::1", "path": "/files?q=&limit=10&includeSla=false", "query": {"q": "", "limit": 10}, "route": "GET /files", "method": "GET"}	2025-10-05 09:49:10.620583+00
1483	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:58:20.906732+00
1557	\N	4	Read	{"q": "", "ip": "::1", "page": 1, "path": "/users?q=&limit=100", "limit": 100, "route": "GET /users", "method": "GET"}	2025-10-05 14:08:04.254802+00
1626	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:42:54.466407+00
1667	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 19:38:16.795873+00
1669	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 19:38:19.094816+00
1713	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:25:29.397083+00
1767	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:43:52.685391+00
1782	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:15:34.11336+00
1783	\N	2	Read	{"ip": "::1", "path": "/files?q=file+02&date_from=2025-08-07T04:14:38.676Z&limit=8&includeSla=false", "query": {"q": "file 02", "limit": 8, "date_from": "2025-08-07T04:14:38.676Z"}, "route": "GET /files", "method": "GET"}	2025-10-06 04:15:38.567636+00
1785	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:15:45.448139+00
186	5	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQwNTgwLCJleHAiOjE3NTk2NDA4ODB9.PkS3tCZU05B934qWsuFGF-NFreY15yLI3wTvrk7JW7c", "count": 1, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:03:18.603618+00
187	5	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQwNTgwLCJleHAiOjE3NTk2NDA4ODB9.PkS3tCZU05B934qWsuFGF-NFreY15yLI3wTvrk7JW7c", "count": 1, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:03:18.607874+00
188	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQwNTgwLCJleHAiOjE3NTk2NDA4ODB9.PkS3tCZU05B934qWsuFGF-NFreY15yLI3wTvrk7JW7c", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:03:18.768679+00
189	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQwNTgwLCJleHAiOjE3NTk2NDA4ODB9.PkS3tCZU05B934qWsuFGF-NFreY15yLI3wTvrk7JW7c", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:03:18.773172+00
194	5	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQwNTgwLCJleHAiOjE3NTk2NDA4ODB9.PkS3tCZU05B934qWsuFGF-NFreY15yLI3wTvrk7JW7c", "count": 1, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:03:18.984427+00
195	5	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQwNTgwLCJleHAiOjE3NTk2NDA4ODB9.PkS3tCZU05B934qWsuFGF-NFreY15yLI3wTvrk7JW7c", "count": 1, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:03:18.988285+00
196	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQwNTgwLCJleHAiOjE3NTk2NDA4ODB9.PkS3tCZU05B934qWsuFGF-NFreY15yLI3wTvrk7JW7c", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:03:19.096724+00
197	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQwNTgwLCJleHAiOjE3NTk2NDA4ODB9.PkS3tCZU05B934qWsuFGF-NFreY15yLI3wTvrk7JW7c", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:03:19.100898+00
202	5	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQwNTgwLCJleHAiOjE3NTk2NDA4ODB9.PkS3tCZU05B934qWsuFGF-NFreY15yLI3wTvrk7JW7c", "count": 1, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:03:19.220878+00
203	5	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQwNTgwLCJleHAiOjE3NTk2NDA4ODB9.PkS3tCZU05B934qWsuFGF-NFreY15yLI3wTvrk7JW7c", "count": 1, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:03:19.224632+00
204	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQwNTgwLCJleHAiOjE3NTk2NDA4ODB9.PkS3tCZU05B934qWsuFGF-NFreY15yLI3wTvrk7JW7c", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:03:38.122823+00
205	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsImlhdCI6MTc1OTY0MDM3MiwiZXhwIjoxNzYwMjQ1MTcyfQ.Qvm7GZosuImqWfl0Evy0GZVgr8L7SB0egw0mbpkOqAc", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:03:38.123031+00
206	5	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsImlhdCI6MTc1OTY0MDM3MiwiZXhwIjoxNzYwMjQ1MTcyfQ.Qvm7GZosuImqWfl0Evy0GZVgr8L7SB0egw0mbpkOqAc", "count": 1, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:03:38.134148+00
207	5	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQwNTgwLCJleHAiOjE3NTk2NDA4ODB9.PkS3tCZU05B934qWsuFGF-NFreY15yLI3wTvrk7JW7c", "count": 1, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:03:38.13479+00
208	5	2	Read	{"ip": "::1", "path": "/files/5", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:03:38.13505+00
209	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:03:38.138182+00
210	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:03:38.144446+00
211	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:03:45.449496+00
212	\N	2	Read	{"ip": "::1", "path": "/files?q=&status=&office=&page=1&limit=50&sort_by=owning_office&sort_dir=desc&includeSla=true&creator=2", "query": {"q": "", "page": 1, "limit": 50, "status": "", "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:03:46.324424+00
213	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:03:47.33463+00
214	5	2	Write	{"ip": "::1", "path": "/files/5/token", "route": "POST /files/:id/token", "method": "POST"}	2025-10-05 05:03:48.313094+00
215	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQwNjI4LCJleHAiOjE3NTk2NDA5Mjh9.LTTnGWiz6vcIFC4NH6kh5okxD7vPXRSWhcorP-MfDHQ", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:03:52.158505+00
216	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQwNjI4LCJleHAiOjE3NTk2NDA5Mjh9.LTTnGWiz6vcIFC4NH6kh5okxD7vPXRSWhcorP-MfDHQ", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:03:52.162168+00
217	5	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQwNjI4LCJleHAiOjE3NTk2NDA5Mjh9.LTTnGWiz6vcIFC4NH6kh5okxD7vPXRSWhcorP-MfDHQ", "count": 1, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:03:52.163731+00
218	5	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQwNjI4LCJleHAiOjE3NTk2NDA5Mjh9.LTTnGWiz6vcIFC4NH6kh5okxD7vPXRSWhcorP-MfDHQ", "count": 1, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:03:52.167412+00
219	5	2	Read	{"ip": "::1", "path": "/files/5", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:03:54.844924+00
221	5	2	Read	{"ip": "::1", "path": "/files/5", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:03:54.851997+00
222	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:03:54.856192+00
223	5	2	Read	{"ip": "::1", "path": "/files/5", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:03:57.549807+00
225	5	2	Read	{"ip": "::1", "path": "/files/5", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:03:57.557309+00
226	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:03:57.562906+00
1394	\N	4	Read	{"q": "", "ip": "::1", "page": 1, "path": "/users?q=&limit=100", "limit": 100, "route": "GET /users", "method": "GET"}	2025-10-05 09:49:10.621025+00
1484	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:58:20.915367+00
1558	12	4	Read	{"ip": "::1", "path": "/files/shared/12/VPACEtknyernJGCr3M-RB6yajwfHDFFS", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 14:16:20.338708+00
1559	12	4	Read	{"ip": "::1", "path": "/files/shared/12/VPACEtknyernJGCr3M-RB6yajwfHDFFS", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 14:16:20.349852+00
1563	\N	4	Read	{"ip": "::1", "path": "/files?q=&limit=10&includeSla=false", "query": {"q": "", "limit": 10}, "route": "GET /files", "method": "GET"}	2025-10-05 14:16:21.015861+00
1627	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:42:55.642259+00
1628	13	1	Read	{"ip": "::1", "path": "/files/13/events", "count": 2, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 14:42:56.788839+00
1629	13	1	Read	{"ip": "::1", "path": "/files/13/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 14:42:56.800352+00
1668	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 19:38:18.666325+00
1714	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:25:30.468207+00
1768	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:45:48.311336+00
1784	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:15:43.416323+00
1829	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:37:25.748578+00
1882	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:42:39.921935+00
1891	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-22", "query": {"limit": 1000, "date_from": "2025-09-22"}, "route": "GET /files", "method": "GET"}	2025-10-06 04:42:54.512802+00
1893	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:42:54.521536+00
1976	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:53:48.103515+00
1977	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:53:48.111235+00
1978	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:53:50.269559+00
1979	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:53:50.280579+00
1984	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:53:51.107051+00
1985	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:53:51.115471+00
1986	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:53:54.906855+00
1987	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:53:54.918936+00
2200	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:58:43.589025+00
2201	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:58:43.595743+00
2202	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:58:44.205693+00
2203	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:58:44.214281+00
2208	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:58:44.360891+00
2209	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:58:44.368925+00
2210	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:58:44.413971+00
2211	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:58:44.422186+00
224	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:03:57.555283+00
227	5	2	Read	{"ip": "::1", "path": "/files/5", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:09:53.350551+00
228	5	2	Read	{"ip": "::1", "path": "/files/5", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:09:53.361452+00
229	\N	2	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "clerk"}	2025-10-05 05:10:25.659025+00
230	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:10:25.689524+00
231	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:10:26.621407+00
232	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:10:27.309179+00
233	5	2	Write	{"ip": "::1", "path": "/files/5/token", "route": "POST /files/:id/token", "method": "POST"}	2025-10-05 05:10:28.224077+00
234	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxMDI4LCJleHAiOjE3NTk2NDEzMjh9.A1wUuAiOXaS6LMlo6NBU283zIH3-ARBgrCZzMiXa-MI", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:10:31.724058+00
235	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxMDI4LCJleHAiOjE3NTk2NDEzMjh9.A1wUuAiOXaS6LMlo6NBU283zIH3-ARBgrCZzMiXa-MI", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:10:31.728572+00
236	5	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxMDI4LCJleHAiOjE3NTk2NDEzMjh9.A1wUuAiOXaS6LMlo6NBU283zIH3-ARBgrCZzMiXa-MI", "count": 1, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:10:31.73119+00
237	5	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxMDI4LCJleHAiOjE3NTk2NDEzMjh9.A1wUuAiOXaS6LMlo6NBU283zIH3-ARBgrCZzMiXa-MI", "count": 1, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:10:31.73481+00
238	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxMDI4LCJleHAiOjE3NTk2NDEzMjh9.A1wUuAiOXaS6LMlo6NBU283zIH3-ARBgrCZzMiXa-MI", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:10:33.326806+00
239	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxMDI4LCJleHAiOjE3NTk2NDEzMjh9.A1wUuAiOXaS6LMlo6NBU283zIH3-ARBgrCZzMiXa-MI", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:10:33.333523+00
240	5	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxMDI4LCJleHAiOjE3NTk2NDEzMjh9.A1wUuAiOXaS6LMlo6NBU283zIH3-ARBgrCZzMiXa-MI", "count": 1, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:10:33.334203+00
241	5	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxMDI4LCJleHAiOjE3NTk2NDEzMjh9.A1wUuAiOXaS6LMlo6NBU283zIH3-ARBgrCZzMiXa-MI", "count": 1, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:10:33.340261+00
242	5	2	Read	{"ip": "::1", "path": "/files/5", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:10:36.708686+00
243	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:10:36.716491+00
244	5	2	Read	{"ip": "::1", "path": "/files/5", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:10:36.717174+00
245	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:10:36.723257+00
246	5	2	Read	{"ip": "::1", "path": "/files/5", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:10:38.114031+00
247	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:10:38.119233+00
248	5	2	Read	{"ip": "::1", "path": "/files/5", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:10:38.121218+00
249	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:10:38.127523+00
250	4	2	Read	{"ip": "::1", "path": "/files/4", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:10:41.839834+00
251	4	2	Read	{"ip": "::1", "path": "/files/4/events", "count": 0, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:10:41.845287+00
252	4	2	Read	{"ip": "::1", "path": "/files/4", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:10:41.845939+00
253	4	2	Read	{"ip": "::1", "path": "/files/4/events", "count": 0, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:10:41.852292+00
254	3	2	Read	{"ip": "::1", "path": "/files/3", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:10:44.649907+00
255	3	2	Read	{"ip": "::1", "path": "/files/3/events", "count": 4, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:10:44.656346+00
256	3	2	Read	{"ip": "::1", "path": "/files/3", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:10:44.658471+00
257	3	2	Read	{"ip": "::1", "path": "/files/3/events", "count": 4, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:10:44.664105+00
258	1	2	Read	{"ip": "::1", "path": "/files/1", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:10:49.217765+00
259	1	2	Read	{"ip": "::1", "path": "/files/1/events", "count": 4, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:10:49.224186+00
260	1	2	Read	{"ip": "::1", "path": "/files/1", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:10:49.224751+00
261	1	2	Read	{"ip": "::1", "path": "/files/1/events", "count": 4, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:10:49.230214+00
262	1	2	Read	{"ip": "::1", "path": "/files/1", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:11:23.166357+00
263	1	2	Read	{"ip": "::1", "path": "/files/1/events", "count": 4, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:11:23.175299+00
264	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:13:29.565295+00
265	4	2	Read	{"ip": "::1", "path": "/files/4/events", "count": 0, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:13:30.686789+00
266	4	2	Write	{"ip": "::1", "path": "/files/4/token", "route": "POST /files/:id/token", "method": "POST"}	2025-10-05 05:13:31.705691+00
267	4	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjQsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxMjExLCJleHAiOjE3NTk2NDE1MTF9.8Xa8Uk_c6Qkc8il0qg7MIf6b3a47QGurbcoPleCh5Fk", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:13:35.634197+00
268	4	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjQsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxMjExLCJleHAiOjE3NTk2NDE1MTF9.8Xa8Uk_c6Qkc8il0qg7MIf6b3a47QGurbcoPleCh5Fk", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:13:35.64194+00
269	4	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjQsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxMjExLCJleHAiOjE3NTk2NDE1MTF9.8Xa8Uk_c6Qkc8il0qg7MIf6b3a47QGurbcoPleCh5Fk", "count": 0, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:13:35.644332+00
270	4	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjQsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxMjExLCJleHAiOjE3NTk2NDE1MTF9.8Xa8Uk_c6Qkc8il0qg7MIf6b3a47QGurbcoPleCh5Fk", "count": 0, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:13:35.648458+00
271	4	2	Read	{"ip": "::1", "path": "/files/4", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:12:43.787493+00
272	4	2	Read	{"ip": "::1", "path": "/files/4/events", "count": 0, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:12:43.794588+00
273	4	2	Read	{"ip": "::1", "path": "/files/4", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:12:43.796565+00
274	4	2	Read	{"ip": "::1", "path": "/files/4/events", "count": 0, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:12:43.80302+00
275	3	2	Read	{"ip": "::1", "path": "/files/3", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:13:42.694474+00
276	3	2	Read	{"ip": "::1", "path": "/files/3/events", "count": 4, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:13:42.701791+00
277	3	2	Read	{"ip": "::1", "path": "/files/3", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:13:42.701924+00
278	3	2	Read	{"ip": "::1", "path": "/files/3/events", "count": 4, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:13:42.707383+00
279	1	2	Read	{"ip": "::1", "path": "/files/1", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:13:47.711292+00
280	1	2	Read	{"ip": "::1", "path": "/files/1/events", "count": 4, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:13:47.717511+00
281	1	2	Read	{"ip": "::1", "path": "/files/1", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:13:47.718329+00
282	1	2	Read	{"ip": "::1", "path": "/files/1/events", "count": 4, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:13:47.724292+00
283	1	2	Read	{"ip": "::1", "path": "/files/1", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:13:51.609674+00
284	1	2	Read	{"ip": "::1", "path": "/files/1/events", "count": 4, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:13:51.62001+00
285	1	2	Read	{"ip": "::1", "path": "/files/1", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:13:51.625142+00
286	1	2	Read	{"ip": "::1", "path": "/files/1/events", "count": 4, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:13:51.638992+00
287	\N	2	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "clerk"}	2025-10-05 05:14:04.180376+00
288	1	2	Read	{"ip": "::1", "path": "/files/1", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:14:04.200142+00
289	1	2	Read	{"ip": "::1", "path": "/files/1", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:14:04.207769+00
290	1	2	Read	{"ip": "::1", "path": "/files/1/events", "count": 4, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:14:04.211702+00
291	1	2	Read	{"ip": "::1", "path": "/files/1/events", "count": 4, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:14:04.215702+00
292	5	2	Read	{"ip": "::1", "path": "/files/5", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:14:10.195753+00
293	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:14:10.202077+00
294	5	2	Read	{"ip": "::1", "path": "/files/5", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:14:10.202789+00
295	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:14:10.207842+00
296	4	2	Read	{"ip": "::1", "path": "/files/4", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:14:13.576633+00
297	4	2	Read	{"ip": "::1", "path": "/files/4/events", "count": 0, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:14:13.582328+00
298	4	2	Read	{"ip": "::1", "path": "/files/4", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:14:13.582651+00
299	4	2	Read	{"ip": "::1", "path": "/files/4/events", "count": 0, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:14:13.588536+00
300	3	2	Read	{"ip": "::1", "path": "/files/3", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:14:17.961111+00
301	3	2	Read	{"ip": "::1", "path": "/files/3/events", "count": 4, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:14:17.967049+00
302	3	2	Read	{"ip": "::1", "path": "/files/3", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:14:17.967696+00
303	3	2	Read	{"ip": "::1", "path": "/files/3/events", "count": 4, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:14:17.974637+00
304	1	2	Read	{"ip": "::1", "path": "/files/1", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:14:32.362597+00
305	1	2	Read	{"ip": "::1", "path": "/files/1", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:14:32.375817+00
306	1	2	Read	{"ip": "::1", "path": "/files/1/events", "count": 4, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:14:32.384185+00
307	1	2	Read	{"ip": "::1", "path": "/files/1/events", "count": 4, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:14:32.391445+00
308	3	2	Read	{"ip": "::1", "path": "/files/3", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:14:37.278143+00
310	3	2	Read	{"ip": "::1", "path": "/files/3", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-05 05:14:37.284706+00
311	3	2	Read	{"ip": "::1", "path": "/files/3/events", "count": 4, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:14:37.289868+00
1395	\N	4	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:49:11.728507+00
1396	12	4	Read	{"ip": "::1", "path": "/files/12/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 09:49:12.049296+00
1397	12	4	Read	{"ip": "::1", "path": "/files/12/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 09:49:12.063267+00
1398	\N	4	Read	{"ip": "::1", "path": "/files?q=&limit=10&includeSla=false", "query": {"q": "", "limit": 10}, "route": "GET /files", "method": "GET"}	2025-10-05 09:49:17.253938+00
1485	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:58:23.591395+00
1560	12	4	Read	{"ip": "::1", "path": "/files/shared/12/VPACEtknyernJGCr3M-RB6yajwfHDFFS/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 14:16:20.357427+00
1561	12	4	Read	{"ip": "::1", "path": "/files/shared/12/VPACEtknyernJGCr3M-RB6yajwfHDFFS/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 14:16:20.364569+00
1562	\N	4	Read	{"q": "", "ip": "::1", "page": 1, "path": "/users?q=&limit=100", "limit": 100, "route": "GET /users", "method": "GET"}	2025-10-05 14:16:21.015758+00
1630	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:43:14.148493+00
1631	13	1	Read	{"ip": "::1", "path": "/files/13/events", "count": 3, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 14:43:14.439621+00
1632	13	1	Read	{"ip": "::1", "path": "/files/13/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 14:43:14.450795+00
1670	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 19:38:37.820902+00
1715	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:25:48.142574+00
1769	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:46:01.969311+00
1786	\N	2	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "clerk"}	2025-10-06 04:16:03.14485+00
1831	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:37:29.96387+00
1884	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:42:48.439065+00
1886	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:42:49.155066+00
1894	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:42:54.529687+00
1982	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:53:51.0968+00
1983	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:53:51.106016+00
1988	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:53:54.919798+00
1989	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:53:54.927576+00
2216	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:58:44.635304+00
2217	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:58:44.642581+00
2218	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:58:54.627918+00
2219	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:58:54.636209+00
2224	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:58:54.958378+00
2225	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:58:54.96514+00
2226	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:58:55.116091+00
2227	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:58:55.124254+00
2231	13	2	Read	{"ip": "::1", "path": "/files/13/events", "count": 3, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 04:58:57.3158+00
2234	13	2	Read	{"ip": "::1", "path": "/files/13/events", "count": 3, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 04:58:57.322944+00
2295	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:02:29.116172+00
2296	14	2	Read	{"ip": "::1", "path": "/files/14/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 05:02:30.071991+00
309	3	2	Read	{"ip": "::1", "path": "/files/3/events", "count": 4, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:14:37.284079+00
312	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:16:53.814369+00
313	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:16:54.662692+00
314	5	2	Write	{"ip": "::1", "path": "/files/5/token", "route": "POST /files/:id/token", "method": "POST"}	2025-10-05 05:16:55.849441+00
315	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNDE1LCJleHAiOjE3NTk2NDE3MTV9.ntndIF94vkpyKGd0EWIEW7bO-z4bntbhwVtRh1u4CFU", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:16:57.422196+00
316	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNDE1LCJleHAiOjE3NTk2NDE3MTV9.ntndIF94vkpyKGd0EWIEW7bO-z4bntbhwVtRh1u4CFU", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:16:57.426004+00
317	5	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNDE1LCJleHAiOjE3NTk2NDE3MTV9.ntndIF94vkpyKGd0EWIEW7bO-z4bntbhwVtRh1u4CFU", "count": 1, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:16:57.429972+00
318	5	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNDE1LCJleHAiOjE3NTk2NDE3MTV9.ntndIF94vkpyKGd0EWIEW7bO-z4bntbhwVtRh1u4CFU", "count": 1, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:16:57.433177+00
319	\N	2	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "clerk"}	2025-10-05 05:17:11.705192+00
320	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:17:11.739203+00
321	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:17:12.994261+00
322	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:17:13.802588+00
323	5	2	Write	{"ip": "::1", "path": "/files/5/token", "route": "POST /files/:id/token", "method": "POST"}	2025-10-05 05:17:14.785074+00
324	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNDM0LCJleHAiOjE3NTk2NDE3MzR9.5TbuNd0mEboVuRRiOL_mso_U717guxbN8qtXwwkDY6k", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:17:16.012815+00
325	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNDM0LCJleHAiOjE3NTk2NDE3MzR9.5TbuNd0mEboVuRRiOL_mso_U717guxbN8qtXwwkDY6k", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:17:16.016807+00
326	5	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNDM0LCJleHAiOjE3NTk2NDE3MzR9.5TbuNd0mEboVuRRiOL_mso_U717guxbN8qtXwwkDY6k", "count": 1, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:17:16.018645+00
327	5	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNDM0LCJleHAiOjE3NTk2NDE3MzR9.5TbuNd0mEboVuRRiOL_mso_U717guxbN8qtXwwkDY6k", "count": 1, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:17:16.021594+00
328	\N	2	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "clerk"}	2025-10-05 05:17:27.763466+00
329	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:17:27.79402+00
330	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:17:29.130386+00
331	3	2	Read	{"ip": "::1", "path": "/files/3/events", "count": 4, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:17:30.027468+00
332	4	2	Read	{"ip": "::1", "path": "/files/4/events", "count": 0, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:17:30.56918+00
333	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:17:31.084681+00
334	2	2	Read	{"ip": "::1", "path": "/files/2/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:17:32.56078+00
335	1	2	Read	{"ip": "::1", "path": "/files/1/events", "count": 4, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:17:42.596222+00
336	5	2	Write	{"ip": "::1", "path": "/files/5/token", "route": "POST /files/:id/token", "method": "POST"}	2025-10-05 05:18:00.222039+00
337	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNDgwLCJleHAiOjE3NTk2NDE3ODB9.Umq_ls0LnXHmNiMc4aXhL8wG14ERckIAzCyjORATNss", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:18:02.720059+00
338	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNDgwLCJleHAiOjE3NTk2NDE3ODB9.Umq_ls0LnXHmNiMc4aXhL8wG14ERckIAzCyjORATNss", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:18:02.725654+00
339	5	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNDgwLCJleHAiOjE3NTk2NDE3ODB9.Umq_ls0LnXHmNiMc4aXhL8wG14ERckIAzCyjORATNss", "count": 1, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:18:02.732577+00
340	5	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNDgwLCJleHAiOjE3NTk2NDE3ODB9.Umq_ls0LnXHmNiMc4aXhL8wG14ERckIAzCyjORATNss", "count": 1, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:18:02.736512+00
655	5	2	Read	{"ip": "::1", "path": "/files/shared/5/vOC73QcUDzGFOs089z-hDXcNb8agHnu0/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:52:14.618419+00
341	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNDgwLCJleHAiOjE3NTk2NDE3ODB9.Umq_ls0LnXHmNiMc4aXhL8wG14ERckIAzCyjORATNss", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:18:05.7411+00
342	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNDgwLCJleHAiOjE3NTk2NDE3ODB9.Umq_ls0LnXHmNiMc4aXhL8wG14ERckIAzCyjORATNss", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:18:05.747051+00
347	5	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNDgwLCJleHAiOjE3NTk2NDE3ODB9.Umq_ls0LnXHmNiMc4aXhL8wG14ERckIAzCyjORATNss", "count": 1, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:18:08.29042+00
348	5	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNDgwLCJleHAiOjE3NTk2NDE3ODB9.Umq_ls0LnXHmNiMc4aXhL8wG14ERckIAzCyjORATNss", "count": 1, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:18:08.293161+00
349	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNDgwLCJleHAiOjE3NTk2NDE3ODB9.Umq_ls0LnXHmNiMc4aXhL8wG14ERckIAzCyjORATNss", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:18:10.471389+00
350	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNDgwLCJleHAiOjE3NTk2NDE3ODB9.Umq_ls0LnXHmNiMc4aXhL8wG14ERckIAzCyjORATNss", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:18:10.475489+00
1399	\N	4	Read	{"q": "", "ip": "::1", "page": 1, "path": "/users?q=&limit=100", "limit": 100, "route": "GET /users", "method": "GET"}	2025-10-05 09:49:17.256083+00
1486	\N	4	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:58:33.274938+00
1564	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:16:22.489041+00
1633	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:43:51.597297+00
1639	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:43:55.628947+00
1671	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 19:38:39.430709+00
1716	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:26:30.999525+00
1718	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:26:34.159129+00
1770	\N	3	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "officer"}	2025-10-05 20:46:59.734085+00
1775	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200&holder=3", "query": {"limit": 200, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:47:03.637548+00
1776	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50&holder=3", "query": {"limit": 50, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:47:05.710601+00
1779	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200&holder=3", "query": {"limit": 200, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:47:06.68383+00
1787	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:16:03.229145+00
1832	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:37:48.277854+00
1833	\N	4	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "admin"}	2025-10-06 04:37:58.586021+00
1889	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:42:53.737097+00
1890	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-22", "query": {"limit": 1000, "date_from": "2025-09-22"}, "route": "GET /files", "method": "GET"}	2025-10-06 04:42:54.506158+00
1897	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:42:56.044656+00
1990	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:54:39.59823+00
1991	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:54:39.608497+00
1992	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:54:39.617067+00
1994	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:54:39.627993+00
2235	13	2	Read	{"ip": "::1", "path": "/files/13", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-06 04:59:18.543381+00
2236	13	2	Read	{"ip": "::1", "path": "/files/13/events", "count": 3, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 04:59:18.551696+00
2297	14	2	Read	{"ip": "::1", "path": "/files/14/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 05:02:30.084273+00
2329	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:06:12.756881+00
343	5	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNDgwLCJleHAiOjE3NTk2NDE3ODB9.Umq_ls0LnXHmNiMc4aXhL8wG14ERckIAzCyjORATNss", "count": 1, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:18:05.749725+00
344	5	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNDgwLCJleHAiOjE3NTk2NDE3ODB9.Umq_ls0LnXHmNiMc4aXhL8wG14ERckIAzCyjORATNss", "count": 1, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:18:05.753016+00
345	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNDgwLCJleHAiOjE3NTk2NDE3ODB9.Umq_ls0LnXHmNiMc4aXhL8wG14ERckIAzCyjORATNss", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:18:08.285856+00
346	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNDgwLCJleHAiOjE3NTk2NDE3ODB9.Umq_ls0LnXHmNiMc4aXhL8wG14ERckIAzCyjORATNss", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:18:08.289292+00
351	5	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNDgwLCJleHAiOjE3NTk2NDE3ODB9.Umq_ls0LnXHmNiMc4aXhL8wG14ERckIAzCyjORATNss", "count": 1, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:18:10.475992+00
352	5	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNDgwLCJleHAiOjE3NTk2NDE3ODB9.Umq_ls0LnXHmNiMc4aXhL8wG14ERckIAzCyjORATNss", "count": 1, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:18:10.480246+00
353	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNDgwLCJleHAiOjE3NTk2NDE3ODB9.Umq_ls0LnXHmNiMc4aXhL8wG14ERckIAzCyjORATNss", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:18:13.488119+00
354	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNDgwLCJleHAiOjE3NTk2NDE3ODB9.Umq_ls0LnXHmNiMc4aXhL8wG14ERckIAzCyjORATNss", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:18:13.491217+00
355	5	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNDgwLCJleHAiOjE3NTk2NDE3ODB9.Umq_ls0LnXHmNiMc4aXhL8wG14ERckIAzCyjORATNss", "count": 1, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:18:13.493588+00
356	5	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNDgwLCJleHAiOjE3NTk2NDE3ODB9.Umq_ls0LnXHmNiMc4aXhL8wG14ERckIAzCyjORATNss", "count": 1, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:18:13.497653+00
357	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNDgwLCJleHAiOjE3NTk2NDE3ODB9.Umq_ls0LnXHmNiMc4aXhL8wG14ERckIAzCyjORATNss", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:18:19.13836+00
358	5	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNDgwLCJleHAiOjE3NTk2NDE3ODB9.Umq_ls0LnXHmNiMc4aXhL8wG14ERckIAzCyjORATNss", "count": 1, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:18:19.145426+00
359	4	2	Read	{"ip": "::1", "path": "/files/4/events", "count": 0, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:18:59.903434+00
360	4	2	Write	{"ip": "::1", "path": "/files/4/token", "route": "POST /files/:id/token", "method": "POST"}	2025-10-05 05:19:01.215894+00
361	4	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjQsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNTQxLCJleHAiOjE3NTk2NDE4NDF9.SagQo6tteHNGVdV-Rx3r3zENVAhwd4YEF0VPmPPT-0Y", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:19:05.20202+00
362	4	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjQsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNTQxLCJleHAiOjE3NTk2NDE4NDF9.SagQo6tteHNGVdV-Rx3r3zENVAhwd4YEF0VPmPPT-0Y", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:19:05.208873+00
363	4	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjQsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNTQxLCJleHAiOjE3NTk2NDE4NDF9.SagQo6tteHNGVdV-Rx3r3zENVAhwd4YEF0VPmPPT-0Y", "count": 0, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:19:05.213192+00
364	4	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjQsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNTQxLCJleHAiOjE3NTk2NDE4NDF9.SagQo6tteHNGVdV-Rx3r3zENVAhwd4YEF0VPmPPT-0Y", "count": 0, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:19:05.218642+00
365	4	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjQsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNTQxLCJleHAiOjE3NTk2NDE4NDF9.SagQo6tteHNGVdV-Rx3r3zENVAhwd4YEF0VPmPPT-0Y", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:19:07.920486+00
366	4	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjQsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNTQxLCJleHAiOjE3NTk2NDE4NDF9.SagQo6tteHNGVdV-Rx3r3zENVAhwd4YEF0VPmPPT-0Y", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:19:07.927411+00
367	4	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjQsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNTQxLCJleHAiOjE3NTk2NDE4NDF9.SagQo6tteHNGVdV-Rx3r3zENVAhwd4YEF0VPmPPT-0Y", "count": 0, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:19:07.937467+00
368	4	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjQsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNTQxLCJleHAiOjE3NTk2NDE4NDF9.SagQo6tteHNGVdV-Rx3r3zENVAhwd4YEF0VPmPPT-0Y", "count": 0, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:19:07.945114+00
369	4	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjQsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNTQxLCJleHAiOjE3NTk2NDE4NDF9.SagQo6tteHNGVdV-Rx3r3zENVAhwd4YEF0VPmPPT-0Y", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:19:09.930075+00
700	2	1	Read	{"ip": "::1", "path": "/files/2/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 06:08:54.032117+00
370	4	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjQsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNTQxLCJleHAiOjE3NTk2NDE4NDF9.SagQo6tteHNGVdV-Rx3r3zENVAhwd4YEF0VPmPPT-0Y", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:19:09.936287+00
1400	\N	4	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:49:39.81154+00
1401	12	4	Read	{"ip": "::1", "path": "/files/12/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 09:49:40.099427+00
1402	12	4	Read	{"ip": "::1", "path": "/files/12/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 09:49:40.111135+00
1403	\N	4	Read	{"ip": "::1", "path": "/files?q=&limit=10&includeSla=false", "query": {"q": "", "limit": 10}, "route": "GET /files", "method": "GET"}	2025-10-05 09:49:43.571455+00
1417	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:49:59.396114+00
1422	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:49:59.420675+00
1487	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:58:44.180821+00
1565	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:16:52.763281+00
1566	\N	4	Read	{"ip": "::1", "path": "/files?q=&limit=10&includeSla=false", "query": {"q": "", "limit": 10}, "route": "GET /files", "method": "GET"}	2025-10-05 14:16:56.530372+00
1568	\N	4	Read	{"q": "", "ip": "::1", "page": 1, "path": "/users?q=&limit=100", "limit": 100, "route": "GET /users", "method": "GET"}	2025-10-05 14:16:57.402673+00
1634	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 14:43:55.598417+00
1636	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 14:43:55.604227+00
1672	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 19:38:41.250467+00
1717	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:26:32.09489+00
1771	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200&holder=3", "query": {"limit": 200, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:46:59.757117+00
1772	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50&holder=3", "query": {"limit": 50, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:47:01.816489+00
1774	\N	3	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&holder=3", "query": {"page": 1, "limit": 50, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:47:02.422573+00
1778	\N	3	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&holder=3", "query": {"page": 1, "limit": 50, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:47:06.240836+00
1788	\N	2	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "clerk"}	2025-10-06 04:17:55.536437+00
1834	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:37:58.616671+00
1835	\N	4	Read	{"ip": "::1", "path": "/files?q=&limit=10&includeSla=false", "query": {"q": "", "limit": 10}, "route": "GET /files", "method": "GET"}	2025-10-06 04:38:03.281957+00
1898	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:43:17.386766+00
1899	11	1	Read	{"ip": "::1", "path": "/files/11/events", "count": 4, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 04:43:23.845928+00
1900	11	1	Read	{"ip": "::1", "path": "/files/11/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 04:43:23.859081+00
1993	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:54:39.620696+00
1995	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:54:39.629176+00
1996	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:54:39.637417+00
1997	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:54:39.645584+00
2237	13	2	Read	{"ip": "::1", "path": "/files/13", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-06 04:59:18.552786+00
2298	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:02:45.637476+00
2330	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:06:12.911563+00
2331	13	2	Read	{"ip": "::1", "path": "/files/13/events", "count": 3, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 05:06:13.516027+00
2332	13	2	Read	{"ip": "::1", "path": "/files/13/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 05:06:13.529773+00
2333	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:06:14.199966+00
371	4	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjQsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNTQxLCJleHAiOjE3NTk2NDE4NDF9.SagQo6tteHNGVdV-Rx3r3zENVAhwd4YEF0VPmPPT-0Y", "count": 0, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:19:09.939264+00
372	4	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjQsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNTQxLCJleHAiOjE3NTk2NDE4NDF9.SagQo6tteHNGVdV-Rx3r3zENVAhwd4YEF0VPmPPT-0Y", "count": 0, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:19:09.944737+00
373	4	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjQsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNTQxLCJleHAiOjE3NTk2NDE4NDF9.SagQo6tteHNGVdV-Rx3r3zENVAhwd4YEF0VPmPPT-0Y", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:19:15.144676+00
374	4	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjQsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNTQxLCJleHAiOjE3NTk2NDE4NDF9.SagQo6tteHNGVdV-Rx3r3zENVAhwd4YEF0VPmPPT-0Y", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:19:15.149854+00
375	4	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjQsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNTQxLCJleHAiOjE3NTk2NDE4NDF9.SagQo6tteHNGVdV-Rx3r3zENVAhwd4YEF0VPmPPT-0Y", "count": 0, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:19:15.154254+00
376	4	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjQsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNTQxLCJleHAiOjE3NTk2NDE4NDF9.SagQo6tteHNGVdV-Rx3r3zENVAhwd4YEF0VPmPPT-0Y", "count": 0, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:19:15.162341+00
377	5	2	Read	{"ip": "::1", "path": "/files/shared/files/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNDgwLCJleHAiOjE3NTk2NDE3ODB9.Umq_ls0LnXHmNiMc4aXhL8wG14ERckIAzCyjORATNss", "route": "GET /files/shared/files/:token", "method": "GET"}	2025-10-05 05:19:26.793229+00
378	5	2	Read	{"ip": "::1", "path": "/files/shared/events/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNDgwLCJleHAiOjE3NTk2NDE3ODB9.Umq_ls0LnXHmNiMc4aXhL8wG14ERckIAzCyjORATNss", "count": 1, "route": "GET /files/shared/events/:token", "method": "GET"}	2025-10-05 05:19:26.803577+00
379	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:19:26.80589+00
380	\N	2	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "clerk"}	2025-10-05 05:20:00.847224+00
381	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:20:00.874641+00
382	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:20:01.894178+00
383	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:20:02.604704+00
384	5	2	Write	{"ip": "::1", "path": "/files/5/token", "route": "POST /files/:id/token", "method": "POST"}	2025-10-05 05:20:03.890341+00
385	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNjAzLCJleHAiOjE3NTk2NDE5MDN9.qnYt_-k28fij_7O6yOE1YQVNJ3ku6r-gfYZORxacUnU", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:20:08.216538+00
386	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNjAzLCJleHAiOjE3NTk2NDE5MDN9.qnYt_-k28fij_7O6yOE1YQVNJ3ku6r-gfYZORxacUnU", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:20:08.22057+00
387	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNjAzLCJleHAiOjE3NTk2NDE5MDN9.qnYt_-k28fij_7O6yOE1YQVNJ3ku6r-gfYZORxacUnU/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:20:08.223353+00
388	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNjAzLCJleHAiOjE3NTk2NDE5MDN9.qnYt_-k28fij_7O6yOE1YQVNJ3ku6r-gfYZORxacUnU/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:20:08.226648+00
389	\N	\N	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:20:18.120068+00
390	\N	\N	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:20:18.120977+00
391	\N	2	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "clerk"}	2025-10-05 05:21:35.765296+00
392	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:21:35.797353+00
393	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:21:37.361267+00
394	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:21:38.235409+00
395	5	2	Write	{"ip": "::1", "path": "/files/5/token", "route": "POST /files/:id/token", "method": "POST"}	2025-10-05 05:21:39.288714+00
396	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNjk5LCJleHAiOjE3NTk2NDE5OTl9.uczDgjXDkwXEm291smOaj5ligDSxBKyC_xJciO2Ssuw", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:21:43.858581+00
397	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNjk5LCJleHAiOjE3NTk2NDE5OTl9.uczDgjXDkwXEm291smOaj5ligDSxBKyC_xJciO2Ssuw", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:21:43.864744+00
701	2	1	Read	{"ip": "::1", "path": "/files/2/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 06:08:55.693074+00
398	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNjk5LCJleHAiOjE3NTk2NDE5OTl9.uczDgjXDkwXEm291smOaj5ligDSxBKyC_xJciO2Ssuw/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:21:43.866654+00
399	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNjk5LCJleHAiOjE3NTk2NDE5OTl9.uczDgjXDkwXEm291smOaj5ligDSxBKyC_xJciO2Ssuw/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:21:43.871123+00
400	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNjk5LCJleHAiOjE3NTk2NDE5OTl9.uczDgjXDkwXEm291smOaj5ligDSxBKyC_xJciO2Ssuw", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:21:53.361264+00
401	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNjk5LCJleHAiOjE3NTk2NDE5OTl9.uczDgjXDkwXEm291smOaj5ligDSxBKyC_xJciO2Ssuw", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:21:53.366193+00
1404	\N	4	Read	{"q": "", "ip": "::1", "page": 1, "path": "/users?q=&limit=100", "limit": 100, "route": "GET /users", "method": "GET"}	2025-10-05 09:49:43.57284+00
1438	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:50:19.219805+00
1448	12	4	Read	{"ip": "::1", "path": "/files/shared/12/5_f2-cBDxUr-2ykappoue7pwOQqhAwPk/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 09:50:25.720251+00
1449	12	4	Read	{"ip": "::1", "path": "/files/shared/12/5_f2-cBDxUr-2ykappoue7pwOQqhAwPk/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 09:50:25.727102+00
1450	\N	4	Read	{"ip": "::1", "path": "/files?q=&limit=10&includeSla=false", "query": {"q": "", "limit": 10}, "route": "GET /files", "method": "GET"}	2025-10-05 09:50:35.22008+00
1453	\N	4	Read	{"q": "", "ip": "::1", "page": 1, "path": "/users?q=&limit=100", "limit": 100, "route": "GET /users", "method": "GET"}	2025-10-05 09:50:36.170399+00
1457	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:50:40.131888+00
1462	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:50:46.005742+00
1488	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:58:46.621614+00
1567	\N	4	Read	{"q": "", "ip": "::1", "page": 1, "path": "/users?q=&limit=100", "limit": 100, "route": "GET /users", "method": "GET"}	2025-10-05 14:16:56.531624+00
1569	\N	4	Read	{"ip": "::1", "path": "/files?q=&limit=10&includeSla=false", "query": {"q": "", "limit": 10}, "route": "GET /files", "method": "GET"}	2025-10-05 14:16:57.403243+00
1571	\N	4	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:17:05.241493+00
1635	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:43:55.603355+00
1673	\N	4	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "admin"}	2025-10-05 19:38:51.904843+00
1684	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 19:39:07.708811+00
1719	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:28:05.486119+00
1721	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:28:07.737907+00
1773	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50&holder=3", "query": {"limit": 50, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:47:02.091338+00
1777	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50&holder=3", "query": {"limit": 50, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:47:05.980592+00
1789	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:17:55.578679+00
1836	\N	4	Read	{"q": "", "ip": "::1", "page": 1, "path": "/users?q=&limit=100", "limit": 100, "route": "GET /users", "method": "GET"}	2025-10-06 04:38:03.283516+00
1901	11	1	Read	{"ip": "::1", "path": "/files/11/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 04:43:34.881738+00
1998	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:54:51.83914+00
1999	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:54:51.847463+00
2004	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:54:54.010112+00
2005	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:54:54.016588+00
2238	\N	2	Read	{"ip": "::1", "path": "/files?q=&status=&office=&page=1&limit=50&sort_by=owning_office&sort_dir=desc&includeSla=true&creator=2", "query": {"q": "", "page": 1, "limit": 50, "status": "", "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:59:18.554698+00
2239	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:59:29.027281+00
2240	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:59:29.034588+00
402	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNjk5LCJleHAiOjE3NTk2NDE5OTl9.uczDgjXDkwXEm291smOaj5ligDSxBKyC_xJciO2Ssuw/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:21:53.368433+00
403	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNjk5LCJleHAiOjE3NTk2NDE5OTl9.uczDgjXDkwXEm291smOaj5ligDSxBKyC_xJciO2Ssuw/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:21:53.372555+00
404	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNjk5LCJleHAiOjE3NTk2NDE5OTl9.uczDgjXDkwXEm291smOaj5ligDSxBKyC_xJciO2Ssuw", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:21:57.912502+00
405	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNjk5LCJleHAiOjE3NTk2NDE5OTl9.uczDgjXDkwXEm291smOaj5ligDSxBKyC_xJciO2Ssuw/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:21:57.919928+00
406	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:21:57.945105+00
407	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:21:57.945724+00
408	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:21:57.953412+00
409	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:21:57.961565+00
410	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNjk5LCJleHAiOjE3NTk2NDE5OTl9.uczDgjXDkwXEm291smOaj5ligDSxBKyC_xJciO2Ssuw", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:22:12.182469+00
411	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNjk5LCJleHAiOjE3NTk2NDE5OTl9.uczDgjXDkwXEm291smOaj5ligDSxBKyC_xJciO2Ssuw", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:22:12.188445+00
412	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNjk5LCJleHAiOjE3NTk2NDE5OTl9.uczDgjXDkwXEm291smOaj5ligDSxBKyC_xJciO2Ssuw/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:22:12.195194+00
413	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNjk5LCJleHAiOjE3NTk2NDE5OTl9.uczDgjXDkwXEm291smOaj5ligDSxBKyC_xJciO2Ssuw/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:22:12.199641+00
414	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNjk5LCJleHAiOjE3NTk2NDE5OTl9.uczDgjXDkwXEm291smOaj5ligDSxBKyC_xJciO2Ssuw", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:22:23.027857+00
415	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNjk5LCJleHAiOjE3NTk2NDE5OTl9.uczDgjXDkwXEm291smOaj5ligDSxBKyC_xJciO2Ssuw", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:22:23.03587+00
416	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNjk5LCJleHAiOjE3NTk2NDE5OTl9.uczDgjXDkwXEm291smOaj5ligDSxBKyC_xJciO2Ssuw/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:22:23.043346+00
417	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNjk5LCJleHAiOjE3NTk2NDE5OTl9.uczDgjXDkwXEm291smOaj5ligDSxBKyC_xJciO2Ssuw/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:22:23.047463+00
418	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:22:24.742716+00
419	5	\N	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNjk5LCJleHAiOjE3NTk2NDE5OTl9.uczDgjXDkwXEm291smOaj5ligDSxBKyC_xJciO2Ssuw", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:22:27.883776+00
420	5	\N	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNjk5LCJleHAiOjE3NTk2NDE5OTl9.uczDgjXDkwXEm291smOaj5ligDSxBKyC_xJciO2Ssuw", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:22:27.890034+00
421	5	\N	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNjk5LCJleHAiOjE3NTk2NDE5OTl9.uczDgjXDkwXEm291smOaj5ligDSxBKyC_xJciO2Ssuw/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:22:27.891791+00
422	5	\N	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNjk5LCJleHAiOjE3NTk2NDE5OTl9.uczDgjXDkwXEm291smOaj5ligDSxBKyC_xJciO2Ssuw/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:22:27.895175+00
423	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNjk5LCJleHAiOjE3NTk2NDE5OTl9.uczDgjXDkwXEm291smOaj5ligDSxBKyC_xJciO2Ssuw", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:23:48.158354+00
424	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxNjk5LCJleHAiOjE3NTk2NDE5OTl9.uczDgjXDkwXEm291smOaj5ligDSxBKyC_xJciO2Ssuw/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:23:48.168589+00
425	\N	2	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "clerk"}	2025-10-05 05:24:04.043202+00
426	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:24:04.086382+00
1405	\N	4	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:49:47.696889+00
1406	12	4	Read	{"ip": "::1", "path": "/files/12/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 09:49:48.577276+00
1407	12	4	Read	{"ip": "::1", "path": "/files/12/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 09:49:48.588537+00
1413	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:49:57.111214+00
1414	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:49:57.389086+00
1415	\N	4	Read	{"ip": "::1", "path": "/files?q=&limit=10&includeSla=false", "query": {"q": "", "limit": 10}, "route": "GET /files", "method": "GET"}	2025-10-05 09:49:58.774884+00
1419	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:49:59.401054+00
1426	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:50:07.121735+00
1431	\N	4	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:50:14.071589+00
1432	12	4	Read	{"ip": "::1", "path": "/files/12/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 09:50:14.366352+00
1433	12	4	Read	{"ip": "::1", "path": "/files/12/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 09:50:14.375572+00
1435	\N	4	Read	{"q": "", "ip": "::1", "page": 1, "path": "/users?q=&limit=100", "limit": 100, "route": "GET /users", "method": "GET"}	2025-10-05 09:50:18.473197+00
1440	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:50:19.232647+00
1489	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 10:01:43.297641+00
1491	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 10:01:44.48586+00
1500	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 10:01:51.080788+00
1503	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 10:01:51.102185+00
1504	\N	4	Read	{"ip": "::1", "path": "/files?q=&limit=10&includeSla=false", "query": {"q": "", "limit": 10}, "route": "GET /files", "method": "GET"}	2025-10-05 10:01:51.685741+00
1506	\N	4	Read	{"ip": "::1", "path": "/files?q=&limit=10&includeSla=false", "query": {"q": "", "limit": 10}, "route": "GET /files", "method": "GET"}	2025-10-05 10:01:53.881192+00
1570	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:17:04.16541+00
1637	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:43:55.611288+00
1674	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 19:38:51.937269+00
1720	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:28:06.22335+00
1722	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:28:10.703174+00
1790	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:18:00.553428+00
1837	\N	4	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:39:14.497877+00
1838	13	4	Read	{"ip": "::1", "path": "/files/13/events", "count": 3, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 04:39:14.814712+00
1839	13	4	Read	{"ip": "::1", "path": "/files/13/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 04:39:14.82753+00
1840	13	4	Read	{"ip": "::1", "path": "/files/13/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 04:39:16.059299+00
1902	\N	1	Read	{"ip": "::1", "path": "/files?status=WithCOF&page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50, "status": "WithCOF"}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:43:39.980287+00
2000	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:54:51.853458+00
2001	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:54:51.860161+00
2002	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:54:54.000376+00
2003	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:54:54.009438+00
2241	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:59:29.041432+00
427	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:24:05.179086+00
428	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:24:05.979381+00
429	5	2	Write	{"ip": "::1", "path": "/files/5/token", "route": "POST /files/:id/token", "method": "POST"}	2025-10-05 05:24:06.880094+00
430	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxODQ2fQ.2fj6i8K3PWlASfdEJqDjiqHEKKCWF_vhHfB1nITiYKQ", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:24:11.532716+00
431	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxODQ2fQ.2fj6i8K3PWlASfdEJqDjiqHEKKCWF_vhHfB1nITiYKQ", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:24:11.537803+00
432	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxODQ2fQ.2fj6i8K3PWlASfdEJqDjiqHEKKCWF_vhHfB1nITiYKQ/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:24:11.541837+00
433	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxODQ2fQ.2fj6i8K3PWlASfdEJqDjiqHEKKCWF_vhHfB1nITiYKQ/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:24:11.545892+00
434	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxODQ2fQ.2fj6i8K3PWlASfdEJqDjiqHEKKCWF_vhHfB1nITiYKQ", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:24:19.818778+00
435	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxODQ2fQ.2fj6i8K3PWlASfdEJqDjiqHEKKCWF_vhHfB1nITiYKQ", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:24:19.822472+00
436	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxODQ2fQ.2fj6i8K3PWlASfdEJqDjiqHEKKCWF_vhHfB1nITiYKQ/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:24:19.8286+00
437	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxODQ2fQ.2fj6i8K3PWlASfdEJqDjiqHEKKCWF_vhHfB1nITiYKQ/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:24:19.83222+00
438	5	3	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxODQ2fQ.2fj6i8K3PWlASfdEJqDjiqHEKKCWF_vhHfB1nITiYKQ", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:24:28.242215+00
439	5	3	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxODQ2fQ.2fj6i8K3PWlASfdEJqDjiqHEKKCWF_vhHfB1nITiYKQ", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:24:28.242544+00
440	5	3	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxODQ2fQ.2fj6i8K3PWlASfdEJqDjiqHEKKCWF_vhHfB1nITiYKQ/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:24:28.250215+00
441	5	3	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxODQ2fQ.2fj6i8K3PWlASfdEJqDjiqHEKKCWF_vhHfB1nITiYKQ/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:24:28.250461+00
442	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200&holder=3", "query": {"limit": 200, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:24:31.237554+00
443	\N	1	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "cof"}	2025-10-05 05:24:38.042195+00
444	5	1	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxODQ2fQ.2fj6i8K3PWlASfdEJqDjiqHEKKCWF_vhHfB1nITiYKQ", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:24:38.062692+00
445	5	1	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxODQ2fQ.2fj6i8K3PWlASfdEJqDjiqHEKKCWF_vhHfB1nITiYKQ", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:24:38.062982+00
446	5	1	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxODQ2fQ.2fj6i8K3PWlASfdEJqDjiqHEKKCWF_vhHfB1nITiYKQ/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:24:38.069825+00
447	5	1	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxODQ2fQ.2fj6i8K3PWlASfdEJqDjiqHEKKCWF_vhHfB1nITiYKQ/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:24:38.070012+00
448	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:24:55.580877+00
449	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:24:58.542662+00
450	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:24:59.159684+00
451	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:25:03.716419+00
452	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:25:03.902899+00
453	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:25:04.064957+00
454	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:25:04.190612+00
455	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxODQ2fQ.2fj6i8K3PWlASfdEJqDjiqHEKKCWF_vhHfB1nITiYKQ", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:25:19.165683+00
456	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxODQ2fQ.2fj6i8K3PWlASfdEJqDjiqHEKKCWF_vhHfB1nITiYKQ", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:25:19.166099+00
457	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxODQ2fQ.2fj6i8K3PWlASfdEJqDjiqHEKKCWF_vhHfB1nITiYKQ/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:25:19.175366+00
458	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQxODQ2fQ.2fj6i8K3PWlASfdEJqDjiqHEKKCWF_vhHfB1nITiYKQ/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:25:19.176102+00
459	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:25:29.399795+00
460	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:25:29.666958+00
461	4	2	Read	{"ip": "::1", "path": "/files/4/events", "count": 0, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:25:30.29525+00
462	3	2	Read	{"ip": "::1", "path": "/files/3/events", "count": 4, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:25:33.656726+00
463	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:25:36.222506+00
464	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:28:28.074474+00
465	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:28:28.829563+00
466	5	2	Write	{"ip": "::1", "path": "/files/5/token", "route": "POST /files/:id/token", "method": "POST"}	2025-10-05 05:28:30.079815+00
467	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:28:31.480777+00
468	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:28:32.639563+00
469	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyMTEwfQ.WGMnTKl2AgADPhedhuFCRuSIFWePn7ORId9rc72m6Qw", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:28:46.312557+00
470	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyMTEwfQ.WGMnTKl2AgADPhedhuFCRuSIFWePn7ORId9rc72m6Qw", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:28:46.316622+00
471	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyMTEwfQ.WGMnTKl2AgADPhedhuFCRuSIFWePn7ORId9rc72m6Qw/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:28:46.322977+00
472	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyMTEwfQ.WGMnTKl2AgADPhedhuFCRuSIFWePn7ORId9rc72m6Qw/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:28:46.326617+00
473	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:28:47.986509+00
474	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:28:49.127616+00
475	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:29:31.692546+00
476	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:29:33.021205+00
477	\N	2	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "clerk"}	2025-10-05 05:29:39.793779+00
478	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:29:39.812118+00
479	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:29:41.643855+00
480	4	2	Read	{"ip": "::1", "path": "/files/4/events", "count": 0, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:29:42.716341+00
481	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:29:43.060045+00
482	3	2	Read	{"ip": "::1", "path": "/files/3/events", "count": 4, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:29:47.894175+00
483	2	2	Read	{"ip": "::1", "path": "/files/2/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:29:49.762948+00
484	1	2	Read	{"ip": "::1", "path": "/files/1/events", "count": 4, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:29:51.081091+00
485	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:31:26.733595+00
486	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:31:27.742357+00
487	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyMTEwfQ.WGMnTKl2AgADPhedhuFCRuSIFWePn7ORId9rc72m6Qw", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:31:33.545575+00
488	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyMTEwfQ.WGMnTKl2AgADPhedhuFCRuSIFWePn7ORId9rc72m6Qw", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:31:33.5502+00
489	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyMTEwfQ.WGMnTKl2AgADPhedhuFCRuSIFWePn7ORId9rc72m6Qw/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:31:33.552846+00
490	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyMTEwfQ.WGMnTKl2AgADPhedhuFCRuSIFWePn7ORId9rc72m6Qw/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:31:33.556601+00
491	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:31:43.442223+00
492	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:31:44.418557+00
493	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyMTEwfQ.WGMnTKl2AgADPhedhuFCRuSIFWePn7ORId9rc72m6Qw", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:31:47.830875+00
494	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyMTEwfQ.WGMnTKl2AgADPhedhuFCRuSIFWePn7ORId9rc72m6Qw", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:31:47.834945+00
495	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyMTEwfQ.WGMnTKl2AgADPhedhuFCRuSIFWePn7ORId9rc72m6Qw/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:31:47.837406+00
496	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyMTEwfQ.WGMnTKl2AgADPhedhuFCRuSIFWePn7ORId9rc72m6Qw/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:31:47.840645+00
497	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:31:53.088829+00
498	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:33:16.867914+00
499	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:33:24.69051+00
500	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyMTEwfQ.WGMnTKl2AgADPhedhuFCRuSIFWePn7ORId9rc72m6Qw", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:33:30.896075+00
501	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyMTEwfQ.WGMnTKl2AgADPhedhuFCRuSIFWePn7ORId9rc72m6Qw", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:33:30.901553+00
502	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyMTEwfQ.WGMnTKl2AgADPhedhuFCRuSIFWePn7ORId9rc72m6Qw/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:33:30.909627+00
503	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyMTEwfQ.WGMnTKl2AgADPhedhuFCRuSIFWePn7ORId9rc72m6Qw/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:33:30.913499+00
504	5	2	Write	{"ip": "::1", "path": "/files/5/token", "route": "POST /files/:id/token", "method": "POST"}	2025-10-05 05:33:33.928588+00
505	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyMTEwfQ.WGMnTKl2AgADPhedhuFCRuSIFWePn7ORId9rc72m6Qw", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:33:37.965137+00
506	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyMTEwfQ.WGMnTKl2AgADPhedhuFCRuSIFWePn7ORId9rc72m6Qw/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:33:37.97194+00
507	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyMTEwfQ.WGMnTKl2AgADPhedhuFCRuSIFWePn7ORId9rc72m6Qw", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:33:37.974368+00
508	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyMTEwfQ.WGMnTKl2AgADPhedhuFCRuSIFWePn7ORId9rc72m6Qw/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:33:37.978725+00
509	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyMTEwfQ.WGMnTKl2AgADPhedhuFCRuSIFWePn7ORId9rc72m6Qw", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:33:39.772449+00
510	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyMTEwfQ.WGMnTKl2AgADPhedhuFCRuSIFWePn7ORId9rc72m6Qw", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:33:39.776204+00
511	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyMTEwfQ.WGMnTKl2AgADPhedhuFCRuSIFWePn7ORId9rc72m6Qw/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:33:39.777182+00
512	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyMTEwfQ.WGMnTKl2AgADPhedhuFCRuSIFWePn7ORId9rc72m6Qw/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:33:39.78042+00
513	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyNDEzfQ.Jds4nQhX9zzr8ePZ9LzO67yPnlQjFg1-Sb9Db5Z9DRE", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:33:43.050515+00
514	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyNDEzfQ.Jds4nQhX9zzr8ePZ9LzO67yPnlQjFg1-Sb9Db5Z9DRE", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:33:43.053957+00
515	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyNDEzfQ.Jds4nQhX9zzr8ePZ9LzO67yPnlQjFg1-Sb9Db5Z9DRE/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:33:43.057107+00
516	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyNDEzfQ.Jds4nQhX9zzr8ePZ9LzO67yPnlQjFg1-Sb9Db5Z9DRE/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:33:43.059929+00
517	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyNDEzfQ.Jds4nQhX9zzr8ePZ9LzO67yPnlQjFg1-Sb9Db5Z9DRE", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:33:45.530008+00
518	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyNDEzfQ.Jds4nQhX9zzr8ePZ9LzO67yPnlQjFg1-Sb9Db5Z9DRE", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:33:45.536095+00
528	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyNDI5fQ.DwyRE-FAjFeJwyo-KjZBX3swdd1xdbwgxQue5B2Cl4U/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:33:52.576342+00
529	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyNDI5fQ.DwyRE-FAjFeJwyo-KjZBX3swdd1xdbwgxQue5B2Cl4U/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:33:52.579784+00
530	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyNDEzfQ.Jds4nQhX9zzr8ePZ9LzO67yPnlQjFg1-Sb9Db5Z9DRE", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:33:53.655472+00
531	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyNDEzfQ.Jds4nQhX9zzr8ePZ9LzO67yPnlQjFg1-Sb9Db5Z9DRE", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:33:53.659857+00
536	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyMTEwfQ.WGMnTKl2AgADPhedhuFCRuSIFWePn7ORId9rc72m6Qw/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:33:54.961256+00
537	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyMTEwfQ.WGMnTKl2AgADPhedhuFCRuSIFWePn7ORId9rc72m6Qw/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:33:54.96493+00
1408	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:49:53.822976+00
1412	\N	4	Read	{"q": "", "ip": "::1", "page": 1, "path": "/users?q=&limit=100", "limit": 100, "route": "GET /users", "method": "GET"}	2025-10-05 09:49:56.208239+00
1420	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:49:59.405624+00
1427	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:50:07.129015+00
1434	\N	4	Read	{"ip": "::1", "path": "/files?q=&limit=10&includeSla=false", "query": {"q": "", "limit": 10}, "route": "GET /files", "method": "GET"}	2025-10-05 09:50:18.473173+00
1436	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:50:19.215579+00
1490	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 10:01:43.993577+00
1572	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:37:40.758421+00
1638	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:43:55.621778+00
1675	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 19:38:56.415237+00
1677	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 19:38:56.422453+00
1679	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 19:38:56.442233+00
1723	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:28:11.073349+00
1791	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:18:01.45632+00
1841	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:39:17.170088+00
1903	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:43:40.687249+00
1904	\N	4	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "admin"}	2025-10-06 04:43:45.86741+00
2006	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:54:57.730644+00
2007	13	2	Read	{"ip": "::1", "path": "/files/13/events", "count": 3, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 04:54:58.257434+00
519	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyNDEzfQ.Jds4nQhX9zzr8ePZ9LzO67yPnlQjFg1-Sb9Db5Z9DRE/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:33:45.53647+00
520	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyNDEzfQ.Jds4nQhX9zzr8ePZ9LzO67yPnlQjFg1-Sb9Db5Z9DRE/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:33:45.541656+00
521	5	2	Write	{"ip": "::1", "path": "/files/5/token", "route": "POST /files/:id/token", "method": "POST"}	2025-10-05 05:33:49.11703+00
522	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyNDI5fQ.DwyRE-FAjFeJwyo-KjZBX3swdd1xdbwgxQue5B2Cl4U", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:33:50.943447+00
523	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyNDI5fQ.DwyRE-FAjFeJwyo-KjZBX3swdd1xdbwgxQue5B2Cl4U", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:33:50.947322+00
524	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyNDI5fQ.DwyRE-FAjFeJwyo-KjZBX3swdd1xdbwgxQue5B2Cl4U/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:33:50.949557+00
525	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyNDI5fQ.DwyRE-FAjFeJwyo-KjZBX3swdd1xdbwgxQue5B2Cl4U/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:33:50.953162+00
526	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyNDI5fQ.DwyRE-FAjFeJwyo-KjZBX3swdd1xdbwgxQue5B2Cl4U", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:33:52.57029+00
527	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyNDI5fQ.DwyRE-FAjFeJwyo-KjZBX3swdd1xdbwgxQue5B2Cl4U", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:33:52.576114+00
532	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyNDEzfQ.Jds4nQhX9zzr8ePZ9LzO67yPnlQjFg1-Sb9Db5Z9DRE/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:33:53.661054+00
533	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyNDEzfQ.Jds4nQhX9zzr8ePZ9LzO67yPnlQjFg1-Sb9Db5Z9DRE/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:33:53.663637+00
534	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyMTEwfQ.WGMnTKl2AgADPhedhuFCRuSIFWePn7ORId9rc72m6Qw", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:33:54.956254+00
535	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyMTEwfQ.WGMnTKl2AgADPhedhuFCRuSIFWePn7ORId9rc72m6Qw", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:33:54.960039+00
538	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:34:11.29305+00
539	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:34:14.939748+00
540	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:34:15.549337+00
541	5	1	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:34:16.549888+00
542	4	1	Read	{"ip": "::1", "path": "/files/4/events", "count": 0, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:34:19.474683+00
543	3	1	Read	{"ip": "::1", "path": "/files/3/events", "count": 4, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:34:21.641037+00
544	2	1	Read	{"ip": "::1", "path": "/files/2/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:34:23.391435+00
545	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:35:54.396622+00
546	5	1	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:35:55.327042+00
547	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:38:45.646985+00
548	5	1	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:38:47.450118+00
549	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:38:58.443092+00
550	5	1	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:38:58.993528+00
551	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:39:02.084618+00
552	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:39:05.654722+00
553	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:39:06.744669+00
554	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:39:07.577652+00
555	5	2	Write	{"ip": "::1", "path": "/files/5/token", "route": "POST /files/:id/token", "method": "POST"}	2025-10-05 05:39:14.598618+00
556	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyNzU0fQ.5hSgcoOMcOQS3Y-JBArtwTeRzT1BNpiM0Jh4g9UGWP4", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:39:15.916373+00
557	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyNzU0fQ.5hSgcoOMcOQS3Y-JBArtwTeRzT1BNpiM0Jh4g9UGWP4", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:39:15.920206+00
558	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyNzU0fQ.5hSgcoOMcOQS3Y-JBArtwTeRzT1BNpiM0Jh4g9UGWP4/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:39:15.923142+00
559	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyNzU0fQ.5hSgcoOMcOQS3Y-JBArtwTeRzT1BNpiM0Jh4g9UGWP4/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:39:15.926779+00
560	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:39:16.88254+00
561	5	2	Write	{"ip": "::1", "path": "/files/5/token", "route": "POST /files/:id/token", "method": "POST"}	2025-10-05 05:39:32.959613+00
562	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyNzcyfQ.vKp9kQhXn8js2UyGcIUE5T3gZxTn50rqq9Z0rD3TDgo", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:39:34.496295+00
563	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyNzcyfQ.vKp9kQhXn8js2UyGcIUE5T3gZxTn50rqq9Z0rD3TDgo", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:39:34.499868+00
564	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyNzcyfQ.vKp9kQhXn8js2UyGcIUE5T3gZxTn50rqq9Z0rD3TDgo/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:39:34.506761+00
565	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyNzcyfQ.vKp9kQhXn8js2UyGcIUE5T3gZxTn50rqq9Z0rD3TDgo/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:39:34.51005+00
566	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyNzcyfQ.vKp9kQhXn8js2UyGcIUE5T3gZxTn50rqq9Z0rD3TDgo", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:39:36.451392+00
567	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyNzcyfQ.vKp9kQhXn8js2UyGcIUE5T3gZxTn50rqq9Z0rD3TDgo", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:39:36.457067+00
568	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyNzcyfQ.vKp9kQhXn8js2UyGcIUE5T3gZxTn50rqq9Z0rD3TDgo/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:39:36.457441+00
569	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyNzcyfQ.vKp9kQhXn8js2UyGcIUE5T3gZxTn50rqq9Z0rD3TDgo/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:39:36.461888+00
570	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyNzcyfQ.vKp9kQhXn8js2UyGcIUE5T3gZxTn50rqq9Z0rD3TDgo", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:39:36.824006+00
571	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyNzcyfQ.vKp9kQhXn8js2UyGcIUE5T3gZxTn50rqq9Z0rD3TDgo", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:39:36.829593+00
572	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyNzcyfQ.vKp9kQhXn8js2UyGcIUE5T3gZxTn50rqq9Z0rD3TDgo/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:39:36.82983+00
573	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyNzcyfQ.vKp9kQhXn8js2UyGcIUE5T3gZxTn50rqq9Z0rD3TDgo/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:39:36.833483+00
574	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyNzcyfQ.vKp9kQhXn8js2UyGcIUE5T3gZxTn50rqq9Z0rD3TDgo", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:39:37.069737+00
575	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyNzcyfQ.vKp9kQhXn8js2UyGcIUE5T3gZxTn50rqq9Z0rD3TDgo", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:39:37.074935+00
576	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyNzcyfQ.vKp9kQhXn8js2UyGcIUE5T3gZxTn50rqq9Z0rD3TDgo/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:39:37.075288+00
577	5	2	Read	{"ip": "::1", "path": "/files/shared/5/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJmaWxlSWQiOjUsInNjb3BlIjoiZmlsZV9zaGFyZV9yZWFkIiwiaWF0IjoxNzU5NjQyNzcyfQ.vKp9kQhXn8js2UyGcIUE5T3gZxTn50rqq9Z0rD3TDgo/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:39:37.079508+00
578	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:45:09.034829+00
579	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:45:09.275293+00
580	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:45:10.330978+00
702	1	1	Read	{"ip": "::1", "path": "/files/1/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 06:08:56.435008+00
581	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:47:40.588707+00
582	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:47:41.546048+00
583	5	2	Write	{"ip": "::1", "path": "/files/5/token", "route": "POST /files/:id/token", "method": "POST", "stable": true}	2025-10-05 05:47:45.900027+00
584	5	2	Read	{"ip": "::1", "path": "/files/shared/5/3QI0fAlOtQpAsJFRUlt-TxSbWLF00X1e", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:47:48.593037+00
585	5	2	Read	{"ip": "::1", "path": "/files/shared/5/3QI0fAlOtQpAsJFRUlt-TxSbWLF00X1e", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:47:48.602577+00
586	5	2	Read	{"ip": "::1", "path": "/files/shared/5/3QI0fAlOtQpAsJFRUlt-TxSbWLF00X1e/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:47:48.604511+00
587	5	2	Read	{"ip": "::1", "path": "/files/shared/5/3QI0fAlOtQpAsJFRUlt-TxSbWLF00X1e/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:47:48.61166+00
588	5	2	Write	{"ip": "::1", "path": "/files/5/token", "route": "POST /files/:id/token", "method": "POST", "stable": true}	2025-10-05 05:47:52.325718+00
589	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:47:53.950072+00
590	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:47:54.750421+00
591	5	2	Read	{"ip": "::1", "path": "/files/shared/5/3QI0fAlOtQpAsJFRUlt-TxSbWLF00X1e", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:47:56.321771+00
592	5	2	Read	{"ip": "::1", "path": "/files/shared/5/3QI0fAlOtQpAsJFRUlt-TxSbWLF00X1e", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:47:56.330751+00
593	5	2	Read	{"ip": "::1", "path": "/files/shared/5/3QI0fAlOtQpAsJFRUlt-TxSbWLF00X1e/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:47:56.333095+00
594	5	2	Read	{"ip": "::1", "path": "/files/shared/5/3QI0fAlOtQpAsJFRUlt-TxSbWLF00X1e/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:47:56.339782+00
595	5	2	Read	{"ip": "::1", "path": "/files/shared/5/3QI0fAlOtQpAsJFRUlt-TxSbWLF00X1e", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:48:00.143925+00
596	5	2	Read	{"ip": "::1", "path": "/files/shared/5/3QI0fAlOtQpAsJFRUlt-TxSbWLF00X1e", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:48:00.152618+00
597	5	2	Read	{"ip": "::1", "path": "/files/shared/5/3QI0fAlOtQpAsJFRUlt-TxSbWLF00X1e/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:48:00.152993+00
598	5	2	Read	{"ip": "::1", "path": "/files/shared/5/3QI0fAlOtQpAsJFRUlt-TxSbWLF00X1e/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:48:00.160706+00
599	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:48:00.848527+00
600	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:49:22.940483+00
601	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:49:23.641586+00
602	5	2	Write	{"ip": "::1", "path": "/files/5/token", "route": "POST /files/:id/token", "method": "POST", "stable": true}	2025-10-05 05:49:27.931459+00
603	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:49:28.457775+00
604	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:49:29.668555+00
605	4	2	Read	{"ip": "::1", "path": "/files/4/events", "count": 0, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:49:31.341341+00
606	4	2	Write	{"ip": "::1", "path": "/files/4/token", "route": "POST /files/:id/token", "method": "POST", "stable": true}	2025-10-05 05:49:32.672411+00
607	4	2	Write	{"ip": "::1", "path": "/files/4/token", "route": "POST /files/:id/token", "method": "POST", "stable": true}	2025-10-05 05:49:34.975835+00
608	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:49:39.047584+00
609	4	2	Read	{"ip": "::1", "path": "/files/4/events", "count": 0, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:49:40.408531+00
610	5	2	Read	{"ip": "::1", "path": "/files/shared/5/3QI0fAlOtQpAsJFRUlt-TxSbWLF00X1e", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:50:54.185428+00
611	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:50:54.19454+00
612	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:50:54.19807+00
613	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:50:54.202932+00
614	5	2	Read	{"ip": "::1", "path": "/files/shared/5/3QI0fAlOtQpAsJFRUlt-TxSbWLF00X1e", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:50:54.203528+00
615	5	2	Read	{"ip": "::1", "path": "/files/shared/5/3QI0fAlOtQpAsJFRUlt-TxSbWLF00X1e/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:50:54.206227+00
616	5	2	Read	{"ip": "::1", "path": "/files/shared/5/3QI0fAlOtQpAsJFRUlt-TxSbWLF00X1e/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:50:54.214763+00
617	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:50:54.811362+00
618	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:51:27.795353+00
619	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:51:29.067525+00
620	5	2	Write	{"ip": "::1", "path": "/files/5/token?force=true", "route": "POST /files/:id/token", "method": "POST", "stable": true}	2025-10-05 05:51:31.083519+00
621	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:51:32.809686+00
622	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:51:33.782421+00
623	4	2	Read	{"ip": "::1", "path": "/files/4/events", "count": 0, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:51:36.28281+00
624	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:51:37.184124+00
625	4	2	Read	{"ip": "::1", "path": "/files/4/events", "count": 0, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:51:37.988463+00
626	3	2	Read	{"ip": "::1", "path": "/files/3/events", "count": 4, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:51:39.560188+00
627	2	2	Read	{"ip": "::1", "path": "/files/2/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:51:42.376755+00
628	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:51:44.763338+00
629	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:51:46.125185+00
630	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:51:50.393046+00
631	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:51:50.398192+00
632	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:51:50.398424+00
633	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:51:50.64153+00
634	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:52:03.964233+00
635	5	2	Read	{"ip": "::1", "path": "/files/shared/5/7xZIME44yshU6EvfUNN5egBuMQCVYvZR", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:52:05.210156+00
636	5	2	Read	{"ip": "::1", "path": "/files/shared/5/7xZIME44yshU6EvfUNN5egBuMQCVYvZR", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:52:05.217872+00
637	5	2	Read	{"ip": "::1", "path": "/files/shared/5/7xZIME44yshU6EvfUNN5egBuMQCVYvZR/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:52:05.225655+00
638	5	2	Read	{"ip": "::1", "path": "/files/shared/5/7xZIME44yshU6EvfUNN5egBuMQCVYvZR/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:52:05.232507+00
639	5	2	Write	{"ip": "::1", "path": "/files/5/token?force=true", "route": "POST /files/:id/token", "method": "POST", "stable": true}	2025-10-05 05:52:07.961105+00
640	5	2	Read	{"ip": "::1", "path": "/files/shared/5/vOC73QcUDzGFOs089z-hDXcNb8agHnu0", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:52:09.01574+00
641	5	2	Read	{"ip": "::1", "path": "/files/shared/5/vOC73QcUDzGFOs089z-hDXcNb8agHnu0", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:52:09.024548+00
642	5	2	Read	{"ip": "::1", "path": "/files/shared/5/vOC73QcUDzGFOs089z-hDXcNb8agHnu0/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:52:09.025554+00
643	5	2	Read	{"ip": "::1", "path": "/files/shared/5/vOC73QcUDzGFOs089z-hDXcNb8agHnu0/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:52:09.033302+00
644	5	2	Read	{"ip": "::1", "path": "/files/shared/5/vOC73QcUDzGFOs089z-hDXcNb8agHnu0", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:51:17.471099+00
645	5	2	Read	{"ip": "::1", "path": "/files/shared/5/vOC73QcUDzGFOs089z-hDXcNb8agHnu0", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:51:17.479646+00
646	5	2	Read	{"ip": "::1", "path": "/files/shared/5/vOC73QcUDzGFOs089z-hDXcNb8agHnu0/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:51:17.480149+00
647	5	2	Read	{"ip": "::1", "path": "/files/shared/5/vOC73QcUDzGFOs089z-hDXcNb8agHnu0/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:51:17.487074+00
648	5	2	Read	{"ip": "::1", "path": "/files/shared/5/vOC73QcUDzGFOs089z-hDXcNb8agHnu0", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:52:14.505308+00
649	5	2	Read	{"ip": "::1", "path": "/files/shared/5/vOC73QcUDzGFOs089z-hDXcNb8agHnu0", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:52:14.513943+00
650	5	2	Read	{"ip": "::1", "path": "/files/shared/5/vOC73QcUDzGFOs089z-hDXcNb8agHnu0/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:52:14.514169+00
651	5	2	Read	{"ip": "::1", "path": "/files/shared/5/vOC73QcUDzGFOs089z-hDXcNb8agHnu0/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:52:14.521257+00
652	5	2	Read	{"ip": "::1", "path": "/files/shared/5/vOC73QcUDzGFOs089z-hDXcNb8agHnu0", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:52:14.602482+00
653	5	2	Read	{"ip": "::1", "path": "/files/shared/5/vOC73QcUDzGFOs089z-hDXcNb8agHnu0", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 05:52:14.610555+00
654	5	2	Read	{"ip": "::1", "path": "/files/shared/5/vOC73QcUDzGFOs089z-hDXcNb8agHnu0/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 05:52:14.61078+00
1109	5	3	Write	{"ip": "::1", "path": "/files/5/sla/reason", "route": "POST /files/:id/sla/reason", "method": "POST"}	2025-10-05 09:07:56.804032+00
656	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:52:22.598813+00
657	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:52:23.499623+00
658	4	2	Read	{"ip": "::1", "path": "/files/4/events", "count": 0, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:52:26.636312+00
659	3	2	Read	{"ip": "::1", "path": "/files/3/events", "count": 4, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:52:27.421353+00
660	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:52:30.334256+00
1409	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:49:54.094816+00
1410	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:49:54.69499+00
1411	\N	4	Read	{"ip": "::1", "path": "/files?q=&limit=10&includeSla=false", "query": {"q": "", "limit": 10}, "route": "GET /files", "method": "GET"}	2025-10-05 09:49:56.206645+00
1424	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:50:07.113828+00
1439	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:50:19.226171+00
1492	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 10:01:44.488809+00
1499	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 10:01:51.079364+00
1573	\N	2	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "clerk"}	2025-10-05 14:37:52.487455+00
1640	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:45:04.027795+00
1676	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 19:38:56.421703+00
1724	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:28:44.419245+00
1732	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:28:51.070183+00
1792	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:18:03.127301+00
1842	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:39:46.367684+00
1905	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:43:45.887348+00
2008	13	2	Read	{"ip": "::1", "path": "/files/13/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 04:54:58.269194+00
2009	13	2	Read	{"ip": "::1", "path": "/files/13/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 04:55:01.335357+00
2010	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:02.991753+00
2011	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:02.999892+00
2016	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:03.315172+00
2017	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:03.321096+00
2018	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:03.480032+00
2019	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:03.487747+00
2024	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:03.61493+00
2025	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:03.621586+00
2026	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:03.714292+00
2027	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:03.722029+00
2032	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:04.057869+00
2033	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:04.06396+00
2034	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:04.220515+00
2035	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:04.228054+00
2040	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:04.587367+00
661	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:52:31.736322+00
1416	\N	4	Read	{"q": "", "ip": "::1", "page": 1, "path": "/users?q=&limit=100", "limit": 100, "route": "GET /users", "method": "GET"}	2025-10-05 09:49:58.775116+00
1423	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:50:07.111839+00
1428	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:50:07.136255+00
1429	\N	4	Read	{"ip": "::1", "path": "/files?q=&limit=10&includeSla=false", "query": {"q": "", "limit": 10}, "route": "GET /files", "method": "GET"}	2025-10-05 09:50:10.201049+00
1437	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:50:19.217855+00
1493	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 10:01:44.492862+00
1497	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 10:01:45.134726+00
1501	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 10:01:51.086597+00
1574	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:37:52.52314+00
1641	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:45:04.277524+00
1678	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 19:38:56.432879+00
1680	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 19:38:56.449941+00
1725	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:28:44.914117+00
1727	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:28:45.253564+00
1729	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:28:46.055478+00
1731	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:28:50.694991+00
1793	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:17:08.630159+00
1794	13	2	Read	{"ip": "::1", "path": "/files/13/events", "count": 3, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 04:18:10.165682+00
1795	13	2	Read	{"ip": "::1", "path": "/files/13/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 04:18:10.180825+00
1843	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:40:12.052127+00
1906	\N	4	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:43:58.175216+00
1907	3	4	Read	{"ip": "::1", "path": "/files/3/events", "count": 6, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 04:43:58.462299+00
1908	3	4	Read	{"ip": "::1", "path": "/files/3/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 04:43:58.473423+00
2012	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:03.001583+00
2013	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:03.008206+00
2014	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:03.306231+00
2015	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:03.314723+00
2020	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:03.488197+00
2021	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:03.494194+00
2022	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:03.606345+00
2023	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:03.614515+00
2028	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:03.722444+00
2029	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:03.728877+00
2030	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:04.049834+00
2031	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:04.057398+00
662	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 05:52:35.837009+00
663	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:52:36.566631+00
664	3	2	Read	{"ip": "::1", "path": "/files/3/events", "count": 4, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 05:55:29.152256+00
665	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:02:07.05155+00
666	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:02:08.331931+00
667	5	1	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 06:02:08.844569+00
668	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:02:11.118173+00
669	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:02:11.724039+00
670	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:02:11.884808+00
671	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:02:13.264179+00
672	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:02:13.624227+00
673	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:02:13.903102+00
674	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:02:14.231452+00
675	5	1	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 06:02:14.995603+00
676	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:02:17.90264+00
677	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:02:18.345656+00
678	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:02:18.563625+00
679	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:06:11.977496+00
680	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:06:12.173692+00
681	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:06:12.176425+00
682	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:06:12.177442+00
683	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:06:29.111308+00
684	5	1	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 06:06:31.265298+00
685	5	1	Read	{"ip": "::1", "path": "/files/5/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 06:06:31.277344+00
686	4	1	Read	{"ip": "::1", "path": "/files/4/events", "count": 0, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 06:06:35.599166+00
687	4	1	Read	{"ip": "::1", "path": "/files/4/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 06:06:35.611536+00
688	3	1	Read	{"ip": "::1", "path": "/files/3/events", "count": 4, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 06:06:37.228636+00
689	3	1	Read	{"ip": "::1", "path": "/files/3/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 06:06:37.24154+00
690	2	1	Read	{"ip": "::1", "path": "/files/2/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 06:06:38.67302+00
691	2	1	Read	{"ip": "::1", "path": "/files/2/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 06:06:38.687588+00
692	1	1	Read	{"ip": "::1", "path": "/files/1/events", "count": 4, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 06:06:39.794065+00
693	1	1	Read	{"ip": "::1", "path": "/files/1/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 06:06:39.805927+00
694	5	1	Read	{"ip": "::1", "path": "/files/5/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 06:06:41.4663+00
695	5	1	Read	{"ip": "::1", "path": "/files/5/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 06:06:46.059424+00
696	4	1	Read	{"ip": "::1", "path": "/files/4/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 06:06:46.839142+00
697	4	1	Read	{"ip": "::1", "path": "/files/4/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 06:06:47.427522+00
698	3	1	Read	{"ip": "::1", "path": "/files/3/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 06:08:51.523506+00
699	3	1	Read	{"ip": "::1", "path": "/files/3/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 06:08:53.340415+00
703	4	1	Read	{"ip": "::1", "path": "/files/4/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 06:09:05.343836+00
704	4	1	Read	{"ip": "::1", "path": "/files/4/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 06:09:06.344126+00
705	5	1	Read	{"ip": "::1", "path": "/files/5/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 06:11:16.874715+00
706	5	1	Read	{"ip": "::1", "path": "/files/5/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 06:11:18.097069+00
707	5	1	Read	{"ip": "::1", "path": "/files/5/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 06:11:18.381948+00
708	5	1	Read	{"ip": "::1", "path": "/files/5/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 06:11:23.698561+00
709	5	1	Read	{"ip": "::1", "path": "/files/5/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 06:11:24.091833+00
710	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:11:26.089821+00
711	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:11:26.541179+00
712	5	1	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 06:11:27.150732+00
713	5	1	Read	{"ip": "::1", "path": "/files/5/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 06:11:27.160239+00
714	4	1	Read	{"ip": "::1", "path": "/files/4/events", "count": 0, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 06:11:53.727092+00
715	4	1	Read	{"ip": "::1", "path": "/files/4/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 06:11:53.739018+00
716	6	1	Write	{"ip": "::1", "path": "/files", "route": "POST /files", "method": "POST", "payload": {"remarks": "SOMETHING", "subject": "create file", "priority": "Urgent", "attachments": [{"url": "/new.pdf"}], "category_id": 1, "save_as_draft": false, "sla_policy_id": 2, "date_initiated": "2025-10-05", "confidentiality": false, "notesheet_title": "my file", "owning_office_id": 1, "forward_to_officer_id": 3, "date_received_accounts": "2025-10-05"}}	2025-10-05 06:12:34.494568+00
717	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:12:39.596002+00
718	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:12:41.580258+00
719	6	1	Read	{"ip": "::1", "path": "/files/6/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 06:12:42.516407+00
720	6	1	Read	{"ip": "::1", "path": "/files/6/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 06:12:42.52777+00
721	6	1	Read	{"ip": "::1", "path": "/files/6/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 06:12:48.241694+00
722	5	1	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 06:12:48.808578+00
723	5	1	Read	{"ip": "::1", "path": "/files/5/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 06:12:48.820361+00
724	6	1	Read	{"ip": "::1", "path": "/files/6/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 06:13:08.249286+00
725	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:13:12.610651+00
726	6	1	Read	{"ip": "::1", "path": "/files/6/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 06:13:13.371878+00
727	6	1	Read	{"ip": "::1", "path": "/files/6/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 06:13:13.382892+00
728	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:13:19.612521+00
729	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:13:19.617546+00
730	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:13:19.617711+00
731	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:13:19.982672+00
732	5	1	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 06:13:49.222571+00
733	5	1	Read	{"ip": "::1", "path": "/files/5/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 06:13:49.236286+00
734	6	1	Read	{"ip": "::1", "path": "/files/6/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 06:13:50.960612+00
735	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:13:52.145346+00
736	6	1	Read	{"ip": "::1", "path": "/files/6/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 06:12:56.728191+00
737	6	1	Read	{"ip": "::1", "path": "/files/6/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 06:12:56.73875+00
738	6	1	Read	{"ip": "::1", "path": "/files/6/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 06:14:03.479058+00
739	6	1	Read	{"ip": "::1", "path": "/files/6/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 06:14:04.183113+00
740	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:14:05.429157+00
741	6	1	Read	{"ip": "::1", "path": "/files/6/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 06:14:05.926644+00
742	6	1	Read	{"ip": "::1", "path": "/files/6/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 06:14:05.936526+00
743	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:14:18.244855+00
744	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:14:48.548319+00
745	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:15:47.343926+00
746	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:16:17.618118+00
747	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:16:47.89089+00
748	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:17:41.058412+00
749	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:17:41.346076+00
750	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:17:54.139334+00
751	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:17:55.032578+00
752	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:19:00.0392+00
753	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:19:00.108783+00
754	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:19:39.522495+00
755	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:18:46.08101+00
756	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:20:10.41981+00
757	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:20:11.239827+00
758	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:20:20.597208+00
759	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:20:22.875585+00
760	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:20:23.159711+00
761	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:20:23.264612+00
762	6	1	Read	{"ip": "::1", "path": "/files/6/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 06:20:24.43919+00
763	6	1	Read	{"ip": "::1", "path": "/files/6/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 06:20:24.45107+00
764	6	1	Read	{"ip": "::1", "path": "/files/6/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 06:20:25.450305+00
765	5	1	Read	{"ip": "::1", "path": "/files/5/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 06:20:26.106164+00
766	5	1	Read	{"ip": "::1", "path": "/files/5/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 06:20:26.117952+00
767	5	1	Read	{"ip": "::1", "path": "/files/5/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 06:20:26.584179+00
768	6	1	Read	{"ip": "::1", "path": "/files/6/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 06:20:27.502462+00
769	6	1	Read	{"ip": "::1", "path": "/files/6/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 06:20:27.919933+00
770	6	1	Read	{"ip": "::1", "path": "/files/6/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 06:20:29.483197+00
771	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:20:32.520599+00
772	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:20:53.529579+00
773	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:20:53.687146+00
774	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:21:38.371261+00
775	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:21:41.406649+00
776	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:22:11.436765+00
777	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:22:41.342277+00
778	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:23:11.490589+00
779	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:23:40.111096+00
780	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:24:11.438342+00
781	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:24:40.446165+00
782	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:25:11.619356+00
783	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:25:41.645058+00
784	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:26:11.673815+00
785	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:26:41.704954+00
786	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:27:11.097298+00
787	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:27:41.347686+00
788	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:28:11.601273+00
789	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:28:39.128599+00
790	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:29:10.870872+00
791	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:29:41.161784+00
792	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:30:11.432837+00
793	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:30:41.693297+00
794	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:31:11.158889+00
795	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:31:30.30531+00
796	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:31:53.865218+00
797	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:33:31.196333+00
798	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:33:31.911344+00
799	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:34:03.217011+00
800	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:34:16.192058+00
801	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:34:16.489345+00
802	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:34:46.519665+00
803	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:35:15.006015+00
804	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:35:45.261518+00
805	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:35:51.526198+00
806	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:35:51.803786+00
807	5	1	Write	{"ip": "::1", "path": "/files/5/events", "route": "POST /files/:id/events", "method": "POST", "stored": 14, "payload": {"remarks": "cloe", "to_user_id": 3, "action_type": "Dispatch", "attachments": []}}	2025-10-05 06:36:06.977276+00
808	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:36:06.991509+00
809	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:36:08.685175+00
810	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:36:09.73239+00
811	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:36:40.335898+00
812	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:37:10.342108+00
813	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:37:40.391019+00
814	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:38:10.420981+00
815	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:38:40.348479+00
816	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:39:07.878246+00
817	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:39:39.686212+00
818	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:40:08.255474+00
819	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:40:40.415867+00
820	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:41:10.622504+00
821	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:41:40.237598+00
822	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:42:10.51432+00
823	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:42:40.813858+00
824	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:43:11.605971+00
825	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:43:41.859048+00
826	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:44:13.538518+00
827	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:44:43.543848+00
828	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:45:13.568284+00
829	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:45:43.603663+00
830	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:46:12.559613+00
831	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:46:42.816066+00
832	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:47:13.595265+00
833	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:47:43.208669+00
834	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:48:13.77803+00
835	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:48:43.791507+00
836	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:49:13.8379+00
837	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:49:43.745978+00
838	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:50:11.277041+00
839	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:50:41.528755+00
840	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:51:11.778109+00
841	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:51:42.039108+00
842	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:52:13.928594+00
843	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:52:44.05666+00
844	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:53:14.089185+00
845	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:53:44.041487+00
846	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:54:12.697697+00
847	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:54:42.958478+00
848	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:55:13.231133+00
849	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:55:43.483644+00
850	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:56:14.270493+00
851	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:56:44.31692+00
852	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:57:14.35108+00
853	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:57:44.025649+00
854	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:58:14.287678+00
855	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:58:41.817022+00
856	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:59:12.07864+00
857	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 06:59:42.322357+00
858	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:00:14.086889+00
859	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:00:30.325432+00
860	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:00:32.749925+00
861	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:00:33.258378+00
862	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:00:33.391108+00
863	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:00:36.978409+00
864	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:00:37.295866+00
865	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:00:39.686118+00
866	6	1	Read	{"ip": "::1", "path": "/files/6/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 07:00:41.069423+00
867	6	1	Read	{"ip": "::1", "path": "/files/6/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 07:00:41.083534+00
868	6	1	Read	{"ip": "::1", "path": "/files/6/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 07:00:49.737277+00
869	5	1	Read	{"ip": "::1", "path": "/files/5/events", "count": 2, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 07:00:50.888756+00
870	5	1	Read	{"ip": "::1", "path": "/files/5/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 07:00:50.899112+00
871	5	1	Read	{"ip": "::1", "path": "/files/5/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 07:00:59.684937+00
872	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:01:01.694133+00
873	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:09:48.376758+00
874	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 2, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 07:09:49.246524+00
875	5	2	Read	{"ip": "::1", "path": "/files/5/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 07:09:49.264155+00
876	5	2	Read	{"ip": "::1", "path": "/files/5/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 07:09:52.074911+00
877	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:09:52.80388+00
878	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:10:03.641443+00
879	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:10:09.398253+00
880	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:11:46.206551+00
881	7	2	Write	{"ip": "::1", "path": "/files", "route": "POST /files", "method": "POST", "payload": {"remarks": "yeah", "subject": "file 2 ", "priority": "Routine", "attachments": [{"url": "/new.pdf"}], "category_id": 1, "save_as_draft": false, "sla_policy_id": 1, "date_initiated": "2025-10-05", "confidentiality": true, "notesheet_title": "file 2 ", "owning_office_id": 2, "forward_to_officer_id": 3, "date_received_accounts": "2025-10-06"}}	2025-10-05 07:12:52.027193+00
882	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:12:52.051263+00
883	7	2	Read	{"ip": "::1", "path": "/files/7/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 07:12:52.340273+00
884	7	2	Read	{"ip": "::1", "path": "/files/7/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 07:12:52.353219+00
885	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:12:56.767475+00
886	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:13:01.56058+00
887	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:13:02.782631+00
888	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:13:25.54004+00
889	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:25:03.584529+00
890	7	2	Read	{"ip": "::1", "path": "/files/7/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 07:25:04.599385+00
891	7	2	Read	{"ip": "::1", "path": "/files/7/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 07:25:04.611936+00
892	8	2	Write	{"ip": "::1", "path": "/files", "route": "POST /files", "method": "POST", "payload": {"remarks": "new", "subject": "something", "priority": "Urgent", "category_id": 1, "save_as_draft": true, "sla_policy_id": 2, "date_initiated": "2025-10-05", "confidentiality": true, "notesheet_title": "new", "owning_office_id": 1, "forward_to_officer_id": 3, "date_received_accounts": "2025-10-05"}}	2025-10-05 07:25:27.132158+00
893	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:25:27.156779+00
894	8	2	Read	{"ip": "::1", "path": "/files/8/events", "count": 0, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 07:25:27.442294+00
895	8	2	Read	{"ip": "::1", "path": "/files/8/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 07:25:27.45269+00
896	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:25:34.667119+00
897	8	2	Read	{"ip": "::1", "path": "/files/8/events", "count": 0, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 07:25:34.969147+00
898	8	2	Read	{"ip": "::1", "path": "/files/8/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 07:25:34.979771+00
899	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:25:35.216175+00
900	8	2	Read	{"ip": "::1", "path": "/files/8/events", "count": 0, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 07:25:35.508469+00
901	8	2	Read	{"ip": "::1", "path": "/files/8/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 07:25:35.516857+00
902	7	2	Read	{"ip": "::1", "path": "/files/7/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 07:25:48.070908+00
903	7	2	Read	{"ip": "::1", "path": "/files/7/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 07:25:48.081604+00
904	7	2	Read	{"ip": "::1", "path": "/files/7/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 07:25:51.749553+00
905	8	2	Read	{"ip": "::1", "path": "/files/8/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 07:25:52.789786+00
906	5	2	Read	{"ip": "::1", "path": "/files/5/events", "count": 2, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 07:26:09.269413+00
907	5	2	Read	{"ip": "::1", "path": "/files/5/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 07:26:09.279827+00
908	5	2	Read	{"ip": "::1", "path": "/files/5/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 07:26:17.561845+00
909	4	2	Read	{"ip": "::1", "path": "/files/4/events", "count": 0, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 07:26:18.17839+00
910	4	2	Read	{"ip": "::1", "path": "/files/4/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 07:26:18.187118+00
911	4	2	Read	{"ip": "::1", "path": "/files/4/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 07:26:18.551537+00
912	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:26:19.621979+00
913	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:26:20.428366+00
914	8	2	Read	{"ip": "::1", "path": "/files/8/events", "count": 0, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 07:26:21.329158+00
915	8	2	Read	{"ip": "::1", "path": "/files/8/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 07:26:21.339106+00
916	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:26:23.022024+00
917	9	2	Write	{"ip": "::1", "path": "/files", "route": "POST /files", "method": "POST", "payload": {"remarks": "ys", "subject": "urgent test", "priority": "Urgent", "category_id": 1, "save_as_draft": false, "sla_policy_id": 2, "date_initiated": "2025-10-05", "confidentiality": false, "notesheet_title": "urgent", "owning_office_id": 1, "forward_to_officer_id": 3, "date_received_accounts": "2025-10-05"}}	2025-10-05 07:26:40.280444+00
918	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:26:40.302374+00
919	9	2	Read	{"ip": "::1", "path": "/files/9/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 07:26:40.58891+00
920	9	2	Read	{"ip": "::1", "path": "/files/9/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 07:26:40.599216+00
921	9	2	Read	{"ip": "::1", "path": "/files/9/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 07:26:42.787602+00
922	8	2	Read	{"ip": "::1", "path": "/files/8/events", "count": 0, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 07:26:43.611558+00
923	8	2	Read	{"ip": "::1", "path": "/files/8/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 07:26:43.621889+00
924	9	2	Read	{"ip": "::1", "path": "/files/9/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 07:26:50.519419+00
925	9	2	Read	{"ip": "::1", "path": "/files/9/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 07:26:52.000277+00
926	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:26:59.137996+00
927	9	2	Read	{"ip": "::1", "path": "/files/9/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 07:27:00.024828+00
928	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:32:56.741817+00
929	9	2	Read	{"ip": "::1", "path": "/files/9/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 07:32:57.066595+00
930	9	2	Read	{"ip": "::1", "path": "/files/9/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 07:32:57.080988+00
931	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:33:24.23648+00
932	9	2	Read	{"ip": "::1", "path": "/files/9/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 07:33:24.52997+00
933	9	2	Read	{"ip": "::1", "path": "/files/9/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 07:33:24.543651+00
934	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:33:27.674172+00
935	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:38:49.319304+00
936	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:38:50.550242+00
937	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:38:53.015632+00
938	11	2	Write	{"ip": "::1", "path": "/files", "route": "POST /files", "method": "POST", "payload": {"remarks": "draft", "subject": "draft check", "priority": "Urgent", "category_id": 1, "save_as_draft": true, "sla_policy_id": 2, "date_initiated": "2025-10-05", "confidentiality": false, "notesheet_title": "draft", "owning_office_id": 1, "forward_to_officer_id": 3, "date_received_accounts": "2025-10-05"}}	2025-10-05 07:39:11.548216+00
939	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:39:11.578023+00
940	11	2	Read	{"ip": "::1", "path": "/files/11/events", "count": 0, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 07:39:11.868313+00
941	11	2	Read	{"ip": "::1", "path": "/files/11/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 07:39:11.884106+00
942	9	2	Read	{"ip": "::1", "path": "/files/9/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 07:39:17.825047+00
943	9	2	Read	{"ip": "::1", "path": "/files/9/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 07:39:17.838594+00
944	8	2	Read	{"ip": "::1", "path": "/files/8/events", "count": 0, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 07:39:20.848148+00
945	8	2	Read	{"ip": "::1", "path": "/files/8/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 07:39:20.860468+00
946	11	2	Read	{"ip": "::1", "path": "/files/11/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 07:39:32.56567+00
947	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:40:07.013133+00
948	11	2	Read	{"ip": "::1", "path": "/files/11/events", "count": 0, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 07:40:07.335648+00
949	11	2	Read	{"ip": "::1", "path": "/files/11/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 07:40:07.346534+00
950	11	2	Read	{"ip": "::1", "path": "/files/11/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 07:40:07.77744+00
951	11	2	Read	{"ip": "::1", "path": "/files/11/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 07:40:08.098312+00
952	11	2	Read	{"ip": "::1", "path": "/files/11/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 07:40:08.962295+00
953	11	2	Read	{"ip": "::1", "path": "/files/11/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 07:40:09.328484+00
954	11	2	Read	{"ip": "::1", "path": "/files/11/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 07:40:10.095382+00
955	11	2	Read	{"ip": "::1", "path": "/files/11/events", "count": 0, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 07:42:20.399325+00
956	11	2	Read	{"ip": "::1", "path": "/files/11/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 07:42:20.412131+00
957	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:42:21.777333+00
958	11	2	Read	{"ip": "::1", "path": "/files/11/events", "count": 0, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 07:42:22.09941+00
959	11	2	Read	{"ip": "::1", "path": "/files/11/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 07:42:22.110806+00
960	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:43:03.461003+00
961	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:44:45.861759+00
962	11	2	Read	{"ip": "::1", "path": "/files/11/events", "count": 0, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 07:44:46.617777+00
963	11	2	Read	{"ip": "::1", "path": "/files/11/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 07:44:46.632298+00
964	11	2	Write	{"ip": "::1", "path": "/files/11", "route": "PUT /files/:id", "method": "PUT", "submit": true}	2025-10-05 07:44:57.710939+00
965	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:44:57.731076+00
966	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:45:00.863169+00
967	11	2	Read	{"ip": "::1", "path": "/files/11/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 07:45:01.938525+00
968	11	2	Read	{"ip": "::1", "path": "/files/11/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 07:45:01.950515+00
969	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 07:45:24.17366+00
970	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:00:46.556643+00
971	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:00:47.259642+00
972	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:06:42.363843+00
973	\N	1	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "cof"}	2025-10-05 08:06:47.465348+00
974	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:06:47.495699+00
975	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:06:49.565429+00
976	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:07:40.645187+00
977	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:07:44.420345+00
978	\N	1	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "cof"}	2025-10-05 08:07:48.877647+00
979	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:07:48.903263+00
980	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:08:23.410664+00
981	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:08:24.390683+00
982	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:08:24.662949+00
983	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:08:26.253546+00
984	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:08:28.664374+00
985	\N	3	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "officer"}	2025-10-05 08:08:37.6449+00
986	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200&holder=3", "query": {"limit": 200, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:08:37.664762+00
987	\N	3	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&holder=3", "query": {"page": 1, "limit": 50, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:08:41.989048+00
988	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50&holder=3", "query": {"limit": 50, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:08:42.425306+00
989	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50&holder=3", "query": {"limit": 50, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:08:42.724499+00
990	\N	1	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "cof"}	2025-10-05 08:08:46.963183+00
991	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:08:46.988022+00
992	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:08:50.352808+00
993	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:15:31.840981+00
994	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:15:37.903624+00
995	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:15:43.520473+00
996	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:15:47.024121+00
997	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:15:49.875442+00
998	11	1	Read	{"ip": "::1", "path": "/files/11/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 08:17:48.378615+00
999	11	1	Read	{"ip": "::1", "path": "/files/11/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 08:17:48.393149+00
1000	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:17:49.041662+00
1001	11	1	Read	{"ip": "::1", "path": "/files/11/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 08:17:50.420452+00
1002	11	1	Read	{"ip": "::1", "path": "/files/11/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 08:17:50.432444+00
1003	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:17:51.071651+00
1004	11	1	Read	{"ip": "::1", "path": "/files/11/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 08:17:51.45277+00
1005	11	1	Read	{"ip": "::1", "path": "/files/11/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 08:17:51.462826+00
1006	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:17:52.009034+00
1007	11	1	Read	{"ip": "::1", "path": "/files/11/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 08:17:52.340066+00
1008	11	1	Read	{"ip": "::1", "path": "/files/11/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 08:17:52.350893+00
1009	11	1	Read	{"ip": "::1", "path": "/files/11/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 08:17:57.560357+00
1010	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:17:57.84576+00
1011	11	1	Read	{"ip": "::1", "path": "/files/11/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 08:18:00.102687+00
1012	11	1	Read	{"ip": "::1", "path": "/files/11/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 08:18:00.113548+00
1013	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:18:00.899529+00
1014	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:18:03.332481+00
1015	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:18:10.849974+00
1016	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:18:13.039408+00
1017	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:18:22.567564+00
1018	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:18:30.737764+00
1019	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:18:33.361358+00
1020	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:18:35.345534+00
1021	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:18:37.964989+00
1022	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:18:38.239268+00
1023	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:18:57.052236+00
1024	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:18:57.314206+00
1025	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:18:57.718952+00
1026	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:19:03.663184+00
1027	\N	3	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "officer"}	2025-10-05 08:24:06.280557+00
1028	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200&holder=3", "query": {"limit": 200, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:24:06.320463+00
1029	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50&holder=3", "query": {"limit": 50, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:24:08.516132+00
1030	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50&holder=3", "query": {"limit": 50, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:24:08.813068+00
1031	11	3	Write	{"ip": "::1", "path": "/files/11/events", "route": "POST /files/:id/events", "method": "POST", "stored": 18, "payload": {"remarks": "for closing", "to_user_id": 1, "action_type": "Escalate"}}	2025-10-05 08:24:20.390753+00
1032	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50&holder=3", "query": {"limit": 50, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:24:20.407859+00
1152	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:22:47.022683+00
1033	9	3	Write	{"ip": "::1", "path": "/files/9/events", "route": "POST /files/:id/events", "method": "POST", "stored": 19, "payload": {"remarks": "to close", "to_user_id": 1, "action_type": "Escalate"}}	2025-10-05 08:24:28.724182+00
1034	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50&holder=3", "query": {"limit": 50, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:24:28.73365+00
1035	7	3	Write	{"ip": "::1", "path": "/files/7/events", "route": "POST /files/:id/events", "method": "POST", "stored": 20, "payload": {"remarks": "CLOSE", "to_user_id": 1, "action_type": "Escalate"}}	2025-10-05 08:24:35.679528+00
1036	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50&holder=3", "query": {"limit": 50, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:24:35.68723+00
1037	\N	1	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "cof"}	2025-10-05 08:24:44.265839+00
1038	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:24:44.293288+00
1039	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:24:46.088818+00
1040	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:24:46.362089+00
1041	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:24:47.801972+00
1042	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:25:07.895726+00
1043	11	1	Read	{"ip": "::1", "path": "/files/11/events", "count": 3, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 08:25:08.785847+00
1044	11	1	Read	{"ip": "::1", "path": "/files/11/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 08:25:08.799161+00
1045	11	1	Read	{"ip": "::1", "path": "/files/11/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 08:25:10.730555+00
1046	6	1	Read	{"ip": "::1", "path": "/files/6/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 08:25:11.360638+00
1047	6	1	Read	{"ip": "::1", "path": "/files/6/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 08:25:11.371649+00
1048	6	1	Read	{"ip": "::1", "path": "/files/6/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 08:25:12.337677+00
1049	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:25:14.687252+00
1050	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:28:35.884841+00
1051	9	1	Read	{"ip": "::1", "path": "/files/9/events", "count": 2, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 08:28:36.207421+00
1052	9	1	Read	{"ip": "::1", "path": "/files/9/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 08:28:36.221198+00
1053	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:28:39.143241+00
1054	9	1	Read	{"ip": "::1", "path": "/files/9/events", "count": 3, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 08:28:39.459572+00
1055	9	1	Read	{"ip": "::1", "path": "/files/9/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 08:28:39.470872+00
1056	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:28:51.665035+00
1057	9	1	Read	{"ip": "::1", "path": "/files/9/events", "count": 3, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 08:28:51.979085+00
1058	9	1	Read	{"ip": "::1", "path": "/files/9/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 08:28:51.991151+00
1059	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:29:29.774672+00
1060	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:29:33.028809+00
1061	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:29:36.992676+00
1062	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:31:27.852496+00
1063	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:31:32.815461+00
1064	11	1	Read	{"ip": "::1", "path": "/files/11/events", "count": 4, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 08:31:33.898338+00
1065	11	1	Read	{"ip": "::1", "path": "/files/11/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 08:31:33.911827+00
1066	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:31:36.703045+00
1067	9	1	Read	{"ip": "::1", "path": "/files/9/events", "count": 3, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 08:31:37.863308+00
1068	9	1	Read	{"ip": "::1", "path": "/files/9/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 08:31:37.908907+00
1069	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:34:18.856099+00
1070	\N	3	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "officer"}	2025-10-05 08:34:36.293424+00
1071	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200&holder=3", "query": {"limit": 200, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:34:36.318592+00
1076	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50&holder=3", "query": {"limit": 50, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:34:46.135338+00
1077	3	3	Write	{"ip": "::1", "path": "/files/3/events", "route": "POST /files/:id/events", "method": "POST", "stored": 26, "payload": {"remarks": "some", "to_user_id": 1, "action_type": "Escalate"}}	2025-10-05 08:34:50.623597+00
1418	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:49:59.398515+00
1442	\N	4	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:50:22.131689+00
1443	12	4	Read	{"ip": "::1", "path": "/files/12/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 09:50:22.907698+00
1444	12	4	Read	{"ip": "::1", "path": "/files/12/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 09:50:22.91846+00
1445	12	4	Write	{"ip": "::1", "path": "/files/12/token", "route": "POST /files/:id/token", "method": "POST", "stable": true}	2025-10-05 09:50:23.874145+00
1446	12	4	Read	{"ip": "::1", "path": "/files/shared/12/5_f2-cBDxUr-2ykappoue7pwOQqhAwPk", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 09:50:25.709815+00
1447	12	4	Read	{"ip": "::1", "path": "/files/shared/12/5_f2-cBDxUr-2ykappoue7pwOQqhAwPk", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 09:50:25.71866+00
1451	\N	4	Read	{"q": "", "ip": "::1", "page": 1, "path": "/users?q=&limit=100", "limit": 100, "route": "GET /users", "method": "GET"}	2025-10-05 09:50:35.221989+00
1452	\N	4	Read	{"ip": "::1", "path": "/files?q=&limit=10&includeSla=false", "query": {"q": "", "limit": 10}, "route": "GET /files", "method": "GET"}	2025-10-05 09:50:36.169937+00
1461	\N	4	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:50:45.236417+00
1494	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 10:01:44.496838+00
1495	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 10:01:44.50427+00
1575	13	2	Write	{"ip": "::1", "path": "/files", "route": "POST /files", "method": "POST", "payload": {"remarks": "ssss", "subject": "sdfd", "priority": "Urgent", "category_id": 1, "save_as_draft": false, "sla_policy_id": 2, "date_initiated": "2025-10-05", "confidentiality": true, "notesheet_title": "sdofjddo", "owning_office_id": 1, "forward_to_officer_id": 3, "date_received_accounts": "2025-10-05"}}	2025-10-05 14:38:23.575529+00
1642	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:45:04.417332+00
1681	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 19:38:57.823789+00
1726	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:28:45.104337+00
1728	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:28:45.653037+00
1730	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:28:46.272258+00
1734	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:28:51.343102+00
1796	\N	2	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "clerk"}	2025-10-06 04:19:43.190976+00
1844	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:40:14.014787+00
1909	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:44:01.433563+00
2036	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:04.228533+00
2037	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:04.234866+00
2038	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:04.579654+00
2039	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:04.586934+00
2044	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:04.713939+00
2045	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:04.721044+00
2046	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:04.906207+00
2047	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:04.913813+00
2051	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:05.302963+00
2340	14	2	Read	{"ip": "::1", "path": "/files/14/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 05:06:27.297917+00
1072	\N	3	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&holder=3", "query": {"page": 1, "limit": 50, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:34:37.709096+00
1073	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50&holder=3", "query": {"limit": 50, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:34:39.227616+00
1074	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50&holder=3", "query": {"limit": 50, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:34:39.500983+00
1075	6	3	Write	{"ip": "::1", "path": "/files/6/events", "route": "POST /files/:id/events", "method": "POST", "stored": 25, "payload": {"remarks": "some", "to_user_id": 1, "action_type": "Escalate"}}	2025-10-05 08:34:46.12787+00
1078	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50&holder=3", "query": {"limit": 50, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:34:50.630129+00
1079	2	3	Write	{"ip": "::1", "path": "/files/2/events", "route": "POST /files/:id/events", "method": "POST", "stored": 27, "payload": {"remarks": "som", "to_user_id": 1, "action_type": "Escalate"}}	2025-10-05 08:34:57.718023+00
1080	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50&holder=3", "query": {"limit": 50, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:34:57.724699+00
1081	\N	1	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "cof"}	2025-10-05 08:35:09.068925+00
1082	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:35:09.097101+00
1083	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:35:11.195124+00
1084	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:37:19.84761+00
1085	6	1	Read	{"ip": "::1", "path": "/files/6/events", "count": 3, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 08:37:20.136928+00
1086	6	1	Read	{"ip": "::1", "path": "/files/6/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 08:37:20.151068+00
1087	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:37:33.892136+00
1088	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:37:34.156531+00
1089	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:37:50.983745+00
1090	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:38:42.905166+00
1091	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:39:55.7464+00
1092	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:39:56.192252+00
1093	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:39:57.03446+00
1094	11	1	Read	{"ip": "::1", "path": "/files/11/events", "count": 4, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 08:39:57.355284+00
1095	11	1	Read	{"ip": "::1", "path": "/files/11/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 08:39:57.368812+00
1096	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 08:39:59.470497+00
1097	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:04:10.00017+00
1098	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:04:34.945215+00
1099	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:04:49.205425+00
1100	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:05:03.469563+00
1101	\N	3	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "officer"}	2025-10-05 09:05:14.109914+00
1102	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200&holder=3", "query": {"limit": 200, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:05:14.137918+00
1103	\N	3	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&holder=3", "query": {"page": 1, "limit": 50, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:05:15.618817+00
1104	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50&holder=3", "query": {"limit": 50, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:05:22.67283+00
1105	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50&holder=3", "query": {"limit": 50, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:05:22.946729+00
1106	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200&holder=3", "query": {"limit": 200, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:05:24.567027+00
1107	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200&holder=3", "query": {"limit": 200, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:06:09.943263+00
1108	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200&holder=3", "query": {"limit": 200, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:07:52.222988+00
1110	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200&holder=3", "query": {"limit": 200, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:07:56.811539+00
1113	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200&holder=3", "query": {"limit": 200, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:08:06.254666+00
1114	1	3	Write	{"ip": "::1", "path": "/files/1/sla/reason", "route": "POST /files/:id/sla/reason", "method": "POST"}	2025-10-05 09:08:10.045338+00
1116	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200&holder=3", "query": {"limit": 200, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:08:11.585184+00
1118	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50&holder=3", "query": {"limit": 50, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:08:15.728901+00
1120	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200&holder=3", "query": {"limit": 200, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:08:18.996342+00
1421	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:49:59.413304+00
1430	\N	4	Read	{"q": "", "ip": "::1", "page": 1, "path": "/users?q=&limit=100", "limit": 100, "route": "GET /users", "method": "GET"}	2025-10-05 09:50:10.201412+00
1496	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 10:01:44.511411+00
1576	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:38:23.611839+00
1577	13	2	Read	{"ip": "::1", "path": "/files/13/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 14:38:23.901294+00
1578	13	2	Read	{"ip": "::1", "path": "/files/13/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 14:38:23.915234+00
1643	\N	4	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "admin"}	2025-10-05 14:46:01.123342+00
1682	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 19:38:58.126338+00
1683	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 19:38:59.158641+00
1733	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:28:51.209078+00
1797	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:19:43.233073+00
1845	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:40:14.642924+00
1910	\N	1	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "cof"}	2025-10-06 04:44:12.631788+00
2041	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:04.594187+00
2042	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:04.706026+00
2043	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:04.713486+00
2048	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:04.914221+00
2049	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:04.920993+00
2050	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:05.294543+00
2052	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:05.303448+00
2053	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:05.312173+00
2054	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:05.518658+00
2055	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:05.528095+00
2060	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:05.778783+00
2061	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:05.784955+00
2062	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:06.225092+00
2063	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:06.233489+00
2068	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:06.412922+00
2069	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:06.419651+00
2070	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:06.554082+00
2071	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:06.562433+00
1111	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200&holder=3", "query": {"limit": 200, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:07:58.720466+00
1112	5	3	Write	{"ip": "::1", "path": "/files/5/sla/reason", "route": "POST /files/:id/sla/reason", "method": "POST"}	2025-10-05 09:08:06.248431+00
1115	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200&holder=3", "query": {"limit": 200, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:08:10.051709+00
1117	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50&holder=3", "query": {"limit": 50, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:08:15.422263+00
1119	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200&holder=3", "query": {"limit": 200, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:08:17.548533+00
1121	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200&holder=3", "query": {"limit": 200, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:08:19.413621+00
1122	\N	1	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "cof"}	2025-10-05 09:08:58.872506+00
1123	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:08:58.903151+00
1124	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:09:00.333758+00
1125	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:10:42.956346+00
1126	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:11:32.466236+00
1127	\N	3	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "officer"}	2025-10-05 09:11:39.386872+00
1128	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200&holder=3", "query": {"limit": 200, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:11:39.401551+00
1129	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200&holder=3", "query": {"limit": 200, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:11:40.821538+00
1130	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:11:46.236844+00
1131	8	3	Write	{"ip": "::1", "path": "/files/8/sla/reason", "route": "POST /files/:id/sla/reason", "method": "POST"}	2025-10-05 09:11:53.856193+00
1132	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:11:53.865164+00
1133	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200&holder=3", "query": {"limit": 200, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:12:00.243641+00
1134	\N	1	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "cof"}	2025-10-05 09:12:11.334894+00
1135	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:12:11.363775+00
1136	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:12:17.260291+00
1137	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:12:17.559378+00
1138	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:12:18.435578+00
1139	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:12:23.746343+00
1140	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:22:46.910084+00
1141	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:22:46.910899+00
1142	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:22:46.951271+00
1143	\N	1	Read	{"path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:22:46.952283+00
1144	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:22:46.963776+00
1145	\N	1	Read	{"path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:22:46.974638+00
1146	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:22:46.985313+00
1147	\N	1	Read	{"path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:22:46.985857+00
1148	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:22:46.988921+00
1149	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:22:46.990509+00
1150	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:22:47.000298+00
1151	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:22:47.011546+00
1153	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:22:47.484128+00
1160	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:22:47.552134+00
1172	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:22:56.920031+00
1180	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:22:56.941275+00
1191	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:23:07.942471+00
1195	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:23:07.951567+00
1425	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:50:07.116072+00
1498	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 10:01:51.076314+00
1579	13	2	Write	{"ip": "::1", "path": "/files/13/token", "route": "POST /files/:id/token", "method": "POST", "stable": true}	2025-10-05 14:38:39.534982+00
1580	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 14:38:48.173863+00
1581	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 14:38:48.183624+00
1644	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:46:01.159845+00
1645	\N	4	Read	{"ip": "::1", "path": "/files?q=&limit=10&includeSla=false", "query": {"q": "", "limit": 10}, "route": "GET /files", "method": "GET"}	2025-10-05 14:46:07.308679+00
1685	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 19:39:36.901514+00
1735	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:29:16.4267+00
1737	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:29:26.663165+00
1798	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:24:45.334755+00
1846	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:40:15.067402+00
1847	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:40:15.998846+00
1911	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:44:12.662079+00
2056	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:05.528532+00
2057	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:05.534993+00
2058	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:05.770428+00
2059	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:05.778357+00
2064	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:06.233929+00
2065	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:06.240158+00
2066	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:06.404618+00
2067	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:06.41254+00
2072	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:06.562649+00
2073	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:06.56979+00
2074	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:06.743867+00
2075	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:06.752047+00
2080	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:06.966062+00
2081	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:06.973682+00
2082	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:07.253106+00
2083	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:07.26064+00
1154	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:22:47.48974+00
1165	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:22:47.571545+00
1171	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:22:48.59274+00
1184	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:22:56.955695+00
1189	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:22:56.986463+00
1441	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:50:19.239438+00
1502	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 10:01:51.094239+00
1505	\N	4	Read	{"q": "", "ip": "::1", "page": 1, "path": "/users?q=&limit=100", "limit": 100, "route": "GET /users", "method": "GET"}	2025-10-05 10:01:51.68645+00
1507	\N	4	Read	{"q": "", "ip": "::1", "page": 1, "path": "/users?q=&limit=100", "limit": 100, "route": "GET /users", "method": "GET"}	2025-10-05 10:01:53.881285+00
1508	\N	4	Read	{"q": "a", "ip": "::1", "page": 1, "path": "/users?q=a&limit=100", "limit": 100, "route": "GET /users", "method": "GET"}	2025-10-05 10:01:59.251831+00
1509	\N	4	Read	{"q": "ad", "ip": "::1", "page": 1, "path": "/users?q=ad&limit=100", "limit": 100, "route": "GET /users", "method": "GET"}	2025-10-05 10:01:59.378398+00
1510	\N	4	Read	{"q": "adm", "ip": "::1", "page": 1, "path": "/users?q=adm&limit=100", "limit": 100, "route": "GET /users", "method": "GET"}	2025-10-05 10:01:59.609315+00
1511	\N	4	Read	{"q": "admi", "ip": "::1", "page": 1, "path": "/users?q=admi&limit=100", "limit": 100, "route": "GET /users", "method": "GET"}	2025-10-05 10:01:59.845301+00
1512	\N	4	Read	{"q": "admin", "ip": "::1", "page": 1, "path": "/users?q=admin&limit=100", "limit": 100, "route": "GET /users", "method": "GET"}	2025-10-05 10:01:59.921291+00
1513	\N	4	Read	{"q": "", "ip": "::1", "page": 1, "path": "/users?q=&limit=100", "limit": 100, "route": "GET /users", "method": "GET"}	2025-10-05 10:02:03.460002+00
1582	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 14:38:48.189346+00
1583	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 14:38:48.196427+00
1584	13	2	Read	{"ip": "::1", "path": "/files/13/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 14:38:54.035377+00
1585	13	2	Read	{"ip": "::1", "path": "/files/13/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 14:38:54.974626+00
1646	\N	4	Read	{"q": "", "ip": "::1", "page": 1, "path": "/users?q=&limit=100", "limit": 100, "route": "GET /users", "method": "GET"}	2025-10-05 14:46:07.308782+00
1686	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 19:39:50.977049+00
1736	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:29:23.16848+00
1799	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:24:57.438933+00
1800	13	2	Read	{"ip": "::1", "path": "/files/13/events", "count": 3, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 04:24:58.580509+00
1801	13	2	Read	{"ip": "::1", "path": "/files/13/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 04:24:58.593069+00
1802	13	2	Read	{"ip": "::1", "path": "/files/13/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 04:25:01.474663+00
1803	\N	2	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "clerk"}	2025-10-06 04:25:07.351171+00
1848	\N	4	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:40:20.644523+00
1849	12	4	Read	{"ip": "::1", "path": "/files/12/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 04:40:20.922307+00
1850	12	4	Read	{"ip": "::1", "path": "/files/12/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 04:40:20.933982+00
1912	\N	2	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "clerk"}	2025-10-06 04:44:27.702697+00
2076	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:06.752453+00
2077	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:06.759171+00
2078	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:06.956264+00
2079	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:06.964707+00
2084	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:07.261816+00
2085	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:07.267815+00
2086	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:07.547178+00
1155	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:22:47.490623+00
1157	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:22:47.519428+00
1162	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:22:47.559749+00
1167	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:22:47.588514+00
1173	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:22:56.921444+00
1454	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:50:37.603802+00
1514	\N	4	Read	{"q": "", "ip": "::1", "page": 1, "path": "/users?q=&limit=100", "limit": 100, "route": "GET /users", "method": "GET"}	2025-10-05 14:05:04.97681+00
1515	\N	4	Read	{"ip": "::1", "path": "/files?q=&limit=10&includeSla=false", "query": {"q": "", "limit": 10}, "route": "GET /files", "method": "GET"}	2025-10-05 14:05:04.977178+00
1586	13	2	Read	{"ip": "::1", "path": "/files/13/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 14:39:36.964221+00
1647	\N	4	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:46:29.914954+00
1687	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 19:39:51.242238+00
1738	\N	4	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "admin"}	2025-10-05 20:29:45.245118+00
1804	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:25:07.373052+00
1851	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:40:25.759582+00
1913	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:44:27.731116+00
2087	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:07.554995+00
2092	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:07.891474+00
2093	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:07.898444+00
2094	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:08.200888+00
2095	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:08.210566+00
2100	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:08.448945+00
2101	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:08.457004+00
2102	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:08.600457+00
2103	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:08.609828+00
2108	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:09.010517+00
2109	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:09.017034+00
2110	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:09.371638+00
2111	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:09.379777+00
2116	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:09.577149+00
2117	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:09.583649+00
2118	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:09.797343+00
2119	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:09.804514+00
2124	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:10.045691+00
2125	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:10.05297+00
2242	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:59:29.048605+00
2299	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:02:45.93501+00
1156	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:22:47.502926+00
1158	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:22:47.530722+00
1159	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:22:47.546465+00
1163	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:22:47.563922+00
1175	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:22:56.927533+00
1178	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:22:56.936127+00
1181	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:22:56.941585+00
1185	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:22:56.956441+00
1187	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:22:56.971437+00
1190	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:23:07.942314+00
1196	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:23:07.954384+00
1198	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:23:07.969112+00
1455	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:50:40.126761+00
1464	\N	4	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:50:46.475468+00
1516	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:05:10.086515+00
1587	\N	2	Read	{"ip": "::1", "path": "/files?q=&status=WithOfficer&office=&page=1&limit=50&sort_dir=asc&includeSla=true&creator=2", "query": {"q": "", "page": 1, "limit": 50, "status": "WithOfficer", "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:39:38.704097+00
1588	13	2	Read	{"ip": "::1", "path": "/files/13/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 14:39:38.995998+00
1648	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:46:39.026099+00
1688	\N	2	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "clerk"}	2025-10-05 19:55:13.071605+00
1739	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:29:45.276459+00
1805	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:25:37.655461+00
1852	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:40:27.133628+00
1914	\N	3	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "officer"}	2025-10-06 04:47:15.345097+00
2088	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:07.555428+00
2089	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:07.561967+00
2090	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:07.882569+00
2091	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:07.891377+00
2096	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:08.210981+00
2097	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:08.217471+00
2098	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:08.441065+00
2099	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:08.44848+00
2104	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:08.610247+00
2105	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:08.617114+00
2106	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:09.002121+00
2107	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:09.010284+00
2300	14	2	Read	{"ip": "::1", "path": "/files/14/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 05:02:46.922417+00
1161	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:22:47.552868+00
1164	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:22:47.564839+00
1166	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:22:47.579406+00
1168	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:22:47.598118+00
1170	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:22:47.615003+00
1174	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:22:56.927335+00
1176	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:22:56.92906+00
1183	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:22:56.94878+00
1186	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:22:56.962741+00
1193	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:23:07.94527+00
1194	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:23:07.946979+00
1197	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:23:07.961488+00
1456	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:50:40.130567+00
1517	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:05:23.770556+00
1589	\N	2	Read	{"ip": "::1", "path": "/files?q=&status=&office=&page=1&limit=50&sort_dir=asc&includeSla=true&creator=2", "query": {"q": "", "page": 1, "limit": 50, "status": "", "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:39:39.863249+00
1590	13	2	Read	{"ip": "::1", "path": "/files/13/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 14:39:40.154795+00
1596	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:39:51.468517+00
1649	\N	4	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:47:00.14412+00
1689	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 19:55:13.11417+00
1691	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 19:55:19.820185+00
1740	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:30:32.716044+00
1806	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:25:53.735822+00
1853	\N	2	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "clerk"}	2025-10-06 04:40:50.94584+00
1862	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:40:57.516981+00
1915	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200&holder=3", "query": {"limit": 200, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:47:15.375855+00
2112	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:09.380033+00
2113	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:09.3862+00
2114	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:09.567388+00
2115	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:09.576627+00
2120	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:09.804924+00
2121	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:09.811228+00
2122	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:10.036938+00
2123	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:10.045246+00
2243	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:59:34.70233+00
1169	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:22:47.607455+00
1458	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:50:40.138117+00
1518	\N	4	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:05:38.383105+00
1519	4	4	Read	{"ip": "::1", "path": "/files/4/events", "count": 0, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 14:05:38.694122+00
1520	4	4	Read	{"ip": "::1", "path": "/files/4/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 14:05:38.719284+00
1521	12	4	Read	{"ip": "::1", "path": "/files/12/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 14:05:40.777466+00
1522	12	4	Read	{"ip": "::1", "path": "/files/12/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 14:05:40.78722+00
1591	\N	2	Read	{"ip": "::1", "path": "/files?q=&status=WithCOF&office=&page=1&limit=50&sort_dir=asc&includeSla=true&creator=2", "query": {"q": "", "page": 1, "limit": 50, "status": "WithCOF", "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:39:41.347025+00
1650	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:47:00.54622+00
1690	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 19:55:17.855881+00
1741	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:30:52.380416+00
1743	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:30:52.919247+00
1807	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:26:24.064341+00
1854	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:40:50.978231+00
1916	\N	2	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "clerk"}	2025-10-06 04:47:52.340696+00
2126	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:55:11.291894+00
2127	13	2	Read	{"ip": "::1", "path": "/files/13/events", "count": 3, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 04:55:12.163752+00
2128	13	2	Read	{"ip": "::1", "path": "/files/13/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 04:55:12.174356+00
2244	\N	2	Read	{"ip": "::1", "path": "/files?q=test++sl&date_from=2025-08-07T04:58:41.914Z&limit=8&includeSla=false", "query": {"q": "test  sl", "limit": 8, "date_from": "2025-08-07T04:58:41.914Z"}, "route": "GET /files", "method": "GET"}	2025-10-06 04:59:41.634589+00
2245	\N	2	Read	{"ip": "::1", "path": "/files?q=test++sla&date_from=2025-08-07T04:58:43.516Z&limit=8&includeSla=false", "query": {"q": "test  sla", "limit": 8, "date_from": "2025-08-07T04:58:43.516Z"}, "route": "GET /files", "method": "GET"}	2025-10-06 04:59:43.098058+00
2301	14	2	Read	{"ip": "::1", "path": "/files/14/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 05:02:46.934681+00
2341	14	2	Read	{"ip": "::1", "path": "/files/14/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 05:06:27.688967+00
2342	14	2	Read	{"ip": "::1", "path": "/files/14/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 05:06:27.995332+00
2343	14	2	Read	{"ip": "::1", "path": "/files/14/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 05:06:28.881548+00
2344	13	2	Read	{"ip": "::1", "path": "/files/13/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 05:06:29.3323+00
2365	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:07:53.415261+00
2366	14	2	Read	{"ip": "::1", "path": "/files/14/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 05:07:54.240992+00
2367	14	2	Read	{"ip": "::1", "path": "/files/14/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 05:07:54.250841+00
2384	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:19:00.936425+00
2394	\N	2	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "clerk"}	2025-10-06 06:17:30.30672+00
2404	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:29:32.09278+00
2405	\N	1	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "cof"}	2025-10-06 06:29:38.202559+00
2418	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:32:52.818812+00
2422	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:35:04.232525+00
2424	16	1	Write	{"ip": "::1", "path": "/files", "route": "POST /files", "method": "POST", "payload": {"remarks": "remarks", "subject": "ss", "priority": "Urgent", "category_id": 1, "save_as_draft": false, "sla_policy_id": 2, "date_initiated": "2025-10-06", "confidentiality": true, "notesheet_title": "sss", "owning_office_id": 1, "forward_to_officer_id": 3, "date_received_accounts": "2025-10-06"}}	2025-10-06 06:36:00.578645+00
1177	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:22:56.929123+00
1179	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:22:56.937492+00
1182	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:22:56.946133+00
1188	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:22:56.978606+00
1192	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:23:07.942553+00
1199	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:24:34.927016+00
1200	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:24:34.937583+00
1201	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:24:34.943336+00
1202	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:24:34.9514+00
1203	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:24:34.958482+00
1204	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:24:34.965074+00
1205	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:24:38.876337+00
1206	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:24:38.880896+00
1207	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:24:38.881848+00
1208	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:24:38.888297+00
1209	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:24:38.895945+00
1210	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:24:38.903522+00
1211	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:25:05.88468+00
1212	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:25:05.891344+00
1213	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:25:05.893653+00
1214	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:25:05.893844+00
1215	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:25:05.894017+00
1216	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:25:05.903142+00
1217	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:25:05.903759+00
1218	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:25:05.911432+00
1219	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:25:05.918592+00
1220	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:25:47.598247+00
1221	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:25:47.607498+00
1222	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:25:47.607661+00
1223	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:25:47.61298+00
1224	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:25:47.61315+00
1225	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:25:47.613015+00
1226	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:25:47.620849+00
1227	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:25:47.624573+00
1228	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:25:47.624716+00
1229	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:25:47.625467+00
1230	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:25:47.633477+00
1231	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:25:47.633785+00
1233	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:25:47.643032+00
1235	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:25:47.656345+00
1459	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:50:40.146011+00
1523	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:05:41.841314+00
1592	\N	2	Read	{"ip": "::1", "path": "/files?q=&status=&office=&page=1&limit=50&sort_dir=asc&includeSla=true&creator=2", "query": {"q": "", "page": 1, "limit": 50, "status": "", "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:39:42.580605+00
1593	13	2	Read	{"ip": "::1", "path": "/files/13/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 14:39:42.85787+00
1594	13	2	Read	{"ip": "::1", "path": "/files/13/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 14:39:44.916744+00
1595	\N	2	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "clerk"}	2025-10-05 14:39:51.451612+00
1597	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:39:52.645211+00
1598	13	2	Read	{"ip": "::1", "path": "/files/13/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 14:39:53.398697+00
1599	13	2	Read	{"ip": "::1", "path": "/files/13/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 14:39:53.409074+00
1651	\N	4	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:47:13.136589+00
1692	\N	2	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "clerk"}	2025-10-05 20:04:47.682377+00
1742	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:30:52.650392+00
1808	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:26:56.065588+00
1855	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:40:53.872972+00
1856	13	2	Read	{"ip": "::1", "path": "/files/13/events", "count": 3, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 04:40:55.140078+00
1857	13	2	Read	{"ip": "::1", "path": "/files/13/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 04:40:55.150516+00
1858	13	2	Read	{"ip": "::1", "path": "/files/13/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 04:40:55.706679+00
1859	8	2	Read	{"ip": "::1", "path": "/files/8/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 04:40:56.129708+00
1860	8	2	Read	{"ip": "::1", "path": "/files/8/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 04:40:56.140731+00
1861	8	2	Read	{"ip": "::1", "path": "/files/8/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 04:40:56.676402+00
1917	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:47:52.372052+00
2129	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:55:34.346925+00
2246	14	2	Write	{"ip": "::1", "path": "/files", "route": "POST /files", "method": "POST", "payload": {"remarks": "sla test", "subject": "test  sla", "priority": "Urgent", "category_id": 1, "save_as_draft": false, "sla_policy_id": 2, "date_initiated": "2025-10-06", "confidentiality": false, "notesheet_title": "test sla", "owning_office_id": 1, "forward_to_officer_id": 3, "date_received_accounts": "2025-10-05"}}	2025-10-06 04:59:53.494036+00
2302	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:02:58.242296+00
2305	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:02:59.058346+00
2306	14	2	Read	{"ip": "::1", "path": "/files/14/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 05:03:00.027701+00
2307	14	2	Read	{"ip": "::1", "path": "/files/14/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 05:03:00.039056+00
2345	14	2	Read	{"ip": "::1", "path": "/files/14/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 05:06:47.869316+00
2369	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:08:27.714723+00
2385	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:24:50.032101+00
1232	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:25:47.642965+00
1460	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:50:40.153504+00
1524	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:06:12.132275+00
1600	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:40:58.883128+00
1601	13	2	Read	{"ip": "::1", "path": "/files/13/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 14:40:59.356823+00
1602	13	2	Read	{"ip": "::1", "path": "/files/13/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 14:40:59.371709+00
1652	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 14:47:15.108708+00
1655	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:47:15.122756+00
1693	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:04:47.731421+00
1744	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:30:55.13397+00
1809	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:27:25.902411+00
1863	\N	3	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "officer"}	2025-10-06 04:41:32.287026+00
1918	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:47:53.369544+00
1919	\N	3	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "officer"}	2025-10-06 04:48:03.851035+00
2130	\N	2	Read	{"ip": "::1", "path": "/files?q=&status=&office=&page=1&limit=50&sort_by=owning_office&sort_dir=desc&includeSla=true&creator=2", "query": {"q": "", "page": 1, "limit": 50, "status": "", "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:55:35.880226+00
2131	13	2	Read	{"ip": "::1", "path": "/files/13/events", "count": 3, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 04:55:36.230098+00
2132	13	2	Read	{"ip": "::1", "path": "/files/13/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 04:55:36.241816+00
2133	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:37.098266+00
2134	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:37.106767+00
2247	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:59:53.521893+00
2248	14	2	Read	{"ip": "::1", "path": "/files/14/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 04:59:53.806504+00
2249	14	2	Read	{"ip": "::1", "path": "/files/14/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 04:59:53.817574+00
2303	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:02:58.614204+00
2346	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:06:50.035977+00
2370	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:08:57.968058+00
2386	15	2	Read	{"ip": "::1", "path": "/files/15/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 05:24:51.047896+00
2387	15	2	Read	{"ip": "::1", "path": "/files/15/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 05:24:51.059999+00
2388	15	2	Read	{"ip": "::1", "path": "/files/15/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 05:24:55.930749+00
2395	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:17:30.399814+00
2396	\N	2	Read	{"ip": "::1", "path": "/files?q=fff&date_from=2025-08-07T06:16:44.240Z&limit=8&includeSla=false", "query": {"q": "fff", "limit": 8, "date_from": "2025-08-07T06:16:44.240Z"}, "route": "GET /files", "method": "GET"}	2025-10-06 06:17:44.063816+00
2407	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:29:49.168432+00
2408	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:29:49.402831+00
2419	\N	1	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "cof"}	2025-10-06 06:34:03.994994+00
2423	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:35:34.474942+00
2425	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:36:00.68261+00
2426	16	1	Read	{"ip": "::1", "path": "/files/16/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 06:36:00.994275+00
1234	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:25:47.649783+00
1236	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:25:47.662693+00
1463	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:50:46.277259+00
1525	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:06:42.403576+00
1603	\N	3	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "officer"}	2025-10-05 14:41:15.479037+00
1607	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50&holder=3", "query": {"limit": 50, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:41:31.875462+00
1653	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:47:15.112454+00
1657	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:47:15.141953+00
1694	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:05:17.936664+00
1745	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:31:30.555904+00
1810	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:27:56.206032+00
1864	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200&holder=3", "query": {"limit": 200, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:41:32.313623+00
1867	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:41:36.851463+00
1920	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200&holder=3", "query": {"limit": 200, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:48:03.866083+00
1921	\N	4	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "admin"}	2025-10-06 04:48:19.114938+00
2135	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:37.109256+00
2136	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:37.115646+00
2137	13	2	Write	{"ip": "::1", "path": "/files/13/token?force=true", "route": "POST /files/:id/token", "method": "POST", "stable": true}	2025-10-06 04:55:39.393455+00
2250	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:59:55.929786+00
2251	14	2	Read	{"ip": "::1", "path": "/files/14/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 04:59:56.231501+00
2252	14	2	Read	{"ip": "::1", "path": "/files/14/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 04:59:56.240135+00
2253	14	2	Read	{"ip": "::1", "path": "/files/14/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 04:59:56.552796+00
2254	14	2	Read	{"ip": "::1", "path": "/files/14/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 04:59:56.890443+00
2304	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:02:58.906405+00
2347	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:06:50.387849+00
2348	14	2	Read	{"ip": "::1", "path": "/files/14/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 05:06:51.312354+00
2349	14	2	Read	{"ip": "::1", "path": "/files/14/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 05:06:51.323652+00
2350	14	2	Read	{"ip": "::1", "path": "/files/14/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 05:06:55.88295+00
2351	13	2	Read	{"ip": "::1", "path": "/files/13/events", "count": 3, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 05:06:56.476476+00
2352	13	2	Read	{"ip": "::1", "path": "/files/13/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 05:06:56.488093+00
2353	14	2	Read	{"ip": "::1", "path": "/files/14/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 05:06:58.428794+00
2371	\N	2	Read	{"ip": "::1", "path": "/files?q=serv&date_from=2025-08-07T05:08:27.920Z&limit=8&includeSla=false", "query": {"q": "serv", "limit": 8, "date_from": "2025-08-07T05:08:27.920Z"}, "route": "GET /files", "method": "GET"}	2025-10-06 05:09:27.826007+00
2372	\N	2	Read	{"ip": "::1", "path": "/files?q=some&date_from=2025-08-07T05:08:29.145Z&limit=8&includeSla=false", "query": {"q": "some", "limit": 8, "date_from": "2025-08-07T05:08:29.145Z"}, "route": "GET /files", "method": "GET"}	2025-10-06 05:09:29.048812+00
2373	\N	2	Read	{"ip": "::1", "path": "/files?q=some+i&date_from=2025-08-07T05:08:30.281Z&limit=8&includeSla=false", "query": {"q": "some i", "limit": 8, "date_from": "2025-08-07T05:08:30.281Z"}, "route": "GET /files", "method": "GET"}	2025-10-06 05:09:30.185447+00
2374	\N	2	Read	{"ip": "::1", "path": "/files?q=draf&date_from=2025-08-07T05:08:31.725Z&limit=8&includeSla=false", "query": {"q": "draf", "limit": 8, "date_from": "2025-08-07T05:08:31.725Z"}, "route": "GET /files", "method": "GET"}	2025-10-06 05:09:31.626322+00
2409	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:29:50.389676+00
1237	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:25:47.669154+00
1238	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:26:34.305683+00
1239	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:26:34.319994+00
1240	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:26:34.330013+00
1241	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:26:34.3369+00
1242	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:26:34.341909+00
1243	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:26:34.343377+00
1244	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:26:34.346095+00
1245	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:26:34.349316+00
1246	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:26:34.352172+00
1247	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:26:35.10318+00
1248	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:26:35.105534+00
1249	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:26:35.1454+00
1250	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:26:35.14935+00
1251	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:26:35.155409+00
1252	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:26:35.201151+00
1253	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:26:40.779175+00
1254	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:26:40.78226+00
1255	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:26:40.784025+00
1256	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:26:40.790103+00
1257	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:26:40.79609+00
1258	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:26:40.801668+00
1259	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:26:42.244343+00
1260	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:26:47.731378+00
1261	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:26:47.733204+00
1262	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:26:47.736347+00
1263	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:26:47.740575+00
1264	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:26:47.748235+00
1265	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:26:47.753877+00
1266	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:27:35.260344+00
1267	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:27:35.263595+00
1268	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:27:35.273002+00
1269	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:27:35.275467+00
1270	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:27:35.277746+00
1272	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:27:35.279696+00
1271	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:27:35.279761+00
1273	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:27:35.287132+00
1274	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:27:35.289379+00
1275	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:27:35.290344+00
1282	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:27:35.334839+00
1287	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:27:37.530716+00
1291	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:27:40.743695+00
1292	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:27:42.344973+00
1465	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:51:47.468128+00
1526	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:07:05.661405+00
1604	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200&holder=3", "query": {"limit": 200, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:41:15.506834+00
1606	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50&holder=3", "query": {"limit": 50, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:41:31.585443+00
1654	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 14:47:15.115217+00
1695	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:05:18.185136+00
1746	\N	2	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "clerk"}	2025-10-05 20:31:40.751732+00
1811	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:28:24.656787+00
1865	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:41:34.987377+00
1922	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:48:19.143484+00
2138	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:45.322672+00
2139	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:45.330745+00
2255	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:00:18.416186+00
2256	14	2	Read	{"ip": "::1", "path": "/files/14/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 05:00:18.705043+00
2257	14	2	Read	{"ip": "::1", "path": "/files/14/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 05:00:18.716074+00
2267	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:00:21.596763+00
2268	14	2	Read	{"ip": "::1", "path": "/files/14/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 05:00:21.890439+00
2269	14	2	Read	{"ip": "::1", "path": "/files/14/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 05:00:21.89958+00
2273	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:00:33.040736+00
2274	14	2	Read	{"ip": "::1", "path": "/files/14/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 05:00:33.338858+00
2275	14	2	Read	{"ip": "::1", "path": "/files/14/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 05:00:33.348533+00
2308	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:05:39.596414+00
2354	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:07:04.595636+00
2375	\N	2	Read	{"ip": "::1", "path": "/files?q=draft+file&date_from=2025-08-07T05:08:32.660Z&limit=8&includeSla=false", "query": {"q": "draft file", "limit": 8, "date_from": "2025-08-07T05:08:32.660Z"}, "route": "GET /files", "method": "GET"}	2025-10-06 05:09:32.56234+00
2389	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:27:10.449779+00
2397	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:18:12.42917+00
1276	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:27:35.30058+00
1277	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:27:35.300725+00
1286	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:27:37.526909+00
1293	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:27:42.983035+00
1297	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:27:59.820736+00
1466	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:54:54.558127+00
1527	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:07:05.941991+00
1605	\N	3	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&holder=3", "query": {"page": 1, "limit": 50, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:41:22.011984+00
1656	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:47:15.133964+00
1696	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:05:18.991166+00
1747	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:31:40.77981+00
1812	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:28:56.3522+00
1866	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200&holder=3", "query": {"limit": 200, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:41:36.520672+00
1923	\N	2	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "clerk"}	2025-10-06 04:50:25.669014+00
2140	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:45.333765+00
2141	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:45.339911+00
2142	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:47.545421+00
2143	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:47.552122+00
2144	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:47.563435+00
2145	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:47.570107+00
2146	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:55:57.721451+00
2147	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:55:57.734598+00
2258	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:00:20.133441+00
2259	14	2	Read	{"ip": "::1", "path": "/files/14/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 05:00:20.426135+00
2260	14	2	Read	{"ip": "::1", "path": "/files/14/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 05:00:20.436471+00
2309	\N	2	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "clerk"}	2025-10-06 05:05:52.989495+00
2355	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:07:04.596224+00
2376	\N	2	Read	{"ip": "::1", "path": "/files?q=draf&date_from=2025-08-07T05:11:09.652Z&limit=8&includeSla=false", "query": {"q": "draf", "limit": 8, "date_from": "2025-08-07T05:11:09.652Z"}, "route": "GET /files", "method": "GET"}	2025-10-06 05:12:07.84767+00
2377	\N	2	Read	{"ip": "::1", "path": "/files?q=draft&date_from=2025-08-07T05:11:10.832Z&limit=8&includeSla=false", "query": {"q": "draft", "limit": 8, "date_from": "2025-08-07T05:11:10.832Z"}, "route": "GET /files", "method": "GET"}	2025-10-06 05:12:08.924204+00
2390	\N	2	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "clerk"}	2025-10-06 05:58:34.967694+00
2398	14	2	Read	{"ip": "::1", "path": "/files/14/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 06:18:13.560242+00
2399	14	2	Read	{"ip": "::1", "path": "/files/14/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 06:18:13.601109+00
2400	15	2	Read	{"ip": "::1", "path": "/files/15/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 06:18:14.401422+00
2401	15	2	Read	{"ip": "::1", "path": "/files/15/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 06:18:14.446765+00
2410	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:29:51.555937+00
2420	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:34:04.098635+00
1278	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:27:35.3098+00
1279	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:27:35.309965+00
1284	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:27:35.560345+00
1285	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:27:37.522498+00
1295	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:27:45.429166+00
1467	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:55:25.10682+00
1528	9	4	Write	{"ip": "::1", "path": "/files/9/events", "route": "POST /files/:id/events", "method": "POST", "stored": 36, "payload": {"remarks": "SOME REASON", "to_user_id": 1, "action_type": "Escalate"}}	2025-10-05 14:07:17.053127+00
1608	13	3	Write	{"ip": "::1", "path": "/files/13/events", "route": "POST /files/:id/events", "method": "POST", "stored": 39, "payload": {"remarks": "ddddsd", "to_user_id": 1, "action_type": "Escalate"}}	2025-10-05 14:41:48.453533+00
1610	\N	3	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&holder=3", "query": {"page": 1, "limit": 50, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:41:50.66351+00
1612	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50&holder=3", "query": {"limit": 50, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:41:56.899737+00
1614	\N	3	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&holder=3", "query": {"page": 1, "limit": 50, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:41:57.324375+00
1658	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:48:16.200015+00
1659	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:48:16.452269+00
1697	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:05:19.627417+00
1748	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:31:42.344161+00
1813	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:29:24.994684+00
1868	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200&holder=3", "query": {"limit": 200, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:41:40.140603+00
1924	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:50:25.701247+00
2148	\N	2	Read	{"ip": "::1", "path": "/files?q=&status=&office=&page=1&limit=50&sort_by=owning_office&sort_dir=desc&includeSla=true&creator=2", "query": {"q": "", "page": 1, "limit": 50, "status": "", "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:55:58.478886+00
2149	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:56:04.941632+00
2150	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:56:04.951259+00
2261	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:00:20.795671+00
2262	14	2	Read	{"ip": "::1", "path": "/files/14/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 05:00:21.093883+00
2263	14	2	Read	{"ip": "::1", "path": "/files/14/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 05:00:21.1026+00
2310	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:05:53.028128+00
2356	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:07:05.84188+00
2357	14	2	Read	{"ip": "::1", "path": "/files/14/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 05:07:06.745656+00
2358	14	2	Read	{"ip": "::1", "path": "/files/14/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 05:07:06.757725+00
2378	\N	2	Read	{"ip": "::1", "path": "/files?q=smthin&date_from=2025-08-07T05:15:33.679Z&limit=8&includeSla=false", "query": {"q": "smthin", "limit": 8, "date_from": "2025-08-07T05:15:33.679Z"}, "route": "GET /files", "method": "GET"}	2025-10-06 05:16:30.921885+00
2391	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:58:35.062288+00
2402	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:18:30.958136+00
2416	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:32:00.487651+00
2421	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:34:34.207037+00
1280	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:27:35.317948+00
1289	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:27:37.541069+00
1294	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:27:43.255923+00
1468	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:55:59.086033+00
1529	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:07:17.074564+00
1609	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50&holder=3", "query": {"limit": 50, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:41:48.468946+00
1611	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200&holder=3", "query": {"limit": 200, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:41:51.607967+00
1613	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50&holder=3", "query": {"limit": 50, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:41:57.197882+00
1620	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200&holder=3", "query": {"limit": 200, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:42:15.967198+00
1660	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:48:17.46306+00
1698	\N	4	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "admin"}	2025-10-05 20:16:46.130343+00
1749	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:32:05.158111+00
1751	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:32:05.750957+00
1814	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:29:56.444914+00
1869	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:41:40.59075+00
1871	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50&holder=3", "query": {"limit": 50, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:41:44.830668+00
1925	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:50:31.759116+00
2151	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:56:04.955034+00
2152	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:56:04.975223+00
2264	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:00:21.191199+00
2265	14	2	Read	{"ip": "::1", "path": "/files/14/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 05:00:21.489483+00
2266	14	2	Read	{"ip": "::1", "path": "/files/14/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 05:00:21.498839+00
2311	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:05:55.140673+00
2312	14	2	Read	{"ip": "::1", "path": "/files/14/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 05:05:56.022649+00
2313	14	2	Read	{"ip": "::1", "path": "/files/14/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 05:05:56.033164+00
2359	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:07:20.599301+00
2379	\N	2	Read	{"ip": "::1", "path": "/files?q=sda&date_from=2025-08-07T05:17:37.057Z&limit=8&includeSla=false", "query": {"q": "sda", "limit": 8, "date_from": "2025-08-07T05:17:37.057Z"}, "route": "GET /files", "method": "GET"}	2025-10-06 05:18:36.700591+00
2392	\N	2	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "clerk"}	2025-10-06 06:17:06.458897+00
2403	\N	2	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "clerk"}	2025-10-06 06:29:31.993265+00
2406	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:29:38.247895+00
2411	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:29:51.844836+00
2412	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:29:52.05828+00
2413	15	1	Read	{"ip": "::1", "path": "/files/15/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 06:29:52.645862+00
2414	15	1	Read	{"ip": "::1", "path": "/files/15/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 06:29:52.698992+00
2415	15	1	Write	{"ip": "::1", "path": "/files/15/token", "route": "POST /files/:id/token", "method": "POST", "stable": true}	2025-10-06 06:29:54.269495+00
2417	\N	4	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "admin"}	2025-10-06 06:32:52.725341+00
1281	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:27:35.326254+00
1288	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:27:37.535172+00
1290	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:27:37.546368+00
1296	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:27:54.162298+00
1469	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:56:00.02675+00
1530	\N	4	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:07:20.302233+00
1531	12	4	Read	{"ip": "::1", "path": "/files/12/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 14:07:21.621737+00
1532	12	4	Read	{"ip": "::1", "path": "/files/12/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 14:07:21.632592+00
1533	12	4	Write	{"ip": "::1", "path": "/files/12/token?force=true", "route": "POST /files/:id/token", "method": "POST", "stable": true}	2025-10-05 14:07:25.939481+00
1534	12	4	Read	{"ip": "::1", "path": "/files/shared/12/VPACEtknyernJGCr3M-RB6yajwfHDFFS", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 14:07:27.183992+00
1535	12	4	Read	{"ip": "::1", "path": "/files/shared/12/VPACEtknyernJGCr3M-RB6yajwfHDFFS", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 14:07:27.194681+00
1615	\N	3	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:42:04.821499+00
1661	\N	2	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "clerk"}	2025-10-05 14:49:59.138304+00
1699	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:16:46.17162+00
1700	\N	4	Read	{"ip": "::1", "path": "/files?q=&limit=10&includeSla=false", "query": {"q": "", "limit": 10}, "route": "GET /files", "method": "GET"}	2025-10-05 20:16:50.029432+00
1750	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:32:05.596395+00
1752	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:32:05.910554+00
1815	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:32:25.809373+00
1870	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50&holder=3", "query": {"limit": 50, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:41:44.552592+00
1872	\N	3	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&holder=3", "query": {"page": 1, "limit": 50, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:41:49.74159+00
1926	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:50:32.37542+00
1927	13	2	Read	{"ip": "::1", "path": "/files/13/events", "count": 3, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 04:50:33.40501+00
1928	13	2	Read	{"ip": "::1", "path": "/files/13/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 04:50:33.417436+00
1929	13	2	Read	{"ip": "::1", "path": "/files/13/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 04:50:33.84344+00
2153	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:56:42.630665+00
2154	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:56:42.63785+00
2157	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:56:46.095355+00
2270	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:00:31.689478+00
2271	14	2	Read	{"ip": "::1", "path": "/files/14/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 05:00:31.980058+00
2272	14	2	Read	{"ip": "::1", "path": "/files/14/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 05:00:31.98966+00
2279	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:00:47.054967+00
2280	13	2	Read	{"ip": "::1", "path": "/files/13/events", "count": 3, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 05:00:48.108237+00
2281	13	2	Read	{"ip": "::1", "path": "/files/13/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 05:00:48.121047+00
2282	14	2	Read	{"ip": "::1", "path": "/files/14/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 05:00:48.84663+00
2283	14	2	Read	{"ip": "::1", "path": "/files/14/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 05:00:48.856129+00
2314	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:05:57.662482+00
2315	14	2	Read	{"ip": "::1", "path": "/files/14/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 05:05:58.536611+00
1283	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:27:35.342674+00
1298	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:28:29.863438+00
1299	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:29:47.473885+00
1300	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:31:14.945431+00
1301	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:31:15.312305+00
1302	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:31:19.515223+00
1303	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:31:19.609889+00
1304	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:31:59.290537+00
1305	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:32:00.291394+00
1306	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:32:13.297273+00
1307	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:32:13.7299+00
1308	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:32:14.14237+00
1309	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:32:14.581039+00
1310	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:32:14.782928+00
1311	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:32:38.206796+00
1312	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:32:58.155672+00
1313	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:32:58.157576+00
1314	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:36:51.286187+00
1315	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:36:51.417533+00
1316	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:38:40.068016+00
1317	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:38:40.077713+00
1318	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:38:40.0842+00
1319	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:38:40.093128+00
1320	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:38:40.100747+00
1321	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:38:40.110206+00
1322	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:38:41.125838+00
1323	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:38:42.387908+00
1324	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:38:51.562946+00
1325	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:38:52.757685+00
1326	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:38:53.031187+00
1327	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:38:57.099078+00
1328	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:38:57.915052+00
1329	4	1	Read	{"ip": "::1", "path": "/files/4/events", "count": 0, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 09:38:58.207764+00
1330	4	1	Read	{"ip": "::1", "path": "/files/4/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 09:38:58.220876+00
1331	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:38:59.335448+00
1332	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:39:00.201248+00
1333	3	1	Read	{"ip": "::1", "path": "/files/3/events", "count": 5, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 09:39:00.492206+00
1334	3	1	Read	{"ip": "::1", "path": "/files/3/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 09:39:00.502151+00
1336	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:39:02.373968+00
1337	2	1	Read	{"ip": "::1", "path": "/files/2/events", "count": 2, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 09:39:02.649347+00
1338	2	1	Read	{"ip": "::1", "path": "/files/2/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 09:39:02.659623+00
1345	4	1	Read	{"ip": "::1", "path": "/files/shared/4/tLYpK7R2p1JChbhJzPURmAO7kJNTJGIx/events", "count": 0, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 09:39:11.167124+00
1346	4	1	Read	{"ip": "::1", "path": "/files/shared/4/tLYpK7R2p1JChbhJzPURmAO7kJNTJGIx/events", "count": 0, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 09:39:11.174141+00
1347	11	1	Read	{"ip": "::1", "path": "/files/11/events", "count": 4, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 09:39:18.015726+00
1348	11	1	Read	{"ip": "::1", "path": "/files/11/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 09:39:18.026061+00
1349	11	1	Read	{"ip": "::1", "path": "/files/11/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 09:39:20.405751+00
1470	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:56:00.031738+00
1536	12	4	Read	{"ip": "::1", "path": "/files/shared/12/VPACEtknyernJGCr3M-RB6yajwfHDFFS/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 14:07:27.195984+00
1537	12	4	Read	{"ip": "::1", "path": "/files/shared/12/VPACEtknyernJGCr3M-RB6yajwfHDFFS/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-05 14:07:27.205607+00
1549	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:07:44.06511+00
1616	\N	3	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&holder=3", "query": {"page": 1, "limit": 50, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:42:06.068615+00
1662	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:49:59.175666+00
1701	\N	4	Read	{"q": "", "ip": "::1", "page": 1, "path": "/users?q=&limit=100", "limit": 100, "route": "GET /users", "method": "GET"}	2025-10-05 20:16:50.030535+00
1753	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:33:43.985578+00
1755	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:33:46.93039+00
1816	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:32:36.360868+00
1873	\N	3	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:41:53.493085+00
1930	\N	2	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "clerk"}	2025-10-06 04:50:57.763797+00
2155	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:56:42.644239+00
2156	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:56:42.650632+00
2158	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:56:46.106181+00
2276	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:00:45.270289+00
2277	14	2	Read	{"ip": "::1", "path": "/files/14/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 05:00:46.311946+00
2278	14	2	Read	{"ip": "::1", "path": "/files/14/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 05:00:46.321449+00
2316	14	2	Read	{"ip": "::1", "path": "/files/14/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 05:05:58.547584+00
2326	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:06:11.6054+00
2327	11	2	Read	{"ip": "::1", "path": "/files/11/events", "count": 4, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 05:06:12.178126+00
2328	11	2	Read	{"ip": "::1", "path": "/files/11/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 05:06:12.18791+00
2360	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:07:21.580344+00
2380	15	2	Write	{"ip": "::1", "path": "/files", "route": "POST /files", "method": "POST", "payload": {"remarks": "", "subject": "sda", "priority": "Routine", "category_id": 1, "save_as_draft": false, "sla_policy_id": 1, "date_initiated": "2025-10-06", "confidentiality": true, "notesheet_title": "sad", "owning_office_id": 1, "forward_to_officer_id": 3, "date_received_accounts": "2025-10-06"}}	2025-10-06 05:18:52.111068+00
2393	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:17:06.56489+00
1335	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:39:01.567195+00
1471	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:56:00.034685+00
1538	\N	4	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:07:38.825674+00
1539	9	4	Read	{"ip": "::1", "path": "/files/9/events", "count": 5, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 14:07:39.112311+00
1540	9	4	Read	{"ip": "::1", "path": "/files/9/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 14:07:39.129342+00
1541	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:07:41.09931+00
1617	\N	3	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:42:06.400495+00
1619	\N	3	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:42:09.066783+00
1663	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:50:17.026333+00
1664	13	2	Read	{"ip": "::1", "path": "/files/13/events", "count": 3, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 14:50:18.273745+00
1665	13	2	Read	{"ip": "::1", "path": "/files/13/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 14:50:18.285858+00
1702	\N	4	Read	{"ip": "::1", "path": "/files?q=&limit=10&includeSla=false", "query": {"q": "", "limit": 10}, "route": "GET /files", "method": "GET"}	2025-10-05 20:20:21.751484+00
1705	\N	4	Read	{"q": "", "ip": "::1", "page": 1, "path": "/users?q=&limit=100", "limit": 100, "route": "GET /users", "method": "GET"}	2025-10-05 20:20:23.199309+00
1706	\N	4	Read	{"q": "", "ip": "::1", "page": 1, "path": "/users?q=&limit=100", "limit": 100, "route": "GET /users", "method": "GET"}	2025-10-05 20:20:23.313235+00
1754	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:33:45.54841+00
1756	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:33:47.307321+00
1817	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:32:52.671874+00
1819	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:32:54.259597+00
1820	13	2	Read	{"ip": "::1", "path": "/files/13/events", "count": 3, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 04:32:54.968807+00
1821	13	2	Read	{"ip": "::1", "path": "/files/13/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 04:32:54.980302+00
1874	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50&holder=3", "query": {"limit": 50, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:42:10.833293+00
1876	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200&holder=3", "query": {"limit": 200, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:42:11.85433+00
1931	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:50:57.79305+00
2159	\N	2	Read	{"ip": "::1", "path": "/files?q=&status=&office=&page=1&limit=50&sort_by=owning_office&sort_dir=desc&includeSla=true&creator=2", "query": {"q": "", "page": 1, "limit": 50, "status": "", "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:56:46.10971+00
2160	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:56:46.691973+00
2161	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:56:46.700481+00
2166	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:56:47.586246+00
2167	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:56:47.593254+00
2168	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:56:47.702561+00
2169	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:56:47.710638+00
2284	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:00:49.488852+00
2285	14	2	Read	{"ip": "::1", "path": "/files/14/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 05:00:50.463554+00
2286	14	2	Read	{"ip": "::1", "path": "/files/14/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 05:00:50.473695+00
2317	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:06:08.791228+00
2361	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:07:25.744325+00
1339	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:39:03.201638+00
1472	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:56:00.041381+00
1542	\N	4	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:07:42.0744+00
1543	12	4	Read	{"ip": "::1", "path": "/files/12/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 14:07:42.346479+00
1544	12	4	Read	{"ip": "::1", "path": "/files/12/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 14:07:42.36203+00
1545	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 14:07:44.029625+00
1546	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 14:07:44.038461+00
1618	\N	3	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&holder=3", "query": {"page": 1, "limit": 50, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:42:07.071641+00
1703	\N	4	Read	{"q": "", "ip": "::1", "page": 1, "path": "/users?q=&limit=100", "limit": 100, "route": "GET /users", "method": "GET"}	2025-10-05 20:20:21.751355+00
1704	\N	4	Read	{"ip": "::1", "path": "/files?q=&limit=10&includeSla=false", "query": {"q": "", "limit": 10}, "route": "GET /files", "method": "GET"}	2025-10-05 20:20:23.19886+00
1707	\N	4	Read	{"ip": "::1", "path": "/files?q=&limit=10&includeSla=false", "query": {"q": "", "limit": 10}, "route": "GET /files", "method": "GET"}	2025-10-05 20:20:23.313867+00
1757	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:35:27.05666+00
1818	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:32:53.510845+00
1875	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50&holder=3", "query": {"limit": 50, "holder": 3}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:42:11.100166+00
1932	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:51:03.347894+00
1933	\N	2	Read	{"ip": "::1", "path": "/files?q=file+02&date_from=2025-08-07T04:50:09.590Z&limit=8&includeSla=false", "query": {"q": "file 02", "limit": 8, "date_from": "2025-08-07T04:50:09.590Z"}, "route": "GET /files", "method": "GET"}	2025-10-06 04:51:06.797705+00
1934	\N	2	Read	{"ip": "::1", "path": "/files?q=file+03&date_from=2025-08-07T04:50:12.550Z&limit=8&includeSla=false", "query": {"q": "file 03", "limit": 8, "date_from": "2025-08-07T04:50:12.550Z"}, "route": "GET /files", "method": "GET"}	2025-10-06 04:51:12.237318+00
1935	\N	2	Read	{"ip": "::1", "path": "/files?q=file+01&date_from=2025-08-07T04:50:14.121Z&limit=8&includeSla=false", "query": {"q": "file 01", "limit": 8, "date_from": "2025-08-07T04:50:14.121Z"}, "route": "GET /files", "method": "GET"}	2025-10-06 04:51:13.678819+00
1936	\N	2	Read	{"ip": "::1", "path": "/files?q=someth&date_from=2025-08-07T04:50:17.761Z&limit=8&includeSla=false", "query": {"q": "someth", "limit": 8, "date_from": "2025-08-07T04:50:17.761Z"}, "route": "GET /files", "method": "GET"}	2025-10-06 04:51:17.016329+00
1937	\N	2	Read	{"ip": "::1", "path": "/files?q=something&date_from=2025-08-07T04:50:18.849Z&limit=8&includeSla=false", "query": {"q": "something", "limit": 8, "date_from": "2025-08-07T04:50:18.849Z"}, "route": "GET /files", "method": "GET"}	2025-10-06 04:51:18.013096+00
2162	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:56:46.700814+00
2163	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:56:46.708649+00
2164	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:56:47.577398+00
2165	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:56:47.585147+00
2170	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:56:47.711105+00
2171	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:56:47.720928+00
2287	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:02:22.694016+00
2288	14	2	Read	{"ip": "::1", "path": "/files/14/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 05:02:23.414898+00
2289	14	2	Read	{"ip": "::1", "path": "/files/14/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 05:02:23.426311+00
2318	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:06:09.154003+00
2319	14	2	Read	{"ip": "::1", "path": "/files/14/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 05:06:09.735692+00
2320	14	2	Read	{"ip": "::1", "path": "/files/14/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 05:06:09.746802+00
2362	14	2	Read	{"ip": "::1", "path": "/files/14/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 05:07:26.604481+00
2363	14	2	Read	{"ip": "::1", "path": "/files/14/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 05:07:26.614731+00
1340	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:39:06.838684+00
1341	4	1	Read	{"ip": "::1", "path": "/files/4/events", "count": 0, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 09:39:07.139457+00
1342	4	1	Read	{"ip": "::1", "path": "/files/4/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 09:39:07.149957+00
1343	4	1	Read	{"ip": "::1", "path": "/files/shared/4/tLYpK7R2p1JChbhJzPURmAO7kJNTJGIx", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 09:39:11.154382+00
1344	4	1	Read	{"ip": "::1", "path": "/files/shared/4/tLYpK7R2p1JChbhJzPURmAO7kJNTJGIx", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-05 09:39:11.165623+00
1350	12	1	Write	{"ip": "::1", "path": "/files", "route": "POST /files", "method": "POST", "payload": {"remarks": "som", "subject": "draft", "priority": "Urgent", "category_id": 1, "save_as_draft": true, "sla_policy_id": 2, "date_initiated": "2025-10-05", "confidentiality": false, "notesheet_title": "draft", "owning_office_id": 1, "forward_to_officer_id": 3, "date_received_accounts": "2025-10-05"}}	2025-10-05 09:39:39.951728+00
1351	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:39:39.986627+00
1352	12	1	Read	{"ip": "::1", "path": "/files/12/events", "count": 0, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 09:39:40.302874+00
1353	12	1	Read	{"ip": "::1", "path": "/files/12/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 09:39:40.312522+00
1354	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:40:06.095023+00
1355	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:40:14.444491+00
1356	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:40:21.777069+00
1357	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:40:33.689213+00
1358	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:40:39.489733+00
1359	12	1	Read	{"ip": "::1", "path": "/files/12/events", "count": 0, "route": "GET /files/:id/events", "method": "GET"}	2025-10-05 09:40:40.561411+00
1360	12	1	Read	{"ip": "::1", "path": "/files/12/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-05 09:40:40.57677+00
1361	12	1	Write	{"ip": "::1", "path": "/files/12", "route": "PUT /files/:id", "method": "PUT", "submit": true}	2025-10-05 09:40:53.946688+00
1362	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:40:53.968608+00
1363	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:40:56.031672+00
1364	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:40:56.794722+00
1365	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:41:03.257225+00
1366	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:41:03.993025+00
1367	\N	4	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "admin"}	2025-10-05 09:41:29.448883+00
1368	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:41:29.478674+00
1369	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:41:32.538209+00
1370	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:41:32.54106+00
1371	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:41:32.544219+00
1372	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:41:32.54902+00
1373	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:41:32.555933+00
1374	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:41:32.562594+00
1375	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:41:33.041365+00
1376	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:41:34.149808+00
1377	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:41:34.154214+00
1378	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:41:34.155025+00
1379	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:41:34.162943+00
1380	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:41:34.169722+00
1381	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:41:34.17609+00
1387	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:41:35.445543+00
1388	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:41:39.551745+00
1473	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:56:00.05055+00
1547	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:07:44.04535+00
1621	\N	1	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "cof"}	2025-10-05 14:42:31.995553+00
1708	\N	4	Read	{"q": "", "ip": "::1", "page": 1, "path": "/users?q=&limit=100", "limit": 100, "route": "GET /users", "method": "GET"}	2025-10-05 20:22:01.933719+00
1758	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:36:54.02078+00
1822	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:32:57.438062+00
1823	13	2	Read	{"ip": "::1", "path": "/files/13/events", "count": 3, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 04:32:58.764645+00
1824	13	2	Read	{"ip": "::1", "path": "/files/13/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 04:32:58.773913+00
1877	\N	3	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:42:14.241075+00
1938	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:51:32.547756+00
2172	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:58:19.340335+00
2173	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:58:19.348835+00
2178	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:58:20.595937+00
2179	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:58:20.60292+00
2180	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:58:20.704398+00
2181	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:58:20.714208+00
2186	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:58:20.809109+00
2187	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:58:20.817201+00
2188	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:58:21.107962+00
2189	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:58:21.116833+00
2194	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:58:21.218568+00
2195	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:58:21.227048+00
2290	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:02:25.88715+00
2292	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:02:26.264312+00
2293	14	2	Read	{"ip": "::1", "path": "/files/14/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 05:02:27.331342+00
2294	14	2	Read	{"ip": "::1", "path": "/files/14/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 05:02:27.341298+00
2321	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:06:10.367911+00
2325	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:06:11.497869+00
2334	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:06:14.3419+00
2335	14	2	Read	{"ip": "::1", "path": "/files/14/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 05:06:15.179926+00
2336	14	2	Read	{"ip": "::1", "path": "/files/14/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 05:06:15.191441+00
2337	14	2	Read	{"ip": "::1", "path": "/files/14/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 05:06:15.881428+00
2338	13	2	Read	{"ip": "::1", "path": "/files/13/events", "count": 3, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 05:06:16.330611+00
2339	13	2	Read	{"ip": "::1", "path": "/files/13/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 05:06:16.341726+00
1382	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:41:35.422116+00
1390	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:41:41.25926+00
1474	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:56:00.059409+00
1548	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:07:44.057115+00
1622	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:42:32.025945+00
1709	\N	4	Read	{"ip": "::1", "path": "/files?q=&limit=10&includeSla=false", "query": {"q": "", "limit": 10}, "route": "GET /files", "method": "GET"}	2025-10-05 20:22:01.933963+00
1759	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:37:03.55202+00
1825	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:34:07.054811+00
1878	\N	1	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "cof"}	2025-10-06 04:42:36.820649+00
1895	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:42:54.537265+00
1939	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:51:36.554705+00
1940	13	2	Read	{"ip": "::1", "path": "/files/13/events", "count": 3, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 04:51:37.392624+00
1941	13	2	Read	{"ip": "::1", "path": "/files/13/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 04:51:37.410985+00
1942	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:51:39.453014+00
1943	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:51:39.461428+00
2174	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:58:19.355675+00
2175	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:58:19.363102+00
2176	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:58:20.585757+00
2177	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:58:20.594594+00
2182	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:58:20.715184+00
2183	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:58:20.722811+00
2184	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:58:20.799241+00
2185	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:58:20.808561+00
2190	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:58:21.117327+00
2191	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:58:21.124831+00
2192	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:58:21.209417+00
2193	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:58:21.217934+00
2291	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:02:26.129414+00
2322	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:06:10.512471+00
2323	13	2	Read	{"ip": "::1", "path": "/files/13/events", "count": 3, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 05:06:11.147908+00
2324	13	2	Read	{"ip": "::1", "path": "/files/13/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 05:06:11.159915+00
2364	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:07:53.113902+00
2368	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:07:57.452096+00
2381	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 05:18:52.143515+00
2382	15	2	Read	{"ip": "::1", "path": "/files/15/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 05:18:52.460756+00
2383	15	2	Read	{"ip": "::1", "path": "/files/15/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 05:18:52.475048+00
1383	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:41:35.42447+00
1384	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:41:35.427675+00
1386	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:41:35.439362+00
1475	\N	4	Read	{"ip": "::1", "path": "/files?q=&limit=10&includeSla=false", "query": {"q": "", "limit": 10}, "route": "GET /files", "method": "GET"}	2025-10-05 09:58:17.941643+00
1478	\N	4	Read	{"ip": "::1", "path": "/files?q=&limit=10&includeSla=false", "query": {"q": "", "limit": 10}, "route": "GET /files", "method": "GET"}	2025-10-05 09:58:20.125995+00
1480	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:58:20.885707+00
1550	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:07:44.075805+00
1551	\N	4	Read	{"q": "", "ip": "::1", "page": 1, "path": "/users?q=&limit=100", "limit": 100, "route": "GET /users", "method": "GET"}	2025-10-05 14:07:58.303855+00
1623	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:42:45.356405+00
1710	\N	2	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "clerk"}	2025-10-05 20:22:18.127204+00
1760	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:37:27.213055+00
1826	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:37:08.845458+00
1879	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:42:36.854959+00
1883	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:42:46.888722+00
1944	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:51:39.463012+00
1945	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:51:39.470738+00
2196	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:58:40.973034+00
2197	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:58:40.982877+00
2198	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:58:43.579046+00
2199	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:58:43.587129+00
2204	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:58:44.21476+00
2205	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:58:44.221979+00
2206	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:58:44.350117+00
2207	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:58:44.36037+00
2212	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:58:44.422402+00
2213	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:58:44.428929+00
2214	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:58:44.627011+00
2215	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:58:44.634852+00
2220	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:58:54.636837+00
2221	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:58:54.642315+00
2222	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:58:54.950199+00
2223	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:58:54.958129+00
2228	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:58:55.124422+00
2229	13	2	Read	{"ip": "::1", "path": "/files/shared/13/BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:58:55.133006+00
2230	13	2	Read	{"ip": "::1", "path": "/files/13", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-06 04:58:57.310068+00
2232	13	2	Read	{"ip": "::1", "path": "/files/13", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-06 04:58:57.316662+00
2233	13	2	Read	{"ip": "::1", "path": "/files/13", "route": "GET /files/:id", "method": "GET", "includeSla": true}	2025-10-06 04:58:57.32287+00
1385	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:41:35.43272+00
1389	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:41:40.979972+00
1476	\N	4	Read	{"q": "", "ip": "::1", "page": 1, "path": "/users?q=&limit=100", "limit": 100, "route": "GET /users", "method": "GET"}	2025-10-05 09:58:17.941547+00
1477	\N	4	Read	{"q": "", "ip": "::1", "page": 1, "path": "/users?q=&limit=100", "limit": 100, "route": "GET /users", "method": "GET"}	2025-10-05 09:58:20.12563+00
1479	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-21", "query": {"limit": 1000, "date_from": "2025-09-21"}, "route": "GET /files", "method": "GET"}	2025-10-05 09:58:20.879324+00
1482	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 09:58:20.89917+00
1552	\N	4	Read	{"ip": "::1", "path": "/files?q=&limit=10&includeSla=false", "query": {"q": "", "limit": 10}, "route": "GET /files", "method": "GET"}	2025-10-05 14:07:58.314012+00
1624	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 14:42:48.957155+00
1711	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-05 20:22:18.157698+00
1761	\N	2	Read	{"ip": "::1", "path": "/files?q=file&date_from=2025-08-06T20:42:24.862Z&limit=8&includeSla=false", "query": {"q": "file", "limit": 8, "date_from": "2025-08-06T20:42:24.862Z"}, "route": "GET /files", "method": "GET"}	2025-10-05 20:43:22.857737+00
1762	\N	2	Read	{"ip": "::1", "path": "/files?q=file+2&date_from=2025-08-06T20:42:26.553Z&limit=8&includeSla=false", "query": {"q": "file 2", "limit": 8, "date_from": "2025-08-06T20:42:26.553Z"}, "route": "GET /files", "method": "GET"}	2025-10-05 20:43:24.37483+00
1763	\N	2	Read	{"ip": "::1", "path": "/files?q=fif&date_from=2025-08-06T20:42:29.223Z&limit=8&includeSla=false", "query": {"q": "fif", "limit": 8, "date_from": "2025-08-06T20:42:29.223Z"}, "route": "GET /files", "method": "GET"}	2025-10-05 20:43:26.779961+00
1764	\N	2	Read	{"ip": "::1", "path": "/files?q=file+02&date_from=2025-08-06T20:42:30.475Z&limit=8&includeSla=false", "query": {"q": "file 02", "limit": 8, "date_from": "2025-08-06T20:42:30.475Z"}, "route": "GET /files", "method": "GET"}	2025-10-05 20:43:27.905139+00
1765	\N	2	Read	{"ip": "::1", "path": "/files?q=file+02&date_from=2025-08-06T20:42:40.356Z&limit=8&includeSla=false", "query": {"q": "file 02", "limit": 8, "date_from": "2025-08-06T20:42:40.356Z"}, "route": "GET /files", "method": "GET"}	2025-10-05 20:43:36.802561+00
1827	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:37:11.674364+00
1880	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:42:39.387624+00
1885	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 04:42:48.738386+00
1946	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:53:31.605983+00
1947	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:53:31.613538+00
1956	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:53:36.105157+00
1957	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:53:36.11329+00
1958	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:53:36.938886+00
1959	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:53:36.949379+00
1964	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:53:39.00768+00
1965	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:53:39.015948+00
1966	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:53:40.538618+00
1967	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:53:40.546153+00
1968	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:53:40.558447+00
1969	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:53:40.566293+00
1970	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:53:48.077212+00
1971	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:53:48.085379+00
1973	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:53:48.094195+00
1975	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 04:53:48.1026+00
1980	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:53:50.280787+00
1981	13	2	Read	{"ip": "::1", "path": "/files/shared/13/qLIq-6XP-Xh1xQ9IphauYNvwIBGp3ViY/events", "count": 3, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 04:53:50.290298+00
2427	16	1	Read	{"ip": "::1", "path": "/files/16/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 06:36:01.03186+00
2428	16	1	Write	{"ip": "::1", "path": "/files/16/token", "route": "POST /files/:id/token", "method": "POST", "stable": true}	2025-10-06 06:36:06.877664+00
2429	16	1	Read	{"ip": "::1", "path": "/files/shared/16/YxN1AcpKq177bZNIrD903lnkNKU0AKO7", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 06:36:55.81532+00
2430	16	1	Read	{"ip": "::1", "path": "/files/shared/16/YxN1AcpKq177bZNIrD903lnkNKU0AKO7", "route": "GET /files/shared/:id/:token", "method": "GET"}	2025-10-06 06:36:55.835208+00
2431	16	1	Read	{"ip": "::1", "path": "/files/shared/16/YxN1AcpKq177bZNIrD903lnkNKU0AKO7/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 06:36:55.850062+00
2432	16	1	Read	{"ip": "::1", "path": "/files/shared/16/YxN1AcpKq177bZNIrD903lnkNKU0AKO7/events", "count": 1, "route": "GET /files/shared/:id/:token/events", "method": "GET"}	2025-10-06 06:36:55.870021+00
2433	16	1	Read	{"ip": "::1", "path": "/files/16/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 06:37:13.70891+00
2434	16	1	Read	{"ip": "::1", "path": "/files/16/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 06:37:14.054472+00
2435	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:37:15.063756+00
2436	16	1	Read	{"ip": "::1", "path": "/files/16/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 06:37:15.407534+00
2437	16	1	Read	{"ip": "::1", "path": "/files/16/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 06:37:15.43966+00
2438	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:37:18.868515+00
2439	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:37:19.590304+00
2440	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:37:19.865878+00
2441	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-22", "query": {"limit": 1000, "date_from": "2025-09-22"}, "route": "GET /files", "method": "GET"}	2025-10-06 06:38:50.385006+00
2442	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-22", "query": {"limit": 1000, "date_from": "2025-09-22"}, "route": "GET /files", "method": "GET"}	2025-10-06 06:38:50.396462+00
2443	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:38:50.397571+00
2444	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:38:50.425154+00
2445	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:38:50.448876+00
2446	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:38:50.466319+00
2447	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:38:52.920097+00
2448	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:38:53.913187+00
2449	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:38:54.214593+00
2450	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:39:30.27041+00
2451	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:39:31.58416+00
2452	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-22", "query": {"limit": 1000, "date_from": "2025-09-22"}, "route": "GET /files", "method": "GET"}	2025-10-06 06:39:31.590725+00
2453	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-22", "query": {"limit": 1000, "date_from": "2025-09-22"}, "route": "GET /files", "method": "GET"}	2025-10-06 06:39:31.608901+00
2454	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:39:31.612856+00
2455	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:39:31.632091+00
2456	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:39:31.647749+00
2457	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:39:32.411668+00
2458	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:39:34.055369+00
2459	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:39:35.253052+00
2460	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:39:38.121486+00
2461	16	1	Read	{"ip": "::1", "path": "/files/16/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 06:39:39.239739+00
2462	16	1	Read	{"ip": "::1", "path": "/files/16/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 06:38:40.230029+00
2463	16	1	Read	{"ip": "::1", "path": "/files/16/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 06:39:40.591853+00
2464	15	1	Read	{"ip": "::1", "path": "/files/15/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 06:39:41.148757+00
2465	15	1	Read	{"ip": "::1", "path": "/files/15/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 06:39:41.176653+00
2466	16	1	Read	{"ip": "::1", "path": "/files/16/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 06:39:41.676524+00
2467	16	1	Read	{"ip": "::1", "path": "/files/16/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 06:39:42.178089+00
2468	16	1	Read	{"ip": "::1", "path": "/files/16/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 06:39:42.950507+00
2469	16	1	Read	{"ip": "::1", "path": "/files/16/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 06:39:43.249754+00
2470	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-22", "query": {"limit": 1000, "date_from": "2025-09-22"}, "route": "GET /files", "method": "GET"}	2025-10-06 06:39:52.952024+00
2471	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-22", "query": {"limit": 1000, "date_from": "2025-09-22"}, "route": "GET /files", "method": "GET"}	2025-10-06 06:39:52.966355+00
2472	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:39:52.971966+00
2473	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:39:53.000438+00
2474	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:39:53.029311+00
2475	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:39:53.050022+00
2476	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:40:09.386313+00
2477	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:40:11.239784+00
2478	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:40:11.50928+00
2479	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:40:22.126867+00
2480	16	1	Read	{"ip": "::1", "path": "/files/16/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 06:40:22.854888+00
2481	16	1	Read	{"ip": "::1", "path": "/files/16/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 06:40:22.90153+00
2482	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:40:25.239309+00
2483	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:40:25.540604+00
2484	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:40:26.966257+00
2485	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:41:10.949442+00
2486	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:41:37.951941+00
2487	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-22", "query": {"limit": 1000, "date_from": "2025-09-22"}, "route": "GET /files", "method": "GET"}	2025-10-06 06:41:38.433398+00
2488	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-22", "query": {"limit": 1000, "date_from": "2025-09-22"}, "route": "GET /files", "method": "GET"}	2025-10-06 06:41:38.453283+00
2489	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:41:38.45807+00
2490	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:41:38.47808+00
2491	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:41:38.499162+00
2492	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:41:38.518264+00
2493	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:41:42.013869+00
2494	16	1	Read	{"ip": "::1", "path": "/files/16/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 06:42:06.720463+00
2495	16	1	Read	{"ip": "::1", "path": "/files/16/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 06:42:06.763664+00
2496	16	1	Read	{"ip": "::1", "path": "/files/16/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 06:42:07.361163+00
2497	16	1	Read	{"ip": "::1", "path": "/files/16/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 06:42:08.208594+00
2498	16	1	Read	{"ip": "::1", "path": "/files/16/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 06:42:08.831961+00
2499	\N	1	Read	{"ip": "::1", "path": "/files?q=&status=&office=&page=1&limit=50&sort_by=subject&sort_dir=desc&includeSla=true", "query": {"q": "", "page": 1, "limit": 50, "status": ""}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:41:14.316646+00
2500	16	1	Read	{"ip": "::1", "path": "/files/16/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 06:42:14.7393+00
2501	16	1	Read	{"ip": "::1", "path": "/files/16/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 06:42:15.423549+00
2502	16	1	Read	{"ip": "::1", "path": "/files/16/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 06:42:15.709315+00
2503	16	1	Read	{"ip": "::1", "path": "/files/16/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 06:42:17.174175+00
2504	\N	1	Read	{"ip": "::1", "path": "/files?q=&status=&office=&page=1&limit=50&sort_by=subject&sort_dir=asc&includeSla=true", "query": {"q": "", "page": 1, "limit": 50, "status": ""}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:42:17.871881+00
2505	16	1	Read	{"ip": "::1", "path": "/files/16/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 06:42:21.20487+00
2506	16	1	Read	{"ip": "::1", "path": "/files/16/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 06:42:22.010224+00
2507	15	1	Read	{"ip": "::1", "path": "/files/15/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-06 06:42:24.32878+00
2508	15	1	Read	{"ip": "::1", "path": "/files/15/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 06:42:24.377253+00
2509	15	1	Read	{"ip": "::1", "path": "/files/15/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 06:42:24.926765+00
2510	16	1	Read	{"ip": "::1", "path": "/files/16/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-06 06:42:25.521369+00
2511	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:42:28.021942+00
2512	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:42:28.278332+00
2513	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:42:30.592314+00
2514	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:42:33.097545+00
2515	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:42:33.373089+00
2516	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:42:34.25395+00
2517	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:42:34.658259+00
2518	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:42:34.922842+00
2519	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:42:36.338828+00
2520	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:42:36.583088+00
2521	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-06 06:42:38.102851+00
2522	\N	2	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "clerk"}	2025-10-08 02:49:15.248685+00
2523	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:49:15.322285+00
2524	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:49:18.810028+00
2525	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:49:26.425369+00
2526	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:49:27.53491+00
2527	\N	1	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "cof"}	2025-10-08 02:49:33.791647+00
2528	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:49:33.811241+00
2529	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:49:44.683405+00
2530	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:49:44.947994+00
2531	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:49:47.198888+00
2532	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:49:47.991863+00
2533	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:50:48.903925+00
2534	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:51:19.390924+00
2535	\N	1	Read	{"ip": "::1", "path": "/files?q=file&date_from=2025-08-09T02:50:29.303Z&limit=8&includeSla=false", "query": {"q": "file", "limit": 8, "date_from": "2025-08-09T02:50:29.303Z"}, "route": "GET /files", "method": "GET"}	2025-10-08 02:51:32.512621+00
2536	\N	1	Read	{"ip": "::1", "path": "/files?q=file+time&date_from=2025-08-09T02:50:30.500Z&limit=8&includeSla=false", "query": {"q": "file time", "limit": 8, "date_from": "2025-08-09T02:50:30.500Z"}, "route": "GET /files", "method": "GET"}	2025-10-08 02:51:33.609075+00
2537	\N	1	Read	{"ip": "::1", "path": "/files?q=file+time+check&date_from=2025-08-09T02:50:32.404Z&limit=8&includeSla=false", "query": {"q": "file time check", "limit": 8, "date_from": "2025-08-09T02:50:32.404Z"}, "route": "GET /files", "method": "GET"}	2025-10-08 02:51:35.355309+00
2538	17	1	Write	{"ip": "::1", "path": "/files", "route": "POST /files", "method": "POST", "payload": {"remarks": "new routine file ", "subject": "file time check", "priority": "Routine", "category_id": 1, "save_as_draft": false, "sla_policy_id": 1, "date_initiated": "2025-10-08", "confidentiality": false, "notesheet_title": "file time", "owning_office_id": 1, "forward_to_officer_id": 3, "date_received_accounts": "2025-10-08"}}	2025-10-08 02:51:50.049395+00
2539	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:51:50.08412+00
2540	17	1	Read	{"ip": "::1", "path": "/files/17/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-08 02:51:50.374586+00
2541	17	1	Read	{"ip": "::1", "path": "/files/17/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-08 02:51:50.394516+00
2542	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:52:21.975404+00
2543	17	1	Read	{"ip": "::1", "path": "/files/17/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-08 02:52:22.277528+00
2544	17	1	Read	{"ip": "::1", "path": "/files/17/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-08 02:52:22.288902+00
2545	17	1	Read	{"ip": "::1", "path": "/files/17/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-08 02:52:46.394067+00
2546	17	1	Read	{"ip": "::1", "path": "/files/17/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-08 02:52:46.846652+00
2547	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:52:47.69036+00
2548	17	1	Read	{"ip": "::1", "path": "/files/17/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-08 02:52:47.986157+00
2549	17	1	Read	{"ip": "::1", "path": "/files/17/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-08 02:52:47.996481+00
2550	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:52:49.210912+00
2551	17	1	Read	{"ip": "::1", "path": "/files/17/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-08 02:52:49.498191+00
2552	17	1	Read	{"ip": "::1", "path": "/files/17/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-08 02:52:49.50863+00
2553	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:52:50.372719+00
2554	17	1	Read	{"ip": "::1", "path": "/files/17/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-08 02:52:50.669187+00
2555	17	1	Read	{"ip": "::1", "path": "/files/17/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-08 02:52:50.680813+00
2556	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:52:50.93476+00
2557	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:52:51.272664+00
2558	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:52:51.588147+00
2559	17	1	Read	{"ip": "::1", "path": "/files/17/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-08 02:52:51.889156+00
2560	17	1	Read	{"ip": "::1", "path": "/files/17/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-08 02:52:51.899643+00
2561	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:52:57.379927+00
2562	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:52:57.658959+00
2563	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:52:59.055908+00
2564	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:53:26.599808+00
2565	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:53:44.642088+00
2566	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:53:52.227845+00
2567	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:53:54.709881+00
2568	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:54:22.427579+00
2569	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:54:23.047454+00
2570	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:54:23.320056+00
2571	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:54:23.454877+00
2572	17	1	Read	{"ip": "::1", "path": "/files/17/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-08 02:54:24.015666+00
2573	17	1	Read	{"ip": "::1", "path": "/files/17/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-08 02:54:24.027868+00
2574	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:54:25.626354+00
2575	17	1	Read	{"ip": "::1", "path": "/files/17/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-08 02:54:26.858302+00
2576	17	1	Read	{"ip": "::1", "path": "/files/17/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-08 02:54:26.87395+00
2577	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:55:38.331232+00
2578	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:55:40.05229+00
2579	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:56:02.320697+00
2580	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:56:12.281466+00
2581	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:56:22.630559+00
2582	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:56:23.311093+00
2583	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:56:23.950486+00
2584	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:56:28.162209+00
2585	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:56:29.484601+00
2586	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:56:30.458136+00
2587	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:56:30.868561+00
2588	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:56:31.409009+00
2589	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:56:31.641646+00
2590	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:56:32.05831+00
2591	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:56:33.526598+00
2592	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:56:33.875314+00
2593	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:56:39.045372+00
2594	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:57:52.548163+00
2595	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:59:35.975853+00
2596	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 02:59:46.075288+00
2597	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:00:34.096491+00
2598	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:00:44.162095+00
2599	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:00:44.175514+00
2600	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:00:56.342754+00
2601	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:00:58.212136+00
2602	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:00:58.816765+00
2603	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:01:21.965473+00
2604	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:01:22.233803+00
2605	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:01:22.938533+00
2606	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:01:23.468784+00
2607	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:01:23.74265+00
2608	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:01:25.794852+00
2609	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:01:26.606522+00
2610	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:01:33.836526+00
2611	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-24", "query": {"limit": 1000, "date_from": "2025-09-24"}, "route": "GET /files", "method": "GET"}	2025-10-08 03:01:56.9459+00
2612	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-24", "query": {"limit": 1000, "date_from": "2025-09-24"}, "route": "GET /files", "method": "GET"}	2025-10-08 03:01:56.955751+00
2613	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:01:56.961584+00
2614	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:01:56.97025+00
2615	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:01:56.979229+00
2616	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:01:56.986903+00
2617	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:02:11.043216+00
2618	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:02:33.25217+00
2619	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:02:33.511072+00
2620	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:02:35.001824+00
2621	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:03:05.471141+00
2622	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:03:06.032884+00
2623	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:03:08.654713+00
2624	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:03:08.927805+00
2625	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=200", "query": {"limit": 200}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:03:12.864476+00
2626	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:03:14.225134+00
2627	17	1	Read	{"ip": "::1", "path": "/files/17/events", "count": 1, "route": "GET /files/:id/events", "method": "GET"}	2025-10-08 03:03:14.517445+00
2628	17	1	Read	{"ip": "::1", "path": "/files/17/token", "route": "GET /files/:id/token", "method": "GET", "hasToken": "[REDACTED]"}	2025-10-08 03:03:14.530746+00
2629	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-24", "query": {"limit": 1000, "date_from": "2025-09-24"}, "route": "GET /files", "method": "GET"}	2025-10-08 03:03:15.904501+00
2630	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:03:15.910292+00
2631	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=false&limit=1000&date_from=2025-09-24", "query": {"limit": 1000, "date_from": "2025-09-24"}, "route": "GET /files", "method": "GET"}	2025-10-08 03:03:15.910935+00
2632	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:03:15.91814+00
2633	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:03:15.929208+00
2634	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=1000", "query": {"limit": 1000}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:03:15.937078+00
2635	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:03:51.32004+00
2636	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:04:42.873181+00
2637	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:05:15.634316+00
2638	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:05:31.255003+00
2639	\N	1	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=50", "query": {"limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:05:31.517823+00
2640	\N	1	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true", "query": {"page": 1, "limit": 50}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:05:31.686665+00
2641	\N	2	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "clerk"}	2025-10-08 03:05:37.679439+00
2642	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:05:37.696861+00
2643	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:05:42.971867+00
2644	\N	2	Read	{"ip": "::1", "path": "/files?page=1&limit=50&includeSla=true&creator=2", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:06:28.653821+00
2645	\N	2	Read	{"ip": "::1", "path": "/files?q=sda&status=&office=&page=1&limit=50&sort_dir=asc&includeSla=true&creator=2", "query": {"q": "sda", "page": 1, "limit": 50, "status": "", "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:06:30.870301+00
2646	\N	2	Read	{"ip": "::1", "path": "/files?q=&status=&office=&page=1&limit=50&sort_dir=asc&includeSla=true&creator=2", "query": {"q": "", "page": 1, "limit": 50, "status": "", "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:06:31.860399+00
2647	\N	2	Read	{"ip": "::1", "path": "/files?q=file+02&status=&office=&page=1&limit=50&sort_dir=asc&includeSla=true&creator=2", "query": {"q": "file 02", "page": 1, "limit": 50, "status": "", "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:06:34.160379+00
2660	\N	4	Read	{"ip": "::1", "path": "/files?includeSla=true&limit=500", "query": {"limit": 500}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:06:52.805031+00
2648	\N	2	Read	{"ip": "::1", "path": "/files?q=fil&status=&office=&page=1&limit=50&sort_dir=asc&includeSla=true&creator=2", "query": {"q": "fil", "page": 1, "limit": 50, "status": "", "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:06:35.187148+00
2649	\N	2	Read	{"ip": "::1", "path": "/files?q=&status=&office=&page=1&limit=50&sort_dir=asc&includeSla=true&creator=2", "query": {"q": "", "page": 1, "limit": 50, "status": "", "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:06:37.406693+00
2650	\N	2	Read	{"ip": "::1", "path": "/files?q=&status=Closed&office=&page=1&limit=50&sort_dir=asc&includeSla=true&creator=2", "query": {"q": "", "page": 1, "limit": 50, "status": "Closed", "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:06:38.596484+00
2651	\N	2	Read	{"ip": "::1", "path": "/files?q=&status=&office=&page=1&limit=50&sort_dir=asc&includeSla=true&creator=2", "query": {"q": "", "page": 1, "limit": 50, "status": "", "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:06:39.999561+00
2652	\N	2	Read	{"ip": "::1", "path": "/files?q=&status=Dispatched&office=&page=1&limit=50&sort_dir=asc&includeSla=true&creator=2", "query": {"q": "", "page": 1, "limit": 50, "status": "Dispatched", "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:06:41.083187+00
2653	\N	2	Read	{"ip": "::1", "path": "/files?q=&status=&office=&page=1&limit=50&sort_dir=asc&includeSla=true&creator=2", "query": {"q": "", "page": 1, "limit": 50, "status": "", "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:06:42.202472+00
2654	\N	2	Read	{"ip": "::1", "path": "/files?q=&status=&office=1&page=1&limit=50&sort_dir=asc&includeSla=true&creator=2", "query": {"q": "", "page": 1, "limit": 50, "office": 1, "status": "", "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:06:43.141132+00
2655	\N	2	Read	{"ip": "::1", "path": "/files?q=&status=&office=&page=1&limit=50&sort_dir=asc&includeSla=true&creator=2", "query": {"q": "", "page": 1, "limit": 50, "status": "", "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:06:44.498989+00
2656	\N	2	Read	{"ip": "::1", "path": "/files?q=&status=&office=2&page=1&limit=50&sort_dir=asc&includeSla=true&creator=2", "query": {"q": "", "page": 1, "limit": 50, "office": 2, "status": "", "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:06:45.315939+00
2657	\N	2	Read	{"ip": "::1", "path": "/files?q=&status=&office=&page=1&limit=50&sort_dir=asc&includeSla=true&creator=2", "query": {"q": "", "page": 1, "limit": 50, "status": "", "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:06:46.376219+00
2658	\N	2	Read	{"ip": "::1", "path": "/files?creator=2&type=file_intake&page=1&limit=50", "query": {"page": 1, "limit": 50, "creator": 2}, "route": "GET /files", "method": "GET", "includeSla": true}	2025-10-08 03:06:47.004124+00
2659	\N	4	Read	{"ip": "::1", "path": "/auth/login", "route": "POST /auth/login", "method": "POST", "result": "ok", "username": "admin"}	2025-10-08 03:06:52.787358+00
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
2025-10-01	5
\.


--
-- Data for Name: file_events; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.file_events (id, file_id, seq_no, from_user_id, to_user_id, action_type, started_at, ended_at, business_minutes_held, remarks, attachments_json) FROM stdin;
3	3	1	2	3	Forward	2025-10-04 02:53:40.878672+00	2025-10-04 13:05:44.343453+00	612	YES	[{"url": "/uploads/sm.pdf"}]
1	1	1	2	3	Forward	2025-10-04 01:46:57.624191+00	2025-10-04 13:30:41.210283+00	704	yes	[{"url": "/uploads/sm.pdf"}]
4	3	2	3	\N	Hold	2025-10-04 13:05:44.343453+00	2025-10-04 14:27:47.627307+00	82	som reason	[]
8	3	3	3	1	Escalate	2025-10-04 14:27:47.627307+00	2025-10-04 14:33:25.091577+00	6	sm	[]
5	1	2	3	3	Hold	2025-10-04 13:30:41.210283+00	2025-10-04 14:51:45.269752+00	81	errors	[]
10	1	3	3	1	Escalate	2025-10-04 14:51:45.269752+00	2025-10-04 14:52:44.370027+00	1	somethign	[]
12	5	1	2	3	Forward	2025-10-04 15:44:26.547413+00	2025-10-05 06:36:06.967636+00	892	new	[{"url": "/sd.pdf"}]
17	11	1	2	3	Forward	2025-10-05 07:44:57.702968+00	2025-10-05 08:24:20.378416+00	39	yea	\N
16	9	1	2	3	Forward	2025-10-05 07:26:40.272918+00	2025-10-05 08:24:28.716925+00	58	ys	\N
15	7	1	2	3	Forward	2025-10-05 07:12:52.011945+00	2025-10-05 08:24:35.674034+00	72	yeah	[{"url": "/new.pdf"}]
18	11	2	3	1	Escalate	2025-10-05 08:24:20.378416+00	2025-10-05 08:24:54.792932+00	1	for closing	\N
20	7	2	3	1	Escalate	2025-10-05 08:24:35.674034+00	2025-10-05 08:25:00.161864+00	0	CLOSE	\N
22	7	3	1	1	Dispatch	2025-10-05 08:25:00.161864+00	\N	\N	{"remarks":"Approved & Dispatched","signature":"data:image/png;base64,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"}	\N
21	11	3	1	1	Dispatch	2025-10-05 08:24:54.792932+00	2025-10-05 08:25:27.818171+00	1	{"remarks":"Approved & Dispatched","signature":"data:image/png;base64,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"}	\N
23	11	4	1	1	Dispatch	2025-10-05 08:25:27.818171+00	\N	\N	{"remarks":"Approved & Dispatched","signature":"data:image/png;base64,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"}	\N
19	9	2	3	1	Escalate	2025-10-05 08:24:28.716925+00	2025-10-05 08:28:39.116037+00	4	to close	\N
13	6	1	1	3	Forward	2025-10-05 06:12:34.481244+00	2025-10-05 08:34:46.120137+00	142	SOMETHING	[{"url": "/new.pdf"}]
9	3	4	1	3	Forward	2025-10-04 14:33:25.091577+00	2025-10-05 08:34:50.616615+00	1082	bad file	[]
2	2	1	2	3	Forward	2025-10-04 01:53:46.400097+00	2025-10-05 08:34:57.71466+00	1841	SOMETHING	[{"url": "/sm.pdf"}]
27	2	2	3	1	Escalate	2025-10-05 08:34:57.71466+00	\N	\N	som	\N
25	6	2	3	1	Escalate	2025-10-05 08:34:46.120137+00	2025-10-05 08:37:19.806791+00	3	some	\N
28	6	3	1	1	Dispatch	2025-10-05 08:37:19.806791+00	\N	\N	{"remarks":"Approved & Dispatched","signature":"data:image/png;base64,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"}	\N
14	5	2	3	3	Dispatch	2025-10-05 06:36:06.967636+00	2025-10-05 09:07:56.795935+00	152	cloe	[]
31	5	3	3	3	SLAReason	2025-10-05 09:07:56.795935+00	2025-10-05 09:08:06.244885+00	0	yeah	\N
32	5	4	3	3	SLAReason	2025-10-05 09:08:06.244885+00	\N	\N	somthing bad	\N
11	1	4	1	3	Return	2025-10-04 14:52:44.370027+00	2025-10-05 09:08:10.039632+00	1095	yeah it's bad	[]
33	1	5	3	3	SLAReason	2025-10-05 09:08:10.039632+00	\N	\N	very bad	\N
34	8	1	3	\N	SLAReason	2025-10-05 09:11:53.849074+00	\N	\N	oh messed up	\N
35	12	1	1	3	Forward	2025-10-05 09:40:53.939061+00	\N	\N	oh yeah forgot	\N
24	9	3	1	1	Dispatch	2025-10-05 08:28:39.116037+00	2025-10-05 14:07:17.012649+00	339	{"remarks":"Approved & Dispatched","signature":"data:image/png;base64,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"}	\N
36	9	4	1	1	Escalate	2025-10-05 14:07:17.012649+00	2025-10-05 14:07:38.783286+00	0	SOME REASON	\N
37	9	5	4	4	Dispatch	2025-10-05 14:07:38.783286+00	\N	\N	{"remarks":"SOME REASON","signature":"data:image/png;base64,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"}	\N
38	13	1	2	3	Forward	2025-10-05 14:38:23.559069+00	2025-10-05 14:41:48.444362+00	3	ssss	\N
39	13	2	3	1	Escalate	2025-10-05 14:41:48.444362+00	2025-10-05 14:43:14.113274+00	1	ddddsd	\N
40	13	3	1	1	Dispatch	2025-10-05 14:43:14.113274+00	\N	\N	{"remarks":"Approved & Dispatched","signature":"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAcAAAACgCAYAAACbprydAAAQAElEQVR4Aeydz28jyXXH36sm9Ws0VPfOSOTa8Y/dschde0+OkQRIEPuee85BAuRi5GIEyC1BcgsC33wL4AC55R/I1c4hP5DA8MHY9ZCa9XrtZJfUzJikNPpJdlXeq2ZTlEYzkkZks8X+9nR1N7urq159ilNfvarqpiEsIAACIAACIFBAAhDAAlY6igwCIAACIEAEASzytwBlBwEQAIECE4AAFrjyUXQQAAEQKDIBCGCRax9lLzIBlB0ECk8AAlj4rwAAgAAIgEAxCUAAi1nvKDUIgECRCaDsngAE0GPABgRA4DICq9Xto7DWcFGtYS+7jnMgcJcJQADvcu3BdhCYIQEVvRU2K5zkMdolH7AFgUUgUFABXISqQxlAYDYEos1GHNUaTlIfiZ4jZ0k/yymsILA4BCCAi1OXKAkI3JbA96W701Jw9nywE+3rtlvc222a2yaO+0EgbwTwpc5bjcCemRNABi8TiKrvqdf3PXH5ZE2un7KLex0IX0ID20UkAAFcxFpFmUDg+gS+H73dsMRu3BY4WbrtJh983ipdPxnEBIG7R2D8pb97psNiEACB2xC4X/Vjfd8jRyOvz1E8iG2v01rgduE2xHDvohHAF33RahTlAYFrENio1W2JJ8b6yDkd69t7/iQgLCBQEAIQwIJUNIoJAkog3Hp3GFUb0t/JI69Pz/Kw14bXpyQQFpvAxdJBAC8SwefcEVh/+GgY1rbjqFq36rmENX0wu64PZ0vQ/etDKA1+JEH2NhTPZ/3Bu8PcFTIDg6Jaw7IpB0mHp9Mcxetrcrf9uKwfEECgaAQggEWr8QzLe+/eOweVzW27UW3YSMRLBGgkWCpg1w/lUilgMoaY2W9Il9SB0f3rA48uy96v5XI5EDEQWxIbwqoKaMNWtlRgHw009UUKla33BlpeKZOSkB1RbHnYbWOGp4eBTWEJmMKWvIgFz6DMleo7g1AEL6w13NL9pbUgMGyY5B/Logawbm4cvL8yustZctaRo5hcbN2VwVoni8TXdZTG5C41TExlQ6WSikVUqzstQ1RtuPBhPaY7ukS1hg2MG8/mFI7e69vbbcLru6N1CrOnRwACOD2WhU2pUnsUi1hI92LDBbxUYiZZz3BIo+s/iAolwkXOxTS07pgG4oVIF5x2w70+9Npn1/Wh7H6nabpPm2Zvt3Vl6EscfZ5NJ3mk+Z3unx5SLDaILTQyMNklWyIpBMnCRFxiI0LiBTHcali6I4vaLKZKCWQrqx2SFY74Py8ssIKAEsB/BqWAcCmBler2cVTbHoabjXhDGv6kK1O7MxtOPSMfaiJ6VDLSyp4TPSvCEttj7WZjaXS9yPU6LdNX4WqLaLU/Dnq95tKlGWdw8uDgk3vdp2KD2NLtJOKa2Nlid2wH1g1F6KxL5VBNkjKSuIiswuKDdJmu1BrHei1PIXz47qHal9qkZei2m9x/1gzSc9iDAAjQ2TRowACB+1X/XJjVxlPDKptl+YoEHJAxRtp+9m6RbkmOkkDJoo2sdk2enopzZ62IhyPDK0Hkx9e0O7E+HnPTtK8VpPsx8qHuwq1te1/GspLcZrvt9XaW+p2Pg257xySi2GQviFrIyawN8yrRcijdpWKnXVv70uHk5ayPK9X394Wr5VJZzEpyt2SdliH5hC0IgMAkATP5AcfFIqBT4sPqto1UZMSTKzHp94HppUUG3LwvpAqggdJew3FMvYkN8dJSIpeGRB1YZJJZ4rAeyP6GK0t8H5jYGC4ZV5IGXoS07jbE+1pff/S5xMhk9YI48hRjEgdRPFxKUJBYR7pZrqytRiKG2k1aqby/TxktYfjVflSTsT6260RiCSXL6WAw6IuIJ5+wLTQBFP5SAubSszi5cARW3n77OKxtxxURjkga6ajWcGzKAbPx7Xda4FGbrrv4uP/i2Dqycs0Rs7T3LIcaiJItvXZxetVvRC1k9C8W4Tg4Pbr2uJ8dWsne6aIpTQQm0UMur5dqWg7xwGyWjzbstX8R9EZdp4NhHJN4WTRemNgQB2t2XW2riOc6vjTtg/X1b2vZeWW5IkmzhHT1E10Onv9ibl3MqSHYg0CeCZg8Gwfbbk5gbe0rh6EIXVQbjdXVGk4aSbfqKstMxgSGpaGUldJFFcq6eBBbnSAicqcnVO2ClY31FcMk3xFmvUMDjRaN5EQSJYhv6JyK1fCA2ppGGnptGVtLvCbT6+yYPRGO09/86tqNcv/ZjheaXqflxxA1XbJxIshqwMgWJuayPtqQeLLSFflb/dGlme9ePHtS0q5Ste1weHqqik3CJc04MIbVww6nKIRhbVsfa7DR+hd/rGVP89K6UzskSJ2Nz+IABEDgFQQK8h/lFaVfkNOTszCXKyurLEJHRNI2kl/GB/JJdcPJojMgpaEUYWkxxdYFZeNnOrKR+yTeaEu+LR/dpI8d6AQRvU/FrddusQSjQcVqf7/5tt46y9DdfSJjc02TTlwR5Y2d2qeZsm6Ilyv3KqGMPS4/+OqJP5PR5uTZJ8v9jtgmXOJD80LsSiwTu1iEMNQ/Rqp1u7HxtRs/a/jWW+//SoTPj88yGX2sQVIlv+jYq9ZJFz9Z5HlgAwLXJWCuGxHx8kVgo/ooDhOPxwVUEkeNvJemVvpWVzcSpH/OOTuIfQPZbopgSei0zJBK+tiC1TQoKMn3gPVWH8SrI7LWe4ReaNSLk3u6T5tGJ4j4SDnZ9HY/LvXEPnu09MTJkprFzLRWXl4Kq3W3vPUoUyFUG/b2fn5f7DIne8dH0gGsp0gJsyxmNZCxzLr1J1+zicSTD2viydcazi3ZLzFpNdPZEpPTeu1B+M6Y4AgEbkBAGr4bxEbUuRC491Z9uFFtjMbvGv4RBMMlw9qinrPIOR23U+8sFa69tojW7i9KaTSdoBFJg1oKqMREzLJRL0+8FUq9QvHouLu7E9AdWvr9n233VKRF5NUjSk1nZlozpaWwdrXgpPdMc394+OlaV7pwhwf2QNKVP0lklQMS9FoXdGGJqnXv5WkdERnDRLLSxCL3W07GUeUPkokLOAQBELghAQjgDYFlET3c1McR6k4bQQ06s1JawtH4nVgwahKlKRTnwnovQD2Bbrtljo7+bzwFXmKOVxWAUDxGNkmD6r08UT4rrp6KpXgr3H368Z0SvXHhLhyoR6Q8nIsVkb/KxBxW627l7bf3/ImMN/v7O+tik5E6YjFKVqK0Lu49eO9I6tkLn5jJNLFoRGedO3X2RO73Xdbd3cfXHkedSAqHIAACFwiYC5/xcY4ENh5ux1Gt7vRBAqJz7SCRiJUP0iK6ofPdk+rp9To7r61DFT6fJrEskoysInrOe3ntFvfbd8vTE/OvvfY6T0RwmqzdwHqTAlh1lfsV4ayf5xViUbQ070i88aWyW5HPvsKlekk92JNS6T9U8Hri0fZ2W+ags6NxJBrWmxFAbBB4NYHXNp6vvg1XbkNgo9b4K2n4kufvxCsTkfLenikZqQ8WqVP/zLl4aK1OptCGUD0HHzoyhvesdaWntlHb9h4Fi/ARMemiwqdp9duvF02Nu0hBu4HJ6eMKSamC0vjVZsJIOFWl21HqIZpxCEXspN6dZC/1nNgyudVXCPS84DXN4f9++PuT13AMAiAwfQKX/kecfjZIcZJAv938e2mQrdcl0Sb2B2kMR/GBO+hJd+bes51AJ1OkV66z39hKJk2YyQkTzvlu0v6CCZ9Obgm3Hsn4aD2OtrZtWJWyV3WMtO5SsfGiJsJDHARn/NgfylZW6VxmZl8FLKdnGDRpyeFsVXdPP7E71T9Mek/xqjLFgQAC0yJwVToQwKsIzeh6t/OkNHTS2fVS+kyle+aeeAo2rNXthowHvhTlwonV1S8eherFSEMvPuS4nbU0Gh/stO5MPYdh41S7KL2gSfmVgwTxkOt+8k8qaHpOJ7ewKQWGZTTNyJZJ/xGN9Ix0Yd28Pngd0s2sw4QZsT0e6tirCl/389byxCUcggAIZETgzjSMGfHINJv9TivQbi/p8/TDexcy12acTUD++Txt8JMgQiBClxyLtyPHKxvrKyzL5P36QLZxTCqM+vaXLIIKdiRCvFFtiDe2LV28SddiWG24sHpmd1h7LxE0sX2yHHrMK1QOtCtYBU2VjGgkYbKTNf1EF5eReCWdx6R/WvgzQ2ftYDiMT/ZeHHelezENJH8cJElItGM78GIk3cvT3pOY4m1W25MMSUxye7uflkcfsQMBEJgTATOnfJHtiIB2e40bXWmg6YQH0ohLqzyK8NJuoiV96drZCcPEJKKoq7pIWQTJUlfWvHm0JSZiH2RDyaKjnERnn+kVSwJBaIiKkAiWtc7poxqDYRxXlo//LBUzvx+Jl3Qdc6/TNKOZoGa/sxO8ePZx6fDw8tmxJHaI6I4fE6EpLPc3G4Oolgg+MZ8VVApk3dD2dos1BjsFpEgCBGZCAAI4E6xvnmi3+3hJGnE/e9E37O0mdx+UvnHk7Ak5EQCftLSkfk9yanSQh52a5U1M2nwvXYldelaCE4c38XcdWRvT0J6eutiJB3ayd3gk5X1XAqehp2Vvt1j2wmPH9HdbRh/VePHsSenTTz/9YZL0m23HKPV2q5vbB/F840i8Wn3GkihlIHUkqz4Qr3/o6Eu1CQsIgEAuCEAAc1ENVxjx4YcfrRAvEbNvVb3OSKN6LKIo3s5YMFLhmNvee2H63s7H3iYRcr8Xe4yKmHw2OiMz+bwT7LU/Dg5+0yrp22UOD3+9JhQ+kTDz9Qtf+O014rOvvhOX9TaZynhlHFYbmsxZopKgvh+1JyIuwegD8XIqyxV5gQAIXEHg3H/YK+Li8hwIbG5+fT2S7jSWxWcv6idC4r2iow6eDfNMbrBZevDl4yP74oCJOb2tHJf01xTSj9feV7ZknFPqhowfsPT3OTeaeCTCp+9H9SexAQEQyCUBCGAuqyUxav3h14ZDE+8TJW21aJ/TbjTC8kYE9KXh98qrEzMuE7F6+vSjF9dJ0M+2rdVtJN2cGgKjrmNSN+KQO3fc2bvqxQTXyQdxQODWBJDAtQhAAK+FKftI0WbDlktBMNI+GsqgmXalZW/JYuSos1MDKvnvu/whQe547b+7VzwXGYZhX19Ll75UwM+2pTPPUck4Sy55WUHL9Hq9DT2HAAIgcDcI+AbhbphaHCvDWsPSWPqI9AXX+x08JP2m3wARPye6xXq/E1dN/pDgXu+nv6ufJ0MylqceXjKDk1eqFX0tnSH19JKYcr8cWHc6OI1lLJN7u01z05cVSAJYQQAEckBgQQUwB2TfwIS1ta8cateatNSySgLOOW1kX/WCa4mB9RUEouib/xlWG767UsTPx7LirYn4nfvOq4cnf3A45Z6M5amHl+DXm6QKyFrn4kE8fv+qeo4Hzz+Z6qMTmhcCCIBAtgTONQbZZo3cJgnoG1+WKyures6RI+uGttu5O29wUbvzEMJw+zSs1h0tH/yeSNlIyRyJhMV98dbUxuWH75yI4HlxVA9vFEkvwc4vyQAAD/NJREFUiX/od87GZPWPj16nxf3dltl7/iTwV7ABARBYGAJmYUpyhwsSbjWsvvElLYI7ssN+ZzF+migt06z3/pc0qg3HK6bMnEiac46s/CnRbbe413lS2hDO6u2tlZaWxJ4kkhyo6klML3g6yUiEz/TxXk5PBhsQWGQCEMA5125Yq1s2lDTGMsBkBs9a/f4TvCbrmvWifzyIN+eMvj4toejvPD11sXpvgjR5h2it4YxwHkeRCxJRu5h/xwtke3F/FkrKiRUEQOASAuaScziVEYGN2qMB08hdUU+l0+Tnz583Msr+TmcT+WfwxOMzxOOCiMt3bPZ33SkNlpaSnzwKSGVvHEOcPXELT3a7qacnV/5HAtaFIYCCgMD1CZjrR0XMaRMwFIwnUnTbeD/kVXxX335/Vz1m9fhE10bCJ52XMsIn2ueIHa3E97d4idSDHl3XVK07HJ76nxzScdVut/uWnkUAARAoNgEI4JzqPwy3T2nkvOgzfoTltQSi2rZdsXaTKfWY0+hMRs6xLESGickvTrbOJjM39Y+Lk2efTDwALxexggAILByBmxbI3PQGxJ8OAV426qX4xPbxjJ/ncNkm3Bo9yjAhbpfFG5+LYx3X4167yb1dzNwcc8EBCIDASwQggC8hmf2Jler2ceqp6C8izD7Hu5fDRvVr/pcV2KSkXi6DjOaRtc4dEZ10RfB8ePrEvBwTZ0AABEDgZQJoLF5mMvMzKyyjVKNc9tpTfNxhlOZd3q3WGs+jasMZDl76bjqSf6J4yavHxMPrNP0zesft5spdLjNsBwEQmA+BlxqZ+ZhRrFx57NToSFWxyn6xtFH0rX8Lq8mvKkS1uhMle2uMZxRZ37fpjmnofwVjdwevHhtxwQ4EQOB2BCCAt+P3pndzciMXUgH1rTcidjasNRwt7/8hsxEespKGhIzfjiax9HabptdrjsdM/TVsLhLAZxAAgRsSgADeENg0ozuyCy+AUfTuRiJ4yWSWSLs3AzJEftomnVtkUE96OP0kFj+eh0ks5/DgAwiAwHQJSEM03QSR2usJLG89OkljnPQPT9PjRdpXHugEFunWFLGj5XLPBCp4lLh3ydYXV/RO9s45O/S/rNAdvXdTTmIFARC4CQHEfSMC5o3uwk1vTGCVS/oeSrnf0aL8yoN6eGFVPLxqw/+qQlDWCSzSrTkhdlLg8SqK59xxZ6/XaXK33TK93Y9L44s4AAEQAIGMCEAAMwKt2UTV7ZhHomBjsnruLoao+rVhVGv4MTzZO/XwpFw88vEuLZIjZ323ZrvJvc6OjOnhx2MvBYWTIAACmRFYEAHMjNdtMvo2sfG8nfT99Z+2gtsklvG939moPorDkYdHHKjtzFcYYZ1/E8sfqfD12neqvFeUDJdBAAQWgYBvkBehIHkvQ6XW+FFqI5+WP0+P87zf2KzbqFbXX1P4keGSuUrxdEZPbP2P+FZV9Pod/yaWf81zGWEbCIBAcQlAADOq+2Cix7Pb/fALGWV7rWzWH7w7DGvbcWWrbiub2yJ6yVieCVTyxM+T9VUJqejJNZ25ud2T7s29Xf8jvrtyLrMVGYEACIDAmxCAAL4JtVvc46T78xa33+rWaPNRHNXEqxt1ZUa1ROjK5XLAZEwgPl4gG7pykRE9Z1X0WEVPvD39Hj258jZEAAEQAIEcEdCGK0fmwJRpEgj1DStV6cIcCR0FJalv8epe49Fdnn/i59mke1NnbrJOZLk8Ls6CQJYEkBcIvDkBaRDf/GbcmS8C9+595WcbtbMuTGbDJHqXWil+G6mUiRPqKB6qnulMVD2VRjm/l4gaqdtuieg1/Xs3z0fAJxAAARC4uwQggJnV3fRR33vw7mCj2ohT0Vu6v/KBIRG9C2US4XOD4TDuiZDRMQ1Z38Am3qBhVqP4XHSJbEUbpVuT8WD6OTL4AAIgkDMCtzVHG8DbpoH7r0EgfekZE18Zu1J7FOvv4IU17b68LCRjd0vlcskwmUnRU3dOgtOfWfIi1m7y0XAwKAWB0TE/XqES0ZlbKHFJFne6f3ro43eapv9sJ5BzWEEABEBgoQlAALOuXtE/FaLXhYBE14yqFIt1lwU5PbGqiDknA3QcH+ikFAnmlEqDqFb3MzrXSktLLEt6i8Yfyg0qeBKXZW8ODj65l17HHgRAAASKQMAUoZB5KGNfPCvpXVTtuZY5GlG8RqfP1V0M4t7Z4QH9e7etrxJrsopYr7NjTnpHQVRN3tCySrRMqqE0WiRBSU/fxrKk8fc7eDB9RAY7EACBghKAAGZY8YP9wdE4OxGk8bEciEcWiyem3pgPKlL9TtPoc3UXQ+9pM9jfb/6B3Eb37r1zkHp6KxvrK8TErBdGQX9Lr9te/0K302RJL5DTAwlYQQAEQKDwBCCAGX4Fkm5GN5a+0+Xyj9MPJeYgrDVcpfaN9lUmVSrv7+sYYSTxl+4vrRGd0zyd6emGB/ZABVV/S4/oJ3fizTOE5SYEEBcEQOCWBCCAtwR409vjw1Lf3yNu2tLJ4Dv20OzJcJzXQTlFAQ2rUbXuHj784EMfb2Kjb2qJqg0XrNl1NqTRJ66SE/fyxIteu2n293fWJy/iGARAAARA4DwBc/4jPs2awN7eR1E8tPr8nc8qWIsr7B9d8BpIfhGHLi4Nvh7V0hmgyazPwMiFVPY0unMyRng8VNGTYI7bzRV/PzYgAAKLTQClmwoBCOBUMN4skb1nO4FOZEnuEkWTlV5y6EgWvaBBDmVVzSPfg2pjHdPrdloyRvhpWS5hBQEQAAEQuCEBCOANgU0ruk5kEa+NBwMX+9mhqm6T4ZKMVAqHRINue6d0yWWcAgEQAAEQuAGBOyqANyhhzqO+eN4q9dotk3h0TR7v23IswRn7S53VkhajxFyOag23sVm3m5sf/CQ9jz0IgAAIgMDNCEAAb8Yr89i9z3beUVE0g+AH0vspPqKsYoUJmIfB4JteDLfqVk5hBQEQAAEQuAEBCOANYM0z6vPnH/1Fr9M03XaLZRxQtPDMGmOYVQjDWt0+ePD+z86uLOYRSgUCIAAC0yAAAZwGxYzT0Mkv+qC8i+lQxHCcOxOzLdsPomrdRZsN9Qqj8UUcgAAIgAAInCMAATyH42596D1t3hMx5FWz9jdENukb1SIwEwUkXmH9N1E1GS+s1b7xt3oJAQTuNgFYDwLTIwABnB7LuaX02Wc//btue0e6R5s8JHc6oYRETKTjhSc0/GvtJpVgw6339wkLCIAACBScAARwwb4A++3WsnaPVkP+c6e/EHGmhmlJmY1dFyF0oXiHla36UMNGrX66/vDr7bfe2v6HNCL2IAACIJAnAtO2BQI4baI5Se/x48f/2OvsmF4neZwidvyJCuKkeb6n1HAQSDDE5XIprrol85dRTcYQa8nbZ5Jj/fxyUAGVIB5lY/hWbfuzRqPxx5Pp4xgEQAAE8kzA5Nk42DY9Anudx++qIOrD9xqs46E+gJ9MJ03dxHTPExnr8eVBBVQCs6HAkXl7t0//EqlwimepY486K1VDpdo42qi+d3AxrNfqP5jICIcgAAIgkCkBCGCmuG+Z2RRv73cel/UB/MRDbLGKYred7IfLJ/9ETM+ss4PY0vCyQNY6EU9ZLzFqpJdMzBoCphXDbu1iKBN/NxJvU71IFcxXBBvWGieX5IJTIAACIHArAhDAW+FbzJv3P/3ln3Y/b272OztLe7vN8mWhu+u7V42ONybimXS1DuPg56J7OhHHi2PiU+r2YkjZqUSSbOQzXxpERGkpSjzL06j6/n9JLKwgAAIgcGsCEMBbI0QCkwT2n3709e7nj3UijhfHRCDVs7wYEsG0hn4tSun8694uaqT/LFfTDJjKjuJvpR8LtkdxQQAEpkwAAjhloEjuZgT6nzW/3Os0jb7u7WJwzH9CzDyZIjMPJj/jGARAAATelAAE8E3J4b4MCFj1ASfycUclQ9+dOIFDECgGAZRyJgQggDPBikSnQaDXbv3z5Phit91ae/pZ84fTSBtpgAAIgAAEEN8BEAABEACBQhK4IwJYyLpBoUEABEAABGZIAAI4Q7hIGgRAAARAIL8EIID5rRtYNiKAHQiAAAjMggAEcBZUkSYIgAAIgEDuCUAAc19FMBAEikwAZQeB2RGAAM6OLVIGARAAARDIMQEIYI4rB6aBAAiAQJEJzLrsEMBZE0b6IAACIAACuSQAAcxltcAoEAABEACBWROAAM6a8G3Sx70gAAIgAAIzIwABnBlaJAwCIAACIJBnAhDAPNcObCsyAZQdBEBgxgQggDMGjORBAARAAATySQACmM96gVUgAAJFJoCyZ0IAApgJZmQCAiAAAiCQNwIQwLzVCOwBARAAARDIhEBOBTCTsiMTEAABEACBAhOAABa48lF0EAABECgyAQhgkWs/p2WHWSAAAiCQBQEIYBaUkQcIgAAIgEDuCEAAc1clMAgEikwAZQeB7AhAALNjjZxAAARAAARyRAACmKPKgCkgAAIgUGQCWZcdApg1ceQHAiAAAiCQCwIQwFxUA4wAARAAARDImgAEMGvir8sP10AABEAABDIjAAHMDDUyAgEQAAEQyBMBCGCeagO2FJkAyg4CIJAxAQhgxsCRHQiAAAiAQD4IQADzUQ+wAgRAoMgEUPa5EIAAzgU7MgUBEAABEJg3AQjgvGsA+YMACIAACMyFQE4EcC5lR6YgAAIgAAIFJgABLHDlo+ggAAIgUGQCEMAi135Oyg4zQAAEQGAeBCCA86COPEEABEAABOZOAAI49yqAASBQZAIoOwjMjwAEcH7skTMIgAAIgMAcCUAA5wgfWYMACIBAkQnMu+wQwHnXAPIHARAAARCYCwEI4FywI1MQAAEQAIF5E4AAzrMGkDcIgAAIgMDcCEAA54YeGYMACIAACMyTAARwnvSRd5EJoOwgAAJzJgABnHMFIHsQAAEQAIH5EIAAzoc7cgUBECgyAZQ9FwQggLmoBhgBAiAAAiCQNQEIYNbEkR8IgAAIgEAuCMxJAHNRdhgBAiAAAiBQYAIQwAJXPooOAiAAAkUmAAEscu3PqezIFgRAAATyQAACmIdagA0gAAIgAAKZE4AAZo4cGYJAkQmg7CCQHwIQwPzUBSwBARAAARDIkAAEMEPYyAoEQAAEikwgb2WHAOatRmAPCIAACIBAJgQggJlgRiYgAAIgAAJ5IwABzLJGkBcIgAAIgEBuCEAAc1MVMAQEQAAEQCBLAhDALGkjryITQNlBAARyRgACmLMKgTkgAAIgAALZEIAAZsMZuYAACBSZAMqeSwIQwFxWC4wCARAAARCYNQEI4KwJI30QAAEQAIFcEshIAHNZdhgFAiAAAiBQYAIQwAJXPooOAiAAAkUmAAEscu1nVHZkAwIgAAJ5JAABzGOtwCYQAAEQAIGZE4AAzhwxMgCBIhNA2UEgvwQggPmtG1gGAiAAAiAwQwIQwBnCRdIgAAIgUGQCeS/7/wMAAP//Zb2/wgAAAAZJREFUAwD+jIsE5+5thwAAAABJRU5ErkJggg=="}	\N
26	3	5	3	1	Escalate	2025-10-05 08:34:50.616615+00	2025-10-06 04:43:58.131452+00	925	some	\N
41	3	6	4	4	Dispatch	2025-10-06 04:43:58.131452+00	\N	\N	{"remarks":"Approved & Dispatched som reason","signature":"data:image/png;base64,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"}	\N
42	14	1	2	3	Forward	2025-10-06 04:59:53.488645+00	\N	\N	sla test	\N
43	15	1	2	3	Forward	2025-10-06 05:18:52.100582+00	\N	\N		\N
44	16	1	1	3	Forward	2025-10-06 06:36:00.564465+00	\N	\N	remarks	\N
45	17	1	1	3	Forward	2025-10-08 02:51:50.03566+00	\N	\N	new routine file 	\N
\.


--
-- Data for Name: file_share_tokens; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.file_share_tokens (file_id, token_hash, updated_at, token, created_by, created_at, last_used_at) FROM stdin;
4	c990d45c646d7b4131eaa7a5915bdb53b06c7e8644d9799f9b484e2fddba3109	2025-10-05 05:49:32.671618+00	tLYpK7R2p1JChbhJzPURmAO7kJNTJGIx	2	2025-10-05 05:49:32.671618+00	2025-10-05 09:39:11.173219+00
12	06caf049c9000ef64ebe8af81d7f4a3f75de120ed2ae4cbb87281e724c723a74	2025-10-05 14:07:25.937544+00	VPACEtknyernJGCr3M-RB6yajwfHDFFS	4	2025-10-05 09:50:23.872442+00	2025-10-05 14:16:20.363142+00
13	7e55652795cea7467ea5aee65d7808eca0c6731f558942bc55bb9e4e669d3517	2025-10-06 04:55:39.392078+00	BBKcHcRpY5gRIObP7-7nPUp2Fe_VS0Ga	2	2025-10-05 14:38:39.533886+00	2025-10-06 04:59:29.047412+00
15	b5c6e0e32a418e99cc3ffc2bd9528d293a07ef7c8efec315d342b1caaf5e92c3	2025-10-06 06:29:54.26507+00	D_LbkazKwVlYbQH8sMzFVn6szAIEmNkV	1	2025-10-06 06:29:54.26507+00	\N
16	7ddf258bbc5faadd4e4c3a56528708d879f18a6bdce66acce4ed8173bb53e917	2025-10-06 06:36:06.875348+00	YxN1AcpKq177bZNIrD903lnkNKU0AKO7	1	2025-10-06 06:36:06.875348+00	2025-10-06 06:36:55.868031+00
5	a42e56437f433f20ce858d02e72ebd7eecb0e856081f08409f0d2612e7a0fea8	2025-10-05 05:52:07.960221+00	vOC73QcUDzGFOs089z-hDXcNb8agHnu0	2	2025-10-05 05:47:45.886985+00	2025-10-05 05:52:17.255744+00
\.


--
-- Data for Name: files; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.files (id, file_no, subject, notesheet_title, owning_office_id, category_id, date_initiated, date_received_accounts, current_holder_user_id, status, confidentiality, sla_policy_id, created_by, created_at, sla_consumed_minutes, sla_percent, sla_status, sla_remaining_minutes, sla_last_warning_at, sla_last_escalated_at) FROM stdin;
6	ACC-20251005-01	create file	my file	1	1	2025-10-05	2025-10-05	1	Dispatched	f	2	1	2025-10-05 06:12:34.478008+00	145	30	On-track	335	\N	\N
14	ACC-20251006-01	test  sla	test sla	1	1	2025-10-06	2025-10-05	3	WithOfficer	f	2	2	2025-10-06 04:59:53.484314+00	0	0	On-track	480	\N	\N
15	ACC-20251006-02	sda	sad	1	1	2025-10-06	2025-10-06	3	WithOfficer	t	1	2	2025-10-06 05:18:52.097187+00	0	0	On-track	1440	\N	\N
5	ACC-20251004-05	new file audit log check	audit log check	1	1	2025-10-04	2025-10-04	3	Closed	t	2	2	2025-10-04 15:44:26.54448+00	1044	100	Breach	0	\N	\N
1	ACC-20251004-01	FILE 01	NOTESHEET 01	1	1	2025-10-04	2025-10-05	3	WithOfficer	t	2	2	2025-10-04 01:46:57.615997+00	1800	100	Breach	0	\N	\N
8	ACC-20251005-03	something	new	1	1	2025-10-05	2025-10-05	\N	Open	t	2	2	2025-10-05 07:25:27.126273+00	0	0	On-track	480	\N	\N
12	ACC-20251005-06	draft	draft	1	1	2025-10-05	2025-10-05	3	WithOfficer	f	2	1	2025-10-05 09:39:39.945807+00	0	0	On-track	480	\N	\N
16	ACC-20251006-03	ss	sss	1	1	2025-10-06	2025-10-06	3	WithOfficer	t	2	1	2025-10-06 06:36:00.560417+00	0	0	On-track	480	\N	\N
7	ACC-20251005-02	file 2 	file 2 	2	1	2025-10-05	2025-10-06	1	Dispatched	t	1	2	2025-10-05 07:12:52.006296+00	72	5	On-track	1368	\N	\N
9	ACC-20251005-04	urgent test	urgent	1	1	2025-10-05	2025-10-05	4	Dispatched	f	2	2	2025-10-05 07:26:40.270968+00	401	84	Warning	79	\N	\N
11	ACC-20251005-05	draft check	draft new 	1	1	2025-10-05	2025-10-05	1	Dispatched	f	2	2	2025-10-05 07:39:11.544353+00	41	9	On-track	439	\N	\N
4	ACC-20251004-04	NEW DRAFT TRY	draft file 	1	1	2025-10-04	2025-10-04	\N	Open	t	2	2	2025-10-04 15:11:22.795242+00	0	0	On-track	480	\N	\N
17	ACC-20251008-01	file time check	file time	1	1	2025-10-08	2025-10-08	3	WithOfficer	f	1	1	2025-10-08 02:51:50.029691+00	0	0	On-track	1440	\N	\N
3	ACC-20251004-03	yeah	something	1	1	2025-10-04	2025-10-04	4	Dispatched	f	2	2	2025-10-04 02:53:40.875365+00	2625	100	Breach	0	\N	\N
13	ACC-20251005-07	sdfd	sdofjddo	1	1	2025-10-05	2025-10-05	1	Dispatched	t	2	2	2025-10-05 14:38:23.555674+00	561	100	Breach	0	\N	\N
2	ACC-20251004-02	FILE 02	FILE 02	1	1	2025-10-04	2025-10-04	1	WithCOF	t	1	2	2025-10-04 01:53:46.398072+00	1841	100	Breach	0	\N	\N
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
1	office A
2	office B
\.


--
-- Data for Name: query_threads; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.query_threads (id, file_id, initiator_user_id, target_user_id, query_text, response_text, created_at, resolved_at, status) FROM stdin;
\.


--
-- Data for Name: sla_notifications; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.sla_notifications (id, file_id, event_type, payload, created_at, processed, processed_at) FROM stdin;
\.


--
-- Data for Name: sla_policies; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.sla_policies (id, category_id, sla_minutes, name, warning_pct, escalate_pct, pause_on_hold, notify_role, notify_user_id, notify_channel, auto_escalate, active, description, created_at, updated_at, priority) FROM stdin;
1	1	1440	Budget - Routine (3 business days)	70	100	t	AccountsOfficer	\N	\N	f	t	Routine SLA for Budget	2025-10-03 16:51:58.609755+00	2025-10-03 16:51:58.609755+00	Routine
2	1	480	Budget - Urgent (1 business day)	70	100	t	AccountsOfficer	\N	\N	f	t	Urgent SLA for Budget	2025-10-03 16:59:12.428045+00	2025-10-03 16:59:12.428045+00	Urgent
3	1	240	Budget - Critical (half day)	70	100	t	AccountsOfficer	\N	\N	t	t	Critical SLA for Budget	2025-10-03 16:59:12.430711+00	2025-10-03 16:59:12.430711+00	Critical
4	2	1440	Audit - Routine (3 business days)	70	100	t	AccountsOfficer	\N	\N	f	t	Routine SLA for Audit	2025-10-03 16:59:33.101492+00	2025-10-03 16:59:33.101492+00	Routine
5	2	480	Audit - Urgent (1 business day)	70	100	t	AccountsOfficer	\N	\N	f	t	Urgent SLA for Audit	2025-10-03 16:59:33.103888+00	2025-10-03 16:59:33.103888+00	Urgent
6	2	240	Audit - Critical (half day)	70	100	t	AccountsOfficer	\N	\N	t	t	Critical SLA for Audit	2025-10-03 16:59:33.104834+00	2025-10-03 16:59:33.104834+00	Critical
7	3	1440	Salary - Routine (3 business days)	70	100	t	AccountsOfficer	\N	\N	f	t	Routine SLA for Salary	2025-10-03 16:59:48.007121+00	2025-10-03 16:59:48.007121+00	Routine
8	3	480	Salary - Urgent (1 business day)	70	100	t	AccountsOfficer	\N	\N	f	t	Urgent SLA for Salary	2025-10-03 16:59:48.009654+00	2025-10-03 16:59:48.009654+00	Urgent
9	3	240	Salary - Critical (half day)	70	100	t	AccountsOfficer	\N	\N	t	t	Critical SLA for Salary	2025-10-03 16:59:48.010369+00	2025-10-03 16:59:48.010369+00	Critical
10	4	1440	Procurement - Routine (3 business days)	70	100	t	AccountsOfficer	\N	\N	f	t	Routine SLA for Procurement	2025-10-03 17:00:02.88787+00	2025-10-03 17:00:02.88787+00	Routine
11	4	480	Procurement - Urgent (1 business day)	70	100	t	AccountsOfficer	\N	\N	f	t	Urgent SLA for Procurement	2025-10-03 17:00:02.890196+00	2025-10-03 17:00:02.890196+00	Urgent
12	4	240	Procurement - Critical (half day)	70	100	t	AccountsOfficer	\N	\N	t	t	Critical SLA for Procurement	2025-10-03 17:00:02.89095+00	2025-10-03 17:00:02.89095+00	Critical
13	5	1440	Misc - Routine (3 business days)	70	100	t	AccountsOfficer	\N	\N	f	t	Routine SLA for Misc	2025-10-03 17:00:13.059874+00	2025-10-03 17:00:13.059874+00	Routine
14	5	480	Misc - Urgent (1 business day)	70	100	t	AccountsOfficer	\N	\N	f	t	Urgent SLA for Misc	2025-10-03 17:00:13.062351+00	2025-10-03 17:00:13.062351+00	Urgent
15	5	240	Misc - Critical (half day)	70	100	t	AccountsOfficer	\N	\N	t	t	Critical SLA for Misc	2025-10-03 17:00:13.063411+00	2025-10-03 17:00:13.063411+00	Critical
\.


--
-- Data for Name: users; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.users (id, username, name, office_id, role, password_hash, email) FROM stdin;
1	cof	COF User	1	COF	$2a$10$p4uF8HoOmt7Ey5EzzeuWOOpg9Z4qTgUS3mXsqVEEFOrnJuOAryBgy	cof@example.com
2	clerk	Clerk Office A	1	Clerk	$2a$10$7xY/xxJfrg/E3Rr/q7ccrOilLAcw9ngluLmTy8lgt.BUzMMohx9xe	clerk@example.com
3	officer	Officer Office A	1	AccountsOfficer	$2a$10$DVEdVamVg74CbkSF4gt4d.zTUPkvOMwih3NYIHfk5kAsYFT6LKI5O	officer@example.com
4	admin	Admin Office A	1	Admin	$2a$10$OEf7MFOmtaL7opg3Wvn2EOe5/5pCdWcjTY1h5EWpjyR82OHLfp3j2	admin@example.com
\.


--
-- Data for Name: working_hours; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.working_hours (id, weekday, start_time, end_time) FROM stdin;
1	6	00:00:00	23:59:59
2	0	00:00:00	23:59:59
3	2	10:00:00	17:00:00
4	5	10:00:00	17:00:00
5	4	10:00:00	17:00:00
6	1	10:00:00	17:00:00
7	3	10:00:00	17:00:00
\.


--
-- Name: attachments_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.attachments_id_seq', 1, false);


--
-- Name: audit_logs_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.audit_logs_id_seq', 2660, true);


--
-- Name: categories_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.categories_id_seq', 5, true);


--
-- Name: file_events_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.file_events_id_seq', 45, true);


--
-- Name: files_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.files_id_seq', 17, true);


--
-- Name: holidays_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.holidays_id_seq', 1, false);


--
-- Name: offices_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.offices_id_seq', 2, true);


--
-- Name: query_threads_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.query_threads_id_seq', 1, false);


--
-- Name: sla_notifications_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.sla_notifications_id_seq', 1, false);


--
-- Name: sla_policies_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.sla_policies_id_seq', 15, true);


--
-- Name: users_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.users_id_seq', 4, true);


--
-- Name: working_hours_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.working_hours_id_seq', 7, true);


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
-- Name: file_share_tokens file_share_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.file_share_tokens
    ADD CONSTRAINT file_share_tokens_pkey PRIMARY KEY (file_id);


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
-- Name: sla_notifications sla_notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sla_notifications
    ADD CONSTRAINT sla_notifications_pkey PRIMARY KEY (id);


--
-- Name: sla_policies sla_policies_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sla_policies
    ADD CONSTRAINT sla_policies_pkey PRIMARY KEY (id);


--
-- Name: sla_policies uq_sla_policies_category_priority; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sla_policies
    ADD CONSTRAINT uq_sla_policies_category_priority UNIQUE (category_id, priority);


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
-- Name: idx_files_sla_remaining; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_files_sla_remaining ON public.files USING btree (sla_remaining_minutes);


--
-- Name: idx_files_sla_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_files_sla_status ON public.files USING btree (sla_status);


--
-- Name: idx_files_status_holder; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_files_status_holder ON public.files USING btree (status, current_holder_user_id);


--
-- Name: idx_query_threads_file_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_query_threads_file_id ON public.query_threads USING btree (file_id);


--
-- Name: idx_sla_notifications_file_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_sla_notifications_file_id ON public.sla_notifications USING btree (file_id);


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
-- Name: ux_file_share_tokens_hash; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX ux_file_share_tokens_hash ON public.file_share_tokens USING btree (token_hash);


--
-- Name: file_events trigger_update_business_minutes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trigger_update_business_minutes BEFORE INSERT OR UPDATE OF ended_at ON public.file_events FOR EACH ROW EXECUTE FUNCTION public.update_business_minutes();


--
-- Name: file_events trigger_update_file_sla; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trigger_update_file_sla AFTER INSERT OR UPDATE ON public.file_events FOR EACH ROW EXECUTE FUNCTION public.file_events_after_change();


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
-- Name: file_share_tokens file_share_tokens_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.file_share_tokens
    ADD CONSTRAINT file_share_tokens_file_id_fkey FOREIGN KEY (file_id) REFERENCES public.files(id) ON DELETE CASCADE;


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
-- Name: sla_notifications sla_notifications_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sla_notifications
    ADD CONSTRAINT sla_notifications_file_id_fkey FOREIGN KEY (file_id) REFERENCES public.files(id) ON DELETE CASCADE;


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

\unrestrict ZnfcOClpmdA4ZfbPj4dLDiJmGEOAx5wfJQIWE743c4XdJ9N1jsDT640pChZYQpx

