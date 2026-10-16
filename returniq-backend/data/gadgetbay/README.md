# Challenge 10 – What Came Back
**Gadgetbay**  ·  Data snapshot: morning of 2026-11-16; history up to 2026-11-15

## Files

### `inventory.csv`  (88 rows)

`sku`, `new_stock`, `avg_daily_demand`

### `liquidation.csv`  (24 rows)

`category`, `condition_grade`, `recovery_pct_of_cost`

### `products.csv`  (88 rows)

`sku`, `product`, `category`, `cost_price`, `selling_price`, `supplier`

### `refurbishment.csv`  (6 rows)

`category`, `refurb_cost`, `days_required`, `resale_pct_of_new`

### `returns.csv`  (918 rows)

`return_id`, `date_received`, `sku`, `supplier_batch`, `reason_code`, `condition_grade`, `status`

### `sales.csv`  (5,838 rows)

`date`, `sku`, `qty_sold`, `selling_price`

### `vendor_terms.csv`  (88 rows)

`supplier`, `sku`, `rtv_allowed`, `credit_pct`, `window_days`

## Notes

- `returns.csv` `status`: Processed, Awaiting decision, Queued for liquidation, In refurbishment queue.
- Vendor `window_days` counts from `date_received`.
- Liquidation recovery and vendor credit are fractions of cost price; refurbished resale is a fraction of new selling price.

At hour 14 an updated version of one of these files will be released. Same columns, same format.