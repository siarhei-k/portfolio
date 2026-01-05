/* * Project: Marketplace Data Mart Development & Ad-hoc Analysis
 * Objective: Building a comprehensive user-profile data mart for the "VseTut" marketplace 
 * and performing exploratory data analysis to solve business-critical tasks.
 */

---

/* Part 1. Data Mart Development */

-- 0. Preliminary Calculation: Identify Top-3 regions by order volume.
-- This subset will be used to filter the user base for further analysis.
WITH top_regions AS (
    SELECT
        region,
        COUNT(*) AS region_orders
    FROM ds_ecom.orders o
    LEFT JOIN ds_ecom.users u ON o.buyer_id = u.buyer_id
    GROUP BY region
    ORDER BY region_orders DESC
    LIMIT 3
),

-- Step 1. Payment Analysis
-- Identifying payment methods (money transfers, promo codes, or installments).
-- Using window functions to analyze payment composition within individual orders.
order_payments_info AS (
    SELECT DISTINCT
        order_id,
        -- Check if the primary payment (sequential = 1) was a "money transfer"
        CASE
            WHEN (FIRST_VALUE(payment_type) OVER (
                    PARTITION BY order_id 
                    ORDER BY payment_sequential)
                    ) = 'money transfer' -- (Money Transfer)
                THEN 1
            ELSE 0
        END AS used_money_transfer,
        -- Flag orders where at least one promo code was applied
        CASE
            WHEN (COUNT(*) FILTER (WHERE payment_type = 'promocode') OVER (
                    PARTITION BY order_id)
                    ) >= 1
                THEN 1
            ELSE 0
        END AS order_with_promo,
        -- Flag installment usage (installments > 1)
        CASE
            WHEN MAX(payment_installments) OVER (PARTITION BY order_id) > 1
                THEN 1
            ELSE 0
        END AS used_installments
    FROM ds_ecom.order_payments
),

-- Step 2. Order Financials
-- Calculating total costs (price + delivery) strictly for 'Delivered' orders.
order_costs AS (
    SELECT
        o.order_id,
        COALESCE(SUM(oi.price + oi.delivery_cost)::numeric, 0) AS total_order_costs
    FROM ds_ecom.orders o
    LEFT JOIN ds_ecom.order_items oi ON o.order_id = oi.order_id
    WHERE o.order_status = 'Delivered' -- Filtering for Delivered status per requirements
    GROUP BY o.order_id
),

-- Step 3. Rating Normalization
-- Consolidating heterogeneous rating scales (1-5 and 10-50) into a unified 1-5 format.
reviews_info AS (
    SELECT
        order_id,
        AVG(CASE 
            WHEN review_score > 5 THEN review_score::numeric / 10.0 
            ELSE review_score::numeric
        END) AS avg_order_rating
    FROM ds_ecom.order_reviews
    WHERE review_score IS NOT NULL
    GROUP BY order_id
),

-- Step 4. User Profile Aggregation
-- Merging user data with order history and calculated metrics.
users_orders AS (
    SELECT
        u.user_id,
        u.region,
        -- Time-based metrics
        MIN(order_purchase_ts) AS first_order_ts,
        MAX(order_purchase_ts) AS last_order_ts,
        MAX(order_purchase_ts) - MIN(order_purchase_ts) AS lifetime,
        COUNT(o.order_id) AS total_orders,
        
        -- Rating metrics
        AVG(ri.avg_order_rating) AS avg_order_rating,
        COUNT(*) FILTER (WHERE ri.avg_order_rating IS NOT NULL) AS num_orders_with_rating,
        
        -- Order statuses
        COUNT(*) FILTER (WHERE o.order_status = 'Canceled') AS num_canceled_orders,
        
        -- Financial metrics
        SUM(oc.total_order_costs) AS total_order_costs,
        AVG(oc.total_order_costs) AS avg_order_cost,
        
        -- Payment behavioral features
        SUM(op.used_installments) AS num_installment_orders,
        SUM(op.order_with_promo) AS num_orders_with_promo,
        SUM(op.used_money_transfer) AS sum_used_money_transfer,
        SUM(op.used_installments) AS sum_used_installments
    FROM ds_ecom.users u
    LEFT JOIN ds_ecom.orders o ON u.buyer_id = o.buyer_id
    LEFT JOIN reviews_info ri ON ri.order_id = o.order_id
    LEFT JOIN order_costs oc ON o.order_id = oc.order_id
    LEFT JOIN order_payments_info op ON o.order_id = op.order_id
    WHERE 
        o.order_status IN ('Delivered', 'Canceled') 
        AND u.region IN (SELECT region FROM top_regions)
    GROUP BY u.user_id, u.region
)

-- Final Data Mart Output
SELECT
    uo.user_id,
    uo.region,
    uo.first_order_ts,
    uo.last_order_ts,
    uo.lifetime,
    uo.total_orders,
    uo.avg_order_rating,
    uo.num_orders_with_rating,
    uo.num_canceled_orders,
    -- Cancellation ratio (percentage)
    ROUND(uo.num_canceled_orders::numeric / uo.total_orders * 100, 3) AS canceled_orders_ratio,
    
    COALESCE(uo.total_order_costs, 0) AS total_order_costs, 
    COALESCE(uo.avg_order_cost, 0) AS avg_order_cost,
    
    uo.num_installment_orders,
    uo.num_orders_with_promo,
    
    -- Binary flags for behavior analysis
    CASE WHEN uo.sum_used_money_transfer > 0 THEN 1 ELSE 0 END AS used_money_transfer,
    CASE WHEN uo.sum_used_installments > 0 THEN 1 ELSE 0 END AS used_installments,
    CASE WHEN uo.num_canceled_orders > 0 THEN 1 ELSE 0 END AS used_cancel
