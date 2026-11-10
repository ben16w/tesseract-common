FROM haugene/transmission-openvpn

RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d \
 && chmod +x /usr/sbin/policy-rc.d \
 && apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends dante-server \
 && rm -rf /var/lib/apt/lists/* /usr/sbin/policy-rc.d

COPY danted.conf /etc/danted.conf
COPY scripts/transmission-post-start.sh /scripts/transmission-post-start.sh
COPY scripts/transmission-pre-stop.sh /scripts/transmission-pre-stop.sh
RUN chmod +x /scripts/transmission-post-start.sh /scripts/transmission-pre-stop.sh
