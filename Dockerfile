# JBrowse 1.x for InterMine, served as static files by nginx.
#
# JBrowse 1.x is a pure client-side application: once built it is a folder
# of HTML, JavaScript and CSS, and the genome data is fetched by the
# browser directly from each InterMine's own web service
# (<PUBLIC_URL>/<MINE>/service/jbrowse/...). Nothing here talks to a mine.
#
# The release archive is downloaded at build time and checked against a
# pinned SHA-256, so the image is reproducible.

FROM alpine:3.20 AS fetch
ARG JBROWSE_VERSION=1.16.11
ARG JBROWSE_SHA256=1482279b572102bd34f240d5e63a77ef0e53a5ccad6c63ae6eb1da44bcec4260
RUN apk add --no-cache curl unzip \
 && curl -fsSL -o /tmp/jbrowse.zip \
      "https://github.com/GMOD/jbrowse/releases/download/${JBROWSE_VERSION}-release/JBrowse-${JBROWSE_VERSION}.zip" \
 && echo "${JBROWSE_SHA256}  /tmp/jbrowse.zip" | sha256sum -c - \
 && unzip -q /tmp/jbrowse.zip -d /tmp \
 && mv "/tmp/JBrowse-${JBROWSE_VERSION}" /jbrowse \
 && rm -rf /jbrowse/sample_data /jbrowse/src /jbrowse/docs /jbrowse/bin \
 # InterMine hands JBrowse a ?data= URL on the mine's own host, so JBrowse
 # must accept a data root on another origin. This is the one edit the
 # InterMine documentation requires ("Install JBrowse").
 && sed -i 's/"allowCrossOriginDataRoot": false/"allowCrossOriginDataRoot": true/' /jbrowse/index.html \
 && grep -q '"allowCrossOriginDataRoot": true' /jbrowse/index.html

FROM nginx:1.27.1-alpine
COPY --from=fetch /jbrowse /usr/share/nginx/html
COPY jbrowse_conf.json /usr/share/nginx/html/jbrowse_conf.json
COPY default.conf /etc/nginx/conf.d/default.conf
HEALTHCHECK CMD wget -qO /dev/null http://127.0.0.1/index.html || exit 1