FROM users_orders uo;

---

/* Part 2. Ad-hoc Analysis */

/* Task 1. User Segmentation 
 * Segregate users by order frequency to identify loyalty patterns.
 */

WITH users_segments AS (
    SELECT
        user_id,
        CASE
            WHEN SUM(total_orders) = 1 THEN '1 order'
            WHEN SUM(total_orders) BETWEEN 2 AND 5 THEN '2–5 orders'
            WHEN SUM(total_orders) BETWEEN 6 AND 10 THEN '6–10 orders'
            WHEN SUM(total_orders) >= 11 THEN '11+ orders'
        END AS segment,
        SUM(total_order_costs) AS total_order_costs,
        SUM(total_orders) AS total_orders
    FROM ds_ecom.product_user_features
    GROUP BY user_id
)
SELECT
    segment,
    COUNT(user_id) AS users,
    ROUND(AVG(total_orders), 3) AS avg_orders,
    ROUND(SUM(total_order_costs) / SUM(total_orders), 3) AS avg_order_cost
FROM users_segments
GROUP BY segment
ORDER BY MIN(total_orders);

-- CONCLUSION 1:
-- The vast majority of users (~60k vs ~2k) are one-time purchasers. Retention is extremely low.
-- Inverse correlation detected: as order frequency increases, Average Order Value (AOV) decreases.
-- The marketplace currently acts as a destination for one-off high-ticket item purchases.

---

/* Task 2. High-Value User Ranking
 * Identify the top 15 users with 3+ orders, ranked by their Average Order Value.
 */

SELECT
    user_id,
    SUM(total_orders) AS orders,
    ROUND(SUM(total_order_costs) / SUM(total_orders), 2) AS avg_order_costs
FROM ds_ecom.product_user_features
GROUP BY user_id
HAVING SUM(total_orders) >= 3
ORDER BY avg_order_costs DESC
LIMIT 15;

-- CONCLUSION 2:
-- Even among high-value users, activity is minimal: 13 of the top 15 did exactly 3 orders.
-- The most "active" user in this list (5 orders) sits in the middle of the ranking with an AOV nearly 50% lower than the leader.

---

/* Task 3. Regional Performance Statistics 
 * Comparative analysis of Top-3 regions across volume, cost, and payment behavior.
 */

SELECT
    region,
    COUNT(user_id) AS users,
    SUM(total_orders) AS orders,
    ROUND(SUM(total_order_costs) / SUM(total_orders), 3) AS avg_order_cost,
    ROUND(SUM(num_installment_orders)::numeric / SUM(total_orders), 3) AS installments_orders_share,
    ROUND(SUM(num_orders_with_promo)::numeric / SUM(total_orders), 3) AS promo_orders_share,
    ROUND(SUM(used_cancel)::numeric / COUNT(user_id), 3) AS cancel_users_share
FROM ds_ecom.product_user_features
GROUP BY region;

-- CONCLUSION 3:
-- Moscow dominates in volume (3.5x more users than others) but yields the lowest AOV.
-- St. Petersburg leads in AOV (~3593 RUB) and promo code engagement.
-- Installments are significantly more popular in St. Petersburg and Novosibirsk (>54%) compared to Moscow (<48%).
-- Order cancellation rates are remarkably low across all regions (under 1%).

---

/* Task 4. 2023 Cohort Activity
 * Analyzing user behavior based on their first purchase month in 2023.
 */

WITH users_first_month AS (
    SELECT
        user_id,
        DATE_TRUNC('month', MIN(first_order_ts)) AS first_order,
        SUM(total_orders) AS orders,
        SUM(total_order_costs) AS total_order_costs,
        AVG(avg_order_rating) AS avg_order_rating,
        MAX(used_money_transfer) AS used_money_transfer,
        AVG(lifetime) AS lifetime
    FROM ds_ecom.product_user_features
    GROUP BY user_id
    HAVING EXTRACT(YEAR FROM MIN(first_order_ts)) = 2023
)
SELECT
    first_order,
    COUNT(user_id) AS users,
    SUM(orders) AS orders,
    ROUND(SUM(total_order_costs) / SUM(orders), 3) AS avg_order_costs,
    ROUND(AVG(avg_order_rating), 3) AS avg_order_rating,
    ROUND(SUM(used_money_transfer)::numeric / COUNT(user_id), 3) AS money_transfer_share,
    AVG(lifetime) AS avg_lifetime
FROM users_first_month
GROUP BY first_order
ORDER BY first_order;

-- CONCLUSION 4:
-- Explosive growth in Customer Acquisition (CAC) towards Q4: November's cohort is 10x larger than January's.
-- Autumn/Winter cohorts spend more per order but provide lower ratings, suggesting service/logistics strain during peak seasons.
-- Customer Lifetime (LT) is declining; even early cohorts (January) remained active for less than two weeks, highlighting a systemic retention issue.