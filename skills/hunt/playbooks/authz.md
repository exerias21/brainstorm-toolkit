# Playbook: authz — broken access control / IDOR / missing role checks

## What this hunts

Routes and handlers that operate on a resource without verifying the
caller is allowed to touch *this specific* resource. Two sub-shapes:

1. **Vertical authz break** — low-priv user reaches an admin-only path.
2. **Horizontal authz break (IDOR)** — user A reaches user B's resource
   by changing an ID in the URL or body.

## Sweep targets

- Route handlers (use the threat model's entry-point list, or grep
  framework decorators directly).
- ORM lookups by primary key: `findById`, `get_object_or_404`, `Model.find`,
  `Repository.findOne`, `Where(id=...).First()`.
- Path/query/body params named `id`, `userId`, `accountId`, `orderId`,
  `tenantId`, `*_id`, `uuid`.

## Vulnerable shape

```python
# Flask
@app.get("/orders/<int:order_id>")
def get_order(order_id):
    return Order.query.get(order_id)  # no owner check
```

```javascript
// Express
app.get("/api/users/:id", async (req, res) => {
  const user = await User.findByPk(req.params.id);
  res.json(user);  // any authenticated user can read any user
});
```

## Safe shape (suppression)

```python
@app.get("/orders/<int:order_id>")
@login_required
def get_order(order_id):
    order = Order.query.get(order_id)
    if order.owner_id != current_user.id and not current_user.is_admin:
        abort(404)  # 404, not 403, to avoid existence oracle
    return order
```

Or the centralized policy pattern:
```python
order = require_can_view(current_user, Order, order_id)
```

## Suppression rules

- Handler is behind a role guard middleware that *also* enforces ownership
  (e.g. `@admin_required` + the resource is global).
- Resource is scoped by the auth subject implicitly:
  `current_user.orders.find(id)` (the query itself excludes other users).
- Endpoint is internal-only and not routed publicly (check ingress
  config, not just comments).

## Trace direction

Source → sink doesn't apply here. Instead:
1. Start at each handler.
2. List the lookups by id.
3. For each lookup, ask: does the code that follows check ownership /
   role *between* the lookup and the response?
4. If no check, confidence depends on whether auth itself is required
   (anon-reachable = 10; authed = 9; authed+role-guarded = 8 if the
   role guard is wrong shape, drop to 7 if it's right shape).

## Fix vocabulary

Centralize: a `require_can_*(actor, resource)` policy module. The fix
*adds the check* — but the durable fix is to migrate the lookup to a
scoped query (`actor.orders.find(id)`) so the bug class can't recur.
Codify the safe shape in `/codify` to sweep fleet-wide.
