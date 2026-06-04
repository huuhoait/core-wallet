-- Test Data for Outbox Relay Service
-- This file is loaded automatically by docker-compose.test.yml

-- Insert sample events for testing
-- These events will be processed by the outbox relay service

-- Insert 10 transaction events
SELECT public.insert_test_events(10, 'transactions.posted');

-- Insert 5 withdrawal events
SELECT public.insert_test_events(5, 'withdrawals.posted');

-- Insert 3 reversal events
SELECT public.insert_test_events(3, 'reversals.posted');

-- Insert 2 custom events with specific payloads
INSERT INTO public.wlt_outbox (event_uuid, event_type, payload) VALUES
(
    gen_random_uuid(),
    'custom.event',
    jsonb_build_object(
        'event_id', 'CUSTOM-001',
        'source', 'test-script',
        'data', jsonb_build_object(
            'message', 'This is a custom test event',
            'priority', 'high'
        )
    )
),
(
    gen_random_uuid(),
    'custom.event',
    jsonb_build_object(
        'event_id', 'CUSTOM-002',
        'source', 'test-script',
        'data', jsonb_build_object(
            'message', 'Another custom test event',
            'priority', 'low'
        )
    )
);

-- Log data insertion
DO $$
DECLARE
    v_total INT;
BEGIN
    SELECT COUNT(*) INTO v_total FROM public.wlt_outbox;
    RAISE NOTICE 'Test data inserted successfully. Total events: %', v_total;
END $$;