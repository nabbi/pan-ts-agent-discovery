FROM alpine:latest
LABEL maintainer="nic@boet.cc"

RUN apk add --no-cache git fping tcl expect openssl \
    bind-tools openssh logrotate tini

WORKDIR /opt/pan-ts-agent-discovery
COPY src/ ./

COPY crontab .
RUN cat crontab >> /etc/crontabs/root \
 && rm crontab
COPY logrotate /etc/logrotate.d/pan-ts-agent-discovery

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/usr/sbin/crond", "-f", "-d", "0"]
