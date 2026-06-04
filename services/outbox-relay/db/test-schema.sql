-- Test Schema for Outbox Relay Service
-- This file is loaded automatically by docker-compose.test.yml

-- Create WLT_OUTBOX table
CREATE TABLE IF NOT EXISTS public.wlt_outbox (
    id          BIGINT        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_uuid   UUID          NOT NULL UNIQUE,
    event_type   VARCHAR(64)   NOT NULL,
    payload     JSONB         NOT NULL,
    created_at   TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    processed_at TIMESTAMPTZ,
    retry_count  INT           NOT NULL DEFAULT 0
);

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_outbox_processed 
    ON public.wlt_outbox(processed_at) 
    WHERE processed_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_outbox_created 
    ON public.wlt_outbox(created_at);

-- Grant permissions
GRANT SELECT, INSERT, UPDATE ON public.wlt_outbox TO wallet_app;
GRANT USAGE, SELECT ON SEQUENCE public.wlt_outbox_id_seq TO wallet_app;

-- Create a function to insert test events
CREATE OR REPLACE FUNCTION public.insert_test_event(
    p_event_type VARCHAR,
    p_payload JSONB
) RETURNS UUID AS $$
DECLARE
    v_event_uuid UUID;
BEGIN
    v_event_uuid := gen_random_uuid();
    
    INSERT INTO public.wlt_outbox (event_uuid, event_type, payload)
    VALUES (v_event_uuid, p_event_type, p_payload);
    
    RETURN v_event_uuid;
END;
$$ LANGUAGE plpgsql;

-- Grant execute permission
GRANT EXECUTE ON FUNCTION public.insert_test_event TO wallet_app;

-- Create a function to insert multiple test events
CREATE OR REPLACE FUNCTION public.insert_test_events(
    p_count INT,
    p_event_type VARCHAR
) RETURNS INT AS $$
DECLARE
    v_inserted INT := 0;
    v_i INT;
BEGIN
    FOR v_i IN 1..p_count LOOP
        INSERT INTO public.wlt_outbox (event_uuid, event_type, payload)
        VALUES (
            gen_random_uuid(),
            p_event_type,
            jsonb_build_object(
                'test_id', v_i,
                'timestamp', NOW(),
                'data', jsonb_build_object(
                    'amount', (random() * 1000000)::int,
                    'account_no', '9701' || LPAD(v_i::text, 10, '0')
                )
            )
        );
        v_inserted := v_inserted + 1;
    END LOOP;
    
    RETURN v_inserted;
END;
$$ LANGUAGE plpgsql;

-- Grant execute permission
GRANT EXECUTE ON FUNCTION public.insert_test_events TO wallet_app;

-- Create a view to monitor outbox status
CREATE OR REPLACE VIEW public.v_outbox_status AS
SELECT 
    COUNT(*) FILTER (WHERE processed_at IS NULL) AS pending_events,
    COUNT(*) FILTER (WHERE processed_at IS NOT NULL) AS processed_events,
    COUNT(*) AS total_events,
    AVG(EXTRACT(EPOCH FROM (COALESCE(processed_at, NOW()) - created_at))) FILTER (WHERE processed_at IS NOT NULL) AS avg_processing_time_seconds,
    MAX(retry_count) AS max_retry_count
FROM public.wlt_outbox;

-- Grant select permission
GRANT SELECT ON public.v_outbox_status TO wallet_app;

-- Create a function to reset test data
CREATE OR REPLACE FUNCTION public.reset_test_data() RETURNS VOID AS $$
BEGIN
    TRUNCATE TABLE public.wlt_outbox RESTART IDENTITY CASCADE;
END;
$$ LANGUAGE plpgsql;

-- Grant execute permission
GRANT EXECUTE ON FUNCTION public.reset_test_data TO wallet_app;

-- Log schema creation
DO $$
BEGIN
    RAISE NOTICE 'Test schema created successfully';
END $$;