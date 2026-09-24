# Private Folder internet relay

The relay holds no files and cannot decrypt filenames, manifests, or file chunks. It only forwards end-to-end encrypted WebSocket frames while both devices are online.

Deploy the Docker image behind a TLS reverse proxy and expose `/v1/connect` as WebSocket traffic. Set `RELAY_TOKEN` to a random value of at least 32 characters. Devices use `wss://your-domain/v1/connect` and the same private token. Do not expose plain `ws://` over the internet.

Example container command:

```sh
docker build -t private-folder-relay .
docker run -d --restart unless-stopped -e RELAY_TOKEN='replace-with-32-random-characters' -p 127.0.0.1:8080:8080 private-folder-relay
```

Configure Caddy, nginx, or a managed container host to terminate HTTPS/WSS and proxy to `127.0.0.1:8080`. `GET /health` returns relay health and the current connection count without device identities.
