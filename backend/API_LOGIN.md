# Login API (POST /auth/login)

This document describes the login endpoint used to obtain a JWT for authenticated requests. The register route is intentionally omitted (private project).

## Endpoint

- Method: POST
- Path: /auth/login
- Purpose: Exchange username + password for a JWT and basic user info.

## Authentication
- No authentication required to call this endpoint.
- On success the endpoint returns a JSON Web Token (JWT). Use it in subsequent requests with the `Authorization: Bearer <token>` header.
- Tokens are signed using `process.env.JWT_SECRET` (fallback `dev-secret`) and expire after 8 hours.

## Request payload
Content-Type: application/json

Schema (Zod equivalent used server-side):

{
  "username": "string (min 1)",
  "password": "string (min 1)"
}

Example request body:

{
  "username": "alice",
  "password": "s3cret-password"
}

## Successful response (200)

Content-Type: application/json

Example:

{
  "token": "<jwt-token-string>",
  "user": {
    "id": 123,
    "username": "alice",
    "name": "Alice Example"
  }
}

Notes:
- `token` is a JWT with payload: { sub: user.id, username: user.username }
- Token expiry is 8 hours from issuance.
- The `user` object contains non-sensitive public fields. Password hash is never returned.

## Error responses

400 Bad Request
- Triggered when the request body fails validation (missing fields or wrong types).
- Response shape (example):

{
  "error": { /* zod formatted validation errors */ }
}

401 Unauthorized
- Triggered when the username does not exist or the password does not match.
- Response:

{
  "error": "invalid credentials"
}

500 Internal Server Error
- Generic server error. Response format may vary.

## Example curl

Login with credentials and save the token to a shell variable:

```bash
curl -s -X POST -H "Content-Type: application/json" \
  -d '{"username":"alice","password":"s3cret-password"}' \
  http://localhost:3000/auth/login | jq -r '.token' > token.txt
```

Use the token in requests:

```bash
TOKEN=$(cat token.txt)
curl -H "Authorization: Bearer $TOKEN" http://localhost:3000/files
```

(If you don't have `jq` installed, you can inspect the whole JSON response directly.)

## Server-side details (for frontend engineers)

- Passwords are hashed on the server using `bcrypt` (bcryptjs). The frontend should send plaintext over TLS and not hash on the client.
- The server compares the supplied password to the stored `password_hash` using `bcrypt.compare`.
- The backend renders a generic `invalid credentials` message on failure — do not rely on different messages to distinguish username existence.

## Notes & next steps
- If you want `email` or other fields included in the `user` object, tell me and I will update the response and `createUser`/`findUserByUsername` helpers.
- If you'd like the register route documented too (private/admin-only), I can add it but you requested it's not required.

---
Generated from the current server implementation in `src/routes/auth.ts` (login payload and response shapes).