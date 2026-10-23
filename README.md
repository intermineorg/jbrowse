# JBrowse for InterMine

A self-contained Docker image and compose stack that serves
[JBrowse 1.16.11](https://jbrowse.org/) for InterMine report pages. One
instance serves any number of mines: JBrowse is a pure client-side
application, and the browser fetches all genome data straight from each
mine's own web service (`<mine URL>/service/jbrowse/...`). Nothing in this
container talks to a mine.

This is the piece InterMine's documentation assumes exists but does not
ship. Report pages (the BlueGenes tool `@intermine/bluegenes-jbrowse-tool`
and the classic webapp's `jbrowseDisplayer.jsp`) embed
`https://jbrowse.intermine.org/?data=<mine service>/jbrowse/config/<taxon>`
in an iframe, so when that host is down every gene report page shows a
blank panel.

It was split out of
[intermineorg/docker_template](https://github.com/intermineorg/docker_template),
which deploys a mine. Each mine clone does not need its own JBrowse.

## Contents

| File | Purpose |
|------|---------|
| `Dockerfile` | Downloads the JBrowse 1.16.11 release (SHA-256 pinned), sets `allowCrossOriginDataRoot` to `true` (the one edit InterMine's docs require), serves it with nginx. |
| `default.conf` | nginx static-site config. Deliberately sends no `X-Frame-Options`, so mines can iframe it. |
| `jbrowse_conf.json` | The dataset drop-down in JBrowse's menu bar: one entry per mine. |
| `docker-compose.yml` | One container, `jbrowse`, published on `JBROWSE_HTTP_PORT` (default 14880). |
| `.env.example` | Copy to `.env` to change the port. |
| `docker-compose.override.yml.example` | Copy to `docker-compose.override.yml` to join the container to each mine's Docker network (route B below). |

## Start

```sh
git clone https://github.com/intermineorg/jbrowse.git ~/intermine/docker/jbrowse
cd ~/intermine/docker/jbrowse
docker-compose up -d --build
docker ps --filter name=jbrowse --format '{{.Names}} {{.Status}}'          # ... (healthy)
curl -s http://localhost:14880/ | grep -o 'allowCrossOriginDataRoot": [a-z]*'   # true
```

The container listens on plain HTTP on the host port only. Browsers refuse
an `http://` iframe inside an `https://` page, so it has to be published
over HTTPS by one of the two routes below. They can be used together.

## Route A: a shared hostname (`https://jbrowse.<domain>/`)

Give the container a hostname on the TLS front end that already serves the
mines. If that hostname is `jbrowse.intermine.org`, mines that keep
InterMine's defaults need **no change at all**.

1. DNS: an `A` record (and `AAAA` if available) for the hostname pointing at
   the server.
2. A virtual host on the front end for that name, with its own certificate,
   proxying to `127.0.0.1:14880`. The certificate must cover the hostname:
   a name that resolves to the server but is served with another site's
   certificate gives every visitor a security warning and the iframe stays
   blank. With nginx and certbot:

   ```nginx
   server {
       listen 80;
       listen [::]:80;
       server_name jbrowse.intermine.org;
       return 301 https://$host$request_uri;
   }
   server {
       listen 443 ssl http2;
       listen [::]:443 ssl http2;
       server_name jbrowse.intermine.org;
       ssl_certificate     /etc/letsencrypt/live/jbrowse.intermine.org/fullchain.pem;
       ssl_certificate_key /etc/letsencrypt/live/jbrowse.intermine.org/privkey.pem;
       location / {
           proxy_pass http://127.0.0.1:14880;
           proxy_set_header Host $host;
           proxy_set_header X-Forwarded-Proto https;
           proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
       }
   }
   ```

   ```sh
   sudo certbot --nginx -d jbrowse.intermine.org
   sudo nginx -t && sudo systemctl reload nginx
   ```

   The JBrowse page must be at the **root** of that hostname, because the
   tool's default URL is `https://jbrowse.intermine.org/?data=`. A
   sub-path such as `https://host/mine-jbrowse/` works too, but then each
   mine must be told about it (step 3 of route B).

3. Check:

   ```sh
   curl -sI https://jbrowse.intermine.org/ | head -1            # HTTP/2 200
   curl -s  https://jbrowse.intermine.org/ | grep -o 'allowCrossOriginDataRoot": [a-z]*'
   ```

## Route B: under each mine's own hostname (`https://<mine>/jbrowse/`)

When no new public port or hostname is available, each mine's own nginx
container can proxy to this one, so JBrowse is reached as
`https://www.humanmine.org/jbrowse/`. This is same-origin with the mine's
data, so CORS is not involved, but it must be set up per mine.

1. Join the container to each mine's frontend network. The network is named
   `<compose project>_frontend`, where the project is the mine's directory
   name (`docker network ls --filter name=frontend`).

   ```sh
   cp docker-compose.override.yml.example docker-compose.override.yml   # edit the network names
   docker-compose up -d
   docker inspect jbrowse -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}'
   ```

2. Route `/jbrowse/` in the mine's nginx. Mines deployed from
   `docker_template` already have this in `nginx/nginx.conf.template`. For
   any other nginx in front of a mine, add inside the `server` block:

   ```nginx
   location /jbrowse/ {
       resolver 127.0.0.11 valid=10s ipv6=off;
       set $jbrowse http://jbrowse:80;
       rewrite ^/jbrowse/(.*)$ /$1 break;
       proxy_pass $jbrowse;
       proxy_set_header Host $host;
       proxy_set_header X-Forwarded-Proto https;
   }
   location = /jbrowse {
       absolute_redirect off;
       return 301 /jbrowse/;
   }
   ```

   The upstream is a runtime-resolved variable, so the mine's nginx starts
   and serves normally even while no `jbrowse` container exists (requests
   to `/jbrowse/` then return 502). Rebuild the mine's nginx
   (`docker-compose up -d --build nginx` in the mine directory) and check
   `curl -sI https://www.humanmine.org/jbrowse/ | head -1`.

3. Tell the mine where JBrowse is.
   - BlueGenes: edit `jbrowseUrl` in the installed tool's `config.json`
     (in the mine's tools directory, mounted at `./data/tools` in
     `docker_template`):

     ```sh
     f=$(find data/tools -path '*bluegenes-jbrowse-tool/config.json')
     sed -i 's#"https://jbrowse.intermine.org/?data="#"https://www.humanmine.org/jbrowse/?data="#' "$f"
     docker-compose restart bluegenes
     ```

     The tool store re-reads `config.json` on every request. Reinstalling
     or updating the tool from the BlueGenes admin page restores the
     default URL, so keep a note of the edit.
   - Classic webapp (only if its report pages are in use): set
     `jbrowse.install.url = https://www.humanmine.org/jbrowse/` in the mine
     properties and run `./gradlew cargoRedeployRemote`.

## Check from a browser

Open the URL a HumanMine gene report page embeds, substituting your JBrowse
base URL:

```
https://www.humanmine.org/jbrowse/?data=https%3A%2F%2Fwww.humanmine.org%2Fhumanmine%2Fservice%2Fjbrowse%2Fconfig%2F9606&loc=1:1000000..1100000&tracks=Humanmine-9606-Gene
```

You should see chromosome 1 with a Gene track, and the dataset drop-down
top left should list the mines from `jbrowse_conf.json`. Then open a gene
report page on each mine. If a panel is blank, press F12, open the Network
tab and reload: the failing request is either the JBrowse page itself
(front end, certificate or network problem) or a `service/jbrowse/...`
request (mine problem, see below).

## `jbrowse_conf.json`

The keys under `datasets` must equal the `dataset_id` each mine writes into
its `trackList.json`, which is `<project.title>-<taxonId>`:

```sh
curl -s https://www.flymine.org/flymine/service/jbrowse/config/7227/trackList.json | grep -o '"dataset_id":"[^"]*"'
```

HumanMine's is `Humanmine-9606` and FlyMine's is `FlyMine-7227` (both
verified). To add a mine, add an entry and `docker-compose up -d --build`.
A wrong key only affects which entry the drop-down highlights.

## Verifying the mine side

JBrowse makes these requests. All must return JSON, not HTML, and when
JBrowse is on another origin (route A) must carry
`Access-Control-Allow-Origin`:

```sh
M=https://www.humanmine.org/humanmine/service/jbrowse
curl -sI "$M/config/9606/trackList.json"   | grep -i -E '^(HTTP|content-type|access-control-allow-origin)'
curl -sI "$M/config/9606/seq/refSeqs.json" | grep -i -E '^(HTTP|content-type)'
curl -s  "$M/config/9606/trackList.json"   | grep -o '"baseUrl":"[^"]*"' | sort -u   # must be the public URL
curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' "$M/9606/features/1?start=1000000&end=1100000&type=Gene"
```

The `baseUrl` values come from the mine's `webapp.baseurl` property. In a
Docker deployment that must be the public URL, not the container's; see
`docs/codegen-url-fix.md` in `docker_template`.

## Operations

- Logs: `docker-compose logs -f`. Restart: `docker-compose restart`.
  Rebuild after editing any file: `docker-compose up -d --build`. The
  container restarts by itself after a reboot (`restart: unless-stopped`).
- Moving an existing deployment here from `docker_template/jbrowse/`: copy
  `.env` and `docker-compose.override.yml` across, run `docker-compose down`
  in the old directory and `docker-compose up -d --build` in this one. The
  container name and port are unchanged, so nothing else needs editing;
  JBrowse is unavailable for the minute in between.
- Upgrade: change `JBROWSE_VERSION` and `JBROWSE_SHA256` in the Dockerfile
  (`sha256sum` of the release zip) and rebuild. Stay on 1.16.x: JBrowse 2
  has a different configuration model and InterMine's endpoints implement
  the 1.x REST specification.
- `allowCrossOriginDataRoot` lets any page pass any `?data=` URL. That is
  the intended use and JBrowse has no logins, but it is why the setting is
  off by default. The container serves nothing else.

## Licence

MIT, see `LICENSE`. JBrowse itself is distributed under its own licence
(LGPL 2.1 / Artistic 2.0).
