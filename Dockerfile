FROM alpine:latest
LABEL maintainer="nic@boet.cc"

RUN apk add --no-cache git fping tcl expect openssl \
    bind-tools openssh logrotate tini
RUN apk add --update busybox-suid

RUN addgroup -S app && adduser -S -G app app

WORKDIR /opt/pan-ts-agent-discovery
COPY src/ ./
COPY crontab /tmp/crontab
COPY logrotate /etc/logrotate.d/app
RUN mkdir /var/log/paloalto \
 && chown app:app /var/log/paloalto

USER app
RUN crontab /tmp/crontab

USER root
RUN rm /tmp/crontab

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/usr/sbin/crond", "-f", "-d", "0"]
