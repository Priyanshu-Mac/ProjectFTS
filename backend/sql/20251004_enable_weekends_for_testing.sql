-- Make calculate_business_minutes respect working_hours only (no hardcoded weekend skip)
-- and add weekend working hours for testing so consumption increases on Saturday/Sunday.

CREATE OR REPLACE FUNCTION public.calculate_business_minutes(start_ts timestamp with time zone, end_ts timestamp with time zone)
RETURNS integer
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

-- Enable weekends for testing: add Saturday(6) and Sunday(0) full-day hours if missing
INSERT INTO public.working_hours(weekday, start_time, end_time)
SELECT 6, '00:00:00'::time, '23:59:59'::time
WHERE NOT EXISTS (SELECT 1 FROM public.working_hours WHERE weekday = 6);

INSERT INTO public.working_hours(weekday, start_time, end_time)
SELECT 0, '00:00:00'::time, '23:59:59'::time
WHERE NOT EXISTS (SELECT 1 FROM public.working_hours WHERE weekday = 0);
