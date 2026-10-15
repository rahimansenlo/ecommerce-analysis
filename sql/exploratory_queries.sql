-- ============================================================
-- E-COMMERCE ANALYSIS — РАЗВЕДОЧНЫЕ SQL-ЗАПРОСЫ
-- База: ecommerce.db, таблица: transactions
-- Данные очищены в Python (см. notebook.ipynb) перед загрузкой в SQLite:
--   - удалены служебные StockCode (D, POST, M, BANK CHARGES и т.д.)
--   - удалены служебные записи в Description (check, damages, found и т.д.)
--   - удалены строки с нулевой/отрицательной ценой
--   - добавлены вычисляемые столбцы: Revenue (Quantity * UnitPrice), 
--     IsReturn (InvoiceNo начинается с 'C')
-- Период данных: 2010-12-01 — 2011-12-09 (последний месяц неполный)
-- ============================================================


-- ============================================================
-- ВОПРОС 1: Топ-страны и концентрация выручки
-- Какие страны приносят основную часть выручки, и насколько
-- бизнес зависит от одной-двух стран?
-- ============================================================

-- 1.1 Базовая выручка и количество заказов по странам
SELECT 
    Country,
    SUM(Revenue) as total_revenue,
    COUNT(DISTINCT InvoiceNo) as order_count
FROM transactions
GROUP BY Country
ORDER BY total_revenue DESC;

-- 1.2 Доля каждой страны от общей выручки (концентрация)
-- Результат: United Kingdom = 84.44% всей выручки
WITH country_revenue AS (
    SELECT 
        Country,
        SUM(Revenue) as total_revenue
    FROM transactions
    GROUP BY Country
)
SELECT 
    Country,
    total_revenue,
    ROUND(total_revenue * 100.0 / (SELECT SUM(total_revenue) FROM country_revenue), 2) as pct_of_total
FROM country_revenue
ORDER BY total_revenue DESC;

-- 1.3 Проверка: стабильна ли доля UK во времени, или это тренд?
-- Результат: доля колеблется 77-91% без явного тренда — структурная
-- характеристика бизнеса, а не временное явление
SELECT 
    strftime('%Y-%m', InvoiceDate) as month,
    SUM(CASE WHEN Country = 'United Kingdom' THEN Revenue ELSE 0 END) as uk_revenue,
    SUM(Revenue) as total_revenue,
    ROUND(SUM(CASE WHEN Country = 'United Kingdom' THEN Revenue ELSE 0 END) * 100.0 / SUM(Revenue), 2) as uk_pct
FROM transactions
GROUP BY month
ORDER BY month;


-- ============================================================
-- ВОПРОС 2: Сезонность
-- Есть ли выраженная сезонность в продажах, и в какие месяцы
-- бизнес особенно активен?
-- (использует тот же запрос 1.3 — total_revenue по месяцам)
-- Результат: выраженный пик сентябрь-ноябрь перед Рождеством,
-- выручка выросла почти вдвое к ноябрю (1.42M против ~500K в январе).
-- Декабрь 2011 в данных неполный (только 1-9 декабря).
-- ============================================================

-- Диапазон дат в датасете — важно для корректной интерпретации
-- последнего месяца (неполные данные)
SELECT MIN(InvoiceDate) as first_date, MAX(InvoiceDate) as last_date
FROM transactions;


-- ============================================================
-- ВОПРОС 3: Retention
-- Какая доля клиентов совершает повторные покупки, и сколько
-- в среднем покупок делает один клиент?
-- ВАЖНО: CustomerID IS NOT NULL обязателен — 135,080 строк (~25%)
-- не имеют CustomerID и должны быть исключены из клиентской аналитики.
-- Возвратные счета (IsReturn = 1) НЕ считаются заказами, а клиенты с
-- нулевой/отрицательной чистой выручкой исключены (как и в RFM, 4320 клиентов).
-- ============================================================

