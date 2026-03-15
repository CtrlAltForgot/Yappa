# newChat node API contract (phase 5)

## Identity model
- each node manages its own usernames and passwords
- there is no cross-node identity service
- client stores session token per node

## Auth flow
1. user enters username + password for a node
2. client sends `POST /api/auth/session`
3. server creates the account if it does not exist yet
4. otherwise server verifies the password
5. server returns a persistent session token
6. client stores that token and reuses it on next launch

## Presence flow
1. client opens Socket.IO with `auth.token`
2. server verifies the token
3. server marks that user online while at least one socket is connected
4. server emits `presence:update`

## Message flow
1. client fetches initial history over HTTP
2. client sends new messages over HTTP for now
3. server emits `message:new` to connected clients
4. client appends live messages to the open channel

## Voice/media plan
After chat/auth/presence are stable, add a self-hosted media server.
That will handle:
- voice channels
- adaptive quality
- mute/deafen
- screen/window share
- later camera/video if wanted
