FROM alpine:3.20

RUN apk add --no-cache bash coreutils findutils gawk gzip grep python3 curl mariadb-client pv

# Copy scripts into image so they're available without volume mounts
COPY scripts/ /opt/crz-opt-scripts/

WORKDIR /workspace

ENTRYPOINT ["bash", "/opt/crz-opt-scripts/restore-worker-entrypoint.sh"]