-- 3.1 Сегментация клиентов по числу заказов: доля клиентов и доля выручки
-- Результат (4320 клиентов):
--   1 покупка : 34.56% клиентов -> 6.50%  выручки
--   2-5 покупок: 45.42% клиентов -> 25.44% выручки
--   6+ покупок: 20.02% клиентов -> 68.06% выручки
-- Первая версия запроса считала возвратные счета (InvoiceNo на 'C') как заказы
-- и давала 30.42 / 45.12 / 24.46 % клиентов и 5.33 / 22.36 / 72.30 % выручки —
-- вывод про концентрацию выручки сохраняется, но цифры были завышены для 6+.
WITH customer_stats AS (
    SELECT 
        CustomerID,
        COUNT(DISTINCT CASE WHEN IsReturn = 0 THEN InvoiceNo END) AS order_count,
        SUM(Revenue) AS customer_revenue
    FROM transactions
    WHERE CustomerID IS NOT NULL
    GROUP BY CustomerID
    HAVING COUNT(DISTINCT CASE WHEN IsReturn = 0 THEN InvoiceNo END) >= 1
       AND SUM(Revenue) > 0.01
),
segmented AS (
    SELECT 
        CASE 
            WHEN order_count = 1 THEN '1. Одна покупка'
            WHEN order_count BETWEEN 2 AND 5 THEN '2. 2-5 покупок'
            ELSE '3. 6+ покупок'
        END AS customer_segment,
        customer_revenue
    FROM customer_stats
)
SELECT 
    customer_segment,
    COUNT(*) AS customer_count,
    ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM segmented), 2) AS pct_of_customers,
    ROUND(SUM(customer_revenue), 2) AS segment_revenue,
    ROUND(SUM(customer_revenue) * 100.0 / (SELECT SUM(customer_revenue) FROM segmented), 2) AS pct_of_revenue
FROM segmented
GROUP BY customer_segment
ORDER BY customer_segment;


-- ============================================================
-- ВОПРОС 5: Возвраты
-- Какую долю составляют возвраты по числу счетов и по деньгам,
-- и есть ли страны с аномально высокой долей?
-- ОГОВОРКА: мы измеряем долю ВОЗВРАТНЫХ СЧЕТОВ (InvoiceNo на 'C'), а не
-- "процент отменённых заказов": возврат может относиться к покупке
-- до 2010-12-01, которой нет в данных.
-- ============================================================

-- 5.0 Проверка качества: отрицательное Quantity бывает только у возвратных счетов
-- Результат: 0 (признак IsReturn надёжен)
SELECT COUNT(*) AS negative_qty_not_credit
FROM transactions
WHERE Quantity < 0 AND IsReturn = 0;

-- 5.1 Общий масштаб возвратов
-- Результат: 23230 счетов, 3454 возвратных (14.87%);
-- валовые продажи 10 296 944.57, возвраты 714 005.77 (6.93% по сумме)
SELECT 
    COUNT(DISTINCT InvoiceNo) AS total_invoices,
    COUNT(DISTINCT CASE WHEN IsReturn = 1 THEN InvoiceNo END) AS return_invoices,
    ROUND(COUNT(DISTINCT CASE WHEN IsReturn = 1 THEN InvoiceNo END) * 100.0 
          / COUNT(DISTINCT InvoiceNo), 2) AS pct_return_invoices,
    ROUND(SUM(CASE WHEN IsReturn = 0 THEN Revenue ELSE 0 END), 2) AS gross_sales,
    ROUND(-SUM(CASE WHEN IsReturn = 1 THEN Revenue ELSE 0 END), 2) AS returned_value,
    ROUND(-SUM(CASE WHEN IsReturn = 1 THEN Revenue ELSE 0 END) * 100.0 
          / SUM(CASE WHEN IsReturn = 0 THEN Revenue ELSE 0 END), 2) AS pct_value_returned
FROM transactions;

