# Yappa backend + LiveKit all-in-one stack

This keeps Yappa as one backend folder, but starts the media server for voice and screen share in the same Docker Compose stack.

You still have **one Yappa project**, **one join flow**, and **one command to start it**:

```bash
cd /path/to/your/yappa-server
docker compose up -d --build
```

## What changed

`docker-compose.yml` now starts:

- `yappa-backend` on port `4100`
- `yappa-livekit` on ports `7880/tcp`, `7881/tcp`, and `7882/udp`

The backend already has `/api/voice/token`, so once LiveKit is configured in `.env`, Yappa can mint tokens and join voice rooms.

## One-time setup

Copy `.env.example` to `.env` if you do not already have one.

Then edit only these values:

```env
LIVEKIT_URL=ws://YOUR_SERVER_LAN_IP:7880
LIVEKIT_API_KEY=change_me_key
LIVEKIT_API_SECRET=change_me_secret
LIVEKIT_USE_EXTERNAL_IP=false
```

For a simple LAN test, `LIVEKIT_URL` should be your server's LAN IP, like:

```env
LIVEKIT_URL=ws://192.168.1.254:7880
```

## Start the stack

```bash
docker compose up -d --build
docker compose logs -f yappa-livekit
docker compose logs -f yappa-backend
```

## Test flow

1. Start the stack.
2. Start the Yappa backend client.
3. Join the same voice deck from two clients.
4. If the banner about voice transport configuration is gone, the backend is seeing your LiveKit config.
5. If both users join the same deck, they should now attempt a real room connection.

## Important note about outside-internet access

This stack is perfect for:

- same machine testing
- same LAN testing
- WireGuard / VPN testing

For public internet voice, forwarding only `4100` is **not enough**. You will eventually need additional media ports and probably TLS on a real domain for the best compatibility.
