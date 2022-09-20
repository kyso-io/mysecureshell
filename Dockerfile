ARG ALPINE_VERSION
FROM registry.kyso.io/docker/alpine:$ALPINE_VERSION as builder
LABEL maintainer="Sergio Talens-Oliag <sto@kyso.io>"
RUN apk update &&\
 apk add --no-cache alpine-sdk git musl-dev &&\
 git clone https://github.com/sto/mysecureshell.git &&\
 cd mysecureshell &&\
 ./configure --prefix=/usr --sysconfdir=/etc --mandir=/usr/share/man\
 --localstatedir=/var --with-shutfile=/var/lib/misc/sftp.shut --with-debug=2 &&\
 make all && make install &&\
 rm -rf /var/cache/apk/*
COPY sftp_config /etc/ssh/

FROM registry.kyso.io/docker/alpine:$ALPINE_VERSION
LABEL maintainer="Sergio Talens-Oliag <sto@kyso.io>"
COPY --from=builder /usr/bin/mysecureshell /usr/bin/mysecureshell
COPY --from=builder /usr/bin/sftp-* /usr/bin/
RUN apk update &&\
 apk add --no-cache openssh shadow pwgen &&\
 sed -i -e "s|^.*\(AuthorizedKeysFile\).*$|\1 /etc/ssh/auth_keys/%u|"\
 /etc/ssh/sshd_config &&\
 mkdir /etc/ssh/auth_keys &&\
 cat /dev/null > /etc/motd &&\
 add-shell '/usr/bin/mysecureshell' &&\
 rm -rf /var/cache/apk/*
COPY sftp_config /etc/ssh/
COPY entrypoint.sh /
EXPOSE 22
VOLUME /sftp
ENTRYPOINT ["/entrypoint.sh"]
CMD ["server"]
