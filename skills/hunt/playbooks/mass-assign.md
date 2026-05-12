# Playbook: mass-assign — over-posting / mass assignment

## What this hunts

Endpoints that bind a whole request body to a model object without an
allowlist of writable fields. The attacker sends an extra field
(`isAdmin: true`, `accountBalance: 9999999`, `userId: <victim>`) and
the ORM happily writes it.

## Sweep targets

| Framework | Vulnerable pattern | Safe pattern |
|---|---|---|
| Rails | `Model.new(params)` (params not `.permit`-ed), `update(params)` | `params.require(:model).permit(:safe_field)` |
| Django | `Model(**request.POST.dict())`, `serializer.save(**request.data)` | DRF `Serializer` with explicit `fields = [...]` (not `__all__`) |
| Flask + SQLAlchemy | `Model(**request.json)`, `user.update_from_dict(request.json)` | `marshmallow.Schema` with `Meta.fields = [...]` |
| Express + Mongoose | `Model.create(req.body)`, `Object.assign(user, req.body)` | Hand-picked: `{name, email}` destructure; or `mongoose` `select` w/ schema validation |
| Spring | `@ModelAttribute User user` (binds everything), `@RequestBody User user` w/o DTO | DTO class with only writable fields, `@JsonIgnoreProperties(ignoreUnknown=true)` plus an *allowlist* DTO |
| Laravel | `User::create($request->all())`, `$user->fill($request->all())` | `$request->only([...])`, `$fillable` on model |

## Vulnerable shape

```ruby
# Rails — the classic
def update
  @user.update(params[:user])    # attacker posts user[role]=admin
end
```

```typescript
// Express + Mongoose
app.put("/profile", async (req, res) => {
  Object.assign(req.user, req.body);   // attacker posts {isAdmin: true}
  await req.user.save();
});
```

```java
// Spring — entity binding
@PostMapping("/users")
public User create(@RequestBody User user) { ... }
// attacker posts {"role": "ADMIN"} and User.role is writable
```

## Safe shape

- **DTO at the boundary, entity inside**. Never bind a request body
  directly to a persistent entity.
- **Explicit allowlist**, not denylist. `permit(:name, :email)`, not
  `except(:role)` — adding a field to the model shouldn't silently
  expose it.
- **Schema validation library** (Pydantic, Zod, Joi, marshmallow,
  io-ts) that rejects unknown keys by default.

## Suppression rules

- The body is destructured with explicit keys (`const {name, email} =
  req.body`) — the model only ever sees the named fields.
- A DTO class is used and its fields are an allowlist of safe
  attributes.
- The framework validator is configured `additionalProperties: false`
  (JSON Schema) / `ConfigDict(extra="forbid")` (Pydantic v2) and runs
  before binding.

## Trace direction

Sink-first: find every model-creation and model-update call. For each,
look at the source of the keyword args. If it's the raw request body,
form data, or query string passed in bulk, it's a candidate. Confidence
is 10 if there's a known sensitive field on the model (`role`, `isAdmin`,
`ownerId`, `tenantId`, `balance`, `email_verified`). Drop to 8 if no
clearly-sensitive field exists today — the bug is still a bug, but the
impact depends on future schema growth.

## Fix vocabulary

For each finding, name the boundary, propose the DTO/allowlist pattern,
and recommend codifying the allowlist via `/codify` so new endpoints
default to safe. If the codebase has a shared `BaseSchema` with
`extra="forbid"`, cite it as the safe-by-default helper.
