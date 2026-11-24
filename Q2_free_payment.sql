/* =====================================================================
   ICT371  QUESTION 2 - University Fee Payments                   [50]
   ===================================================================== */
DROP SCHEMA IF EXISTS q2 CASCADE;
CREATE SCHEMA q2;
SET search_path TO q2, public;

-- Test helper (not part of the marked answer)
CREATE PROCEDURE expect_error(p_sql text) LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RAISE NOTICE 'UNEXPECTED: statement succeeded -> %', p_sql;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'Rejected as expected -> %', SQLERRM;
END $$;


/* ---------------------------------------------------------------------
   (a) DATABASE AND SEED DATA                                       [6]
   - student_number is UNIQUE (the UQ in the brief).
   - amount > 0 is a CHECK, so even direct SQL cannot store a zero or
     negative payment.
   - "No credit balances" (total paid > fee_due) involves two tables, so a
     CHECK constraint cannot enforce it; the procedure in (c) does, while
     holding a lock on the student row.
   - Payments are loaded through pr_receive_payment AFTER the trigger
     exists, so every payment also gets its audit row.
   --------------------------------------------------------------------- */
CREATE TABLE students (
    student_id      INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_number  VARCHAR(20)   NOT NULL UNIQUE,
    full_name       VARCHAR(100)  NOT NULL,
    fee_due         NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id  INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id  INTEGER       NOT NULL REFERENCES students (student_id),
    amount      NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on     DATE          NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE payment_audit (
    audit_id    INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    payment_id  INTEGER       NOT NULL REFERENCES payments (payment_id),
    student_id  INTEGER       NOT NULL REFERENCES students (student_id),
    amount      NUMERIC(12,2) NOT NULL,
    logged_at   TIMESTAMPTZ   NOT NULL DEFAULT now()
);

CREATE TABLE daily_collections (
    collection_date  DATE          PRIMARY KEY,
    payment_count    INTEGER       NOT NULL CHECK (payment_count >= 0),
    total_amount     NUMERIC(14,2) NOT NULL CHECK (total_amount >= 0)
);

-- Three students with DIFFERENT fee balances
INSERT INTO students (student_number, full_name, fee_due) VALUES
    ('2023010101', 'Mwila Banda',    15000.00),   -- will settle in full
    ('2023010102', 'Chanda Phiri',   12000.00),   -- will part-pay
    ('2023010103', 'Natasha Zulu',    9000.00);   -- NO payments at all


/* ---------------------------------------------------------------------
   (b) FUNCTION fn_fee_balance                                      [6]
   - Unknown student -> exception (IF NOT FOUND after SELECT INTO).
   - SUM() over zero rows returns NULL, not 0. COALESCE(...,0) turns it
     into 0, so a student with no payments gets the FULL fee back.
     Without COALESCE, fee_due - NULL = NULL (a classic mistake).
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_fee  students.fee_due%TYPE;
    v_paid NUMERIC(12,2);
BEGIN
    SELECT fee_due INTO v_fee
    FROM   students
    WHERE  student_id = p_student_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student id %', p_student_id;
    END IF;

    SELECT COALESCE(SUM(amount), 0) INTO v_paid
    FROM   payments
    WHERE  student_id = p_student_id;

    RETURN v_fee - v_paid;
END;
$$;


/* ---------------------------------------------------------------------
   (c) PROCEDURE pr_receive_payment                                 [8]
   - Order of checks: amount (NULL / zero / negative) -> date -> student
     exists -> amount not above balance.
   - FOR UPDATE on the student row: two cashiers receiving payments for the
     same student at the same time are processed one after the other, so
     together they cannot push the student into credit.
   - Only an INSERT into payments. fee_due is never touched (the balance
     is always derived: fee_due - SUM(payments)).
   - NO audit insert here: the trigger in (d) does that.
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE pr_receive_payment(
    p_student_id INTEGER,
    p_amount     NUMERIC,
    p_paid_on    DATE DEFAULT CURRENT_DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_balance NUMERIC(12,2);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Invalid payment amount %: must be greater than zero', p_amount;
    END IF;
    IF p_amount <> round(p_amount, 2) THEN
        RAISE EXCEPTION 'Invalid payment amount %: at most 2 decimal places', p_amount;
    END IF;
    IF p_paid_on IS NULL OR p_paid_on > CURRENT_DATE THEN
        RAISE EXCEPTION 'Invalid payment date %', p_paid_on;
    END IF;

    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student id %', p_student_id;
    END IF;

    v_balance := fn_fee_balance(p_student_id);

    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment of K% exceeds outstanding balance of K% for student %',
                        p_amount, v_balance, p_student_id;
    END IF;

    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, p_paid_on);
END;
$$;


/* ---------------------------------------------------------------------
   (d) TRIGGER: AFTER INSERT, FOR EACH ROW, on payments              [8]
   - NEW holds the inserted payment, including the generated payment_id
     (available in an AFTER trigger).
   - Because the audit lives in the trigger, ANY insert into payments is
     audited: through the procedure or through direct SQL.
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION trg_fn_payments_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, now());
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_payments_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_payments_audit();


-- (a) continued: six payments through the procedure ------------------
CALL pr_receive_payment(1, 5000.00, CURRENT_DATE - 3);
CALL pr_receive_payment(2, 3000.00, CURRENT_DATE - 3);
CALL pr_receive_payment(1, 4000.00, CURRENT_DATE - 2);
CALL pr_receive_payment(2, 2500.00, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 1500.00, CURRENT_DATE - 1);
CALL pr_receive_payment(1, 6000.00, CURRENT_DATE - 1);   -- Mwila now fully paid

SELECT * FROM payments ORDER BY payment_id;

-- Tests for (b)
SELECT student_id, full_name, fee_due, fn_fee_balance(student_id) AS balance
FROM   students ORDER BY student_id;      -- 0.00 / 5000.00 / 9000.00 (full fee)
CALL expect_error('SELECT fn_fee_balance(999)');

-- Tests for (c)
CALL expect_error('CALL pr_receive_payment(2, NULL, CURRENT_DATE)');
CALL expect_error('CALL pr_receive_payment(2, 0, CURRENT_DATE)');
CALL expect_error('CALL pr_receive_payment(2, -50, CURRENT_DATE)');
CALL expect_error('CALL pr_receive_payment(2, 5000.01, CURRENT_DATE)');  -- over balance
CALL expect_error('CALL pr_receive_payment(1, 1, CURRENT_DATE)');        -- settled
SELECT fee_due FROM students WHERE student_id = 2;   -- still 12000.00, never changed

-- Tests for (d): one audit row per payment, procedure or direct SQL
SELECT * FROM payment_audit ORDER BY audit_id;       -- 6 rows
INSERT INTO payments (student_id, amount, paid_on) VALUES (3, 1000.00, CURRENT_DATE);
SELECT * FROM payment_audit ORDER BY audit_id DESC LIMIT 1;   -- written by trigger


/* ---------------------------------------------------------------------
   (e) VIEW v_fee_balances                                          [5]
   - LEFT JOIN keeps students with no payments (their total is NULL ->
     COALESCE -> 0). An INNER JOIN would wrongly hide them.
   - Payments are summed in a sub-query first, then joined: one row per
     student.
   - WHERE balance > 0 excludes fully settled students.
   --------------------------------------------------------------------- */
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number,
       s.full_name,
       s.fee_due - COALESCE(p.total_paid, 0) AS outstanding_balance
FROM   students s
LEFT JOIN (SELECT student_id, SUM(amount) AS total_paid
           FROM   payments
           GROUP  BY student_id) p
       ON p.student_id = s.student_id
WHERE  s.fee_due - COALESCE(p.total_paid, 0) > 0;

SELECT * FROM v_fee_balances ORDER BY student_number;   -- Mwila (settled) is absent


/* ---------------------------------------------------------------------
   (f) COMPOSITE INDEX                                               [5]
   Query: WHERE student_id = ? AND paid_on BETWEEN ? AND ?
   - student_id (equality) first, paid_on (range) second: all of one
     student's payments sit together in the index in date order, so the
     range is read as one contiguous slice.
   - (paid_on, student_id) would be worse: it would read every student's
     payments in the date range, then discard the other students.
   - It also serves fn_fee_balance (WHERE student_id = ?) and FK checks.
   - EXPLAIN note: tiny table -> seq scan is cheaper; enable_seqscan off
     shows the index plan the planner uses on real volumes.
   --------------------------------------------------------------------- */
CREATE INDEX idx_payments_student_paidon ON payments (student_id, paid_on);
ANALYZE payments;

EXPLAIN
SELECT payment_id, amount, paid_on
FROM   payments
WHERE  student_id = 2
AND    paid_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;

SET enable_seqscan = off;
EXPLAIN ANALYZE
SELECT payment_id, amount, paid_on
FROM   payments
WHERE  student_id = 2
AND    paid_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;


/* ---------------------------------------------------------------------
   (g) SCHEDULED JOB                                                 [6]
   - COUNT(*) and SUM over that day's payments; a day with no payments
     stores 0 and 0.00.
   - ON CONFLICT ... DO UPDATE replaces an existing summary row for that
     date (rerun-safe). '0 1 * * *' = 01:00 every day.
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql
SET search_path = q2, public
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day must not be NULL';
    END IF;

    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0)
    FROM   payments
    WHERE  paid_on = p_day
    ON CONFLICT (collection_date) DO UPDATE
    SET    payment_count = EXCLUDED.payment_count,
           total_amount  = EXCLUDED.total_amount;
END;
$$;

CALL pr_refresh_collections(CURRENT_DATE - 1);
CALL pr_refresh_collections(CURRENT_DATE - 1);   -- rerun: replaced, not doubled
CALL pr_refresh_collections(CURRENT_DATE - 3);
SELECT * FROM daily_collections ORDER BY collection_date;

SELECT cron.schedule(
    'q2_refresh_collections',
    '0 1 * * *',
    $$CALL q2.pr_refresh_collections(CURRENT_DATE - 1)$$
);

SELECT jobid, jobname, schedule, command, active
FROM   cron.job
WHERE  jobname = 'q2_refresh_collections';