-- 5.2 Влияние двух гигантских пар "заказ + отмена" (74215 и 80995 единиц,
-- отменённые через 12-16 минут): они завышают и продажи, и возвраты
-- Результат: возвраты 714 005.77 всего, 468 352.57 без гигантов
-- (разница 245 653.20 = 34.4% всех возвратов). Доля по сумме без гигантов ~4.66%
SELECT 
    ROUND(-SUM(Revenue), 2) AS returned_value_total,
    ROUND(-SUM(CASE WHEN Quantity > -50000 THEN Revenue ELSE 0 END), 2) AS returned_value_without_giants
FROM transactions
WHERE IsReturn = 1;

-- 5.3 Возвраты по странам (только страны со 100+ счетов; Netherlands, 96 счетов, не попала)
-- Результат: Germany 23.36%, EIRE 18.73%, Belgium 16.24%, UK 14.60%, France 13.38%, Spain 12.00%
SELECT 
    Country,
    COUNT(DISTINCT InvoiceNo) AS total_invoices,
    COUNT(DISTINCT CASE WHEN IsReturn = 1 THEN InvoiceNo END) AS return_invoices,
    ROUND(COUNT(DISTINCT CASE WHEN IsReturn = 1 THEN InvoiceNo END) * 100.0 
          / COUNT(DISTINCT InvoiceNo), 2) AS pct_return_invoices
FROM transactions
GROUP BY Country
HAVING COUNT(DISTINCT InvoiceNo) >= 100
ORDER BY pct_return_invoices DESC;

-- 5.4 Кто создаёт возвраты в Германии: концентрация по клиентам
-- Результат: возвраты широко распределены. Топ-1 клиент даёт 13% возвратных счетов
-- (18 из 135), топ-10 около 58%. Это не проблема одного покупателя.
SELECT 
    CustomerID,
    COUNT(DISTINCT InvoiceNo) AS total_invoices,
    COUNT(DISTINCT CASE WHEN IsReturn = 1 THEN InvoiceNo END) AS return_invoices,
    ROUND(-SUM(CASE WHEN IsReturn = 1 THEN Revenue ELSE 0 END), 2) AS returned_value
FROM transactions
WHERE Country = 'Germany' AND CustomerID IS NOT NULL
GROUP BY CustomerID
ORDER BY return_invoices DESC
LIMIT 10;

-- 5.5 Доля возвратов по сумме и средний размер счёта (без двух гигантских пар)
-- Результат: Germany 2.32% по сумме при 23.36% по числу счетов; UK 5.11%; Spain 7.11%
-- (но у Spain всего 100 счетов). Средний счёт на покупку у Germany 464.04.
SELECT 
    Country,
    ROUND(SUM(CASE WHEN IsReturn = 0 THEN Revenue ELSE 0 END), 2) AS gross_sales,
    ROUND(-SUM(CASE WHEN IsReturn = 1 THEN Revenue ELSE 0 END), 2) AS returned_value,
    ROUND(-SUM(CASE WHEN IsReturn = 1 THEN Revenue ELSE 0 END) * 100.0 
          / SUM(CASE WHEN IsReturn = 0 THEN Revenue ELSE 0 END), 2) AS pct_value_returned,
    ROUND(SUM(CASE WHEN IsReturn = 0 THEN Revenue ELSE 0 END) * 1.0 
          / COUNT(DISTINCT CASE WHEN IsReturn = 0 THEN InvoiceNo END), 2) AS avg_purchase_invoice,
    ROUND(-SUM(CASE WHEN IsReturn = 1 THEN Revenue ELSE 0 END) * 1.0 
          / COUNT(DISTINCT CASE WHEN IsReturn = 1 THEN InvoiceNo END), 2) AS avg_return_invoice
FROM transactions
WHERE Country IN ('Germany','EIRE','Belgium','United Kingdom','France','Spain')
  AND ABS(Quantity) < 50000
GROUP BY Country
ORDER BY pct_value_returned DESC;
